package main

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"sync"
	"time"
)

type Target struct {
	Type   string `json:"type"`
	Bvid   string `json:"bvid,omitempty"`
	Cid    int64  `json:"cid,omitempty"`
	Epid   int64  `json:"epid,omitempty"`
	RoomId int64  `json:"roomId,omitempty"`
	Title  string `json:"title,omitempty"`
}

// sameTarget reports whether a member's reported page matches the room's
// current target. A nil member target means "not on the video page" and
// must NOT count — a member sitting on the room page with a background
// player still buffering would otherwise hold the room barrier (spec F2).
// A nil room target stays lenient: early-room states still aggregate.
func sameTarget(member, room *Target) bool {
	if member == nil {
		return false
	}
	if room == nil {
		return true
	}
	return member.Type == room.Type &&
		member.Bvid == room.Bvid &&
		member.Cid == room.Cid &&
		member.Epid == room.Epid &&
		member.RoomId == room.RoomId
}

type PlaybackState struct {
	PlaybackRate         float64 `json:"playbackRate"`
	CurrentTime          float64 `json:"currentTime"`
	Paused               bool    `json:"paused"`
	Duration             float64 `json:"duration"`
	LastUpdateClientTime float64 `json:"lastUpdateClientTime"`
	LastUpdateServerTime float64 `json:"lastUpdateServerTime"`
	Url                  string  `json:"url,omitempty"`
	VideoTitle           string  `json:"videoTitle,omitempty"`
	Target               *Target `json:"target,omitempty"`
}

// Member represents one connected participant. Membership tracks the live
// WebSocket connection: entries are added on join/update and removed on
// disconnect, never expired by a timer.
type Member struct {
	TempUser  string  `json:"tempUser"`
	IsLoading bool    `json:"isLoading"`
	Target    *Target `json:"-"`
	// LoadingSince marks when IsLoading last flipped false→true. The
	// loading barrier stops honouring the flag once it is older than
	// maxMemberLoadingWait, so a member whose player is permanently wedged
	// (dead network, failed source) cannot deadlock the room forever.
	LoadingSince time.Time `json:"-"`
	// JoinedAt orders members for host handover on host disconnect.
	JoinedAt time.Time `json:"-"`
	// LastHeartbeat is refreshed by every update_member (and join). The
	// barrier aggregation ignores members whose heartbeat is stale
	// (memberHeartbeatTTL) — a half-open/backgrounded client whose socket
	// has not been reaped yet must not hold the room barrier.
	LastHeartbeat time.Time `json:"-"`
}

// mu guards HostId, Playback, members and seen. Never acquire Hub.mu while
// holding it.
type Room struct {
	id       string
	Name     string
	Password string

	mu       sync.Mutex
	HostId   string
	Playback PlaybackState
	// members: currently online participants (deleted on disconnect).
	members map[string]*Member
	// seen: tempUsers that have ever sent `update` (VT userIds). Written
	// only, never deleted while the room lives; drives takeover semantics.
	seen map[string]bool
	// loadingWait is captured from the owning RoomStore at creation.
	loadingWait time.Duration
	// lastMemberUpdateBarrier is the waitForLoadding value last published
	// through the member_update path — lets setLoading broadcast a barrier
	// flip (e.g. loading TTL expiry) even when no member flag changed.
	lastMemberUpdateBarrier bool
	// transferReqAt rate-limits transfer_request per sender so a member
	// cannot spam the host with approval dialogs.
	transferReqAt map[string]time.Time
}

func (r *Room) setHostLocked(id string) { r.HostId = id }

func (r *Room) IsHost(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return id != "" && id == r.HostId
}

func (r *Room) IsProtected() bool { return r.Password != md5hex("") }

