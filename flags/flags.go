// Package flags handles message flag operations (read/unread, starred).
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
		respond.Error(w, "Invalid op: "+op)
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

// GetMessageFlags returns the flags for a given message, translating
// the internal "unread" storage back to the Zulip "read" convention.
func GetMessageFlags(messageID int) []string {
	rows, err := DB.Query(`SELECT flag_name FROM message_flags WHERE message_id = ?`, messageID)
	if err != nil {
		return []string{"read"}
	}
	defer rows.Close()

	result := []string{}
	hasUnread := false
	for rows.Next() {
		var flag string
		rows.Scan(&flag)
		if flag == "unread" {
			hasUnread = true
		} else {
			result = append(result, flag)
		}
	}

	if !hasUnread {
		result = append(result, "read")
	}
	return result
}
