// Package auth resolves "who is this request acting as" for Gopher.
//
// Identity is a username read from the gopher_user cookie (set by the
// /gopher/login endpoint) and sanitized — the name becomes a session
// directory segment and is embedded in HTML and Zulip messages, so it
// is scrubbed to a safe character set here. No password: this is an
// open game; the name is provenance, not a security boundary.
package auth

import (
	"net/http"
	"strings"
	"unicode"
)

// DefaultUser is who a request acts as before anyone has logged in.
const DefaultUser = "guest"

// maxUserLen caps a sanitized username's length.
const maxUserLen = 40

// CurrentUser returns the sanitized username from the gopher_user
// cookie, or DefaultUser when there's no usable cookie.
func CurrentUser(r *http.Request) string {
	if c, err := r.Cookie("gopher_user"); err == nil {
		if name := SanitizeUser(c.Value); name != "" {
			return name
		}
	}
	return DefaultUser
}

// SanitizeUser normalizes a player-supplied name into something safe
// to use as a directory segment and to embed in HTML/Zulip: keeps
// letters, digits, spaces, and `-_.`; collapses whitespace runs; caps
// length; rejects path-traversal names. Returns "" if nothing usable
// remains (caller should then fall back or reject).
func SanitizeUser(name string) string {
	var b strings.Builder
	lastSpace := false
	for _, r := range strings.TrimSpace(name) {
		switch {
		case unicode.IsLetter(r) || unicode.IsNumber(r):
			b.WriteRune(r)
			lastSpace = false
		case r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
			lastSpace = false
		case r == ' ':
			if !lastSpace && b.Len() > 0 {
				b.WriteRune(' ')
				lastSpace = true
			}
		}
		if b.Len() >= maxUserLen {
			break
		}
	}
	out := strings.TrimRight(b.String(), " ")
	if out == "." || out == ".." {
		return ""
	}
	return out
}
