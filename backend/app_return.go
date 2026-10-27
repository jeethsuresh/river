package main

import (
	"html/template"
	"net/http"
)

// Return links only wake the app. The verifier-bound broker retains the login
// token/session; neither credential is placed in a URL or browser history.
var appReturnPage = template.Must(template.New("return").Parse(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Return to River</title></head><body style="font:18px system-ui;max-width:36rem;margin:10vh auto;padding:24px;background:#f3f7ff;color:#142744"><h1>{{.Message}}</h1><p>Opening River to finish connecting this device.</p><p><a id="return" href="{{.URL}}">Open River</a></p><p>If River does not open automatically, tap Open River or switch back to the app.</p><script>window.location.replace(document.getElementById('return').href)</script></body></html>`))

func returnToApp(w http.ResponseWriter, kind, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = appReturnPage.Execute(w, struct {
		Message string
		URL     template.URL
	}{message, template.URL("river://auth/" + kind)})
}
