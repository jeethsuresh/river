package main

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

// Live updates contain invalidations only. Gravitas authorizes every audience
// and rechecks token revocation while the connection is open.
func (s *server) live(w http.ResponseWriter, r *http.Request, session gravitas.AppSession) {
	if r.Method != http.MethodGet {
		w.WriteHeader(405)
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), session.ExpiresAt)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", s.upstream(ctx).Issuer+"/app/v1/live", nil)
	req.Header.Set("Authorization", "Bearer "+session.LocalToken)
	req.Header.Set("Accept", "text/event-stream")
	client := *s.upstream(ctx).HTTP
	client.Timeout = 0
	resp, err := client.Do(req)
	if err != nil {
		fail(w, 503, "Live updates are temporarily unavailable")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		status := 503
		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			status = resp.StatusCode
		}
		fail(w, status, "Live updates are unavailable")
		return
	}
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	flusher, ok := w.(http.Flusher)
	if !ok {
		return
	}
	flusher.Flush()
	lines := bufio.NewScanner(resp.Body)
	lines.Buffer(make([]byte, 4096), 4096)
	for lines.Scan() {
		line := lines.Text()
		// Never blindly proxy data/URLs from another origin into a browser stream.
		if line == "event: ready" || line == "event: invalidate" || line == "event: revoked" || line == "data: {}" || line == ": heartbeat" || line == "" {
			if _, err := io.WriteString(w, line+"\n"); err != nil {
				return
			}
			if line == "" {
				flusher.Flush()
			}
		}
	}
}
