package main

import (
	"context"
	"crypto/rand"
	"log"
	"net/http"
	"os"
	"time"

	newton "github.com/jeethsuresh/newtond/log"
)

const newtonRequestHeader = "X-NewtonD-Request-ID"

type newtonRequestKey struct{}

type newtonSender struct {
	sender *newton.UDPSender
}

func setupNewtonD() *newtonSender {
	address := os.Getenv("NEWTOND_UDP_ADDRESS")
	if address == "" {
		return nil
	}
	sender, err := newton.NewUDPSender(context.Background(), address, "river", []byte(os.Getenv("NEWTOND_UDP_KEY")))
	if err != nil {
		log.Printf("newtonD sender disabled: %v", err)
		return nil
	}
	return &newtonSender{sender: sender}
}

type observedResponse struct {
	http.ResponseWriter
	status int
}

func (w *observedResponse) WriteHeader(status int) {
	if w.status == 0 && status >= 200 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *observedResponse) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(body)
}

func (w *observedResponse) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (s *newtonSender) observe(w http.ResponseWriter, r *http.Request) (http.ResponseWriter, *http.Request, func()) {
	id, started := rand.Text(), time.Now()
	out := &observedResponse{ResponseWriter: w}
	w.Header().Set(newtonRequestHeader, id)
	r = r.WithContext(context.WithValue(r.Context(), newtonRequestKey{}, id))
	finish := func() {
		status := out.status
		if status == 0 {
			status = http.StatusOK
		}
		s.sender.Emit("info", newton.MsgFormat{Msg: "River request finished", Params: map[string]any{
			"route": r.URL.Path, "status": status, "duration": time.Since(started), "request_id": id,
		}})
	}
	return out, r, finish
}

func (s *server) observeIAMPermissions(req *http.Request, issuer string) func(*http.Response, error) {
	id, _ := req.Context().Value(newtonRequestKey{}).(string)
	if s.newtond == nil || id == "" || issuer != "https://gravitas.cool" {
		return func(*http.Response, error) {}
	}
	req.Header.Set(newtonRequestHeader, id)
	started := time.Now()
	return func(response *http.Response, err error) {
		status := 0
		if err == nil && response != nil {
			status = response.StatusCode
		}
		s.newtond.sender.Emit("info", newton.MsgFormat{Msg: "Gravitas permissions call finished", Params: map[string]any{
			"status": status, "duration": time.Since(started), "request_id": id,
		}})
	}
}
