package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"time"
)

var uploadIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

type uploadMeta struct {
	ID        string     `json:"id"`
	Path      string     `json:"path"`
	Size      int64      `json:"size"`
	Modified  *time.Time `json:"modified,omitempty"`
	Created   time.Time  `json:"created"`
	Overwrite bool       `json:"overwrite"`
}

type uploadStart struct {
	Path      string     `json:"path"`
	Size      int64      `json:"size"`
	Modified  *time.Time `json:"modified,omitempty"`
	Overwrite bool       `json:"overwrite"`
}

func uploadPart(id string) string { return ".nasdrive/uploads/" + id + ".part" }
func uploadJSON(id string) string { return ".nasdrive/uploads/" + id + ".json" }

func (s *server) lockUpload(id string) func() {
	v, _ := s.uploadLocks.LoadOrStore(id, &sync.Mutex{})
	m := v.(*sync.Mutex)
	m.Lock()
	return m.Unlock
}

func (s *server) startUpload(w http.ResponseWriter, r *http.Request) {
	var req uploadStart
	if !decodeJSON(w, r, &req) {
		return
	}
	clean, err := cleanRequestPath(req.Path, false)
	if err != nil || req.Size < 0 {
		writeError(w, 400, "bad_request", "The upload path or size is invalid.")
		return
	}
	parent := path.Dir(clean)
	if err := s.rejectSymlink(parent, false); err != nil {
		s.fsError(w, err)
		return
	}
	parentInfo, err := s.root.Stat(parent)
	if err != nil || !parentInfo.IsDir() {
		writeError(w, 404, "not_found", "The destination folder does not exist.")
		return
	}
	if info, err := s.root.Lstat(clean); err == nil {
		if !req.Overwrite || !info.Mode().IsRegular() {
			writeError(w, 409, "exists", "An item already uses that name.")
			return
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		s.fsError(w, err)
		return
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(s.cfg.dataDir, &stat); err == nil {
		free := int64(stat.Bavail) * int64(stat.Bsize)
		if free < req.Size+(1<<30) {
			writeError(w, 507, "insufficient_storage", "The NAS does not have enough free space for this upload.")
			return
		}
	}
	id, err := randomID()
	if err != nil {
		writeError(w, 500, "internal", "Could not create the upload.")
		return
	}
	meta := uploadMeta{ID: id, Path: displayPath(clean), Size: req.Size, Modified: req.Modified, Created: time.Now().UTC(), Overwrite: req.Overwrite}
	b, _ := json.Marshal(meta)
	part, err := s.root.OpenFile(uploadPart(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		s.fsError(w, err)
		return
	}
	_ = part.Close()
	if err := s.root.WriteFile(uploadJSON(id), b, 0o640); err != nil {
		_ = s.root.Remove(uploadPart(id))
		s.fsError(w, err)
		return
	}
	writeJSON(w, 201, map[string]any{"id": id, "chunkSize": s.cfg.chunkSize, "received": 0})
}

func (s *server) readUpload(id string) (uploadMeta, int64, error) {
	var meta uploadMeta
	if !uploadIDPattern.MatchString(id) {
		return meta, 0, os.ErrNotExist
	}
	b, err := s.root.ReadFile(uploadJSON(id))
	if err != nil {
		return meta, 0, err
	}
	if err := json.Unmarshal(b, &meta); err != nil {
		return meta, 0, err
	}
	info, err := s.root.Stat(uploadPart(id))
	if err != nil {
		return meta, 0, err
	}
	return meta, info.Size(), nil
}

func (s *server) uploadStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	unlock := s.lockUpload(id)
	defer unlock()
	meta, received, err := s.readUpload(id)
	if err != nil {
		s.fsError(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"id": id, "path": meta.Path, "size": meta.Size, "received": received})
}

func (s *server) uploadChunk(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	unlock := s.lockUpload(id)
	defer unlock()
	meta, received, err := s.readUpload(id)
	if err != nil {
		s.fsError(w, err)
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		writeError(w, 400, "bad_request", "The upload offset is invalid.")
		return
	}
	if offset != received {
		writeJSON(w, 409, map[string]any{"error": "offset_mismatch", "message": "Resume from the server's received offset.", "received": received})
		return
	}
	remaining := meta.Size - received
	allowed := min64(s.cfg.chunkSize, remaining)
	if remaining <= 0 || r.ContentLength > allowed {
		writeError(w, 413, "too_large", "That upload chunk is too large.")
		return
	}
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Minute))
	f, err := s.root.OpenFile(uploadPart(id), os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		s.fsError(w, err)
		return
	}
	limited := http.MaxBytesReader(w, r.Body, allowed)
	n, copyErr := io.Copy(f, limited)
	if copyErr != nil {
		_ = f.Truncate(received)
		_ = f.Close()
		var mbe *http.MaxBytesError
		if errors.As(copyErr, &mbe) {
			writeError(w, 413, "too_large", "That upload chunk is too large.")
		} else {
			writeError(w, 400, "bad_request", "The upload chunk was interrupted.")
		}
		return
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		writeError(w, 500, "internal", "The NAS could not save that upload chunk.")
		return
	}
	if err := f.Close(); err != nil {
		writeError(w, 500, "internal", "The NAS could not save that upload chunk.")
		return
	}
	writeJSON(w, 200, map[string]any{"received": received + n})
}

