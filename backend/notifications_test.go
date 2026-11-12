package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIOSNotificationRegistrationUsesAuthenticatedRiverSession(t *testing.T) {
	s, session, revoked, _ := fixture(t)
	key := strings.Repeat("n", 48)
	t.Setenv("NOTIFICATION_PROVIDER_KEY", key)
	s.notificationStore = "https://apps.gravitas.cool"
	transport := s.auth.HTTP.Transport
	forwarded := 0
	s.auth.HTTP.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "apps.gravitas.cool" {
			return transport.RoundTrip(r)
		}
		forwarded++
		if !strings.HasPrefix(r.URL.Path, "/v1/notification-installations/river/") ||
			!notificationProviderID.MatchString(strings.TrimPrefix(r.URL.Path, "/v1/notification-installations/river/")) ||
			r.Header.Get("Authorization") != "Bearer "+key {
			t.Fatal("registration was not scoped to River")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if r.Method == "DELETE" && body["session_proof"] == nil {
			return &http.Response{StatusCode: 204, Body: http.NoBody}, nil
		}
		if r.Method != "PUT" || body["session_proof"] != base64.RawURLEncoding.EncodeToString(make([]byte, 32)) ||
			body["platform"] != "ios" || body["environment"] != "production" {
			t.Fatal("registration used incorrect identity or environment")
		}
		return &http.Response{StatusCode: 200, Body: http.NoBody}, nil
	})
	installation := strings.Repeat("a", 64)
	body := `{"installation":"` + installation + `","generation":1,"environment":"production","token":"abcdef"}`
	if w := request(s, "PUT", "/api/notifications/ios", body, ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	if w := request(s, "PUT", "/api/notifications/ios", body, session); w.Code != 204 {
		t.Fatal(w.Code, w.Body)
	}
	if w := request(s, "DELETE", "/api/notifications/ios", `{"installation":"`+installation+`","generation":2}`, session); w.Code != 204 {
		t.Fatal(w.Code, w.Body)
	}
	*revoked = true
	if w := request(s, "PUT", "/api/notifications/ios", body, session); w.Code != 401 || forwarded != 2 {
		t.Fatal("revoked session was forwarded", w.Code, forwarded)
	}
}

func TestNotificationProviderReconciliation(t *testing.T) {
	s, _, _, _ := fixture(t)
	t.Setenv("NOTIFICATION_PROVIDER_KEY", strings.Repeat("k", 48))
	body := `{"issuer":"` + s.auth.Issuer + `","subject":"11111111-1111-4111-8111-111111111111","enabled":true,"protocol":"appstore/1.0.0","callback":""}`
	call := func(method, key, value string) int {
		r := httptest.NewRequest(method, "/api/notifications/providers/"+strings.Repeat("a", 64), strings.NewReader(value))
		r.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		return w.Code
	}
	if n := call("PUT", strings.Repeat("k", 48), body); n != 204 {
		t.Fatal(n)
	}
	if n := call("PUT", strings.Repeat("k", 48), strings.Replace(body, `"enabled":true`, `"enabled":false`, 1)); n != 204 {
		t.Fatal(n)
	}
	if n := call("PUT", "wrong", body); n != 401 {
		t.Fatal(n)
	}
	if n := call("POST", strings.Repeat("k", 48), body); n != 405 {
		t.Fatal(n)
	}
	for _, bad := range []string{strings.Replace(body, s.auth.Issuer, "https://evil.example", 1), strings.Replace(body, `"callback":""`, `"callback":"https://evil.example"`, 1), strings.Replace(body, "appstore/1.0.0", "appstore/2.0.0", 1), strings.Replace(body, "11111111-1111-4111-8111-111111111111", "invalid", 1)} {
		if n := call("PUT", strings.Repeat("k", 48), bad); n != 400 {
			t.Fatal(n)
		}
	}
	t.Setenv("NOTIFICATION_PROVIDER_KEY", "")
	if n := call("PUT", "", body); n != 401 {
		t.Fatal(n)
	}
}
