package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStaticCompressionAndReleaseRevalidation(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(strings.Repeat("web assembly fixture", 1000))
	var compressed bytes.Buffer
	gz := gzip.NewWriter(&compressed)
	_, _ = gz.Write(raw)
	_ = gz.Close()
	for name, data := range map[string][]byte{
		"app.wasm": raw, "app.wasm.gz": compressed.Bytes(),
		"app.wasm.etag": []byte(fmt.Sprintf("%x", sha256.Sum256(raw))),
		"index.html":    []byte("app shell"),
	} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	r := httptest.NewRequest("GET", "/app.wasm", nil)
	r.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()
	serveStatic(w, r, root, "app.wasm")
	if w.Code != 200 || w.Header().Get("Content-Encoding") != "gzip" || w.Header().Get("Content-Type") != "application/wasm" {
		t.Fatalf("bad compressed response: %d %v", w.Code, w.Header())
	}
	reader, err := gzip.NewReader(w.Body)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(reader)
	if err != nil || !bytes.Equal(decoded, raw) {
		t.Fatal("corrupt compressed asset")
	}
	etag := w.Header().Get("ETag")
	r.Header.Set("If-None-Match", etag)
	w = httptest.NewRecorder()
	serveStatic(w, r, root, "app.wasm")
	if w.Code != 304 || w.Body.Len() != 0 {
		t.Fatalf("cache did not revalidate: %d", w.Code)
	}
	r.Header.Set("Accept-Encoding", "gzip;q=0, *;q=1")
	r.Header.Del("If-None-Match")
	w = httptest.NewRecorder()
	serveStatic(w, r, root, "app.wasm")
	if w.Header().Get("Content-Encoding") != "" || !bytes.Equal(w.Body.Bytes(), raw) || w.Header().Get("ETag") == etag {
		t.Fatal("identity negotiation or variant ETag failed")
	}
	w = httptest.NewRecorder()
	w.Header().Set("Cache-Control", "no-store")
	serveStatic(w, httptest.NewRequest("GET", "/", nil), root, "index.html")
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("HTML must remain no-store")
	}
	if err := os.WriteFile(filepath.Join(dir, "app.wasm.etag"), []byte(strings.Repeat("a", 64)), 0600); err != nil {
		t.Fatal(err)
	}
	r.Header.Set("If-None-Match", etag)
	w = httptest.NewRecorder()
	serveStatic(w, r, root, "app.wasm")
	if w.Code != 200 {
		t.Fatal("new release incorrectly returned 304")
	}
}
