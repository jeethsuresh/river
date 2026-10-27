package main

import (
	"net/http/httptest"
	"testing"
)

func TestSubgroupRelayIsGroupScopedAndReadOnly(t *testing.T) {
	path := "/api/groups/11111111-1111-4111-8111-111111111111/subgroups"
	target, ok := proxyRoute(httptest.NewRequest("GET", path, nil))
	if !ok || target != "/app/v1/groups/11111111-1111-4111-8111-111111111111/subgroups" {
		t.Fatalf("wrong subgroup route: %s %v", target, ok)
	}
	for _, method := range []string{"POST", "PUT", "DELETE", "PATCH"} {
		if _, ok := proxyRoute(httptest.NewRequest(method, path, nil)); ok {
			t.Fatalf("subgroup mutation exposed through %s", method)
		}
	}
	for _, path := range []string{"/api/subgroups", "/api/groups/unknown/subgroups", path + "/hidden"} {
		if _, ok := proxyRoute(httptest.NewRequest("GET", path, nil)); ok {
			t.Fatalf("unscoped subgroup route accepted: %s", path)
		}
	}
}
