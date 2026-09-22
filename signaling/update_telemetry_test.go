package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- /update/latest ---

func TestUpdateLatestNotPublished(t *testing.T) {
	tmp := t.TempDir()
	old := latestFilePath
	latestFilePath = filepath.Join(tmp, "latest.json")
	defer func() { latestFilePath = old }()

	rec := httptest.NewRecorder()
	serveUpdateLatest(rec, httptest.NewRequest(http.MethodGet, "/update/latest", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestUpdateLatestServesFile(t *testing.T) {
	tmp := t.TempDir()
	oldDir, oldPath := updateDataDir, latestFilePath
	updateDataDir = tmp
	latestFilePath = filepath.Join(tmp, "latest.json")
	defer func() { updateDataDir, latestFilePath = oldDir, oldPath }()

	body := `{"tag_name":"v9.9.9","assets":[]}`
	if err := os.WriteFile(latestFilePath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	serveUpdateLatest(rec, httptest.NewRequest(http.MethodGet, "/update/latest", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "v9.9.9") {
		t.Fatalf("unexpected: %d %s", rec.Code, rec.Body.String())
	}
}

// --- mergeLatest ---

func TestMergeLatestReplacesPerPlatformAsset(t *testing.T) {
	tmp := t.TempDir()
	oldDir, oldPath := updateDataDir, latestFilePath
	updateDataDir = tmp
	latestFilePath = filepath.Join(tmp, "latest.json")
	defer func() { updateDataDir, latestFilePath = oldDir, oldPath }()

	a1 := latestAsset{Name: "pilisync-latest.apk", BrowserDownloadURL: "https://x/dl/aaa"}
	d1 := latestAsset{Name: "pilisync-latest.dmg", BrowserDownloadURL: "https://x/dl/bbb"}
	if err := mergeLatest("v1", "notes", a1); err != nil {
		t.Fatal(err)
	}
	if err := mergeLatest("v1", "notes", d1); err != nil {
		t.Fatal(err)
	}
	// Republish android — apk asset replaced, dmg kept.
	a2 := latestAsset{Name: "pilisync-latest.apk", BrowserDownloadURL: "https://x/dl/ccc"}
	if err := mergeLatest("v2", "new notes", a2); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(latestFilePath)
	var lf latestFile
	if err := json.Unmarshal(data, &lf); err != nil {
		t.Fatal(err)
	}
	if lf.TagName != "v2" || lf.Body != "new notes" {
		t.Fatalf("tag/body not updated: %+v", lf)
	}
	if len(lf.Assets) != 2 {
		t.Fatalf("expected 2 assets, got %+v", lf.Assets)
	}
	var apk, dmg bool
	for _, a := range lf.Assets {
		if a.Name == "pilisync-latest.apk" && a.BrowserDownloadURL == "https://x/dl/ccc" {
			apk = true
		}
		if a.Name == "pilisync-latest.dmg" {
			dmg = true
		}
	}
	if !apk || !dmg {
		t.Fatalf("assets wrong: %+v", lf.Assets)
	}
}

// --- /update/publish auth ---

func TestPublishUnauthorized(t *testing.T) {
	old := publishSecret
	publishSecret = "test-secret"
	defer func() { publishSecret = old }()

	rec := httptest.NewRecorder()
	servePublish(rec, httptest.NewRequest(http.MethodPost, "/update/publish", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/update/publish", nil)
	req.Header.Set("X-API-Key", "wrong")
	servePublish(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong key, got %d", rec.Code)
	}
}

func TestPublishNotConfigured(t *testing.T) {
	old := publishSecret
	publishSecret = ""
	defer func() { publishSecret = old }()
	rec := httptest.NewRecorder()
	servePublish(rec, httptest.NewRequest(http.MethodPost, "/update/publish", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 when unconfigured, got %d", rec.Code)
	}
}

// --- /dl/<id> ---

func TestDownloadRelaysRedirect(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/f/abc123" {
			w.Header().Set("Location", "https://pan.example.com/signed/xyz")
			w.WriteHeader(http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer upstream.Close()
	old := axoooURL
	axoooURL = upstream.URL
	defer func() { axoooURL = old }()

	rec := httptest.NewRecorder()
	serveDownload(rec, httptest.NewRequest(http.MethodGet, "/dl/abc123", nil))
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "https://pan.example.com/signed/xyz" {
		t.Fatalf("redirect not relayed: %d %q", rec.Code, rec.Header().Get("Location"))
	}
}

func TestDownloadBadID(t *testing.T) {
	rec := httptest.NewRecorder()
	serveDownload(rec, httptest.NewRequest(http.MethodGet, "/dl/", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

// --- /telemetry/ping ---

func withTelemetryDir(t *testing.T) {
	t.Helper()
	tmp := t.TempDir()
	oldDir, oldPath, oldGeo := updateDataDir, telemetryPath, geoCachePath
	updateDataDir = tmp
	telemetryPath = filepath.Join(tmp, "telemetry.jsonl")
	geoCachePath = filepath.Join(tmp, "geo.json")
	t.Cleanup(func() { updateDataDir, telemetryPath, geoCachePath = oldDir, oldPath, oldGeo })
}

func TestTelemetryPingStoresRecord(t *testing.T) {
	withTelemetryDir(t)
	pingRate = map[string][]time.Time{}
	body := `{"device_id":"dev-test-1234","version":"2.9.1","mid":42,"uname":"ray","open_count":7,"wt_count":3,"wt_secs":900}`
	req := httptest.NewRequest(http.MethodPost, "/telemetry/ping", strings.NewReader(body))
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 5.6.7.8")
	rec := httptest.NewRecorder()
	serveTelemetryPing(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
	data, err := os.ReadFile(telemetryPath)
	if err != nil {
		t.Fatal(err)
	}
	var stored telemetryRecord
	if err := json.Unmarshal(bytes.TrimSpace(data), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.DeviceID != "dev-test-1234" || stored.Mid != 42 || stored.WtSecs != 900 {
		t.Fatalf("fields lost: %+v", stored)
	}
	if stored.IP != "1.2.3.4" { // first XFF hop wins
		t.Fatalf("ip not derived server-side: %q", stored.IP)
	}
	if stored.TS == 0 {
		t.Fatal("server timestamp missing")
	}
}

func TestTelemetryPingRejectsBadPayload(t *testing.T) {
	withTelemetryDir(t)
	pingRate = map[string][]time.Time{}
	for _, body := range []string{`{}`, `{"device_id":"x"}`, `not-json`} {
		rec := httptest.NewRecorder()
		serveTelemetryPing(rec, httptest.NewRequest(http.MethodPost, "/telemetry/ping", strings.NewReader(body)))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %q: expected 400, got %d", body, rec.Code)
		}
	}
	if _, err := os.Stat(telemetryPath); !os.IsNotExist(err) {
		t.Fatal("bad payloads must not write storage")
	}
}

// --- dashboard ---

func TestDashboardAuth(t *testing.T) {
	old := telemetryPass
	telemetryPass = "test-pass"
	defer func() { telemetryPass = old }()
	withTelemetryDir(t)

	rec := httptest.NewRecorder()
	serveTelemetryDashboard(rec, httptest.NewRequest(http.MethodGet, "/telemetry/dashboard", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("no key: expected 403, got %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	serveTelemetryDashboard(rec, httptest.NewRequest(http.MethodGet, "/telemetry/dashboard?key=wrong", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("wrong key: expected 403, got %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	serveTelemetryDashboard(rec, httptest.NewRequest(http.MethodGet, "/telemetry/dashboard?key=test-pass", nil))
	if rec.Code != 200 {
		t.Fatalf("correct key: expected 200, got %d", rec.Code)
	}
}

func TestDashboardNoPassConfigured(t *testing.T) {
	old := telemetryPass
	telemetryPass = ""
	defer func() { telemetryPass = old }()
	rec := httptest.NewRecorder()
	serveTelemetryDashboard(rec, httptest.NewRequest(http.MethodGet, "/telemetry/dashboard?key=anything", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unconfigured pass must deny all: %d", rec.Code)
	}
}

func TestAggregate(t *testing.T) {
	recs := []telemetryRecord{
		{TS: 100, IP: "1.1.1.1", telemetryPing: telemetryPing{DeviceID: "a", OpenCount: 3, WtSecs: 10}},
		{TS: 200, IP: "1.1.1.1", telemetryPing: telemetryPing{DeviceID: "a", OpenCount: 5, WtSecs: 40, Mid: 7, Uname: "u"}},
		{TS: 150, IP: "2.2.2.2", telemetryPing: telemetryPing{DeviceID: "b", OpenCount: 1}},
	}
	devs := aggregate(recs)
	if len(devs) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devs))
	}
	a := devs["a"]
	if a.OpenCount != 5 || a.WtSecs != 40 || a.LastSeen != 200 || a.FirstSeen != 100 {
		t.Fatalf("device a aggregation wrong: %+v", a)
	}
	if a.Mid != 7 || a.Uname != "u" {
		t.Fatalf("account not carried: %+v", a)
	}
}

// multipart helper kept for future publish e2e tests
func multipartBody(t *testing.T, fields map[string]string, filename string, content []byte) (string, *bytes.Buffer) {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range fields {
		if err := w.WriteField(k, v); err != nil {
			t.Fatal(err)
		}
	}
	if filename != "" {
		h := textproto.MIMEHeader{}
		h.Set("Content-Disposition", `form-data; name="file"; filename="`+filename+`"`)
		h.Set("Content-Type", "application/octet-stream")
		p, err := w.CreatePart(h)
		if err != nil {
			t.Fatal(err)
		}
		p.Write(content)
	}
	w.Close()
	return w.FormDataContentType(), &buf
}

var _ = multipartBody
