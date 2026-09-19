package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = 54 * time.Second

	maxChatRunes = 500
	maxRooms     = 10000
	maxClients   = 5000
	maxPerIP     = 50

	// inbound rate limit per connection (token bucket)
	msgRate  = 10.0 // messages per second
	msgBurst = 25.0
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// Client is one WebSocket connection. roomName/tempUser/room are guarded by
// Hub.mu; tokens/lastMsg are only touched by the connection's readPump.
type Client struct {
	conn     *websocket.Conn
	send     chan []byte
	done     chan struct{}
	closed   atomic.Bool
	hub      *Hub
	ip       string
	roomName string
	tempUser string
	room     *Room
	tokens   float64
	lastMsg  time.Time
}

// sendJSON enqueues a message; a full buffer marks the client for a
// graceful drain-close instead of an abrupt conn.Close (so queued frames
// like room_closed still get written).
func (c *Client) sendJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	if c.closed.Load() {
		return
	}
	select {
	case c.send <- b:
	default:
		c.kick()
	}
}

// kick schedules a drain-and-close: writePump flushes pending frames,
// writes a CloseMessage and returns, which closes the conn.
func (c *Client) kick() {
	if c.closed.CompareAndSwap(false, true) {
		close(c.done)
	}
}

// allowMsg is a token bucket evaluated only in readPump (single goroutine).
func (c *Client) allowMsg() bool {
	t := time.Now()
	c.tokens += t.Sub(c.lastMsg).Seconds() * msgRate
	c.lastMsg = t
	if c.tokens > msgBurst {
		c.tokens = msgBurst
	}
	if c.tokens < 1 {
		return false
	}
	c.tokens--
	return true
}

type Hub struct {
	mu          sync.Mutex
	clients     map[*Client]bool
	clientsByIP map[string]int
	rooms       *RoomStore
}

func NewHub(rooms *RoomStore) *Hub {
	h := &Hub{
		clients:     make(map[*Client]bool),
		clientsByIP: make(map[string]int),
		rooms:       rooms,
	}
	rooms.onExpire = h.closeRoom
	return h
}

func (h *Hub) clientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// binding returns the connection's bound identity under h.mu.
func (h *Hub) binding(c *Client) (roomName, tempUser string, room *Room) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return c.roomName, c.tempUser, c.room
}

// closeRoom is invoked by the room store when a room expires. It only kicks
// connections still bound to that exact Room instance, so a room recreated
// under the same name is not affected.
func (h *Hub) closeRoom(room *Room) {
	h.mu.Lock()
	targets := make([]*Client, 0)
	for c := range h.clients {
		if c.room == room {
			c.roomName = ""
			c.tempUser = ""
			c.room = nil
			targets = append(targets, c)
		}
	}
	h.mu.Unlock()
	for _, c := range targets {
		c.sendJSON(map[string]any{"type": "room_closed"})
		c.kick() // drains the queue, then closes
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
			go c.kick()
		}
	}
}

