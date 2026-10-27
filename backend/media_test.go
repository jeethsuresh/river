package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"
)

func TestLinkedMediaPublicAddresses(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.100.100.200", "0.0.0.0", "224.0.0.1", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "64:ff9b::a00:1", "2002:7f00:1::"} {
		if publicMediaIP(netip.MustParseAddr(address)) {
			t.Errorf("allowed private image address %s", address)
		}
	}
	for _, address := range []string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"} {
		if !publicMediaIP(netip.MustParseAddr(address)) {
			t.Errorf("rejected public image address %s", address)
		}
	}
	if conn, err := publicMediaDial(context.Background(), "tcp", "127.0.0.1:80"); err == nil {
		conn.Close()
		t.Fatal("dialed private host")
	}
}

func TestLinkedMediaURLsAndRedirects(t *testing.T) {
	for _, value := range []string{"file:///secret", "data:image/gif;base64,AA", "https://user:secret@host/a.gif", "https://host:22/a.gif", "//host/a.gif", "https://host/" + strings.Repeat("a", 2048)} {
		u, err := url.Parse(value)
		if err == nil && validMediaURL(u) {
			t.Errorf("accepted %s", value)
		}
	}
	request, _ := http.NewRequest("GET", "https://example.com/a.gif", nil)
	if linkedMediaClient.CheckRedirect(request, make([]*http.Request, 3)) == nil {
		t.Fatal("unbounded redirects")
	}
}

func TestLinkedMediaRetainsGIFBytesAndNeverForwardsCredentials(t *testing.T) {
	gif, _ := base64.StdEncoding.DecodeString("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("Referer") != "" {
			t.Fatal("credentials forwarded to image host")
		}
		if r.UserAgent() != "River (+https://github.com/jeethsuresh/river)" {
			return &http.Response{StatusCode: http.StatusForbidden, Body: io.NopCloser(strings.NewReader("Identify your image client")), Header: http.Header{}}, nil
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(gif)), Header: http.Header{"Set-Cookie": {"tracker=yes"}}}, nil
	})}
	r := httptest.NewRequest("GET", "/api/public/media?url="+url.QueryEscape("https://example.com/a.gif"), nil)
	r.Header.Set("Authorization", "Bearer private-session")
	r.Header.Set("Cookie", "session=private")
	w := httptest.NewRecorder()
	serveLinkedMedia(w, r, client)
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), gif) || w.Header().Get("Content-Type") != "image/gif" || w.Header().Get("Set-Cookie") != "" {
		t.Fatal(w.Code, w.Header())
	}
}

func TestLinkedMediaRejectsHTMLAndOversizedStreams(t *testing.T) {
	for _, tc := range []struct {
		body   string
		size   int64
		status int
	}{
		{"<html>not an image</html>", 0, 415}, {"GIF89a", maxLinkedMedia + 1, 502},
		{strings.Repeat("x", maxLinkedMedia+1), -1, 413},
	} {
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, ContentLength: tc.size, Body: io.NopCloser(strings.NewReader(tc.body)), Header: http.Header{}}, nil
		})}
		w := httptest.NewRecorder()
		serveLinkedMedia(w, httptest.NewRequest("GET", "/api/public/media?url=https://example.com/a.gif", nil), client)
		if w.Code != tc.status {
			t.Fatalf("expected %d, got %d", tc.status, w.Code)
		}
	}
}

func TestPublicPostReactionsRequireLogin(t *testing.T) {
	s, _, _, _ := fixture(t)
	for _, target := range []string{"/api/posts/$river_post/reactions", "/api/groups/11111111-1111-4111-8111-111111111111/reactions"} {
		w := request(s, "POST", target, `{"key":"sticker:https://example.com/a.gif","active":true}`, "")
		if w.Code != 401 {
			t.Fatalf("anonymous reaction returned %d", w.Code)
		}
	}
}
