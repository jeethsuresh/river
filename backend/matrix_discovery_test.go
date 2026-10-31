package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMatrixClientDiscovery(t *testing.T) {
	s, _, _, _ := fixture(t)
	s.auth.HTTP.Transport = roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("client discovery must work without contacting IAM or authenticating")
		return nil, nil
	})
	for _, issuer := range []string{"https://gravitas.cool", "https://identity.example:9443"} {
		s.auth.Issuer = issuer
		r := httptest.NewRequest(http.MethodGet, "https://untrusted.example/.well-known/matrix/client", nil)
		r.Header.Set("Origin", "https://matrix-client.example")
		r.Header.Set("X-Forwarded-Host", "untrusted.example")
		r.Header.Set("Authorization", "Bearer invalid")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "application/json" ||
			w.Header().Get("Access-Control-Allow-Origin") != "*" ||
			w.Header().Get("Cache-Control") != "public, max-age=300" {
			t.Fatalf("discovery unavailable to Matrix clients: %d %v", w.Code, w.Header())
		}
		var body struct {
			Homeserver struct {
				BaseURL string `json:"base_url"`
			} `json:"m.homeserver"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body.Homeserver.BaseURL != issuer {
			t.Fatalf("discovery must use the configured issuer: %s (%v)", w.Body.String(), err)
		}
	}
}

func TestMatrixClientDiscoveryMethods(t *testing.T) {
	s, _, _, _ := fixture(t)
	for method, status := range map[string]int{
		http.MethodHead: http.StatusOK, http.MethodOptions: http.StatusNoContent,
		http.MethodPost: http.StatusMethodNotAllowed, http.MethodPut: http.StatusMethodNotAllowed,
	} {
		w := request(s, method, "/.well-known/matrix/client", "", "")
		if w.Code != status || w.Header().Get("Access-Control-Allow-Origin") != "*" {
			t.Fatalf("%s: %d %v", method, w.Code, w.Header())
		}
		if (method == http.MethodHead || method == http.MethodOptions) && w.Body.Len() != 0 {
			t.Fatalf("%s returned an unexpected body", method)
		}
		if status == http.StatusMethodNotAllowed && w.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
			t.Fatalf("%s did not advertise supported methods", method)
		}
	}
}
