package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

type signalPeer struct {
	id, account, room string
	out               chan []byte
	cancel            context.CancelFunc
}
type signalHub struct {
	mu    sync.Mutex
	rooms map[string]map[string]*signalPeer
	count int
}

func fileSignalRoom(r *http.Request) string {
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(p) == 5 && p[0] == "api" && p[1] == "groups" && uuidPattern.MatchString(p[2]) && p[3] == "files" && p[4] == "signal" {
		return p[2]
	}
	return ""
}
func (s *server) fileAllowed(ctx context.Context, token, room string) bool {
	req, _ := http.NewRequestWithContext(ctx, "GET", s.auth.Issuer+"/app/v1/groups/"+room+"/files", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := s.auth.HTTP.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 2<<20))
	return resp.StatusCode == 200
}
func (s *server) fileSignal(w http.ResponseWriter, r *http.Request, session gravitas.AppSession, room string) {
	if r.Method != "GET" {
		w.WriteHeader(405)
		return
	}
	if r.URL.RawQuery != "" {
		fail(w, 400, "Use the session header or cookie")
		return
	}
	if !s.fileAllowed(r.Context(), session.LocalToken, room) {
		fail(w, 403, "You cannot access files in this room")
		return
	}
	origin, _ := url.Parse(s.auth.AppURL)
	if value := r.Header.Get("Origin"); value != "" && value != origin.Scheme+"://"+origin.Host {
		fail(w, 403, "Invalid origin")
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{origin.Host}})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	conn.SetReadLimit(70_000)
	ctx, cancel := context.WithDeadline(r.Context(), session.ExpiresAt)
	defer cancel()
	s.mu.Lock()
	if s.files == nil {
		s.files = &signalHub{rooms: make(map[string]map[string]*signalPeer)}
	}
	hub := s.files
	s.mu.Unlock()
	peer := &signalPeer{id: random(), account: session.Authorization.Subject, room: room, out: make(chan []byte, 32), cancel: cancel}
	hub.mu.Lock()
	if hub.rooms[room] == nil {
		hub.rooms[room] = make(map[string]*signalPeer)
	}
	same := 0
	for _, p := range hub.rooms[room] {
		if p.account == peer.account {
			same++
		}
	}
	if hub.count >= 512 || len(hub.rooms[room]) >= 32 || same >= 4 {
		hub.mu.Unlock()
		_ = conn.Close(websocket.StatusPolicyViolation, "Room connection limit reached")
		return
	}
	ids := []string{}
	for id := range hub.rooms[room] {
		ids = append(ids, id)
	}
	hub.rooms[room][peer.id] = peer
	hub.count++
	hub.mu.Unlock()
	defer func() {
		hub.mu.Lock()
		delete(hub.rooms[room], peer.id)
		hub.count--
		left, _ := json.Marshal(map[string]string{"type": "peer-left", "peerId": peer.id})
		for _, p := range hub.rooms[room] {
			select {
			case p.out <- left:
			default:
				p.cancel()
			}
		}
		if len(hub.rooms[room]) == 0 {
			delete(hub.rooms, room)
		}
		hub.mu.Unlock()
	}()
	welcome, _ := json.Marshal(map[string]any{"type": "welcome", "peerId": peer.id, "peers": ids})
	peer.out <- welcome
	go func() {
		ping := time.NewTicker(20 * time.Second)
		defer ping.Stop()
		auth := time.NewTicker(10 * time.Second)
		defer auth.Stop()
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case raw := <-peer.out:
				if conn.Write(ctx, websocket.MessageText, raw) != nil {
					return
				}
			case <-ping.C:
				pc, stop := context.WithTimeout(ctx, 5*time.Second)
				err := conn.Ping(pc)
				stop()
				if err != nil {
					return
				}
			case <-auth.C:
				if s.auth.Revalidate(ctx, session) != nil || !s.fileAllowed(ctx, session.LocalToken, room) {
					_ = conn.Close(websocket.StatusPolicyViolation, "Room access changed")
					return
				}
			}
		}
	}()
	window := time.Now()
	count := 0
	for {
		typ, raw, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			_ = conn.Close(websocket.StatusUnsupportedData, "Only signaling is accepted")
			return
		}
		if time.Since(window) >= time.Minute {
			window = time.Now()
			count = 0
		}
		count++
		if count > 300 {
			_ = conn.Close(websocket.StatusPolicyViolation, "Too many signals")
			return
		}
		var msg map[string]json.RawMessage
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		var kind, to string
		_ = json.Unmarshal(msg["type"], &kind)
		_ = json.Unmarshal(msg["to"], &to)
		if kind != "offer" && kind != "answer" && kind != "ice" && kind != "attachment" {
			continue
		}
		next := map[string]json.RawMessage{"type": msg["type"]}
		next["from"], _ = json.Marshal(peer.id)
		switch kind {
		case "offer", "answer":
			next["description"] = msg["description"]
		case "ice":
			next["candidate"] = msg["candidate"]
		case "attachment":
			next["attachmentId"] = msg["attachmentId"]
		}
		encoded, err := json.Marshal(next)
		if err != nil {
			continue
		}
		hub.mu.Lock()
		if kind == "attachment" {
			for id, p := range hub.rooms[room] {
				if id != peer.id {
					select {
					case p.out <- encoded:
					default:
						p.cancel()
					}
				}
			}
		} else if target := hub.rooms[room][to]; target != nil && target != peer {
			select {
			case target.out <- encoded:
			default:
				target.cancel()
			}
		}
		hub.mu.Unlock()
	}
}
