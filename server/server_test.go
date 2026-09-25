package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testKey = "0123456789abcdef0123456789abcdef"

func testServer(t *testing.T, dir string) (*server, http.Handler) {
	t.Helper()
	if dir == "" {
		dir = t.TempDir()
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Close() })
	if err := root.MkdirAll(".nasdrive/uploads", 0o750); err != nil {
		t.Fatal(err)
	}
	c := config{accessKey: testKey, dataDir: dir, listen: ":8080", chunkSize: 4, linkTTL: time.Hour, uploadTTL: time.Hour}
	mac := sha256.Sum256([]byte("test-link-key"))
	s := &server{cfg: c, root: root, linkKey: mac[:], started: time.Now(), limiter: newAuthLimiter()}
	return s, s.routes()
}

func request(t *testing.T, h http.Handler, method, target string, body []byte, auth bool) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, target, bytes.NewReader(body))
	r.RemoteAddr = "192.0.2.1:1234"
	if auth {
		r.Header.Set("Authorization", "Bearer "+testKey)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func jsonReq(t *testing.T, h http.Handler, method, target string, value any) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return request(t, h, method, target, b, true)
}

func TestAuthAndRateLimitIsolation(t *testing.T) {
	_, h := testServer(t, "")
	if got := request(t, h, "GET", "/api/v1/list?path=/", nil, false).Code; got != 401 {
		t.Fatalf("no auth = %d", got)
	}
	for i := 0; i < 9; i++ {
		r := httptest.NewRequest("GET", "/api/v1/list?path=/", nil)
		r.RemoteAddr = "192.0.2.1:1234"
		r.Header.Set("CF-Connecting-IP", "198.51.100."+strconv.Itoa(i+1))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
	}
	if got := request(t, h, "GET", "/api/v1/list?path=/", nil, false).Code; got != 429 {
		t.Fatalf("rate limit = %d", got)
	}
	r := httptest.NewRequest("GET", "/api/v1/list?path=/", nil)
	r.RemoteAddr = "198.51.100.2:9"
	r.Header.Set("Authorization", "Bearer "+testKey)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("other IP = %d", w.Code)
	}
}

func TestPathsAndSymlinks(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "safe.txt"), []byte("ok"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc", filepath.Join(dir, "escape")); err != nil {
		t.Fatal(err)
	}
	_, h := testServer(t, dir)
	bad := []string{"..", "%2e%2e", "/./../x", ".nasdrive/uploads", "a%00b", "a%01b"}
	for _, p := range bad {
		if got := request(t, h, "GET", "/api/v1/file?path="+p, nil, true).Code; got != 400 {
			t.Errorf("path %q = %d", p, got)
		}
	}
	if got := request(t, h, "GET", "/api/v1/file?path=/escape/passwd", nil, true).Code; got != 400 && got != 404 {
		t.Fatalf("symlink access = %d", got)
	}
	w := request(t, h, "GET", "/api/v1/list?path=/", nil, true)
	if strings.Contains(w.Body.String(), "escape") {
		t.Fatal("symlink appeared in list")
	}
}

func TestRangeAndSignedLinks(t *testing.T) {
	dir := t.TempDir()
	data := bytes.Repeat([]byte("0123456789"), 30)
	if err := os.WriteFile(filepath.Join(dir, "movie.mp4"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	_, h := testServer(t, dir)
	r := httptest.NewRequest("GET", "/api/v1/file?path=/movie.mp4", nil)
	r.Header.Set("Authorization", "Bearer "+testKey)
	r.Header.Set("Range", "bytes=100-199")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), data[100:200]) {
		t.Fatalf("range status=%d len=%d", w.Code, w.Body.Len())
	}
	r = httptest.NewRequest("GET", "/api/v1/file?path=/movie.mp4", nil)
	r.Header.Set("Authorization", "Bearer "+testKey)
	r.Header.Set("Range", "bytes=-100")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), data[len(data)-100:]) {
		t.Fatal("suffix range failed")
	}
	r = httptest.NewRequest("GET", "/api/v1/file?path=/movie.mp4", nil)
	r.Header.Set("Authorization", "Bearer "+testKey)
	r.Header.Set("Range", "bytes=9999-")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 416 {
		t.Fatalf("invalid range = %d", w.Code)
	}
	link := jsonReq(t, h, "POST", "/api/v1/link", map[string]string{"path": "/movie.mp4"})
	if link.Code != 200 {
		t.Fatal(link.Body.String())
	}
	var out struct {
		URL string `json:"url"`
	}
	json.Unmarshal(link.Body.Bytes(), &out)
	if got := request(t, h, "GET", out.URL, nil, false).Code; got != 200 {
		t.Fatalf("signed = %d", got)
	}
	segments := strings.Split(out.URL, "/")
	segments[2] = "x" + segments[2][1:]
	tampered := strings.Join(segments, "/")
	if got := request(t, h, "GET", tampered, nil, false).Code; got != 401 {
		t.Fatalf("tampered = %d", got)
	}
}

