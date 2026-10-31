package gravitas

import (
	"context"
	"regexp"
	"time"
)

var brokerProof = regexp.MustCompile(`^[A-Za-z0-9_-]{43,128}$`)

// The native app supplies its own verifier. The store's access and refresh
// credentials never reach River; IAM verifies the one-use code and target.
func (c *Client) BrokerSession(ctx context.Context, code, verifier, subject, family, username string) (string, error) {
	if len(code) < 32 || len(code) > 2048 || !brokerProof.MatchString(verifier) || subject == "" || len(subject) > 256 || len(family) != 36 {
		return "", ErrLoginRequired
	}
	selected, expected, err := c.ResolveLogin(username, false)
	if err != nil || selected != c {
		return "", ErrLoginRequired
	}
	auth, err := c.exchange(ctx, code, verifier, expected, true)
	if err != nil {
		return "", err
	}
	if auth.Subject != subject || auth.SessionID != family {
		return "", ErrLoginRequired
	}
	expires := time.Now().Add(time.Hour - time.Minute)
	if auth.RefreshToken != "" {
		expires = time.Unix(auth.CheckExpires, 0)
	}
	value, _, err := c.encodeAppSession(auth, auth.AccessToken, expires)
	return value, err
}
