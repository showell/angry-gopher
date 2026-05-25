// Package auth holds name validation and reads the raw identity claim.
//
// Identity is now a numeric user id from the gopher_uid cookie; the
// display name is a mutable attribute resolved against the registry (see
// web.CurrentUser). Names are still validated/sanitized here because they
// are a directory-free attribute and are embedded in HTML.
package auth

import (
	"net/http"
	"strings"
	"unicode"
)

// maxUserLen caps a username's length.
const maxUserLen = 40

// CurrentUID returns the numeric user id from the gopher_uid cookie, or
// "" when there's no usable cookie. It's the raw identity claim; the
// caller resolves it against the registry (and for members the signed
// session cookie is authoritative — see web.CurrentUser).
func CurrentUID(r *http.Request) string {
	c, err := r.Cookie("gopher_uid")
	if err != nil || c.Value == "" {
		return ""
	}
	for _, ch := range c.Value {
		if ch < '0' || ch > '9' {
			return ""
		}
	}
	return c.Value
}

// allowedNameChar reports whether r may appear in a username: letters,
// digits, spaces, and apostrophes (for names like O'Reilly). No other
// punctuation is permitted.
func allowedNameChar(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || r == ' ' || r == '\''
}

// SanitizeUser scrubs a name into a clean attribute value: keeps the
// allowed characters, collapses whitespace runs, caps length. Lenient
// (strips rather than rejects) because it runs on a name handed through
// from the reserved-name notice; the login path then re-checks it with
// ValidateUserName for user-facing validation. Returns "" if nothing
// usable remains.
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
// spaces, and apostrophes, with at least one letter or digit. Returns
// the cleaned name with an empty error message on success, or
// ("", message) describing the fix to show the player.
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
	return out, ""
}
