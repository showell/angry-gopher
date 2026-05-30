// Chat-message SSE — the per-(conv, session) live stream that delivers
// rendered messages to one open conversation page.
//
// SSE landscape (three streams, one file each):
//   - chat-message (HERE):       /chat/c/{conv}/{sid}/stream
//   - notify        chat_notify.go: /chat/notifications  (per-user "you have
//                                   activity over there" pings + favicon-violet)
//   - recent        recent.go:      /chat/recent/stream  (per-user activity feed)
//
// Publish chokepoints (every SSE event the server emits is fired from one
// of these — the publish-at-source pattern is uniform):
//   - chat_store.go::AppendChatMessage publishes chat-message + notify + recent.
//   - docs_store.go::WriteUserDoc / CreateUserDoc publish recent.
//
// Why this file isn't fused with chat_store.go: the subscriber registry
// (chatSubs) and the publish loop live in chat_store.go because they're
// co-located with the file append under chatMu — that lock guarantees a
// new subscriber atomically observes "current backlog vs. future stream"
// without losing a message in the gap (see chat_store.go's header).
// chat_stream.go is just the HTTP face of that machinery: handler + wire
// encoding. Subscribe/publish stay near the storage they're synchronized
// with.

package chat

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HandleChatStream is the SSE endpoint for /chat/c/<conv>/<sid>/stream.
// It replays from `since` (or the Last-Event-ID on reconnect) and then
// streams live messages until the client disconnects.
func HandleChatStream(w http.ResponseWriter, r *http.Request) {
	user, conv, sessionID, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)

	since := 0
	if lei := strings.TrimSpace(r.Header.Get("Last-Event-ID")); lei != "" {
		if n, err := strconv.Atoi(lei); err == nil {
			since = n + 1
		}
	} else if q := r.URL.Query().Get("since"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n >= 0 {
			since = n
		}
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	// This connection is long-lived; clear the server's 30s WriteTimeout
	// so it isn't torn down mid-stream.
	_ = rc.SetWriteDeadline(time.Time{})

	backlog, ch, cancel := OpenChatStream(user.ID, partner, sessionID, since)
	defer cancel()

	// Preamble: tell the client how many backlog events to expect so it can
	// suppress per-message scroll work until the whole backlog has landed.
	// Without this, a 1000-message conversation scrolls visibly on each
	// message during initial load. Named SSE event ("backlog-size") routes
	// to a separate addEventListener on the client; the unnamed message
	// events for actual chat messages keep going to onmessage.
	if _, err := fmt.Fprintf(w, "event: backlog-size\ndata: %d\n\n", len(backlog)); err != nil {
		return
	}
	if rc.Flush() != nil {
		return
	}

	for _, evt := range backlog {
		if writeChatEvent(w, rc, evt, user.Name) != nil {
			return
		}
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
			if writeChatEvent(w, rc, evt, user.Name) != nil {
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

// chatWireMsg is the JSON payload of one SSE message event. `id` is the
// full MSG_ id (e.g. "2026-05-23_42"); the client uses it for #msg-<id>
// anchors and for MSG_ref click resolution.
type chatWireMsg struct {
	Index int    `json:"index"`
	From  string `json:"from"`
	Time  string `json:"time"`
	HTML  string `json:"html"`
	Enc   string `json:"enc"`
	Body  string `json:"body"` // raw markdown source, for client-side quote-reply
	ID    string `json:"id"`
	Mine  bool   `json:"mine"`
	Cid   string `json:"cid,omitempty"` // sender's correlation id (live broadcast only)
}

func writeChatEvent(w io.Writer, rc *http.ResponseController, evt chatEvent, me string) error {
	wire := chatWireMsg{
		Index: evt.Index,
		From:  evt.Msg.From,
		Time:  formatChatTime(evt.Msg.At),
		HTML:  string(RenderChatMarkdown(evt.Msg.Body)),
		Enc:   chatStoredForm(evt.Index, evt.Msg),
		Body:  evt.Msg.Body,
		ID:    evt.Msg.ID,
		Mine:  evt.Msg.From == me,
		Cid:   evt.Cid,
	}
	data, err := json.Marshal(wire)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "id: %d\ndata: %s\n\n", evt.Index, data); err != nil {
		return err
	}
	return rc.Flush()
}
