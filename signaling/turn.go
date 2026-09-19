package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// TURN credential relay. The Cloudflare TURN API token must NEVER ship in
// the client — it is a long-lived secret. The server mints short-lived
// ICE-server credentials upstream and hands those to clients instead.
//
// Configure via environment (see signaling/.env, gitignored):
//
//	TURN_KEY_ID     Cloudflare TURN key id
//	TURN_API_TOKEN  Cloudflare TURN API token (Bearer)
//
// When unset the endpoint returns a STUN-only config so calls still work
// on networks where STUN suffices.
var (
	turnKeyID    = os.Getenv("TURN_KEY_ID")
	turnAPIToken = os.Getenv("TURN_API_TOKEN")

	// turnAPIBase is a var so tests can point it at httptest.
	turnAPIBase = "https://rtc.live.cloudflare.com"
	// requested credential lifetime; Cloudflare caps this server-side.
	turnCredTTLSecs = 86400

	turnHTTPClient = &http.Client{Timeout: 5 * time.Second}
)

var defaultICEServers = []map[string]any{
	{"urls": "stun:stun.l.google.com:19302"},
}

type turnCache struct {
	mu        sync.Mutex
	servers   []map[string]any
	expiresAt time.Time
	fetchedAt time.Time
}

var iceCache = &turnCache{}

// serveICEServers returns the WebRTC iceServers array for clients.
// Clients GET this before creating a peer connection.
func serveICEServers(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	servers := fetchICEServers()
	_ = json.NewEncoder(w).Encode(map[string]any{"iceServers": servers})
}

func fetchICEServers() []map[string]any {
	if turnKeyID == "" || turnAPIToken == "" {
		return defaultICEServers
	}
	iceCache.mu.Lock()
	defer iceCache.mu.Unlock()
	if time.Now().Before(iceCache.expiresAt) && iceCache.servers != nil {
		return iceCache.servers
	}
	servers, err := requestCloudflareICE()
	if err != nil {
		log.Printf("[turn] upstream failed, falling back to STUN: %v", err)
		if iceCache.servers != nil {
			// serve slightly-stale creds rather than nothing
			return iceCache.servers
		}
		return defaultICEServers
	}
	iceCache.servers = servers
	iceCache.fetchedAt = time.Now()
	// refresh at half the credential lifetime so we never hand out
	// credentials that are about to expire
	iceCache.expiresAt = time.Now().Add(time.Duration(turnCredTTLSecs/2) * time.Second)
	return servers
}

// requestCloudflareICE calls the Cloudflare TURN credentials endpoint and
// normalizes the response into a WebRTC iceServers array.
func requestCloudflareICE() ([]map[string]any, error) {
	req, err := http.NewRequest(
		http.MethodPost,
		turnAPIBase+"/v1/turn/keys/"+turnKeyID+"/credentials/generate-ice-servers",
		nil,
	)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+turnAPIToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := turnHTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var body struct {
		ICEServers struct {
			// passthrough: Cloudflare may send a string or an array, and
			// WebRTC accepts both — forward verbatim.
			URLs       json.RawMessage `json:"urls"`
			Username   string          `json:"username"`
			Credential string          `json:"credential"`
		} `json:"iceServers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, errStatus(resp.StatusCode)
	}
	if len(body.ICEServers.URLs) == 0 || body.ICEServers.Credential == "" {
		return nil, errStatus(-1)
	}
	return []map[string]any{
		{
			"urls":       body.ICEServers.URLs,
			"username":   body.ICEServers.Username,
			"credential": body.ICEServers.Credential,
		},
	}, nil
}

type statusError int

func (e statusError) Error() string {
	if e < 0 {
		return "empty iceServers in upstream response"
	}
	return "cloudflare TURN API status " + http.StatusText(int(e))
}

func errStatus(code int) error { return statusError(code) }
