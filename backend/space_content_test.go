package main

import (
	"net/http/httptest"
	"testing"
)

func TestSpaceEntryRoutes(t *testing.T) {
	base := "/api/spaces/11111111-1111-4111-8111-111111111111"
	for _, route := range []struct{ method, path, upstream string }{
		{"GET", base + "/entries", "/app/v1/spaces/11111111-1111-4111-8111-111111111111/entries"},
		{"POST", base + "/entry", "/app/v1/spaces/11111111-1111-4111-8111-111111111111/entry"},
		{"PUT", base + "/entries/cool.gravitas.river.post.v1/txn", "/app/v1/spaces/11111111-1111-4111-8111-111111111111/entries/cool.gravitas.river.post.v1/txn"},
		{"PUT", base + "/entries/cool.gravitas.river.discussion.v1/txn", "/app/v1/spaces/11111111-1111-4111-8111-111111111111/entries/cool.gravitas.river.discussion.v1/txn"},
		{"PUT", base + "/entries/m.room.message/txn", ""},
		{"PUT", base + "/entries/m.room.member/txn", ""},
		{"GET", "/api/spaces/invalid/entries", ""},
	} {
		got, ok := proxyRoute(httptest.NewRequest(route.method, route.path, nil))
		if got != route.upstream || ok != (route.upstream != "") {
			t.Errorf("%s %s: got %q, %v", route.method, route.path, got, ok)
		}
	}
}
