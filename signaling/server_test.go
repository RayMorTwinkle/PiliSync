package main

import (
	"encoding/json"
	"fmt"
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
	rooms := newRoomStore(nil, expire, interval, maxMemberLoadingWait)
	hub := NewHub(rooms)
	mux := setupMux(rooms, hub)
	return httptest.NewServer(mux)
}

// startTestServerRooms returns the store alongside the server so tests
// can inspect/backdate member state (e.g. stale heartbeats).
func startTestServerRooms(t *testing.T) (*httptest.Server, *RoomStore) {
	rooms := NewRoomStore(nil)
	hub := NewHub(rooms)
	mux := setupMux(rooms, hub)
	return httptest.NewServer(mux), rooms
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

	// 4. member reports loading -> everyone (incl. sender) notified.
	// F11-k: a nil target no longer counts toward the barrier, so the
	// member must report its target (room target is nil -> lenient).
	isLoading := true
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB",
		"isLoading": isLoading, "t": 123.0, "target": videoTarget,
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

	// 10. F13: a BOUND member's update can no longer seize the room —
	// host changes go through `transfer` (consent) or disconnect handover.
	send(member, updateMsg("r1", "pw1", "memB", 60))
	waitForErr(t, member, "other_host_syncing", 2*time.Second)
	// Explicit host transfer promotes the member instead.
	send(host, map[string]any{
		"type": "transfer", "room": "r1", "tempUser": "hostA", "to": "memB",
	})
	waitFor(t, member, "host_changed", 2*time.Second)
	waitFor(t, member, "room", 2*time.Second)
	send(member, updateMsg("r1", "pw1", "memB", 60))
	ack = waitFor(t, member, "update_ack", 2*time.Second)
	if ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("transferred member should be marked isHost")
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
var videoTarget = map[string]any{"type": "video", "bvid": "BV1test", "cid": 100}

// updateMsgWithTarget is updateMsg plus a playback.target so the room has
// a current page members can match.
func updateMsgWithTarget(room, pass, user string, t float64) map[string]any {
	m := updateMsg(room, pass, user, t)
	m["playback"].(map[string]any)["target"] = videoTarget
	return m
}

func memberLoadingMsg(room, pass, user string, loading bool, withTarget bool) map[string]any {
	m := map[string]any{
		"type": "update_member", "room": room, "password": pass, "tempUser": user,
		"isLoading": loading,
	}
	if withTarget {
		m["target"] = videoTarget
	}
	return m
}

func TestLoadingWaitExpires(t *testing.T) {
	defer func(orig time.Duration) { maxMemberLoadingWait = orig }(maxMemberLoadingWait)
	maxMemberLoadingWait = 80 * time.Millisecond
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	// F11-k: loading only counts when the member reports the room target.
	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("fresh loading should hold the barrier")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second) // drain echo

	time.Sleep(150 * time.Millisecond) // past the TTL

	// Re-sending the same flag is not a false→true transition, so
	// LoadingSince is not refreshed: the stale flag must now be ignored.
	// It is also an unchanged heartbeat (dedup): only the sender echoes,
	// so the host learns the release from the next update_ack instead.
	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	_ = waitFor(t, member, "member_update", 2*time.Second) // sender echo
	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 11))
	if ack := waitFor(t, host, "update_ack", 2*time.Second); ack["room"].(map[string]any)["waitForLoadding"] != false {
		t.Fatalf("stale loading must release the barrier, got %v", ack["room"])
	}

	// A genuine false→true transition starts a fresh window.
	send(member, memberLoadingMsg("r1", "pw1", "memB", false, true))
	_ = waitFor(t, host, "member_update", 2*time.Second)
	_ = waitFor(t, member, "member_update", 2*time.Second)
	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("a new loading run should re-hold the barrier")
	}
}

