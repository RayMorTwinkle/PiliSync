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
// current target. A nil side means "unknown" and does not count as a
// mismatch (older clients do not report a target).
func sameTarget(a, b *Target) bool {
	if a == nil || b == nil {
		return true
	}
	return a.Type == b.Type &&
		a.Bvid == b.Bvid &&
		a.Cid == b.Cid &&
		a.Epid == b.Epid &&
		a.RoomId == b.RoomId
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
	if r.Playback.CurrentTime == r.Playback.Duration {
		return false
	}
	for _, m := range r.members {
		if m.IsLoading && sameTarget(m.Target, r.Playback.Target) {
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
func (r *Room) setTargetLocked(t *Target) {
	r.Playback.Target = t
	r.Playback.CurrentTime = 0
	r.Playback.Paused = false
	r.Playback.LastUpdateClientTime = now()
	r.Playback.LastUpdateServerTime = now()
}

func (r *Room) upsertMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.upsertMemberLocked(tempUser)
}

func (r *Room) upsertMemberLocked(tempUser string) {
	if _, ok := r.members[tempUser]; !ok {
		r.members[tempUser] = &Member{TempUser: tempUser}
	}
}

func (r *Room) removeMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.members, tempUser)
}

// setLoading records a member's loading flag and current page. Returns
// false when the tempUser is not an online member.
func (r *Room) setLoading(tempUser string, isLoading bool, target *Target) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	m, ok := r.members[tempUser]
	if !ok {
		return false
	}
	m.IsLoading = isLoading
	m.Target = target
	return true
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
)

type RoomStore struct {
	mu    sync.Mutex
	rooms map[string]*Room
	// expire/interval are captured at construction so tests can tune them
	// per store without racing the package defaults.
	expire   time.Duration
	interval time.Duration
	// called when a room expires; the store lock is NOT held during the call
	onExpire func(room *Room)
}

func NewRoomStore(onExpire func(room *Room)) *RoomStore {
	return newRoomStore(onExpire, roomExpire, cleanupInterval)
}

func newRoomStore(onExpire func(room *Room), expire, interval time.Duration) *RoomStore {
	rs := &RoomStore{
		rooms:    make(map[string]*Room),
		expire:   expire,
		interval: interval,
		onExpire: onExpire,
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
			id:       newRoomID(),
			Name:     name,
			Password: md5hex(password),
			HostId:   hostId,
			members:  make(map[string]*Member),
			seen:     map[string]bool{hostId: true},
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
