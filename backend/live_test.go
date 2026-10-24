package main

import (
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLiveRelayOnlyForwardsInvalidationProtocol(t *testing.T) {
	s := &server{auth: &gravitas.Client{Issuer: "https://gravitas.test", HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/app/v1/live" || r.Header.Get("Authorization") != "Bearer private" {
			t.Fatal("not pinned")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/event-stream"}}, Body: io.NopCloser(strings.NewReader("event: ready\ndata: {}\n\nevent: invalidate\ndata: {\"private\":true}\n\nevent: revoked\ndata: {}\n\n"))}, nil
	})}}}
	w := httptest.NewRecorder()
	s.live(w, httptest.NewRequest("GET", "/api/live", nil), gravitas.AppSession{LocalToken: "private", ExpiresAt: time.Now().Add(time.Minute)})
	if w.Code != 200 || !strings.Contains(w.Body.String(), "event: invalidate") || strings.Contains(w.Body.String(), "private") {
		t.Fatal(w.Body.String())
	}
}
func TestWorkspaceRelayRoutesStayNarrow(t *testing.T) {
	for _, tc := range []struct{ method, path, want string }{
		{"GET", "/api/home", "/app/v1/home"}, {"POST", "/api/conversations", "/app/v1/conversations"},
		{"POST", "/api/groups/00000000-0000-0000-0000-000000000001/invitations", "/app/v1/groups/00000000-0000-0000-0000-000000000001/invitations"},
		{"POST", "/api/groups/00000000-0000-0000-0000-000000000001/entry/read", "/app/v1/groups/00000000-0000-0000-0000-000000000001/entry/read"},
		{"POST", "/api/home", ""}, {"DELETE", "/api/conversations", ""}, {"GET", "/api/groups/nope/invitations", ""},
	} {
		got, _ := proxyRoute(httptest.NewRequest(tc.method, tc.path, nil))
		if got != tc.want {
			t.Fatalf("%s: %s", tc.path, got)
		}
	}
}
