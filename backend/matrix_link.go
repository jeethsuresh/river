package main

import (
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

// Only the short-lived Matrix SSO login token crosses this broker. Matrix access
// credentials and private encryption keys are created and retained by the client.
type matrixLink struct {
	Challenge, Issuer, Subject, UserID, SessionID, Platform string
	Expires                                                 time.Time
	Started, Completed                                      bool
	Token, Error                                            string
}

func (s *server) pruneMatrixLinks() {
	for id, link := range s.matrixLinks {
		if !link.Expires.After(time.Now()) {
			delete(s.matrixLinks, id)
		}
	}
}

func (s *server) matrixNew(w http.ResponseWriter, r *http.Request, session gravitas.AppSession) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		Challenge string `json:"challenge"`
		Platform  string `json:"platform"`
	}
	if decode(r, &input) != nil || (input.Platform != "web" && input.Platform != "native") {
		fail(w, 400, "invalid_request")
		return
	}
	proof, err := base64.RawURLEncoding.DecodeString(input.Challenge)
	identity := session.Authorization.Identity
	if err != nil || len(proof) != 32 || !strings.HasPrefix(identity.UserID, "@") || !strings.Contains(identity.UserID, ":") {
		fail(w, 400, "invalid_request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.matrixLinks == nil {
		s.matrixLinks = map[string]*matrixLink{}
	}
	s.pruneMatrixLinks()
	count := 0
	for _, link := range s.matrixLinks {
		if link.Issuer == identity.Issuer && link.Subject == identity.Subject {
			count++
		}
	}
	if count >= 8 || len(s.matrixLinks) >= 256 {
		fail(w, 429, "too_many_requests")
		return
	}
	expires := time.Now().Add(5 * time.Minute)
	if session.ExpiresAt.Before(expires) {
		expires = session.ExpiresAt
	}
	id := random()
	s.matrixLinks[id] = &matrixLink{
		Challenge: input.Challenge, Issuer: identity.Issuer, Subject: identity.Subject,
		UserID: identity.UserID, SessionID: session.Authorization.SessionID,
		Platform: input.Platform, Expires: expires,
	}
	respond(w, 200, map[string]any{
		"id": id, "url": s.auth.AppURL + "/matrix/link?id=" + url.QueryEscape(id),
		"homeserver": identity.Issuer, "user_id": identity.UserID,
		"expires_at": expires.Unix(),
	})
}

func (s *server) matrixStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	id := r.URL.Query().Get("id")
	s.mu.Lock()
	s.pruneMatrixLinks()
	link := s.matrixLinks[id]
	if link == nil || link.Started {
		s.mu.Unlock()
		fail(w, 400, "expired_matrix_link")
		return
	}
	link.Started = true
	issuer := link.Issuer
	s.mu.Unlock()
	callback := s.auth.AppURL + "/matrix/callback?id=" + url.QueryEscape(id)
	http.Redirect(w, r, strings.TrimRight(issuer, "/")+"/_matrix/client/v3/login/sso/redirect?"+url.Values{
		"redirectUrl": {callback},
	}.Encode(), http.StatusSeeOther)
}

func (s *server) matrixCallback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	id, token := r.URL.Query().Get("id"), r.URL.Query().Get("loginToken")
	s.mu.Lock()
	s.pruneMatrixLinks()
	link := s.matrixLinks[id]
	if link == nil || !link.Started || link.Completed || len(token) > 2048 {
		s.mu.Unlock()
		fail(w, 400, "expired_matrix_link")
		return
	}
	link.Completed = true
	if token == "" || r.URL.Query().Get("error") != "" {
		link.Error = "matrix_login_failed"
	} else {
		link.Token = token
	}
	platform := link.Platform
	s.mu.Unlock()
	if platform == "web" {
		http.Redirect(w, r, s.auth.AppURL+"/?matrixLink="+url.QueryEscape(id), http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte("<!doctype html><html><meta name=viewport content='width=device-width,initial-scale=1'><title>River sign-in</title><p>Matrix sign-in finished. Return to River to continue.</p></html>"))
}

func (s *server) matrixPoll(w http.ResponseWriter, r *http.Request, session gravitas.AppSession) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		ID       string `json:"id"`
		Verifier string `json:"verifier"`
	}
	if decode(r, &input) != nil || len(input.Verifier) < 43 || len(input.Verifier) > 128 {
		fail(w, 400, "invalid_request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneMatrixLinks()
	link := s.matrixLinks[input.ID]
	identity := session.Authorization.Identity
	if link == nil || link.Issuer != identity.Issuer || link.Subject != identity.Subject ||
		link.UserID != identity.UserID || link.SessionID != session.Authorization.SessionID ||
		subtle.ConstantTimeCompare([]byte(link.Challenge), []byte(challenge(input.Verifier))) != 1 {
		fail(w, 403, "invalid_matrix_link")
		return
	}
	if !link.Completed {
		respond(w, 200, map[string]bool{"pending": true})
		return
	}
	delete(s.matrixLinks, input.ID)
	if link.Error != "" {
		fail(w, 400, link.Error)
		return
	}
	respond(w, 200, map[string]string{"login_token": link.Token, "homeserver": link.Issuer, "user_id": link.UserID})
}
