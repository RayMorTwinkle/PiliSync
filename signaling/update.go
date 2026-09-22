package main

// Domestic update channel: the app checks this server for releases instead of
// GitHub (api.github.com is unreliable in CN). CI publishes artifacts via
// /update/publish — the server deletes the previous file on axooo-pan,
// uploads the new one under a fixed name (saves pan space), registers a
// permanent /f/<id> host link, and writes data/latest.json in GitHub-release
// schema so the client parser needs no changes.
//
// Downloads never flow through this server: /dl/<id> proxies the /f/ lookup
// and relays the 302 to the pan's signed URL — the client then talks to the
// pan CDN directly.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	updateDataDir  = envOr("DATA_DIR", "data")
	axoooURL       = strings.TrimRight(envOr("AXOOO_URL", "http://10.126.126.1:3005"), "/")
	axoooKey       = os.Getenv("AXOOO_KEY")
	publishSecret  = os.Getenv("PUBLISH_SECRET")
	updatePubBase  = strings.TrimRight(envOr("PUBLIC_BASE", "https://wt.raymor.top"), "/")
	latestFilePath = filepath.Join(updateDataDir, "latest.json")
	latestMu       sync.Mutex
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// latestFile mirrors the GitHub release JSON shape the client's
// Update.checkUpdate already parses.
type latestFile struct {
	TagName   string        `json:"tag_name"`
	Body      string        `json:"body"`
	CreatedAt string        `json:"created_at"` // RFC3339 — client compares vs build time
	Assets    []latestAsset `json:"assets"`
}

type latestAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

// Fixed pan paths per platform — one "latest" file each, deleted before every
// re-upload (overwrite semantics are not trusted on the pan side).
var panPathByPlatform = map[string]string{
	"android": "/apps/pilisync/pilisync-latest.apk",
	"macos":   "/apps/pilisync/pilisync-latest.dmg",
	"windows": "/apps/pilisync/pilisync-latest.zip",
	"linux":   "/apps/pilisync/pilisync-latest.tar.gz",
}

