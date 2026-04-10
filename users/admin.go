// Admin user management endpoints.
//
//   POST   /api/v1/users                — create a user (admin)
//   PATCH  /api/v1/users/{id}           — update a user (admin)
//   POST   /api/v1/users/{id}/deactivate — deactivate a user (admin)
//   POST   /api/v1/users/{id}/reactivate — reactivate a user (admin)
//   DELETE /api/v1/users/me             — deactivate own account
//   POST   /api/v1/users/{id}/regenerate_api_key — regenerate API key (admin)
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
		`INSERT INTO users (email, full_name, api_key, is_admin, is_active) VALUES (?, ?, ?, ?, 1)`,
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

// HandleDeactivateUser handles POST /api/v1/users/{id}/deactivate.
func HandleDeactivateUser(w http.ResponseWriter, r *http.Request) {
	adminID := requireAdmin(r)
	if adminID == 0 {
		respond.Error(w, "Admin access required")
		return
	}

	targetID := respond.PathSegmentInt(r.URL.Path, 4)
	if targetID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	if targetID == adminID {
		respond.Error(w, "Cannot deactivate yourself via this endpoint")
		return
	}

	result, err := DB.Exec(`UPDATE users SET is_active = 0 WHERE id = ? AND is_active = 1`, targetID)
	if err != nil {
		respond.Error(w, "Failed to deactivate user")
		return
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		respond.Error(w, "User not found or already deactivated")
		return
	}

	log.Printf("[api] Admin %d deactivated user %d", adminID, targetID)
	respond.Success(w, nil)
}

// HandleReactivateUser handles POST /api/v1/users/{id}/reactivate.
func HandleReactivateUser(w http.ResponseWriter, r *http.Request) {
	if requireAdmin(r) == 0 {
		respond.Error(w, "Admin access required")
		return
	}

	targetID := respond.PathSegmentInt(r.URL.Path, 4)
	if targetID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	result, err := DB.Exec(`UPDATE users SET is_active = 1 WHERE id = ? AND is_active = 0`, targetID)
	if err != nil {
		respond.Error(w, "Failed to reactivate user")
		return
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		respond.Error(w, "User not found or already active")
		return
	}

	log.Printf("[api] Reactivated user %d", targetID)
	respond.Success(w, nil)
}

// HandleDeactivateOwnUser handles DELETE /api/v1/users/me.
func HandleDeactivateOwnUser(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	DB.Exec(`UPDATE users SET is_active = 0 WHERE id = ?`, userID)
	log.Printf("[api] User %d deactivated their own account", userID)
	respond.Success(w, nil)
}

// HandleRegenerateAPIKey handles POST /api/v1/users/{id}/regenerate_api_key.
func HandleRegenerateAPIKey(w http.ResponseWriter, r *http.Request) {
	if requireAdmin(r) == 0 {
		respond.Error(w, "Admin access required")
		return
	}

	targetID := respond.PathSegmentInt(r.URL.Path, 4)
	if targetID == 0 {
		respond.Error(w, "Invalid user ID")
		return
	}

	newKey := generateAPIKey()
	_, err := DB.Exec(`UPDATE users SET api_key = ? WHERE id = ?`, newKey, targetID)
	if err != nil {
		respond.Error(w, "Failed to regenerate API key")
		return
	}

	log.Printf("[api] Regenerated API key for user %d", targetID)
	respond.Success(w, map[string]interface{}{"api_key": newKey})
}
