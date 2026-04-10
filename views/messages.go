package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
	"time"
)

// HandleMessages serves /gopher/messages.
//
//   No params:               list channels
//   ?channel_id=N:           list topics in channel
//   ?channel_id=N&topic=T:   show messages + compose
//   POST:                    send a message
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
		renderMessages(w, userID, channelID, topic)
	}
}

func renderChannelList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Messages")

	rows, err := DB.Query(`
		SELECT c.channel_id, c.name,
			(SELECT COUNT(*) FROM messages m WHERE m.channel_id = c.channel_id) AS msg_count
		FROM channels c
		JOIN subscriptions s ON c.channel_id = s.channel_id AND s.user_id = ?
		ORDER BY c.name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load channels.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Channel</th><th>Messages</th></tr></thead><tbody>`)
	for rows.Next() {
		var id, count int
		var name string
		rows.Scan(&id, &name, &count)
		fmt.Fprintf(w, `<tr><td><a href="/gopher/messages?channel_id=%d">#%s</a></td><td>%d</td></tr>`,
			id, html.EscapeString(name), count)
	}
	fmt.Fprint(w, `</tbody></table>`)
	PageFooter(w)
}

func renderTopicList(w http.ResponseWriter, userID int, channelID int) {
	var channelName string
	DB.QueryRow(`SELECT name FROM channels WHERE channel_id = ?`, channelID).Scan(&channelName)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s — Topics", channelName))

	fmt.Fprint(w, `<a class="back" href="/gopher/messages">&larr; Back to channels</a>`)

	rows, err := DB.Query(`
		SELECT t.topic_name,
			(SELECT COUNT(*) FROM messages m WHERE m.topic_id = t.topic_id) AS msg_count
		FROM topics t
		WHERE t.channel_id = ?
		ORDER BY t.topic_name`, channelID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load topics.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	fmt.Fprint(w, `<table><thead><tr><th>Topic</th><th>Messages</th></tr></thead><tbody>`)
	for rows.Next() {
		var count int
		var topicName string
		rows.Scan(&topicName, &count)
		fmt.Fprintf(w, `<tr><td><a href="/gopher/messages?channel_id=%d&topic=%s">%s</a></td><td>%d</td></tr>`,
			channelID, html.EscapeString(topicName), html.EscapeString(topicName), count)
	}
	fmt.Fprint(w, `</tbody></table>`)
	PageFooter(w)
}

func renderMessages(w http.ResponseWriter, userID int, channelID int, topic string) {
	var channelName string
	DB.QueryRow(`SELECT name FROM channels WHERE channel_id = ?`, channelID).Scan(&channelName)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s > %s", channelName, topic))

	fmt.Fprintf(w, `<a class="back" href="/gopher/messages?channel_id=%d">&larr; Back to topics</a>`, channelID)

	rows, err := DB.Query(`
		SELECT m.id, u.full_name, mc.html, m.timestamp
		FROM messages m
		JOIN users u ON m.sender_id = u.id
		JOIN message_content mc ON m.content_id = mc.content_id
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = ? AND t.topic_name = ?
		ORDER BY m.id ASC`, channelID, topic)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load messages.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var msgID int
		var senderName, content string
		var timestamp int64
		rows.Scan(&msgID, &senderName, &content, &timestamp)
		t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
		fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`,
			html.EscapeString(senderName), html.EscapeString(t), content)
	}

	// Compose form.
	fmt.Fprintf(w, `
<form method="POST" action="/gopher/messages">
<input type="hidden" name="channel_id" value="%d">
<input type="hidden" name="topic" value="%s">
<textarea name="content" placeholder="Write a message..." required></textarea>
<button type="submit">Send</button>
</form>`, channelID, html.EscapeString(topic))

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

	htmlContent := RenderMarkdown(content)
	tx, _ := DB.Begin()
	defer tx.Rollback()

	var topicID int64
	err := tx.QueryRow(`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
		channelID, topic).Scan(&topicID)
	if err != nil {
		result, _ := tx.Exec(`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`, channelID, topic)
		topicID, _ = result.LastInsertId()
	}

	contentResult, _ := tx.Exec(`INSERT INTO message_content (markdown, html) VALUES (?, ?)`, content, htmlContent)
	contentID, _ := contentResult.LastInsertId()

	timestamp := time.Now().Unix()
	tx.Exec(`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		contentID, userID, channelID, topicID, timestamp)
	tx.Commit()

	http.Redirect(w, r, fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s", channelID, topic), http.StatusSeeOther)
}
