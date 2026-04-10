package views

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"

	"angry-gopher/messages"
)

// HandleMessages serves /gopher/messages.
func HandleMessages(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleMessageSend(w, r, userID)
		return
	}

	channelIDStr := r.URL.Query().Get("channel_id")
	topic := r.URL.Query().Get("topic")

	if channelIDStr == "" {
		renderChannelList(w, userID)
	} else if topic == "" {
		channelID, _ := strconv.Atoi(channelIDStr)
		renderTopicList(w, userID, channelID)
	} else {
		channelID, _ := strconv.Atoi(channelIDStr)
		renderMessages(w, r, userID, channelID, topic)
	}
}

func renderChannelList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Messages")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name
		FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id AND s.user_id = ?
		ORDER BY c.name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load channels.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Channel</th></tr></thead><tbody>`)
	for rows.Next() {
		var id int
		var name string
		rows.Scan(&id, &name)
		fmt.Fprintf(w, `<tr><td><a href="/gopher/messages?channel_id=%d">#%s</a></td></tr>`,
			id, html.EscapeString(name))
	}
	fmt.Fprint(w, `</tbody></table>`)
	PageFooter(w)
}

func renderTopicList(w http.ResponseWriter, userID int, channelID int) {
	var channelName string
	DB.QueryRow(`SELECT name FROM channels WHERE channel_id = ?`, channelID).Scan(&channelName)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s — Topics", channelName))

	Breadcrumb(w, "Messages", "/gopher/messages", "#"+channelName)

	// Single query: topic name, message count, unread count, most recent timestamp.
	rows, err := DB.Query(`
		SELECT t.topic_name,
			COUNT(m.id) AS msg_count,
			SUM(CASE WHEN u.message_id IS NOT NULL THEN 1 ELSE 0 END) AS unread_count,
			MAX(m.timestamp) AS last_ts
		FROM topics t
		LEFT JOIN messages m ON m.topic_id = t.topic_id
		LEFT JOIN unreads u ON u.message_id = m.id AND u.user_id = ?
		WHERE t.channel_id = ?
		GROUP BY t.topic_id
		ORDER BY last_ts DESC NULLS LAST`, userID, channelID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load topics.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Topic</th><th>Messages</th><th>Unread</th><th>Last Activity</th></tr></thead><tbody>`)
	for rows.Next() {
		var topicName string
		var msgCount, unreadCount int
		var lastTS sql.NullInt64
		rows.Scan(&topicName, &msgCount, &unreadCount, &lastTS)

		ago := "—"
		if lastTS.Valid {
			ago = TimeAgo(lastTS.Int64)
		}

		unreadBadge := ""
		if unreadCount > 0 {
			unreadBadge = fmt.Sprintf(`<span style="background:lavender;padding:2px 6px;border-radius:4px;font-weight:bold">%d</span>`, unreadCount)
		}

		fmt.Fprintf(w, `<tr><td><a href="/gopher/messages?channel_id=%d&topic=%s">%s</a></td><td>%d</td><td>%s</td><td class="muted">%s</td></tr>`,
			channelID, html.EscapeString(topicName), html.EscapeString(topicName),
			msgCount, unreadBadge, ago)
	}
	fmt.Fprint(w, `</tbody></table>`)
	PageFooter(w)
}

func renderMessages(w http.ResponseWriter, r *http.Request, userID int, channelID int, topic string) {
	var channelName string
	DB.QueryRow(`SELECT name FROM channels WHERE channel_id = ?`, channelID).Scan(&channelName)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s > %s", channelName, topic))

	Breadcrumb(w,
		"Messages", "/gopher/messages",
		"#"+channelName, fmt.Sprintf("/gopher/messages?channel_id=%d", channelID),
		topic)
	FlashFromRequest(w, r)

	const renderLimit = 25000

	// Get IDs with LIMIT.
	idRows, err := DB.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = ? AND t.topic_name = ?
		ORDER BY m.id DESC LIMIT ?`, channelID, topic, renderLimit)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load messages.</p>`)
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

	fmt.Fprintf(w, `<p class="muted">%d messages</p>`, len(ids))

	flusher, canFlush := w.(http.Flusher)
	if canFlush {
		flusher.Flush()
	}

	// Hydrate and flush in chunks.
	const chunkSize = 500
	for i := 0; i < len(ids); i += chunkSize {
		end := i + chunkSize
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[i:end]

		placeholders := make([]string, len(chunk))
		args := make([]interface{}, len(chunk))
		for j, id := range chunk {
			placeholders[j] = "?"
			args[j] = id
		}

		rows, err := DB.Query(fmt.Sprintf(`
			SELECT m.id, m.sender_id, u.full_name, mc.html, m.timestamp
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ",")), args...)
		if err != nil {
			continue
		}

		for rows.Next() {
			var msgID, senderID int
			var senderName, content string
			var timestamp int64
			rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp)
			ago := TimeAgo(timestamp)
			fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`, html.EscapeString(senderName), html.EscapeString(ago), content)
		}
		rows.Close()

		if canFlush {
			flusher.Flush()
		}
	}

	fmt.Fprintf(w, `
<div class="compose-sticky">
<form method="POST" action="/gopher/messages">
<input type="hidden" name="channel_id" value="%d">
<input type="hidden" name="topic" value="%s">
<textarea name="content" placeholder="Write a message..." required></textarea>
<button type="submit">Send</button>
</form>
</div>`, channelID, html.EscapeString(topic))

	PageFooter(w)
}

func handleMessageSend(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	channelIDStr := r.FormValue("channel_id")
	topic := r.FormValue("topic")
	content := r.FormValue("content")
	channelID, _ := strconv.Atoi(channelIDStr)

	if channelID == 0 || topic == "" || content == "" {
		http.Error(w, "Missing fields", http.StatusBadRequest)
		return
	}

	_, err := messages.SendMessage(userID, channelID, topic, content)
	if err != nil {
		http.Error(w, "Failed to send message", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s&flash=Message+sent!", channelID, topic), http.StatusSeeOther)
}
