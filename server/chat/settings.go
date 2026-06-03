// User settings. The first setting is a bot API key, reached from the chat
// subsystem (see chatChromeTop). Self-service is safe because the endpoint
// acts on the SESSION identity — never a user id from the request — so a
// member can only manage their OWN key. The key acts as the member (read +
// write, like their password) but is admin-stripped, so it's a subset of
// the session's powers. More settings (display name, password, prefs) will
// slot in as sections here.
package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"fmt"
	"html"
	"net/http"
)

// HandleSettings serves the member settings page.
func HandleSettings(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/settings" {
		http.NotFound(w, r)
		return
	}
	renderSettings(w, r, users.CurrentUser(r))
}

// HandleSettingsAPIKey generates or revokes the CURRENT member's API key.
// It always acts on the session identity (never a request-supplied user
// id), so a member can only manage their own key.
func HandleSettingsAPIKey(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/settings", http.StatusSeeOther)
		return
	}
	if r.FormValue("revoke") == "1" {
		if err := users.ClearUserAPIKey(user.ID); err != nil {
			http.Error(w, "revoke: "+err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/settings?keyrevoked=1", http.StatusSeeOther)
		return
	}
	key, err := users.SetUserAPIKey(user.ID)
	if err != nil {
		http.Error(w, "generate: "+err.Error(), http.StatusInternalServerError)
		return
	}
	users.RenderAPIKeyShown(w, user.ID, key, "/settings", "Settings")
}

func renderSettings(w http.ResponseWriter, r *http.Request, user users.User) {
	chatPageHeader(w, "Settings", user, "settings")

	if r.URL.Query().Get("keyrevoked") == "1" {
		fmt.Fprint(w, `<p class="flash">Your API key was revoked.</p>`)
	}

	fmt.Fprint(w, `<h2>API key</h2>
<p class="muted">An API key lets a bot act as you through the chat API — read your
conversations <strong>and send on your behalf</strong>. It can't reach admin, but otherwise
treat it like your password. Hand it to the bot via the <code>GOPHER_API_KEY</code>
environment variable, not in a prompt; revoke it here anytime.</p>`)

	if !users.UserHasAPIKey(user.ID) {
		fmt.Fprint(w, `<p>You don't have an API key yet.</p>
<form method="post" action="/settings/apikey" style="display:inline"><button type="submit">Generate key</button></form>`)
		web.PageFooter(w)
		return
	}

	// Has a key. Reveal it when ?show=1; otherwise just offer the buttons.
	if r.URL.Query().Get("show") == "1" {
		if key, ok := users.GetUserAPIKey(user.ID); ok {
			fmt.Fprintf(w, `<p>Your API key (copy it somewhere safe):</p>
<code style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:15px;background:#f4f4ec;`+
				`border:1px solid #ccc;padding:8px 12px;border-radius:4px;display:inline-block;`+
				`user-select:all;word-break:break-all">%s</code>`, html.EscapeString(key))
		} else {
			fmt.Fprint(w, `<p class="muted">This key predates the show feature — regenerate it to see the value.</p>`)
		}
	} else {
		fmt.Fprint(w, `<p>You have an API key.</p>`)
	}
	fmt.Fprint(w, `<p>
<form method="get" action="/settings" style="display:inline"><input type="hidden" name="show" value="1"><button type="submit">Show key</button></form>
<form method="post" action="/settings/apikey" style="display:inline"><button type="submit">Regenerate key</button></form>
<form method="post" action="/settings/apikey" style="display:inline"><input type="hidden" name="revoke" value="1"><button type="submit" style="background:#b00020">Revoke key</button></form>
</p>`)
	web.PageFooter(w)
}
