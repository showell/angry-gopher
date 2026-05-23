// Login. Two tiers, both keyed by a numeric user id (the cookie carries
// the id, not the name):
//   /login       — guests: pick a non-reserved name; a fresh login
//                  allocates a new user id. Plays Lyn Rummy, no chat.
//   /login/full  — members: name + password. An existing member name
//                  verifies; a new name creates an account (confirm step)
//                  and reserves the name. Members get a signed session.
// Logout clears the cookies; release also deletes the user's data + record.

package main

import (
	"fmt"
	"html"
	"log"
	"net/http"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/views"
)

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		name, errMsg := auth.ValidateUserName(r.FormValue("name"))
		if errMsg != "" {
			renderLoginPage(w, views.CurrentUser(r).Name, errMsg)
			return
		}
		if views.IsNameReserved(name) {
			// Password-protected name — guests can't claim it.
			renderReservedNotice(w, name)
			return
		}
		// Guests are honor-system: a fresh login allocates a new user id
		// with this name. Identity is the cookie; protect a name by
		// becoming a member.
		id, err := views.AllocateUser(name)
		if err != nil {
			http.Error(w, "allocate user: "+err.Error(), http.StatusInternalServerError)
			return
		}
		loginAsGuest(w, r, id)
		return
	}
	renderLoginPage(w, views.CurrentUser(r).Name, "")
}

