package main

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"
)

type authRecord struct {
	failures []time.Time
	blocked  time.Time
	seen     time.Time
}

type authLimiter struct {
	mu      sync.Mutex
	records map[string]*authRecord
}

func newAuthLimiter() *authLimiter {
	return &authLimiter{records: make(map[string]*authRecord)}
}

func (l *authLimiter) blocked(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	r := l.records[ip]
	if r == nil {
		return false
	}
	r.seen = now
	return now.Before(r.blocked)
}

func (l *authLimiter) fail(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	r := l.records[ip]
	if r == nil {
		r = &authRecord{}
		l.records[ip] = r
	}
	cutoff := now.Add(-10 * time.Minute)
	kept := r.failures[:0]
	for _, t := range r.failures {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	r.failures = append(kept, now)
	r.seen = now
	if len(r.failures) >= 10 {
		r.blocked = now.Add(15 * time.Minute)
		return true
	}
	return false
}

func (l *authLimiter) success(ip string) {
	l.mu.Lock()
	delete(l.records, ip)
	l.mu.Unlock()
}

func (l *authLimiter) prune(now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for ip, r := range l.records {
		if now.Sub(r.seen) > 30*time.Minute && now.After(r.blocked) {
			delete(l.records, ip)
		}
	}
}

func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		now := time.Now()
		ip := clientIP(r)
		limitLegacy := !s.users.initialized() || s.cfg.allowLegacyKey
		if limitLegacy && s.limiter.blocked(ip, now) {
			writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many rejected access keys. Try again later.")
			return
		}
		header := r.Header.Get("Authorization")
		key := ""
		if strings.HasPrefix(header, "Bearer ") {
			key = strings.TrimPrefix(header, "Bearer ")
		}
		p, ok := s.authenticateBearer(key)
		if !ok {
			if limitLegacy && s.limiter.fail(ip, now) {
				writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many rejected access keys. Try again later.")
			} else {
				writeError(w, http.StatusUnauthorized, "unauthorized", "Access key rejected.")
			}
			return
		}
		if limitLegacy {
			s.limiter.success(ip)
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalContextKey{}, p)))
	})
}
