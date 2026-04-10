package views

import (
	"fmt"
	"html"
	"net/http"
)

// HandleRecent serves /gopher/recent — recently active topics.
func HandleRecent(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Recent Conversations")
	PageSubtitle(w, "Topics with the most recent activity across all your channels.")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, t.topic_name, COUNT(m.id) AS msg_count,
			MAX(m.timestamp) AS last_ts
		FROM topics t
		JOIN channels c ON t.channel_id = c.channel_id
		JOIN subscriptions s ON s.channel_id = c.channel_id AND s.user_id = ?
		LEFT JOIN messages m ON m.topic_id = t.topic_id
		GROUP BY t.topic_id
		HAVING msg_count > 0
		ORDER BY last_ts DESC
		LIMIT 50`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load recent conversations.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Channel</th><th>Topic</th><th>Messages</th><th>Last Activity</th></tr></thead><tbody>`)
	for rows.Next() {
		var chID, msgCount int
		var chName, topicName string
		var lastTS int64
		rows.Scan(&chID, &chName, &topicName, &msgCount, &lastTS)
		ago := TimeAgo(lastTS)
		url := fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s", chID, topicName)
		fmt.Fprintf(w, `<tr><td>%s</td><td><a href="%s">%s</a></td><td>%d</td><td class="muted">%s</td></tr>`,
			ChannelLink(chID, chName), html.EscapeString(url), html.EscapeString(topicName), msgCount, ago)
	}
	fmt.Fprint(w, `</tbody></table>`)

	PageFooter(w)
}
