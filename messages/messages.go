// Package messages handles fetching and sending messages.
package messages

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/flags"
	"angry-gopher/reactions"
	"angry-gopher/respond"
)

var DB *sql.DB

// RenderMarkdown is set by main to avoid a circular dependency
// with the markdown package.
var RenderMarkdown func(string) string

// HandleGetMessages handles GET /api/v1/messages.
func HandleGetMessages(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)

	anchor := r.URL.Query().Get("anchor")
	numBeforeStr := r.URL.Query().Get("num_before")
	numBefore, _ := strconv.Atoi(numBeforeStr)
	if numBefore <= 0 {
		numBefore = 100
	}

	// Only return messages from channels the user can see:
	// public channels OR channels the user is subscribed to.
	accessFilter := `m.channel_id IN (
		SELECT channel_id FROM channels WHERE invite_only = 0
		UNION
		SELECT channel_id FROM subscriptions WHERE user_id = ?
	)`

	var query string
	var args []interface{}

	if anchor == "newest" {
		query = `SELECT m.id, mc.html, m.sender_id, m.channel_id, m.timestamp,
		                t.topic_name, u.email, u.full_name
		         FROM messages m
		         JOIN message_content mc ON m.content_id = mc.content_id
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         WHERE ` + accessFilter + `
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{userID, numBefore}
	} else {
		anchorID, _ := strconv.Atoi(anchor)
		query = `SELECT m.id, mc.html, m.sender_id, m.channel_id, m.timestamp,
		                t.topic_name, u.email, u.full_name
		         FROM messages m
		         JOIN message_content mc ON m.content_id = mc.content_id
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         WHERE m.id < ? AND ` + accessFilter + `
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{anchorID, userID, numBefore}
	}

	dbRows, err := DB.Query(query, args...)
	if err != nil {
		respond.Error(w, "Failed to query messages")
		return
	}

	// Collect all rows first, then close, so the single DB connection
	// is free for subsequent queries (flags, reactions).
	type messageRow struct {
		id, senderID, channelID int
		timestamp               int64
		html, topicName         string
		email, fullName         string
	}
	var rows []messageRow
	for dbRows.Next() {
		var row messageRow
		dbRows.Scan(&row.id, &row.html, &row.senderID, &row.channelID,
			&row.timestamp, &row.topicName, &row.email, &row.fullName)
		rows = append(rows, row)
	}
	dbRows.Close()

	result := []map[string]interface{}{}
	for _, row := range rows {
		msgFlags := flags.GetMessageFlags(row.id, userID)
		result = append(result, map[string]interface{}{
			"id":                row.id,
			"content":           row.html,
			"sender_id":         row.senderID,
			"sender_email":      row.email,
			"sender_full_name":  row.fullName,
			"stream_id":         row.channelID,
			"subject":           row.topicName,
			"timestamp":         row.timestamp,
			"type":              "stream",
			"flags":             msgFlags,
			"reactions":         reactions.GetReactions(row.id),
			"display_recipient": fmt.Sprintf("channel_%d", row.channelID),
		})
	}

	// Reverse to ascending order (Zulip sends oldest first).
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}

	foundOldest := len(result) < numBefore

	respond.Success(w, map[string]interface{}{
		"messages":     result,
		"found_oldest": foundOldest,
	})
}

// SendMessage is the core logic for creating a message. It renders
// markdown, stores content, creates the topic if needed, and inserts
// the message. Returns the new message ID. Used by both the HTTP
// handler and the seed data.
//
// All DB operations run inside a single transaction so that
// concurrent calls don't interleave their queries. Without this,
// goroutine A could look up a topic, goroutine B could grab the
// connection and modify state, and then A would fail or see stale data.
func SendMessage(senderID, channelID int, topic, markdown string) (int64, error) {
	html := RenderMarkdown(markdown)

	tx, err := DB.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	// Find or create the topic.
	var topicID int64
	err = tx.QueryRow(
		`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
		channelID, topic,
	).Scan(&topicID)
	if err != nil {
		result, err := tx.Exec(
			`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
			channelID, topic,
		)
		if err != nil {
			return 0, err
		}
		topicID, _ = result.LastInsertId()
	}

	// Insert content (markdown + rendered HTML).
	contentResult, err := tx.Exec(
		`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
		markdown, html,
	)
	if err != nil {
		return 0, err
	}
	contentID, _ := contentResult.LastInsertId()

	// Insert the message.
	timestamp := time.Now().Unix()
	msgResult, err := tx.Exec(
		`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		contentID, senderID, channelID, topicID, timestamp,
	)
	if err != nil {
		return 0, err
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}

	return msgResult.LastInsertId()
}

