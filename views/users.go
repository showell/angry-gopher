package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
)

// HandleUsers serves /gopher/users.
//
//   GET:   list all users + edit-own-name form
//   POST:  update your own display name
func HandleUsers(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleUserUpdate(w, r, userID)
		return
	}

	idStr := r.URL.Query().Get("id")
	if idStr != "" {
		id, _ := strconv.Atoi(idStr)
		renderUserDetail(w, userID, id)
		return
	}

	renderUserList(w, userID)
}

func renderUserList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Users")

	var myName, myEmail string
	DB.QueryRow(`SELECT full_name, email FROM users WHERE id = ?`, userID).Scan(&myName, &myEmail)

	fmt.Fprintf(w, `<p>Logged in as <b>%s</b> (%s)</p>`,
		html.EscapeString(myName), html.EscapeString(myEmail))

	// Edit own name.
	fmt.Fprintf(w, `<h2>Update Your Name</h2>
<form method="POST" action="/gopher/users">
<input type="text" name="full_name" value="%s" style="width:300px;padding:4px" required>
<button type="submit">Save</button>
</form>`, html.EscapeString(myName))

	// All users list.
	fmt.Fprint(w, `<h2>All Users</h2>`)
	rows, err := DB.Query(`SELECT id, full_name, email, is_admin FROM users ORDER BY full_name`)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load users.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Name</th><th>Email</th><th>Role</th></tr></thead><tbody>`)
	for rows.Next() {
		var id, isAdmin int
		var name, email string
		rows.Scan(&id, &name, &email, &isAdmin)
		role := ""
		if isAdmin == 1 {
			role = "Admin"
		}
		style := ""
		if id == userID {
			style = ` style="background:#f0f0ff"`
		}
		fmt.Fprintf(w, `<tr%s><td>%s</td><td>%s</td><td>%s</td></tr>`,
			style, UserLink(id, name), html.EscapeString(email), role)
	}
	fmt.Fprint(w, `</tbody></table>`)

	PageFooter(w)
}

func renderUserDetail(w http.ResponseWriter, currentUserID, targetID int) {
	var name, email string
	var isAdmin int
	err := DB.QueryRow(`SELECT full_name, email, is_admin FROM users WHERE id = ?`, targetID).Scan(&name, &email, &isAdmin)
	if err != nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, name)

	fmt.Fprint(w, `<a class="back" href="/gopher/users">&larr; Back to users</a>`)

	role := "Member"
	if isAdmin == 1 {
		role = "Admin"
	}
	fmt.Fprintf(w, `<table>
<tr><td><b>Email</b></td><td>%s</td></tr>
<tr><td><b>Role</b></td><td>%s</td></tr>
</table>`, html.EscapeString(email), role)

	// Channels this user is subscribed to.
	rows, err := DB.Query(`
		SELECT c.channel_id, c.name FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id
		WHERE s.user_id = ?
		ORDER BY c.name`, targetID)
	if err == nil {
		defer rows.Close()
		fmt.Fprint(w, `<h2>Channels</h2><ul>`)
		for rows.Next() {
			var chID int
			var chName string
			rows.Scan(&chID, &chName)
			fmt.Fprintf(w, `<li>%s</li>`, ChannelLink(chID, chName))
		}
		fmt.Fprint(w, `</ul>`)
	}

	// Link to DM if not self.
	if targetID != currentUserID {
		fmt.Fprintf(w, `<p><a href="/gopher/dm?user_id=%d">Send a DM &rarr;</a></p>`, targetID)
	}

	PageFooter(w)
}

func handleUserUpdate(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	fullName := r.FormValue("full_name")
	if fullName == "" {
		http.Error(w, "Name cannot be empty", http.StatusBadRequest)
		return
	}
	DB.Exec(`UPDATE users SET full_name = ? WHERE id = ?`, fullName, userID)
	http.Redirect(w, r, "/gopher/users", http.StatusSeeOther)
}
