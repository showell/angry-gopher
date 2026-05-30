// Login. Two tiers, both keyed by a numeric user id (the cookie carries
// the id, not the name):
//   /login       — guests: pick a non-reserved name; a fresh login
//                  allocates a new user id. Plays Lyn Rummy, no chat.
//   /login/full  — members: name + password. An existing member name
//                  verifies; a new name creates an account (confirm step)
//                  and reserves the name. Members get a signed session.
// Logout clears the cookies; release also deletes the user's data + record.

package login

import (
	"fmt"
	"html"
	"log"
	"net/http"
	"strings"

	"angry-gopher/server/lynrummy"
	"angry-gopher/server/users"
)

func HandleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		name, errMsg := users.ValidateUserName(r.FormValue("name"))
		if errMsg != "" {
			renderLoginPage(w, users.CurrentUser(r).Name, errMsg)
			return
		}
		if users.IsNameReserved(name) {
			// Password-protected name — guests can't claim it.
			renderReservedNotice(w, name)
			return
		}
		// Guests are honor-system: a fresh login allocates a new user id
		// with this name. Identity is the cookie; protect a name by
		// becoming a member.
		id, err := users.AllocateUser(name)
		if err != nil {
			http.Error(w, "allocate user: "+err.Error(), http.StatusInternalServerError)
			return
		}
		loginAsGuest(w, r, id)
		return
	}
	renderLoginPage(w, users.CurrentUser(r).Name, "")
}

