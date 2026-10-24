package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

type pairing struct {
	Challenge, Label, Session, Username string
	Register                            bool
	Expires                             time.Time
}
type server struct {
	auth   *gravitas.Client
	static string
	mu     sync.Mutex
	pairs  map[string]*pairing
	files  *signalHub
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var eventPattern = regexp.MustCompile(`^\$[a-zA-Z0-9_.:-]{1,511}$`)
var txnPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)

const scopes = "profile.name chats.list chats.read chats.write groups.create groups.manage groups.join spaces.channels contacts.read contacts.manage calls.read calls.join posts.publish"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func main() {
	a, err := gravitas.New(env("GRAVITAS_ISSUER", "https://gravitas.cool"), env("APP_URL", "https://chat.gravitas.cool"), os.Getenv("GRAVITAS_SESSION_KEY"))
	if err != nil {
		log.Fatal(err)
	}
	a.Scope = scopes
	s := &server{auth: a, static: env("STATIC_DIR", "../client/build/web"), pairs: map[string]*pairing{}}
	go s.rtcReaper(context.Background())
	h := &http.Server{Addr: env("ADDR", ":8080"), Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	log.Printf("River listening on %s", h.Addr)
	log.Fatal(h.ListenAndServe())
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}
func random() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func challenge(s string) string {
	b := sha256.Sum256([]byte(s))
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func decode(r *http.Request, v any) error {
	d := json.NewDecoder(io.LimitReader(r.Body, 40001))
	if err := d.Decode(v); err != nil {
		return err
	}
	var x any
	if d.Decode(&x) != io.EOF {
		return errors.New("invalid JSON")
	}
	return nil
}
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Permissions-Policy", "camera=(self), microphone=(self), display-capture=(self)")
	switch r.URL.Path {
	case "/healthz":
		respond(w, 200, map[string]string{"status": "ok", "app": "River"})
		return
	case "/auth/gravitas/config":
		respond(w, 200, map[string]string{"defaultDomain": s.auth.DefaultDomain()})
		return
	case "/auth/gravitas/start", "/auth/gravitas/register":
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		if err := s.auth.Start(w, r, r.URL.Path == "/auth/gravitas/register"); err != nil {
			if errors.Is(err, gravitas.ErrInvalidUsername) {
				fail(w, 400, err.Error())
				return
			}
			fail(w, 503, "Gravitas sign-in is temporarily unavailable")
		}
		return
	case "/auth/gravitas/callback":
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		a, next, err := s.auth.Callback(w, r)
		if errors.Is(err, gravitas.ErrConsentRequired) || errors.Is(err, gravitas.ErrLoginRequired) {
			http.Redirect(w, r, "/?auto=off", 303)
			return
		}
		if err != nil {
			fail(w, 400, "Sign-in failed. Please start again.")
			return
		}
		if err = s.auth.SetAppSession(w, gravitas.SessionCookie, a, a.AccessToken, time.Now().Add(time.Hour-time.Minute)); err != nil {
			fail(w, 503, "Cannot establish session")
			return
		}
		http.Redirect(w, r, next, 303)
		return
	case "/auth/logout":
		if r.Method != "POST" || !s.auth.ValidMutation(r) {
			fail(w, 403, "Invalid request")
			return
		}
		s.auth.ClearSession(w)
		respond(w, 200, map[string]bool{"ok": true})
		return
	case "/api/native/new":
		s.nativeNew(w, r)
		return
	case "/auth/native/start":
		s.nativeStart(w, r)
		return
	case "/device/link":
		s.nativeFinish(w, r)
		return
	case "/api/native/session":
		s.nativeSession(w, r)
		return
	}
	if upstream, ok := publicRoute(r); ok {
		token := ""
		// Anonymous publication reads work independently of sign-in. A valid
		// session additionally permits this account's private member comments.
		if session, err := s.session(r); err == nil {
			token = session.LocalToken
			r = s.withIssuer(r, session.Authorization.Issuer)
		}
		s.proxy(w, r, token, upstream)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		session, err := s.session(r)
		if err != nil {
			status := 401
			if errors.Is(err, gravitas.ErrUnavailable) {
				status = 503
			}
			fail(w, status, err.Error())
			return
		}
		r = s.withIssuer(r, session.Authorization.Issuer)
		if r.Method != "GET" && !s.auth.ValidMutation(r) {
			fail(w, 403, "Invalid request")
			return
		}
		if room := rtcRoom(r); room != "" {
			s.rtcUpdate(w, r, session, room)
			return
		}
		if room := fileSignalRoom(r); room != "" {
			s.fileSignal(w, r, session, room)
			return
		}
		switch r.URL.Path {
		case "/api/live":
			s.live(w, r, session)
			return
		case "/api/session":
			if r.Method != "GET" {
				w.WriteHeader(405)
				return
			}
			respond(w, 200, map[string]any{"user": session.Authorization.Identity, "expires_at": session.ExpiresAt.Unix()})
			return
		case "/api/rtc":
			if r.Method != "GET" {
				w.WriteHeader(405)
				return
			}
			s.rtc(w, r, session)
			return
		}
		if upstream, ok := proxyRoute(r); ok {
			s.proxy(w, r, session.LocalToken, upstream)
			return
		}
		http.NotFound(w, r)
		return
	}
	if r.URL.Path == "/" && r.Method == "GET" && r.URL.Query().Get("auto") != "off" && gravitas.HasSharedSignInHint(r) {
		if _, err := r.Cookie(gravitas.SessionCookie); err != nil {
			http.Redirect(w, r, "/auth/gravitas/start?prompt=none", 303)
			return
		}
	}
	if r.Method != "GET" && r.Method != "HEAD" {
		w.WriteHeader(405)
		return
	}
	file := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if file == "" {
		file = "index.html"
	}
	if publicPage(r.URL.Path) {
		file = "index.html"
	}
	f, err := os.OpenRoot(s.static)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat(file)
	if err != nil || info.IsDir() {
		http.NotFound(w, r)
		return
	}
	http.ServeFileFS(w, r, f.FS(), file)
}
func (s *server) session(r *http.Request) (gravitas.AppSession, error) {
	if raw := r.Header.Get("Authorization"); strings.HasPrefix(raw, "Bearer ") {
		return s.auth.AuthenticateValue(r.Context(), strings.TrimPrefix(raw, "Bearer "))
	}
	return s.auth.AppSession(r, gravitas.SessionCookie)
}
func publicPage(p string) bool {
	parts := strings.Split(strings.Trim(p, "/"), "/")
	return len(parts) == 2 && parts[0] == "posts" && eventPattern.MatchString(parts[1]) || len(parts) == 3 && parts[0] == "spaces" && uuidPattern.MatchString(parts[1]) && parts[2] == "posts"
}
func publicRoute(r *http.Request) (string, bool) {
	if r.Method != "GET" {
		return "", false
	}
	p := strings.TrimPrefix(r.URL.Path, "/api/public")
	if !strings.HasPrefix(r.URL.Path, "/api/public/") || !publicPage(p) {
		return "", false
	}
	parts := strings.Split(strings.Trim(p, "/"), "/")
	if len(parts) == 2 {
		return "/public/v1/posts/" + url.PathEscape(parts[1]), true
	}
	return "/public/v1/spaces/" + parts[1] + "/posts", true
}
func proxyRoute(r *http.Request) (string, bool) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) == 4 && parts[0] == "api" && parts[1] == "posts" && eventPattern.MatchString(parts[2]) && (parts[3] == "comment" || parts[3] == "reactions") && r.Method == "POST" {
		return "/app/v1/posts/" + url.PathEscape(parts[2]) + "/" + parts[3], true
	}
	if r.URL.Path == "/api/calls" && r.Method == "GET" {
		return "/app/v1/calls", true
	}
	if r.URL.Path == "/api/home" && r.Method == "GET" {
		return "/app/v1/home", true
	}
	if r.URL.Path == "/api/conversations" && r.Method == "POST" {
		return "/app/v1/conversations", true
	}
	if r.URL.Path == "/api/presence" && r.Method == "GET" {
		return "/app/v1/presence", true
	}
	if r.URL.Path == "/api/overview" && r.Method == "GET" {
		return "/app/v1/overview", true
	}
	if r.URL.Path == "/api/friends" && (r.Method == "GET" || r.Method == "POST") {
		return "/app/v1/friends", true
	}
	if r.URL.Path == "/api/friends/events" && r.Method == "GET" {
		return "/app/v1/friends/events", true
	}
	if r.URL.Path == "/api/direct" && r.Method == "POST" {
		return "/app/v1/direct", true
	}
	if len(parts) == 2 && parts[0] == "api" && parts[1] == "groups" && (r.Method == "GET" || r.Method == "POST") {
		return "/app/v1/groups", true
	}
	if len(parts) < 3 || parts[0] != "api" || parts[1] != "groups" || !uuidPattern.MatchString(parts[2]) {
		return "", false
	}
	if len(parts) == 3 && r.Method == "PATCH" {
		return "/app/v1/groups/" + parts[2], true
	}
	if len(parts) == 4 && parts[3] == "publication" && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/publication", true
	}
	if len(parts) == 4 && parts[3] == "files" && r.Method == "GET" {
		return "/app/v1/groups/" + parts[2] + "/files", true
	}
	if len(parts) == 4 && parts[3] == "invitations" && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/invitations", true
	}
	if len(parts) == 5 && parts[3] == "entry" && parts[4] == "read" && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/entry/read", true
	}
	if len(parts) == 4 && parts[3] == "membership" && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/membership", true
	}
	if len(parts) == 4 && parts[3] == "channels" && (r.Method == "GET" || r.Method == "POST") {
		return "/app/v1/groups/" + parts[2] + "/channels", true
	}
	if len(parts) == 4 && parts[3] == "read" && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/read", true
	}
	if len(parts) == 4 && parts[3] == "entries" && r.Method == "GET" {
		return "/app/v1/groups/" + parts[2] + "/entries", true
	}
	if len(parts) == 4 && parts[3] == "thread" && r.Method == "GET" {
		return "/app/v1/groups/" + parts[2] + "/thread", true
	}
	if len(parts) == 4 && (parts[3] == "reactions" || parts[3] == "entry") && r.Method == "POST" {
		return "/app/v1/groups/" + parts[2] + "/" + parts[3], true
	}
	if len(parts) == 4 && parts[3] == "events" && r.Method == "GET" {
		return "/app/v1/groups/" + parts[2] + "/events", true
	}
	if len(parts) == 6 && parts[3] == "events" && r.Method == "PUT" && txnPattern.MatchString(parts[5]) {
		switch parts[4] {
		case "m.room.message", "m.reaction", "cool.gravitas.river.post.v1", "cool.gravitas.river.discussion.v1":
			return "/app/v1/groups/" + parts[2] + "/events/" + url.PathEscape(parts[4]) + "/" + parts[5], true
		}
	}
	return "", false
}
func (s *server) proxy(w http.ResponseWriter, r *http.Request, token, upstream string) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 300001))
	if err != nil || len(raw) > 300000 {
		fail(w, 413, "Request is too large")
		return
	}
	q := url.Values{}
	for _, key := range []string{"limit", "before", "event_id", "file_id", "kind"} {
		if value := r.URL.Query().Get(key); value != "" {
			q.Set(key, value)
		}
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, s.upstream(r.Context()).Issuer+upstream+"?"+q.Encode(), bytes.NewReader(raw))
	if err != nil {
		fail(w, 400, "Invalid request")
		return
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := s.upstream(r.Context()).HTTP.Do(req)
	if err != nil {
		fail(w, 503, "Gravitas is temporarily unavailable")
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, (2<<20)+1))
	if err != nil || len(body) > 2<<20 || !json.Valid(body) {
		fail(w, 502, "Invalid Gravitas response")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}
