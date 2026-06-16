// Chat-message SSE — the per-(conv, session) live stream that delivers
// rendered messages to one open conversation page. Unlike the per-user
// streams (notify / sidebar / recent / images / code, all on serveSSE),
// this one replays a backlog and emits a custom "backlog-size" preamble
// + per-event id, so it owns its own loop here. Subscribe/publish live
// in chat_store.go, co-located with the file append under chatMu so a
// new subscriber atomically observes "backlog vs. future stream"
// without losing a message in the gap.
package chat

import (
	"angry-gopher/server/users"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// parseSince extracts the SSE replay cursor from Last-Event-ID
// (reconnect path) or ?since=N (initial load).
func parseSince(r *http.Request) int {
	if lei := strings.TrimSpace(r.Header.Get("Last-Event-ID")); lei != "" {
		if n, err := strconv.Atoi(lei); err == nil {
			return n + 1
		}
	}
	if q := r.URL.Query().Get("since"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n >= 0 {
			return n
		}
	}
	return 0
}

// HandleChatStream is the SSE endpoint for /chat/c/<conv>/<sid>/stream.
func HandleChatStream(w http.ResponseWriter, r *http.Request) {
	user, conv, sessionID, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)
	serveChatStream(w, r, DMConv(user.ID, partner), sessionID, parseSince(r))
}

// serveChatStream replays the session's backlog (with a "backlog-size"
// preamble so the client can suppress per-message scroll work until
// initial load lands) and streams live messages until disconnect. Used
// by both DM and channel topic streams.
func serveChatStream(w http.ResponseWriter, r *http.Request, c Conv, sid string, since int) {
	user := users.CurrentUser(r)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	backlog, ch, cancel := c.OpenStream(sid, since)
	defer cancel()

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
// anchors and for MSG_ref click resolution. `markdown` is the raw source;
// `html` is the server-rendered output of that same source.
type chatWireMsg struct {
	Index    int    `json:"index"`
	From     string `json:"from"`
	At       string `json:"at"` // RFC3339 UTC instant; client formats per-viewer zone
	HTML     string `json:"html"`
	Markdown string `json:"markdown"` // raw source, for client-side quote-reply / search
	ID       string `json:"id"`
	Mine     bool   `json:"mine"`
	Cid      string `json:"cid,omitempty"` // sender's correlation id (live broadcast only)
}

func writeChatEvent(w io.Writer, rc *http.ResponseController, evt chatEvent, me string) error {
	wire := chatWireMsg{
		Index:    evt.Index,
		From:     evt.Msg.From,
		At:       formatChatInstant(evt.Msg.At),
		HTML:     string(RenderChatMarkdown(evt.Msg.Markdown)),
		Markdown: evt.Msg.Markdown,
		ID:       evt.Msg.ID,
		Mine:     evt.Msg.From == me,
		Cid:      evt.Cid,
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
