package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

func matrixIdentity(s *server) gravitas.AppSession {
	return gravitas.AppSession{
		Authorization: gravitas.Authorization{
			Identity:   gravitas.Identity{Issuer: s.auth.Issuer, Subject: "alice", Username: "alice", Domain: "example.test", UserID: "@alice:example.test"},
			CheckToken: base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
			SessionID:  "11111111-1111-4111-8111-111111111111", CheckExpires: time.Now().Add(time.Hour).Unix(),
		},
		LocalToken: "upstream-only", ExpiresAt: time.Now().Add(30 * time.Minute),
	}
}

func matrixFixture(t *testing.T, platform string) (*server, string, string, string, *bool) {
	t.Helper()
	s, _, revoked, _ := fixture(t)
	identity := matrixIdentity(s)
	w := httptest.NewRecorder()
	if err := s.auth.SetAppSession(w, gravitas.SessionCookie, identity.Authorization, identity.LocalToken, identity.ExpiresAt); err != nil {
		t.Fatal(err)
	}
	token := w.Result().Cookies()[0].Value
	proof := strings.Repeat("a", 43)
	w = request(s, "POST", "/api/matrix/link", `{"challenge":"`+challenge(proof)+`","platform":"`+platform+`"}`, token)
	if w.Code != 200 {
		t.Fatalf("new Matrix link: %d %s", w.Code, w.Body.String())
	}
	var data map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if data["homeserver"] != s.auth.Issuer || data["user_id"] != identity.Authorization.UserID || strings.Contains(w.Body.String(), "upstream-only") {
		t.Fatal("wrong Matrix account binding or leaked delegated credential")
	}
	return s, token, data["id"].(string), proof, revoked
}

func TestMatrixLinkRequiresProofAndMatchingCentralSession(t *testing.T) {
	s, token, id, proof, revoked := matrixFixture(t, "native")
	poll := func(verifier string) *httptest.ResponseRecorder {
		return request(s, "POST", "/api/matrix/poll", `{"id":"`+id+`","verifier":"`+verifier+`"}`, token)
	}
	if w := poll(proof); w.Code != 200 || !strings.Contains(w.Body.String(), `"pending":true`) {
		t.Fatal("pending link did not wait")
	}
	if w := poll(strings.Repeat("b", 43)); w.Code != 403 {
		t.Fatal("wrong verifier accepted")
	}
	w := request(s, "GET", "/matrix/link?id="+id, "", "")
	location, _ := url.Parse(w.Header().Get("Location"))
	if w.Code != 303 || !strings.HasPrefix(location.String(), s.auth.Issuer+"/_matrix/client/v3/login/sso/redirect?") || location.Query().Get("redirectUrl") != "https://chat.gravitas.cool/matrix/callback?id="+id {
		t.Fatal("SSO did not use the bound issuer and fixed callback")
	}
	if w := request(s, "GET", "/matrix/link?id="+id, "", ""); w.Code != 400 {
		t.Fatal("SSO start replay accepted")
	}
	w = request(s, "GET", "/matrix/callback?id="+id+"&loginToken=one-use-matrix-token", "", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "one-use-matrix-token") || w.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatal("native completion leaked the login token")
	}
	if w := request(s, "GET", "/matrix/callback?id="+id+"&loginToken=replaced", "", ""); w.Code != 400 {
		t.Fatal("callback replaced a completed login token")
	}
	for _, change := range []func(*gravitas.AppSession){
		func(a *gravitas.AppSession) { a.Authorization.Subject = "bob" },
		func(a *gravitas.AppSession) { a.Authorization.Issuer = "https://other.example" },
		func(a *gravitas.AppSession) { a.Authorization.UserID = "@bob:example.test" },
		func(a *gravitas.AppSession) { a.Authorization.SessionID = "other-session" },
	} {
		other := matrixIdentity(s)
		change(&other)
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/api/matrix/poll", strings.NewReader(`{"id":"`+id+`","verifier":"`+proof+`"}`))
		s.matrixPoll(w, r, other)
		if w.Code != 403 {
			t.Fatal("cross-account/session Matrix token redemption accepted")
		}
	}
	*revoked = true
	if w := poll(proof); w.Code != 401 {
		t.Fatal("revoked central session redeemed a Matrix login token")
	}
	*revoked = false
	w = poll(proof)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"login_token":"one-use-matrix-token"`) {
		t.Fatal("proof holder could not finish Matrix login")
	}
	if w := poll(proof); w.Code != 403 {
		t.Fatal("Matrix login token redemption replay accepted")
	}
}

func TestMatrixLinkWebCallbackAndExpiry(t *testing.T) {
	s, token, id, proof, _ := matrixFixture(t, "web")
	request(s, "GET", "/matrix/link?id="+id, "", "")
	w := request(s, "GET", "/matrix/callback?id="+id+"&loginToken=private", "", "")
	if w.Code != 303 || w.Header().Get("Location") != "https://chat.gravitas.cool/?matrixLink="+id || strings.Contains(w.Body.String(), "private") {
		t.Fatal("browser callback did not remove the Matrix token")
	}
	s.matrixLinks[id].Expires = time.Now().Add(-time.Second)
	w = request(s, "POST", "/api/matrix/poll", `{"id":"`+id+`","verifier":"`+proof+`"}`, token)
	if w.Code != 403 || len(s.matrixLinks) != 0 {
		t.Fatal("expired link remained usable")
	}
}

func TestMatrixLinkInputAndResourceBounds(t *testing.T) {
	s, token, _, _, _ := matrixFixture(t, "web")
	for _, body := range []string{`{}`, `{"challenge":"bad","platform":"web"}`, `{"challenge":"` + challenge(strings.Repeat("a", 43)) + `","platform":"other"}`} {
		if w := request(s, "POST", "/api/matrix/link", body, token); w.Code != 400 {
			t.Fatal("invalid Matrix link accepted")
		}
	}
	for i := 0; i < 7; i++ {
		if w := request(s, "POST", "/api/matrix/link", `{"challenge":"`+challenge(strings.Repeat("a", 43))+`","platform":"web"}`, token); w.Code != 200 {
			t.Fatal("valid link unexpectedly rejected")
		}
	}
	if w := request(s, "POST", "/api/matrix/link", `{"challenge":"`+challenge(strings.Repeat("a", 43))+`","platform":"web"}`, token); w.Code != 429 {
		t.Fatal("per-account pending-link limit was not enforced")
	}
	if w := request(s, "POST", "/api/matrix/link", `{}`, ""); w.Code != 401 {
		t.Fatal("anonymous Matrix link created")
	}
}
