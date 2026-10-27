package main

import (
	"mime"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
)

func acceptsGzip(value string) bool {
	wildcard := false
	for _, entry := range strings.Split(value, ",") {
		parts := strings.Split(entry, ";")
		encoding := strings.TrimSpace(strings.ToLower(parts[0]))
		quality := 1.0
		for _, param := range parts[1:] {
			key, raw, ok := strings.Cut(strings.TrimSpace(param), "=")
			if ok && key == "q" {
				q, err := strconv.ParseFloat(raw, 64)
				if err != nil || q < 0 || q > 1 {
					quality = 0
				} else {
					quality = q
				}
			}
		}
		if encoding == "gzip" {
			return quality > 0
		}
		if encoding == "*" {
			wildcard = quality > 0
		}
	}
	return wildcard
}

func serveStatic(w http.ResponseWriter, r *http.Request, root *os.Root, file string) {
	served, compressed := file, false
	if info, err := root.Stat(file + ".gz"); err == nil && !info.IsDir() {
		w.Header().Add("Vary", "Accept-Encoding")
		if acceptsGzip(r.Header.Get("Accept-Encoding")) {
			served, compressed = file+".gz", true
			w.Header().Set("Content-Encoding", "gzip")
			if contentType := mime.TypeByExtension(path.Ext(file)); contentType != "" {
				w.Header().Set("Content-Type", contentType)
			}
		}
	}
	// Revalidate unversioned Flutter assets so releases cannot mix bundles.
	// Entry HTML and authentication responses retain their no-store policy.
	if path.Ext(file) != ".html" {
		w.Header().Set("Cache-Control", "public, max-age=0, must-revalidate")
		if raw, err := root.ReadFile(file + ".etag"); err == nil {
			digest := strings.TrimSpace(string(raw))
			if len(digest) == 64 && strings.Trim(digest, "0123456789abcdef") == "" {
				if compressed {
					digest += "-gzip"
				}
				w.Header().Set("ETag", `"`+digest+`"`)
			}
		}
	}
	http.ServeFileFS(w, r, root.FS(), served)
}
