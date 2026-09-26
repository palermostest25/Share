package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	"golang.org/x/net/webdav"
)

// Finder needs a mounted filesystem, not a Finder Sync extension. WebDAV gives
// it a real volume while the native app remains the no-full-download media path.
func (s *server) webDAV() http.Handler {
	h := &webdav.Handler{
		Prefix:     "/Share",
		FileSystem: &rootedDAV{server: s},
		LockSystem: webdav.NewMemLS(),
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Finder probes OPTIONS before sending credentials. Its capability
		// response contains no file data, and must not consume auth attempts.
		if r.Method == http.MethodOptions {
			h.ServeHTTP(w, r)
			return
		}
		user, password, ok := r.BasicAuth()
		ip := clientIP(r) + "/dav/" + strings.ToLower(user)
		now := time.Now()
		if s.limiter.blocked(ip, now) {
			http.Error(w, "Too many rejected access keys.", http.StatusTooManyRequests)
			return
		}
		p, valid := s.davPrincipal(user, password)
		if !ok || !valid {
			if s.limiter.fail(ip, now) {
				http.Error(w, "Too many rejected access keys.", http.StatusTooManyRequests)
				return
			}
			w.Header().Set("WWW-Authenticate", `Basic realm="Share"`)
			http.Error(w, "Access key rejected.", http.StatusUnauthorized)
			return
		}
		s.limiter.success(ip)
		h.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalContextKey{}, p)))
	})
}

func (s *server) davPrincipal(user, password string) (principal, bool) {
	if user == "share" {
		got, want := sha256.Sum256([]byte(password)), sha256.Sum256([]byte(s.cfg.accessKey))
		if subtle.ConstantTimeCompare(got[:], want[:]) == 1 && (!s.users.initialized() || s.cfg.allowLegacyKey) {
			return s.legacyPrincipal(), true
		}
	}
	if a, ok := s.users.byToken(password); ok && strings.EqualFold(a.Name, user) {
		return principal{user: a}, true
	}
	s.users.mu.RLock()
	defer s.users.mu.RUnlock()
	for _, a := range s.users.users {
		if strings.EqualFold(a.Name, user) && bcrypt.CompareHashAndPassword([]byte(a.Hash), []byte(password)) == nil {
			return principal{user: a}, true
		}
	}
	return principal{}, false
}

type rootedDAV struct{ server *server }

func (d *rootedDAV) name(raw string, rootAllowed bool, missingLeaf bool) (string, error) {
	if raw != "/" {
		raw = strings.TrimSuffix(raw, "/")
	}
	clean, err := cleanRequestPath(raw, rootAllowed)
	if err != nil {
		return "", os.ErrInvalid
	}
	if err := d.server.rejectSymlink(clean, missingLeaf); err != nil {
		return "", err
	}
	return clean, nil
}

func (d *rootedDAV) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	clean, err := d.name(name, false, true)
	if err != nil {
		return err
	}
	if !davAllowed(ctx, clean, true) {
		return os.ErrPermission
	}
	return d.server.root.Mkdir(clean, perm)
}

func (d *rootedDAV) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	clean, err := d.name(name, true, flag&os.O_CREATE != 0)
	if err != nil {
		return nil, err
	}
	if clean == "." && flag != os.O_RDONLY {
		return nil, os.ErrPermission
	}
	write := flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC|os.O_APPEND) != 0
	if write && !davAllowed(ctx, clean, true) {
		return nil, os.ErrPermission
	}
	if !write && !davVisible(ctx, clean) {
		return nil, os.ErrPermission
	}
	f, err := d.server.root.OpenFile(clean, flag, perm)
	if err != nil {
		return nil, err
	}
	p, _ := ctx.Value(principalContextKey{}).(principal)
	return &davFile{File: f, root: d.server.root, name: clean, principal: p}, nil
}

func (d *rootedDAV) RemoveAll(ctx context.Context, name string) error {
	clean, err := d.name(name, false, false)
	if err != nil {
		return err
	}
	if !davAllowed(ctx, clean, true) {
		return os.ErrPermission
	}
	return d.server.root.RemoveAll(clean)
}

func (d *rootedDAV) Rename(ctx context.Context, oldName, newName string) error {
	oldPath, err := d.name(oldName, false, false)
	if err != nil {
		return err
	}
	newPath, err := d.name(newName, false, true)
	if err != nil {
		return err
	}
	if !davAllowed(ctx, oldPath, true) || !davAllowed(ctx, newPath, true) {
		return os.ErrPermission
	}
	if oldPath == newPath || strings.HasPrefix(newPath, oldPath+"/") {
		return os.ErrInvalid
	}
	return d.server.root.Rename(oldPath, newPath)
}

func (d *rootedDAV) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	clean, err := d.name(name, true, false)
	if err != nil {
		return nil, err
	}
	if !davVisible(ctx, clean) {
		return nil, os.ErrPermission
	}
	return d.server.root.Stat(clean)
}

func davAllowed(ctx context.Context, clean string, write bool) bool {
	p, _ := ctx.Value(principalContextKey{}).(principal)
	return p.allowed(clean, write)
}
func davVisible(ctx context.Context, clean string) bool {
	p, _ := ctx.Value(principalContextKey{}).(principal)
	return p.visible(clean)
}

type davFile struct {
	*os.File
	root      *os.Root
	name      string
	principal principal
}

func (f *davFile) Readdir(count int) ([]os.FileInfo, error) {
	// The upload workspace and symlinks must never surface in Finder.
	visible := []os.FileInfo{}
	for count <= 0 || len(visible) < count {
		items, err := f.File.Readdir(1)
		if len(items) != 0 && items[0].Name() != ".nasdrive" && items[0].Mode()&os.ModeSymlink == 0 && f.principal.visible(strings.TrimPrefix(f.name+"/"+items[0].Name(), "./")) {
			visible = append(visible, items[0])
		}
		if err != nil {
			if err == io.EOF && (count <= 0 || len(visible) != 0) {
				return visible, nil
			}
			return visible, err
		}
	}
	return visible, nil
}

func (f *davFile) Read(p []byte) (int, error)                   { return f.File.Read(p) }
func (f *davFile) Write(p []byte) (int, error)                  { return f.File.Write(p) }
func (f *davFile) Seek(offset int64, whence int) (int64, error) { return f.File.Seek(offset, whence) }
func (f *davFile) Stat() (os.FileInfo, error)                   { return f.File.Stat() }
func (f *davFile) Close() error                                 { return f.File.Close() }

var _ webdav.FileSystem = (*rootedDAV)(nil)
var _ webdav.File = (*davFile)(nil)
