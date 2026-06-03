package chat

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// serveSSE drives the standard chat SSE wire shape: per-user channel,
// ": ok" preamble, 25s ": ping" keepalive, JSON-encoded events. The
// callsite supplies `open` to register a subscriber and return its
// channel + cancel.
//
// Five streams use this: /chat/notifications, /chat/sidebar/stream,
// /chat/recent/stream, /chat/images/stream, /chat/code/stream. Grep
// for serveSSE to find them. The in-thread message stream
// (/chat/c/{conv}/{sid}/stream) is the exception — it replays a
// backlog and emits a custom "backlog-size" preamble + per-event id,
// so it owns its own loop in chat_stream.go.
func serveSSE[T any](w http.ResponseWriter, r *http.Request, open func() (<-chan T, func())) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	ch, cancel := open()
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
