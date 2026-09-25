package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"strings"
	"time"
)

type entry struct {
	Name     string    `json:"name"`
	Type     string    `json:"type"`
	Size     int64     `json:"size,omitempty"`
	Modified time.Time `json:"modified"`
}

func (s *server) list(w http.ResponseWriter, r *http.Request) {
	clean, err := cleanRequestPath(r.URL.Query().Get("path"), true)
	if err != nil {
		writeError(w, 400, "bad_path", "That folder path is invalid.")
		return
	}
	if !currentPrincipal(r).visible(clean) {
		writeError(w, 403, "forbidden", "This folder is not shared with you.")
		return
	}
	if err := s.rejectSymlink(clean, false); err != nil {
		s.fsError(w, err)
		return
	}
	f, err := s.root.Open(clean)
	if err != nil {
		s.fsError(w, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		s.fsError(w, err)
		return
	}
	if !info.IsDir() {
		writeError(w, 400, "bad_path", "That path is not a folder.")
		return
	}
	items, err := f.ReadDir(-1)
	if err != nil {
		s.fsError(w, err)
		return
	}
	entries := make([]entry, 0, len(items))
	for _, item := range items {
		if item.Name() == ".nasdrive" {
			continue
		}
		rel := item.Name()
		if clean != "." {
			rel = clean + "/" + item.Name()
		}
		li, err := s.root.Lstat(rel)
		if err != nil || li.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if !currentPrincipal(r).visible(rel) {
			continue
		}
		typ := ""
		if li.IsDir() {
			typ = "dir"
		} else if li.Mode().IsRegular() {
			typ = "file"
		} else {
			continue
		}
		entries = append(entries, entry{Name: item.Name(), Type: typ, Size: li.Size(), Modified: li.ModTime().UTC()})
	}
	writeJSON(w, 200, map[string]any{"path": displayPath(clean), "entries": entries})
}

func (s *server) file(w http.ResponseWriter, r *http.Request) {
	clean, err := cleanRequestPath(r.URL.Query().Get("path"), false)
	if err != nil {
		writeError(w, 400, "bad_path", "That file path is invalid.")
		return
	}
	if !requireAccess(w, r, clean, false) {
		return
	}
	s.servePath(w, r, r.URL.Query().Get("path"))
}

func (s *server) servePath(w http.ResponseWriter, r *http.Request, raw string) {
	clean, err := cleanRequestPath(raw, false)
	if err != nil {
		writeError(w, 400, "bad_path", "That file path is invalid.")
		return
	}
	if err := s.rejectSymlink(clean, false); err != nil {
		s.fsError(w, err)
		return
	}
	f, err := s.root.Open(clean)
	if err != nil {
		s.fsError(w, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		s.fsError(w, err)
		return
	}
	if !info.Mode().IsRegular() {
		writeError(w, 400, "bad_path", "That path is not a file.")
		return
	}
	typ := mime.TypeByExtension(strings.ToLower(path.Ext(clean)))
	if typ == "" {
		typ = "application/octet-stream"
	}
	w.Header().Set("Content-Type", typ)
	http.ServeContent(w, r, path.Base(clean), info.ModTime(), f)
}

type linkRequest struct {
	Path string `json:"path"`
}
type linkPayload struct {
	Path    string `json:"p"`
	Expires int64  `json:"e"`
	Owner   string `json:"o,omitempty"`
}

func (s *server) createLink(w http.ResponseWriter, r *http.Request) {
	var req linkRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	clean, err := cleanRequestPath(req.Path, false)
	if err != nil {
		writeError(w, 400, "bad_path", "That file path is invalid.")
		return
	}
	if !requireAccess(w, r, clean, false) {
		return
	}
	if err := s.rejectSymlink(clean, false); err != nil {
		s.fsError(w, err)
		return
	}
	info, err := s.root.Stat(clean)
	if err != nil {
		s.fsError(w, err)
		return
	}
	if !info.Mode().IsRegular() {
		writeError(w, 400, "bad_path", "Streaming links only work for files.")
		return
	}
	expires := time.Now().Add(s.cfg.linkTTL).UTC()
	payload, _ := json.Marshal(linkPayload{Path: displayPath(clean), Expires: expires.Unix(), Owner: currentPrincipal(r).user.ID})
	mac := hmac.New(sha256.New, s.linkKey)
	mac.Write(payload)
	token := base64.RawURLEncoding.EncodeToString(payload) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	writeJSON(w, 200, map[string]any{"url": "/s/" + token + "/" + fileNameForURL(clean), "expires": expires.Format(time.RFC3339)})
}

func (s *server) signedFile(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		writeError(w, 401, "unauthorized", "This streaming link is invalid.")
		return
	}
	payload, err1 := base64.RawURLEncoding.DecodeString(parts[0])
	sig, err2 := base64.RawURLEncoding.DecodeString(parts[1])
	mac := hmac.New(sha256.New, s.linkKey)
	mac.Write(payload)
	if err1 != nil || err2 != nil || !hmac.Equal(sig, mac.Sum(nil)) {
		writeError(w, 401, "unauthorized", "This streaming link is invalid.")
		return
	}
	var p linkPayload
	if json.Unmarshal(payload, &p) != nil || time.Now().Unix() > p.Expires {
		writeError(w, 401, "unauthorized", "This streaming link has expired.")
		return
	}
	if p.Owner == "" || p.Owner == "legacy" {
		if s.users.initialized() && !s.cfg.allowLegacyKey {
			writeError(w, 401, "unauthorized", "This old link is no longer valid.")
			return
		}
	} else {
		clean, err := cleanRequestPath(p.Path, false)
		if err != nil || !s.users.userCanRead(p.Owner, clean) {
			writeError(w, 403, "forbidden", "This link is no longer shared.")
			return
		}
	}
	s.servePath(w, r, p.Path)
}

func (s *server) mkdir(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	clean, err := cleanRequestPath(req.Path, false)
	if err != nil {
		writeError(w, 400, "bad_path", "That folder path is invalid.")
		return
	}
	if !requireAccess(w, r, clean, true) {
		return
	}
	if info, err := s.root.Lstat(clean); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			writeError(w, 409, "exists", "A file already uses that name.")
			return
		}
		w.WriteHeader(200)
		return
	} else if !errors.Is(err, os.ErrNotExist) {
		s.fsError(w, err)
		return
	}
	parent := path.Dir(clean)
	if err := s.rejectSymlinkInExistingPrefix(parent); err != nil {
		s.fsError(w, err)
		return
	}
	if err := s.root.MkdirAll(clean, 0o750); err != nil {
		s.fsError(w, err)
		return
	}
	w.WriteHeader(201)
}

