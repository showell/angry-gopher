// User CRUD endpoints.
//
//   POST   /api/v1/users      — create a user (full_name only)
//   PATCH  /api/v1/users/{id} — rename a user
//
// Post-user-rip: no admin gating, no email, no api_key.
package users

import (
	"log"
	"net/http"
	"strings"
	"time"

	"angry-gopher/events"
	"angry-gopher/respond"
)

// HandleCreateUser handles POST /api/v1/users.
func HandleCreateUser(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	fullName := strings.TrimSpace(r.FormValue("full_name"))
	if fullName == "" {
		respond.Error(w, "Missing required param: full_name")
		return
	}

	result, err := DB.Exec(
		`INSERT INTO users (full_name, created_at) VALUES (?, ?)`,
		fullName, time.Now().Unix(),
	)
	if err != nil {
		respond.Error(w, "Failed to create user")
		return
	}

	id, _ := result.LastInsertId()
	log.Printf("[api] Created user %d: %s", id, fullName)

	respond.Success(w, map[string]interface{}{"user_id": id})
}

// HandleUpdateUser handles PATCH /api/v1/users/{id}. Renames a user.
func HandleUpdateUser(w http.ResponseWriter, r *http.Request) {
	targetID := respond.PathSegmentInt(r.URL.Path, 4)
	if targetID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	fullName := strings.TrimSpace(r.FormValue("full_name"))
	if fullName == "" {
		respond.Error(w, "Missing required param: full_name")
		return
	}

	_, err := DB.Exec(`UPDATE users SET full_name = ? WHERE id = ?`, fullName, targetID)
	if err != nil {
		respond.Error(w, "Failed to update user")
		return
	}

	log.Printf("[api] Updated user %d name to %q", targetID, fullName)

	events.PushToAll(map[string]interface{}{
		"type": "realm_user",
		"op":   "update",
		"person": map[string]interface{}{
			"user_id":   targetID,
			"full_name": fullName,
		},
	})

	respond.Success(w, nil)
}
