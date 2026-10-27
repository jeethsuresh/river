package main

import (
	"errors"
	"net/http"
	"strings"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

func sessionValue(r *http.Request) string {
	if raw := r.Header.Get("Authorization"); strings.HasPrefix(raw, "Bearer ") {
		return strings.TrimPrefix(raw, "Bearer ")
	}
	if c, err := r.Cookie(gravitas.SessionCookie); err == nil {
		return c.Value
	}
	return ""
}

func (s *server) refreshSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if !s.auth.ValidMutation(r) {
		fail(w, 403, "Invalid request")
		return
	}
	value, err := s.auth.RefreshValue(r.Context(), sessionValue(r))
	if err != nil {
		status := 401
		if errors.Is(err, gravitas.ErrUnavailable) {
			status = 503
		}
		fail(w, status, err.Error())
		return
	}
	// Native clients replace their platform-secure envelope. Browser clients
	// receive only an HttpOnly cookie, never credentials in readable JSON.
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		respond(w, 200, map[string]string{"session": value})
	} else {
		if err = s.auth.SetSessionValue(w, value); err != nil {
			fail(w, 503, "Cannot renew session")
			return
		}
		respond(w, 200, map[string]bool{"ok": true})
	}
}
