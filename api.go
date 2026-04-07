// API handlers for the Zulip-compatible endpoints, backed by SQLite.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// --- Event queue system ---
//
// Each registered client gets a queue. When something changes (new
// message, flag update, etc.), we push events to all queues. The
// /events endpoint long-polls until events are available or timeout.

type eventQueue struct {
	id         string
	events     []map[string]interface{}
	lastID     int
	mu         sync.Mutex
	notify     chan struct{}
}

var (
	queues   = map[string]*eventQueue{}
	queuesMu sync.Mutex
	nextQueueID int
)

func newEventQueue() *eventQueue {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	nextQueueID++
	q := &eventQueue{
		id:     fmt.Sprintf("gopher-%d", nextQueueID),
		lastID: -1,
		notify: make(chan struct{}, 1),
	}
	queues[q.id] = q
	return q
}

func pushEventToAll(event map[string]interface{}) {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	for _, q := range queues {
		q.mu.Lock()
		q.lastID++
		// Copy the event so each queue gets its own event ID.
		copy := make(map[string]interface{})
		for k, v := range event {
			copy[k] = v
		}
		copy["id"] = q.lastID
		q.events = append(q.events, copy)
		q.mu.Unlock()
		// Wake up any long-polling goroutine.
		select {
		case q.notify <- struct{}{}:
		default:
		}
	}
}

// --- POST /api/v1/register ---

func handleRegister(w http.ResponseWriter, r *http.Request) {
	q := newEventQueue()
	log.Printf("[api] Registered event queue: %s", q.id)
	writeJSON(w, map[string]interface{}{
		"result":        "success",
		"msg":           "",
		"queue_id":      q.id,
		"last_event_id": -1,
	})
}

// --- GET /api/v1/events ---

func handleEvents(w http.ResponseWriter, r *http.Request) {
	queueID := r.URL.Query().Get("queue_id")
	lastEventIDStr := r.URL.Query().Get("last_event_id")
	lastEventID, _ := strconv.Atoi(lastEventIDStr)

	queuesMu.Lock()
	q, ok := queues[queueID]
	queuesMu.Unlock()

	if !ok {
		writeJSON(w, map[string]interface{}{
			"result": "error",
			"msg":    "Bad event queue id: " + queueID,
			"code":   "BAD_EVENT_QUEUE_ID",
		})
		return
	}

	// Check for pending events.
	q.mu.Lock()
	var pending []map[string]interface{}
	for _, ev := range q.events {
		if ev["id"].(int) > lastEventID {
			pending = append(pending, ev)
		}
	}
	q.mu.Unlock()

	if len(pending) > 0 {
		writeJSON(w, map[string]interface{}{
			"result": "success",
			"msg":    "",
			"events": pending,
		})
		return
	}

	// Long-poll: wait up to 50 seconds for new events.
	select {
	case <-q.notify:
	case <-time.After(50 * time.Second):
	}

	// Collect any events that arrived.
	q.mu.Lock()
	for _, ev := range q.events {
		if ev["id"].(int) > lastEventID {
			pending = append(pending, ev)
		}
	}
	q.mu.Unlock()

	if len(pending) == 0 {
		// Send a heartbeat so the client knows we're alive.
		pending = []map[string]interface{}{
			{"type": "heartbeat", "id": lastEventID + 1},
		}
	}

	writeJSON(w, map[string]interface{}{
		"result": "success",
		"msg":    "",
		"events": pending,
	})
}

// --- GET /api/v1/users ---

func handleUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := DB.Query(`SELECT id, email, full_name, is_admin FROM users`)
	if err != nil {
		writeJSON(w, errorResponse("Failed to query users"))
		return
	}
	defer rows.Close()

	var members []map[string]interface{}
	for rows.Next() {
		var id int
		var email, fullName string
		var isAdmin int
		rows.Scan(&id, &email, &fullName, &isAdmin)
		members = append(members, map[string]interface{}{
			"user_id":   id,
			"email":     email,
			"full_name": fullName,
			"is_admin":  isAdmin == 1,
			"is_bot":    false,
		})
	}

	writeJSON(w, map[string]interface{}{
		"result":  "success",
		"msg":     "",
		"members": members,
	})
}

// --- GET /api/v1/users/me/subscriptions ---

