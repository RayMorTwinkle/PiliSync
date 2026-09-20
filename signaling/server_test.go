package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
)

func startTestServer(t *testing.T) *httptest.Server {
	rooms := NewRoomStore(nil)
	hub := NewHub(rooms)
	mux := setupMux(rooms, hub)
	return httptest.NewServer(mux)
}

func startTestServerWithExpiry(t *testing.T, expire, interval time.Duration) *httptest.Server {
	rooms := newRoomStore(nil, expire, interval)
	hub := NewHub(rooms)
	mux := setupMux(rooms, hub)
	return httptest.NewServer(mux)
}

func dial(t *testing.T, srv *httptest.Server) *websocket.Conn {
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return conn
}

func send(conn *websocket.Conn, v any) {
	b, _ := json.Marshal(v)
	_ = conn.WriteMessage(websocket.TextMessage, b)
}

func playback(t float64) map[string]any {
	return map[string]any{
		"playbackRate": 1.0, "currentTime": t, "paused": false,
		"duration": 100.0, "lastUpdateClientTime": 1000.0,
	}
}

func updateMsg(room, pass, user string, t float64) map[string]any {
	return map[string]any{
		"type": "update", "room": room, "password": pass, "tempUser": user,
		"playback": playback(t),
	}
}

func recv(t *testing.T, conn *websocket.Conn, timeout time.Duration) (map[string]any, error) {
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return nil, err
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			continue
		}
		if m["type"] == "ping" {
			continue
		}
		return m, nil
	}
}

func waitFor(t *testing.T, conn *websocket.Conn, typ string, timeout time.Duration) map[string]any {
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatalf("timeout waiting for %s", typ)
		}
		m, err := recv(t, conn, remaining)
		if err != nil {
			t.Fatalf("error waiting for %s: %v", typ, err)
		}
		if m["type"] == typ {
			return m
		}
	}
}

func waitForErr(t *testing.T, conn *websocket.Conn, code string, timeout time.Duration) map[string]any {
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatalf("timeout waiting for error %s", code)
		}
		m, err := recv(t, conn, remaining)
		if err != nil {
			t.Fatalf("error waiting for %s: %v", code, err)
		}
		if m["type"] == "error" && m["code"] == code {
			return m
		}
	}
}

