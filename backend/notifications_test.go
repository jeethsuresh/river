package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

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
