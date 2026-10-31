package main

import (
	"errors"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"net/http"
)

func (s *server) nativeBroker(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	if !s.auth.ValidMutation(r) {
		fail(w, 403, "Invalid request")
		return
	}
	var input struct {
		Code     string `json:"code"`
		Verifier string `json:"code_verifier"`
		Subject  string `json:"sub"`
		Family   string `json:"session_id"`
		Username string `json:"username"`
	}
	if decode(r, &input) != nil {
		fail(w, 400, "invalid_request")
		return
	}
	value, err := s.auth.BrokerSession(r.Context(), input.Code, input.Verifier, input.Subject, input.Family, input.Username)
	if err != nil {
		if errors.Is(err, gravitas.ErrUnavailable) {
			fail(w, 503, "temporarily_unavailable")
		} else {
			fail(w, 403, "broker_login_failed")
		}
		return
	}
	respond(w, 200, map[string]string{"session": value})
}
