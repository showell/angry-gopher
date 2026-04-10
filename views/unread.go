package views

import (
	"fmt"
	"html"
	"net/http"
)

// HandleUnread serves /gopher/unread — topics with unread messages.
func HandleUnread(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Unread Messages")
	PageSubtitle(w, "Topics where you have unread messages. Click to catch up.")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name, t.topic_name, COUNT(u.message_id) AS unread_count
		FROM unreads u
		JOIN messages m ON u.message_id = m.id
		JOIN channels c ON m.channel_id = c.channel_id
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE u.user_id = ?
		GROUP BY t.topic_id
		ORDER BY MAX(m.timestamp) DESC`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load unreads.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	totalUnread := 0
	fmt.Fprint(w, `<table><thead><tr><th>Channel</th><th>Topic</th><th>Unread</th></tr></thead><tbody>`)
	for rows.Next() {
		var chID, unreadCount int
		var chName, topicName string
		rows.Scan(&chID, &chName, &topicName, &unreadCount)
		totalUnread += unreadCount
		url := fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s", chID, topicName)
		fmt.Fprintf(w, `<tr><td>%s</td><td><a href="%s">%s</a></td><td><span style="background:lavender;padding:2px 6px;border-radius:4px;font-weight:bold">%d</span></td></tr>`,
			ChannelLink(chID, chName), html.EscapeString(url), html.EscapeString(topicName), unreadCount)
	}
	fmt.Fprint(w, `</tbody></table>`)

	if totalUnread == 0 {
		fmt.Fprint(w, `<p class="muted">All caught up!</p>`)
	}

	PageFooter(w)
}
