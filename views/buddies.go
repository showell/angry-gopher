package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
)

// HandleBuddies serves /gopher/buddies.
//
//   GET:   show buddy list with toggle checkboxes
//   POST:  toggle a buddy
func HandleBuddies(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleBuddyToggle(w, r, userID)
		return
	}

	renderBuddyList(w, userID)
}

func renderBuddyList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Buddies")
	PageSubtitle(w, "Your curated list of people you care about. Buddy lists are private and persist across sessions.")

	// Get current buddy IDs.
	buddyIDs := map[int]bool{}
	rows, err := DB.Query(`SELECT buddy_id FROM buddies WHERE user_id = ?`, userID)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var id int
			rows.Scan(&id)
			buddyIDs[id] = true
		}
	}

	fmt.Fprintf(w, `<p>You have <b>%d</b> buddies selected.</p>`, len(buddyIDs))

	// All users.
	urows, err := DB.Query(`SELECT id, full_name FROM users WHERE id != ? ORDER BY full_name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load users.</p>`)
		PageFooter(w)
		return
	}
	defer urows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Buddy</th><th>User</th></tr></thead><tbody>`)
	for urows.Next() {
		var id int
		var name string
		urows.Scan(&id, &name)
		checked := ""
		if buddyIDs[id] {
			checked = " checked"
		}
		fmt.Fprintf(w, `<tr><td>
<form method="POST" action="/gopher/buddies" style="margin:0">
<input type="hidden" name="buddy_id" value="%d">
<input type="checkbox" onchange="this.form.submit()"%s>
</form></td><td>%s</td></tr>`,
			id, checked, html.EscapeString(name))
	}
	fmt.Fprint(w, `</tbody></table>`)

	PageFooter(w)
}

func handleBuddyToggle(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	buddyIDStr := r.FormValue("buddy_id")
	buddyID, _ := strconv.Atoi(buddyIDStr)
	if buddyID == 0 {
		http.Error(w, "Missing buddy_id", http.StatusBadRequest)
		return
	}

	// Check if currently a buddy.
	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM buddies WHERE user_id = ? AND buddy_id = ?`, userID, buddyID).Scan(&count)

	if count > 0 {
		DB.Exec(`DELETE FROM buddies WHERE user_id = ? AND buddy_id = ?`, userID, buddyID)
	} else {
		DB.Exec(`INSERT OR IGNORE INTO buddies (user_id, buddy_id) VALUES (?, ?)`, userID, buddyID)
	}

	http.Redirect(w, r, "/gopher/buddies", http.StatusSeeOther)
}
