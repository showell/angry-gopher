// Sidebar SSE — the per-user stream that pushes structural changes the
// conversation page's left sidebar needs to upsert without a reload:
// new chat partner, new topic, partner came-online. Live-only: no
// backlog. The initial server-rendered sidebar IS the backlog; a reload
// re-derives state from disk.
package chat

import (
	"angry-gopher/server/users"
	"net/http"
)

// init wires chat's sidebar publish into users' new-member hook so login
// doesn't need to import chat. Runs at process startup when the chat
// package is imported (which main.go does via the registry).
func init() {
	users.RegisterNewMemberHook(func(uid, name string) {
		PublishUserArrived(uid, name)
	})
}

// sidebarEvent is one structural ping. Kind discriminates: user-arrived
// is a fresh chat partner (Conv pre-resolved to the partner-key from the
// RECIPIENT'S perspective so the client doesn't need to know its own uid);
// topic-added is a new session in a conversation you're (probably) in;
// user-online flips the partner-row presence dot on (no Conv field —
// presence is per-user, not per-conversation).
type sidebarEvent struct {
	Kind     string `json:"kind"` // "user-arrived" | "topic-added" | "user-online"
	UserID   string `json:"user_id,omitempty"`
	UserName string `json:"user_name,omitempty"`
	Conv     string `json:"conv,omitempty"`
	SID      string `json:"sid,omitempty"`
}

// sidebarBus is keyed by viewer user id.
var sidebarBus = newSubBus[sidebarEvent]()

// PublishUserArrived broadcasts a new-partner event to every authorized
// principal EXCEPT the new user. Per-recipient, Conv is pre-resolved
// (the canonical numerically-sorted "<a>_<b>") so the client gets an
// already-buildable /chat/c/<conv> link without knowing its own uid.
func PublishUserArrived(newUID, newName string) {
	for _, u := range users.ListAuthorized() {
		if u.ID == newUID {
			continue
		}
		sidebarBus.publish(u.ID, sidebarEvent{
			Kind:     "user-arrived",
			UserID:   newUID,
			UserName: newName,
			Conv:     chatPairKey(u.ID, newUID),
		})
	}
}

// publishTopicAddedForConv broadcasts a new-session event to every
// conv member. Called by Conv.AppendMessage when the message being
// appended is the first in its session.
func publishTopicAddedForConv(c Conv, sid string) {
	evt := sidebarEvent{Kind: "topic-added", Conv: c.Key, SID: sid}
	for _, uid := range c.Members {
		sidebarBus.publish(uid, evt)
	}
}

// HandleSidebarStream serves GET /chat/sidebar/stream.
func HandleSidebarStream(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan sidebarEvent, func()) {
		return sidebarBus.open(user.ID)
	})
}