// SendMessageHTML is like SendMessage but takes pre-rendered HTML
// instead of running the markdown renderer. Used by webhook
// integrations that produce their own HTML.
func SendMessageHTML(senderID, channelID int, topic, markdown, html string) (int64, error) {
	tx, err := DB.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var topicID int64
	err = tx.QueryRow(
		`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
		channelID, topic,
	).Scan(&topicID)
	if err != nil {
		result, err := tx.Exec(
			`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
			channelID, topic,
		)
		if err != nil {
			return 0, err
		}
		topicID, _ = result.LastInsertId()
	}

	contentResult, err := tx.Exec(
		`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
		markdown, html,
	)
	if err != nil {
		return 0, err
	}
	contentID, _ := contentResult.LastInsertId()

	timestamp := time.Now().Unix()
	msgResult, err := tx.Exec(
		`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		contentID, senderID, channelID, topicID, timestamp,
	)
	if err != nil {
		return 0, err
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}

	return msgResult.LastInsertId()
}

// MarkUnreadForSubscribers inserts unread rows for all users
// subscribed to the channel, except the sender.
func MarkUnreadForSubscribers(messageID int64, channelID, senderID int) {
	DB.Exec(`
		INSERT OR IGNORE INTO unreads (message_id, user_id)
		SELECT ?, s.user_id
		FROM subscriptions s
		WHERE s.channel_id = ? AND s.user_id != ?`,
		messageID, channelID, senderID)
}

// HandleSendMessage handles POST /api/v1/messages.
func HandleSendMessage(w http.ResponseWriter, r *http.Request) {
	channelID, _ := strconv.Atoi(r.FormValue("to"))
	topic := r.FormValue("topic")
	content := r.FormValue("content")
	localID := r.FormValue("local_id")

	if channelID == 0 || topic == "" || content == "" {
		respond.Error(w, "Missing required parameters: to, topic, content")
		return
	}

	senderID := auth.Authenticate(r)
	if senderID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	if !channels.CanAccess(senderID, channelID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	messageID, err := SendMessage(senderID, channelID, topic, content)
	if err != nil {
		respond.Error(w, "Failed to send message")
		return
	}

	MarkUnreadForSubscribers(messageID, channelID, senderID)

	html := RenderMarkdown(content)
	timestamp := time.Now().Unix()

	var email, fullName string
	DB.QueryRow(`SELECT email, full_name FROM users WHERE id = ?`, senderID).Scan(&email, &fullName)

	log.Printf("[api] New message %d in channel %d, topic %q", messageID, channelID, topic)

	event := map[string]interface{}{
		"type":  "message",
		"flags": []string{"read"},
		"message": map[string]interface{}{
			"id":                messageID,
			"content":           html,
			"sender_id":         senderID,
			"sender_email":      email,
			"sender_full_name":  fullName,
			"stream_id":         channelID,
			"subject":           topic,
			"timestamp":         timestamp,
			"type":              "stream",
			"flags":             []string{"read"},
			"reactions":         []interface{}{},
			"display_recipient": fmt.Sprintf("channel_%d", channelID),
		},
		"local_message_id": localID,
	}
	events.PushFiltered(event, func(uid int) bool {
		return channels.CanAccess(uid, channelID)
	})

	respond.Success(w, map[string]interface{}{"id": messageID})
}

// HandleEditMessage handles PATCH /api/v1/messages/{id}.
func HandleEditMessage(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	messageID := respond.PathSegmentInt(r.URL.Path, 4)
	if messageID == 0 {
		respond.Error(w, "Invalid message ID")
		return
	}

	if !channels.CanAccessMessage(userID, messageID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	content := r.FormValue("content")
	if content == "" {
		respond.Error(w, "Missing required parameter: content")
		return
	}

	html := RenderMarkdown(content)

	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "Failed to update message")
		return
	}
	defer tx.Rollback()

	_, err = tx.Exec(`
		UPDATE message_content SET markdown = ?, html = ?
		WHERE content_id = (SELECT content_id FROM messages WHERE id = ?)`,
		content, html, messageID,
	)
	if err != nil {
		respond.Error(w, "Failed to update message")
		return
	}

	var channelID int
	tx.QueryRow(`SELECT channel_id FROM messages WHERE id = ?`, messageID).Scan(&channelID)

	if err := tx.Commit(); err != nil {
		respond.Error(w, "Failed to update message")
		return
	}

	log.Printf("[api] Edited message %d", messageID)

	events.PushFiltered(map[string]interface{}{
		"type":             "update_message",
		"message_id":       messageID,
		"content":          content,
		"rendered_content": html,
	}, func(uid int) bool {
		return channels.CanAccess(uid, channelID)
	})

	respond.Success(w, nil)
}

