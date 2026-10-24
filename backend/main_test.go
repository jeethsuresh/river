package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"net/http"
	"net/http/httptest"
	"net/url"
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
		case "/oauth/token":
			respond(w, 200, map[string]any{"access_token": "upstream-only", "token_type": "Bearer", "session_check_token": base64.RawURLEncoding.EncodeToString(make([]byte, 32)), "session_check_expires_in": 3600, "session_id": "11111111-1111-4111-8111-111111111111"})
		case "/app/v1/me":
			origin, _ := url.Parse(iam.URL)
			respond(w, 200, map[string]string{"sub": "alice", "username": "alice", "domain": origin.Hostname(), "user_id": "@alice:" + origin.Hostname()})
		case "/oauth/session":
			checks++
			if revoked {
				w.WriteHeader(401)
				return
			}
			respond(w, 200, map[string]any{"active": true, "iss": iam.URL, "sub": "alice", "app_origin": "https://chat.gravitas.cool", "session_id": "11111111-1111-4111-8111-111111111111", "exp": time.Now().Add(time.Hour).Unix()})
		case "/app/v1/rtc":
			respond(w, 200, map[string]bool{"allow_ice": true, "allow_calls": true})
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
	r := httptest.NewRequest("POST", "https://chat.gravitas.cool/device/link?id="+p["id"], nil)
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
	login, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	requested := " " + login.Query().Get("scope") + " "
	for _, permission := range []string{"contacts.read", "contacts.manage"} {
		if !strings.Contains(requested, " "+permission+" ") {
			t.Fatalf("contact consent missing: %s", permission)
		}
	}
	if strings.Contains(requested, " friends.") {
		t.Fatal("legacy friend scopes requested instead of contact consent")
	}
	w = request(s, "GET", "/api/rtc", "", token)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Fatal("RTC capability misreported")
	}
}

func TestNativeBrowserHandoffReturnsToConfirmation(t *testing.T) {
	s, _, _, _ := fixture(t)
	body, _ := json.Marshal(map[string]string{"challenge": challenge(random())})
	created := request(s, "POST", "/api/native/new", string(body), "")
	var pair map[string]string
	if err := json.Unmarshal(created.Body.Bytes(), &pair); err != nil {
		t.Fatal(err)
	}
	started := request(s, "GET", "/auth/native/start?id="+pair["id"], "", "")
	if started.Code != 303 {
		t.Fatal(started.Code, started.Body.String())
	}
	location, err := url.Parse(started.Header().Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "https://chat.gravitas.cool/auth/gravitas/callback?code=test-code&state="+url.QueryEscape(location.Query().Get("state")), nil)
	for _, c := range started.Result().Cookies() {
		r.AddCookie(c)
	}
	completed := httptest.NewRecorder()
	s.ServeHTTP(completed, r)
	expected := "/device/link?id=" + pair["id"]
	if completed.Code != 303 || completed.Header().Get("Location") != expected {
		t.Fatal("native login lost its confirmation destination", completed.Code, completed.Header().Get("Location"))
	}
	r = httptest.NewRequest("GET", "https://chat.gravitas.cool"+expected, nil)
	for _, c := range completed.Result().Cookies() {
		if c.Name == gravitas.SessionCookie {
			r.AddCookie(c)
		}
	}
	confirmed := httptest.NewRecorder()
	s.ServeHTTP(confirmed, r)
	if confirmed.Code != 200 || !strings.Contains(confirmed.Body.String(), pair["label"]) {
		t.Fatal("confirmation page unavailable", confirmed.Code)
	}
}

func TestChannelAndFriendRelayRoutes(t *testing.T) {
	id := "11111111-1111-4111-8111-111111111111"
	for _, c := range []struct{ method, path, upstream string }{
		{"GET", "/api/overview", "/app/v1/overview"},
		{"GET", "/api/friends", "/app/v1/friends"},
		{"POST", "/api/friends", "/app/v1/friends"},
		{"GET", "/api/friends/events", "/app/v1/friends/events"},
		{"POST", "/api/direct", "/app/v1/direct"},
		{"GET", "/api/groups/" + id + "/channels", "/app/v1/groups/" + id + "/channels"},
		{"POST", "/api/groups/" + id + "/channels", "/app/v1/groups/" + id + "/channels"},
		{"POST", "/api/groups/" + id + "/read", "/app/v1/groups/" + id + "/read"},
		{"GET", "/api/groups/" + id + "/thread", "/app/v1/groups/" + id + "/thread"},
		{"POST", "/api/groups/" + id + "/reactions", "/app/v1/groups/" + id + "/reactions"},
		{"POST", "/api/groups/" + id + "/entry", "/app/v1/groups/" + id + "/entry"},
	} {
		r := httptest.NewRequest(c.method, "https://chat.gravitas.cool"+c.path, nil)
		upstream, ok := proxyRoute(r)
		if !ok || upstream != c.upstream {
			t.Fatalf("route %s %s: %q %v", c.method, c.path, upstream, ok)
		}
		for _, badMethod := range []string{"DELETE", "TRACE", "PATCH"} {
			r.Method = badMethod
			if _, ok := proxyRoute(r); ok {
				t.Fatalf("unexpected method %s on %s", badMethod, c.path)
			}
		}
	}
	s, token, revoked, _ := fixture(t)
	*revoked = true
	for _, p := range []string{"/api/overview", "/api/friends", "/api/friends/events", "/api/groups/" + id + "/channels", "/api/groups/" + id + "/thread", "/api/groups/" + id + "/reactions", "/api/groups/" + id + "/entry"} {
		if w := request(s, "GET", p, "", token); w.Code != 401 {
			t.Fatalf("revoked session reached %s: %d", p, w.Code)
		}
	}
}
