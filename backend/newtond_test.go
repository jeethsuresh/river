package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	newton "github.com/jeethsuresh/newtond/log"
)

func TestNewtonDPilotRecordsOnlyOperationalParameters(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sender, err := newton.NewUDPSender(ctx, conn.LocalAddr().String(), "river", []byte(strings.Repeat("x", 32)))
	if err != nil {
		t.Fatal(err)
	}
	probe := &server{newtond: &newtonSender{sender: sender}}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/api/rtc?private=content", nil)
	out, request, finish := probe.newtond.observe(w, r)
	out.WriteHeader(401)
	finish()
	id := w.Header().Get(newtonRequestHeader)
	if id == "" {
		t.Fatal("missing request ID")
	}
	upstream, err := http.NewRequestWithContext(request.Context(), "GET", "https://gravitas.cool/app/v1/rtc", nil)
	if err != nil {
		t.Fatal(err)
	}
	finishCall := probe.observeIAMPermissions(upstream, "https://gravitas.cool")
	if upstream.Header.Get(newtonRequestHeader) != id {
		t.Fatal("request ID was not propagated")
	}
	finishCall(&http.Response{StatusCode: 200}, nil)
	external := httptest.NewRequest("GET", "https://other.example/app/v1/rtc", nil).WithContext(request.Context())
	probe.observeIAMPermissions(external, "https://other.example")(nil, nil)
	if external.Header.Get(newtonRequestHeader) != "" {
		t.Fatal("request ID was forwarded to a federated issuer")
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	for _, want := range []struct{ message, status string }{
		{"River request finished", "401"}, {"Gravitas permissions call finished", "200"},
	} {
		buf := make([]byte, newton.DatagramLimit)
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			t.Fatal(err)
		}
		var event newton.Event
		if err := json.Unmarshal(buf[65:n], &event); err != nil {
			t.Fatal(err)
		}
		if event.Message != want.message || event.Params["status"].Value != want.status ||
			event.Params["request_id"].Value != id || event.Params["duration"].Type != "duration_ns" ||
			strings.Contains(string(buf[:n]), "private=content") {
			t.Fatalf("unexpected operational data: %v", event)
		}
	}
}
