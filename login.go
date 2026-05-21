// Name login: no password yet, just a name (honor system). A name is
// unique — claimed by creating the player's directory at login. Logging
// in with a free name claims it; with a taken name, we ask whether the
// player is the existing owner on another device (Yes resumes that
// account, No sends them back to pick another). Logout optionally
// releases the account (deletes all data, frees the name).

package main

import (
	"fmt"
	"html"
	"log"
	"net/http"
	"net/url"

	"angry-gopher/auth"
	"angry-gopher/views"
	"angry-gopher/zulip"
)

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		name, errMsg := auth.ValidateUserName(r.FormValue("name"))
		if errMsg != "" {
			renderLoginPage(w, auth.CurrentUser(r), errMsg)
			return
		}
		switch {
		case !views.UserExists(name):
			// Free name — claim the directory (reserving it before any
			// game is played), then log in.
			if err := views.ClaimUser(name); err != nil {
				http.Error(w, "claim user: "+err.Error(), http.StatusInternalServerError)
				return
			}
			loginAs(w, r, name)
		case r.FormValue("confirm_existing") == "yes" || auth.CurrentUser(r) == name:
			// Taken name, honor-system confirmed (or already them):
			// resume that account.
			loginAs(w, r, name)
		default:
			// Taken and unconfirmed — ask whether they're the existing
			// owner logging in from another device.
			renderExistingUserConfirm(w, name)
		}
		return
	}

	// GET: a blank form, or a "that name is taken" nudge after a "No".
	msg := ""
	if taken := auth.SanitizeUser(r.URL.Query().Get("taken")); taken != "" {
		msg = fmt.Sprintf("“%s” is taken. Please pick another name.", taken)
	}
	renderLoginPage(w, auth.CurrentUser(r), msg)
}

// loginAs sets the identity cookie, fires the Zulip ping, and sends the
// player home.
func loginAs(w http.ResponseWriter, r *http.Request, name string) {
	http.SetCookie(w, &http.Cookie{
		Name:     "gopher_user",
		Value:    name,
		Path:     "/",
		MaxAge:   60 * 60 * 24 * 365,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	go zulip.NotifyLogin(name)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// handleLogout shows the logout page (GET) and performs logout (POST).
// A "release" checkbox deletes the account and all its data, freeing the
// name; unchecked (the default) just clears the cookie and keeps the
// data so the player can log back in later.
func handleLogout(w http.ResponseWriter, r *http.Request) {
	user := auth.CurrentUser(r)
	if r.Method == http.MethodPost {
		if r.FormValue("release") == "yes" && user != auth.DefaultUser {
			if err := views.DeleteUserData(user); err != nil {
				log.Printf("logout release for %q: %v", user, err)
			}
		}
		clearUserCookie(w)
		renderLogoutComplete(w)
		return
	}
	if user == auth.DefaultUser {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	renderLogoutPage(w, user)
}

func clearUserCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "gopher_user",
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
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
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
h1 { color: #000080; }
.muted { color: #888; font-size: 14px; }
.err { color: #b00020; font-size: 14px; }
input[type=text] { font-size: 16px; padding: 8px; width: 100%%; box-sizing: border-box; margin: 8px 0; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
button:hover { background: #0000a0; }
</style>
</head><body>
<h1>Log in to Lyn Rummy</h1>
<p class="muted">No password — just a name. Letters, numbers, spaces, and apostrophes; names are unique.</p>
%s%s
<form id="f" method="post" action="/login">
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

// renderExistingUserConfirm asks whether the player is the existing
// owner of a taken name, logging in from another device (honor system).
func renderExistingUserConfirm(w http.ResponseWriter, name string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	esc := html.EscapeString(name)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 440px; padding: 0 24px; }
h1 { color: #000080; font-size: 22px; }
.muted { color: #888; font-size: 14px; }
.row { margin-top: 16px; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
button:hover { background: #0000a0; }
a { color: #000080; }
</style>
</head><body>
<h1>“%s” is already taken</h1>
<p>Are you <strong>%s</strong>, logging in from another device?</p>
<p class="muted">No passwords yet — this is on the honor system.</p>
<form class="row" method="post" action="/login">
  <input type="hidden" name="name" value="%s">
  <input type="hidden" name="confirm_existing" value="yes">
  <button type="submit">Yes, that's me — log me in</button>
</form>
<p class="row"><a href="/login?taken=%s">No — I'll pick another name</a></p>
</body></html>`, esc, esc, esc, url.QueryEscape(name))
}

// renderLogoutPage shows the logout confirmation with the release
// checkbox (default unchecked = keep the account for future logins).
func renderLogoutPage(w http.ResponseWriter, user string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	esc := html.EscapeString(user)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 460px; padding: 0 24px; }
h1 { color: #000080; font-size: 22px; }
.muted { color: #888; font-size: 14px; }
.warn { color: #b00020; font-size: 14px; }
label { display: block; margin: 16px 0 8px; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
button:hover { background: #0000a0; }
a { color: #000080; margin-left: 16px; }
</style>
</head><body>
<h1>Log out</h1>
<p>You're logged in as <strong>%s</strong>.</p>
<form method="post" action="/logout">
  <label><input type="checkbox" name="release" value="yes"> Release my account and all associated data</label>
  <p class="muted">Leave this unchecked to keep your games — you can log back in later from any device.</p>
  <p class="warn">Checking it permanently deletes all of “%s”'s games and puzzles and frees the name.</p>
  <button type="submit">Log out</button>
  <a href="/">Cancel</a>
</form>
</body></html>`, esc, esc)
}

// renderLogoutComplete clears the localStorage name prefill and sends
// the player to the login page.
func renderLogoutComplete(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html><meta charset="utf-8">
<script>
  localStorage.removeItem('gopher_user');
  location.replace('/login');
</script>`)
}