func (s *server) completeUpload(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	unlock := s.lockUpload(id)
	defer unlock()
	meta, received, err := s.readUpload(id)
	if err != nil {
		s.fsError(w, err)
		return
	}
	if received != meta.Size {
		writeJSON(w, 409, map[string]any{"error": "incomplete", "message": "The upload is not complete.", "received": received})
		return
	}
	clean, err := cleanRequestPath(meta.Path, false)
	if err != nil {
		writeError(w, 400, "bad_path", "The upload destination is invalid.")
		return
	}
	if dst, err := s.root.Lstat(clean); err == nil {
		if !meta.Overwrite || !dst.Mode().IsRegular() {
			writeError(w, 409, "exists", "An item already uses that name.")
			return
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		s.fsError(w, err)
		return
	}
	if err := s.root.Rename(uploadPart(id), clean); err != nil {
		s.fsError(w, err)
		return
	}
	if meta.Modified != nil {
		_ = s.root.Chtimes(clean, *meta.Modified, *meta.Modified)
	}
	_ = s.root.Remove(uploadJSON(id))
	s.uploadLocks.Delete(id)
	info, err := s.root.Stat(clean)
	if err != nil {
		s.fsError(w, err)
		return
	}
	writeJSON(w, 200, entry{Name: path.Base(clean), Type: "file", Size: info.Size(), Modified: info.ModTime().UTC()})
}

func (s *server) abortUpload(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !uploadIDPattern.MatchString(id) {
		writeError(w, 404, "not_found", "That upload no longer exists.")
		return
	}
	unlock := s.lockUpload(id)
	defer unlock()
	_ = s.root.Remove(uploadPart(id))
	_ = s.root.Remove(uploadJSON(id))
	s.uploadLocks.Delete(id)
	w.WriteHeader(204)
}

func (s *server) cleanupLoop() {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for now := range ticker.C {
		s.cleanupUploads()
		s.limiter.prune(now)
	}
}

func (s *server) cleanupUploads() {
	dir, err := s.root.Open(".nasdrive/uploads")
	if err != nil {
		return
	}
	items, _ := dir.ReadDir(-1)
	_ = dir.Close()
	now := time.Now()
	for _, item := range items {
		if path.Ext(item.Name()) != ".json" {
			continue
		}
		id := item.Name()[:len(item.Name())-5]
		meta, _, err := s.readUpload(id)
		if err != nil || now.Sub(meta.Created) > s.cfg.uploadTTL {
			_ = s.root.Remove(uploadPart(id))
			_ = s.root.Remove(uploadJSON(id))
			s.uploadLocks.Delete(id)
		}
	}
}
