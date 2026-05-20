// Package auth resolves "who is this request acting as" for Gopher.
//
// Login is not implemented yet: every request acts as the single
// hard-coded player (Steve). When a name-login lands, CurrentUser
// will read the gopher_user cookie set by the login picker and
// sanitize it (the name becomes a session-directory path segment).
package auth

import "net/http"

// DefaultUser is the hard-coded current player until login lands.
const DefaultUser = "Steve"

// CurrentUser returns the username the request acts as. For now it
// always returns DefaultUser.
func CurrentUser(r *http.Request) string {
	return DefaultUser
}
