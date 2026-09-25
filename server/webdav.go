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
	want := sha256.Sum256([]byte(s.cfg.accessKey))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		now := time.Now()
		if s.limiter.blocked(ip, now) {
			http.Error(w, "Too many rejected access keys.", http.StatusTooManyRequests)
			return
		}
		user, password, ok := r.BasicAuth()
		got := sha256.Sum256([]byte(password))
		if !ok || user != "share" || subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			if s.limiter.fail(ip, now) {
				http.Error(w, "Too many rejected access keys.", http.StatusTooManyRequests)
				return
			}
			w.Header().Set("WWW-Authenticate", `Basic realm="Share"`)
			http.Error(w, "Access key rejected.", http.StatusUnauthorized)
			return
		}
		s.limiter.success(ip)
		h.ServeHTTP(w, r)
	})
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

func (d *rootedDAV) Mkdir(_ context.Context, name string, perm os.FileMode) error {
	clean, err := d.name(name, false, true)
	if err != nil {
		return err
	}
	return d.server.root.Mkdir(clean, perm)
}

func (d *rootedDAV) OpenFile(_ context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	clean, err := d.name(name, true, flag&os.O_CREATE != 0)
	if err != nil {
		return nil, err
	}
	if clean == "." && flag != os.O_RDONLY {
		return nil, os.ErrPermission
	}
	f, err := d.server.root.OpenFile(clean, flag, perm)
	if err != nil {
		return nil, err
	}
	return &davFile{File: f, root: d.server.root, name: clean}, nil
}

func (d *rootedDAV) RemoveAll(_ context.Context, name string) error {
	clean, err := d.name(name, false, false)
	if err != nil {
		return err
	}
	return d.server.root.RemoveAll(clean)
}

func (d *rootedDAV) Rename(_ context.Context, oldName, newName string) error {
	oldPath, err := d.name(oldName, false, false)
	if err != nil {
		return err
	}
	newPath, err := d.name(newName, false, true)
	if err != nil {
		return err
	}
	if oldPath == newPath || strings.HasPrefix(newPath, oldPath+"/") {
		return os.ErrInvalid
	}
	return d.server.root.Rename(oldPath, newPath)
}

func (d *rootedDAV) Stat(_ context.Context, name string) (os.FileInfo, error) {
	clean, err := d.name(name, true, false)
	if err != nil {
		return nil, err
	}
	return d.server.root.Stat(clean)
}

type davFile struct {
	*os.File
	root *os.Root
	name string
}

func (f *davFile) Readdir(count int) ([]os.FileInfo, error) {
	// The upload workspace and symlinks must never surface in Finder.
	visible := []os.FileInfo{}
	for count <= 0 || len(visible) < count {
		items, err := f.File.Readdir(1)
		if len(items) != 0 && items[0].Name() != ".nasdrive" && items[0].Mode()&os.ModeSymlink == 0 {
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
