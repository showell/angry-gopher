// Package users handles user-related Zulip API endpoints:
//   GET   /api/v1/users     — list all users
//   PATCH /api/v1/settings  — update the authenticated user's settings
package users

import (
	"database/sql"
	"log"
	"net/http"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

func HandleUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := DB.Query(`SELECT id, email, full_name, is_admin FROM users`)
	if err != nil {
		respond.Error(w, "Failed to query users")
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

	respond.Success(w, map[string]interface{}{"members": members})
}

// HandleGetUser handles GET /api/v1/users/{id}.
func HandleGetUser(w http.ResponseWriter, r *http.Request) {
	userID := respond.PathSegmentInt(r.URL.Path, 4)
	if userID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	var email, fullName string
	var isAdmin int
	err := DB.QueryRow(`SELECT email, full_name, is_admin FROM users WHERE id = ?`, userID).Scan(&email, &fullName, &isAdmin)
	if err != nil {
		respond.Error(w, "User not found")
		return
	}

	respond.Success(w, map[string]interface{}{
		"user": map[string]interface{}{
			"user_id":   userID,
			"email":     email,
			"full_name": fullName,
			"is_admin":  isAdmin == 1,
		},
	})
}

// HandleGetUserByEmail handles GET /api/v1/users/by_email?email=...
func HandleGetUserByEmail(w http.ResponseWriter, r *http.Request) {
	email := r.URL.Query().Get("email")
	if email == "" {
		respond.Error(w, "Missing required param: email")
		return
	}

	var id int
	var fullName string
	var isAdmin int
	err := DB.QueryRow(`SELECT id, full_name, is_admin FROM users WHERE email = ?`, email).Scan(&id, &fullName, &isAdmin)
	if err != nil {
		respond.Error(w, "User not found")
		return
	}

	respond.Success(w, map[string]interface{}{
		"user": map[string]interface{}{
			"user_id":   id,
			"email":     email,
			"full_name": fullName,
			"is_admin":  isAdmin == 1,
		},
	})
}

// HandleGetOwnUser handles GET /api/v1/users/me.
func HandleGetOwnUser(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	var email, fullName string
	var isAdmin int
	DB.QueryRow(`SELECT email, full_name, is_admin FROM users WHERE id = ?`, userID).Scan(&email, &fullName, &isAdmin)

	respond.Success(w, map[string]interface{}{
		"user_id":   userID,
		"email":     email,
		"full_name": fullName,
		"is_admin":  isAdmin == 1,
	})
}

// HandleMuteUser handles POST /api/v1/users/me/muted_users/{id}.
func HandleMuteUser(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	mutedID := respond.PathSegmentInt(r.URL.Path, 5)
	if mutedID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	if r.Method == "POST" {
		DB.Exec(`INSERT OR IGNORE INTO muted_users (user_id, muted_user_id) VALUES (?, ?)`, userID, mutedID)
		log.Printf("[api] User %d muted user %d", userID, mutedID)
		respond.Success(w, nil)
	} else if r.Method == "DELETE" {
		DB.Exec(`DELETE FROM muted_users WHERE user_id = ? AND muted_user_id = ?`, userID, mutedID)
		log.Printf("[api] User %d unmuted user %d", userID, mutedID)
		respond.Success(w, nil)
	} else {
		respond.Error(w, "Method not allowed")
	}
}

// HandleGetMutedUsers handles GET /api/v1/users/me/muted_users.
func HandleGetMutedUsers(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	rows, err := DB.Query(`
		SELECT mu.muted_user_id, u.full_name
		FROM muted_users mu
		JOIN users u ON mu.muted_user_id = u.id
		WHERE mu.user_id = ?`, userID)
	if err != nil {
		respond.Error(w, "Failed to query muted users")
		return
	}
	defer rows.Close()

	var muted []map[string]interface{}
	for rows.Next() {
		var id int
		var name string
		rows.Scan(&id, &name)
		muted = append(muted, map[string]interface{}{
			"id":        id,
			"full_name": name,
		})
	}

	respond.Success(w, map[string]interface{}{"muted_users": muted})
}

// HandleUpdateSettings handles PATCH /api/v1/settings.
//
// Mirrors Zulip's settings update endpoint. The authenticated
// user updates their own profile. For now we accept a single
// field, full_name, but the endpoint is shaped to grow more
// fields without changing the route. Unknown form fields are
// ignored.
//
// Request:
//   PATCH /api/v1/settings
//   Content-Type: application/x-www-form-urlencoded
//   full_name=...
//
// Response:
//   { "result": "success", "full_name": "..." }   on success
//   { "result": "error",   "msg": "..."        }   on failure
func HandleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPatch {
		respond.Error(w, "Method not allowed")
		return
	}

	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	fullName := strings.TrimSpace(r.FormValue("full_name"))
	if fullName == "" {
		respond.Error(w, "full_name cannot be empty")
		return
	}

	_, err := DB.Exec(
		`UPDATE users SET full_name = ? WHERE id = ?`,
		fullName, userID,
	)
	if err != nil {
		respond.Error(w, "Failed to update settings")
		return
	}

	log.Printf("[api] Updated full_name for user %d to %q", userID, fullName)

	// Notify all connected clients so buddy lists, message
	// sender names, etc. update in real time without a page
	// refresh. Matches Zulip's "realm_user" event shape.
	events.PushToAll(map[string]interface{}{
		"type": "realm_user",
		"op":   "update",
		"person": map[string]interface{}{
			"user_id":   userID,
			"full_name": fullName,
		},
	})

	respond.Success(w, map[string]interface{}{
		"full_name": fullName,
	})
}