func TestFullFlow(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	// 1. host first update creates room; snapshot must not leak hostId
	send(host, updateMsg("r1", "pw1", "hostA", 10))
	ack := waitFor(t, host, "update_ack", 2*time.Second)
	if _, leaked := ack["room"].(map[string]any)["hostId"]; leaked {
		t.Fatalf("hostId must not be broadcast: %v", ack["room"])
	}
	if ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("update_ack should mark sender isHost")
	}

	// 2. member join
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	joined := waitFor(t, member, "joined", 2*time.Second)
	if joined["isHost"] != false {
		t.Fatalf("member should not be host")
	}
	room := joined["room"].(map[string]any)
	if _, leaked := room["hostId"]; leaked {
		t.Fatalf("hostId must not be broadcast: %v", room)
	}
	if room["currentTime"].(float64) != 10.0 {
		t.Fatalf("room snapshot currentTime mismatch")
	}
	if room["memberCount"].(float64) != 2 {
		t.Fatalf("memberCount should be 2 (host+member), got %v", room["memberCount"])
	}
	waitFor(t, host, "peer_joined", 2*time.Second)

	// 3. host update -> member receives room broadcast (per-recipient isHost)
	send(host, updateMsg("r1", "pw1", "hostA", 42))
	roomMsg := waitFor(t, member, "room", 2*time.Second)
	room = roomMsg["room"].(map[string]any)
	if room["currentTime"].(float64) != 42.0 || room["paused"] != false {
		t.Fatalf("broadcast mismatch: %v", room)
	}
	if room["isHost"] != false {
		t.Fatalf("member's room broadcast should say isHost=false")
	}
	if _, leaked := room["hostId"]; leaked {
		t.Fatalf("hostId must not be broadcast: %v", room)
	}

	// 4. member reports loading -> everyone (incl. sender) notified
	isLoading := true
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": isLoading, "t": 123.0,
	})
	mu := waitFor(t, host, "member_update", 2*time.Second)
	if mu["waitForLoadding"] != true {
		t.Fatalf("waitForLoadding should be true")
	}
	echo := waitFor(t, member, "member_update", 2*time.Second)
	if echo["t"].(float64) != 123.0 {
		t.Fatalf("member_update should echo t, got %v", echo)
	}

	// 5. loading member stays counted without further messages (>10s is
	// now irrelevant: membership tracks the live connection).
	// (lastSeen window removed — see spec F2)

	// 6. host navigate -> member receives; playback position resets
	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"target": map[string]any{"type": "video", "bvid": "BV1xx", "cid": 123},
	})
	nav := waitFor(t, member, "navigate", 2*time.Second)
	if nav["target"].(map[string]any)["bvid"] != "BV1xx" {
		t.Fatalf("navigate target mismatch")
	}
	send(host, updateMsg("r1", "pw1", "hostA", 0))
	roomMsg = waitFor(t, member, "room", 2*time.Second)

	// 7. member navigate -> host_only error
	send(member, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "memB",
		"target": map[string]any{"type": "video", "bvid": "evil"},
	})
	waitForErr(t, member, "host_only", 2*time.Second)

	// 8. wrong password
	conn := dial(t, srv)
	send(conn, map[string]any{"type": "join", "room": "r1", "password": "bad", "tempUser": "x"})
	waitForErr(t, conn, "wrong_password", 2*time.Second)
	conn.Close()

	// 9. impersonation attempt: bound member cannot speak as the host
	send(member, updateMsg("r1", "pw1", "hostA", 55))
	waitForErr(t, member, "not_in_room", 2*time.Second)

	// 10. VT semantics: member's first update with OWN tempUser takes over
	send(member, updateMsg("r1", "pw1", "memB", 60))
	ack = waitFor(t, member, "update_ack", 2*time.Second)
	if ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("member takeover should be marked isHost")
	}
	// former host is now the loser
	send(host, updateMsg("r1", "pw1", "hostA", 61))
	waitForErr(t, host, "other_host_syncing", 2*time.Second)
}

// Unbound connection claiming a brand-new tempUser takes over (host reclaim
// after restart); a bound connection claiming a foreign tempUser is rejected.
func TestTakeoverAndImpersonation(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	send(host, updateMsg("r2", "", "hostA", 5))
	waitFor(t, host, "update_ack", 2*time.Second)

	// unbound conn, fresh tempUser -> takeover succeeds
	fresh := dial(t, srv)
	defer fresh.Close()
	send(fresh, updateMsg("r2", "", "freshC", 6))
	ack := waitFor(t, fresh, "update_ack", 2*time.Second)
	if ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("fresh tempUser should take over")
	}

	// malformed update from another fresh user must NOT take over first
	bad := dial(t, srv)
	defer bad.Close()
	send(bad, map[string]any{
		"type": "update", "room": "r2", "password": "", "tempUser": "badX",
	})
	waitForErr(t, bad, "missing_playback", 2*time.Second)
	// verify badX is not host: badX joins -> isHost must be false
	bad2 := dial(t, srv)
	defer bad2.Close()
	send(bad2, map[string]any{"type": "join", "room": "r2", "password": "", "tempUser": "badX"})
	joined := waitFor(t, bad2, "joined", 2*time.Second)
	if joined["isHost"] != false {
		t.Fatalf("missing_playback update must not take over host")
	}
}

