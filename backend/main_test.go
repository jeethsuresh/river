package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) (*server, string, *bool, *int) {
	t.Helper()
	revoked := false
	checks := 0
	var iam *httptest.Server
	iam = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/iam-configuration":
			respond(w, 200, map[string]string{"issuer": iam.URL, "identity_domain": strings.TrimPrefix(iam.URL, "https://"), "browser_initiation_endpoint": iam.URL + "/oauth/start", "token_endpoint": iam.URL + "/oauth/token", "userinfo_endpoint": iam.URL + "/app/v1/me", "session_check_endpoint": iam.URL + "/oauth/session"})
		case "/oauth/session":
			checks++
			if revoked {
				w.WriteHeader(401)
				return
			}
			respond(w, 200, map[string]any{"active": true, "iss": iam.URL, "sub": "alice", "app_origin": "https://chat.gravitas.cool", "session_id": "11111111-1111-4111-8111-111111111111", "exp": time.Now().Add(time.Hour).Unix()})
		case "/app/v1/groups":
			if r.Header.Get("Authorization") != "Bearer upstream-only" {
				t.Error("wrong upstream credential")
			}
			respond(w, 200, map[string]any{"groups": []any{}})
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(iam.Close)
	a, err := gravitas.New(iam.URL, "https://chat.gravitas.cool", base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	// Discovery domain uses hostname, not host:port.
	a.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		response, err := iam.Client().Do(r)
		if err == nil && r.URL.Path == "/.well-known/iam-configuration" {
			response.Body.Close()
			raw, _ := json.Marshal(map[string]string{"issuer": iam.URL, "identity_domain": r.URL.Hostname(), "browser_initiation_endpoint": iam.URL + "/oauth/start", "token_endpoint": iam.URL + "/oauth/token", "userinfo_endpoint": iam.URL + "/app/v1/me", "session_check_endpoint": iam.URL + "/oauth/session"})
			response.Body = ioCloser{bytes.NewReader(raw)}
		}
		return response, err
	})}
	a.Scope = scopes
	auth := gravitas.Authorization{Identity: gravitas.Identity{Issuer: iam.URL, Subject: "alice", Username: "alice"}, CheckToken: base64.RawURLEncoding.EncodeToString(make([]byte, 32)), SessionID: "11111111-1111-4111-8111-111111111111", CheckExpires: time.Now().Add(time.Hour).Unix()}
	w := httptest.NewRecorder()
	if err := a.SetAppSession(w, gravitas.SessionCookie, auth, "upstream-only", time.Now().Add(30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	return &server{auth: a, static: t.TempDir(), pairs: map[string]*pairing{}}, w.Result().Cookies()[0].Value, &revoked, &checks
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type ioCloser struct{ *bytes.Reader }

func (ioCloser) Close() error { return nil }
func request(s *server, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "https://chat.gravitas.cool"+path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Gravitas-CSRF", "1")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func TestPinnedRelayAndRevocation(t *testing.T) {
	s, token, revoked, checks := fixture(t)
	for range 2 {
		w := request(s, "GET", "/api/groups", "", token)
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), "upstream-only") {
			t.Fatal("token leaked")
		}
	}
	if *checks != 2 {
		t.Fatal("authorization was cached")
	}
	*revoked = true
	if w := request(s, "GET", "/api/groups", "", token); w.Code != 401 {
		t.Fatal(w.Code)
	}
}
func TestNativePairingNeedsProofAndExplicitApproval(t *testing.T) {
	s, token, _, _ := fixture(t)
	proof := random()
	body, _ := json.Marshal(map[string]string{"challenge": challenge(proof)})
	w := request(s, "POST", "/api/native/new", string(body), "")
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	var p map[string]string
	json.Unmarshal(w.Body.Bytes(), &p)
	poll := func(verifier string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(map[string]string{"id": p["id"], "verifier": verifier})
		return request(s, "POST", "/api/native/session", string(b), "")
	}
	if poll(random()).Code != 403 || poll(proof).Code != 202 {
		t.Fatal("pairing proof/pending failure")
	}
	r := httptest.NewRequest("POST", "https://chat.gravitas.cool/auth/native/finish?id="+p["id"], nil)
	r.AddCookie(&http.Cookie{Name: gravitas.SessionCookie, Value: token})
	r.Header.Set("X-Gravitas-CSRF", "1")
	r.Header.Set("Origin", "https://evil.example")
	w = httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin approval accepted")
	}
	r.Header.Set("Origin", s.auth.AppURL)
	w = httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	w = poll(proof)
	if w.Code != 200 || !strings.Contains(w.Body.String(), token) {
		t.Fatal("approved device did not receive session")
	}
	if poll(proof).Code != 403 {
		t.Fatal("pairing replay accepted")
	}
}
func TestRouteAndStaticBoundaries(t *testing.T) {
	s, token, _, _ := fixture(t)
	os.WriteFile(filepath.Join(s.static, "index.html"), []byte("River"), 0600)
	if request(s, "GET", "/", "", "").Code != 200 || request(s, "GET", "/api/groups", "", "").Code != 401 {
		t.Fatal("auth boundary")
	}
	for _, p := range []string{"/api/groups/nope/events", "/api/groups/11111111-1111-4111-8111-111111111111/events/m.room.member/txn", "/api/admin"} {
		if request(s, "PUT", p, `{}`, token).Code != 404 {
			t.Fatal("unexpected proxy route", p)
		}
	}
	r := httptest.NewRequest("POST", "https://chat.gravitas.cool/api/groups", strings.NewReader(`{}`))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("CSRF was optional")
	}
	w = request(s, "GET", "/auth/gravitas/start", "", "")
	if w.Code != 303 || !strings.Contains(w.Header().Get("Location"), "groups.create") {
		t.Fatal("delegation scopes missing", w.Code)
	}
	w = request(s, "GET", "/api/rtc", "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Fatal("RTC capability misreported")
	}
}
