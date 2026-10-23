package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

type rtcConfig struct{ URL, Key, Secret string }

func configuredRTC() (rtcConfig, bool) {
	c := rtcConfig{os.Getenv("LIVEKIT_URL"), os.Getenv("LIVEKIT_API_KEY"), os.Getenv("LIVEKIT_API_SECRET")}
	u, e := url.Parse(c.URL)
	if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return c, false
	}
	secure := u.Scheme == "wss"
	dev := os.Getenv("RIVER_RTC_DEV") == "true" && u.Scheme == "ws" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost")
	return c, (secure || dev) && c.Key != "" && len(c.Secret) >= 32
}
func iceServers(subject string) []map[string]any {
	servers := []map[string]any{{"urls": []string{"stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"}}}
	uris := strings.Fields(os.Getenv("TURN_URIS"))
	secret := os.Getenv("TURN_SHARED_SECRET")
	if len(uris) > 0 && secret != "" {
		username := fmt.Sprintf("%d:%s", time.Now().Add(5*time.Minute).Unix(), challenge(subject)[:16])
		m := hmac.New(sha1.New, []byte(secret))
		_, _ = m.Write([]byte(username))
		servers = append(servers, map[string]any{"urls": uris, "username": username, "credential": base64.StdEncoding.EncodeToString(m.Sum(nil))})
	}
	return servers
}
func (s *server) rtc(w http.ResponseWriter, subject string) {
	_, enabled := configuredRTC()
	reason := ""
	if !enabled {
		reason = "Calling requires the configured River media service. Peer file exchange is available with the advertised ICE servers."
	}
	respond(w, 200, map[string]any{"enabled": enabled, "matrixrtc": enabled, "iceServers": iceServers(subject), "ttl": 300, "reason": reason})
}
func signRTC(c rtcConfig, subject string, video map[string]any, extra map[string]any) string {
	enc := func(v any) string { b, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(b) }
	now := time.Now().Unix()
	claims := map[string]any{"iss": c.Key, "sub": subject, "iat": now, "nbf": now - 5, "exp": now + 60, "jti": random(), "video": video}
	for k, v := range extra {
		claims[k] = v
	}
	payload := enc(map[string]string{"alg": "HS256", "typ": "JWT"}) + "." + enc(claims)
	mac := hmac.New(sha256.New, []byte(c.Secret))
	_, _ = mac.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (s *server) iamRequest(ctx context.Context, token, path string, body any) (map[string]any, int, error) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", s.auth.Issuer+path, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.auth.HTTP.Do(req)
	if err != nil {
		return nil, 503, err
	}
	defer resp.Body.Close()
	raw, err = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, 502, err
	}
	var result map[string]any
	if json.Unmarshal(raw, &result) != nil {
		return nil, 502, errors.New("invalid response")
	}
	return result, resp.StatusCode, nil
}
func rtcRoom(r *http.Request) string {
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(p) == 4 && p[0] == "api" && p[1] == "groups" && uuidPattern.MatchString(p[2]) && p[3] == "rtc" {
		return p[2]
	}
	return ""
}
func (s *server) rtcUpdate(w http.ResponseWriter, r *http.Request, session gravitas.AppSession, room string) {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	c, enabled := configuredRTC()
	if !enabled {
		fail(w, 503, "rtc_unavailable")
		return
	}
	var input struct {
		Action string `json:"action"`
		Member string `json:"member_id"`
	}
	if decode(r, &input) != nil || (input.Action != "join" && input.Action != "renew" && input.Action != "leave") || len(input.Member) != 43 || !txnPattern.MatchString(input.Member) {
		fail(w, 400, "Invalid call request")
		return
	}
	data, status, err := s.iamRequest(r.Context(), session.LocalToken, "/app/v1/groups/"+room+"/rtc", map[string]string{"action": input.Action, "member_id": input.Member})
	if err != nil {
		fail(w, status, "Gravitas calling is temporarily unavailable")
		return
	}
	if status != 200 {
		respond(w, status, data)
		return
	}
	get := func(k string) string { v, _ := data[k].(string); return v }
	name, identity := get("livekit_room"), get("identity")
	if get("transport_url") != c.URL || !strings.HasPrefix(name, "river_") || identity == "" {
		fail(w, 502, "Media service configuration does not match Gravitas")
		return
	}
	if input.Action == "leave" {
		_ = s.rtcAdmin(r.Context(), c, "RemoveParticipant", map[string]any{"room": name, "identity": identity}, map[string]any{"roomAdmin": true, "room": name}, nil)
	} else if input.Action == "join" {
		if err := s.rtcAdmin(r.Context(), c, "CreateRoom", map[string]any{"name": name, "empty_timeout": 60, "departure_timeout": 10, "max_participants": 32}, map[string]any{"roomCreate": true}, nil); err != nil {
			_, _, _ = s.iamRequest(r.Context(), session.LocalToken, "/app/v1/groups/"+room+"/rtc", map[string]string{"action": "leave", "member_id": input.Member})
			fail(w, 503, "The media service could not start this call. Please retry.")
			return
		}
		metadata, _ := json.Marshal(map[string]string{"lease": input.Member})
		data["jwt"] = signRTC(c, identity, map[string]any{"roomJoin": true, "room": name, "canPublish": true, "canSubscribe": true, "canPublishData": true, "canUpdateOwnMetadata": false}, map[string]any{"metadata": string(metadata), "name": "River participant"})
	}
	respond(w, 200, data)
}
func (s *server) rtcAdmin(ctx context.Context, c rtcConfig, method string, body, grant map[string]any, out any) error {
	u, _ := url.Parse(c.URL)
	if u.Scheme == "wss" {
		u.Scheme = "https"
	} else {
		u.Scheme = "http"
	}
	u.Path = "/twirp/livekit.RoomService/" + method
	raw, _ := json.Marshal(body)
	callCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(callCtx, "POST", u.String(), bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+signRTC(c, "river-coordinator", grant, nil))
	resp, err := s.auth.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("media operation failed: %d", resp.StatusCode)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(out)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	return nil
}
func (s *server) rtcReaper(ctx context.Context) {
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		s.reapRTC(ctx)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
func (s *server) reapRTC(ctx context.Context) {
	c, enabled := configuredRTC()
	if !enabled {
		return
	}
	var rooms struct {
		Rooms []struct {
			Name string `json:"name"`
		} `json:"rooms"`
	}
	if s.rtcAdmin(ctx, c, "ListRooms", map[string]any{}, map[string]any{"roomList": true}, &rooms) != nil {
		return
	}
	for _, room := range rooms.Rooms {
		if !strings.HasPrefix(room.Name, "river_") {
			continue
		}
		var peers struct {
			Participants []struct {
				Identity string `json:"identity"`
				Metadata string `json:"metadata"`
			} `json:"participants"`
		}
		if s.rtcAdmin(ctx, c, "ListParticipants", map[string]any{"room": room.Name}, map[string]any{"roomAdmin": true, "room": room.Name}, &peers) != nil {
			continue
		}
		for _, peer := range peers.Participants {
			var metadata struct {
				Lease string `json:"lease"`
			}
			_ = json.Unmarshal([]byte(peer.Metadata), &metadata)
			active := false
			if len(metadata.Lease) == 43 && txnPattern.MatchString(metadata.Lease) {
				req, _ := http.NewRequestWithContext(ctx, "GET", s.auth.Issuer+"/rtc/leases/"+metadata.Lease, nil)
				if response, err := s.auth.HTTP.Do(req); err == nil {
					var result struct {
						Active bool `json:"active"`
					}
					err = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&result)
					_ = response.Body.Close()
					active = err == nil && response.StatusCode == 200 && result.Active
				}
			}
			// Fail closed if IAM cannot confirm the session, current consent, room ACL,
			// absence of blocks and the renewable membership lease. This works on startup.
			if !active {
				_ = s.rtcAdmin(ctx, c, "RemoveParticipant", map[string]any{"room": room.Name, "identity": peer.Identity}, map[string]any{"roomAdmin": true, "room": room.Name}, nil)
			}
		}
	}
}
