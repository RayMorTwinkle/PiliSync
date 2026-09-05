package main

import (
	"crypto/md5"
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

type Member struct {
	TempUser  string  `json:"tempUser"`
	IsLoading bool    `json:"isLoading"`
	LastSeen  float64 `json:"-"`
}

// mu guards HostId, Playback and members. Never acquire Hub.mu while holding it.
type Room struct {
	Name     string
	Password string

	mu       sync.Mutex
	HostId   string
	Playback PlaybackState
	members  map[string]*Member
}

func (r *Room) setHostLocked(id string) { r.HostId = id }

func (r *Room) IsHost(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return id != "" && id == r.HostId
}

func (r *Room) IsProtected() bool { return r.Password != md5hex("") }

func (r *Room) snapshotLocked() map[string]any {
	pb := r.Playback
	pb.Target = nil
	if r.Playback.Target != nil {
		t := *r.Playback.Target
		pb.Target = &t
	}
	anyLoading := false
	for _, m := range r.members {
		if m.IsLoading && now()-m.LastSeen < 10 {
			anyLoading = true
		}
	}
	snap := map[string]any{
		"name":            r.Name,
		"protected":       r.IsProtected(),
		"hostId":          r.HostId,
		"memberCount":     len(r.members),
		"waitForLoadding": anyLoading,
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

func (r *Room) setTargetLocked(t *Target) {
	r.Playback.Target = t
	r.Playback.LastUpdateServerTime = now()
}

func (r *Room) upsertMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.upsertMemberLocked(tempUser)
}

func (r *Room) upsertMemberLocked(tempUser string) {
	m, ok := r.members[tempUser]
	if !ok {
		m = &Member{TempUser: tempUser}
		r.members[tempUser] = m
	}
	m.LastSeen = now()
}

func (r *Room) removeMember(tempUser string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.members, tempUser)
}

func (r *Room) setLoading(tempUser string, isLoading bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if m, ok := r.members[tempUser]; ok {
		m.IsLoading = isLoading
		m.LastSeen = now()
	}
}

func (r *Room) activeMembers() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, m := range r.members {
		if now()-m.LastSeen < 10 {
			n++
		}
	}
	return n
}

func (r *Room) anyoneLoading() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, m := range r.members {
		if m.IsLoading && now()-m.LastSeen < 10 {
			return true
		}
	}
	return false
}

func (r *Room) knownMember(tempUser string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.members[tempUser]
	return ok
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

var roomExpire = 3 * time.Minute

type RoomStore struct {
	mu    sync.Mutex
	rooms map[string]*Room
	// called when a room expires; the store lock is NOT held during the call
	onExpire func(name string)
}

func NewRoomStore(onExpire func(name string)) *RoomStore {
	rs := &RoomStore{rooms: make(map[string]*Room), onExpire: onExpire}
	go rs.cleanupLoop()
	return rs
}

func (rs *RoomStore) cleanupLoop() {
	t := time.NewTicker(30 * time.Second)
	for range t.C {
		var expired []string
		rs.mu.Lock()
		for name, room := range rs.rooms {
			room.mu.Lock()
			stale := now()-room.Playback.LastUpdateServerTime > roomExpire.Seconds()
			room.mu.Unlock()
			if stale {
				expired = append(expired, name)
				delete(rs.rooms, name)
			}
		}
		rs.mu.Unlock()
		for _, name := range expired {
			log.Printf("[cleanup] expire room %s", name)
			if rs.onExpire != nil {
				rs.onExpire(name)
			}
		}
	}
}

func (rs *RoomStore) Get(name string) *Room {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.rooms[name]
}

func (rs *RoomStore) GetOrCreate(name, password, hostId string) *Room {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	room, ok := rs.rooms[name]
	if !ok {
		room = &Room{
			Name:     name,
			Password: md5hex(password),
			HostId:   hostId,
			members:  make(map[string]*Member),
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
