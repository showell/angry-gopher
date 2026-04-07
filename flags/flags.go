// Package flags handles message flag operations (read/unread, starred).
//
// Internally we use two concrete tables — unreads and starred_messages —
// rather than a generic flags table. The Zulip API speaks "read" and
// "starred"; we translate here.
package flags

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// HandleUpdateFlags handles POST /api/v1/messages/flags.
func HandleUpdateFlags(w http.ResponseWriter, r *http.Request) {
	op := r.FormValue("op")
	flag := r.FormValue("flag")
	messagesJSON := r.FormValue("messages")

	if op == "" || flag == "" || messagesJSON == "" {
		respond.Error(w, "Missing required parameters: op, flag, messages")
		return
	}

	var messageIDs []int
	if err := json.Unmarshal([]byte(messagesJSON), &messageIDs); err != nil {
		respond.Error(w, "Invalid messages parameter: "+err.Error())
		return
	}

	if op != "add" && op != "remove" {
		respond.Error(w, "Invalid op: "+op)
		return
	}

	switch flag {
	case "read":
		applyReadFlag(op, messageIDs)
	case "starred":
		applyStarredFlag(op, messageIDs)
	default:
		respond.Error(w, "Unknown flag: "+flag)
		return
	}

	log.Printf("[api] %s flag %q on %d messages", op, flag, len(messageIDs))

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
func applyReadFlag(op string, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			DB.Exec(`DELETE FROM unreads WHERE message_id = ?`, id)
		case "remove":
			DB.Exec(`INSERT OR IGNORE INTO unreads (message_id) VALUES (?)`, id)
		}
	}
}

func applyStarredFlag(op string, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			DB.Exec(`INSERT OR IGNORE INTO starred_messages (message_id) VALUES (?)`, id)
		case "remove":
			DB.Exec(`DELETE FROM starred_messages WHERE message_id = ?`, id)
		}
	}
}

// GetMessageFlags returns the Zulip-style flags list for a message.
// A message is "read" unless it has a row in unreads. Starred is
// present if the message has a row in starred_messages.
func GetMessageFlags(messageID int) []string {
	flags := []string{}

	var unreadExists int
	DB.QueryRow(`SELECT COUNT(*) FROM unreads WHERE message_id = ?`, messageID).Scan(&unreadExists)
	if unreadExists == 0 {
		flags = append(flags, "read")
	}

	var starredExists int
	DB.QueryRow(`SELECT COUNT(*) FROM starred_messages WHERE message_id = ?`, messageID).Scan(&starredExists)
	if starredExists > 0 {
		flags = append(flags, "starred")
	}

	return flags
}
