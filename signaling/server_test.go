package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func startTestServer(t *testing.T) *httptest.Server {
	rooms := NewRoomStore()
	hub := NewHub(rooms)
	go hub.run()
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

func TestFullFlow(t *testing.T) {
	srv := startTestServer(t)
	defer srv.Close()

	host := dial(t, srv)
	defer host.Close()
	member := dial(t, srv)
	defer member.Close()

	// 1. host first update creates room (no self-broadcast expected)
	send(host, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"playback": map[string]any{
			"playbackRate": 1.0, "currentTime": 10.0, "paused": false,
			"lastUpdateClientTime": 1000.0,
		},
	})
	waitFor(t, host, "update_ack", 2*time.Second)

	// 2. member join
	send(member, map[string]any{"type": "join", "room": "r1", "password": "pw1", "tempUser": "memB"})
	joined := waitFor(t, member, "joined", 2*time.Second)
	if joined["isHost"] != false {
		t.Fatalf("member should not be host")
	}
	if joined["room"].(map[string]any)["currentTime"].(float64) != 10.0 {
		t.Fatalf("room snapshot currentTime mismatch")
	}

	// host receives peer_joined
	waitFor(t, host, "peer_joined", 2*time.Second)

	// 3. member tries update -> rejected
	send(member, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "memB",
		"playback": map[string]any{"playbackRate": 2.0, "currentTime": 99.0, "paused": false},
	})
	waitFor(t, member, "error", 2*time.Second)

	// 4. host update -> member receives room broadcast
	send(host, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"playback": map[string]any{
			"playbackRate": 1.5, "currentTime": 42.0, "paused": true,
			"lastUpdateClientTime": 2000.0,
		},
	})
	roomMsg := waitFor(t, member, "room", 2*time.Second)
	room := roomMsg["room"].(map[string]any)
	if room["currentTime"].(float64) != 42.0 || room["paused"] != true {
		t.Fatalf("broadcast mismatch: %v", room)
	}

	// 5. member reports loading -> host notified
	isLoading := true
	send(member, map[string]any{
		"type": "update_member", "room": "r1", "password": "pw1", "tempUser": "memB", "isLoading": isLoading,
	})
	mu := waitFor(t, host, "member_update", 2*time.Second)
	if mu["waitForLoadding"] != true {
		t.Fatalf("waitForLoadding should be true")
	}

	// 6. host navigate -> member receives
	send(host, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"target": map[string]any{"type": "video", "bvid": "BV1xx", "cid": 123},
	})
	nav := waitFor(t, member, "navigate", 2*time.Second)
	if nav["target"].(map[string]any)["bvid"] != "BV1xx" {
		t.Fatalf("navigate target mismatch")
	}

	// 7. member navigate -> host_only error
	send(member, map[string]any{
		"type": "navigate", "room": "r1", "password": "pw1", "tempUser": "memB",
		"target": map[string]any{"type": "video", "bvid": "evil"},
	})
	if e := waitFor(t, member, "error", 2*time.Second); e["code"] != "host_only" {
		t.Fatalf("expected host_only, got %v", e)
	}

	// 8. wrong password
	send(dial(t, srv), map[string]any{"type": "join", "room": "r1", "password": "bad", "tempUser": "x"})
	// note: leaked conn acceptable in test
	conn := dial(t, srv)
	send(conn, map[string]any{"type": "join", "room": "r1", "password": "bad", "tempUser": "x"})
	if e := waitFor(t, conn, "error", 2*time.Second); e["code"] != "wrong_password" {
		t.Fatalf("expected wrong_password, got %v", e)
	}
	conn.Close()

	// 9. host takeover by new user
	send(host, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "freshC",
		"playback": map[string]any{"playbackRate": 1.0, "currentTime": 1.0, "paused": false},
	})
	waitFor(t, host, "update_ack", 2*time.Second)
	// hostA (now non-host) gets rejected
	send(host, map[string]any{
		"type": "update", "room": "r1", "password": "pw1", "tempUser": "hostA",
		"playback": map[string]any{"playbackRate": 1.0, "currentTime": 2.0, "paused": false},
	})
	if e := waitFor(t, host, "error", 2*time.Second); e["code"] != "other_host_syncing" {
		t.Fatalf("expected other_host_syncing, got %v", e)
	}
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
