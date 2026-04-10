package views

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var DB *sql.DB
var RenderMarkdown func(string) string

// HandleDM serves GET /gopher/dm (conversation list or message view)
// and POST /gopher/dm (send a message).
func HandleDM(w http.ResponseWriter, r *http.Request) {
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	if r.Method == "POST" {
		handleDMSend(w, r, userID)
		return
	}

	userIDParam := r.URL.Query().Get("user_id")
	if userIDParam != "" {
		otherID, _ := strconv.Atoi(userIDParam)
		if otherID != 0 {
			renderDMConversation(w, userID, otherID)
			return
		}
	}

	renderDMList(w, userID)
}

func renderDMList(w http.ResponseWriter, userID int) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Direct Messages")

	// All users (for "New conversation" links).
	rows, err := DB.Query(`SELECT id, full_name FROM users WHERE id != ? ORDER BY full_name`, userID)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load users.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	type userInfo struct {
		id       int
		name     string
		hasDMs   bool
		msgCount int
	}
	var users []userInfo
	for rows.Next() {
		var u userInfo
		rows.Scan(&u.id, &u.name)
		users = append(users, u)
	}

	// Check which users have existing conversations.
	for i := range users {
		lo, hi := userID, users[i].id
		if lo > hi {
			lo, hi = hi, lo
		}
		DB.QueryRow(`
			SELECT COUNT(*) FROM dm_messages dm
			JOIN dm_conversations dc ON dm.conversation_id = dc.id
			WHERE dc.user_id_1 = ? AND dc.user_id_2 = ?`,
			lo, hi).Scan(&users[i].msgCount)
		users[i].hasDMs = users[i].msgCount > 0
	}

	// Active conversations first.
	fmt.Fprint(w, `<h2>Conversations</h2>`)
	hasConvos := false
	fmt.Fprint(w, `<table><thead><tr><th>User</th><th>Messages</th></tr></thead><tbody>`)
	for _, u := range users {
		if !u.hasDMs {
			continue
		}
		hasConvos = true
		fmt.Fprintf(w, `<tr><td><a href="/gopher/dm?user_id=%d">%s</a> (%s)</td><td>%d</td></tr>`,
			u.id, html.EscapeString(u.name), UserLink(u.id, "profile"), u.msgCount)
	}
	fmt.Fprint(w, `</tbody></table>`)
	if !hasConvos {
		fmt.Fprint(w, `<p class="muted">No conversations yet.</p>`)
	}

	// All users for starting new conversations.
	fmt.Fprint(w, `<h2>Start a conversation</h2>`)
	fmt.Fprint(w, `<table><thead><tr><th>User</th></tr></thead><tbody>`)
	for _, u := range users {
		if u.hasDMs {
			continue
		}
		fmt.Fprintf(w, `<tr><td><a href="/gopher/dm?user_id=%d">%s</a></td></tr>`,
			u.id, html.EscapeString(u.name))
	}
	fmt.Fprint(w, `</tbody></table>`)

	PageFooter(w)
}

func renderDMConversation(w http.ResponseWriter, userID, otherID int) {
	var otherName string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, otherID).Scan(&otherName)
	if otherName == "" {
		http.Error(w, "Unknown user", http.StatusNotFound)
		return
	}

	lo, hi := userID, otherID
	if lo > hi {
		lo, hi = hi, lo
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("DM with %s", otherName))

	fmt.Fprint(w, `<a class="back" href="/gopher/dm">&larr; Back to conversations</a>`)

	// Messages.
	rows, err := DB.Query(`
		SELECT dm.sender_id, u.full_name, mc.html, dm.timestamp
		FROM dm_messages dm
		JOIN dm_conversations dc ON dm.conversation_id = dc.id
		JOIN message_content mc ON dm.content_id = mc.content_id
		JOIN users u ON dm.sender_id = u.id
		WHERE dc.user_id_1 = ? AND dc.user_id_2 = ?
		ORDER BY dm.id ASC`,
		lo, hi)
	if err != nil {
		fmt.Fprint(w, `<p>Failed to load messages.</p>`)
		PageFooter(w)
		return
	}
	defer rows.Close()

	msgCount := 0
	for rows.Next() {
		var senderID int
		var senderName, content string
		var timestamp int64
		rows.Scan(&senderID, &senderName, &content, &timestamp)

		t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
		fmt.Fprintf(w, `<div style="margin-bottom:8px;padding-bottom:8px;border-bottom:1px solid #ccc">
<b>%s</b> <span class="muted">%s</span>
<div class="msg-content">%s</div>
</div>`,
			UserLink(senderID, senderName), html.EscapeString(t), content)
		msgCount++
	}

	if msgCount == 0 {
		fmt.Fprint(w, `<p class="muted">No messages yet. Send the first one!</p>`)
	}

	// Compose form.
	fmt.Fprintf(w, `
<form method="POST" action="/gopher/dm">
<input type="hidden" name="to" value="%d">
<textarea name="content" placeholder="Message %s..." required></textarea>
<button type="submit">Send</button>
</form>`, otherID, html.EscapeString(otherName))

	PageFooter(w)
}

func handleDMSend(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	recipientIDStr := r.FormValue("to")
	content := strings.TrimSpace(r.FormValue("content"))
	recipientID, _ := strconv.Atoi(recipientIDStr)

	if recipientID == 0 || content == "" {
		http.Error(w, "Missing to or content", http.StatusBadRequest)
		return
	}

	// Use the DM API logic by importing the dm package would create
	// a circular dependency, so we duplicate the core insert here.
	lo, hi := userID, recipientID
	if lo > hi {
		lo, hi = hi, lo
	}

	// Get or create conversation.
	var convID int64
	err := DB.QueryRow(
		`SELECT id FROM dm_conversations WHERE user_id_1 = ? AND user_id_2 = ?`,
		lo, hi).Scan(&convID)
	if err != nil {
		result, err := DB.Exec(
			`INSERT INTO dm_conversations (user_id_1, user_id_2) VALUES (?, ?)`,
			lo, hi)
		if err != nil {
			http.Error(w, "Failed to create conversation", http.StatusInternalServerError)
			return
		}
		convID, _ = result.LastInsertId()
	}

	htmlContent := RenderMarkdown(content)
	contentResult, err := DB.Exec(
		`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
		content, htmlContent)
	if err != nil {
		http.Error(w, "Failed to save message", http.StatusInternalServerError)
		return
	}
	contentID, _ := contentResult.LastInsertId()

	timestamp := time.Now().Unix()
	DB.Exec(
		`INSERT INTO dm_messages (conversation_id, sender_id, content_id, timestamp) VALUES (?, ?, ?, ?)`,
		convID, userID, contentID, timestamp)

	// Redirect back to the conversation.
	http.Redirect(w, r, fmt.Sprintf("/gopher/dm?user_id=%d", recipientID), http.StatusSeeOther)
}
