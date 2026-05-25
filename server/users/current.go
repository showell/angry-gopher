package users

import (
	"net/http"
)

// CurrentUser resolves the identity a request acts as. A valid member
// session is authoritative. Otherwise it's the guest named by the
// gopher_uid cookie — but only if that id is a NON-member; a uid pointing
// at a member without a session is a forge attempt and is ignored.
// Returns the zero User (ID == "") when there's no valid identity.
func CurrentUser(r *http.Request) User {
	if id, ok := SessionUser(r); ok {
		return LoadUser(id)
	}
	// An API key authenticates a member for read-only access; it is never
	// an admin credential, so strip Admin (the login gate also blocks any
	// non-GET key request).
	if id, ok := apiKeyUser(r); ok {
		u := LoadUser(id)
		u.Admin = false
		return u
	}
	id := CurrentUID(r)
	if id != "" && UserExists(id) && !UserIsMember(id) {
		return LoadUser(id)
	}
	return User{}
}
