// Sidebar SSE — the per-user stream that pushes structural changes the
// conversation page's left sidebar needs to upsert without a reload:
// new chat partner, new topic, partner came-online. Live-only: no
// backlog. The initial server-rendered sidebar IS the backlog; a reload
// re-derives state from disk.
package chat

import (
	"angry-gopher/server/users"
	"net/http"
	"strings"
	"sync"
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

var (
	sidebarMu sync.Mutex
	// sidebarSubs is keyed by viewer user id; a user may have multiple tabs
	// open, so each id maps to a set of channels.
	sidebarSubs = map[string]map[chan sidebarEvent]struct{}{}
)

// publishSidebar delivers one event to every live sidebar subscriber of
// the named user. Best-effort: a full channel is skipped. Leaf lock,
// safe to call while holding chatMu (lock order: chatMu -> sidebarMu).
func publishSidebar(userID string, evt sidebarEvent) {
	sidebarMu.Lock()
	defer sidebarMu.Unlock()
	for ch := range sidebarSubs[userID] {
		select {
		case ch <- evt:
		default:
		}
	}
}

// PublishUserArrived broadcasts a new-partner event to every authorized
// principal EXCEPT the new user. Per-recipient, Conv is pre-resolved
// (the canonical numerically-sorted "<a>_<b>") so the client gets an
// already-buildable /chat/c/<conv> link without knowing its own uid.
func PublishUserArrived(newUID, newName string) {
	for _, u := range users.ListAuthorized() {
		if u.ID == newUID {
			continue
		}
		publishSidebar(u.ID, sidebarEvent{
			Kind:     "user-arrived",
			UserID:   newUID,
			UserName: newName,
			Conv:     chatPairKey(u.ID, newUID),
		})
	}
}

// PublishTopicAdded broadcasts a new-session event to BOTH conv
// participants. Called by AppendChatMessage exactly when the message
// being appended is the first in its session.
func PublishTopicAdded(conv, sid string) {
	a, b, ok := strings.Cut(conv, "_")
	if !ok || a == "" || b == "" {
		return
	}
	evt := sidebarEvent{Kind: "topic-added", Conv: conv, SID: sid}
	publishSidebar(a, evt)
	publishSidebar(b, evt)
}

func openSidebar(userID string) (<-chan sidebarEvent, func()) {
	ch := make(chan sidebarEvent, 16)
	sidebarMu.Lock()
	if sidebarSubs[userID] == nil {
		sidebarSubs[userID] = map[chan sidebarEvent]struct{}{}
	}
	sidebarSubs[userID][ch] = struct{}{}
	sidebarMu.Unlock()

	return ch, func() {
		sidebarMu.Lock()
		defer sidebarMu.Unlock()
		if subs := sidebarSubs[userID]; subs != nil {
			if _, ok := subs[ch]; ok {
				delete(subs, ch)
				close(ch)
			}
			if len(subs) == 0 {
				delete(sidebarSubs, userID)
			}
		}
	}
}

// HandleSidebarStream serves GET /chat/sidebar/stream.
func HandleSidebarStream(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan sidebarEvent, func()) {
		return openSidebar(user.ID)
	})
}
