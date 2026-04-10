package views

import (
	"fmt"
	"html"
	"net/http"
	"time"
)

// HandleInvites serves /gopher/invites-view.
//
//   GET:   list active invitations
//   POST:  revoke an invitation
func HandleInvites(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	var isAdmin int
	DB.QueryRow(`SELECT is_admin FROM users WHERE id = ?`, userID).Scan(&isAdmin)
	if isAdmin != 1 {
		http.Error(w, "Admin access required", http.StatusForbidden)
		return
	}

	if r.Method == "POST" {
		r.ParseForm()
		action := r.FormValue("action")

		if action == "create" {
			fullName := r.FormValue("full_name")
			email := r.FormValue("email")
			if fullName != "" && email != "" {
				token := fmt.Sprintf("%d-%s", time.Now().UnixNano(), email)
				expiresAt := time.Now().Add(7 * 24 * time.Hour).Unix()
				DB.Exec(`INSERT INTO invites (token, email, full_name, expires_at) VALUES (?, ?, ?, ?)`,
					token, email, fullName, expiresAt)
				http.Redirect(w, r, "/gopher/invites-view?flash=Invite+created!", http.StatusSeeOther)
				return
			}
		} else {
			token := r.FormValue("token")
			if token != "" {
				DB.Exec(`DELETE FROM invites WHERE token = ?`, token)
			}
		}
		http.Redirect(w, r, "/gopher/invites-view", http.StatusSeeOther)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Invitations")
	FlashFromRequest(w, r)

	now := time.Now().Unix()

	rows, err := DB.Query(`SELECT token, email, full_name, expires_at FROM invites ORDER BY expires_at DESC`)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load invites.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Name</th><th>Email</th><th>Status</th><th>Expires</th><th></th></tr></thead><tbody>`)
	count := 0
	for rows.Next() {
		var token, email, fullName string
		var expiresAt int64
		rows.Scan(&token, &email, &fullName, &expiresAt)

		status := `<span style="color:green">Active</span>`
		if expiresAt < now {
			status = `<span class="muted">Expired</span>`
		}

		t := time.Unix(expiresAt, 0).Format("Jan 2 15:04")
		fmt.Fprintf(w, `<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td>
<td><form method="POST" style="margin:0"><input type="hidden" name="token" value="%s">
<button type="submit" style="background:#cc0000">Revoke</button></form></td></tr>`,
			html.EscapeString(fullName), html.EscapeString(email), status, t, html.EscapeString(token))
		count++
	}
	fmt.Fprint(w, `</tbody></table>`)
	if count == 0 {
		fmt.Fprint(w, `<p class="muted">No invitations.</p>`)
	}

	// Create invite form.
	fmt.Fprint(w, `<h2>Create Invitation</h2>
<form method="POST" action="/gopher/invites-view">
<input type="hidden" name="action" value="create">
<label style="display:block;margin-bottom:4px;font-weight:bold">Full name</label>
<input type="text" name="full_name" required style="width:300px;padding:4px;margin-bottom:8px"><br>
<label style="display:block;margin-bottom:4px;font-weight:bold">Email</label>
<input type="email" name="email" required style="width:300px;padding:4px;margin-bottom:8px"><br>
<button type="submit">Create Invite</button>
</form>`)

	PageFooter(w)
}
