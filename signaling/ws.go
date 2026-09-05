package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = 54 * time.Second
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

type Client struct {
	conn     *websocket.Conn
	send     chan []byte
	hub      *Hub
	roomName string
	tempUser string
	isHost   bool
}

func (h *Hub) bind(c *Client, roomName, tempUser string, isHost bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c.roomName = roomName
	c.tempUser = tempUser
	c.isHost = isHost
}

func (c *Client) sendJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	select {
	case c.send <- b:
	default:
		log.Printf("[warn] send buffer full, dropping client %s", c.tempUser)
	}
}

type Hub struct {
	mu      sync.Mutex
	clients map[*Client]bool
	rooms   *RoomStore
}

func NewHub(rooms *RoomStore) *Hub {
	return &Hub{clients: make(map[*Client]bool), rooms: rooms}
}

func (h *Hub) run() {
	t := time.NewTicker(pingPeriod)
	for range t.C {
		h.mu.Lock()
		for c := range h.clients {
			c.sendJSON(map[string]any{"type": "ping", "t": now()})
		}
		h.mu.Unlock()
	}
}

func (h *Hub) broadcast(roomName string, v any, skip *Client) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		if c.roomName != roomName || c == skip {
			continue
		}
		select {
		case c.send <- b:
		default:
		}
	}
}

