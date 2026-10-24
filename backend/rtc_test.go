package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func rtcEnv(t *testing.T) {
	t.Helper()
	t.Setenv("LIVEKIT_URL", "wss://rtc.example")
	t.Setenv("LIVEKIT_API_KEY", "test-key")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("s", 32))
}
func TestMediaTokensAreShortLivedPseudonymousAndRoomLimited(t *testing.T) {
	rtcEnv(t)
	c, ok := configuredRTC()
	if !ok {
		t.Fatal("config")
	}
	raw := signRTC(c, "random-identity", map[string]any{"roomJoin": true, "room": "river_hash", "canPublish": true}, nil)
	parts := strings.Split(raw, ".")
	body, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	_ = json.Unmarshal(body, &claims)
	if claims["sub"] != "random-identity" || claims["video"].(map[string]any)["roomAdmin"] != nil || claims["exp"].(float64)-claims["iat"].(float64) != 60 {
		t.Fatal("overprivileged token")
	}
	if strings.Contains(string(body), "@") {
		t.Fatal("identity leak")
	}
	t.Setenv("LIVEKIT_URL", "ws://remote.example")
	if _, ok := configuredRTC(); ok {
		t.Fatal("insecure remote accepted")
	}
}
func TestRTCJoinDoesNotMintForDeniedMembershipAndCompensatesMediaFailure(t *testing.T) {
	rtcEnv(t)
	calls := []string{}
	deny := true
	s := &server{auth: &gravitas.Client{Issuer: "https://gravitas.example", HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls = append(calls, r.URL.Path)
		status := 200
		body := `{}`
		if r.URL.Host == "gravitas.example" {
			if deny {
				status = 403
				body = `{"error":"forbidden"}`
			} else {
				body = `{"livekit_room":"river_hash","identity":"hash","transport_url":"wss://rtc.example"}`
			}
		} else {
			status = 503
		}
		return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}}}
	session := gravitas.AppSession{LocalToken: "delegated", ExpiresAt: time.Now().Add(time.Minute)}
	input := `{"action":"join","member_id":"` + strings.Repeat("a", 43) + `"}`
	room := "00000000-0000-0000-0000-000000000001"
	w := httptest.NewRecorder()
	s.rtcUpdate(w, httptest.NewRequest("POST", "/api/groups/"+room+"/rtc", strings.NewReader(input)), session, room)
	if w.Code != 403 || strings.Contains(w.Body.String(), "jwt") || len(calls) != 1 {
		t.Fatal("denied join minted token")
	}
	deny = false
	calls = nil
	w = httptest.NewRecorder()
	s.rtcUpdate(w, httptest.NewRequest("POST", "/api/groups/"+room+"/rtc", strings.NewReader(input)), session, room)
	if w.Code != 503 || len(calls) != 3 || calls[2] != "/app/v1/groups/"+room+"/rtc" {
		t.Fatal("no compensating leave", calls)
	}
}
func TestMediaReaperSurvivesRestartAndRestrictsItsNamespace(t *testing.T) {
	rtcEnv(t)
	removed := 0
	s := &server{auth: &gravitas.Client{Issuer: "https://gravitas.example", HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{}`
		switch {
		case strings.HasSuffix(r.URL.Path, "ListRooms"):
			body = `{"rooms":[{"name":"unrelated"},{"name":"river_hash"}]}`
		case strings.HasSuffix(r.URL.Path, "ListParticipants"):
			body = `{"participants":[{"identity":"hash","metadata":"{\"lease\":\"` + strings.Repeat("a", 43) + `\"}"}]}`
		case strings.HasPrefix(r.URL.Path, "/rtc/leases/"):
			body = `{"active":false}`
		case strings.HasSuffix(r.URL.Path, "RemoveParticipant"):
			removed++
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}}}
	s.reapRTC(context.Background())
	if removed != 1 {
		t.Fatal("revoked participant not removed", removed)
	}
}

func TestICECredentialsRequireCurrentChatConsent(t *testing.T) {
	rtcEnv(t)
	t.Setenv("TURN_URIS", "turns:turn.example:443?transport=tcp")
	t.Setenv("TURN_SHARED_SECRET", strings.Repeat("t", 32))
	t.Setenv("TURN_FORCE_RELAY", "true")
	allowed, revoked := false, false
	s := &server{auth: &gravitas.Client{Issuer: "https://iam.test", HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/app/v1/rtc" || r.Header.Get("Authorization") != "Bearer delegated" {
			t.Error("missing current consent check")
		}
		code := 200
		body := `{"allow_ice":false,"allow_calls":false}`
		if allowed {
			body = `{"allow_ice":true,"allow_calls":true}`
		}
		if revoked {
			code = 403
		}
		return &http.Response{StatusCode: code, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}}}
	session := gravitas.AppSession{LocalToken: "delegated", Authorization: gravitas.Authorization{Identity: gravitas.Identity{Subject: "alice"}}}
	check := func() (*httptest.ResponseRecorder, map[string]any) {
		w := httptest.NewRecorder()
		s.rtc(w, httptest.NewRequest("GET", "/api/rtc", nil), session)
		var result map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &result)
		return w, result
	}
	w, result := check()
	if w.Code != 200 || len(result["iceServers"].([]any)) != 0 || result["enabled"] != false {
		t.Fatal("profile-only consent minted credentials", w.Body.String())
	}
	allowed = true
	w, result = check()
	if w.Code != 200 || result["enabled"] != true || result["iceTransportPolicy"] != "relay" || !strings.Contains(w.Body.String(), "credential") {
		t.Fatal("consented ICE unavailable", w.Body.String())
	}
	revoked = true
	w, _ = check()
	if w.Code != 403 || strings.Contains(w.Body.String(), "credential") {
		t.Fatal("revoked consent minted credentials")
	}
}
