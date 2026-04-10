// Package auth extracts the authenticated user from HTTP Basic auth.
// Angry Cat sends base64(email:api_key) on every request.
package auth

import (
	"database/sql"
	"encoding/base64"
	"net/http"
	"strings"
)

var DB *sql.DB

// Authenticate extracts the user from the Basic auth header.
// Returns the user ID, or 0 if auth fails.
func Authenticate(r *http.Request) int {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Basic ") {
		return 0
	}

	decoded, err := base64.StdEncoding.DecodeString(header[len("Basic "):])
	if err != nil {
		return 0
	}

	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) != 2 {
		return 0
	}
	email, apiKey := parts[0], parts[1]

	var userID int
	err = DB.QueryRow(
		`SELECT id FROM users WHERE email = ? AND api_key = ?`,
		email, apiKey,
	).Scan(&userID)
	if err != nil {
		return 0
	}

	return userID
}

// IsAdmin returns true if the given user has admin privileges.
func IsAdmin(userID int) bool {
	var isAdmin int
	err := DB.QueryRow(`SELECT is_admin FROM users WHERE id = ?`, userID).Scan(&isAdmin)
	return err == nil && isAdmin == 1
}
