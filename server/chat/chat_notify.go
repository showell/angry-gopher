// Notify — the per-user "you have activity over there" SSE feed. Drives
// the #chat-notify status strip + favicon-violet on every page that
// includes notify.js (chat, docs, recent). Carries a tiny ping (from,
// conv, session) — no message body — so the user sees there's something
// to read and a link to get to it. Live-only: no backlog, no read-state.
//
// SSE landscape (three streams, one file each):
//   - chat-message  chat_stream.go: /chat/c/{conv}/{sid}/stream
//                                   (full rendered messages for ONE open session)
//   - notify        (HERE):         /chat/notifications
//                                   (per-user pings + favicon-violet)
//   - recent        recent.go:      /chat/recent/stream
//                                   (per-user row upserts for the Recent page)
//
// Publish chokepoint: chat_store.go::AppendChatMessage pings the RECIPIENT
// (and only the recipient) for every message, whatever its source
// (composer, Docs "post to chat", the API).
package chat

import (
	"angry-gopher/server/users"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// notifyEvent is one activity ping: "<From> sent you a message on <Session>"
// in conversation <Conv>. No body — just who/where, so the client shows a
// status line and a link, not the message itself.
type notifyEvent struct {
	From    string `json:"from"`
	Conv    string `json:"conv"`
	Session string `json:"session"`
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

// openNotify registers a subscriber for one user; the returned cancel
// unregisters and closes its channel.
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

// HandleChatNotifications is the per-user SSE stream of cross-session activity
// pings (GET /chat/notifications). Live-only — it registers the caller and
// forwards pings until the connection drops; no backlog, no message bodies.
func HandleChatNotifications(w http.ResponseWriter, r *http.Request) {
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
	// Long-lived; clear the server's 30s WriteTimeout so it isn't torn down.
	_ = rc.SetWriteDeadline(time.Time{})

	ch, cancel := openNotify(user.ID)
	defer cancel()

	// Flush immediately so the response headers go out and the client's
	// EventSource is established now — not 25s from now on the first keepalive.
	// (The message stream does the same via its backlog-size preamble.)
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
		case <-ticker.C: // keep-alive comment so idle proxies don't time out
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		}
	}
}
