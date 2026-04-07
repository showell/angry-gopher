// Package invites handles one-time invite links for new users.
//
// Flow:
//   1. Admin creates invite: POST /api/v1/invites
//      → stores token with name, email, expiry
//      → returns the token
//   2. New user redeems invite: POST /api/v1/invites/redeem
//      → validates token (one-time, not expired)
//      → creates user with generated API key
//      → subscribes to all public channels
//      → returns credentials to Angry Cat
package invites

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"log"
	"net/http"
	"time"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

var DB *sql.DB

const tokenExpiry = 24 * time.Hour

func generateToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func generateAPIKey(name string) string {
	b := make([]byte, 12)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// HandleCreateInvite handles POST /api/v1/invites.
// Requires admin auth. Params: email, full_name.
func HandleCreateInvite(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	// Verify the user is an admin.
	var isAdmin int
	DB.QueryRow(`SELECT is_admin FROM users WHERE id = ?`, userID).Scan(&isAdmin)
	if isAdmin != 1 {
		respond.Error(w, "Only admins can create invites")
		return
	}

	email := r.FormValue("email")
	fullName := r.FormValue("full_name")
	if email == "" || fullName == "" {
		respond.Error(w, "Missing required parameters: email, full_name")
		return
	}

	// Check if email is already taken.
	var existing int
	DB.QueryRow(`SELECT COUNT(*) FROM users WHERE email = ?`, email).Scan(&existing)
	if existing > 0 {
		respond.Error(w, "A user with this email already exists")
		return
	}

	token := generateToken()
	expiresAt := time.Now().Add(tokenExpiry).Unix()

	_, err := DB.Exec(
		`INSERT INTO invites (token, email, full_name, expires_at) VALUES (?, ?, ?, ?)`,
		token, email, fullName, expiresAt,
	)
	if err != nil {
		respond.Error(w, "Failed to create invite")
		return
	}

	log.Printf("[api] Invite created for %s (%s) by user %d", fullName, email, userID)

	respond.Success(w, map[string]interface{}{
		"token": token,
	})
}

// HandleRedeemInvite handles POST /api/v1/invites/redeem.
// No auth required — the token is the credential. Param: token.
func HandleRedeemInvite(w http.ResponseWriter, r *http.Request) {
	token := r.FormValue("token")
	if token == "" {
		respond.Error(w, "Missing required parameter: token")
		return
	}

	var email, fullName string
	var expiresAt int64
	err := DB.QueryRow(
		`SELECT email, full_name, expires_at FROM invites WHERE token = ?`,
		token,
	).Scan(&email, &fullName, &expiresAt)
	if err != nil {
		respond.Error(w, "Invalid invite token")
		return
	}

	if time.Now().Unix() > expiresAt {
		DB.Exec(`DELETE FROM invites WHERE token = ?`, token)
		respond.Error(w, "Invite has expired")
		return
	}

	// Create the user.
	apiKey := generateAPIKey(fullName)
	result, err := DB.Exec(
		`INSERT INTO users (email, full_name, api_key) VALUES (?, ?, ?)`,
		email, fullName, apiKey,
	)
	if err != nil {
		respond.Error(w, "Failed to create user")
		return
	}
	newUserID, _ := result.LastInsertId()

	// Subscribe to all public channels. Collect IDs first, then
	// close the rows so the single DB connection is free for inserts.
	var publicChannelIDs []int
	rows, err := DB.Query(`SELECT channel_id FROM channels WHERE invite_only = 0`)
	if err == nil {
		for rows.Next() {
			var channelID int
			rows.Scan(&channelID)
			publicChannelIDs = append(publicChannelIDs, channelID)
		}
		rows.Close()
	}
	for _, channelID := range publicChannelIDs {
		DB.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`,
			newUserID, channelID)
	}

	// Delete the invite — single use.
	DB.Exec(`DELETE FROM invites WHERE token = ?`, token)

	log.Printf("[api] Invite redeemed: %s (%s) → user %d", fullName, email, newUserID)

	respond.Success(w, map[string]interface{}{
		"email":     email,
		"api_key":   apiKey,
		"full_name": fullName,
		"user_id":   newUserID,
	})
}
