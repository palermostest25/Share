package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

//go:embed web/*
var webFiles embed.FS
var version = "1.3.0"

type config struct {
	accessKey      string
	allowLegacyKey bool
	dataDir        string
	listen         string
	chunkSize      int64
	linkTTL        time.Duration
	uploadTTL      time.Duration
}

type server struct {
	cfg         config
	root        *os.Root
	linkKey     []byte
	started     time.Time
	limiter     *authLimiter
	uploadLocks sync.Map
	users       *userStore
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		healthcheck()
		return
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	registerMIMETypes()
	if err := os.MkdirAll(cfg.dataDir, 0o750); err != nil {
		log.Fatalf("create data directory: %v", err)
	}
	root, err := os.OpenRoot(cfg.dataDir)
	if err != nil {
		log.Fatalf("open data root: %v", err)
	}
	defer root.Close()
	if err := root.MkdirAll(".nasdrive/uploads", 0o750); err != nil {
		log.Fatalf("create upload directory: %v", err)
	}
	mac := hmac.New(sha256.New, []byte(cfg.accessKey))
	mac.Write([]byte("share-link-v1"))
	s := &server{cfg: cfg, root: root, linkKey: mac.Sum(nil), started: time.Now(), limiter: newAuthLimiter()}
	s.users, err = loadUsers(root, cfg.accessKey)
	if err != nil {
		log.Fatalf("load users: %v", err)
	}
	s.cleanupUploads()
	go s.cleanupLoop()

	h := s.routes()
	httpServer := &http.Server{
		Addr:              cfg.listen,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()

	log.Printf("Share server listening on %s with data at %s", cfg.listen, cfg.dataDir)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func loadConfig() (config, error) {
	c := config{
		accessKey:      os.Getenv("ACCESS_KEY"),
		allowLegacyKey: os.Getenv("ALLOW_LEGACY_KEY") == "true",
		dataDir:        envOr("DATA_DIR", "/data"),
		listen:         envOr("LISTEN_ADDR", ":8080"),
		chunkSize:      32 << 20,
		linkTTL:        12 * time.Hour,
		uploadTTL:      24 * time.Hour,
	}
	if len(c.accessKey) < 32 {
		return c, errors.New("ACCESS_KEY is required and must be at least 32 characters")
	}
	if raw := os.Getenv("CHUNK_SIZE"); raw != "" {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n < 1<<20 || n > 64<<20 {
			return c, errors.New("CHUNK_SIZE must be between 1 MiB and 64 MiB")
		}
		c.chunkSize = n
	}
	var err error
	if c.linkTTL, err = durationEnv("LINK_TTL", c.linkTTL); err != nil {
		return c, err
	}
	if c.uploadTTL, err = durationEnv("UPLOAD_TTL", c.uploadTTL); err != nil {
		return c, err
	}
	return c, nil
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	v := os.Getenv(name)
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return d, nil
}

func registerMIMETypes() {
	types := map[string]string{
		".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime",
		".mkv": "video/x-matroska", ".webm": "video/webm", ".avi": "video/x-msvideo",
		".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac",
		".flac": "audio/flac", ".wav": "audio/wav", ".heic": "image/heic",
	}
	for ext, typ := range types {
		_ = mime.AddExtensionType(ext, typ)
	}
}

func healthcheck() {
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get("http://127.0.0.1:8080/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		os.Exit(1)
	}
	_ = resp.Body.Close()
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /api/v1/version", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]string{"version": version}) })
	mux.HandleFunc("GET /", s.web)
	mux.HandleFunc("GET /assets/", s.web)
	mux.HandleFunc("GET /s/{token}/{filename}", s.signedFile)
	mux.HandleFunc("HEAD /s/{token}/{filename}", s.signedFile)
	dav := s.webDAV()
	for _, method := range []string{"OPTIONS", "GET", "HEAD", "POST", "DELETE", "PUT", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK", "PROPFIND", "PROPPATCH"} {
		mux.Handle(method+" /Share/", dav)
	}
	mux.Handle("GET /api/v1/list", s.auth(http.HandlerFunc(s.list)))
	mux.HandleFunc("GET /api/v1/setup/status", s.setupStatus)
	mux.HandleFunc("POST /api/v1/setup", s.setup)
	mux.HandleFunc("POST /api/v1/login", s.login)
	mux.Handle("GET /api/v1/me", s.auth(http.HandlerFunc(s.me)))
	mux.Handle("POST /api/v1/me/password", s.auth(http.HandlerFunc(s.changePassword)))
	mux.Handle("GET /api/v1/admin/users", s.auth(http.HandlerFunc(s.adminUsers)))
	mux.Handle("POST /api/v1/admin/users", s.auth(http.HandlerFunc(s.adminCreateUser)))
	mux.Handle("PUT /api/v1/admin/users/{id}", s.auth(http.HandlerFunc(s.adminUpdateUser)))
	mux.Handle("DELETE /api/v1/admin/users/{id}", s.auth(http.HandlerFunc(s.adminDeleteUser)))
	mux.Handle("GET /api/v1/file", s.auth(http.HandlerFunc(s.file)))
	mux.Handle("HEAD /api/v1/file", s.auth(http.HandlerFunc(s.file)))
	mux.Handle("POST /api/v1/link", s.auth(http.HandlerFunc(s.createLink)))
	mux.Handle("POST /api/v1/mkdir", s.auth(http.HandlerFunc(s.mkdir)))
	mux.Handle("POST /api/v1/move", s.auth(http.HandlerFunc(s.move)))
	mux.Handle("DELETE /api/v1/entry", s.auth(http.HandlerFunc(s.deleteEntry)))
	mux.Handle("POST /api/v1/uploads", s.auth(http.HandlerFunc(s.startUpload)))
	mux.Handle("GET /api/v1/uploads/{id}", s.auth(http.HandlerFunc(s.uploadStatus)))
	mux.Handle("PUT /api/v1/uploads/{id}", s.auth(http.HandlerFunc(s.uploadChunk)))
	mux.Handle("DELETE /api/v1/uploads/{id}", s.auth(http.HandlerFunc(s.abortUpload)))
	mux.Handle("POST /api/v1/uploads/{id}/complete", s.auth(http.HandlerFunc(s.completeUpload)))
	return s.logging(s.headers(mux))
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok\n")
}

func (s *server) web(w http.ResponseWriter, r *http.Request) {
	name := "web/index.html"
	if r.URL.Path == "/assets/app.css" {
		name = "web/app.css"
	} else if r.URL.Path == "/assets/transfers.css" {
		name = "web/transfers.css"
	} else if r.URL.Path == "/assets/app.js" {
		name = "web/app.js"
	} else if r.URL.Path == "/assets/manifest.webmanifest" {
		name = "web/manifest.webmanifest"
	} else if r.URL.Path == "/assets/icon.svg" {
		name = "web/icon.svg"
	} else if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := fs.ReadFile(webFiles, name)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	switch path.Ext(name) {
	case ".html":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	case ".css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case ".js":
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	case ".webmanifest":
		w.Header().Set("Content-Type", "application/manifest+json; charset=utf-8")
	case ".svg":
		w.Header().Set("Content-Type", "image/svg+xml")
	}
	_, _ = w.Write(b)
}

func (s *server) headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; media-src 'self' blob:; img-src 'self' blob: data:; style-src 'self'; script-src 'self'; connect-src 'self' https://api.github.com")
		next.ServeHTTP(w, r)
	})
}

type logWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *logWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *logWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
		w.ResponseWriter.WriteHeader(code)
	}
}
func (w *logWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}
func (w *logWriter) ReadFrom(r io.Reader) (int64, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if rf, ok := w.ResponseWriter.(io.ReaderFrom); ok {
		n, err := rf.ReadFrom(r)
		w.bytes += n
		return n, err
	}
	n, err := io.Copy(struct{ io.Writer }{w}, r)
	return n, err
}

func (s *server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lw := &logWriter{ResponseWriter: w}
		next.ServeHTTP(lw, r)
		status := lw.status
		if status == 0 {
			status = http.StatusOK
		}
		route := r.URL.Path
		if strings.HasPrefix(route, "/s/") {
			route = "/s/<redacted>"
		}
		ip := clientIP(r)
		log.Printf("time=%s ip=%q method=%s route=%q status=%d bytes=%d duration=%s", start.UTC().Format(time.RFC3339), ip, r.Method, route, status, lw.bytes, time.Since(start).Round(time.Millisecond))
	})
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"error": code, "message": message})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "Invalid request body.")
		return false
	}
	return true
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func cleanRequestPath(raw string, allowRoot bool) (string, error) {
	if !utf8.ValidString(raw) || len(raw) > 4096 || strings.ContainsRune(raw, 0) {
		return "", errors.New("invalid path")
	}
	raw = strings.TrimPrefix(raw, "/")
	if raw == "" {
		if allowRoot {
			return ".", nil
		}
		return "", errors.New("root is not allowed")
	}
	parts := strings.Split(raw, "/")
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || part == ".nasdrive" || len([]byte(part)) > 255 {
			return "", errors.New("invalid path segment")
		}
		for _, r := range part {
			if r < 0x20 || r == 0x7f {
				return "", errors.New("control character")
			}
		}
	}
	return strings.Join(parts, "/"), nil
}

func displayPath(clean string) string {
	if clean == "." {
		return "/"
	}
	return "/" + clean
}

func (s *server) rejectSymlink(clean string, allowMissingLeaf bool) error {
	if clean == "." {
		return nil
	}
	parts := strings.Split(clean, "/")
	for i := range parts {
		p := strings.Join(parts[:i+1], "/")
		info, err := s.root.Lstat(p)
		if errors.Is(err, os.ErrNotExist) && allowMissingLeaf && i == len(parts)-1 {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symlink refused")
		}
	}
	return nil
}

func (s *server) rejectSymlinkInExistingPrefix(clean string) error {
	if clean == "." {
		return nil
	}
	parts := strings.Split(clean, "/")
	for i := range parts {
		p := strings.Join(parts[:i+1], "/")
		info, err := s.root.Lstat(p)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symlink refused")
		}
	}
	return nil
}

func fileNameForURL(p string) string {
	name := path.Base(p)
	if name == "." || name == "/" {
		return "file"
	}
	return url.PathEscape(name)
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

var _ = base64.RawURLEncoding
var _ = subtle.ConstantTimeCompare