func TestResumableUploadAndRestart(t *testing.T) {
	dir := t.TempDir()
	_, h := testServer(t, dir)
	source := []byte("hello world")
	start := jsonReq(t, h, "POST", "/api/v1/uploads", map[string]any{"path": "/result.bin", "size": len(source), "overwrite": false})
	if start.Code != 201 {
		t.Fatal(start.Body.String())
	}
	var created struct {
		ID    string `json:"id"`
		Chunk int64  `json:"chunkSize"`
	}
	json.Unmarshal(start.Body.Bytes(), &created)
	put := func(handler http.Handler, offset int, b []byte) *httptest.ResponseRecorder {
		return request(t, handler, "PUT", "/api/v1/uploads/"+created.ID+"?offset="+strconv.Itoa(offset), b, true)
	}
	if got := put(h, 1, source[:4]).Code; got != 409 {
		t.Fatalf("wrong offset = %d", got)
	}
	if got := put(h, 0, source[:5]).Code; got != 413 {
		t.Fatalf("oversize = %d", got)
	}
	if got := put(h, 0, source[:4]).Code; got != 200 {
		t.Fatalf("chunk 1 = %d", got)
	}
	if got := jsonReq(t, h, "POST", "/api/v1/uploads/"+created.ID+"/complete", map[string]any{}).Code; got != 409 {
		t.Fatalf("early complete = %d", got)
	}
	_, h2 := testServer(t, dir)
	status := request(t, h2, "GET", "/api/v1/uploads/"+created.ID, nil, true)
	if status.Code != 200 || !strings.Contains(status.Body.String(), `"received":4`) {
		t.Fatal(status.Body.String())
	}
	if got := put(h2, 4, source[4:8]).Code; got != 200 {
		t.Fatalf("chunk 2 = %d", got)
	}
	if got := put(h2, 8, source[8:]).Code; got != 200 {
		t.Fatalf("chunk 3 = %d", got)
	}
	if got := jsonReq(t, h2, "POST", "/api/v1/uploads/"+created.ID+"/complete", map[string]any{}).Code; got != 200 {
		t.Fatalf("complete = %d", got)
	}
	result, _ := os.ReadFile(filepath.Join(dir, "result.bin"))
	if sha256.Sum256(result) != sha256.Sum256(source) {
		t.Fatal("hash mismatch")
	}
}

func TestMoveDeleteAndCleanup(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "folder"), 0o700)
	os.WriteFile(filepath.Join(dir, "a"), []byte("a"), 0o600)
	os.WriteFile(filepath.Join(dir, "b"), []byte("b"), 0o600)
	s, h := testServer(t, dir)
	if got := jsonReq(t, h, "POST", "/api/v1/move", map[string]any{"from": "/a", "to": "/b", "overwrite": false}).Code; got != 409 {
		t.Fatalf("conflict=%d", got)
	}
	if got := jsonReq(t, h, "POST", "/api/v1/move", map[string]any{"from": "/folder", "to": "/folder/inside", "overwrite": false}).Code; got != 400 {
		t.Fatalf("self move=%d", got)
	}
	if got := request(t, h, "DELETE", "/api/v1/entry?path=/", nil, true).Code; got != 400 {
		t.Fatalf("delete root=%d", got)
	}
	meta := uploadMeta{ID: strings.Repeat("a", 32), Path: "/old", Size: 0, Created: time.Now().Add(-2 * time.Hour)}
	b, _ := json.Marshal(meta)
	s.root.WriteFile(uploadJSON(meta.ID), b, 0o600)
	s.root.WriteFile(uploadPart(meta.ID), nil, 0o600)
	s.cfg.uploadTTL = time.Hour
	s.cleanupUploads()
	if _, err := s.root.Stat(uploadJSON(meta.ID)); !os.IsNotExist(err) {
		t.Fatal("expired upload not removed")
	}
}

func TestMkdirCreatesMissingParents(t *testing.T) {
	dir := t.TempDir()
	_, h := testServer(t, dir)
	w := jsonReq(t, h, "POST", "/api/v1/mkdir", map[string]string{"path": "/one/two/three"})
	if w.Code != 201 {
		t.Fatalf("mkdir status=%d body=%s", w.Code, w.Body.String())
	}
	info, err := os.Stat(filepath.Join(dir, "one", "two", "three"))
	if err != nil || !info.IsDir() {
		t.Fatalf("nested directory not created: %v", err)
	}
}

func TestWebUIIsAvailableWithoutExposingFiles(t *testing.T) {
	_, h := testServer(t, "")
	w := request(t, h, "GET", "/", nil, false)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Open Share") {
		t.Fatalf("web UI status=%d", w.Code)
	}
	if got := request(t, h, "GET", "/api/v1/list?path=/", nil, false).Code; got != 401 {
		t.Fatalf("API unauthenticated=%d", got)
	}
}