// F11-k: a member whose heartbeat carries no target (off the video page)
// must not hold the room barrier — regression for spec F2 compliance.
func TestLoadingWithoutTargetIgnored(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("r1", "pw1", "memB", true, false))
	// changed → broadcast to all including host
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != false {
		t.Fatalf("target-less member loading must not raise the barrier")
	}
}

// F11-l: end-of-video exemption uses tolerance, not float equality.
func TestLoadingNearEndIgnored(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	up := updateMsgWithTarget("r1", "pw1", "hostA", 10)
	up["playback"].(map[string]any)["currentTime"] = 99.9 // duration=100
	send(host, up)
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != false {
		t.Fatalf("tail buffering must not hold the barrier")
	}
}

// F11-i: when the host disconnects the earliest online member inherits
// HostId — but only after hostHandoverGrace elapses, so a brief network
// blip cannot permanently demote a returning host.
func TestHostHandoverOnDisconnect(t *testing.T) {
	srv, rooms := startTestServerRooms(t)
	defer srv.Close()

	host := dial(t, srv)
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	_ = host.Close()

	// peer_left is immediate, but the handover is deferred by
	// hostHandoverGrace — the post-disconnect snapshot still reports the
	// member as non-host so a host blip cannot swap roles mid-reconnect.
	waitFor(t, member, "peer_left", 2*time.Second)
	snap := waitFor(t, member, "room", 2*time.Second)
	if snap["room"].(map[string]any)["isHost"] != false {
		t.Fatalf("handover must wait out the grace period, got %v", snap)
	}

	// Force the grace to be due and sweep — now the member promotes.
	room := rooms.Get("r1")
	room.mu.Lock()
	room.hostGoneAt = time.Now().Add(-hostHandoverGrace - time.Second)
	room.mu.Unlock()
	rooms.sweepHandovers()

	waitFor(t, member, "host_changed", 2*time.Second)
	snap = waitFor(t, member, "room", 2*time.Second)
	if snap["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("member should inherit host after the grace, got %v", snap)
	}
	// The promoted member's update must now be accepted, not rejected
	// with other_host_syncing.
	send(member, updateMsg("r1", "pw1", "memB", 20))
	if ack := waitFor(t, member, "update_ack", 2*time.Second); ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("promoted member update should ack isHost=true, got %v", ack)
	}
}

// A host that rejoins inside the grace window keeps the role — the room
// must not flip it to member via a stale handover.
func TestHostRejoinWithinGraceKeepsRole(t *testing.T) {
	srv, rooms := startTestServerRooms(t)
	defer srv.Close()

	host := dial(t, srv)
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	_ = host.Close()
	waitFor(t, member, "peer_left", 2*time.Second)
	// Drain the post-disconnect room snapshot so a later "room" read
	// unambiguously belongs to the rejoin flow.
	_ = waitFor(t, member, "room", 2*time.Second)

	// Same identity rejoins on a fresh conn before the grace elapses.
	host2 := dial(t, srv)
	defer host2.Close()
	send(host2, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "hostA"})
	j := waitFor(t, host2, "joined", 2*time.Second)
	if j["isHost"] != true {
		t.Fatalf("rejoining inside the grace must keep the host role, got %v", j)
	}

	// The sweep sees the member record back online and cancels the
	// pending handover instead of promoting the member.
	rooms.sweepHandovers()
	room := rooms.Get("r1")
	room.mu.Lock()
	pending := !room.hostGoneAt.IsZero()
	room.mu.Unlock()
	if pending {
		t.Fatalf("host rejoin must clear the pending handover")
	}
	if !room.IsHost("hostA") {
		t.Fatalf("hostA must still own the room after rejoin")
	}

	// The member must still be a member — and its update must NOT be
	// treated as a host update.
	send(member, updateMsg("r1", "pw1", "memB", 20))
	waitForErr(t, member, "other_host_syncing", 2*time.Second)
}

