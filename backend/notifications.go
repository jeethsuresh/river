package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
	"os"
	"regexp"
	"strings"
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
