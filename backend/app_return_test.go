package main

import (
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeApprovalReturnsToAppWithoutCredentials(t *testing.T) {
	s, token, _, _ := fixture(t)
	w := request(s, http.MethodGet, "/auth/native/return?session=untrusted&next=https://evil.test", "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `href="river://auth/native"`) ||
		!strings.Contains(w.Body.String(), "window.location.replace") || strings.Contains(w.Body.String(), "untrusted") || strings.Contains(w.Body.String(), token) {
		t.Fatal("native app return is missing or includes untrusted credentials/destination")
	}
	if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatal("authentication return may be cached or leak referrers")
	}
	if request(s, http.MethodPost, "/auth/native/return", "", "").Code != 405 {
		t.Fatal("return endpoint accepted a mutation")
	}
}

func TestMatrixApprovalReturnsToNativeAppOnSuccessAndDenial(t *testing.T) {
	for _, query := range []string{"&loginToken=private-one-use-token", "&error=access_denied"} {
		s, token, id, proof, _ := matrixFixture(t, "native")
		request(s, "GET", "/matrix/link?id="+id, "", "")
		w := request(s, "GET", "/matrix/callback?id="+id+query, "", "")
		if w.Code != 200 || !strings.Contains(w.Body.String(), `href="river://auth/matrix"`) ||
			strings.Contains(w.Body.String(), "private-one-use-token") || strings.Contains(w.Body.String(), id) {
			t.Fatal("Matrix callback did not safely return to the app")
		}
		poll := request(s, "POST", "/api/matrix/poll", `{"id":"`+id+`","verifier":"`+proof+`"}`, token)
		if strings.Contains(query, "access_denied") {
			if poll.Code != 400 {
				t.Fatal("denied approval was not reported to app")
			}
		} else if poll.Code != 200 || !strings.Contains(poll.Body.String(), "private-one-use-token") {
			t.Fatal("native app cannot redeem successful approval")
		}
		if request(s, "GET", "/matrix/callback?id="+id+query, "", "").Code != 400 {
			t.Fatal("callback replay accepted")
		}
	}
}

func TestApprovalPageOnlyRedirectsAfterExplicitLink(t *testing.T) {
	s, token, _, _ := fixture(t)
	id := random()
	s.pairs[id] = &pairing{Label: "ABCDEF", Expires: matrixIdentity(s).ExpiresAt}
	r := httptest.NewRequest("GET", "https://chat.gravitas.cool/device/link?id="+id, nil)
	r.AddCookie(&http.Cookie{Name: gravitas.SessionCookie, Value: token})
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code == 200 {
		if !strings.Contains(w.Body.String(), "window.location.replace('/auth/native/return')") || s.pairs[id].Session != "" {
			t.Fatal("GET approved a device or omitted the post-approval redirect")
		}
	} else {
		t.Fatal("approval fixture did not authenticate")
	}
}
