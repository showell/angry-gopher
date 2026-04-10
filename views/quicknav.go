package views

import (
	"fmt"
	"html"
	"net/http"
)

// HandleQuickNav serves /gopher/quicknav — direct links to message pages.
func HandleQuickNav(w http.ResponseWriter, r *http.Request) {
	RequireAuth(w, r)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Quick Nav")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, t.topic_name
		FROM topics t
		JOIN channels c ON t.channel_id = c.channel_id
		ORDER BY c.name, t.topic_name
		LIMIT 200`)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	currentChannel := ""
	for rows.Next() {
		var chID int
		var chName, topicName string
		rows.Scan(&chID, &chName, &topicName)

		if chName != currentChannel {
			if currentChannel != "" {
				fmt.Fprint(w, `</ul>`)
			}
			fmt.Fprintf(w, `<h2 style="margin-top:16px">#%s</h2><ul>`, html.EscapeString(chName))
			currentChannel = chName
		}

		url := fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s", chID, topicName)
		fmt.Fprintf(w, `<li><a href="%s">%s</a></li>`,
			html.EscapeString(url), html.EscapeString(topicName))
	}
	if currentChannel != "" {
		fmt.Fprint(w, `</ul>`)
	}

	PageFooter(w)
}
