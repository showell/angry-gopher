// Package users handles user-related Zulip API endpoints:
//   GET   /api/v1/users     — list all users
//   GET   /api/v1/users/me  — current user (from auth.Authenticate)
//   PATCH /api/v1/settings  — update the authenticated user's full_name
//
// Post-user-rip: users have only id + full_name + created_at.
// Every API response still emits email/is_admin/is_bot shaped like
// Zulip expects for Angry Cat compatibility, filled with stable
// defaults (synthesized "<name>@gopher.local" email, all is_admin=true,
// is_bot=false).
package users

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

var DB *sql.DB

// synthEmail builds a stable pseudo-email for Angry Cat compatibility.
// Cat still filters/displays by email; keep the shape while the data
// has drained away.
func synthEmail(fullName string) string {
	slug := strings.ToLower(strings.ReplaceAll(fullName, " ", "."))
	return fmt.Sprintf("%s@gopher.local", slug)
}

func HandleUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := DB.Query(`SELECT id, full_name FROM users ORDER BY id`)
	if err != nil {
		respond.Error(w, "Failed to query users")
		return
	}
	defer rows.Close()

	var members []map[string]interface{}
	for rows.Next() {
		var id int
		var fullName string
		rows.Scan(&id, &fullName)
		members = append(members, map[string]interface{}{
			"user_id":   id,
			"email":     synthEmail(fullName),
			"full_name": fullName,
			"is_admin":  true,
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

	var fullName string
	err := DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&fullName)
	if err != nil {
		respond.Error(w, "User not found")
		return
	}

	respond.Success(w, map[string]interface{}{
		"user": map[string]interface{}{
			"user_id":   userID,
			"email":     synthEmail(fullName),
			"full_name": fullName,
			"is_admin":  true,
		},
	})
}

// HandleGetUserByEmail handles GET /api/v1/users/by_email?email=...
// Matches against synthesized emails so Angry Cat still finds users
// by their old-style "<slug>@gopher.local" identifier.
func HandleGetUserByEmail(w http.ResponseWriter, r *http.Request) {
	email := r.URL.Query().Get("email")
	if email == "" {
		respond.Error(w, "Missing required param: email")
		return
	}

	rows, err := DB.Query(`SELECT id, full_name FROM users`)
	if err != nil {
		respond.Error(w, "Failed to query users")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var id int
		var fullName string
		rows.Scan(&id, &fullName)
		if synthEmail(fullName) == email {
			respond.Success(w, map[string]interface{}{
				"user": map[string]interface{}{
					"user_id":   id,
					"email":     email,
					"full_name": fullName,
					"is_admin":  true,
				},
			})
			return
		}
	}
	respond.Error(w, "User not found")
}

// HandleGetOwnUser handles GET /api/v1/users/me.
func HandleGetOwnUser(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)

	var fullName string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&fullName)

	respond.Success(w, map[string]interface{}{
		"user_id":   userID,
		"email":     synthEmail(fullName),
		"full_name": fullName,
		"is_admin":  true,
	})
}

// HandleUpdateSettings handles PATCH /api/v1/settings.
func HandleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPatch {
		respond.Error(w, "Method not allowed")
		return
	}

	userID := auth.Authenticate(r)
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
