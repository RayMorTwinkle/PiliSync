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
	PlaybackRate        float64 `json:"playbackRate"`
	CurrentTime         float64 `json:"currentTime"`
	Paused              bool    `json:"paused"`
	Duration            float64 `json:"duration"`
	LastUpdateClientTime float64 `json:"lastUpdateClientTime"`
	LastUpdateServerTime float64 `json:"lastUpdateServerTime"`
	Url                 string  `json:"url,omitempty"`
	VideoTitle          string  `json:"videoTitle,omitempty"`
	Target              *Target `json:"target,omitempty"`
}

type Member struct {
	TempUser  string  `json:"tempUser"`
	IsLoading bool    `json:"isLoading"`
	LastSeen  float64 `json:"-"`
}

type Room struct {
	Name     string
	Password string
	HostId   string
	Playback PlaybackState
	WaitingForLoading bool
	membersMu sync.Mutex
	members   map[string]*Member
}

func (r *Room) Snapshot() map[string]any {
	r.membersMu.Lock()
	memberCount := len(r.members)
	anyLoading := false
	for _, m := range r.members {
		if m.IsLoading {
			anyLoading = true
		}
	}
	r.membersMu.Unlock()

	snap := map[string]any{
		"name":            r.Name,
		"protected":       r.Password != md5hex(""),
		"hostId":          r.HostId,
		"memberCount":     memberCount,
		"waitForLoadding": anyLoading,
	}
	b, _ := json.Marshal(r.Playback)
	var pb map[string]any
	_ = json.Unmarshal(b, &pb)
	for k, v := range pb {
		snap[k] = v
	}
	return snap
}

func (r *Room) Host() string { return r.HostId }

func (r *Room) SetHost(id string) { r.HostId = id }

func (r *Room) IsHost(id string) bool { return id != "" && id == r.HostId }

func (r *Room) upsertMember(tempUser string) *Member {
	r.membersMu.Lock()
	defer r.membersMu.Unlock()
	m, ok := r.members[tempUser]
	if !ok {
		m = &Member{TempUser: tempUser}
		r.members[tempUser] = m
	}
	m.LastSeen = now()
	return m
}

func (r *Room) removeMember(tempUser string) bool {
	r.membersMu.Lock()
	defer r.membersMu.Unlock()
	_, ok := r.members[tempUser]
	delete(r.members, tempUser)
	return ok
}

func (r *Room) activeMembers() int {
	r.membersMu.Lock()
	defer r.membersMu.Unlock()
	n := 0
	for _, m := range r.members {
		if now()-m.LastSeen < 10 {
			n++
		}
	}
	return n
}

func (r *Room) anyoneLoading() bool {
	r.membersMu.Lock()
	defer r.membersMu.Unlock()
	for _, m := range r.members {
		if m.IsLoading && now()-m.LastSeen < 10 {
			return true
		}
	}
	return false
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

var roomExpire = 3 * time.Minute

type RoomStore struct {
	mu    sync.Mutex
	rooms map[string]*Room
}

func NewRoomStore() *RoomStore {
	rs := &RoomStore{rooms: make(map[string]*Room)}
	go rs.cleanupLoop()
	return rs
}

func (rs *RoomStore) cleanupLoop() {
	t := time.NewTicker(30 * time.Second)
	for range t.C {
		rs.mu.Lock()
		for name, room := range rs.rooms {
			if now()-room.Playback.LastUpdateServerTime > roomExpire.Seconds() {
				log.Printf("[cleanup] expire room %s", name)
				delete(rs.rooms, name)
			}
		}
		rs.mu.Unlock()
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

func (rs *RoomStore) Delete(name string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	delete(rs.rooms, name)
}

func (rs *RoomStore) Count() int {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return len(rs.rooms)
}

func now() float64 { return float64(time.Now().UnixMilli()) / 1000 }
