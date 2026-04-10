// Package dm handles 1:1 direct messages.
//
//   GET  /api/v1/dm/conversations       — list conversations for the current user
//   GET  /api/v1/dm/messages?user_id=N  — get messages with a specific user
//   POST /api/v1/dm/messages            — send a DM
package dm

import (
	"database/sql"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB
var RenderMarkdown func(string) string

// getOrCreateConversation finds or creates a dm_conversations row
// for the two users. Always stores the smaller ID first.
func getOrCreateConversation(userA, userB int) (int64, error) {
	lo, hi := userA, userB
	if lo > hi {
		lo, hi = hi, lo
	}

	var id int64
	err := DB.QueryRow(
		`SELECT id FROM dm_conversations WHERE user_id_1 = ? AND user_id_2 = ?`,
		lo, hi,
	).Scan(&id)
	if err == nil {
		return id, nil
	}

	result, err := DB.Exec(
		`INSERT INTO dm_conversations (user_id_1, user_id_2) VALUES (?, ?)`,
		lo, hi,
	)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

// HandleConversations handles GET /api/v1/dm/conversations.
func HandleConversations(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	rows, err := DB.Query(`
		SELECT dc.id,
			CASE WHEN dc.user_id_1 = ? THEN dc.user_id_2 ELSE dc.user_id_1 END AS other_user_id,
			u.full_name,
			(SELECT COUNT(*) FROM dm_messages WHERE conversation_id = dc.id) AS message_count
		FROM dm_conversations dc
		JOIN users u ON u.id = CASE WHEN dc.user_id_1 = ? THEN dc.user_id_2 ELSE dc.user_id_1 END
		WHERE dc.user_id_1 = ? OR dc.user_id_2 = ?
		ORDER BY dc.id DESC`,
		userID, userID, userID, userID,
	)
	if err != nil {
		respond.Error(w, "Failed to query conversations")
		return
	}
	defer rows.Close()

	var convos []map[string]interface{}
	for rows.Next() {
		var id, otherUserID, messageCount int
		var fullName string
		rows.Scan(&id, &otherUserID, &fullName, &messageCount)
		convos = append(convos, map[string]interface{}{
			"id":            id,
			"other_user_id": otherUserID,
			"full_name":     fullName,
			"message_count": messageCount,
		})
	}

	respond.Success(w, map[string]interface{}{"conversations": convos})
}

// HandleMessages routes GET and POST for /api/v1/dm/messages.
func HandleMessages(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	switch r.Method {
	case "GET":
		handleGetMessages(w, r, userID)
	case "POST":
		handleSendMessage(w, r, userID)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func handleGetMessages(w http.ResponseWriter, r *http.Request, userID int) {
	otherIDStr := r.URL.Query().Get("user_id")
	otherID, _ := strconv.Atoi(otherIDStr)
	if otherID == 0 {
		respond.Error(w, "Missing required param: user_id")
		return
	}

	lo, hi := userID, otherID
	if lo > hi {
		lo, hi = hi, lo
	}

	rows, err := DB.Query(`
		SELECT dm.id, dm.sender_id, mc.html, dm.timestamp
		FROM dm_messages dm
		JOIN dm_conversations dc ON dm.conversation_id = dc.id
		JOIN message_content mc ON dm.content_id = mc.content_id
		WHERE dc.user_id_1 = ? AND dc.user_id_2 = ?
		ORDER BY dm.id ASC`,
		lo, hi,
	)
	if err != nil {
		respond.Error(w, "Failed to query messages")
		return
	}
	defer rows.Close()

	var msgs []map[string]interface{}
	for rows.Next() {
		var id, senderID int
		var content string
		var timestamp int64
		rows.Scan(&id, &senderID, &content, &timestamp)
		msgs = append(msgs, map[string]interface{}{
			"id":        id,
			"sender_id": senderID,
			"content":   content,
			"timestamp": timestamp,
		})
	}

	respond.Success(w, map[string]interface{}{"messages": msgs})
}

func handleSendMessage(w http.ResponseWriter, r *http.Request, userID int) {
	r.ParseForm()
	recipientIDStr := r.FormValue("to")
	content := strings.TrimSpace(r.FormValue("content"))
	recipientID, _ := strconv.Atoi(recipientIDStr)

	if recipientID == 0 || content == "" {
		respond.Error(w, "Missing required params: to, content")
		return
	}

	if recipientID == userID {
		respond.Error(w, "Cannot send a DM to yourself")
		return
	}

	// Verify recipient exists.
	var exists int
	DB.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, recipientID).Scan(&exists)
	if exists == 0 {
		respond.Error(w, "Unknown recipient")
		return
	}

	conversationID, err := getOrCreateConversation(userID, recipientID)
	if err != nil {
		respond.Error(w, "Failed to create conversation")
		return
	}

	html := RenderMarkdown(content)

	contentResult, err := DB.Exec(
		`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
		content, html,
	)
	if err != nil {
		respond.Error(w, "Failed to save message")
		return
	}
	contentID, _ := contentResult.LastInsertId()

	timestamp := time.Now().Unix()
	msgResult, err := DB.Exec(
		`INSERT INTO dm_messages (conversation_id, sender_id, content_id, timestamp) VALUES (?, ?, ?, ?)`,
		conversationID, userID, contentID, timestamp,
	)
	if err != nil {
		respond.Error(w, "Failed to save message")
		return
	}
	msgID, _ := msgResult.LastInsertId()

	// Mark unread for the recipient.
	DB.Exec(`INSERT OR IGNORE INTO unreads (message_id, user_id) VALUES (?, ?)`,
		msgID, recipientID)

	// Look up sender info for the event.
	var senderEmail, senderName string
	DB.QueryRow(`SELECT email, full_name FROM users WHERE id = ?`, userID).Scan(&senderEmail, &senderName)

	// Push event to both participants.
	event := map[string]interface{}{
		"type": "message",
		"message": map[string]interface{}{
			"id":                msgID,
			"content":           html,
			"sender_id":         userID,
			"sender_email":      senderEmail,
			"sender_full_name":  senderName,
			"timestamp":         timestamp,
			"type":              "private",
			"flags":             []string{},
			"reactions":         []interface{}{},
			"display_recipient": []map[string]interface{}{
				{"id": userID},
				{"id": recipientID},
			},
		},
	}

	events.PushFiltered(event, func(uid int) bool {
		return uid == userID || uid == recipientID
	})

	log.Printf("[api] DM %d → user %d from user %d", msgID, recipientID, userID)
	respond.Success(w, map[string]interface{}{"id": msgID})
}