func (s *server) nativeNew(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	var input struct {
		Challenge string `json:"challenge"`
		Username  string `json:"username"`
		Register  bool   `json:"register"`
	}
	if decode(r, &input) != nil {
		fail(w, 400, "Invalid request")
		return
	}
	_, username, resolveErr := s.auth.ResolveLogin(input.Username, input.Register)
	if resolveErr != nil {
		fail(w, 400, "Use a username or user@domain")
		return
	}
	b, err := base64.RawURLEncoding.DecodeString(input.Challenge)
	if err != nil || len(b) != 32 {
		fail(w, 400, "Invalid challenge")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, p := range s.pairs {
		if !p.Expires.After(time.Now()) {
			delete(s.pairs, id)
		}
	}
	if len(s.pairs) >= 1024 {
		fail(w, 429, "Please try again later")
		return
	}
	id := random()
	label := strings.ToUpper(id[:6])
	s.pairs[id] = &pairing{Username: username, Register: input.Register, Challenge: input.Challenge, Label: label, Expires: time.Now().Add(5 * time.Minute)}
	respond(w, 200, map[string]string{"id": id, "label": label, "url": s.auth.AppURL + "/auth/native/start?id=" + id})
}
func (s *server) nativeStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		w.WriteHeader(405)
		return
	}
	id := r.URL.Query().Get("id")
	s.mu.Lock()
	p := s.pairs[id]
	valid := p != nil && p.Expires.After(time.Now()) && p.Session == ""
	s.mu.Unlock()
	if !valid {
		fail(w, 400, "Device request expired")
		return
	}
	clone := r.Clone(r.Context())
	u := *r.URL
	clone.URL = &u
	clone.URL.RawQuery = url.Values{"next": {"/device/link?id=" + id}, "username": {p.Username}}.Encode()
	if err := s.auth.Start(w, clone, p.Register); err != nil {
		fail(w, 503, "Sign-in is temporarily unavailable")
	}
}
func (s *server) nativeFinish(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if r.Method == "POST" && !s.auth.ValidMutation(r) {
		fail(w, 403, "Invalid request")
		return
	}
	if _, err := s.auth.AppSession(r, gravitas.SessionCookie); err != nil {
		fail(w, 401, "Sign in again")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	id := r.URL.Query().Get("id")
	p := s.pairs[id]
	if p == nil || !p.Expires.After(time.Now()) {
		fail(w, 400, "Device request expired")
		return
	}
	if r.Method == "POST" {
		c, _ := r.Cookie(gravitas.SessionCookie)
		p.Session = c.Value
		respond(w, 200, map[string]bool{"linked": true})
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = fmt.Fprintf(w, `<!doctype html><html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Link River</title><body style="font:18px system-ui;max-width:36rem;margin:10vh auto;padding:24px;background:#f3f7ff;color:#142744"><h1>Link your River app</h1><p>Only continue if your River app shows <strong>%s</strong>.</p><p>This device will use the group and chat permissions you approved.</p><button id="link" style="padding:16px;background:#185adb;color:white;border:0;border-radius:12px">Link this River device</button><p id="result"></p><script>document.getElementById('link').onclick=async()=>{let r=await fetch('/device/link?id=%s',{method:'POST',headers:{'X-Gravitas-CSRF':'1'}});document.getElementById('result').textContent=r.ok?'Linked. Return to River.':'Request failed. Start again.';document.getElementById('link').disabled=r.ok}</script></body></html>`, p.Label, id)
}
func (s *server) nativeSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	var input struct {
		ID       string `json:"id"`
		Verifier string `json:"verifier"`
	}
	if decode(r, &input) != nil || len(input.Verifier) != 43 {
		fail(w, 400, "Invalid request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.pairs[input.ID]
	if p == nil || !p.Expires.After(time.Now()) || subtle.ConstantTimeCompare([]byte(p.Challenge), []byte(challenge(input.Verifier))) != 1 {
		fail(w, 403, "Device request invalid or expired")
		return
	}
	if p.Session == "" {
		respond(w, 202, map[string]string{"status": "pending"})
		return
	}
	value := p.Session
	delete(s.pairs, input.ID)
	respond(w, 200, map[string]string{"session": value})
}

// The selected issuer comes only from a verified app session.
type upstreamIssuerKey struct{}

func (s *server) withIssuer(r *http.Request, issuer string) *http.Request {
	selected, err := s.auth.ForIssuer(issuer)
	if err != nil {
		return r
	}
	return r.WithContext(context.WithValue(r.Context(), upstreamIssuerKey{}, selected))
}
func (s *server) upstream(ctx context.Context) *gravitas.Client {
	if selected, ok := ctx.Value(upstreamIssuerKey{}).(*gravitas.Client); ok {
		return selected
	}
	return s.auth
}
