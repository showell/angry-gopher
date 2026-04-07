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

	switch flag {
	case "read":
		applyReadFlag(op, userID, messageIDs)
	case "starred":
		applyStarredFlag(op, userID, messageIDs)
	default:
		respond.Error(w, "Unknown flag: "+flag)
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
func applyReadFlag(op string, userID int, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			DB.Exec(`DELETE FROM unreads WHERE message_id = ? AND user_id = ?`, id, userID)
		case "remove":
			DB.Exec(`INSERT OR IGNORE INTO unreads (message_id, user_id) VALUES (?, ?)`, id, userID)
		}
	}
}

func applyStarredFlag(op string, userID int, messageIDs []int) {
	for _, id := range messageIDs {
		switch op {
		case "add":
			DB.Exec(`INSERT OR IGNORE INTO starred_messages (message_id, user_id) VALUES (?, ?)`, id, userID)
		case "remove":
			DB.Exec(`DELETE FROM starred_messages WHERE message_id = ? AND user_id = ?`, id, userID)
		}
	}
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
