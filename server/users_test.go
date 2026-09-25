package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func accountRequest(t *testing.T, h http.Handler, method, target, token string, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, target, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestAccountsAndSharedOnlyPermissions(t *testing.T) {
	dir := t.TempDir()
	for _, p := range []string{"public", "private"} {
		if err := os.Mkdir(filepath.Join(dir, p), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range []string{"public/hello.txt", "private/secret.txt"} {
		if err := os.WriteFile(filepath.Join(dir, p), []byte(p), 0600); err != nil {
			t.Fatal(err)
		}
	}
	_, h := testServer(t, dir)
	setup := jsonReq(t, h, "POST", "/api/v1/setup", map[string]any{"accessKey": testKey, "username": "owner", "password": "correct horse battery staple"})
	if setup.Code != 201 {
		t.Fatal(setup.Body.String())
	}
	var session struct {
		Token string `json:"token"`
	}
	json.Unmarshal(setup.Body.Bytes(), &session)
	if session.Token == "" {
		t.Fatal("no session token")
	}
	if got := request(t, h, "GET", "/api/v1/list?path=/", nil, true).Code; got != 401 {
		t.Fatalf("legacy key after setup=%d", got)
	}
	if got := jsonReq(t, h, "POST", "/api/v1/setup", map[string]any{"accessKey": testKey, "username": "other", "password": "some long password"}).Code; got != 409 {
		t.Fatalf("second setup=%d", got)
	}
	member := accountRequest(t, h, "POST", "/api/v1/admin/users", session.Token, `{"username":"guest","password":"a sufficiently long password"}`)
	if member.Code != 201 {
		t.Fatal(member.Body.String())
	}
	var user struct {
		ID string `json:"id"`
	}
	json.Unmarshal(member.Body.Bytes(), &user)
	login := request(t, h, "POST", "/api/v1/login", []byte(`{"username":"guest","password":"a sufficiently long password"}`), false)
	if login.Code != 200 {
		t.Fatal(login.Body.String())
	}
	json.Unmarshal(login.Body.Bytes(), &session)
	memberToken := session.Token
	root := accountRequest(t, h, "GET", "/api/v1/list?path=/", memberToken, "")
	if root.Code != 200 || strings.Contains(root.Body.String(), "private") || strings.Contains(root.Body.String(), "public") {
		t.Fatalf("shared-only root: %s", root.Body.String())
	}
	for _, url := range []string{"/api/v1/file?path=/private/secret.txt", "/api/v1/list?path=/private", "/api/v1/file?path=/public/hello.txt"} {
		if got := accountRequest(t, h, "GET", url, memberToken, "").Code; got != 403 {
			t.Errorf("%s=%d", url, got)
		}
	}
	if got := accountRequest(t, h, "POST", "/api/v1/link", memberToken, `{"path":"/private/secret.txt"}`).Code; got != 403 {
		t.Fatalf("link=%d", got)
	}
	if got := accountRequest(t, h, "POST", "/api/v1/uploads", memberToken, `{"path":"/private/new.txt","size":1}`).Code; got != 403 {
		t.Fatalf("upload=%d", got)
	}
	if got := accountRequest(t, h, "POST", "/api/v1/admin/users", memberToken, `{"username":"evil","password":"a sufficiently long password"}`).Code; got != 403 {
		t.Fatalf("admin=%d", got)
	}
	// Use the original administrator token; the member login replaced session.Token.
	var adminSession struct {
		Token string `json:"token"`
	}
	json.Unmarshal(setup.Body.Bytes(), &adminSession)
	grant := accountRequest(t, h, "PUT", "/api/v1/admin/users/"+user.ID, adminSession.Token, `{"grants":[{"path":"/public","write":false}]}`)
	if grant.Code != 200 {
		t.Fatal(grant.Body.String())
	}
	// Existing tokens immediately pick up current grants from the account store.
	root = accountRequest(t, h, "GET", "/api/v1/list?path=/", memberToken, "")
	if root.Code != 200 || !strings.Contains(root.Body.String(), "public") || strings.Contains(root.Body.String(), "private") {
		t.Fatalf("filtered root: %s", root.Body.String())
	}
	if got := accountRequest(t, h, "GET", "/api/v1/file?path=/public/hello.txt", memberToken, "").Code; got != 200 {
		t.Fatalf("shared read=%d", got)
	}
	linked := accountRequest(t, h, "POST", "/api/v1/link", memberToken, `{"path":"/public/hello.txt"}`)
	if linked.Code != 200 {
		t.Fatal(linked.Body.String())
	}
	var link struct {
		URL string `json:"url"`
	}
	json.Unmarshal(linked.Body.Bytes(), &link)
	if got := accountRequest(t, h, "POST", "/api/v1/mkdir", memberToken, `{"path":"/public/new"}`).Code; got != 403 {
		t.Fatalf("read-only write=%d", got)
	}
	if got := accountRequest(t, h, "GET", "/api/v1/file?path=/private/secret.txt", memberToken, "").Code; got != 403 {
		t.Fatalf("private read=%d", got)
	}
	// WebDAV cannot bypass the API's shared-only view.
	r := httptest.NewRequest("PROPFIND", "/Share/", nil)
	r.SetBasicAuth("guest", "a sufficiently long password")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if strings.Contains(w.Body.String(), "private") {
		t.Fatalf("DAV leaked private path: %s", w.Body.String())
	}
	r = httptest.NewRequest("GET", "/Share/private/secret.txt", nil)
	r.SetBasicAuth("guest", "a sufficiently long password")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code == 200 {
		t.Fatal("DAV private read succeeded")
	}
	if got := accountRequest(t, h, "PUT", "/api/v1/admin/users/"+user.ID, adminSession.Token, `{"grants":[]}`).Code; got != 200 {
		t.Fatalf("revoke=%d", got)
	}
	if got := request(t, h, "GET", link.URL, nil, false).Code; got != 403 {
		t.Fatalf("revoked public link=%d", got)
	}
	changed := accountRequest(t, h, "POST", "/api/v1/me/password", memberToken, `{"current":"a sufficiently long password","next":"a different long password"}`)
	if changed.Code != 200 {
		t.Fatal(changed.Body.String())
	}
	if got := accountRequest(t, h, "GET", "/api/v1/me", memberToken, "").Code; got != 401 {
		t.Fatalf("old token after password change=%d", got)
	}
}
