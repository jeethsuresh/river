package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// Opt-in loopback-only transport fixture. It never uses real users, production
// authorization, a production media key, or an Internet listener.
func TestLocalMediaHarness(t *testing.T) {
	if os.Getenv("RIVER_LOCAL_MEDIA_TEST") != "true" {
		t.Skip("local media fixture disabled")
	}
	t.Setenv("LIVEKIT_URL", "ws://127.0.0.1:57880")
	t.Setenv("LIVEKIT_API_KEY", "river-local-media-test")
	t.Setenv("LIVEKIT_API_SECRET", "river-local-isolated-test-secret-0123456789")
	t.Setenv("RIVER_RTC_DEV", "true")
	if os.Getenv("RIVER_TEST_TURN") == "true" {
		t.Setenv("TURN_URIS", "turn:127.0.0.1:57883?transport=tcp")
		t.Setenv("TURN_SHARED_SECRET", "river-local-isolated-turn-secret-0123456789")
		t.Setenv("TURN_FORCE_RELAY", "true")
	}
	s, cookie, _, _ := fixture(t)
	decoded, err := s.auth.DecodeAppSession(cookie)
	if err != nil {
		t.Fatal(err)
	}
	previous := s.auth.HTTP.Transport
	var authMu sync.Mutex
	var mu sync.Mutex
	leases := map[string]bool{}
	var manifests []any
	s.auth.HTTP.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/oauth/session" {
			raw, _ := json.Marshal(map[string]any{"active": true, "iss": s.auth.Issuer, "sub": "alice", "app_origin": s.auth.AppURL, "session_id": decoded.Authorization.SessionID, "exp": decoded.Authorization.CheckExpires})
			return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
		}
		if strings.Contains(r.URL.Path, "/rtc") || strings.HasPrefix(r.URL.Path, "/rtc/leases/") || strings.HasSuffix(r.URL.Path, "/files") {
			body := map[string]any{}
			mu.Lock()
			if r.URL.Path == "/app/v1/rtc" {
				body = map[string]any{"allow_ice": true, "allow_calls": true}
			} else if strings.HasPrefix(r.URL.Path, "/rtc/leases/") {
				body["active"] = leases[strings.TrimPrefix(r.URL.Path, "/rtc/leases/")]
			} else if strings.HasSuffix(r.URL.Path, "/files") {
				if id := r.URL.Query().Get("file_id"); id != "" {
					for _, v := range manifests {
						m, _ := v.(map[string]any)
						if m["id"] == id {
							body["attachment"] = m
						}
					}
				} else {
					body["attachments"] = manifests
				}
			} else {
				var input map[string]string
				_ = json.NewDecoder(r.Body).Decode(&input)
				leases[input["member_id"]] = input["action"] != "leave"
				body = map[string]any{"livekit_room": "river_local_transport_test", "identity": challenge(input["member_id"]), "transport_url": "ws://127.0.0.1:57880", "call_chat_id": "11111111-1111-4111-8111-111111111112", "member_id": input["member_id"]}
			}
			mu.Unlock()
			raw, _ := json.Marshal(body)
			return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
		}
		if r.URL.Host == "127.0.0.1:57880" {
			return http.DefaultTransport.RoundTrip(r)
		}
		authMu.Lock()
		defer authMu.Unlock()
		return previous.RoundTrip(r)
	})
	done := make(chan struct{})
	listener, err := net.Listen("tcp", "127.0.0.1:57890")
	if err != nil {
		t.Fatal(err)
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			u, _ := url.Parse(origin)
			if u == nil || (u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1") {
				w.WriteHeader(403)
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Gravitas-CSRF")
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,OPTIONS")
		}
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == "/test/files" && r.Method == "POST" {
			var manifest map[string]any
			if json.NewDecoder(io.LimitReader(r.Body, 10000)).Decode(&manifest) != nil {
				w.WriteHeader(400)
				return
			}
			mu.Lock()
			manifests = append(manifests, manifest)
			mu.Unlock()
			respond(w, 200, map[string]bool{"ok": true})
			return
		}
		if r.URL.Path == "/test/stop" {
			respond(w, 200, map[string]bool{"ok": true})
			select {
			case <-done:
			default:
				close(done)
			}
			return
		}
		r = r.Clone(r.Context())
		r.Header = r.Header.Clone()
		r.Header.Set("Authorization", "Bearer "+cookie)
		if r.Header.Get("Origin") != "" {
			r.Header.Set("Origin", s.auth.AppURL)
		}
		r.Header.Set("X-Gravitas-CSRF", "1")
		s.ServeHTTP(w, r)
	})
	h := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go h.Serve(listener)
	t.Cleanup(func() { _ = h.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.rtcReaper(ctx)
	t.Log("Loopback River transport fixture ready on 57890")
	select {
	case <-done:
	case <-time.After(45 * time.Minute):
		t.Fatal("local fixture deadline reached")
	}
}