func serveUpdateLatest(w http.ResponseWriter, _ *http.Request) {
	latestMu.Lock()
	data, err := os.ReadFile(latestFilePath)
	latestMu.Unlock()
	if err != nil {
		http.Error(w, `{"msg":"no release published"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

// serveDownload proxies /f/<id> on axooo-pan and relays the resulting 302
// (the pan's signed CDN URL) to the client. Only the redirect is proxied —
// bytes flow client↔pan directly.
func serveDownload(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/dl/")
	if id == "" || strings.Contains(id, "/") {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	req, err := http.NewRequest(http.MethodGet, axoooURL+"/f/"+id, nil)
	if err != nil {
		http.Error(w, "bad upstream", http.StatusBadGateway)
		return
	}
	client := &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "upstream unreachable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if loc := resp.Header.Get("Location"); loc != "" {
		w.Header().Set("Location", loc)
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusFound)
		return
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(io.Discard, resp.Body)
}

// servePublish accepts a multipart release artifact from CI:
//   file=<binary>  platform=android|macos|windows|linux
//   name=<asset name shown to clients>  tag=<vX.Y.Z>  body=<changelog>
// Auth: X-API-Key header or ?key= must match PUBLISH_SECRET.
func servePublish(w http.ResponseWriter, r *http.Request) {
	if publishSecret == "" {
		http.Error(w, "publish not configured", http.StatusNotFound)
		return
	}
	key := r.Header.Get("X-API-Key")
	if key == "" {
		key = r.URL.Query().Get("key")
	}
	if !constTimeEq(key, publishSecret) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 300<<20)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		http.Error(w, "multipart parse: "+err.Error(), http.StatusBadRequest)
		return
	}
	platform := r.FormValue("platform")
	panPath, ok := panPathByPlatform[platform]
	if !ok {
		http.Error(w, "unknown platform", http.StatusBadRequest)
		return
	}
	assetName := r.FormValue("name")
	tag := r.FormValue("tag")
	if assetName == "" || tag == "" {
		http.Error(w, "name and tag required", http.StatusBadRequest)
		return
	}
	f, _, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "file required", http.StatusBadRequest)
		return
	}
	defer f.Close()
	tmp, err := os.CreateTemp("", "wt-publish-*")
	if err != nil {
		http.Error(w, "tempfile", http.StatusInternalServerError)
		return
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, f); err != nil {
		tmp.Close()
		http.Error(w, "read upload", http.StatusInternalServerError)
		return
	}
	tmp.Close()

	// 1) delete the previous "latest" file (ignore missing), 2) upload,
	// 3) register a permanent host link, 4) merge into latest.json.
	_ = axoooDelete(panPath)
	if err := axoooUpload(tmp.Name(), panPath); err != nil {
		log.Printf("[update] publish %s upload failed: %v", platform, err)
		http.Error(w, "upload: "+err.Error(), http.StatusBadGateway)
		return
	}
	hid, err := axoooHost(panPath)
	if err != nil {
		log.Printf("[update] publish %s host failed: %v", platform, err)
		http.Error(w, "host: "+err.Error(), http.StatusBadGateway)
		return
	}
	if err := mergeLatest(tag, r.FormValue("body"), latestAsset{
		Name:               assetName,
		BrowserDownloadURL: updatePubBase + "/dl/" + hid,
	}); err != nil {
		http.Error(w, "latest.json: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok": true, "tag": tag, "platform": platform, "dl": updatePubBase + "/dl/" + hid,
	})
	log.Printf("[update] published %s %s -> /dl/%s", platform, tag, hid)
}

func mergeLatest(tag, body string, asset latestAsset) error {
	latestMu.Lock()
	defer latestMu.Unlock()
	var lf latestFile
	if data, err := os.ReadFile(latestFilePath); err == nil {
		_ = json.Unmarshal(data, &lf)
	}
	lf.TagName = tag
	if body != "" {
		lf.Body = body
	}
	lf.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	// Replace the asset for this platform (match by file extension family),
	// keep the others — one publish call updates one platform at a time.
	ext := filepath.Ext(asset.Name)
	out := lf.Assets[:0]
	for _, a := range lf.Assets {
		if filepath.Ext(a.Name) == ext {
			continue
		}
		out = append(out, a)
	}
	lf.Assets = append(out, asset)
	if err := os.MkdirAll(updateDataDir, 0o755); err != nil {
		return err
	}
	tmp := latestFilePath + ".tmp"
	data, err := json.MarshalIndent(&lf, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, latestFilePath)
}

// --- axooo-pan API client (internal network only) ---

func axoooReq(method, path string, body io.Reader, ctype string) (*http.Response, error) {
	req, err := http.NewRequest(method, axoooURL+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", axoooKey)
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	client := &http.Client{Timeout: 10 * time.Minute}
	return client.Do(req)
}

func axoooDelete(path string) error {
	resp, err := axoooReq(http.MethodDelete, "/file?path="+urlQueryEscape(path), nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

func axoooUpload(localPath, remotePath string) error {
	data, err := os.ReadFile(localPath)
	if err != nil {
		return err
	}
	resp, err := axoooReq(http.MethodPost,
		"/upload?path="+urlQueryEscape(remotePath),
		bytes.NewReader(data), "application/octet-stream")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return fmt.Errorf("axooo upload %d: %s", resp.StatusCode, string(payload))
	}
	var out struct {
		Code int    `json:"code"`
		Msg  string `json:"msg"`
	}
	if err := json.Unmarshal(payload, &out); err == nil && out.Code != 0 {
		return fmt.Errorf("axooo upload code=%d: %s", out.Code, out.Msg)
	}
	return nil
}

func axoooHost(path string) (string, error) {
	resp, err := axoooReq(http.MethodPost, "/host?path="+urlQueryEscape(path), nil, "")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out struct {
		Code int `json:"code"`
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
		Msg string `json:"msg"`
	}
	if err := json.Unmarshal(payload, &out); err != nil {
		return "", fmt.Errorf("axooo host parse: %v", err)
	}
	if out.Code != 0 || out.Data.ID == "" {
		return "", fmt.Errorf("axooo host code=%d: %s", out.Code, out.Msg)
	}
	return out.Data.ID, nil
}

func urlQueryEscape(s string) string { return url.QueryEscape(s) }

// constTimeEq avoids early-exit comparison on secrets.
func constTimeEq(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := range a {
		v |= a[i] ^ b[i]
	}
	return v == 0
}
