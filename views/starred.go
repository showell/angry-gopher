package views

import (
	"fmt"
	"html"
	"net/http"
	"strings"
)

// HandleStarred serves /gopher/starred — your starred messages.
func HandleStarred(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Starred Messages")
	PageSubtitle(w, "Messages you've starred for quick reference. Stars persist across sessions.")

	// Get starred message IDs.
	idRows, err := DB.Query(`
		SELECT m.id FROM starred_messages sm
		JOIN messages m ON sm.message_id = m.id
		WHERE sm.user_id = ?
		ORDER BY m.id DESC`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load starred messages.</p>`)
		PageFooter(w)
		return
	}
	var ids []int
	for idRows.Next() {
		var id int
		idRows.Scan(&id)
		ids = append(ids, id)
	}
	idRows.Close()

	fmt.Fprintf(w, `<p class="muted">%d starred messages</p>`, len(ids))

	if len(ids) > 0 {
		limit := len(ids)
		if limit > 200 {
			limit = 200
		}
		showIDs := ids[:limit]

		placeholders := make([]string, len(showIDs))
		args := make([]interface{}, len(showIDs))
		for i, id := range showIDs {
			placeholders[i] = "?"
			args[i] = id
		}

		rows, err := DB.Query(fmt.Sprintf(`
			SELECT m.id, m.sender_id, u.full_name, mc.html, m.timestamp, c.name, t.topic_name, m.channel_id
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			JOIN channels c ON m.channel_id = c.channel_id
			JOIN topics t ON m.topic_id = t.topic_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ",")), args...)
		if err == nil {
			defer rows.Close()
			for rows.Next() {
				var msgID, senderID, chID int
				var senderName, content, chName, topicName string
				var timestamp int64
				rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp, &chName, &topicName, &chID)
				ago := TimeAgo(timestamp)
				fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> in %s > %s <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`, UserLink(senderID, senderName), ChannelLink(chID, chName),
					html.EscapeString(topicName), html.EscapeString(ago), content)
			}
		}
	}

	PageFooter(w)
}
