// Package reactions handles adding and removing emoji reactions on messages.
package reactions

import (
	"database/sql"
	"log"
	"net/http"
	"strconv"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// HandleReaction handles POST and DELETE on /api/v1/messages/{id}/reactions.
func HandleReaction(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	// Extract message ID from URL: /api/v1/messages/{id}/reactions
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 6 {
		respond.Error(w, "Invalid URL")
		return
	}
	messageID, _ := strconv.Atoi(parts[4])
	if messageID == 0 {
		respond.Error(w, "Invalid message ID")
		return
	}

	// Go only auto-parses the request body for POST/PUT/PATCH.
	// For DELETE with a form body, we override the method temporarily
	// so ParseForm reads the body.
	origMethod := r.Method
	r.Method = "POST"
	r.ParseForm()
	r.Method = origMethod

	emojiName := r.FormValue("emoji_name")
	emojiCode := r.FormValue("emoji_code")
	if emojiName == "" || emojiCode == "" {
		respond.Error(w, "Missing required parameters: emoji_name, emoji_code")
		return
	}

	var op string
	switch r.Method {
	case "POST":
		op = "add"
		_, err := DB.Exec(
			`INSERT OR IGNORE INTO reactions (message_id, user_id, emoji_name, emoji_code) VALUES (?, ?, ?, ?)`,
			messageID, userID, emojiName, emojiCode,
		)
		if err != nil {
			respond.Error(w, "Failed to add reaction")
			return
		}
	case "DELETE":
		op = "remove"
		_, err := DB.Exec(
			`DELETE FROM reactions WHERE message_id = ? AND user_id = ? AND emoji_code = ?`,
			messageID, userID, emojiCode,
		)
		if err != nil {
			respond.Error(w, "Failed to remove reaction")
			return
		}
	default:
		respond.Error(w, "Method not allowed")
		return
	}

	log.Printf("[api] %s reaction %s on message %d by user %d", op, emojiName, messageID, userID)

	events.PushToAll(map[string]interface{}{
		"type":          "reaction",
		"op":            op,
		"message_id":    messageID,
		"user_id":       userID,
		"emoji_code":    emojiCode,
		"emoji_name":    emojiName,
		"reaction_type": "unicode_emoji",
	})

	respond.Success(w, nil)
}

// GetReactions returns the reactions for a message as a slice of maps,
// matching the Zulip API format that Angry Cat expects.
func GetReactions(messageID int) []map[string]interface{} {
	rows, err := DB.Query(
		`SELECT user_id, emoji_name, emoji_code FROM reactions WHERE message_id = ?`,
		messageID,
	)
	if err != nil {
		return []map[string]interface{}{}
	}
	defer rows.Close()

	result := []map[string]interface{}{}
	for rows.Next() {
		var userID int
		var emojiName, emojiCode string
		rows.Scan(&userID, &emojiName, &emojiCode)
		result = append(result, map[string]interface{}{
			"user_id":       userID,
			"emoji_name":    emojiName,
			"emoji_code":    emojiCode,
			"reaction_type": "unicode_emoji",
		})
	}
	return result
}
