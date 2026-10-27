package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

func TestBrowserAndNativeRenewalAfterLoginAccessExpires(t *testing.T) {
	s, _, revoked, _ := fixture(t)
	original := s.auth.HTTP.Transport
	rotations := 0
	s.auth.HTTP.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/oauth/token" {
			return original.RoundTrip(r)
		}
		_ = r.ParseForm()
		ttl := int64(2)
		refresh := "refresh-original"
		if r.Form.Get("grant_type") == "refresh_token" {
			rotations++
			if r.Form.Get("refresh_token") != "refresh-original" || rotations != 1 {
				t.Error("refresh replay reached IAM")
			}
			ttl = 3600
			refresh = "refresh-rotated"
		}
		raw, _ := json.Marshal(map[string]any{"access_token": "upstream-only", "refresh_token": refresh, "expires_in": ttl, "token_type": "Bearer", "session_check_token": base64.RawURLEncoding.EncodeToString(make([]byte, 32)), "session_check_expires_in": 3600, "session_id": "11111111-1111-4111-8111-111111111111"})
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: ioCloser{bytes.NewReader(raw)}}, nil
	})
	started := request(s, "GET", "/auth/gravitas/start", "", "")
	location, _ := url.Parse(started.Header().Get("Location"))
	r := httptest.NewRequest("GET", s.auth.AppURL+"/auth/gravitas/callback?code=code&state="+url.QueryEscape(location.Query().Get("state")), nil)
	for _, cookie := range started.Result().Cookies() {
		r.AddCookie(cookie)
	}
	callback := httptest.NewRecorder()
	s.ServeHTTP(callback, r)
	if callback.Code != 303 {
		t.Fatal(callback.Code, callback.Body.String())
	}
	var envelope *http.Cookie
	for _, cookie := range callback.Result().Cookies() {
		if cookie.Name == gravitas.SessionCookie {
			envelope = cookie
		}
	}
	if envelope == nil {
		t.Fatal("login did not set session")
	}
	got, err := s.auth.DecodeAppSession(envelope.Value)
	if err != nil || got.Authorization.RefreshToken != "refresh-original" {
		t.Fatal("login discarded refresh token", err)
	}
	if got.ExpiresAt.Unix() != got.Authorization.CheckExpires {
		t.Fatal("login still capped before family expiry")
	}
	if request(s, "GET", "/api/session/refresh", "", envelope.Value).Code != 405 {
		t.Fatal("refresh allowed GET")
	}
	denied := httptest.NewRequest("POST", s.auth.AppURL+"/api/session/refresh", nil)
	denied.AddCookie(envelope)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, denied)
	if w.Code != 403 {
		t.Fatal("refresh allowed missing CSRF")
	}
	denied.Header.Set("X-Gravitas-CSRF", "1")
	denied.Header.Set("Origin", "https://evil.example")
	w = httptest.NewRecorder()
	s.ServeHTTP(w, denied)
	if w.Code != 403 {
		t.Fatal("refresh allowed foreign origin")
	}

	time.Sleep(time.Until(time.Unix(got.Authorization.AccessExpires, 0)) + 10*time.Millisecond)
	if request(s, "GET", "/api/groups", "", envelope.Value).Code != 401 {
		t.Fatal("expired access reached upstream")
	}
	browser := httptest.NewRequest("POST", s.auth.AppURL+"/api/session/refresh", nil)
	browser.AddCookie(envelope)
	browser.Header.Set("X-Gravitas-CSRF", "1")
	w = httptest.NewRecorder()
	s.ServeHTTP(w, browser)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	for _, secret := range []string{"upstream-only", "refresh-original", "refresh-rotated", "session"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("browser refresh leaked credential")
		}
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || !cookies[0].Secure {
		t.Fatal("missing secure renewed cookie")
	}
	if request(s, "GET", "/api/groups", "", cookies[0].Value).Code != 200 {
		t.Fatal("renewed cookie did not restore messages")
	}
	native := request(s, "POST", "/api/session/refresh", "", envelope.Value)
	var data map[string]string
	_ = json.Unmarshal(native.Body.Bytes(), &data)
	if native.Code != 200 || data["session"] != cookies[0].Value || rotations != 1 {
		t.Fatal("native renewal/concurrent retry failed", native.Code)
	}
	*revoked = true
	if request(s, "POST", "/api/session/refresh", "", envelope.Value).Code != 401 {
		t.Fatal("revocation bypassed cached renewal")
	}
}
