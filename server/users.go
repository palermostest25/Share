package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type grant struct {
	Path  string `json:"path"`
	Write bool   `json:"write"`
}

type account struct {
	ID     string  `json:"id"`
	Name   string  `json:"name"`
	Hash   string  `json:"hash"`
	Admin  bool    `json:"admin"`
	Grants []grant `json:"grants"`
}

type userStore struct {
	mu    sync.RWMutex
	root  *os.Root
	users []account
	key   []byte
}

type principal struct {
	user   account
	legacy bool
}
type principalContextKey struct{}

var usernamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$`)

func loadUsers(root *os.Root, accessKey string) (*userStore, error) {
	u := &userStore{root: root, key: []byte(accessKey), users: []account{}}
	b, err := root.ReadFile(".nasdrive/users.json")
	if errors.Is(err, os.ErrNotExist) {
		return u, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &u.users); err != nil {
		return nil, err
	}
	return u, nil
}

func (u *userStore) saveLocked() error {
	b, err := json.MarshalIndent(u.users, "", "  ")
	if err != nil {
		return err
	}
	f, err := u.root.OpenFile(".nasdrive/users.json.tmp", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return u.root.Rename(".nasdrive/users.json.tmp", ".nasdrive/users.json")
}

func (u *userStore) initialized() bool { u.mu.RLock(); defer u.mu.RUnlock(); return len(u.users) > 0 }

func (s *server) setupStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]any{"needsSetup": !s.users.initialized()})
}

func (s *server) setup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AccessKey string `json:"accessKey"`
		Username  string `json:"username"`
		Password  string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	got, want := sha256.Sum256([]byte(req.AccessKey)), sha256.Sum256([]byte(s.cfg.accessKey))
	if subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
		writeError(w, 401, "unauthorized", "Bootstrap key rejected.")
		return
	}
	if !usernamePattern.MatchString(req.Username) || len(req.Password) < 12 || len(req.Password) > 72 {
		writeError(w, 400, "bad_request", "Use a 2–64 character username and a password of 12–72 bytes.")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, 500, "internal", "Could not create account.")
		return
	}
	u := s.users
	u.mu.Lock()
	defer u.mu.Unlock()
	if len(u.users) > 0 {
		writeError(w, 409, "already_setup", "An administrator already exists.")
		return
	}
	id, err := randomID()
	if err != nil {
		writeError(w, 500, "internal", "Could not create account.")
		return
	}
	u.users = []account{{ID: id, Name: req.Username, Hash: string(hash), Admin: true, Grants: []grant{}}}
	if err := u.saveLocked(); err != nil {
		u.users = nil
		writeError(w, 500, "internal", "Could not save account.")
		return
	}
	writeJSON(w, 201, map[string]any{"user": publicAccount(u.users[0]), "token": u.token(u.users[0])})
}

func publicAccount(a account) map[string]any {
	return map[string]any{"id": a.ID, "name": a.Name, "admin": a.Admin, "grants": a.Grants}
}

func (u *userStore) token(a account) string {
	version := sha256.Sum256([]byte(a.Hash))
	payload, _ := json.Marshal(struct {
		ID      string `json:"i"`
		Expires int64  `json:"e"`
		Version string `json:"v"`
	}{a.ID, time.Now().Add(30 * 24 * time.Hour).Unix(), base64.RawURLEncoding.EncodeToString(version[:8])})
	mac := hmac.New(sha256.New, u.key)
	mac.Write([]byte("share-session-v1"))
	mac.Write(payload)
	return base64.RawURLEncoding.EncodeToString(payload) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (u *userStore) byToken(token string) (account, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return account{}, false
	}
	payload, e1 := base64.RawURLEncoding.DecodeString(parts[0])
	sig, e2 := base64.RawURLEncoding.DecodeString(parts[1])
	if e1 != nil || e2 != nil || len(payload) > 512 {
		return account{}, false
	}
	mac := hmac.New(sha256.New, u.key)
	mac.Write([]byte("share-session-v1"))
	mac.Write(payload)
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return account{}, false
	}
	var claim struct {
		ID      string `json:"i"`
		Expires int64  `json:"e"`
		Version string `json:"v"`
	}
	if json.Unmarshal(payload, &claim) != nil || time.Now().Unix() > claim.Expires {
		return account{}, false
	}
	u.mu.RLock()
	defer u.mu.RUnlock()
	for _, a := range u.users {
		if a.ID == claim.ID {
			version := sha256.Sum256([]byte(a.Hash))
			if claim.Version == base64.RawURLEncoding.EncodeToString(version[:8]) {
				return a, true
			}
		}
	}
	return account{}, false
}

func (u *userStore) userCanRead(id, clean string) bool {
	u.mu.RLock()
	defer u.mu.RUnlock()
	for _, a := range u.users {
		if a.ID == id {
			return (principal{user: a}).allowed(clean, false)
		}
	}
	return false
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	ip := clientIP(r) + "/login/" + strings.ToLower(req.Username)
	now := time.Now()
	if s.limiter.blocked(ip, now) {
		writeError(w, 429, "rate_limited", "Try again later.")
		return
	}
	s.users.mu.RLock()
	var found account
	for _, a := range s.users.users {
		if strings.EqualFold(a.Name, req.Username) {
			found = a
			break
		}
	}
	s.users.mu.RUnlock()
	if found.ID == "" || bcrypt.CompareHashAndPassword([]byte(found.Hash), []byte(req.Password)) != nil {
		s.limiter.fail(ip, now)
		writeError(w, 401, "unauthorized", "Username or password is incorrect.")
		return
	}
	s.limiter.success(ip)
	writeJSON(w, 200, map[string]any{"user": publicAccount(found), "token": s.users.token(found)})
}

func (s *server) me(w http.ResponseWriter, r *http.Request) {
	p := currentPrincipal(r)
	writeJSON(w, 200, publicAccount(p.user))
}

func (s *server) changePassword(w http.ResponseWriter, r *http.Request) {
	p := currentPrincipal(r)
	if p.legacy {
		writeError(w, 403, "forbidden", "Use a personal account to change its password.")
		return
	}
	var req struct {
		Current string `json:"current"`
		Next    string `json:"next"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Next) < 12 || len(req.Next) > 72 {
		writeError(w, 400, "bad_request", "New password must be 12–72 bytes.")
		return
	}
	u := s.users
	u.mu.Lock()
	defer u.mu.Unlock()
	for i, a := range u.users {
		if a.ID == p.user.ID {
			if bcrypt.CompareHashAndPassword([]byte(a.Hash), []byte(req.Current)) != nil {
				writeError(w, 400, "bad_password", "Current password is incorrect.")
				return
			}
			hash, err := bcrypt.GenerateFromPassword([]byte(req.Next), bcrypt.DefaultCost)
			if err != nil {
				writeError(w, 500, "internal", "Could not change password.")
				return
			}
			old := a
			a.Hash = string(hash)
			u.users[i] = a
			if err := u.saveLocked(); err != nil {
				u.users[i] = old
				writeError(w, 500, "internal", "Could not save password.")
				return
			}
			writeJSON(w, 200, map[string]any{"token": u.token(a)})
			return
		}
	}
	writeError(w, 404, "not_found", "Account no longer exists.")
}

