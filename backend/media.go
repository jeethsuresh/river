package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

const maxLinkedMedia = 25 << 20

var mediaSlots = make(chan struct{}, 2)

// Browser image decoding and sticker downloads need same-origin bytes even
// when the image host does not offer CORS. This client never carries a session,
// honors no environment proxy, and validates the actual address at dial time.
var linkedMediaClient = &http.Client{
	Timeout: 20 * time.Second,
	Transport: &http.Transport{
		DialContext:            publicMediaDial,
		TLSHandshakeTimeout:    5 * time.Second,
		ResponseHeaderTimeout:  10 * time.Second,
		MaxResponseHeaderBytes: 16 << 10,
		MaxIdleConns:           16,
		IdleConnTimeout:        30 * time.Second,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 3 || !validMediaURL(req.URL) {
			return errors.New("invalid image redirect")
		}
		return nil
	},
}

func validMediaURL(u *url.URL) bool {
	return u != nil && len(u.String()) <= 2048 && (u.Scheme == "https" || u.Scheme == "http") &&
		u.Hostname() != "" && u.User == nil && (u.Port() == "" || u.Port() == "443" || u.Port() == "80") &&
		!strings.ContainsAny(u.String(), "\\\r\n\t ")
}

var nonPublicMedia = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:db8::/32"), netip.MustParsePrefix("64:ff9b::/96"),
	netip.MustParsePrefix("2001::/32"),
	netip.MustParsePrefix("64:ff9b:1::/48"), netip.MustParsePrefix("2002::/16"),
}

func publicMediaIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	for _, prefix := range nonPublicMedia {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

func publicMediaDial(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	if port != "80" && port != "443" {
		return nil, errors.New("invalid image port")
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, errors.New("image host unavailable")
	}
	for _, ip := range ips {
		if !publicMediaIP(ip) {
			return nil, errors.New("non-public image host")
		}
	}
	// Dial the validated numeric address; never resolve it again after validation.
	dialer := net.Dialer{Timeout: 5 * time.Second}
	for _, ip := range ips {
		conn, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if dialErr == nil {
			return conn, nil
		}
		err = dialErr
	}
	return nil, err
}

func linkedImageType(data []byte) string {
	kind := http.DetectContentType(data)
	switch kind {
	case "image/gif", "image/png", "image/jpeg", "image/webp", "image/bmp":
		return kind
	}
	if len(data) >= 12 && string(data[4:8]) == "ftyp" && (string(data[8:12]) == "avif" || string(data[8:12]) == "avis") {
		return "image/avif"
	}
	return ""
}

func serveLinkedMedia(w http.ResponseWriter, r *http.Request, client *http.Client) {
	if r.Method != "GET" {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	u, err := url.Parse(r.URL.Query().Get("url"))
	if err != nil || !validMediaURL(u) {
		fail(w, 400, "Invalid image URL")
		return
	}
	select {
	case mediaSlots <- struct{}{}:
		defer func() { <-mediaSlots }()
	default:
		fail(w, 429, "Too many images loading. Try again.")
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), "GET", u.String(), nil)
	if err != nil {
		fail(w, 400, "Invalid image URL")
		return
	}
	req.Header.Set("Accept", "image/avif,image/webp,image/png,image/jpeg,image/gif,image/bmp")
	response, err := client.Do(req)
	if err != nil {
		fail(w, 502, "Unable to load image")
		return
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || response.ContentLength > maxLinkedMedia {
		fail(w, 502, "Image unavailable or too large")
		return
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxLinkedMedia+1))
	if err != nil || len(data) > maxLinkedMedia {
		fail(w, 413, "Image unavailable or too large")
		return
	}
	kind := linkedImageType(data)
	if kind == "" {
		fail(w, 415, "Unsupported image data")
		return
	}
	w.Header().Set("Content-Type", kind)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.WriteHeader(200)
	_, _ = w.Write(data)
}
