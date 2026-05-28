// Per-user chat state: which conversation+session a user was last
// looking at. Used by /chat/default to land them back where they were,
// and by the conversation page to remember their session selection
// across visits.
//
// Two pieces of state per user:
//
//	{ChatDataRoot}/users/<uid>/last-conv          — conv-key text file
//	{ChatDataRoot}/users/<uid>/last-sessions/<conv-key>
//	                                              — session-id text file
//
// We write on every conv page view + on every send, so the pointer
// tracks the user's actual focus. Best-effort: a failed write doesn't
// stop the request — the user just loses the bookmark for that visit.
package chat

import (
	"os"
	"path/filepath"
	"strings"
)

// userChatStateDir is a user's per-chat-state directory under
// ChatDataRoot. Sibling of users/<id>/docs/.
func userChatStateDir(uid string) string {
	return filepath.Join(ChatDataRoot, "users", uid)
}

// lastSessionPath is the per-conv last-viewed-session file.
func lastSessionPath(uid, convKey string) string {
	return filepath.Join(userChatStateDir(uid), "last-sessions", convKey)
}

// lastConvPath is the user's most-recently-viewed conv-key file.
func lastConvPath(uid string) string {
	return filepath.Join(userChatStateDir(uid), "last-conv")
}

// LastUserSession returns the session id this user last viewed for the
// (a, b) conversation, or "" if they've never been there.
func LastUserSession(uid, a, b string) string {
	b1, err := os.ReadFile(lastSessionPath(uid, chatPairKey(a, b)))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b1))
}

// SetUserLastSession persists which session this user last viewed for
// the (a, b) conv. Best-effort: errors are not surfaced.
func SetUserLastSession(uid, a, b, sessionID string) {
	if uid == "" || sessionID == "" {
		return
	}
	key := chatPairKey(a, b)
	dir := filepath.Join(userChatStateDir(uid), "last-sessions")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, key), []byte(sessionID+"\n"), 0o644)
	// Also bump the user's "last-conv" pointer (which conv they were on),
	// so /chat/default can resume to the right pair.
	_ = os.WriteFile(lastConvPath(uid), []byte(key+"\n"), 0o644)
}

// LastUserConv returns the conv-key this user was most recently
// looking at, or "" if they've never had one.
func LastUserConv(uid string) string {
	b, err := os.ReadFile(lastConvPath(uid))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// OtherInConv returns the partner uid given a user's own id and a
// conv-key in canonical "<a>_<b>" form, plus ok=false if the user
// isn't in the conv.
func OtherInConv(uid, convKey string) (string, bool) {
	x, y, found := strings.Cut(convKey, "_")
	if !found || x == "" || y == "" {
		return "", false
	}
	switch uid {
	case x:
		return y, true
	case y:
		return x, true
	}
	return "", false
}
