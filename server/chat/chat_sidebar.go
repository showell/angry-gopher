// Sidebar SSE — the per-user stream that pushes structural changes the
// conversation page's left sidebar needs to upsert without a reload:
// a new authorized principal joined (new Conversations row) or a new
// topic appeared (new Sessions row, only if you're viewing that conv).
//
// SSE landscape (four streams, one file each):
//   - chat-message  chat_stream.go:  /chat/c/{conv}/{sid}/stream
//                                    (full rendered messages for ONE open session)
//   - notify        chat_notify.go:  /chat/notifications
//                                    (per-user pings + favicon-violet)
//   - recent        recent.go:       /chat/recent/stream
//                                    (per-user row upserts for the Recent page)
//   - sidebar       (HERE):          /chat/sidebar/stream
//                                    (per-user structural updates for the
//                                    conversation page's left sidebar)
//
// Publish chokepoints:
//   - chat_store.go::AppendChatMessage publishes topic-added to BOTH
//     conv participants when the message being appended is the FIRST
//     in its session (existing length == 0). Covers both code paths
//     that create a session (HandleChatNewTopic seeding "hi" and
//     daily/date sessions auto-created on first send).
//   - login.go::HandleLoginFull → users.FireNewMember → the init() hook
//     below → PublishUserArrived to every other authorized principal.
//
// Live-only: no backlog, no replay. The initial server-rendered sidebar
// IS the backlog; a reload re-derives state from disk.

package chat

import (
	"angry-gopher/server/users"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
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

// openSidebar registers a subscriber for one viewer; the returned cancel
// unregisters and closes its channel.
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

// HandleSidebarStream is the per-user SSE stream of sidebar structural
// events (GET /chat/sidebar/stream). Mirrors HandleRecentStream:
// cleared write deadline, ": ok" preamble flush, 25s ": ping"
// keepalives, ctx-cancel on disconnect.
func HandleSidebarStream(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	ch, cancel := openSidebar(user.ID)
	defer cancel()

	if _, err := fmt.Fprint(w, ": ok\n\n"); err != nil {
		return
	}
	if rc.Flush() != nil {
		return
	}

	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case evt, ok := <-ch:
			if !ok {
				return
			}
			blob, err := json.Marshal(evt)
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", blob); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		}
	}
}