// HandleGetSingleMessage handles GET /api/v1/messages/{id}.
func HandleGetSingleMessage(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	messageID := respond.PathSegmentInt(r.URL.Path, 4)
	if messageID == 0 {
		respond.Error(w, "Invalid message ID")
		return
	}

	if !channels.CanAccessMessage(userID, messageID) {
		respond.Error(w, "Not authorized for this channel")
		return
	}

	var senderID, channelID int
	var content, senderEmail, senderName, topicName string
	var timestamp int64
	err := DB.QueryRow(`
		SELECT m.sender_id, m.channel_id, mc.html, m.timestamp,
			u.email, u.full_name, t.topic_name
		FROM messages m
		JOIN message_content mc ON m.content_id = mc.content_id
		JOIN users u ON m.sender_id = u.id
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.id = ?`, messageID).Scan(
		&senderID, &channelID, &content, &timestamp,
		&senderEmail, &senderName, &topicName)
	if err != nil {
		respond.Error(w, "Message not found")
		return
	}

	respond.Success(w, map[string]interface{}{
		"message": map[string]interface{}{
			"id":               messageID,
			"content":          content,
			"sender_id":        senderID,
			"sender_email":     senderEmail,
			"sender_full_name": senderName,
			"stream_id":        channelID,
			"subject":          topicName,
			"timestamp":        timestamp,
			"type":             "stream",
		},
	})
}

// HandleDeleteMessage handles DELETE /api/v1/messages/{id}.
func HandleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	messageID := respond.PathSegmentInt(r.URL.Path, 4)
	if messageID == 0 {
		respond.Error(w, "Invalid message ID")
		return
	}

	// Only the sender can delete their own message.
	var senderID, channelID int
	err := DB.QueryRow(`SELECT sender_id, channel_id FROM messages WHERE id = ?`, messageID).Scan(&senderID, &channelID)
	if err != nil {
		respond.Error(w, "Message not found")
		return
	}
	if senderID != userID {
		respond.Error(w, "You can only delete your own messages")
		return
	}

	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "Failed to delete message")
		return
	}
	defer tx.Rollback()

	var contentID int
	tx.QueryRow(`SELECT content_id FROM messages WHERE id = ?`, messageID).Scan(&contentID)
	tx.Exec(`DELETE FROM reactions WHERE message_id = ?`, messageID)
	tx.Exec(`DELETE FROM unreads WHERE message_id = ?`, messageID)
	tx.Exec(`DELETE FROM starred_messages WHERE message_id = ?`, messageID)
	tx.Exec(`DELETE FROM messages WHERE id = ?`, messageID)
	tx.Exec(`DELETE FROM message_content WHERE content_id = ?`, contentID)

	if err := tx.Commit(); err != nil {
		respond.Error(w, "Failed to delete message")
		return
	}

	log.Printf("[api] Deleted message %d", messageID)

	events.PushFiltered(map[string]interface{}{
		"type":       "delete_message",
		"message_id": messageID,
	}, func(uid int) bool {
		return channels.CanAccess(uid, channelID)
	})

	respond.Success(w, nil)
}
