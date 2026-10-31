package gravitas

import (
	"context"
	"strings"
	"testing"
)

func TestBrokerSessionBindsProofIdentityFamilyAndScope(t *testing.T) {
	for _, scenario := range []string{"valid", "subject", "family", "username", "scope", "verifier"} {
		t.Run(scenario, func(t *testing.T) {
			c, calls := fixture(t)
			subject, family, username, verifier := "stable-subject", "11111111-1111-4111-8111-111111111111", "alice", strings.Repeat("v", 43)
			switch scenario {
			case "subject":
				subject = "another-subject"
			case "family":
				family = "22222222-2222-4222-8222-222222222222"
			case "username":
				username = "bob"
			case "scope":
				c.Scope = "profile.name contacts.read"
			case "verifier":
				verifier = "invalid"
			}
			value, err := c.BrokerSession(context.Background(), strings.Repeat("b", 43), verifier, subject, family, username)
			if scenario != "valid" {
				if err == nil || value != "" {
					t.Fatal("unbound broker assertion was accepted")
				}
				if scenario == "verifier" && calls.Load() != 0 {
					t.Fatal("invalid proof reached IAM")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			session, err := c.AuthenticateValue(context.Background(), value)
			if err != nil || session.Authorization.Subject != subject || session.Authorization.SessionID != family || session.LocalToken != "private-opaque-token" {
				t.Fatal("broker session lost its binding", err)
			}
			if _, err = c.BrokerSession(context.Background(), strings.Repeat("b", 43), verifier, subject, family, username); err == nil {
				t.Fatal("one-use code was replayed")
			}
		})
	}
}
