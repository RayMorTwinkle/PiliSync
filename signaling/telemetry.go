package main

// Telemetry: the app POSTs one small ping on startup (opt-out in settings).
// Server records device id, app version, account (if logged in), open count,
// Watch-Together usage counters, and derives IP + geo location server-side.
//
// Storage: append-only data/telemetry.jsonl (one JSON object per line).
// Aggregation + geo lookups happen at dashboard render time — the file is
// the single source of truth, so restarts lose nothing.
//
// Dashboard: GET /telemetry/dashboard?key=<pass> — public HTML page, password
// comes from env TELEMETRY_PASS and is never committed to the repo.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	telemetryPass     = os.Getenv("TELEMETRY_PASS")
	telemetryPath     = filepath.Join(updateDataDir, "telemetry.jsonl")
	geoCachePath      = filepath.Join(updateDataDir, "geo.json")
	telemetryMu       sync.Mutex
	geoCacheMu        sync.Mutex
	pingRate          = map[string][]time.Time{}
	pingRateMu        sync.Mutex
	telemetryMaxField = 128 // chars, cap on client-supplied strings
)

type telemetryPing struct {
	DeviceID  string `json:"device_id"`
	Version   string `json:"version"`
	BuildTime int64  `json:"build_time"`
	Mid       int64  `json:"mid"`
	Uname     string `json:"uname"`
	OpenCount int64  `json:"open_count"`
	WtCount   int64  `json:"wt_count"`
	WtSecs    int64  `json:"wt_secs"`
}

// telemetryRecord is one JSONL line: client fields + server-derived metadata.
type telemetryRecord struct {
	TS   int64  `json:"ts"`
	IP   string `json:"ip"`
	telemetryPing
}

func clip(s string) string {
	if len(s) > telemetryMaxField {
		return s[:telemetryMaxField]
	}
	return s
}

// clientIP (ws.go) reads X-Forwarded-For set by nginx — reused for pings.

// allowPing is a coarse per-IP rate limit: at most 6 pings / 10 min.
// Legit clients ping once per app start — anything beyond is noise/abuse.
func allowPing(ip string) bool {
	pingRateMu.Lock()
	defer pingRateMu.Unlock()
	now := time.Now()
	cut := now.Add(-10 * time.Minute)
	list := pingRate[ip][:0]
	for _, t := range pingRate[ip] {
		if t.After(cut) {
			list = append(list, t)
		}
	}
	if len(list) >= 6 {
		pingRate[ip] = list
		return false
	}
	pingRate[ip] = append(list, now)
	return true
}

