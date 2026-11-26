package main

import (
	"encoding/json"
	"testing"
	"time"
)

// Each update replaces the previous playback snapshot. The public Dart
// reader (WtPlaybackState.fromJson) supplies defaults inside that snapshot.
func TestRoomWirePlayback(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		rate    float64
		paused  bool
	}{
		{"missing-both", `{"currentTime":12}`, 1, true},
		{"null-both", `{"currentTime":12,"playbackRate":null,"paused":null}`, 1, true},
		{"missing-rate", `{"currentTime":12,"paused":false}`, 1, false},
		{"missing-paused", `{"currentTime":12,"playbackRate":1.75}`, 1.75, true},
		{"explicit-zero", `{"currentTime":12,"playbackRate":0,"paused":false}`, 0.1, false},
		{"explicit-playing", `{"currentTime":12,"playbackRate":1.75,"paused":false}`, 1.75, false},
		{"explicit-paused", `{"currentTime":12,"playbackRate":1.5,"paused":true}`, 1.5, true},
	}
	srv := startTestServer(t)
	defer srv.Close()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			host := dial(t, srv)
			defer host.Close()
			// Start from a different, complete state to distinguish whole
			// snapshots from patches and to catch stale optional fields.
			msg := updateMsgWithTarget(c.name, "", "sender", 7)
			send(host, msg)
			waitFor(t, host, "update_ack", 2*time.Second)
			msg["playback"] = json.RawMessage(c.payload)
			send(host, msg)
			room := waitFor(t, host, "update_ack", 2*time.Second)["room"].(map[string]any)
			_, hasTarget := room["target"]
			if room["playbackRate"] != c.rate || room["paused"] != c.paused ||
				room["currentTime"] != 12.0 || room["duration"] != 0.0 || hasTarget {
				t.Fatalf("rate=%v paused=%v time=%v duration=%v hasTarget=%v; want %v %v 12 0 false",
					room["playbackRate"], room["paused"], room["currentTime"], room["duration"], hasTarget,
					c.rate, c.paused)
			}
		})
	}
}

// These two synthetic participants share a video page. Only a loading
// member on the current target may raise the room's playback barrier.
func TestRoomWireBarrier(t *testing.T) {
	cases := []struct {
		name   string
		target string
		wait   bool
	}{
		{"missing-type", `{"bvid":"BV1test","cid":100}`, true},
		{"null-type", `{"type":null,"bvid":"BV1test","cid":100}`, true},
		{"matching-video", `{"type":"video","bvid":"BV1test","cid":100}`, true},
		{"different-part", `{"type":"video","bvid":"BV1test","cid":101}`, false},
		{"different-type", `{"type":"live","bvid":"BV1test","cid":100}`, false},
		{"explicit-empty-type", `{"type":"","bvid":"BV1test","cid":100}`, false},
		{"null-target", `null`, false},
	}
	srv := startTestServer(t)
	defer srv.Close()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			host := dial(t, srv)
			defer host.Close()
			member := dial(t, srv)
			defer member.Close()

			send(host, updateMsgWithTarget(c.name, "", "sender", 7))
			waitFor(t, host, "update_ack", 2*time.Second)
			send(member, map[string]any{"type": "join", "room": c.name, "tempUser": "viewer"})
			waitFor(t, member, "joined", 2*time.Second)
			msg := memberLoadingMsg(c.name, "", "viewer", true, false)
			msg["target"] = json.RawMessage(c.target)
			send(member, msg)
			event := waitFor(t, host, "member_update", 2*time.Second)
			if event["waitForLoadding"] != c.wait {
				t.Fatalf("waitForLoadding=%v; want %v", event["waitForLoadding"], c.wait)
			}
		})
	}
}
