// Package views serves HTML CRUD pages for authenticated users.
// Each page is a thin layer over the corresponding API, rendered
// as server-side HTML with Basic auth (browser caches credentials).
package views

import (
	"fmt"
	"net/http"

	"angry-gopher/auth"
)

// RequireAuth returns the authenticated user ID or writes a 401
// response that triggers the browser's Basic auth prompt.
func RequireAuth(w http.ResponseWriter, r *http.Request) int {
	userID := auth.Authenticate(r)
	if userID == 0 {
		w.Header().Set("WWW-Authenticate", `Basic realm="Angry Gopher"`)
		http.Error(w, "Login required", http.StatusUnauthorized)
		return 0
	}
	return userID
}

// PageHeader writes the HTML boilerplate and opens the body.
func PageHeader(w http.ResponseWriter, title string) {
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 700px; }
h1 { color: #000080; }
h2 { color: #000080; margin-top: 24px; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 8px; width: 100%%; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
.muted { color: #888; }
.msg-content { padding: 4px 0; }
textarea { width: 100%%; height: 60px; padding: 6px; box-sizing: border-box; margin: 8px 0; }
button { background: #000080; color: white; border: none; padding: 8px 16px;
         font-size: 14px; cursor: pointer; border-radius: 4px; }
button:hover { background: #0000a0; }
.back { margin-bottom: 16px; display: inline-block; }
</style>
</head><body>
<h1>%s</h1>`, title, title)
}

// PageFooter closes the HTML.
func PageFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</body></html>`)
}