func serveTelemetryPing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	ip := clientIP(r)
	if !allowPing(ip) {
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	var p telemetryPing
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	if err := dec.Decode(&p); err != nil || len(p.DeviceID) < 8 {
		http.Error(w, "bad payload", http.StatusBadRequest)
		return
	}
	p.DeviceID = clip(p.DeviceID)
	p.Version = clip(p.Version)
	p.Uname = clip(p.Uname)
	rec := telemetryRecord{TS: time.Now().Unix(), IP: ip, telemetryPing: p}
	line, _ := json.Marshal(rec)
	telemetryMu.Lock()
	defer telemetryMu.Unlock()
	if err := os.MkdirAll(updateDataDir, 0o755); err != nil {
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	f, err := os.OpenFile(telemetryPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- aggregation ---

type deviceInfo struct {
	ID        string
	Version   string
	BuildTime int64
	Mid       int64
	Uname     string
	OpenCount int64 // max seen
	WtCount   int64 // max seen
	WtSecs    int64 // max seen
	IP        string
	LastSeen  int64
	FirstSeen int64
}

func loadRecords() []telemetryRecord {
	telemetryMu.Lock()
	defer telemetryMu.Unlock()
	f, err := os.Open(telemetryPath)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []telemetryRecord
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		var rec telemetryRecord
		if json.Unmarshal(sc.Bytes(), &rec) == nil && rec.DeviceID != "" {
			out = append(out, rec)
		}
	}
	return out
}

func aggregate(recs []telemetryRecord) map[string]*deviceInfo {
	devs := map[string]*deviceInfo{}
	for _, rec := range recs {
		d, ok := devs[rec.DeviceID]
		if !ok {
			d = &deviceInfo{ID: rec.DeviceID, FirstSeen: rec.TS}
			devs[rec.DeviceID] = d
		}
		d.LastSeen = max(d.LastSeen, rec.TS)
		d.Version = rec.Version
		d.BuildTime = rec.BuildTime
		d.IP = rec.IP
		d.OpenCount = max(d.OpenCount, rec.OpenCount)
		d.WtCount = max(d.WtCount, rec.WtCount)
		d.WtSecs = max(d.WtSecs, rec.WtSecs)
		if rec.Mid != 0 {
			d.Mid = rec.Mid
		}
		if rec.Uname != "" {
			d.Uname = rec.Uname
		}
	}
	return devs
}

// --- geo lookup (ipwho.is, cached on disk; only at dashboard render) ---

func geoLookup(ip string) string {
	if ip == "" || net.ParseIP(ip) == nil || isPrivateIP(ip) {
		return "内网"
	}
	geoCacheMu.Lock()
	cache := map[string]string{}
	if data, err := os.ReadFile(geoCachePath); err == nil {
		_ = json.Unmarshal(data, &cache)
	}
	if v, ok := cache[ip]; ok {
		geoCacheMu.Unlock()
		return v
	}
	geoCacheMu.Unlock()

	url := "https://ipwho.is/" + ip + "?fields=success,country,region_name,city"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	label := "未知"
	if err == nil {
		defer resp.Body.Close()
		var out struct {
			Success bool   `json:"success"`
			Country string `json:"country"`
			Region  string `json:"region_name"`
			City    string `json:"city"`
		}
		if json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out) == nil && out.Success {
			label = strings.Trim(strings.Join([]string{out.Country, out.Region, out.City}, " "), " ")
		}
	}
	geoCacheMu.Lock()
	if data, err := os.ReadFile(geoCachePath); err == nil {
		_ = json.Unmarshal(data, &cache)
	}
	cache[ip] = label
	if err := os.MkdirAll(updateDataDir, 0o755); err == nil {
		tmp := geoCachePath + ".tmp"
		if b, err := json.Marshal(cache); err == nil {
			if os.WriteFile(tmp, b, 0o640) == nil {
				_ = os.Rename(tmp, geoCachePath)
			}
		}
	}
	geoCacheMu.Unlock()
	return label
}

func isPrivateIP(ip string) bool {
	v := net.ParseIP(ip)
	if v == nil {
		return true
	}
	return v.IsPrivate() || v.IsLoopback() || v.IsLinkLocalUnicast()
}

// --- dashboard ---

func serveTelemetryDashboard(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if telemetryPass == "" || !constTimeEq(key, telemetryPass) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte("403"))
		return
	}
	recs := loadRecords()
	devs := aggregate(recs)
	var list []*deviceInfo
	for _, d := range devs {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].LastSeen > list[j].LastSeen })

	now := time.Now().Unix()
	var act24, act7d, wtSessions, wtSecs int64
	geoCount := map[string]int{}
	accounts := map[string]bool{}
	for _, d := range list {
		if now-d.LastSeen < 24*3600 {
			act24++
		}
		if now-d.LastSeen < 7*86400 {
			act7d++
		}
		wtSessions += d.WtCount
		wtSecs += d.WtSecs
		geo := geoLookup(d.IP)
		geoCount[geo]++
		if d.Mid != 0 {
			accounts[fmt.Sprintf("%d %s", d.Mid, d.Uname)] = true
		}
	}

	var b strings.Builder
	b.WriteString(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">`)
	b.WriteString(`<title>PiliSync 遥测</title><style>`)
	b.WriteString(`body{font-family:system-ui,-apple-system,sans-serif;max-width:960px;margin:24px auto;padding:0 16px;color:#222}`)
	b.WriteString(`h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:1.6em}`)
	b.WriteString(`table{border-collapse:collapse;width:100%;font-size:.85rem}`)
	b.WriteString(`td,th{border-bottom:1px solid #e5e5e5;text-align:left;padding:6px 8px;white-space:nowrap}`)
	b.WriteString(`.cards{display:flex;gap:12px;flex-wrap:wrap}.card{border:1px solid #e5e5e5;border-radius:10px;padding:12px 18px;min-width:120px}`)
	b.WriteString(`.card b{display:block;font-size:1.5rem}.muted{color:#888;font-size:.8rem}</style>`)
	b.WriteString(`<h1>PiliSync 遥测</h1>`)
	b.WriteString(`<div class="cards">`)
	card := func(name string, v any) {
		fmt.Fprintf(&b, `<div class="card"><b>%v</b>%s</div>`, v, html.EscapeString(name))
	}
	card("总设备", len(list))
	card("24h 活跃", act24)
	card("7d 活跃", act7d)
	card("一起看次数", wtSessions)
	card("一起看时长", fmt.Sprintf("%.1f h", float64(wtSecs)/3600))
	card("总 ping", len(recs))
	b.WriteString(`</div>`)

	b.WriteString(`<h2>设备</h2><table><tr><th>设备</th><th>版本</th><th>账号</th><th>IP/属地</th><th>打开次数</th><th>WT次数</th><th>WT时长</th><th>最后活跃</th></tr>`)
	for _, d := range list {
		acct := "未登录"
		if d.Mid != 0 {
			acct = fmt.Sprintf("%s (%d)", d.Uname, d.Mid)
		}
		fmt.Fprintf(&b,
			`<tr><td>%s</td><td>%s</td><td>%s</td><td>%s · %s</td><td>%d</td><td>%d</td><td>%.0f min</td><td>%s</td></tr>`,
			html.EscapeString(shortID(d.ID)),
			html.EscapeString(d.Version),
			html.EscapeString(acct),
			html.EscapeString(d.IP),
			html.EscapeString(geoLookup(d.IP)),
			d.OpenCount, d.WtCount, float64(d.WtSecs)/60,
			html.EscapeString(time.Unix(d.LastSeen, 0).Format("01-02 15:04")))
	}
	b.WriteString(`</table>`)

	b.WriteString(`<h2>属地分布</h2><table>`)
	type kv struct {
		k string
		v int
	}
	var geoList []kv
	for k, v := range geoCount {
		geoList = append(geoList, kv{k, v})
	}
	sort.Slice(geoList, func(i, j int) bool { return geoList[i].v > geoList[j].v })
	for _, g := range geoList {
		fmt.Fprintf(&b, `<tr><td>%s</td><td>%d 台</td></tr>`, html.EscapeString(g.k), g.v)
	}
	b.WriteString(`</table>`)

	if len(accounts) > 0 {
		b.WriteString(`<h2>账号</h2><table>`)
		for a := range accounts {
			fmt.Fprintf(&b, `<tr><td>%s</td></tr>`, html.EscapeString(a))
		}
		b.WriteString(`</table>`)
	}
	fmt.Fprintf(&b, `<p class="muted">数据 %s · 记录 %d 条</p>`,
		time.Now().Format("2006-01-02 15:04:05"), len(recs))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(b.String()))
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}
