// Presence — who's actively touching the chat subsystem RIGHT NOW.
//
// Definition: a user is "online" if any chat-related server route counted
// their request within the last 5 minutes. No client-side polling, no idle
// detection — the server's view of "is this user touching things?" IS the
// definition.
//
// Lifecycle:
//   - Every counted route runs through WithPresence, which calls
//     MarkActive. MarkActive bumps the user's lastSeen timestamp.
//   - If the previous lastSeen was zero (never seen) or >= 5 minutes ago,
//     MarkActive reports cameOnline=true and we fan out to every other
//     authorized user via the existing user-attention layer (publishNotify
//     for the status strip + publishSidebar for the partner-row dot).
//   - No background sweeper, no offline broadcast. Clients infer "gone
//     offline" lazily — on the next page render the IsOnline check
//     returns false and the dot paints gray.
//
// Same posture as notifySubs / sidebarSubs: in-memory map, lost on
// restart, 5-minute fuzz is well below the precision the feature needs.
package chat

import (
	"angry-gopher/server/users"
	"net/http"
	"sync"
	"time"
)

// PresenceWindow is the rolling window for "online." A user with a
// MarkActive within this window is online; outside it, offline.
const PresenceWindow = 5 * time.Minute

var (
	presenceMu sync.Mutex
	// lastSeen is uid → most recent MarkActive timestamp.
	lastSeen = map[string]time.Time{}
)

// MarkActive bumps the user's lastSeen and reports whether THIS bump was
// the transition edge from offline to online (true on first-ever sighting
// OR after >= PresenceWindow of inactivity). Callers that need to
// broadcast should use markActiveAndBroadcast instead — this is the
// pure state mutation.
func MarkActive(userID string) (cameOnline bool) {
	if userID == "" {
		return false
	}
	now := time.Now()
	presenceMu.Lock()
	defer presenceMu.Unlock()
	prev, had := lastSeen[userID]
	lastSeen[userID] = now
	return !had || now.Sub(prev) >= PresenceWindow
}

// IsOnline reports whether the user has been MarkActive'd within
// PresenceWindow. Read-only; called by buildSidebarPayload to compute
// each partner row's Online flag at first paint.
func IsOnline(userID string) bool {
	if userID == "" {
		return false
	}
	presenceMu.Lock()
	defer presenceMu.Unlock()
	prev, had := lastSeen[userID]
	return had && time.Since(prev) < PresenceWindow
}

// markActiveAndBroadcast wraps MarkActive — on the came-online edge it
// fans the event out to every OTHER authorized user across both
// user-attention streams:
//
//   - publishSidebar(other, {kind:"user-online", ...}) drives the
//     partner-row dot on conversation pages.
//   - publishNotify(other, {text:"<name> has come online."}) drives the
//     status strip + favicon flash on every chat-chrome page.
//
// Pattern mirrors AppendChatMessage's fanout: leaf publishes happen
// while holding no other lock, and self is excluded (you don't see your
// own arrival, same as the notify suppress-self pattern).
func markActiveAndBroadcast(user users.User) {
	if !MarkActive(user.ID) {
		return
	}
	text := user.Name + " has come online."
	for _, other := range users.ListAuthorized() {
		if other.ID == user.ID {
			continue
		}
		publishSidebar(other.ID, sidebarEvent{
			Kind:     "user-online",
			UserID:   user.ID,
			UserName: user.Name,
		})
		publishNotify(other.ID, notifyEvent{Text: text})
	}
}

// WithPresence wraps a chat-related handler so any authorized request
// counts as activity. Unauthorized requests fall through untouched —
// presence is a privilege of being a real principal, not a way to
// fingerprint anonymous traffic.
//
// Routes that count are listed in registry.go (the chat page + Recent /
// Images / Code / Docs / Settings, plus the discrete actions that POST
// to chat). SSE streams and static JS deliberately don't count: a stream
// is the browser's job and a JS file is a cache hit.
func WithPresence(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if users.IsAuthorized(r) {
			markActiveAndBroadcast(users.CurrentUser(r))
		}
		h(w, r)
	}
}
