package main

import "net/http"

// River is a client of the configured Gravitas homeserver. Client discovery
// keeps its public web address usable in other Matrix clients without claiming
// that River's hostname is a separate Matrix server identity.
func (s *server) matrixDiscovery(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
	switch r.Method {
	case http.MethodOptions:
		w.WriteHeader(http.StatusNoContent)
	case http.MethodGet, http.MethodHead:
		w.Header().Set("Cache-Control", "public, max-age=300")
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		respond(w, http.StatusOK, map[string]any{
			"m.homeserver": map[string]string{"base_url": s.auth.Issuer},
		})
	default:
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		fail(w, http.StatusMethodNotAllowed, "Method not allowed")
	}
}