// loginAsGuest sets the identity cookie to a passwordless user id, clears
// any stale member session, and sends the player home.
func loginAsGuest(w http.ResponseWriter, r *http.Request, id string) {
	setUIDCookie(w, id)
	users.ClearAuthCookie(w) // a guest login is not an authenticated member
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

// handleLoginFull is the password gate for chat. The name is fixed to the
// identity you already have — your guest name, or an explicit ?name= from
// the reserved-name notice; there's no name editing here. A returning
// member verifies their password; a guest completes registration by
// entering a password twice on one screen, which reserves their name. On
// success it issues a member session and returns to `next`.
func HandleLoginFull(w http.ResponseWriter, r *http.Request) {
	next := sanitizeNext(r.FormValue("next"))

	// The name is fixed: an explicit name (reserved-name notice) wins, else
	// the current guest's name. With no usable name, identify first.
	raw := users.SanitizeUser(r.FormValue("name"))
	if raw == "" {
		raw = users.CurrentUser(r).Name
	}
	name, errMsg := users.ValidateUserName(raw)
	if errMsg != "" {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	memberID, isMember := users.FindMemberByName(name)

	if r.Method != http.MethodPost {
		if isMember {
			renderFullLoginPage(w, name, next, "")
		} else {
			renderRegisterPage(w, name, next, "")
		}
		return
	}

	password := r.FormValue("password")
	if isMember {
		// Returning member — verify their password.
		if !users.CheckUserPassword(memberID, password) {
			renderFullLoginPage(w, name, next, fmt.Sprintf("Wrong password for “%s”.", name))
			return
		}
		loginAsMember(w, r, memberID, next)
		return
	}

	// Registration — the same password in both boxes, on one screen.
	if password == "" {
		renderRegisterPage(w, name, next, "Please enter a password.")
		return
	}
	if password != r.FormValue("confirm") {
		renderRegisterPage(w, name, next, "The two passwords don't match — please re-enter them.")
		return
	}
	id, err := registerMember(r, name, password)
	if err != nil {
		http.Error(w, "register: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// Notify subscribers (currently: chat's sidebar SSE) that a new
	// authorized principal exists. Whether this was a fresh allocation
	// or a guest→member promotion, they were NOT a chat partner before
	// and ARE one now — that's what the sidebar cares about.
	users.FireNewMember(id, name)
	loginAsMember(w, r, id, next)
}

// registerMember turns `name` into a password member and returns its id. If
// the current guest IS this name (not yet a member), it upgrades that
// guest's id in place so their identity and data carry over; otherwise it
// allocates a fresh id.
func registerMember(r *http.Request, name, password string) (string, error) {
	if cur := users.CurrentUser(r); cur.ID != "" && !cur.Member && cur.Name == name {
		return cur.ID, users.SetUserPassword(cur.ID, password)
	}
	id, err := users.AllocateUser(name)
	if err != nil {
		return "", err
	}
	return id, users.SetUserPassword(id, password)
}

// loginAsMember sets the identity cookie + signed member session for a
// user id and returns to `next`.
func loginAsMember(w http.ResponseWriter, r *http.Request, id, next string) {
	setUIDCookie(w, id)
	users.SetAuthCookie(w, id)
	users.TouchUser(id) // logging on counts as activity
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
func HandleLogout(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	if r.Method == http.MethodPost {
		if r.FormValue("release") == "yes" && user.ID != "" {
			// Release: delete game data and the user record (frees the
			// name; no id is ever reissued, so no name-backdoor remains).
			if err := lynrummy.DeleteUserData(user.ID); err != nil {
				log.Printf("logout release game data %q: %v", user.ID, err)
			}
			if err := users.DeleteUserRecord(user.ID); err != nil {
				log.Printf("logout release record %q: %v", user.ID, err)
			}
		}
		clearUserCookie(w)
		users.ClearAuthCookie(w)
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

// loginFullCSS is the shared stylesheet for the chat password screens.
const loginFullCSS = `<style>
body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
h1 { color: #000080; font-size: 24px; }
.muted { color: #888; font-size: 14px; }
.err { color: #b00020; font-size: 14px; }
.name { font-size: 18px; font-weight: bold; color: #000080; margin: 12px 0 4px; }
label { display: block; font-size: 13px; color: #444; margin-top: 10px; }
input[type=password] { font-size: 16px; padding: 8px; width: 100%; box-sizing: border-box; margin: 4px 0; }
button { background: #000080; color: white; border: none; padding: 10px 20px;
         font-size: 15px; border-radius: 4px; cursor: pointer; margin-top: 12px; }
a { color: #000080; }
</style>`

// renderFullLoginPage is the returning-member screen: a fixed (read-only)
// name and one password to verify.
func renderFullLoginPage(w http.ResponseWriter, name, next, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	errLine := ""
	if errMsg != "" {
		errLine = fmt.Sprintf(`<p class="err">%s</p>`, html.EscapeString(errMsg))
	}
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
%s</head><body>
<h1>Log in to chat</h1>
<p class="muted">Enter the password for this name.</p>
<div class="name">%s</div>
%s
<form method="post" action="/login/full">
  <input type="hidden" name="name" value="%s">
  <input type="hidden" name="next" value="%s">
  <label>Password</label>
  <input name="password" type="password" autofocus>
  <button type="submit">Log in</button>
</form>
<p class="muted" style="margin-top:16px"><a href="/login">← Use a different name</a></p>
</body></html>`, loginFullCSS, html.EscapeString(name), errLine, html.EscapeString(name), html.EscapeString(next))
}

// renderRegisterPage is the guest→member screen: the name is fixed
// (read-only) and the password is entered twice on one screen.
func renderRegisterPage(w http.ResponseWriter, name, next, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	errLine := ""
	if errMsg != "" {
		errLine = fmt.Sprintf(`<p class="err">%s</p>`, html.EscapeString(errMsg))
	}
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
%s</head><body>
<h1>Complete registration with password</h1>
<p class="muted">Chat needs a password. This reserves your name so only you can use it.</p>
<div class="name">%s</div>
%s
<form method="post" action="/login/full">
  <input type="hidden" name="name" value="%s">
  <input type="hidden" name="next" value="%s">
  <label>Password</label>
  <input name="password" type="password" autofocus>
  <label>Confirm password</label>
  <input name="confirm" type="password">
  <button type="submit">Complete registration</button>
</form>
<p class="muted" style="margin-top:16px"><a href="/">← Back</a> · Just want to play? <a href="/login">Play as a guest</a></p>
</body></html>`, loginFullCSS, html.EscapeString(name), errLine, html.EscapeString(name), html.EscapeString(next))
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
