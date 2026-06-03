// Notify — the per-user "you have activity over there" SSE feed.
// Drives the #chat-notify status strip + favicon-violet on every page
// that includes notify.js. Live-only: no backlog, no read-state.
package chat

import (
	"angry-gopher/server/users"
	"net/http"
)

// notifyEvent is one ping on the user-attention layer. INVARIANT: Text
// and LinkURL are ALWAYS set — every status message is actionable and
// renders as <a href=LinkURL>Text</a> on the client, no conditional.
//
// Conv + Session, when set, name the (conv, session) the event is
// about; the client suppresses the strip update if that pair matches
// the open feed (you don't need a "you have a new message" notice for
// the thread you're actively reading). Cross-thread events (presence,
// channel posts viewed from a different page) leave them empty.
//
// The notify strip is the chat subsystem's "user attention" surface —
// every chat-chrome page wires #chat-notify — so anything that should
// flash the favicon + tab strip for the user belongs here.
type notifyEvent struct {
	Conv    string `json:"conv,omitempty"`
	Session string `json:"session,omitempty"`
	Text    string `json:"text"`
	LinkURL string `json:"link_url"`
}

// notifyBus is keyed by recipient user id (a user may have several
// open tabs, so each id maps to a set of channels).
var notifyBus = newSubBus[notifyEvent]()

// HandleChatNotifications serves GET /chat/notifications.
func HandleChatNotifications(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan notifyEvent, func()) {
		return notifyBus.open(user.ID)
	})
}