// anyoneLoadingLocked reports waitForLoadding: an online member on the same
// page is loading, except when playback reached the end (VT: a member
// buffering on the last frame must not stall the room).
func (r *Room) anyoneLoadingLocked() bool {
	// End-of-video exemption with float tolerance: a member buffering on
	// the tail (credits) must not stall the room. Strict equality missed
	// real reports like currentTime=99.9 / duration=100. The duration must
	// be a sane length — a degenerate duration=0.001 would exempt the
	// barrier at every position.
	if r.Playback.Duration >= 1.0 &&
		r.Playback.CurrentTime >= r.Playback.Duration-0.5 {
		return false
	}
	for _, m := range r.members {
		// The host is excluded: its buffering already reaches members via
		// reportedPaused in the playback payload, and counting it here
		// would pause the host through its own member barrier.
		if m.TempUser == r.HostId {
			continue
		}
		if m.IsLoading &&
			time.Since(m.LastHeartbeat) < memberHeartbeatTTL &&
			time.Since(m.LoadingSince) < r.loadingWait &&
			sameTarget(m.Target, r.Playback.Target) {
			return true
		}
	}
	return false
}

// snapshotLocked deliberately omits HostId: the host uuid is a write
// capability and must never be broadcast. Clients learn their own role via
// the per-recipient "isHost" flag injected by the hub.
func (r *Room) snapshotLocked() map[string]any {
	pb := r.Playback
	pb.Target = nil
	if r.Playback.Target != nil {
		t := *r.Playback.Target
		pb.Target = &t
	}
	snap := map[string]any{
		"name":            r.Name,
		"protected":       r.IsProtected(),
		"memberCount":     len(r.members),
		"waitForLoadding": r.anyoneLoadingLocked(),
	}
	b, _ := json.Marshal(pb)
	var pbMap map[string]any
	_ = json.Unmarshal(b, &pbMap)
	for k, v := range pbMap {
		snap[k] = v
	}
	return snap
}

func (r *Room) Snapshot() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snapshotLocked()
}

func (r *Room) updatePlaybackLocked(pb PlaybackState) {
	r.Playback = pb
}

// setTargetLocked switches to a new video; position resets to the start so
// a snapshot taken between navigate and the next update is self-consistent.
// Paused=true: a member joining/reconnecting in that window must wait at
// the start rather than be seeked to 0 while "playing".
func (r *Room) setTargetLocked(t *Target) {
	r.Playback.Target = t
	r.Playback.CurrentTime = 0
	r.Playback.Paused = true
	r.Playback.LastUpdateClientTime = now()
	r.Playback.LastUpdateServerTime = now()
}

func (r *Room) upsertMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.upsertMemberLocked(tempUser)
}

func (r *Room) upsertMemberLocked(tempUser string) {
	if m, ok := r.members[tempUser]; ok {
		m.LastHeartbeat = time.Now()
		return
	}
	r.members[tempUser] = &Member{
		TempUser:      tempUser,
		JoinedAt:      time.Now(),
		LastHeartbeat: time.Now(),
	}
}

func (r *Room) hasMember(tempUser string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.members[tempUser]
	return ok
}

// transferHostLocked hands HostId to the earliest-joined online member —
// a host disconnect used to freeze the room until expiry because members
// never send `update` and could never take over. Returns "" when nobody
// remains (room then expires normally, preserving brief host reconnects
// for the alone-host case).
func (r *Room) transferHostLocked() string {
	var oldest *Member
	for _, m := range r.members {
		if oldest == nil || m.JoinedAt.Before(oldest.JoinedAt) {
			oldest = m
		}
	}
	if oldest == nil {
		return ""
	}
	r.HostId = oldest.TempUser
	r.seen[oldest.TempUser] = true
	return oldest.TempUser
}

func (r *Room) removeMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.members, tempUser)
}

// setLoading records a member's loading flag and current page. Returns
// ok=false when the tempUser is not an online member; changed reports
// whether the published member_update state (isLoading/target) actually
// moved — unchanged heartbeats only warrant a sender echo, not a room-wide
// broadcast.
func (r *Room) setLoading(tempUser string, isLoading bool, target *Target) (ok, changed bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	m, ok := r.members[tempUser]
	if !ok {
		return false, false
	}
	changed = m.IsLoading != isLoading || !targetEqual(m.Target, target)
	if isLoading && !m.IsLoading {
		m.LoadingSince = time.Now()
	}
	m.IsLoading = isLoading
	m.Target = target
	m.LastHeartbeat = time.Now()
	// Barrier flips that are not member-state changes (loading TTL
	// expiry, heartbeat staleness) still warrant a broadcast.
	barrier := r.anyoneLoadingLocked()
	if barrier != r.lastMemberUpdateBarrier {
		changed = true
		r.lastMemberUpdateBarrier = barrier
	}
	return true, changed
}