type Incoming struct {
	Type     string          `json:"type"`
	Room     string          `json:"room"`
	Password string          `json:"password"`
	TempUser string          `json:"tempUser"`
	To       string          `json:"to,omitempty"`
	Text     string          `json:"text,omitempty"`
	T        float64         `json:"t,omitempty"`
	IsLoading *bool          `json:"isLoading,omitempty"`
	Playback *PlaybackState  `json:"playback,omitempty"`
	Target   *Target         `json:"target,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
}

func (h *Hub) handle(c *Client, raw []byte) {
	var msg Incoming
	if err := json.Unmarshal(raw, &msg); err != nil {
		c.sendJSON(map[string]any{"type": "error", "code": "bad_json"})
		return
	}
	switch msg.Type {
	case "join":
		h.handleJoin(c, &msg)
	case "update":
		h.handleUpdate(c, &msg)
	case "update_member":
		h.handleUpdateMember(c, &msg)
	case "navigate":
		h.handleNavigate(c, &msg)
	case "webrtc":
		h.handleWebRTC(c, &msg)
	case "chat":
		h.handleChat(c, &msg)
	case "pong":
		_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	case "tsync":
		c.sendJSON(map[string]any{"type": "tsync_ack", "t": msg.T, "server": now()})
	default:
		c.sendJSON(map[string]any{"type": "error", "code": "unknown_type", "got": msg.Type})
	}
}

func (h *Hub) checkAccess(c *Client, roomName, password string) *Room {
	room := h.rooms.Get(roomName)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "room_not_exist"})
		return nil
	}
	if room.Password != "" && md5hex(password) != room.Password {
		c.sendJSON(map[string]any{"type": "error", "code": "wrong_password"})
		return nil
	}
	return room
}

func (h *Hub) handleJoin(c *Client, msg *Incoming) {
	room := h.rooms.Get(msg.Room)
	if room == nil {
		log.Printf("[join] rejected room=%s: room_not_exist", msg.Room)
		c.sendJSON(map[string]any{"type": "error", "code": "room_not_exist"})
		return
	}
	if room.Password != "" && md5hex(msg.Password) != room.Password {
		log.Printf("[join] rejected room=%s: wrong_password", msg.Room)
		c.sendJSON(map[string]any{"type": "error", "code": "wrong_password"})
		return
	}
	h.bind(c, msg.Room, msg.TempUser, room.IsHost(msg.TempUser))
	room.upsertMember(msg.TempUser)

	c.sendJSON(map[string]any{
		"type": "joined",
		"room": room.Snapshot(),
		"timestamp": now(),
		"isHost": c.isHost,
	})
	h.broadcast(msg.Room, map[string]any{
		"type": "peer_joined",
		"tempUser": msg.TempUser,
		"memberCount": room.activeMembers(),
	}, c)
	log.Printf("[join] room=%s user=%s host=%v", msg.Room, msg.TempUser, c.isHost)
}

// single-writer: only host may update; a brand-new tempUser takes over host (VT-compatible)
func (h *Hub) handleUpdate(c *Client, msg *Incoming) {
	room := h.rooms.Get(msg.Room)
	if room == nil {
		// first update creates the room
		if msg.TempUser == "" {
			c.sendJSON(map[string]any{"type": "error", "code": "room_not_exist"})
			return
		}
		room = h.rooms.GetOrCreate(msg.Room, msg.Password, msg.TempUser)
	}
	if room.Password != "" && md5hex(msg.Password) != room.Password {
		c.sendJSON(map[string]any{"type": "error", "code": "wrong_password"})
		return
	}
	if !room.IsHost(msg.TempUser) {
		if !h.knownMember(room, msg.TempUser) {
			room.SetHost(msg.TempUser)
			log.Printf("[host] takeover room=%s new=%s", room.Name, msg.TempUser)
		} else {
			c.sendJSON(map[string]any{"type": "error", "code": "other_host_syncing"})
			return
		}
	}
	if msg.Playback == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_playback"})
		return
	}
	// bind connection to room (host may never send "join")
	h.bind(c, room.Name, msg.TempUser, true)
	room.upsertMember(msg.TempUser)

	pb := *msg.Playback
	pb.LastUpdateServerTime = now()
	if pb.LastUpdateClientTime == 0 {
		pb.LastUpdateClientTime = pb.LastUpdateServerTime
	}
	room.Playback = pb
	room.upsertMember(msg.TempUser)

	log.Printf("[update] room=%s user=%s t=%.1f acking", room.Name, msg.TempUser, pb.CurrentTime)
	c.sendJSON(map[string]any{
		"type": "update_ack",
		"room": room.Snapshot(),
		"timestamp": now(),
	})
	h.broadcast(msg.Room, map[string]any{
		"type": "room",
		"room": room.Snapshot(),
		"timestamp": now(),
	}, c)
}

func (h *Hub) knownMember(room *Room, tempUser string) bool {
	room.membersMu.Lock()
	defer room.membersMu.Unlock()
	_, ok := room.members[tempUser]
	return ok
}

func (h *Hub) handleUpdateMember(c *Client, msg *Incoming) {
	room := h.checkAccess(c, msg.Room, msg.Password)
	if room == nil {
		return
	}
	if msg.IsLoading != nil {
		m := room.upsertMember(msg.TempUser)
		m.IsLoading = *msg.IsLoading
		h.broadcast(msg.Room, map[string]any{
			"type": "member_update",
			"tempUser": msg.TempUser,
			"isLoading": *msg.IsLoading,
			"waitForLoadding": room.anyoneLoading(),
			"memberCount": room.activeMembers(),
		}, c)
	}
}

func (h *Hub) handleNavigate(c *Client, msg *Incoming) {
	room := h.checkAccess(c, msg.Room, msg.Password)
	if room == nil {
		return
	}
	if !room.IsHost(msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "host_only"})
		return
	}
	if msg.Target == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_target"})
		return
	}
	room.Playback.Target = msg.Target
	room.Playback.LastUpdateServerTime = now()
	h.broadcast(msg.Room, map[string]any{
		"type": "navigate",
		"from": msg.TempUser,
		"target": msg.Target,
	}, c)
	log.Printf("[navigate] room=%s target=%+v", room.Name, *msg.Target)
}

func (h *Hub) handleWebRTC(c *Client, msg *Incoming) {
	if msg.To == "" {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for peer := range h.clients {
		if peer.roomName == c.roomName && peer.tempUser == msg.To {
			peer.sendJSON(map[string]any{
				"type": "webrtc",
				"from": c.tempUser,
				"payload": msg.Payload,
			})
			return
		}
	}
	c.sendJSON(map[string]any{"type": "error", "code": "peer_not_found", "to": msg.To})
}

func (h *Hub) handleChat(c *Client, msg *Incoming) {
	room := h.checkAccess(c, msg.Room, msg.Password)
	if room == nil {
		return
	}
	h.broadcast(msg.Room, map[string]any{
		"type": "chat",
		"from": msg.TempUser,
		"text": strings.TrimSpace(msg.Text),
		"ts": now(),
	}, nil)
}

func (h *Hub) readPump(c *Client) {
	defer h.disconnect(c)
	c.conn.SetReadLimit(1 << 20)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
		h.handle(c, raw)
	}
}

func (h *Hub) writePump(c *Client) {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()
	for {
		select {
		case b, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, b); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *Hub) disconnect(c *Client) {
	h.mu.Lock()
	delete(h.clients, c)
	close(c.send)
	h.mu.Unlock()

	if c.roomName != "" && c.tempUser != "" {
		if room := h.rooms.Get(c.roomName); room != nil {
			room.removeMember(c.tempUser)
			h.broadcast(c.roomName, map[string]any{
				"type": "peer_left",
				"tempUser": c.tempUser,
				"memberCount": room.activeMembers(),
			}, nil)
		}
	}
	c.conn.Close()
	log.Printf("[leave] room=%s user=%s", c.roomName, c.tempUser)
}

func serveWS(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &Client{conn: conn, send: make(chan []byte, 64), hub: hub}
	hub.mu.Lock()
	hub.clients[c] = true
	hub.mu.Unlock()
	go hub.writePump(c)
	hub.readPump(c)
}

func serveTimestamp(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"timestamp": now(),
	})
}

func serveStats(rooms *RoomStore, hub *Hub, w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"rooms":       rooms.Count(),
		"clients":     len(hub.clients),
		"server_time": now(),
	})
}

func main() {
	rooms := NewRoomStore()
	hub := NewHub(rooms)
	go hub.run()

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) { serveWS(hub, w, r) })
	http.HandleFunc("/timestamp", serveTimestamp)
	http.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) { serveStats(rooms, hub, w, r) })

	addr := ":9901"
	log.Printf("[signaling] listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}

func setupMux(rooms *RoomStore, hub *Hub) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) { serveWS(hub, w, r) })
	mux.HandleFunc("/timestamp", serveTimestamp)
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) { serveStats(rooms, hub, w, r) })
	return mux
}
