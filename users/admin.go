// Admin user management endpoints.
//
//   POST   /api/v1/users      — create a user (admin)
//   PATCH  /api/v1/users/{id} — update a user (admin)
package users

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"strings"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

func requireAdmin(r *http.Request) int {
	userID := auth.Authenticate(r)
	if userID == 0 || !auth.IsAdmin(userID) {
		return 0
	}
	return userID
}

func generateAPIKey() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// HandleCreateUser handles POST /api/v1/users.
func HandleCreateUser(w http.ResponseWriter, r *http.Request) {
	if requireAdmin(r) == 0 {
		respond.Error(w, "Admin access required")
		return
	}

	r.ParseForm()
	email := strings.TrimSpace(r.FormValue("email"))
	fullName := strings.TrimSpace(r.FormValue("full_name"))

	if email == "" || fullName == "" {
		respond.Error(w, "Missing required params: email, full_name")
		return
	}

	// Check for duplicate email.
	var exists int
	DB.QueryRow(`SELECT COUNT(*) FROM users WHERE email = ?`, email).Scan(&exists)
	if exists > 0 {
		respond.Error(w, "A user with this email already exists")
		return
	}

	apiKey := generateAPIKey()
	isAdmin := 0
	if r.FormValue("is_admin") == "true" {
		isAdmin = 1
	}

	result, err := DB.Exec(
		`INSERT INTO users (email, full_name, api_key, is_admin) VALUES (?, ?, ?, ?)`,
		email, fullName, apiKey, isAdmin)
	if err != nil {
		respond.Error(w, "Failed to create user")
		return
	}

	id, _ := result.LastInsertId()
	log.Printf("[api] Created user %d: %s (%s)", id, fullName, email)

	respond.Success(w, map[string]interface{}{
		"user_id": id,
		"api_key": apiKey,
	})
}

// HandleUpdateUser handles PATCH /api/v1/users/{id}.
func HandleUpdateUser(w http.ResponseWriter, r *http.Request) {
	if requireAdmin(r) == 0 {
		respond.Error(w, "Admin access required")
		return
	}

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

	log.Printf("[api] Admin updated user %d name to %q", targetID, fullName)

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