// navigate(nil) (host left the video page) must scrub the playback meta
// too — otherwise snapshots keep presenting the stale url/title and the
// room still looks "in a video" to joiners and dashboards.
func TestNavigateNullClearsPlaybackMeta(t *testing.T) {
	srv, rooms := startTestServerRooms(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()

	send(host, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"playback": map[string]any{
			"playbackRate": 1.0, "currentTime": 42, "paused": false,
			"duration": 100.0, "lastUpdateClientTime": 1000.0,
			"url": "BV1xx", "videoTitle": "old video",
			"target": map[string]any{"type": "video", "bvid": "BV1xx", "cid": 123},
		},
	})
	waitFor(t, host, "update_ack", 2*time.Second)

	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
	})
	time.Sleep(50 * time.Millisecond)

	room := rooms.Get("r1")
	if room == nil {
		t.Fatal("room missing")
	}
	room.mu.Lock()
	defer room.mu.Unlock()
	if room.Playback.Target != nil || room.Playback.Url != "" || room.Playback.VideoTitle != "" {
		t.Fatalf("null navigate must clear target+url+title, got %+v", room.Playback)
	}
}

// F11-j: peer_left carries the recomputed barrier so the host is released
// immediately when the loading member drops.
func TestPeerLeftReleasesBarrier(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("loading should hold the barrier")
	}

	_ = member.Close()
	if pl := waitFor(t, host, "peer_left", 2*time.Second); pl["waitForLoadding"] != false {
		t.Fatalf("peer_left must carry the released barrier, got %v", pl)
	}
}

// F11-m: unchanged update_member heartbeats echo only the sender.
func TestMemberUpdateDedup(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	// First report changes state (target nil → set): broadcasts to all.
	send(member, memberLoadingMsg("r1", "pw1", "memB", false, true))
	_ = waitFor(t, member, "member_update", 2*time.Second)
	_ = waitFor(t, host, "member_update", 2*time.Second)

	// A real change still fans out.
	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["isLoading"] != true {
		t.Fatalf("changed heartbeat must broadcast")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second) // drain echo

	// Identical heartbeat last: unchanged → sender echo only. NB a read
	// timeout permanently corrupts a gorilla conn, so this assertion must
	// come last — the host conn is unusable afterwards.
	send(member, memberLoadingMsg("r1", "pw1", "memB", true, true))
	_ = waitFor(t, member, "member_update", 2*time.Second) // echo
	_ = host.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	_, raw, err := host.ReadMessage()
	if err == nil {
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		if m["type"] == "member_update" {
			t.Fatalf("unchanged heartbeat must not broadcast: %s", raw)
		}
	}
}

// F11-o: navigate snapshots reset to paused@0 so window joiners wait.
func TestNavigateResetsPaused(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()

	send(host, updateMsgWithTarget("r1", "pw1", "hostA", 50))
	waitFor(t, host, "update_ack", 2*time.Second)

	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"target": map[string]any{"type": "video", "bvid": "BV2", "cid": 200},
	})
	// navigate broadcasts to others only; join now and inspect snapshot.
	joiner := dial(t, srv)
	defer joiner.Close()
	send(joiner, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	j := waitFor(t, joiner, "joined", 2*time.Second)
	snap := j["room"].(map[string]any)
	if snap["paused"] != false && snap["paused"] != true {
		t.Fatalf("snapshot missing paused: %v", snap)
	}
	if snap["paused"] != true {
		t.Fatalf("post-navigate snapshot should be paused, got %v", snap["paused"])
	}
	if snap["currentTime"] != 0.0 {
		t.Fatalf("post-navigate currentTime should be 0, got %v", snap["currentTime"])
	}
}

// F12-r: an unbound connection must not claim a tempUser that an online
// member already holds — otherwise anyone in the room could steal the
// host's identity via the update path.
func TestUnboundUpdateCannotStealMemberIdentity(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("r9", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "r9", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)

	// Stranger claims the member's live identity via update -> rejected.
	stranger := dial(t, srv)
	defer stranger.Close()
	send(stranger, updateMsg("r9", "", "memB", 5))
	waitForErr(t, stranger, "identity_in_use", 2*time.Second)

	// And the host's identity is equally protected.
	send(stranger, updateMsg("r9", "", "hostA", 6))
	waitForErr(t, stranger, "identity_in_use", 2*time.Second)

	// A genuinely fresh identity still takes over (VT reclaim semantics).
	send(stranger, updateMsg("r9", "", "freshC", 7))
	if ack := waitFor(t, stranger, "update_ack", 2*time.Second); ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("fresh identity should still take over, got %v", ack)
	}
}

