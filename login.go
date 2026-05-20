// Name login: no password, just a name. POST sets the gopher_user
// cookie (the server's identity seam) and fires a Zulip ping. The
// client mirrors the name into localStorage for prefill on return.

package main

import (
	"fmt"
	"html"
	"net/http"

	"angry-gopher/auth"
)

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		name := auth.SanitizeUser(r.FormValue("name"))
		if name == "" {
			renderLoginPage(w, auth.CurrentUser(r), "Please enter a name (letters, digits, spaces, - _ .).")
			return
		}
		http.SetCookie(w, &http.Cookie{
			Name:     "gopher_user",
			Value:    name,
			Path:     "/",
			MaxAge:   60 * 60 * 24 * 365,
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
		go notifyLogin(name)
		http.Redirect(w, r, "/gopher/", http.StatusSeeOther)
		return
	}
	renderLoginPage(w, auth.CurrentUser(r), "")
}

func renderLoginPage(w http.ResponseWriter, current, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	currentLine := ""
	if current != "" && current != auth.DefaultUser {
		currentLine = fmt.Sprintf(
			`<p class="muted">Currently playing as <strong>%s</strong>.</p>`,
			html.EscapeString(current))
	}
	errLine := ""
	if errMsg != "" {
		errLine = fmt.Sprintf(`<p class="err">%s</p>`, html.EscapeString(errMsg))
	}

	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Log in — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
h1 { color: #000080; }
.muted { color: #888; font-size: 14px; }
.err { color: #b00020; font-size: 14px; }
input { font-size: 16px; padding: 8px; width: 100%%; box-sizing: border-box; margin: 8px 0; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
button:hover { background: #0000a0; }
nav { font-size: 13px; margin-bottom: 16px; } nav a { color: #000080; }
</style>
</head><body>
<nav><a href="/gopher/">← Gopher home</a></nav>
<h1>Log in to Lyn Rummy</h1>
<p class="muted">No password — just a name so your games are saved under it.</p>
%s%s
<form id="f" method="post" action="/gopher/login">
  <input id="name" name="name" type="text" maxlength="40" placeholder="Your name" autofocus>
  <button type="submit">Continue</button>
</form>
<script>
  var inp = document.getElementById('name');
  if (!inp.value) { var n = localStorage.getItem('gopher_user'); if (n) inp.value = n; }
  document.getElementById('f').addEventListener('submit', function () {
    localStorage.setItem('gopher_user', inp.value);
  });
</script>
</body></html>`, currentLine, errLine)
}