// loginAsGuest sets the identity cookie to a passwordless user id, clears
// any stale member session, and sends the player home.
func loginAsGuest(w http.ResponseWriter, r *http.Request, id string) {
	setUIDCookie(w, id)
	views.ClearAuthCookie(w) // a guest login is not an authenticated member
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// setUIDCookie sets the long-lived identity cookie (the user id).
func setUIDCookie(w http.ResponseWriter, id string) {
	http.SetCookie(w, &http.Cookie{
		Name:     "gopher_uid",
		Value:    id,
		Path:     "/",
		MaxAge:   60 * 60 * 24 * 365,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

// handleLoginFull is the password login for chat members. An existing
// member name verifies its password; a free name creates an account (with
// a confirm step) and reserves the name. On success it issues a member
// session for that user id and returns to `next`.
func handleLoginFull(w http.ResponseWriter, r *http.Request) {
	next := sanitizeNext(r.FormValue("next"))
	if r.Method == http.MethodPost {
		name, errMsg := auth.ValidateUserName(r.FormValue("name"))
		if errMsg != "" {
			renderFullLoginPage(w, r.FormValue("name"), next, errMsg)
			return
		}
		password := r.FormValue("password")
		if password == "" {
			renderFullLoginPage(w, name, next, "Please enter a password.")
			return
		}
		if id, ok := views.FindMemberByName(name); ok {
			// Returning member — verify; no confirm step.
			if !views.CheckUserPassword(id, password) {
				renderFullLoginPage(w, name, next, fmt.Sprintf("Wrong password for “%s”.", name))
				return
			}
			loginAsMember(w, r, id, next)
			return
		}
		// New name — require a confirmation step (first entry carried as a
		// bcrypt hash, never plaintext), then create the account.
		pending := r.FormValue("pending")
		if pending == "" {
			h, err := views.HashPassword(password)
			if err != nil {
				http.Error(w, "hash: "+err.Error(), http.StatusInternalServerError)
				return
			}
			renderCreateConfirmPage(w, name, next, h, "")
			return
		}
		if !views.PasswordMatchesHash(pending, password) {
			renderCreateConfirmPage(w, name, next, pending, "That didn't match — re-enter the same password.")
			return
		}
		id, err := views.AllocateUser(name)
		if err != nil {
			http.Error(w, "allocate user: "+err.Error(), http.StatusInternalServerError)
			return
		}
		if err := views.SetUserPassword(id, password); err != nil {
			http.Error(w, "set password: "+err.Error(), http.StatusInternalServerError)
			return
		}
		loginAsMember(w, r, id, next)
		return
	}
	renderFullLoginPage(w, auth.SanitizeUser(r.URL.Query().Get("name")), next, "")
}

// loginAsMember sets the identity cookie + signed member session for a
// user id and returns to `next`.
func loginAsMember(w http.ResponseWriter, r *http.Request, id, next string) {
	setUIDCookie(w, id)
	views.SetAuthCookie(w, id)
	http.Redirect(w, r, next, http.StatusSeeOther)
}

// sanitizeNext keeps only internal redirect targets, to avoid open
// redirects.
func sanitizeNext(next string) string {
	if strings.HasPrefix(next, "/") && !strings.HasPrefix(next, "//") {
		return next
	}
	return "/"
}

// handleLogout shows the logout page (GET) and performs logout (POST).
// A "release" checkbox deletes the account and all its data, freeing the
// name; unchecked (the default) just clears the cookie and keeps the
// data so the player can log back in later.
func handleLogout(w http.ResponseWriter, r *http.Request) {
	user := views.CurrentUser(r)
	if r.Method == http.MethodPost {
		if r.FormValue("release") == "yes" && user.ID != "" {
			// Release: delete game data and the user record (frees the
			// name; no id is ever reissued, so no name-backdoor remains).
			if err := views.DeleteUserData(user.ID); err != nil {
				log.Printf("logout release game data %q: %v", user.ID, err)
			}
			if err := views.DeleteUserRecord(user.ID); err != nil {
				log.Printf("logout release record %q: %v", user.ID, err)
			}
		}
		clearUserCookie(w)
		views.ClearAuthCookie(w)
		renderLogoutComplete(w)
		return
	}
	if user.ID == "" {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	renderLogoutPage(w, user.Name)
}

func clearUserCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "gopher_uid",
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
	if current != "" {
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

// renderReservedNotice tells a guest that a name belongs to a member,
// offering the password login or a different name.
func renderReservedNotice(w http.ResponseWriter, name string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	esc := html.EscapeString(name)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 440px; padding: 0 24px; }
h1 { color: #000080; font-size: 22px; }
.muted { color: #888; font-size: 14px; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
a { color: #000080; }
</style></head><body>
<h1>“%s” is reserved</h1>
<p>That name belongs to a registered member.</p>
<form method="get" action="/login/full"><input type="hidden" name="name" value="%s">
  <button type="submit">Log in with your password</button></form>
<p class="muted" style="margin-top:16px"><a href="/login">← Pick a different name</a></p>
</body></html>`, esc, esc)
}

// renderFullLoginPage is the member (password) login screen.
func renderFullLoginPage(w http.ResponseWriter, name, next, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
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
input[type=text], input[type=password] { font-size: 16px; padding: 8px; width: 100%%; box-sizing: border-box; margin: 8px 0; }
label { font-size: 13px; color: #444; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
a { color: #000080; }
</style></head><body>
<h1>Log in to chat</h1>
<p class="muted">Chat needs a password-protected name. New here? Your name + password reserves it. Returning? Enter your password.</p>
%s
<form method="post" action="/login/full">
  <input type="hidden" name="next" value="%s">
  <input name="name" type="text" maxlength="40" placeholder="Your name" value="%s" autofocus>
  <input name="password" type="password" placeholder="Password">
  <button type="submit">Continue</button>
</form>
<p class="muted" style="margin-top:16px"><a href="/">← Back</a> · Just want to play? <a href="/login">Play as a guest</a></p>
</body></html>`, errLine, html.EscapeString(next), html.EscapeString(name))
}

// renderCreateConfirmPage is the second step of new-account creation: the
// member re-enters the password they just chose (the first entry rides
// along as a bcrypt hash in `pending`, never as plaintext).
func renderCreateConfirmPage(w http.ResponseWriter, name, next, pending, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
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
input[type=password] { font-size: 16px; padding: 8px; width: 100%%; box-sizing: border-box; margin: 8px 0; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; }
a { color: #000080; }
</style></head><body>
<h1>Create your account</h1>
<p class="muted">New name “%s” — re-enter your password to confirm and create the account.</p>
%s
<form method="post" action="/login/full">
  <input type="hidden" name="name" value="%s">
  <input type="hidden" name="next" value="%s">
  <input type="hidden" name="pending" value="%s">
  <input name="password" type="password" placeholder="Re-enter password" autofocus>
  <button type="submit">Create account</button>
</form>
<p class="muted" style="margin-top:16px"><a href="/login/full">← Start over</a></p>
</body></html>`, html.EscapeString(name), errLine, html.EscapeString(name), html.EscapeString(next), html.EscapeString(pending))
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
