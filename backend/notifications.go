package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

var notificationProviderID = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Private Store owns devices and subscriptions. River's homeserver uses PCR
// push.broadcast, so no second device registry or callback queue is needed.
// Acknowledge the Store's reconciliation only for the authenticated contract.
func (s *server) notificationProvider(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		w.WriteHeader(405)
		return
	}
	key := os.Getenv("NOTIFICATION_PROVIDER_KEY")
	supplied := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	expectedHash, suppliedHash := sha256.Sum256([]byte(key)), sha256.Sum256([]byte(supplied))
	if len(key) < 32 || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || subtle.ConstantTimeCompare(expectedHash[:], suppliedHash[:]) != 1 {
		fail(w, 401, "Unauthorized provider")
		return
	}
	var in struct {
		Issuer   string `json:"issuer"`
		Subject  string `json:"subject"`
		Callback string `json:"callback"`
		Protocol string `json:"protocol"`
		Enabled  *bool  `json:"enabled"`
	}
	if !notificationProviderID.MatchString(strings.TrimPrefix(r.URL.Path, "/api/notifications/providers/")) || decode(r, &in) != nil || in.Issuer != s.auth.Issuer || !uuidPattern.MatchString(in.Subject) || in.Protocol != "appstore/1.0.0" || in.Callback != "" || in.Enabled == nil {
		fail(w, 400, "Invalid notification registration")
		return
	}
	w.WriteHeader(204)
}

func notificationStoreOrigin(raw string) (string, error) {
	if raw == "" {
		return "", nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil ||
		u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return "", errors.New("NOTIFICATION_STORE_URL must be an HTTPS origin")
	}
	return raw, nil
}

func (s *server) iosNotifications(w http.ResponseWriter, r *http.Request, session gravitas.AppSession) {
	if r.Method != http.MethodPut && r.Method != http.MethodDelete {
		w.Header().Set("Allow", "PUT, DELETE")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	auth := session.Authorization
	if auth.Issuer != s.auth.Issuer || auth.CheckToken == "" || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		fail(w, 403, "Sign in with Gravitas to enable notifications")
		return
	}
	key := os.Getenv("NOTIFICATION_PROVIDER_KEY")
	if len(key) < 32 || s.notificationStore == "" {
		fail(w, 503, "iOS notifications are unavailable")
		return
	}
	var in struct {
		Installation string `json:"installation"`
		Generation   int64  `json:"generation"`
		Token        string `json:"token"`
		Environment  string `json:"environment"`
	}
	if decode(r, &in) != nil || !notificationProviderID.MatchString(in.Installation) || in.Generation <= 0 {
		fail(w, 400, "Invalid notification installation")
		return
	}
	installation := sha256.Sum256([]byte(auth.Subject + "\x00" + in.Installation))
	body := map[string]any{"generation": in.Generation}
	if r.Method == http.MethodPut {
		if in.Token == "" || len(in.Token) > 1024 || (in.Environment != "sandbox" && in.Environment != "production") {
			fail(w, 400, "Invalid APNs registration")
			return
		}
		body["platform"], body["token"], body["environment"], body["session_proof"] = "ios", in.Token, in.Environment, auth.CheckToken
	}
	data, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(r.Context(), r.Method, s.notificationStore+"/v1/notification-installations/river/"+hex.EncodeToString(installation[:]), bytes.NewReader(data))
	if err != nil {
		fail(w, 503, "iOS notifications are unavailable")
		return
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	response, err := s.auth.HTTP.Do(req)
	if err != nil {
		fail(w, 503, "iOS notifications are unavailable")
		return
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	status := response.StatusCode
	if (r.Method == http.MethodPut && status == 200) || (r.Method == http.MethodDelete && status == 204) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if status != 400 && status != 403 && status != 409 {
		status = 503
	}
	fail(w, status, "Unable to update iOS notifications")
}
