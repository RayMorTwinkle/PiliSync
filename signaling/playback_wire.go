package main

import "encoding/json"

// UnmarshalJSON reads one complete playback snapshot. Seed the same
// defaults used by WtPlaybackState.fromJson, then let JSON override them.
// Explicit false and zero survive decoding and reach the normal rate clamp.
func (p *PlaybackState) UnmarshalJSON(data []byte) error {
	type wire PlaybackState
	snapshot := wire{PlaybackRate: 1, Paused: true}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return err
	}
	*p = PlaybackState(snapshot)
	return nil
}

// UnmarshalJSON matches WtTarget.fromJson for targets without a type.
// A null *Target (the viewer left the page) remains nil in encoding/json.
func (t *Target) UnmarshalJSON(data []byte) error {
	type wire Target
	target := wire{Type: "video"}
	if err := json.Unmarshal(data, &target); err != nil {
		return err
	}
	*t = Target(target)
	return nil
}