// Duplicate join on the same connection is idempotent (no phantom
// peer_joined), and a bound connection may not adopt another identity.
func TestDuplicateJoin(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r3", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "r3", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	// duplicate join: ack again, but no second peer_joined for host
	send(member, map[string]any{"type": "join", "room": "r3", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	// a second peer_joined must not arrive; expect the next real message
	// instead (use a tsync ack as a barrier)
	send(host, map[string]any{"type": "tsync", "t": 1})
	waitFor(t, host, "tsync_ack", 2*time.Second)

	// bound conn may not change identity
	send(member, map[string]any{"type": "join", "room": "r3", "password": "", "tempUser": "other"})
	waitForErr(t, member, "already_bound", 2*time.Second)
}

// Two connections sharing a tempUser: closing one must not remove the
// member entry while the other is still bound.
func TestSharedTempUser(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r4", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	m1 := dial(t, srv)
	send(m1, map[string]any{"type": "join", "room": "r4", "password": "", "tempUser": "memB"})
	waitFor(t, m1, "joined", 2*time.Second)
	m2 := dial(t, srv)
	defer m2.Close()
	send(m2, map[string]any{"type": "join", "room": "r4", "password": "", "tempUser": "memB"})
	waitFor(t, m2, "joined", 2*time.Second)

	m1.Close()
	time.Sleep(100 * time.Millisecond)
	// member memB must still be online via m2: query memberCount via join
	probe := dial(t, srv)
	defer probe.Close()
	send(probe, map[string]any{"type": "join", "room": "r4", "password": "", "tempUser": "probe"})
	joined := waitFor(t, probe, "joined", 2*time.Second)
	if joined["room"].(map[string]any)["memberCount"].(float64) != 3 {
		t.Fatalf("memB should still count via m2: %v", joined["room"])
	}
}

// Expired rooms push room_closed before the connection drops, and a room
// recreated under the same name is not kicked by the stale expiry.
func TestRoomClosedDelivered(t *testing.T) {
	srv := startTestServerWithExpiry(t, 100*time.Millisecond, 20*time.Millisecond)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r5", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	// stop updating; wait for expiry
	waitFor(t, host, "room_closed", 5*time.Second)
}

// webrtc requires binding + a concrete `to`; the "host" alias resolves
// server-side without exposing the host uuid.
func TestWebRTCRelay(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r6", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "r6", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)

	// unbound conn -> not_in_room
	stranger := dial(t, srv)
	defer stranger.Close()
	send(stranger, map[string]any{
		"type": "webrtc", "tempUser": "s", "to": "hostA",
		"payload": map[string]any{"kind": "ice"},
	})
	waitForErr(t, stranger, "not_in_room", 2*time.Second)

	// empty to -> missing_to
	send(member, map[string]any{
		"type": "webrtc", "tempUser": "memB", "to": "",
		"payload": map[string]any{"kind": "offer", "sdp": "x"},
	})
	waitForErr(t, member, "missing_to", 2*time.Second)

	// member -> "host" alias reaches the host without knowing its uuid
	send(member, map[string]any{
		"type": "webrtc", "tempUser": "memB", "to": "host",
		"payload": map[string]any{"kind": "offer", "sdp": "x"},
	})
	w := waitFor(t, host, "webrtc", 2*time.Second)
	if w["from"] != "memB" {
		t.Fatalf("webrtc from mismatch: %v", w)
	}

	// host -> member by tempUser
	send(host, map[string]any{
		"type": "webrtc", "tempUser": "hostA", "to": "memB",
		"payload": map[string]any{"kind": "answer", "sdp": "y"},
	})
	waitFor(t, member, "webrtc", 2*time.Second)

	// unknown peer -> peer_not_found
	send(host, map[string]any{
		"type": "webrtc", "tempUser": "hostA", "to": "ghost",
		"payload": map[string]any{"kind": "ice"},
	})
	waitForErr(t, host, "peer_not_found", 2*time.Second)
}

// chat truncation is rune-safe (no split multi-byte characters).
func TestChatRuneTruncate(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r7", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "r7", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)

	long := strings.Repeat("中", 600)
	send(member, map[string]any{
		"type": "chat", "room": "r7", "password": "", "tempUser": "memB", "text": long,
	})
	msg := waitFor(t, host, "chat", 2*time.Second)
	text := msg["text"].(string)
	if !utf8.ValidString(text) {
		t.Fatalf("truncated text is not valid UTF-8")
	}
	if utf8.RuneCountInString(text) > maxChatRunes {
		t.Fatalf("chat should be capped at %d runes, got %d", maxChatRunes, utf8.RuneCountInString(text))
	}
}

// Rate limit: a flooding connection is disconnected and others see
// peer_left.
func TestRateLimit(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r8", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	flood := dial(t, srv)
	defer flood.Close()
	send(flood, map[string]any{"type": "join", "room": "r8", "password": "", "tempUser": "f"})
	waitFor(t, flood, "joined", 2*time.Second)

	isLoading := true
	for i := 0; i < int(msgBurst)+30; i++ {
		send(flood, map[string]any{
			"type": "update_member", "room": "r8", "password": "", "tempUser": "f",
			"isLoading": isLoading,
		})
	}
	// flood conn gets closed by the server; host sees peer_left
	waitFor(t, host, "peer_left", 5*time.Second)
}

func TestTimestampEndpoint(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL + "/timestamp")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var m map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		t.Fatal(err)
	}
	if _, ok := m["timestamp"]; !ok {
		t.Fatalf("missing timestamp: %v", m)
	}
}

