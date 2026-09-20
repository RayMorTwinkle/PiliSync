package main

import (
	"flag"
	"fmt"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	url := flag.String("server", "ws://127.0.0.1:9901/ws", "ws endpoint")
	flag.Parse()
	conn, _, err := websocket.DefaultDialer.Dial(*url, nil)
	if err != nil {
		fmt.Println("dial err:", err)
		return
	}
	defer conn.Close()

	_ = conn.WriteJSON(map[string]any{
		"type": "update", "room": "probe1", "password": "", "tempUser": "probe",
		"playback": map[string]any{"playbackRate": 1.0, "currentTime": 5.0, "paused": false},
	})
	_ = conn.WriteJSON(map[string]any{"type": "join", "room": "probe1", "password": "", "tempUser": "probe"})
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	for i := 0; i < 5; i++ {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			fmt.Println("read err:", err)
			return
		}
		fmt.Printf("recv: %s\n", msg)
	}
}
