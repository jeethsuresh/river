package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicRoutesAreFixedAndReadOnly(t *testing.T) {
	for _, tc := range []struct{ method, path, want string }{
		{"GET", "/api/public/posts/$river_abc", "/public/v1/posts/$river_abc"},
		{"GET", "/api/public/spaces/11111111-1111-4111-8111-111111111111/posts", "/public/v1/spaces/11111111-1111-4111-8111-111111111111/posts"},
		{"POST", "/api/public/posts/$river_abc", ""}, {"GET", "/api/public/posts/admin", ""}, {"GET", "/api/public/posts/$river_abc/events", ""}, {"GET", "/api/public/spaces/nope/posts", ""},
	} {
		got, _ := publicRoute(httptest.NewRequest(tc.method, tc.path, nil))
		if got != tc.want {
			t.Fatalf("%s => %s", tc.path, got)
		}
	}
}
func TestPublicProxyDoesNotInventAuthenticationOrForwardQuerySecrets(t *testing.T) {
	s, _, _, _ := fixture(t)
	s.auth.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/public/v1/posts/$river_abc" || r.Header.Get("Authorization") != "" || r.URL.Query().Get("access_token") != "" || r.URL.Query().Get("before") != "$older" {
			t.Errorf("unexpected public upstream request: %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"entry":{}}`))}, nil
	})}
	w := request(s, "GET", "/api/public/posts/$river_abc?before=$older&access_token=secret", "", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "secret") {
		t.Fatal(w.Code, w.Body.String())
	}
}