// broadcastRoom sends a room snapshot to every bound connection except
// skip, injecting a per-recipient "isHost" flag (HostId is never sent).
func (h *Hub) broadcastRoom(room *Room, skip *Client) {
	base := room.Snapshot()
	h.mu.Lock()
	type target struct {
		c    *Client
		user string
	}
	targets := make([]target, 0, 4)
	for c := range h.clients {
		if c.room == room && c != skip {
			targets = append(targets, target{c: c, user: c.tempUser})
		}
	}
	h.mu.Unlock()
	for _, t := range targets {
		snap := make(map[string]any, len(base)+1)
		for k, v := range base {
			snap[k] = v
		}
		snap["isHost"] = room.IsHost(t.user)
		t.c.sendJSON(map[string]any{
			"type":      "room",
			"room":      snap,
			"timestamp": now(),
		})
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

// rebindGuard rejects a connection that is already bound to a different
// room (VT-compatible: close the connection to avoid leaking membership
// state).
func (h *Hub) rebindGuard(c *Client, roomName string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c.roomName != "" && c.roomName != roomName {
		log.Printf("[warn] rebind rejected user=%s %s -> %s", c.tempUser, c.roomName, roomName)
		return false
	}
	return true
}

// boundAs reports whether the connection is bound and the message claims
// the same identity. Bound connections may only speak as themselves, so a
// member cannot declare a foreign tempUser.
func (h *Hub) boundAs(c *Client, roomName, tempUser string) bool {
	room, user, _ := h.binding(c)
	if room == "" {
		return false // unbound: identity is asserted by tempUser alone
	}
	return room == roomName && user == tempUser
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
		c.kick()
		return
	}
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	roomName, tempUser, _ := h.binding(c)
	if roomName == msg.Room {
		if tempUser != msg.TempUser {
			// a bound connection may not adopt a different identity
			c.sendJSON(map[string]any{"type": "error", "code": "already_bound"})
			return
		}
		// duplicate join for the same identity: idempotent, just re-ack
		isHost := room.IsHost(msg.TempUser)
		snap := room.Snapshot()
		snap["isHost"] = isHost
		c.sendJSON(map[string]any{
			"type":      "joined",
			"room":      snap,
			"timestamp": now(),
			"isHost":    isHost,
		})
		return
	}
	room.upsertMember(msg.TempUser)
	isHost := room.IsHost(msg.TempUser)

	h.mu.Lock()
	c.roomName = msg.Room
	c.tempUser = msg.TempUser
	c.room = room
	h.mu.Unlock()

	snap := room.Snapshot()
	snap["isHost"] = isHost
	c.sendJSON(map[string]any{
		"type":      "joined",
		"room":      snap,
		"timestamp": now(),
		"isHost":    isHost,
	})
	h.broadcast(msg.Room, map[string]any{
		"type":        "peer_joined",
		"tempUser":    msg.TempUser,
		"memberCount": room.memberCount(),
	}, c)
	log.Printf("[join] room=%s user=%s host=%v", msg.Room, msg.TempUser, isHost)
}

// single-writer: only the host may update. A tempUser that has never sent
// update takes over the host (VT userIds semantics); a previously-seen
// non-host gets other_host_syncing. The playback payload is validated
// before any takeover so a malformed update cannot seize a room.
func (h *Hub) handleUpdate(c *Client, msg *Incoming) {
	if msg.Room == "" || msg.TempUser == "" {
		c.sendJSON(map[string]any{"type": "error", "code": "bad_request"})
		return
	}
	if !h.rebindGuard(c, msg.Room) {
		c.kick()
		return
	}
	roomName, _, _ := h.binding(c)
	if roomName != "" && !h.boundAs(c, msg.Room, msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	if msg.Playback == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_playback"})
		return
	}
	room := h.rooms.Get(msg.Room)
	if room == nil {
		room = h.rooms.GetOrCreate(msg.Room, msg.Password, msg.TempUser)
		if room == nil {
			c.sendJSON(map[string]any{"type": "error", "code": "room_limit"})
			return
		}
	}
	if room.IsProtected() && md5hex(msg.Password) != room.Password {
		c.sendJSON(map[string]any{"type": "error", "code": "wrong_password"})
		return
	}
	isNew := room.markSeen(msg.TempUser)
	if !room.IsHost(msg.TempUser) {
		if isNew {
			room.mu.Lock()
			room.setHostLocked(msg.TempUser)
			room.mu.Unlock()
			log.Printf("[host] takeover room=%s new=%s", room.Name, msg.TempUser)
		} else {
			c.sendJSON(map[string]any{"type": "error", "code": "other_host_syncing"})
			return
		}
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
	c.room = room
	h.mu.Unlock()

	ack := make(map[string]any, len(snap)+2)
	for k, v := range snap {
		ack[k] = v
	}
	ack["isHost"] = room.IsHost(msg.TempUser)
	c.sendJSON(map[string]any{
		"type":      "update_ack",
		"room":      ack,
		"timestamp": now(),
		"t":         msg.T,
	})
	h.broadcastRoom(room, c)
}

func (h *Hub) handleUpdateMember(c *Client, msg *Incoming) {
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	if !h.boundAs(c, msg.Room, msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	if msg.IsLoading == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_isLoading"})
		return
	}
	if !room.setLoading(msg.TempUser, *msg.IsLoading, msg.Target) {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	// broadcast to everyone including the sender (VT-style): the echo
	// doubles as the sender's ack and carries its `t` for time sampling.
	h.broadcast(msg.Room, map[string]any{
		"type":            "member_update",
		"tempUser":        msg.TempUser,
		"isLoading":       *msg.IsLoading,
		"waitForLoadding": room.anyoneLoading(),
		"memberCount":     room.memberCount(),
		"t":               msg.T,
	}, nil)
}

func (h *Hub) handleNavigate(c *Client, msg *Incoming) {
	room, errCode := h.checkRoomAccess(msg.Room, msg.Password)
	if room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": errCode})
		return
	}
	if !h.boundAs(c, msg.Room, msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	if msg.Target == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_target"})
		return
	}
	if !room.IsHost(msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "host_only"})
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
	roomName, from, room := h.binding(c)
	if roomName == "" || room == nil {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	if msg.To == "" {
		c.sendJSON(map[string]any{"type": "error", "code": "missing_to"})
		return
	}
	to := msg.To
	switch to {
	case "host":
		// alias resolved server-side: lets members reach the host without
		// ever learning the host uuid.
		room.mu.Lock()
		to = room.HostId
		room.mu.Unlock()
	case "peer":
		// resolves to the sole other member — only valid in 2-person
		// rooms, which is also the only mode the call UI enables.
		to = ""
		h.mu.Lock()
		for peer := range h.clients {
			if peer.room == room && peer != c {
				if to != "" {
					to = ""
					break // more than one other member: ambiguous
				}
				to = peer.tempUser
			}
		}
		h.mu.Unlock()
		if to == "" {
			c.sendJSON(map[string]any{"type": "error", "code": "peer_ambiguous"})
			return
		}
	}
	payload := map[string]any{
		"type":    "webrtc",
		"from":    from,
		"payload": msg.Payload,
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for peer := range h.clients {
		if peer.room == room && peer.tempUser == to {
			peer.sendJSON(payload)
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
	if !h.boundAs(c, msg.Room, msg.TempUser) {
		c.sendJSON(map[string]any{"type": "error", "code": "not_in_room"})
		return
	}
	text := strings.TrimSpace(msg.Text)
	if utf8.RuneCountInString(text) > maxChatRunes {
		text = string([]rune(text)[:maxChatRunes])
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
		if !c.allowMsg() {
			log.Printf("[ratelimit] disconnecting %s", c.ip)
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
	write := func(b []byte, mt int) bool {
		_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
		return c.conn.WriteMessage(mt, b) == nil
	}
	for {
		select {
		case b := <-c.send:
			if !write(b, websocket.TextMessage) {
				return
			}
		case <-ticker.C:
			if !write(nil, websocket.PingMessage) {
				return
			}
		case <-c.done:
			// drain everything still queued, then close gracefully
			for {
				select {
				case b := <-c.send:
					if !write(b, websocket.TextMessage) {
						return
					}
				default:
					_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
					_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
					return
				}
			}
		}
	}
}

func (h *Hub) disconnect(c *Client) {
	h.mu.Lock()
	_, existed := h.clients[c]
	delete(h.clients, c)
	if c.ip != "" {
		h.clientsByIP[c.ip]--
		if h.clientsByIP[c.ip] <= 0 {
			delete(h.clientsByIP, c.ip)
		}
	}
	roomName, tempUser, room := c.roomName, c.tempUser, c.room
	stillBound := false
	if room != nil && tempUser != "" {
		for o := range h.clients {
			if o.room == room && o.tempUser == tempUser {
				stillBound = true
				break
			}
		}
	}
	h.mu.Unlock()
	if !existed {
		return
	}

	if room != nil && tempUser != "" && !stillBound {
		room.removeMember(tempUser)
		h.broadcast(roomName, map[string]any{
			"type":        "peer_left",
			"tempUser":    tempUser,
			"memberCount": room.memberCount(),
		}, nil)
	}
	_ = c.conn.Close()
	log.Printf("[leave] room=%s user=%s", roomName, tempUser)
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.Index(xff, ","); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func serveWS(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	ip := clientIP(r)
	c := &Client{
		conn:    conn,
		send:    make(chan []byte, 64),
		done:    make(chan struct{}),
		hub:     hub,
		ip:      ip,
		tokens:  msgBurst,
		lastMsg: time.Now(),
	}
	hub.mu.Lock()
	if len(hub.clients) >= maxClients || hub.clientsByIP[ip] >= maxPerIP {
		hub.mu.Unlock()
		_ = conn.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseTryAgainLater, "limit"))
		_ = conn.Close()
		return
	}
	hub.clients[c] = true
	hub.clientsByIP[ip]++
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
	mux.HandleFunc("/ice-servers", serveICEServers)
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
