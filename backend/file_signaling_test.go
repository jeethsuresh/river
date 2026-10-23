package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

func TestFileSignalsAreRoomIsolatedAndSenderIsServerAssigned(t *testing.T) {
	s := &server{auth: &gravitas.Client{AppURL: "https://chat.gravitas.cool", Issuer: "https://iam.test", HTTP: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"files":[]}`))}, nil
	})}}}
	h := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.fileSignal(w, r, gravitas.AppSession{LocalToken: "synthetic", Authorization: gravitas.Authorization{Identity: gravitas.Identity{Subject: "alice"}}, ExpiresAt: time.Now().Add(time.Minute)}, fileSignalRoom(r))
	}))
	defer h.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	room := "11111111-1111-4111-8111-111111111111"
	open := func(room string) (*websocket.Conn, string) {
		c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/api/groups/"+room+"/files/signal", &websocket.DialOptions{HTTPHeader: http.Header{"Origin": []string{s.auth.AppURL}}})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.CloseNow() })
		_, raw, err := c.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var welcome map[string]any
		_ = json.Unmarshal(raw, &welcome)
		return c, welcome["peerId"].(string)
	}
	a, aid := open(room)
	b, bid := open(room)
	other, oid := open("22222222-2222-4222-8222-222222222222")
	send := func(c *websocket.Conn, to, description string) {
		raw, _ := json.Marshal(map[string]any{"type": "offer", "to": to, "from": "forged", "extra": "private", "description": description})
		if err := c.Write(ctx, websocket.MessageText, raw); err != nil {
			t.Fatal(err)
		}
	}
	send(a, oid, "cross-room must not arrive")
	send(b, aid, "same-room")
	_, raw, err := a.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.Unmarshal(raw, &got)
	if got["from"] != bid || got["description"] != "same-room" || got["extra"] != nil {
		t.Fatal("forged sender or fields forwarded", got)
	}
	short, stop := context.WithTimeout(ctx, 150*time.Millisecond)
	defer stop()
	if _, _, err := other.Read(short); err == nil {
		t.Fatal("cross-room signal leaked")
	}
	badOrigin := &websocket.DialOptions{HTTPHeader: http.Header{"Origin": []string{"http://chat.gravitas.cool"}}}
	if c, r, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/api/groups/"+room+"/files/signal", badOrigin); err == nil {
		c.CloseNow()
		t.Fatal("insecure origin accepted")
	} else if r == nil || r.StatusCode != 403 {
		t.Fatal("wrong origin response", r)
	}
}