func handleSubscriptions(w http.ResponseWriter, r *http.Request) {
	// Return channels the current user is subscribed to.
	// For now, we hardcode user 1 (Steve).
	userID := 1

	rows, err := DB.Query(`
		SELECT c.stream_id, c.name, c.description, c.rendered_description,
		       c.stream_weekly_traffic, c.invite_only
		FROM channels c
		JOIN subscriptions s ON c.stream_id = s.stream_id
		WHERE s.user_id = ?`, userID)
	if err != nil {
		writeJSON(w, errorResponse("Failed to query subscriptions"))
		return
	}
	defer rows.Close()

	var subs []map[string]interface{}
	for rows.Next() {
		var streamID, traffic, inviteOnly int
		var name, desc, renderedDesc string
		rows.Scan(&streamID, &name, &desc, &renderedDesc, &traffic, &inviteOnly)
		subs = append(subs, map[string]interface{}{
			"stream_id":              streamID,
			"name":                   name,
			"description":            desc,
			"rendered_description":   renderedDesc,
			"stream_weekly_traffic":  traffic,
			"invite_only":            inviteOnly == 1,
		})
	}

	writeJSON(w, map[string]interface{}{
		"result":        "success",
		"msg":           "",
		"subscriptions": subs,
	})
}

// --- GET /api/v1/messages ---

