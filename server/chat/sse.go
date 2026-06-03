package chat

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// subBus is a keyed pub/sub fan-out for SSE streams: each key maps to a
// set of buffered channels (one per open tab). publish is best-effort —
// a full channel is skipped, since every stream using this is live-only
// (a dropped event is one the user doesn't see; they re-derive on
// reload). Leaf lock — safe to call publish while holding outer locks
// (lock order: caller's mu → subBus.mu). Grep for `Bus.publish` /
// `Bus.open` to find every callsite.
type subBus[T any] struct {
	mu   sync.Mutex
	subs map[string]map[chan T]struct{}
}

func newSubBus[T any]() *subBus[T] {
	return &subBus[T]{subs: map[string]map[chan T]struct{}{}}
}

func (b *subBus[T]) publish(key string, evt T) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs[key] {
		select {
		case ch <- evt:
		default:
		}
	}
}

func (b *subBus[T]) open(key string) (<-chan T, func()) {
	ch := make(chan T, 16)
	b.mu.Lock()
	if b.subs[key] == nil {
		b.subs[key] = map[chan T]struct{}{}
	}
	b.subs[key][ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if set := b.subs[key]; set != nil {
			if _, ok := set[ch]; ok {
				delete(set, ch)
				close(ch)
			}
			if len(set) == 0 {
				delete(b.subs, key)
			}
		}
	}
}

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
