package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
)

// HandleChannels serves /gopher/channels.
//
//   No params:        list subscribed channels
//   ?id=N:            channel detail + edit form
//   POST:             create channel or update description
func HandleChannels(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleChannelPost(w, r, userID)
		return
	}

	idStr := r.URL.Query().Get("id")
	if idStr != "" {
		id, _ := strconv.Atoi(idStr)
		renderChannelDetail(w, userID, id)
	} else {
		renderChannelIndex(w, userID)
	}
}

func renderChannelIndex(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Channels")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, c.invite_only,
			(SELECT COUNT(*) FROM subscriptions s WHERE s.channel_id = c.channel_id) AS sub_count
		FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id AND s.user_id = ?
		ORDER BY c.name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load channels.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Channel</th><th>Type</th><th>Subscribers</th></tr></thead><tbody>`)
	for rows.Next() {
		var id, inviteOnly, subCount int
		var name string
		rows.Scan(&id, &name, &inviteOnly, &subCount)
		visibility := "Public"
		if inviteOnly == 1 {
			visibility = "Private"
		}
		fmt.Fprintf(w, `<tr><td>%s</td><td>%s</td><td>%d</td></tr>`,
			ChannelLink(id, name), visibility, subCount)
	}
	fmt.Fprint(w, `</tbody></table>`)

	// Create channel form.
	fmt.Fprint(w, `<h2>Create Channel</h2>
<form method="POST" action="/gopher/channels">
<input type="hidden" name="action" value="create">
<label style="display:block;margin-bottom:4px;font-weight:bold">Name</label>
<input type="text" name="name" required style="width:300px;padding:4px;margin-bottom:8px"><br>
<label style="display:block;margin-bottom:4px;font-weight:bold">Description</label>
<textarea name="description" style="width:300px;height:40px;padding:4px;margin-bottom:8px"></textarea><br>
<label><input type="checkbox" name="invite_only" value="1"> Private</label><br><br>
<button type="submit">Create</button>
</form>`)

	PageFooter(w)
}

func renderChannelDetail(w http.ResponseWriter, userID int, channelID int) {
	var name, description string
	var inviteOnly int
	err := DB.QueryRow(`SELECT name, invite_only FROM channels WHERE channel_id = ?`, channelID).Scan(&name, &inviteOnly)
	if err != nil {
		http.Error(w, "Channel not found", http.StatusNotFound)
		return
	}
	DB.QueryRow(`SELECT markdown FROM channel_descriptions WHERE channel_id = ?`, channelID).Scan(&description)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s", name))

	Breadcrumb(w, "Channels", "/gopher/channels", "#"+name)
	fmt.Fprintf(w, `<p><a href="/gopher/messages?channel_id=%d">Browse topics &rarr;</a></p>`, channelID)

	visibility := "Public"
	if inviteOnly == 1 {
		visibility = "Private"
	}
	fmt.Fprintf(w, `<p><b>Visibility:</b> %s</p>`, visibility)

	// Subscribers.
	rows, err := DB.Query(`
		SELECT u.id, u.full_name FROM users u
		JOIN subscriptions s ON u.id = s.user_id
		WHERE s.channel_id = ?
		ORDER BY u.full_name`, channelID)
	if err == nil {
		defer rows.Close()
		fmt.Fprint(w, `<h2>Subscribers</h2><ul>`)
		for rows.Next() {
			var uid int
			var fullName string
			rows.Scan(&uid, &fullName)
			fmt.Fprintf(w, `<li>%s</li>`, UserLink(uid, fullName))
		}
		fmt.Fprint(w, `</ul>`)
	}

	// Edit description.
	fmt.Fprintf(w, `<h2>Edit Description</h2>
<form method="POST" action="/gopher/channels">
<input type="hidden" name="action" value="update">
<input type="hidden" name="channel_id" value="%d">
<textarea name="description" style="width:100%%;height:80px;padding:4px">%s</textarea><br><br>
<button type="submit">Update Description</button>
</form>`, channelID, html.EscapeString(description))

	// Link to messages.
	fmt.Fprintf(w, `<p><a href="/gopher/messages?channel_id=%d">Browse messages &rarr;</a></p>`, channelID)

	PageFooter(w)
}

func handleChannelPost(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	action := r.FormValue("action")

	switch action {
	case "create":
		name := r.FormValue("name")
		description := r.FormValue("description")
		inviteOnly := r.FormValue("invite_only") == "1"
		inviteOnlyInt := 0
		if inviteOnly {
			inviteOnlyInt = 1
		}

		result, err := DB.Exec(`INSERT INTO channels (name, invite_only) VALUES (?, ?)`, name, inviteOnlyInt)
		if err != nil {
			http.Error(w, "Failed to create channel", http.StatusInternalServerError)
			return
		}
		channelID, _ := result.LastInsertId()

		// Subscribe the creator.
		DB.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, userID, channelID)

		if description != "" {
			htmlDesc := RenderMarkdown(description)
			DB.Exec(`INSERT INTO channel_descriptions (channel_id, markdown, html) VALUES (?, ?, ?)`,
				channelID, description, htmlDesc)
		}

		http.Redirect(w, r, fmt.Sprintf("/gopher/channels?id=%d", channelID), http.StatusSeeOther)

	case "update":
		channelIDStr := r.FormValue("channel_id")
		channelID, _ := strconv.Atoi(channelIDStr)
		description := r.FormValue("description")
		htmlDesc := RenderMarkdown(description)

		DB.Exec(`INSERT OR REPLACE INTO channel_descriptions (channel_id, markdown, html) VALUES (?, ?, ?)`,
			channelID, description, htmlDesc)

		http.Redirect(w, r, fmt.Sprintf("/gopher/channels?id=%d", channelID), http.StatusSeeOther)
	}
}