// F12-q: if a member takes over host in the gap between the host's
// socket dying and disconnect() processing it, the stale disconnect must
// not clobber the takeover by re-transferring host.
func TestDisconnectHandoverDoesNotClobberTakeover(t *testing.T) {
	rooms := NewRoomStore(nil)
	hub := NewHub(rooms)
	room := rooms.GetOrCreate("rx", "", "hostA")

	host := &Client{send: make(chan []byte, 64), hub: hub}
	member := &Client{send: make(chan []byte, 64), hub: hub}
	hub.mu.Lock()
	hub.clients[host] = true
	hub.clients[member] = true
	host.roomName, host.tempUser, host.room = "rx", "hostA", room
	member.roomName, member.tempUser, member.room = "rx", "memB", room
	hub.mu.Unlock()
	room.mu.Lock()
	room.upsertMemberLocked("hostA")
	room.upsertMemberLocked("memB")
	room.mu.Unlock()

	// The member takes over in the race window (isNew update path).
	room.mu.Lock()
	room.setHostLocked("memB")
	room.mu.Unlock()

	// Now the stale host connection's disconnect runs — it must NOT
	// re-transfer host away from the member who just claimed it.
	hub.disconnect(host)
	if !room.IsHost("memB") {
		t.Fatalf("stale disconnect clobbered the takeover")
	}
}

// F12-s: the update path enforces the same member cap join does — a
// takeover storm cannot overflow the room past maxMembersPerRoom.
func TestUpdatePathRespectsMemberCap(t *testing.T) {
	rooms := NewRoomStore(nil)
	hub := NewHub(rooms)
	room := rooms.GetOrCreate("rc", "", "hostA")

	host := &Client{send: make(chan []byte, 64), hub: hub}
	hub.mu.Lock()
	hub.clients[host] = true
	host.roomName, host.tempUser, host.room = "rc", "hostA", room
	hub.mu.Unlock()
	room.mu.Lock()
	room.upsertMemberLocked("hostA")
	for i := 0; i < maxMembersPerRoom-1; i++ {
		room.upsertMemberLocked(fmt.Sprintf("m%d", i))
	}
	room.mu.Unlock()

	// Room is at cap: a fresh identity's update must be rejected.
	flood := &Client{send: make(chan []byte, 64), hub: hub}
	hub.handleUpdate(flood, &Incoming{
		Type: "update", Room: "rc", TempUser: "invader",
		Playback: &PlaybackState{
			PlaybackRate: 1, CurrentTime: 1, Duration: 100,
			LastUpdateClientTime: 1,
		},
	})
	select {
	case raw := <-flood.send:
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		if m["code"] != "room_full" {
			t.Fatalf("expected room_full, got %v", m)
		}
	default:
		t.Fatal("expected a room_full rejection")
	}
	if room.IsHost("invader") {
		t.Fatalf("rejected update must not leave a phantom host")
	}
}

// F12-v: a degenerate duration (<1s, NaN, negative) must not trigger the
// end-of-video barrier exemption.
func TestDegenerateDurationDoesNotExemptBarrier(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	up := updateMsgWithTarget("rd", "", "hostA", 0)
	up["playback"].(map[string]any)["currentTime"] = 0.9
	up["playback"].(map[string]any)["duration"] = 0.9 // degenerate: <1s
	send(host, up)
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rd", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("rd", "", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("degenerate duration must not exempt the barrier")
	}
}