func handleMessages(w http.ResponseWriter, r *http.Request) {
	anchor := r.URL.Query().Get("anchor")
	numBeforeStr := r.URL.Query().Get("num_before")
	numBefore, _ := strconv.Atoi(numBeforeStr)
	if numBefore <= 0 {
		numBefore = 100
	}

	// Query messages based on anchor.
	var query string
	var args []interface{}

	if anchor == "newest" {
		query = `SELECT m.id, m.content, m.sender_id, m.stream_id, m.timestamp,
		                t.topic_name,
		                u.email, u.full_name
		         FROM messages m
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{numBefore}
	} else {
		anchorID, _ := strconv.Atoi(anchor)
		query = `SELECT m.id, m.content, m.sender_id, m.stream_id, m.timestamp,
		                t.topic_name,
		                u.email, u.full_name
		         FROM messages m
		         JOIN topics t ON m.topic_id = t.topic_id
		         JOIN users u ON m.sender_id = u.id
		         WHERE m.id < ?
		         ORDER BY m.id DESC LIMIT ?`
		args = []interface{}{anchorID, numBefore}
	}

	dbRows, err := DB.Query(query, args...)
	if err != nil {
		writeJSON(w, errorResponse("Failed to query messages"))
		return
	}

	// Collect all rows first, then close, so the connection is free
	// for subsequent queries (flags).
	type messageRow struct {
		id, senderID, streamID int
		timestamp              int64
		content, topicName     string
		email, fullName        string
	}
	var rows []messageRow
	for dbRows.Next() {
		var row messageRow
		dbRows.Scan(&row.id, &row.content, &row.senderID, &row.streamID,
			&row.timestamp, &row.topicName, &row.email, &row.fullName)
		rows = append(rows, row)
	}
	dbRows.Close()

	messages := []map[string]interface{}{}
	for _, row := range rows {
		flags := getMessageFlags(row.id)
		messages = append(messages, map[string]interface{}{
			"id":                row.id,
			"content":           row.content,
			"sender_id":         row.senderID,
			"sender_email":      row.email,
			"sender_full_name":  row.fullName,
			"stream_id":         row.streamID,
			"subject":           row.topicName,
			"timestamp":         row.timestamp,
			"type":              "stream",
			"flags":             flags,
			"reactions":         []interface{}{},
			"display_recipient": fmt.Sprintf("channel_%d", row.streamID),
		})
	}

	// Reverse to ascending order (Zulip sends oldest first).
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}

	// Determine if we've found the oldest message.
	foundOldest := len(messages) < numBefore

	writeJSON(w, map[string]interface{}{
		"result":       "success",
		"msg":          "",
		"messages":     messages,
		"found_oldest": foundOldest,
	})
}

// --- POST /api/v1/messages ---

func handleSendMessage(w http.ResponseWriter, r *http.Request) {
	streamID, _ := strconv.Atoi(r.FormValue("to"))
	topic := r.FormValue("topic")
	content := r.FormValue("content")
	localID := r.FormValue("local_id")

	if streamID == 0 || topic == "" || content == "" {
		writeJSON(w, errorResponse("Missing required parameters: to, topic, content"))
		return
	}

	// Find or create the topic.
	var topicID int64
	err := DB.QueryRow(
		`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
		streamID, topic,
	).Scan(&topicID)
	if err != nil {
		result, err := DB.Exec(
			`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
			streamID, topic,
		)
		if err != nil {
			writeJSON(w, errorResponse("Failed to create topic"))
			return
		}
		topicID, _ = result.LastInsertId()
	}

	// Convert markdown to HTML.
	html := renderMarkdown(content)

	// For now, all messages are sent as user 1.
	senderID := 1
	timestamp := time.Now().Unix()

	result, err := DB.Exec(
		`INSERT INTO messages (content, sender_id, stream_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		html, senderID, streamID, topicID, timestamp,
	)
	if err != nil {
		writeJSON(w, errorResponse("Failed to insert message"))
		return
	}

	messageID, _ := result.LastInsertId()

	// Look up sender info for the event.
	var email, fullName string
	DB.QueryRow(`SELECT email, full_name FROM users WHERE id = ?`, senderID).Scan(&email, &fullName)

	log.Printf("[api] New message %d in channel %d, topic %q", messageID, streamID, topic)

	pushEventToAll(map[string]interface{}{
		"type":  "message",
		"flags": []string{"read"},
		"message": map[string]interface{}{
			"id":                messageID,
			"content":           html,
			"sender_id":         senderID,
			"sender_email":      email,
			"sender_full_name":  fullName,
			"stream_id":         streamID,
			"subject":           topic,
			"timestamp":         timestamp,
			"type":              "stream",
			"flags":             []string{"read"},
			"reactions":         []interface{}{},
			"display_recipient": fmt.Sprintf("channel_%d", streamID),
		},
		"local_message_id": localID,
	})

	writeJSON(w, map[string]interface{}{
		"result": "success",
		"msg":    "",
		"id":     messageID,
	})
}

// --- POST /api/v1/messages/flags ---

func handleUpdateFlags(w http.ResponseWriter, r *http.Request) {
	op := r.FormValue("op")
	flag := r.FormValue("flag")
	messagesJSON := r.FormValue("messages")

	if op == "" || flag == "" || messagesJSON == "" {
		writeJSON(w, errorResponse("Missing required parameters: op, flag, messages"))
		return
	}

	var messageIDs []int
	if err := json.Unmarshal([]byte(messagesJSON), &messageIDs); err != nil {
		writeJSON(w, errorResponse("Invalid messages parameter: "+err.Error()))
		return
	}

	// The "read" flag is stored inverted: we keep "unread" rows so
	// the common case (read) requires no row at all. Translate the
	// client's "read" add/remove into our internal "unread" remove/add.
	dbFlag := flag
	dbOp := op
	if flag == "read" {
		dbFlag = "unread"
		if op == "add" {
			dbOp = "remove"
		} else if op == "remove" {
			dbOp = "add"
		}
	}

	switch dbOp {
	case "add":
		for _, id := range messageIDs {
			DB.Exec(`INSERT OR IGNORE INTO message_flags (message_id, flag_name) VALUES (?, ?)`, id, dbFlag)
		}
	case "remove":
		for _, id := range messageIDs {
			DB.Exec(`DELETE FROM message_flags WHERE message_id = ? AND flag_name = ?`, id, dbFlag)
		}
	default:
		writeJSON(w, errorResponse("Invalid op: "+op))
		return
	}

	log.Printf("[api] %s flag %q on %d messages", op, flag, len(messageIDs))

	pushEventToAll(map[string]interface{}{
		"type":     "update_message_flags",
		"op":       op,
		"flag":     flag,
		"messages": messageIDs,
		"all":      false,
	})

	writeJSON(w, map[string]interface{}{
		"result":   "success",
		"msg":      "",
		"messages": messageIDs,
	})
}

// --- Helpers ---

func getMessageFlags(messageID int) []string {
	rows, err := DB.Query(`SELECT flag_name FROM message_flags WHERE message_id = ?`, messageID)
	if err != nil {
		return []string{"read"}
	}
	defer rows.Close()

	flags := []string{}
	hasUnread := false
	for rows.Next() {
		var flag string
		rows.Scan(&flag)
		if flag == "unread" {
			hasUnread = true
		} else {
			flags = append(flags, flag)
		}
	}

	// No "unread" row means the message is read.
	if !hasUnread {
		flags = append(flags, "read")
	}
	return flags
}

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func errorResponse(msg string) map[string]interface{} {
	return map[string]interface{}{
		"result": "error",
		"msg":    msg,
	}
}