func currentPrincipal(r *http.Request) principal {
	p, _ := r.Context().Value(principalContextKey{}).(principal)
	return p
}

func (p principal) allowed(clean string, write bool) bool {
	if p.user.Admin {
		return true
	}
	for _, g := range p.user.Grants {
		gp := strings.TrimPrefix(g.Path, "/")
		if gp == "" {
			gp = "."
		}
		if (clean == gp || gp == "." || strings.HasPrefix(clean, gp+"/")) && (!write || g.Write) {
			return true
		}
	}
	return false
}

func (p principal) visible(clean string) bool {
	if clean == "." || p.allowed(clean, false) {
		return true
	}
	for _, g := range p.user.Grants {
		gp := strings.TrimPrefix(g.Path, "/")
		if strings.HasPrefix(gp, clean+"/") {
			return true
		}
	}
	return false
}

func requireAccess(w http.ResponseWriter, r *http.Request, clean string, write bool) bool {
	if currentPrincipal(r).allowed(clean, write) {
		return true
	}
	writeError(w, 403, "forbidden", "This account does not have access to that location.")
	return false
}

func (s *server) adminUsers(w http.ResponseWriter, r *http.Request) {
	if !currentPrincipal(r).user.Admin {
		writeError(w, 403, "forbidden", "Administrator only.")
		return
	}
	s.users.mu.RLock()
	defer s.users.mu.RUnlock()
	out := make([]any, 0, len(s.users.users))
	for _, a := range s.users.users {
		out = append(out, publicAccount(a))
	}
	writeJSON(w, 200, map[string]any{"users": out})
}

func normalizeGrants(grants []grant) ([]grant, error) {
	if len(grants) > 100 {
		return nil, os.ErrInvalid
	}
	out := make([]grant, 0, len(grants))
	seen := map[string]bool{}
	for _, g := range grants {
		clean, err := cleanRequestPath(g.Path, false)
		if err != nil {
			return nil, err
		}
		g.Path = displayPath(clean)
		if !seen[g.Path] {
			out = append(out, g)
			seen[g.Path] = true
		}
	}
	return out, nil
}