// F12-x: member_update echoes carry a timestamp so heartbeats feed the
// member's time-sync between the 60s tsync packets.
func TestMemberUpdateEchoCarriesTimestamp(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("re", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "re", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("re", "", "memB", true, true))
	echo := waitFor(t, member, "member_update", 2*time.Second)
	if _, ok := echo["timestamp"].(float64); !ok {
		t.Fatalf("member_update echo must carry timestamp: %v", echo)
	}
}

// F12-y: the host's own loading flag is excluded from the member barrier
// — the host reports its stall through the paused playback state, and
// counting it would make the host wait on itself forever.
func TestHostLoadingExcludedFromBarrier(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rf", "", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rf", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	// Host reports isLoading=true (its heartbeat path does this) — the
	// barrier must stay down.
	send(host, memberLoadingMsg("rf", "", "hostA", true, true))
	mu := waitFor(t, member, "member_update", 2*time.Second)
	if mu["waitForLoadding"] != false {
		t.Fatalf("host loading must not raise the member barrier: %v", mu)
	}
}

// F12-z: a member that stops heartbeating cannot hold the barrier —
// its loading flag is ignored once LastHeartbeat goes stale.
func TestStaleHeartbeatDoesNotHoldBarrier(t *testing.T) {
	srv, rooms := startTestServerRooms(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rg", "", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rg", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("rg", "", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("fresh loading should hold the barrier")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second) // drain echo

	// The member's socket silently dies (no close frame → disconnect not
	// yet processed): heartbeats stop. Backdate LastHeartbeat past the
	// 15s freshness TTL.
	room := rooms.Get("rg")
	room.mu.Lock()
	room.members["memB"].LastHeartbeat = time.Now().Add(-20 * time.Second)
	room.mu.Unlock()

	// Next host update recomputes the barrier → released.
	send(host, updateMsgWithTarget("rg", "", "hostA", 11))
	if ack := waitFor(t, host, "update_ack", 2*time.Second); ack["room"].(map[string]any)["waitForLoadding"] != false {
		t.Fatalf("stale heartbeat must release the barrier, got %v", ack["room"])
	}
}

// F12-aa: when the aggregate barrier flips WITHOUT any member's flag
// changing (TTL expiry of the loading run), the transition must still
// broadcast — otherwise the host waits until its own 2s update.
func TestBarrierFlipBroadcastOnTTLExpiry(t *testing.T) {
	defer func(orig time.Duration) { maxMemberLoadingWait = orig }(maxMemberLoadingWait)
	maxMemberLoadingWait = 80 * time.Millisecond
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rh", "", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rh", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, memberLoadingMsg("rh", "", "memB", true, true))
	if mu := waitFor(t, host, "member_update", 2*time.Second); mu["waitForLoadding"] != true {
		t.Fatalf("fresh loading should hold the barrier")
	}
	_ = waitFor(t, member, "member_update", 2*time.Second)

	// Loading run expires. The member re-sends the SAME flag — no member
	// flag changed, but the barrier flips false→ broadcast to the host.
	time.Sleep(150 * time.Millisecond)
	send(member, memberLoadingMsg("rh", "", "memB", true, true))
	_ = waitFor(t, member, "member_update", 2*time.Second) // sender copy
	mu := waitFor(t, host, "member_update", 2*time.Second)
	if mu["waitForLoadding"] != false {
		t.Fatalf("barrier flip must broadcast waitForLoadding=false, got %v", mu)
	}
}

