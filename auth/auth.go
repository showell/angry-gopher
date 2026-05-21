// Package auth resolves "who is this request acting as" for Gopher.
//
// Identity is a username read from the gopher_user cookie (set by the
// /login endpoint) and sanitized — the name becomes a session
// directory segment and is embedded in HTML and Zulip messages, so it
// is scrubbed to a safe character set here. No password yet: this is an
// open game and the name is the honor-system identity, not a security
// boundary. (Passwords are a planned future addition.)
package auth

import (
	"net/http"
	"strings"
	"unicode"
)

// DefaultUser is who a request acts as before anyone has logged in. It
// is reserved — ValidateUserName refuses it as a chosen name so it can
// never collide with the logged-out sentinel.
const DefaultUser = "guest"

// maxUserLen caps a username's length.
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

// allowedNameChar reports whether r may appear in a username: letters,
// digits, spaces, and apostrophes (for names like O'Reilly). No other
// punctuation is permitted.
func allowedNameChar(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || r == ' ' || r == '\''
}

// SanitizeUser scrubs a name into a safe directory segment: keeps the
// allowed characters, collapses whitespace runs, caps length. It is
// lenient (strips rather than rejects) because it also runs on raw
// cookie values and admin params; the login path uses ValidateUserName
// for user-facing validation. Returns "" if nothing usable remains.
func SanitizeUser(name string) string {
	var b strings.Builder
	lastSpace := false
	for _, r := range strings.TrimSpace(name) {
		switch {
		case r == ' ':
			if !lastSpace && b.Len() > 0 {
				b.WriteRune(' ')
				lastSpace = true
			}
		case allowedNameChar(r):
			b.WriteRune(r)
			lastSpace = false
		}
		if b.Len() >= maxUserLen {
			break
		}
	}
	return strings.TrimRight(b.String(), " ")
}

// ValidateUserName cleans and checks a login-supplied name. It trims,
// collapses internal whitespace, and requires only letters, digits,
// spaces, and apostrophes, with at least one letter or digit, and
// rejects the reserved DefaultUser name. Returns the cleaned name with
// an empty error message on success, or ("", message) describing the
// fix to show the player.
func ValidateUserName(raw string) (name, errMsg string) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", "Please enter a name."
	}
	if len(trimmed) > maxUserLen {
		return "", "That name is too long (40 characters max)."
	}

	var b strings.Builder
	lastSpace := false
	hasAlnum := false
	for _, r := range trimmed {
		if !allowedNameChar(r) {
			return "", "Names can use only letters, numbers, spaces, and apostrophes."
		}
		if r == ' ' {
			if lastSpace {
				continue
			}
			lastSpace = true
		} else {
			lastSpace = false
			if unicode.IsLetter(r) || unicode.IsNumber(r) {
				hasAlnum = true
			}
		}
		b.WriteRune(r)
	}

	out := strings.TrimRight(b.String(), " ")
	if !hasAlnum {
		return "", "Please enter a name with at least one letter or number."
	}
	if strings.EqualFold(out, DefaultUser) {
		return "", "That name is reserved — please choose another."
	}
	return out, ""
}
