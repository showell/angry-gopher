// Package flags handles message flag operations (read/unread, starred).
//
// Internally we use two concrete tables — unreads and starred_messages —
// each keyed on (message_id, user_id), so flags are per-user.
package flags

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// HandleUpdateFlags handles POST /api/v1/messages/flags.
func HandleUpdateFlags(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	op := r.FormValue("op")
	flag := r.FormValue("flag")
	messagesJSON := r.FormValue("messages")

	if op == "" || flag == "" || messagesJSON == "" {
		respond.Error(w, "Missing required parameters: op, flag, messages")
		return
	}

	if op != "add" && op != "remove" {
		respond.Error(w, "Invalid op: "+op)
		return
	}

	var messageIDs []int
	if err := json.Unmarshal([]byte(messagesJSON), &messageIDs); err != nil {
		respond.Error(w, "Invalid messages parameter: "+err.Error())
		return
	}

	// Verify the user can access all referenced messages.
	for _, id := range messageIDs {
		if !channels.CanAccessMessage(userID, id) {
			respond.Error(w, "Not authorized for this channel")
			return
		}
	}

	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "Database error")
		return
	}
	defer tx.Rollback()

	switch flag {
	case "read":
		applyReadFlag(tx, op, userID, messageIDs)
	case "starred":
		applyStarredFlag(tx, op, userID, messageIDs)
	default:
		respond.Error(w, "Unknown flag: "+flag)
		return
	}

	if err := tx.Commit(); err != nil {
		respond.Error(w, "Database error")
		return
	}

	log.Printf("[api] %s flag %q on %d messages for user %d", op, flag, len(messageIDs), userID)

	events.PushToAll(map[string]interface{}{
		"type":     "update_message_flags",
		"op":       op,
		"flag":     flag,
		"messages": messageIDs,
		"all":      false,
	})

	respond.Success(w, map[string]interface{}{"messages": messageIDs})
}

// "add read" means the message is read, so remove from unreads.
// "remove read" means mark unread, so insert into unreads.
func applyReadFlag(tx *sql.Tx, op string, userID int, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			tx.Exec(`DELETE FROM unreads WHERE message_id = ? AND user_id = ?`, id, userID)
		case "remove":
			tx.Exec(`INSERT OR IGNORE INTO unreads (message_id, user_id) VALUES (?, ?)`, id, userID)
		}
	}
}

// StarMessage stars a message for a user. Used by both the HTTP
// handler and seed data.
func StarMessage(messageID, userID int) {
	DB.Exec(`INSERT OR IGNORE INTO starred_messages (message_id, user_id) VALUES (?, ?)`,
		messageID, userID)
}

func applyStarredFlag(tx *sql.Tx, op string, userID int, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			tx.Exec(`INSERT OR IGNORE INTO starred_messages (message_id, user_id) VALUES (?, ?)`, id, userID)
		case "remove":
			tx.Exec(`DELETE FROM starred_messages WHERE message_id = ? AND user_id = ?`, id, userID)
		}
	}
}

// HandleMarkAllRead handles POST /api/v1/mark_all_as_read.
func HandleMarkAllRead(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	DB.Exec(`DELETE FROM unreads WHERE user_id = ?`, userID)
	log.Printf("[api] Marked all messages as read for user %d", userID)
	respond.Success(w, nil)
}

// HandleMarkChannelRead handles POST /api/v1/mark_channel_as_read.
func HandleMarkChannelRead(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	r.ParseForm()
	channelIDStr := r.FormValue("channel_id")
	var channelID int
	if channelIDStr != "" {
		json.Unmarshal([]byte(channelIDStr), &channelID)
		if channelID == 0 {
			// Try plain int.
			DB.QueryRow("SELECT ?+0", channelIDStr).Scan(&channelID)
		}
	}
	if channelID == 0 {
		respond.Error(w, "Missing required param: channel_id")
		return
	}

	DB.Exec(`DELETE FROM unreads WHERE user_id = ? AND message_id IN (SELECT id FROM messages WHERE channel_id = ?)`,
		userID, channelID)
	log.Printf("[api] Marked channel %d as read for user %d", channelID, userID)
	respond.Success(w, nil)
}

// HandleMarkTopicRead handles POST /api/v1/mark_topic_as_read.
func HandleMarkTopicRead(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	r.ParseForm()
	channelIDStr := r.FormValue("channel_id")
	topicName := r.FormValue("topic")
	var channelID int
	if channelIDStr != "" {
		json.Unmarshal([]byte(channelIDStr), &channelID)
		if channelID == 0 {
			DB.QueryRow("SELECT ?+0", channelIDStr).Scan(&channelID)
		}
	}
	if channelID == 0 || topicName == "" {
		respond.Error(w, "Missing required params: channel_id, topic")
		return
	}

	DB.Exec(`DELETE FROM unreads WHERE user_id = ? AND message_id IN (
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = ? AND t.topic_name = ?)`,
		userID, channelID, topicName)
	log.Printf("[api] Marked topic %q in channel %d as read for user %d", topicName, channelID, userID)
	respond.Success(w, nil)
}

// GetMessageFlags returns the Zulip-style flags list for a message
// as seen by the given user.
func GetMessageFlags(messageID, userID int) []string {
	flags := []string{}

	var unreadExists int
	DB.QueryRow(`SELECT COUNT(*) FROM unreads WHERE message_id = ? AND user_id = ?`, messageID, userID).Scan(&unreadExists)
	if unreadExists == 0 {
		flags = append(flags, "read")
	}

	var starredExists int
	DB.QueryRow(`SELECT COUNT(*) FROM starred_messages WHERE message_id = ? AND user_id = ?`, messageID, userID).Scan(&starredExists)
	if starredExists > 0 {
		flags = append(flags, "starred")
	}

	return flags
}
