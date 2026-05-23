// User settings. The first setting is a read-only API key for bots,
// reached from the chat subsystem (see chatChromeTop). Self-service is safe
// because the endpoint acts on the SESSION identity — never a user id from
// the request — so a member can only manage their OWN key, and that key
// grants a strict subset of the session's own access (read-only,
// admin-stripped). More settings (display name, password, prefs) will
// slot in as sections here.
package views

import (
	"fmt"
	"net/http"
	"net/url"
)

// requireMember returns the authenticated member, or the zero User after
// redirecting a non-member to the full login (carrying `next`).
func requireMember(w http.ResponseWriter, r *http.Request, next string) User {
	if !IsMember(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape(next), http.StatusSeeOther)
		return User{}
	}
	return CurrentUser(r)
}

// HandleSettings serves the member settings page.
func HandleSettings(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/settings" {
		http.NotFound(w, r)
		return
	}
	user := requireMember(w, r, "/settings")
	if user.ID == "" {
		return
	}
	renderSettings(w, r, user)
}

// HandleSettingsAPIKey generates or revokes the CURRENT member's API key.
// It always acts on the session identity (never a request-supplied user
// id), so a member can only manage their own key.
func HandleSettingsAPIKey(w http.ResponseWriter, r *http.Request) {
	user := requireMember(w, r, "/settings")
	if user.ID == "" {
		return
	}
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/settings", http.StatusSeeOther)
		return
	}
	if r.FormValue("revoke") == "1" {
		if err := ClearUserAPIKey(user.ID); err != nil {
			http.Error(w, "revoke: "+err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/settings?keyrevoked=1", http.StatusSeeOther)
		return
	}
	key, err := SetUserAPIKey(user.ID)
	if err != nil {
		http.Error(w, "generate: "+err.Error(), http.StatusInternalServerError)
		return
	}
	renderAPIKeyShown(w, user.ID, key, "/settings", "Settings")
}

func renderSettings(w http.ResponseWriter, r *http.Request, user User) {
	chatPageHeader(w, "Settings", user, "settings")

	if r.URL.Query().Get("keyrevoked") == "1" {
		fmt.Fprint(w, `<p class="flash">Your API key was revoked.</p>`)
	}

	fmt.Fprint(w, `<h2>API key</h2>
<p class="muted">A read-only key lets a bot read your conversations through the chat API —
it can't send messages or change your account. Hand it to the bot via the
<code>GOPHER_API_KEY</code> environment variable, not in a prompt; revoke it here anytime.</p>`)

	status, gen := "You don't have an API key yet.", "Generate key"
	if UserHasAPIKey(user.ID) {
		status = "You have an API key. For security, the key itself is shown only once — when you generate it."
		gen = "Regenerate key"
	}
	fmt.Fprintf(w, `<p>%s</p>
<form method="post" action="/settings/apikey" style="display:inline">
  <button type="submit">%s</button>
</form>`, status, gen)
	if UserHasAPIKey(user.ID) {
		fmt.Fprint(w, ` <form method="post" action="/settings/apikey" style="display:inline">
  <input type="hidden" name="revoke" value="1">
  <button type="submit" style="background:#b00020">Revoke key</button>
</form>`)
	}
	PageFooter(w)
}
