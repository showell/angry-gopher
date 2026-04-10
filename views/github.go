package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
)

// HandleGitHub serves /gopher/github.
//
//   GET:   list configured repos with webhook URLs
//   POST:  add or remove a repo
func HandleGitHub(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	// Admin-only.
	var isAdmin int
	DB.QueryRow(`SELECT is_admin FROM users WHERE id = ?`, userID).Scan(&isAdmin)
	if isAdmin != 1 {
		http.Error(w, "Admin access required", http.StatusForbidden)
		return
	}

	if r.Method == "POST" {
		handleGitHubPost(w, r, userID)
		return
	}

	renderGitHubIndex(w, userID)
}

func renderGitHubIndex(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "GitHub Integration")

	// Get admin's API key for webhook URLs.
	var apiKey string
	DB.QueryRow(`SELECT api_key FROM users WHERE id = ?`, userID).Scan(&apiKey)

	// List configured repos.
	rows, err := DB.Query(`
		SELECT gr.id, gr.owner, gr.name, gr.channel_id, c.name, gr.default_topic
		FROM github_repos gr
		JOIN channels c ON gr.channel_id = c.channel_id
		ORDER BY gr.owner, gr.name`)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load repos.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<h2>Configured Repos</h2>`)
	fmt.Fprint(w, `<table><thead><tr><th>Repo</th><th>Channel</th><th>Default Topic</th><th>Webhook URL</th><th></th></tr></thead><tbody>`)
	hasRepos := false
	for rows.Next() {
		hasRepos = true
		var id, channelID int
		var owner, name, channelName, defaultTopic string
		rows.Scan(&id, &owner, &name, &channelID, &channelName, &defaultTopic)
		webhookURL := fmt.Sprintf("/gopher/webhooks/github?repo_id=%d&api_key=%s", id, apiKey)
		topicDisplay := defaultTopic
		if topicDisplay == "" {
			topicDisplay = "(auto)"
		}
		fmt.Fprintf(w, `<tr>
<td><b>%s/%s</b></td>
<td>#%s</td>
<td>%s</td>
<td><input type="text" value="%s" readonly style="width:300px;font-size:12px;font-family:monospace;padding:2px"></td>
<td><form method="POST" style="margin:0"><input type="hidden" name="action" value="delete"><input type="hidden" name="id" value="%d"><button type="submit" style="background:#cc0000">Remove</button></form></td>
</tr>`,
			html.EscapeString(owner), html.EscapeString(name),
			html.EscapeString(channelName),
			html.EscapeString(topicDisplay),
			html.EscapeString(webhookURL),
			id)
	}
	fmt.Fprint(w, `</tbody></table>`)
	if !hasRepos {
		fmt.Fprint(w, `<p class="muted">No repos configured yet.</p>`)
	}

	// Add repo form.
	fmt.Fprint(w, `<h2>Add a Repo</h2>
<form method="POST" action="/gopher/github">
<input type="hidden" name="action" value="create">`)

	fmt.Fprint(w, `<label style="display:block;margin-bottom:4px;font-weight:bold">Owner</label>
<input type="text" name="owner" placeholder="e.g. showell" required style="width:200px;padding:4px;margin-bottom:8px"><br>`)

	fmt.Fprint(w, `<label style="display:block;margin-bottom:4px;font-weight:bold">Repo name</label>
<input type="text" name="name" placeholder="e.g. angry-gopher" required style="width:200px;padding:4px;margin-bottom:8px"><br>`)

	// Channel picker.
	fmt.Fprint(w, `<label style="display:block;margin-bottom:4px;font-weight:bold">Channel</label>
<select name="channel_id" style="margin-bottom:8px">`)
	chRows, _ := DB.Query(`SELECT channel_id, name FROM channels ORDER BY name`)
	if chRows != nil {
		defer chRows.Close()
		for chRows.Next() {
			var chID int
			var chName string
			chRows.Scan(&chID, &chName)
			fmt.Fprintf(w, `<option value="%d">#%s</option>`, chID, html.EscapeString(chName))
		}
	}
	fmt.Fprint(w, `</select><br>`)

	fmt.Fprint(w, `<label style="display:block;margin-bottom:4px;font-weight:bold">Default topic (optional)</label>
<input type="text" name="default_topic" placeholder="Leave blank for auto" style="width:200px;padding:4px;margin-bottom:8px"><br>`)

	fmt.Fprint(w, `<button type="submit">Add Repo</button></form>`)

	PageFooter(w)
}

func handleGitHubPost(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	action := r.FormValue("action")

	switch action {
	case "create":
		owner := r.FormValue("owner")
		name := r.FormValue("name")
		channelIDStr := r.FormValue("channel_id")
		channelID, _ := strconv.Atoi(channelIDStr)
		defaultTopic := r.FormValue("default_topic")

		if owner == "" || name == "" || channelID == 0 {
			http.Error(w, "Missing required fields", http.StatusBadRequest)
			return
		}

		DB.Exec(`INSERT OR REPLACE INTO github_repos (owner, name, channel_id, default_topic) VALUES (?, ?, ?, ?)`,
			owner, name, channelID, defaultTopic)

	case "delete":
		idStr := r.FormValue("id")
		id, _ := strconv.Atoi(idStr)
		DB.Exec(`DELETE FROM github_repos WHERE id = ?`, id)
	}

	http.Redirect(w, r, "/gopher/github", http.StatusSeeOther)
}