func (s *server) adminCreateUser(w http.ResponseWriter, r *http.Request) {
	if !currentPrincipal(r).user.Admin {
		writeError(w, 403, "forbidden", "Administrator only.")
		return
	}
	var req struct {
		Username string  `json:"username"`
		Password string  `json:"password"`
		Admin    bool    `json:"admin"`
		Grants   []grant `json:"grants"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !usernamePattern.MatchString(req.Username) || len(req.Password) < 12 || len(req.Password) > 72 {
		writeError(w, 400, "bad_request", "Invalid username or password (minimum 12 characters).")
		return
	}
	grants, err := normalizeGrants(req.Grants)
	if err != nil {
		writeError(w, 400, "bad_path", "Invalid folder grant.")
		return
	}
	if !s.validGrants(grants) {
		writeError(w, 400, "bad_path", "Grant targets must be existing files or folders.")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, 500, "internal", "Could not create account.")
		return
	}
	id, err := randomID()
	if err != nil {
		writeError(w, 500, "internal", "Could not create account.")
		return
	}
	u := s.users
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, a := range u.users {
		if strings.EqualFold(a.Name, req.Username) {
			writeError(w, 409, "exists", "Username already exists.")
			return
		}
	}
	a := account{ID: id, Name: req.Username, Hash: string(hash), Admin: req.Admin, Grants: grants}
	u.users = append(u.users, a)
	if err := u.saveLocked(); err != nil {
		u.users = u.users[:len(u.users)-1]
		writeError(w, 500, "internal", "Could not save account.")
		return
	}
	writeJSON(w, 201, publicAccount(a))
}

func (s *server) adminUpdateUser(w http.ResponseWriter, r *http.Request) {
	if !currentPrincipal(r).user.Admin {
		writeError(w, 403, "forbidden", "Administrator only.")
		return
	}
	var req struct {
		Password *string  `json:"password"`
		Admin    *bool    `json:"admin"`
		Grants   *[]grant `json:"grants"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	var grants []grant
	var err error
	if req.Grants != nil {
		grants, err = normalizeGrants(*req.Grants)
		if err != nil {
			writeError(w, 400, "bad_path", "Invalid folder grant.")
			return
		}
		if !s.validGrants(grants) {
			writeError(w, 400, "bad_path", "Grant targets must be existing files or folders.")
			return
		}
	}
	var hash []byte
	if req.Password != nil {
		if len(*req.Password) < 12 || len(*req.Password) > 72 {
			writeError(w, 400, "bad_request", "Password must be 12–72 bytes.")
			return
		}
		hash, err = bcrypt.GenerateFromPassword([]byte(*req.Password), bcrypt.DefaultCost)
		if err != nil {
			writeError(w, 500, "internal", "Could not update password.")
			return
		}
	}
	u := s.users
	u.mu.Lock()
	defer u.mu.Unlock()
	for i, a := range u.users {
		if a.ID == r.PathValue("id") {
			if req.Admin != nil && !*req.Admin && a.Admin && adminCount(u.users) <= 1 {
				writeError(w, 409, "last_admin", "At least one administrator is required.")
				return
			}
			if req.Admin != nil {
				a.Admin = *req.Admin
			}
			if req.Grants != nil {
				a.Grants = grants
			}
			if req.Password != nil {
				a.Hash = string(hash)
			}
			old := u.users[i]
			u.users[i] = a
			if err := u.saveLocked(); err != nil {
				u.users[i] = old
				writeError(w, 500, "internal", "Could not save account.")
				return
			}
			writeJSON(w, 200, publicAccount(a))
			return
		}
	}
	writeError(w, 404, "not_found", "Account not found.")
}

func adminCount(users []account) int {
	n := 0
	for _, a := range users {
		if a.Admin {
			n++
		}
	}
	return n
}

func (s *server) adminDeleteUser(w http.ResponseWriter, r *http.Request) {
	if !currentPrincipal(r).user.Admin {
		writeError(w, 403, "forbidden", "Administrator only.")
		return
	}
	u := s.users
	u.mu.Lock()
	defer u.mu.Unlock()
	for i, a := range u.users {
		if a.ID == r.PathValue("id") {
			if a.Admin && adminCount(u.users) <= 1 {
				writeError(w, 409, "last_admin", "At least one administrator is required.")
				return
			}
			old := u.users
			u.users = append(append([]account{}, u.users[:i]...), u.users[i+1:]...)
			if err := u.saveLocked(); err != nil {
				u.users = old
				writeError(w, 500, "internal", "Could not save account.")
				return
			}
			w.WriteHeader(204)
			return
		}
	}
	writeError(w, 404, "not_found", "Account not found.")
}

func (s *server) legacyPrincipal() principal {
	return principal{user: account{ID: "legacy", Name: "Legacy key", Admin: true}, legacy: true}
}

func (s *server) authenticateBearer(token string) (principal, bool) {
	if a, ok := s.users.byToken(token); ok {
		return principal{user: a}, true
	}
	got, want := sha256.Sum256([]byte(token)), sha256.Sum256([]byte(s.cfg.accessKey))
	if subtle.ConstantTimeCompare(got[:], want[:]) == 1 && (!s.users.initialized() || s.cfg.allowLegacyKey) {
		return s.legacyPrincipal(), true
	}
	return principal{}, false
}

func (s *server) validGrants(grants []grant) bool {
	for _, g := range grants {
		clean := strings.TrimPrefix(g.Path, "/")
		if s.rejectSymlink(clean, false) != nil {
			return false
		}
		info, err := s.root.Stat(clean)
		if err != nil || (!info.IsDir() && !info.Mode().IsRegular()) {
			return false
		}
	}
	return true
}
