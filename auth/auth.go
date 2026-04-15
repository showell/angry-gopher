// Package auth resolves "who is this request acting as" for Gopher.
// After the user-rip (2026-04-15), auth is no longer enforced — this
// package just reads a cookie or query parameter to identify the
// caller for audit/ownership purposes.
//
// Resolution order:
//  1. Query param `?as=<id>` or `?as=<name>` — useful for multi-tab
//     testing (open Steve in one tab, Claude in another with ?as=claude).
//  2. Cookie `gopher_user` — set by a login picker; value is either
//     a numeric user id or a full_name.
//  3. Default: user id 1 (Steve).
//
// Identity is trust-on-assertion. Recorded for provenance, not
// enforced for security.
package auth

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"
)

var DB *sql.DB

const DefaultUserID = 1

// Authenticate returns the user id the caller is acting as.
// Always returns a valid id (defaults to DefaultUserID).
//
// Resolution order:
//  1. X-Gopher-User header (used by tests and scripts)
//  2. ?as=... query param
//  3. gopher_user cookie
//  4. DefaultUserID (Steve)
func Authenticate(r *http.Request) int {
	if h := r.Header.Get("X-Gopher-User"); h != "" {
		if id := resolve(h); id > 0 {
			return id
		}
	}
	if as := r.URL.Query().Get("as"); as != "" {
		if id := resolve(as); id > 0 {
			return id
		}
	}
	if c, _ := r.Cookie("gopher_user"); c != nil && c.Value != "" {
		if id := resolve(c.Value); id > 0 {
			return id
		}
	}
	return DefaultUserID
}

// resolve turns a string (numeric id or full_name) into a user id.
// Name match is case-insensitive. Returns 0 on miss.
func resolve(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if n, err := strconv.Atoi(s); err == nil && n > 0 {
		var id int
		if err := DB.QueryRow(`SELECT id FROM users WHERE id = ?`, n).Scan(&id); err == nil {
			return id
		}
		return 0
	}
	var id int
	err := DB.QueryRow(
		`SELECT id FROM users WHERE LOWER(full_name) = LOWER(?) LIMIT 1`, s,
	).Scan(&id)
	if err != nil {
		return 0
	}
	return id
}

// IsAdmin — kept for API shape. Always true now; admin gating has
// been ripped. Callers can be cleaned up opportunistically.
func IsAdmin(_ int) bool { return true }

// RequireAuth used to enforce Basic auth. Post-rip it always succeeds
// and returns the current user. Kept as a shim so existing call sites
// continue to compile; remove when no caller needs it.
func RequireAuth(w http.ResponseWriter, r *http.Request) int {
	return Authenticate(r)
}