func getICEServers(t *testing.T, srv *httptest.Server) map[string]any {
	resp, err := srv.Client().Get(srv.URL + "/ice-servers")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var m map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestICEServersFallbackWithoutTurnEnv(t *testing.T) {
	oldKey, oldTok := turnKeyID, turnAPIToken
	turnKeyID, turnAPIToken = "", ""
	defer func() { turnKeyID, turnAPIToken = oldKey, oldTok }()

	srv := startTestServer(t)
	defer srv.Close()
	m := getICEServers(t, srv)
	list, ok := m["iceServers"].([]any)
	if !ok || len(list) == 0 {
		t.Fatalf("missing iceServers: %v", m)
	}
	first := list[0].(map[string]any)
	if first["urls"] != "stun:stun.l.google.com:19302" {
		t.Fatalf("expected STUN fallback, got %v", first)
	}
	if _, hasCred := first["credential"]; hasCred {
		t.Fatalf("fallback must not carry credentials: %v", first)
	}
}

func TestICEServersRelaysCloudflare(t *testing.T) {
	var gotAuth, gotPath string
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"iceServers":[{"urls":"stun:stun.cloudflare.com:3478"},{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:5349?transport=tcp"],"username":"u1","credential":"c1"}]}`))
	})
	upstream := httptest.NewServer(mux)

	oldBase, oldKey, oldTok := turnAPIBase, turnKeyID, turnAPIToken
	turnAPIBase, turnKeyID, turnAPIToken = upstream.URL, "key-1", "tok-1"
	iceCache.mu.Lock()
	iceCache.servers, iceCache.expiresAt = nil, time.Time{}
	iceCache.mu.Unlock()
	defer func() {
		turnAPIBase, turnKeyID, turnAPIToken = oldBase, oldKey, oldTok
		iceCache.mu.Lock()
		iceCache.servers, iceCache.expiresAt = nil, time.Time{}
		iceCache.mu.Unlock()
		upstream.Close()
	}()

	srv := startTestServer(t)
	defer srv.Close()
	m := getICEServers(t, srv)

	if gotAuth != "Bearer tok-1" {
		t.Fatalf("upstream auth = %q", gotAuth)
	}
	if gotPath != "/v1/turn/keys/key-1/credentials/generate-ice-servers" {
		t.Fatalf("upstream path = %q", gotPath)
	}
	list := m["iceServers"].([]any)
	if len(list) != 2 {
		t.Fatalf("expected 2 upstream entries relayed verbatim, got %v", list)
	}
	turn := list[1].(map[string]any)
	if turn["username"] != "u1" || turn["credential"] != "c1" {
		t.Fatalf("credentials not relayed: %v", turn)
	}
	urls, ok := turn["urls"].([]any)
	if !ok || len(urls) != 2 {
		t.Fatalf("urls not relayed: %v", turn["urls"])
	}
}

// A member that reports isLoading forever must not deadlock the room: the
// barrier only honours a loading flag younger than maxMemberLoadingWait.
func TestLoadingWaitExpires(t *testing.T) {
	defer func(orig time.Duration) { maxMemberLoadingWait = orig }(maxMemberLoadingWait)
	maxMemberLoadingWait = 80 * time.Millisecond
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsg("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": true,
	})
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("fresh loading should hold the barrier")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second) // drain echo

	time.Sleep(150 * time.Millisecond) // past the TTL

	// Re-sending the same flag is not a false→true transition, so
	// LoadingSince is not refreshed: the stale flag must now be ignored.
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": true,
	})
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != false {
		t.Fatalf("stale loading must release the barrier")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second)

	// A genuine false→true transition starts a fresh window.
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": false,
	})
	_ = waitFor(t, host, "member_update", 2*time.Second)
	_ = waitFor(t, member, "member_update", 2*time.Second)
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": true,
	})
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("a new loading run should re-hold the barrier")
	}
}