func targetEqual(a, b *Target) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Type == b.Type &&
		a.Bvid == b.Bvid &&
		a.Cid == b.Cid &&
		a.Epid == b.Epid &&
		a.RoomId == b.RoomId
}

func (r *Room) memberCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.members)
}

func (r *Room) anyoneLoading() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.anyoneLoadingLocked()
}

// seenUser reports whether the tempUser has ever sent `update` in this room
// (VT: userIds). Distinct from members: survives disconnects, dies with the
// room.
func (r *Room) seenUser(tempUser string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.seen[tempUser]
}

// markSeen registers a tempUser as an update-writer. Returns true when the
// user was not previously seen (i.e. eligible for takeover).
func (r *Room) markSeen(tempUser string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen[tempUser] {
		return false
	}
	r.seen[tempUser] = true
	return true
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

func newRoomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

var (
	roomExpire      = 3 * time.Minute
	cleanupInterval = 30 * time.Second
	// maxMemberLoadingWait caps how long a member's isLoading may hold the
	// room barrier — defense-in-depth behind the client's own give-up
	// (~20s); covers old/buggy clients that report loading forever.
	maxMemberLoadingWait = 60 * time.Second
	// memberHeartbeatTTL (VT: IsJoined ~10s) bounds how fresh a member's
	// update_member must be for its loading flag to hold the barrier —
	// tighter than the conn-reap timeout so a zombie conn cannot stall
	// the room for pongWait-scale durations.
	memberHeartbeatTTL = 15 * time.Second
)

type RoomStore struct {
	mu    sync.Mutex
	rooms map[string]*Room
	// expire/interval/loadingWait are captured at construction so tests can
	// tune them per store without racing the package defaults.
	expire      time.Duration
	interval    time.Duration
	loadingWait time.Duration
	// called when a room expires; the store lock is NOT held during the call
	onExpire func(room *Room)
}

func NewRoomStore(onExpire func(room *Room)) *RoomStore {
	return newRoomStore(onExpire, roomExpire, cleanupInterval, maxMemberLoadingWait)
}

func newRoomStore(onExpire func(room *Room), expire, interval, loadingWait time.Duration) *RoomStore {
	rs := &RoomStore{
		rooms:       make(map[string]*Room),
		expire:      expire,
		interval:    interval,
		loadingWait: loadingWait,
		onExpire:    onExpire,
	}
	go rs.cleanupLoop()
	return rs
}

func (rs *RoomStore) cleanupLoop() {
	t := time.NewTicker(rs.interval)
	for range t.C {
		var expired []*Room
		rs.mu.Lock()
		for name, room := range rs.rooms {
			room.mu.Lock()
			stale := now()-room.Playback.LastUpdateServerTime > rs.expire.Seconds()
			room.mu.Unlock()
			if stale {
				expired = append(expired, room)
				delete(rs.rooms, name)
			}
		}
		rs.mu.Unlock()
		for _, room := range expired {
			log.Printf("[cleanup] expire room %s", room.Name)
			if rs.onExpire != nil {
				rs.onExpire(room)
			}
		}
	}
}

func (rs *RoomStore) Get(name string) *Room {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.rooms[name]
}

// GetOrCreate returns the room, creating it atomically under the store
// lock. Returns nil when the room does not exist and maxRooms is reached.
func (rs *RoomStore) GetOrCreate(name, password, hostId string) *Room {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	room, ok := rs.rooms[name]
	if !ok {
		if len(rs.rooms) >= maxRooms {
			return nil
		}
		room = &Room{
			id:          newRoomID(),
			Name:        name,
			Password:    md5hex(password),
			HostId:      hostId,
			members:     make(map[string]*Member),
			seen:        map[string]bool{hostId: true},
			loadingWait: rs.loadingWait,
			transferReqAt: make(map[string]time.Time),
		}
		room.Playback.LastUpdateServerTime = now()
		rs.rooms[name] = room
		log.Printf("[room] created %s host=%s", name, hostId)
	}
	return room
}

func (rs *RoomStore) Count() int {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return len(rs.rooms)
}

func now() float64 { return float64(time.Now().UnixMilli()) / 1000 }