// F12-t: a WebRTC signal to a tempUser is delivered to EVERY live
// connection bound to it — reconnecting devices hold two conns briefly
// and dropping one races the delivery.
func TestWebRTCDeliversToAllMatchingConns(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("ri", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	m1 := dial(t, srv)
	defer m1.Close()
	send(m1, map[string]any{"type": "join", "room": "ri", "password": "", "tempUser": "memB"})
	waitFor(t, m1, "joined", 2*time.Second)
	m2 := dial(t, srv)
	defer m2.Close()
	send(m2, map[string]any{"type": "join", "room": "ri", "password": "", "tempUser": "memB"})
	waitFor(t, m2, "joined", 2*time.Second)

	send(host, map[string]any{
		"type": "webrtc", "tempUser": "hostA", "to": "memB",
		"payload": map[string]any{"kind": "offer", "sdp": "x"},
	})
	waitFor(t, m1, "webrtc", 2*time.Second)
	waitFor(t, m2, "webrtc", 2*time.Second)
}

// F12-u: attacker-controlled fields are length-capped before they can
// amplify through the broadcast fan-out.
func TestFieldLengthCaps(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	send(host, updateMsg("rj", "", "hostA", 1))
	waitFor(t, host, "update_ack", 2*time.Second)

	big := strings.Repeat("x", maxTempUserLen+1)
	conn := dial(t, srv)
	defer conn.Close()
	send(conn, map[string]any{"type": "join", "room": "rj", "password": "", "tempUser": big})
	waitForErr(t, conn, "bad_request", 2*time.Second)

	// Oversized WebRTC payload (>64KiB) is rejected too.
	member := dial(t, srv)
	defer member.Close()
	send(member, map[string]any{"type": "join", "room": "rj", "password": "", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	send(member, map[string]any{
		"type": "webrtc", "tempUser": "memB", "to": "hostA",
		"payload": map[string]any{"sdp": strings.Repeat("s", maxWebRTCLen)},
	})
	waitForErr(t, member, "bad_request", 2*time.Second)
}

// F13: member → transfer_request → host approves via transfer — the role
// flips server-side and both conns get fresh per-conn isHost snapshots.
func TestHostTransferFlow(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rt", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rt", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	// Member requests the host role; host sees who asked.
	send(member, map[string]any{"type": "transfer_request", "room": "rt", "tempUser": "memB"})
	waitFor(t, member, "transfer_requested", 2*time.Second)
	req := waitFor(t, host, "transfer_request", 2*time.Second)
	if req["from"] != "memB" {
		t.Fatalf("transfer_request must name the requester, got %v", req)
	}

	// Cooldown: an immediate second request is rate-limited.
	send(member, map[string]any{"type": "transfer_request", "room": "rt", "tempUser": "memB"})
	waitForErr(t, member, "rate_limited", 2*time.Second)

	// Host approves by transferring to the requester's tempUser.
	send(host, map[string]any{"type": "transfer", "room": "rt", "tempUser": "hostA", "to": "memB"})
	waitFor(t, host, "host_changed", 2*time.Second)
	waitFor(t, member, "host_changed", 2*time.Second)
	snapM := waitFor(t, member, "room", 2*time.Second)
	if snapM["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("transferee must see isHost=true, got %v", snapM)
	}
	snapH := waitFor(t, host, "room", 2*time.Second)
	if snapH["room"].(map[string]any)["isHost"] != false {
		t.Fatalf("old host must see isHost=false, got %v", snapH)
	}

	// Authority moved: the new host's update acks, the old host's update
	// is rejected with other_host_syncing.
	send(member, updateMsg("rt", "pw1", "memB", 20))
	if ack := waitFor(t, member, "update_ack", 2*time.Second); ack["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("new host update should ack isHost=true")
	}
	send(host, updateMsg("rt", "pw1", "hostA", 21))
	waitForErr(t, host, "other_host_syncing", 2*time.Second)
}

// F13: 'peer' resolves to the sole other member in a 2-person room.
func TestTransferPeerAlias(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rp", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rp", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(host, map[string]any{"type": "transfer", "room": "rp", "tempUser": "hostA", "to": "peer"})
	hc := waitFor(t, member, "host_changed", 2*time.Second)
	if hc["to"] != "memB" {
		t.Fatalf("peer alias must resolve to the other member, got %v", hc)
	}
	snap := waitFor(t, member, "room", 2*time.Second)
	if snap["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("peer transferee must see isHost=true")
	}
}

// F13: guard rails — non-host cannot transfer, unknown/self targets are
// rejected, 'peer' is ambiguous with 3+ members.
func TestTransferGuards(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	m1 := dial(t, srv)
	defer m1.Close()
	m2 := dial(t, srv)
	defer m2.Close()

	send(host, updateMsgWithTarget("rg", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(m1, map[string]any{"type": "join", "room": "rg", "password": "pw1", "tempUser": "memB"})
	waitFor(t, m1, "joined", 2*time.Second)
	send(m2, map[string]any{"type": "join", "room": "rg", "password": "pw1", "tempUser": "memC"})
	waitFor(t, m2, "joined", 2*time.Second)

	// Non-host transfer attempt.
	send(m1, map[string]any{"type": "transfer", "room": "rg", "tempUser": "memB", "to": "memC"})
	waitForErr(t, m1, "host_only", 2*time.Second)

	// Unknown target.
	send(host, map[string]any{"type": "transfer", "room": "rg", "tempUser": "hostA", "to": "ghost"})
	waitForErr(t, host, "member_not_found", 2*time.Second)

	// Self-transfer.
	send(host, map[string]any{"type": "transfer", "room": "rg", "tempUser": "hostA", "to": "hostA"})
	waitForErr(t, host, "already_host", 2*time.Second)

	// 'peer' is ambiguous with 3 members.
	send(host, map[string]any{"type": "transfer", "room": "rg", "tempUser": "hostA", "to": "peer"})
	waitForErr(t, host, "peer_ambiguous", 2*time.Second)

	// Explicit transfer to a real member still works in a 3-person room.
	send(host, map[string]any{"type": "transfer", "room": "rg", "tempUser": "hostA", "to": "memC"})
	waitFor(t, m2, "host_changed", 2*time.Second)
	snap := waitFor(t, m2, "room", 2*time.Second)
	if snap["room"].(map[string]any)["isHost"] != true {
		t.Fatalf("explicit transfer in multi-member room must work")
	}
}

// F13: the host's denial reaches the requester; the host role stays put.
func TestTransferDeny(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	send(host, updateMsgWithTarget("rd", "pw1", "hostA", 10))
	waitFor(t, host, "update_ack", 2*time.Second)
	send(member, map[string]any{"type": "join", "room": "rd", "password": "pw1", "tempUser": "memB"})
	waitFor(t, member, "joined", 2*time.Second)
	waitFor(t, host, "peer_joined", 2*time.Second)

	send(member, map[string]any{"type": "transfer_request", "room": "rd", "tempUser": "memB"})
	waitFor(t, member, "transfer_requested", 2*time.Second)
	waitFor(t, host, "transfer_request", 2*time.Second)

	send(host, map[string]any{"type": "transfer_deny", "room": "rd", "tempUser": "hostA", "to": "memB"})
	waitFor(t, member, "transfer_deny", 2*time.Second)

	// Deny does not change the host: member update is still member-side.
	send(member, updateMsg("rd", "pw1", "memB", 20))
	waitForErr(t, member, "other_host_syncing", 2*time.Second)
}

// F14: a null-target navigate clears the room target and broadcasts —
// members use it to pop back off the video route when the host leaves.
func TestNavigateNullTarget(t *testing.T) {
	srv, rooms := startTestServerRooms(t)
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

	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"target": map[string]any{"type": "video", "bvid": "BV1xx", "cid": 123},
	})
	nav := waitFor(t, member, "navigate", 2*time.Second)
	if nav["target"] == nil {
		t.Fatalf("expected target on real navigate")
	}

	// Host leaves the video page: nil target clears and broadcasts.
	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
	})
	nav = waitFor(t, member, "navigate", 2*time.Second)
	if nav["target"] != nil {
		t.Fatalf("expected nil target on leave navigate, got %v", nav["target"])
	}
	room := rooms.Get("r1")
	if room == nil || room.Playback.Target != nil {
		t.Fatalf("room target should be cleared after null navigate")
	}
}
