// Notify — the per-user "you have activity over there" SSE feed.
// Drives the #chat-notify status strip + favicon-violet on every page
// that includes notify.js. Live-only: no backlog, no read-state.
package chat

import (
	"angry-gopher/server/users"
	"net/http"
	"sync"
)

// notifyEvent is one activity ping on the user-attention layer. Two
// shapes flow through the same stream:
//
//   - Message ping: From / Conv / Session populated; the client renders
//     "<From> sent you a message on <Session>" linking to the thread.
//   - Free-form status (presence "X has come online" today): Text +
//     LinkURL populated and the others empty. The client renders Text
//     as the LinkURL's label.
//
// PRODUCT_DECISION: every status message is actionable. When Text is
// set, LinkURL MUST also be set — the client unconditionally wraps Text
// in an <a href=LinkURL>. There is no plain-text "status only"
// rendering path; if you can't motivate a destination for a notice, it
// doesn't belong on the user-attention layer.
//
// Text takes precedence on the client. The notify strip is the chat
// subsystem's "user attention" surface — every chat-chrome page wires
// #chat-notify — so anything that should flash the favicon + tab strip
// for the user (not for a specific thread) belongs here.
type notifyEvent struct {
	From    string `json:"from,omitempty"`
	Conv    string `json:"conv,omitempty"`
	Session string `json:"session,omitempty"`
	Text    string `json:"text,omitempty"`
	LinkURL string `json:"link_url,omitempty"`
}

var (
	notifyMu sync.Mutex
	// notifySubs is keyed by recipient user id; a user may have several open
	// pages/tabs, so each id maps to a set of channels.
	notifySubs = map[string]map[chan notifyEvent]struct{}{}
)

// publishNotify delivers a ping to every live connection of one user.
// Best-effort: a full channel is skipped (notifications are live-only, so a
// dropped ping is just one the user doesn't see). Acquires notifyMu only;
// callers may hold chatMu (lock order chatMu -> notifyMu; notifyMu is a leaf).
func publishNotify(userID string, evt notifyEvent) {
	notifyMu.Lock()
	defer notifyMu.Unlock()
	for ch := range notifySubs[userID] {
		select {
		case ch <- evt:
		default:
		}
	}
}

func openNotify(userID string) (<-chan notifyEvent, func()) {
	ch := make(chan notifyEvent, 16)
	notifyMu.Lock()
	if notifySubs[userID] == nil {
		notifySubs[userID] = map[chan notifyEvent]struct{}{}
	}
	notifySubs[userID][ch] = struct{}{}
	notifyMu.Unlock()

	return ch, func() {
		notifyMu.Lock()
		defer notifyMu.Unlock()
		if subs := notifySubs[userID]; subs != nil {
			if _, ok := subs[ch]; ok {
				delete(subs, ch)
				close(ch)
			}
			if len(subs) == 0 {
				delete(notifySubs, userID)
			}
		}
	}
}

// HandleChatNotifications serves GET /chat/notifications.
func HandleChatNotifications(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan notifyEvent, func()) {
		return openNotify(user.ID)
	})
}
