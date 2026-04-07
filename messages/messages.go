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
	anchor := r.URL.Query().Get("anchor")
	numBeforeStr := r.URL.Query().Get("num_before")
	numBefore, _ := strconv.Atoi(numBeforeStr)
	if numBefore <= 0 {
		numBefore = 100
	}

	var query string
	var args []interface{}

	if anchor == "newest" {
		query = `SELECT m.id, mc.html, m.sender_id, m.channel_id, m.timestamp,
		                t.topic_name, u.email, u.full_name
		         FROM messages m
		         JOIN message_content mc ON m.content_id = mc.content_id
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{numBefore}
	} else {
		anchorID, _ := strconv.Atoi(anchor)
		query = `SELECT m.id, mc.html, m.sender_id, m.channel_id, m.timestamp,
		                t.topic_name, u.email, u.full_name
		         FROM messages m
		         JOIN message_content mc ON m.content_id = mc.content_id
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         WHERE m.id < ?
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{anchorID, numBefore}
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
		msgFlags := flags.GetMessageFlags(row.id)
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

// insertContent stores markdown and rendered HTML in message_content
// and returns the new content_id.
func insertContent(markdown, html string) (int64, error) {
	result, err := DB.Exec(
		`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
		markdown, html,
	)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
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

	// Find or create the topic.
	var topicID int64
	err := DB.QueryRow(
		`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
		channelID, topic,
	).Scan(&topicID)
	if err != nil {
		result, err := DB.Exec(
			`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
			channelID, topic,
		)
		if err != nil {
			respond.Error(w, "Failed to create topic")
			return
		}
		topicID, _ = result.LastInsertId()
	}

	senderID := auth.Authenticate(r)
	if senderID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	html := RenderMarkdown(content)

	contentID, err := insertContent(content, html)
	if err != nil {
		respond.Error(w, "Failed to store content")
		return
	}

	timestamp := time.Now().Unix()

	result, err := DB.Exec(
		`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		contentID, senderID, channelID, topicID, timestamp,
	)
	if err != nil {
		respond.Error(w, "Failed to insert message")
		return
	}

	messageID, _ := result.LastInsertId()

	var email, fullName string
	DB.QueryRow(`SELECT email, full_name FROM users WHERE id = ?`, senderID).Scan(&email, &fullName)

	log.Printf("[api] New message %d in channel %d, topic %q", messageID, channelID, topic)

	events.PushToAll(map[string]interface{}{
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
	})

	respond.Success(w, map[string]interface{}{"id": messageID})
}

// HandleEditMessage handles PATCH /api/v1/messages/{id}.
func HandleEditMessage(w http.ResponseWriter, r *http.Request) {
	messageID := respond.PathSegmentInt(r.URL.Path, 4)
	if messageID == 0 {
		respond.Error(w, "Invalid message ID")
		return
	}

	content := r.FormValue("content")
	if content == "" {
		respond.Error(w, "Missing required parameter: content")
		return
	}

	html := RenderMarkdown(content)

	// Update the message_content row linked to this message.
	_, err := DB.Exec(`
		UPDATE message_content SET markdown = ?, html = ?
		WHERE content_id = (SELECT content_id FROM messages WHERE id = ?)`,
		content, html, messageID,
	)
	if err != nil {
		respond.Error(w, "Failed to update message")
		return
	}

	log.Printf("[api] Edited message %d", messageID)

	events.PushToAll(map[string]interface{}{
		"type":              "update_message",
		"message_id":        messageID,
		"content":           content,
		"rendered_content":  html,
	})

	respond.Success(w, nil)
}
