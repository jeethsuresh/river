package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jeethsuresh/river/backend/internal/gravitas"
)

// Admission only: no media or TURN allocation and no production connections.
// Run with RIVER_TEST_LIVEKIT_BINARY=/absolute/path/to/livekit-server.
func TestLocalCallParticipantAdmission(t *testing.T) {
	binary := os.Getenv("RIVER_TEST_LIVEKIT_BINARY")
	if binary == "" {
		t.Skip("isolated LiveKit admission test disabled")
	}
	if !filepath.IsAbs(binary) {
		t.Fatal("LiveKit binary must be an absolute path")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mediaPort := udp.LocalAddr().(*net.UDPAddr).Port
	_ = udp.Close()
	config := fmt.Sprintf("port: %d\nbind_addresses: [127.0.0.1]\nrtc:\n  tcp_port: 0\n  udp_port: %d\n  node_ip: 127.0.0.1\n  use_external_ip: false\n  enable_loopback_candidate: true\nkeys:\n  admission-test: isolated-admission-test-secret-0123456789\nroom:\n  max_participants: 0\nlogging:\n  level: error\n", port, mediaPort)
	path := filepath.Join(t.TempDir(), "livekit.yaml")
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "--config", path)
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	endpoint := fmt.Sprintf("http://127.0.0.1:%d", port)
	for i := 0; i < 100; i++ {
		response, err := http.Get(endpoint)
		if err == nil {
			_ = response.Body.Close()
			break
		}
		if i == 99 {
			t.Fatal("isolated LiveKit did not start")
		}
		time.Sleep(50 * time.Millisecond)
	}
	c := rtcConfig{URL: strings.Replace(endpoint, "http:", "ws:", 1), Key: "admission-test", Secret: "isolated-admission-test-secret-0123456789"}
	s := &server{auth: &gravitas.Client{HTTP: &http.Client{Timeout: 5 * time.Second}}}
	start := time.Now()
	for _, phase := range []struct {
		name          string
		cap, accepted int
	}{{"control", 32, 32}, {"uncapped", 0, 64}} {
		t.Run(phase.name, func(t *testing.T) {
			name := "river_isolated_admission_" + phase.name
			body := map[string]any{"name": name, "empty_timeout": 10, "departure_timeout": 1}
			if phase.cap > 0 {
				body["max_participants"] = phase.cap
			}
			var room struct {
				Max uint32 `json:"max_participants"`
			}
			if err := s.rtcAdmin(ctx, c, "CreateRoom", body, map[string]any{"roomCreate": true}, &room); err != nil {
				t.Fatal(err)
			}
			if room.Max != uint32(phase.cap) {
				t.Fatalf("unexpected configured maximum: %d", room.Max)
			}
			t.Cleanup(func() {
				_ = s.rtcAdmin(context.Background(), c, "DeleteRoom", map[string]any{"room": name}, map[string]any{"roomCreate": true}, nil)
			})
			conns := []*websocket.Conn{}
			t.Cleanup(func() {
				for _, conn := range conns {
					_ = conn.CloseNow()
				}
			})
			join := func(i int) error {
				identity := fmt.Sprintf("admission-%d", i)
				jwt := signRTC(c, identity, map[string]any{"roomJoin": true, "room": name, "canPublish": false, "canSubscribe": false, "canPublishData": false}, nil)
				target := c.URL + "/rtc?" + url.Values{"access_token": {jwt}, "protocol": {"15"}, "auto_subscribe": {"0"}, "sdk": {"go"}}.Encode()
				joinCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
				defer cancel()
				conn, response, err := websocket.Dial(joinCtx, target, nil)
				if err != nil {
					if response != nil {
						_ = response.Body.Close()
					}
					return err
				}
				typ, data, err := conn.Read(joinCtx)
				if err != nil {
					_ = conn.CloseNow()
					return err
				}
				// SignalResponse.join is field 1 in LiveKit's protobuf protocol.
				if typ != websocket.MessageBinary || len(data) == 0 || data[0] != 0x0a {
					_ = conn.CloseNow()
					return fmt.Errorf("no protobuf join response (type=%v)", typ)
				}
				conns = append(conns, conn)
				go func() {
					for {
						if _, _, err := conn.Read(ctx); err != nil {
							return
						}
					}
				}()
				return nil
			}
			for i := 0; i < phase.accepted; i++ {
				if err := join(i); err != nil {
					t.Fatalf("participant %d: %v", i+1, err)
				}
			}
			if phase.cap > 0 {
				if err := join(phase.accepted); err == nil {
					t.Fatal("control admitted participant 33 despite cap 32")
				}
			}
			var peers struct {
				Participants []json.RawMessage `json:"participants"`
			}
			if err := s.rtcAdmin(ctx, c, "ListParticipants", map[string]any{"room": name}, map[string]any{"roomAdmin": true, "room": name}, &peers); err != nil {
				t.Fatal(err)
			}
			if len(peers.Participants) != phase.accepted {
				t.Fatalf("simultaneous admitted participants: %d, want %d", len(peers.Participants), phase.accepted)
			}
			t.Logf("%d simultaneous signaling admissions; max_participants=%d; no media negotiated", len(peers.Participants), room.Max)
		})
	}
	t.Logf("bounded admission check elapsed %s; this is not a usable-media capacity benchmark", time.Since(start).Round(time.Millisecond))
}
