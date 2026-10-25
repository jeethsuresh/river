package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Explicitly opt-in, loopback-only bridge for Flutter automated production
// journeys. Credentials are real disposable-account envelopes from normal
// Gravitas PKCE/native consent, supplied in a private file outside the repo.
// No authentication or API response is mocked. Never enable against real users.
func TestProductionJourneyBridge(t *testing.T) {
	path := os.Getenv("RIVER_PRODUCTION_JOURNEY_CONFIG")
	if path == "" {
		t.Skip("production journey bridge disabled")
	}
	var config struct {
		Actors map[string]struct {
			Token     string `json:"token"`
			IAMCookie string `json:"iam_cookie"`
			Username  string `json:"username"`
		} `json:"actors"`
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &config); err != nil {
		t.Fatal("invalid private journey configuration")
	}
	if len(config.Actors) != 3 {
		t.Fatal("expected exactly three disposable fixture accounts")
	}
	for label, a := range config.Actors {
		if (label != "alice" && label != "bob" && label != "carol") || !regexp.MustCompile(`^rq[abc][a-f0-9]{8}$`).MatchString(a.Username) || a.Token == "" {
			t.Fatal("unexpected fixture identity")
		}
	}
	target, _ := url.Parse("https://chat.gravitas.cool")
	transport := http.DefaultTransport.(*http.Transport).Clone()
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = transport
	proxy.FlushInterval = -1
	original := proxy.Director
	proxy.Director = func(r *http.Request) {
		actor := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")[0]
		r.URL.Path = strings.TrimPrefix(r.URL.Path, "/"+actor)
		original(r)
		r.Host = target.Host
		r.Header.Del("Cookie")
		if actor == "anonymous" {
			r.Header.Del("Authorization")
		} else {
			r.Header.Set("Authorization", "Bearer "+config.Actors[actor].Token)
		}
		r.Header.Set("Origin", target.String())
		r.Header.Set("X-Gravitas-CSRF", "1")
	}
	proxy.ModifyResponse = func(r *http.Response) error {
		r.Header.Del("Set-Cookie")
		if r.StatusCode >= 400 {
			t.Logf("fixture upstream %s %s: %d content-type=%s", r.Request.Method, r.Request.URL.Path, r.StatusCode, r.Header.Get("Content-Type"))
		}
		return nil
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		http.Error(w, "Production bridge upstream unavailable", 502)
	}
	done := make(chan struct{})
	client := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			u, e := url.Parse(origin)
			if e != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") {
				http.Error(w, "loopback origins only", 403)
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Gravitas-CSRF")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS")
		}
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == "/test/stop" && r.Method == "POST" {
			select {
			case <-done:
			default:
				close(done)
			}
			respond(w, 200, map[string]bool{"stopping": true})
			return
		}
		actor, rest, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
		a, exists := config.Actors[actor]
		if !exists && !(actor == "anonymous" && strings.HasPrefix(rest, "api/public/") && r.Method == "GET") {
			http.NotFound(w, r)
			return
		}
		if rest == "control/revoke" && r.Method == "POST" {
			req, _ := http.NewRequestWithContext(r.Context(), "GET", "https://gravitas.cool/settings", nil)
			req.Header.Set("Cookie", a.IAMCookie)
			response, e := client.Do(req)
			if e != nil {
				http.Error(w, "settings unavailable", 502)
				return
			}
			page, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
			_ = response.Body.Close()
			token := regexp.MustCompile(`name="_csrf_token"[^>]*value="([^"]+)"`).FindSubmatch(page)
			if response.StatusCode != 200 || len(token) != 2 {
				http.Error(w, "fixture settings session invalid", 502)
				return
			}
			form := url.Values{"_csrf_token": {html.UnescapeString(string(token[1]))}, "origin": {target.String()}}
			req, _ = http.NewRequestWithContext(r.Context(), "POST", "https://gravitas.cool/web/settings/apps/revoke", strings.NewReader(form.Encode()))
			req.Header.Set("Cookie", a.IAMCookie)
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			response, e = client.Do(req)
			if e != nil {
				http.Error(w, "revocation unavailable", 502)
				return
			}
			_ = response.Body.Close()
			if response.StatusCode != 303 && response.StatusCode != 302 {
				http.Error(w, fmt.Sprintf("revocation returned %d", response.StatusCode), 502)
				return
			}
			respond(w, 200, map[string]bool{"revoked": true})
			return
		}
		if !strings.HasPrefix(rest, "api/") && rest != "auth/gravitas/config" {
			http.NotFound(w, r)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	// Each browser actor gets a separate connection pool, as separate signed-in
	// browser sessions would. Sharing three long-lived SSE streams on one HTTP/1
	// origin otherwise makes the harness itself contend with API preflights.
	for _, port := range []int{57910, 57911, 57912} {
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		h := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
		go h.Serve(listener)
		t.Cleanup(func() {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = h.Shutdown(ctx)
			_ = h.Close()
		})
	}
	t.Cleanup(transport.CloseIdleConnections)
	t.Log("Real-account loopback production bridge ready on 57910-57912; no personal browser session used")
	select {
	case <-done:
	case <-time.After(45 * time.Minute):
		t.Fatal("journey bridge deadline reached")
	}
}
