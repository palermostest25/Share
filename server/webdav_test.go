package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func davRequest(t *testing.T, h http.Handler, method, target string, body []byte, password string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, target, bytes.NewReader(body))
	r.RemoteAddr = "192.0.2.50:1234"
	if password != "" {
		r.SetBasicAuth("share", password)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestWebDAVFinderOperations(t *testing.T) {
	dir := t.TempDir()
	_, h := testServer(t, dir)
	for i := 0; i < 12; i++ {
		options := davRequest(t, h, "OPTIONS", "/Share/", nil, "")
		if options.Code != 200 || options.Header().Get("DAV") == "" {
			t.Fatalf("unauthenticated capability probe %d: status=%d DAV=%q", i, options.Code, options.Header().Get("DAV"))
		}
	}
	if got := davRequest(t, h, "PROPFIND", "/Share/", nil, "").Code; got != 401 {
		t.Fatalf("no auth=%d", got)
	}
	if got := davRequest(t, h, "MKCOL", "/Share/Folder", nil, testKey).Code; got != 201 {
		t.Fatalf("mkdir=%d", got)
	}
	if got := davRequest(t, h, "PUT", "/Share/Folder/file.txt", []byte("hello world"), testKey).Code; got != 201 {
		t.Fatalf("put=%d", got)
	}
	find := httptest.NewRequest("PROPFIND", "/Share/Folder/", nil)
	find.RemoteAddr = "192.0.2.50:1234"
	find.SetBasicAuth("share", testKey)
	find.Header.Set("Depth", "1")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, find)
	if w.Code != 207 || !strings.Contains(w.Body.String(), "file.txt") {
		t.Fatalf("propfind=%d %s", w.Code, w.Body.String())
	}
	get := httptest.NewRequest("GET", "/Share/Folder/file.txt", nil)
	get.RemoteAddr = "192.0.2.50:1234"
	get.SetBasicAuth("share", testKey)
	get.Header.Set("Range", "bytes=6-10")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, get)
	if w.Code != 206 || w.Body.String() != "world" {
		t.Fatalf("range=%d %q", w.Code, w.Body.String())
	}
	move := httptest.NewRequest("MOVE", "/Share/Folder/file.txt", nil)
	move.RemoteAddr = "192.0.2.50:1234"
	move.SetBasicAuth("share", testKey)
	move.Header.Set("Destination", "http://example.com/Share/Folder/renamed.txt")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, move)
	if w.Code != 201 {
		t.Fatalf("move=%d %s", w.Code, w.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "Folder", "renamed.txt")); err != nil {
		t.Fatal(err)
	}
	if got := davRequest(t, h, "DELETE", "/Share/Folder/renamed.txt", nil, testKey).Code; got != 204 {
		t.Fatalf("delete=%d", got)
	}
	if got := davRequest(t, h, "DELETE", "/Share/", nil, testKey).Code; got == 204 {
		t.Fatal("root deleted")
	}
}

func TestWebDAVHidesInternalsAndSymlinks(t *testing.T) {
	dir := t.TempDir()
	if err := os.Symlink("/etc", filepath.Join(dir, "outside")); err != nil {
		t.Fatal(err)
	}
	_, h := testServer(t, dir)
	r := httptest.NewRequest("PROPFIND", "/Share/", nil)
	r.RemoteAddr = "192.0.2.51:1234"
	r.SetBasicAuth("share", testKey)
	r.Header.Set("Depth", "1")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 207 || strings.Contains(w.Body.String(), ".nasdrive") || strings.Contains(w.Body.String(), "outside") {
		t.Fatalf("unsafe listing=%d %s", w.Code, w.Body.String())
	}
	if got := davRequest(t, h, "GET", "/Share/outside/passwd", nil, testKey).Code; got == 200 {
		t.Fatal("symlink escape")
	}
}
