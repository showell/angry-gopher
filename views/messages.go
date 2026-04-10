package views

import (
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"

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

const hydrateLimit = 1000

func renderMessages(w http.ResponseWriter, userID int, channelID int, topic string) {
	var channelName string
	DB.QueryRow(`SELECT name FROM channels WHERE channel_id = ?`, channelID).Scan(&channelName)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%s > %s", channelName, topic))

	fmt.Fprintf(w, `<a class="back" href="/gopher/messages?channel_id=%d">&larr; Back to topics</a>`, channelID)

	// Step 1: get ALL message IDs (fast, index-only).
	idRows, err := DB.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = ? AND t.topic_name = ?
		ORDER BY m.id DESC`, channelID, topic)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load messages.</p>`)
		PageFooter(w)
		return
	}

	var allIDs []int
	for idRows.Next() {
		var id int
		idRows.Scan(&id)
		allIDs = append(allIDs, id)
	}
	idRows.Close()

	totalCount := len(allIDs)
	fmt.Fprintf(w, `<p class="muted">%d messages total`, totalCount)

	// Step 2: hydrate the first 1000.
	showIDs := allIDs
	if len(showIDs) > hydrateLimit {
		showIDs = showIDs[:hydrateLimit]
		fmt.Fprintf(w, `, showing newest %d`, hydrateLimit)
	}
	fmt.Fprint(w, `</p>`)

	if len(showIDs) == 0 {
		fmt.Fprint(w, `<p class="muted">No messages yet.</p>`)
	} else {
		placeholders := make([]string, len(showIDs))
		args := make([]interface{}, len(showIDs))
		for i, id := range showIDs {
			placeholders[i] = "?"
			args[i] = id
		}

		query := fmt.Sprintf(`
			SELECT m.id, m.sender_id, u.full_name, mc.html, m.timestamp
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ","))

		rows, err := DB.Query(query, args...)
		if err != nil {
			fmt.Fprint(w, `<p>Failed to hydrate messages.</p>`)
			PageFooter(w)
			return
		}
		defer rows.Close()

		for rows.Next() {
			var msgID, senderID int
			var senderName, content string
			var timestamp int64
			rows.Scan(&msgID, &senderID, &senderName, &content, &timestamp)
			t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
			fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`,
				UserLink(senderID, senderName), html.EscapeString(t), content)
		}
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

	_, err := messages.SendMessage(userID, channelID, topic, content)
	if err != nil {
		http.Error(w, "Failed to send message", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, fmt.Sprintf("/gopher/messages?channel_id=%d&topic=%s", channelID, topic), http.StatusSeeOther)
}