func (s *server) move(w http.ResponseWriter, r *http.Request) {
	var req struct {
		From      string `json:"from"`
		To        string `json:"to"`
		Overwrite bool   `json:"overwrite"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	from, e1 := cleanRequestPath(req.From, false)
	to, e2 := cleanRequestPath(req.To, false)
	if e1 != nil || e2 != nil {
		writeError(w, 400, "bad_path", "A source or destination path is invalid.")
		return
	}
	if !requireAccess(w, r, from, true) || !requireAccess(w, r, to, true) {
		return
	}
	if err := s.rejectSymlink(from, false); err != nil {
		s.fsError(w, err)
		return
	}
	if err := s.rejectSymlink(path.Dir(to), false); err != nil {
		s.fsError(w, err)
		return
	}
	src, err := s.root.Lstat(from)
	if err != nil {
		s.fsError(w, err)
		return
	}
	if src.IsDir() && (to == from || strings.HasPrefix(to, from+"/")) {
		writeError(w, 400, "bad_request", "A folder cannot be moved inside itself.")
		return
	}
	if dst, err := s.root.Lstat(to); err == nil {
		if !req.Overwrite {
			writeError(w, 409, "exists", "An item already uses that name.")
			return
		}
		if !src.Mode().IsRegular() || !dst.Mode().IsRegular() {
			writeError(w, 400, "bad_request", "Only a file can replace another file.")
			return
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		s.fsError(w, err)
		return
	}
	if err := s.root.Rename(from, to); err != nil {
		s.fsError(w, err)
		return
	}
	w.WriteHeader(200)
}

func (s *server) deleteEntry(w http.ResponseWriter, r *http.Request) {
	clean, err := cleanRequestPath(r.URL.Query().Get("path"), false)
	if err != nil {
		writeError(w, 400, "bad_path", "That item path is invalid.")
		return
	}
	if !requireAccess(w, r, clean, true) {
		return
	}
	if err := s.rejectSymlink(clean, false); err != nil {
		s.fsError(w, err)
		return
	}
	if err := s.root.RemoveAll(clean); err != nil {
		s.fsError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) fsError(w http.ResponseWriter, err error) {
	if errors.Is(err, fs.ErrNotExist) {
		writeError(w, 404, "not_found", "That item no longer exists.")
		return
	}
	if errors.Is(err, fs.ErrExist) {
		writeError(w, 409, "exists", "An item already uses that name.")
		return
	}
	if strings.Contains(err.Error(), "symlink") {
		writeError(w, 400, "bad_path", "Symbolic links are not available.")
		return
	}
	writeError(w, 500, "internal", "The server could not complete that file operation.")
}
