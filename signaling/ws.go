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

	maxChatBytes = 500
	maxRooms     = 10000
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
}

func (c *Client) sendJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	select {
	case c.send <- b:
	default:
		c.hub.kick(c)
	}
}

type Hub struct {
	mu      sync.Mutex
	clients map[*Client]bool
	rooms   *RoomStore
}

func NewHub(rooms *RoomStore) *Hub {
	h := &Hub{clients: make(map[*Client]bool), rooms: rooms}
	rooms.onExpire = h.closeRoom
	return h
}

func (h *Hub) clientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

func (h *Hub) roomClients(roomName string) []*Client {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]*Client, 0)
	for c := range h.clients {
		if c.roomName == roomName {
			out = append(out, c)
		}
	}
	return out
}

// closeRoom is invoked by the room store when a room expires.
func (h *Hub) closeRoom(name string) {
	for _, c := range h.roomClients(name) {
		c.sendJSON(map[string]any{"type": "room_closed"})
		h.mu.Lock()
		c.roomName = ""
		h.mu.Unlock()
		h.kick(c)
	}
}

func (h *Hub) kick(c *Client) {
	_ = c.conn.Close()
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
			go h.kick(c)
		}
	}
}

type Incoming struct {
	Type      string          `json:"type"`
	Room      string          `json:"room"`
	Password  string          `json:"password"`
	TempUser  string          `json:"tempUser"`
	To        string          `json:"to,omitempty"`
	Text      string          `json:"text,omitempty"`
	T         float64         `json:"t,omitempty"`
	IsLoading *bool           `json:"isLoading,omitempty"`
	Playback  *PlaybackState  `json:"playback,omitempty"`
	Target    *Target         `json:"target,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
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

// rebindGuard rejects a connection that is already bound to a different room
// (VT-compatible: close the connection to avoid leaking membership state).
func (h *Hub) rebindGuard(c *Client, roomName string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c.roomName != "" && c.roomName != roomName {
		log.Printf("[warn] rebind rejected user=%s %s -> %s", c.tempUser, c.roomName, roomName)
		return false
	}
	return true
}

func (h *Hub) checkRoomAccess(roomName, password string) (*Room, string) {
	if roomName == "" {
		return nil, "bad_request"
	}
	room := h.rooms.Get(roomName)
	if room == nil {
		return nil, "room_not_exist"
	}
	if room.IsProtected() && md5hex(password) != room.Password {
		return nil, "wrong_password"
	}
	return room, ""
}

func (h *Hub) handleJoin(c *Client, msg *Incoming) {
	if msg.Room == "" || msg.TempUser == "" {
		c.sendJSON(map[string]any{"type": "error", "code": "bad_request"})
		return
	}
	if !h.rebindGuard(c, msg.Room) {
		h.kick(c)
		return
	}
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	room.upsertMember(msg.TempUser)
	isHost := room.IsHost(msg.TempUser)

	h.mu.Lock()
	c.roomName = msg.Room
	c.tempUser = msg.TempUser
	h.mu.Unlock()

	c.sendJSON(map[string]any{
		"type":      "joined",
		"room":      room.Snapshot(),
		"timestamp": now(),
		"isHost":    isHost,
	})
	h.broadcast(msg.Room, map[string]any{
		"type":        "peer_joined",
		"tempUser":    msg.TempUser,
		"memberCount": room.activeMembers(),
	}, c)
	log.Printf("[join] room=%s user=%s host=%v", msg.Room, msg.TempUser, isHost)
}

// single-writer: only host may update; a brand-new tempUser takes over host (VT-compatible)
func (h *Hub) handleUpdate(c *Client, msg *Incoming) {
	if msg.Room == "" || msg.TempUser == "" {
		c.sendJSON(map[string]any{"type": "error", "code": "bad_request"})
		return
	}
	if !h.rebindGuard(c, msg.Room) {
		h.kick(c)
		return
	}
	room := h.rooms.Get(msg.Room)
	if room == nil {
		if h.rooms.Count() >= maxRooms {
			c.sendJSON(map[string]any{"type": "error", "code": "room_limit"})
			return
		}
		room = h.rooms.GetOrCreate(msg.Room, msg.Password, msg.TempUser)
	}
	if room.IsProtected() && md5hex(msg.Password) != room.Password {
		c.sendJSON(map[string]any{"type": "error", "code": "wrong_password"})
		return
	}
	if !room.IsHost(msg.TempUser) {
		if !room.knownMember(msg.TempUser) {
			room.mu.Lock()
			room.setHostLocked(msg.TempUser)
			room.mu.Unlock()
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
	pb := *msg.Playback
	pb.LastUpdateServerTime = now()
	if pb.LastUpdateClientTime == 0 {
		pb.LastUpdateClientTime = pb.LastUpdateServerTime
	}
	room.mu.Lock()
	room.updatePlaybackLocked(pb)
	room.upsertMemberLocked(msg.TempUser)
	snap := room.snapshotLocked()
	room.mu.Unlock()

	h.mu.Lock()
	c.roomName = room.Name
	c.tempUser = msg.TempUser
	h.mu.Unlock()

	c.sendJSON(map[string]any{
		"type":      "update_ack",
		"room":      snap,
		"timestamp": now(),
	})
	h.broadcast(msg.Room, map[string]any{
		"type":      "room",
		"room":      snap,
		"timestamp": now(),
	}, c)
}

func (h *Hub) handleUpdateMember(c *Client, msg *Incoming) {
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	h.mu.Lock()
	bound := c.roomName == msg.Room && c.tempUser == msg.TempUser
	h.mu.Unlock()
	if !bound {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	if msg.IsLoading == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_isLoading"})
		return
	}
	room.setLoading(msg.TempUser, *msg.IsLoading)
	h.broadcast(msg.Room, map[string]any{
		"type":            "member_update",
		"tempUser":        msg.TempUser,
		"isLoading":       *msg.IsLoading,
		"waitForLoadding": room.anyoneLoading(),
		"memberCount":     room.activeMembers(),
	}, c)
}

func (h *Hub) handleNavigate(c *Client, msg *Incoming) {
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
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
	room.mu.Lock()
	room.setTargetLocked(msg.Target)
	room.mu.Unlock()
	h.broadcast(msg.Room, map[string]any{
		"type":   "navigate",
		"from":   msg.TempUser,
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
				"type":   "webrtc",
				"from":   c.tempUser,
				"payload": msg.Payload,
			})
			return
		}
	}
	c.sendJSON(map[string]any{"type": "error", "code": "peer_not_found", "to": msg.To})
}

func (h *Hub) handleChat(c *Client, msg *Incoming) {
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	h.mu.Lock()
	bound := c.roomName == msg.Room && c.tempUser == msg.TempUser
	h.mu.Unlock()
	if !bound {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	text := strings.TrimSpace(msg.Text)
	if len(text) > maxChatBytes {
		text = text[:maxChatBytes]
	}
	h.broadcast(msg.Room, map[string]any{
		"type": "chat",
		"from": c.tempUser,
		"text": text,
		"ts":   now(),
	}, nil)
}

func (h *Hub) readPump(c *Client) {
	defer h.disconnect(c)
	c.conn.SetReadLimit(1 << 20)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
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
	_, existed := h.clients[c]
	delete(h.clients, c)
	h.mu.Unlock()
	if !existed {
		return
	}

	if c.roomName != "" && c.tempUser != "" {
		if room := h.rooms.Get(c.roomName); room != nil {
			room.removeMember(c.tempUser)
			h.broadcast(c.roomName, map[string]any{
				"type":        "peer_left",
				"tempUser":    c.tempUser,
				"memberCount": room.activeMembers(),
			}, nil)
		}
	}
	_ = c.conn.Close()
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
		"clients":     hub.clientCount(),
		"server_time": now(),
	})
}

func main() {
	rooms := NewRoomStore(nil)
	hub := NewHub(rooms)

	mux := setupMux(rooms, hub)
	addr := ":9901"
	log.Printf("[signaling] listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func setupMux(rooms *RoomStore, hub *Hub) *http.ServeMux {
	go hub.run()
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) { serveWS(hub, w, r) })
	mux.HandleFunc("/timestamp", serveTimestamp)
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) { serveStats(rooms, hub, w, r) })
	return mux
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
