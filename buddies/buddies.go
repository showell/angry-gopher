// Package buddies handles the buddy list — a Gopher-specific feature
// that lets each user store which other users they want to see in
// their sidebar. Unlike Zulip-compatible endpoints that use PATCH
// for partial updates, this uses PUT to replace the entire list
// (matching how the client treats it as a single blob).
//
//   GET /api/v1/buddies  — returns the authenticated user's buddy list
//   PUT /api/v1/buddies  — replaces the entire buddy list
package buddies

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

var DB *sql.DB

// HandleBuddies routes GET and PUT for /api/v1/buddies.
func HandleBuddies(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	switch r.Method {
	case "GET":
		handleGet(w, userID)
	case "PUT":
		handlePut(w, r, userID)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func handleGet(w http.ResponseWriter, userID int) {
	rows, err := DB.Query(`SELECT buddy_id FROM buddies WHERE user_id = ?`, userID)
	if err != nil {
		respond.Error(w, "Failed to query buddies")
		return
	}
	defer rows.Close()

	ids := []int{}
	for rows.Next() {
		var id int
		rows.Scan(&id)
		ids = append(ids, id)
	}

	respond.Success(w, map[string]interface{}{"ids": ids})
}

func handlePut(w http.ResponseWriter, r *http.Request, userID int) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		respond.Error(w, "Failed to read request body")
		return
	}

	var payload struct {
		IDs []int `json:"ids"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		respond.Error(w, "Invalid JSON: expected {\"ids\": [...]}")
		return
	}

	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "Database error")
		return
	}

	tx.Exec(`DELETE FROM buddies WHERE user_id = ?`, userID)
	for _, buddyID := range payload.IDs {
		tx.Exec(`INSERT OR IGNORE INTO buddies (user_id, buddy_id) VALUES (?, ?)`,
			userID, buddyID)
	}

	if err := tx.Commit(); err != nil {
		respond.Error(w, "Failed to save buddies")
		return
	}

	respond.Success(w, nil)
}
