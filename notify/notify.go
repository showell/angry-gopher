// Package notify is the plumbing for the Claude↔Steve dev-harness
// forcing function: every meaningful Claude/Steve interaction leaves
// two traces — a persistent breadcrumb in /tmp/claude_inbox.log
// (Claude reads on wake) and a live SSE broadcast (Steve's browser
// lights up a bell, no reload needed).
//
// label: SPIKE (ANCHOR_COMMENTS)
package notify

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

const inboxPath = "/tmp/claude_inbox.log"

// Breadcrumb appends one tab-separated line to the inbox log.
// Future-Claude greps for author=="Steve" on session wake-up.
func Breadcrumb(source, author, location, anchor, body string) {
	f, err := os.OpenFile(inboxPath,
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	snippet := strings.ReplaceAll(body, "\n", " ")
	if len(snippet) > 200 {
		snippet = snippet[:200] + "…"
	}
	fmt.Fprintf(f, "%s\t%s\t%s\t%s\t%s\t%s\n",
		time.Now().Format(time.RFC3339), source, author, location, anchor, snippet)
}

// --- Live broadcast (SSE) ---

type Event struct {
	Summary string `json:"summary"`
	URL     string `json:"url"`
	Kind    string `json:"kind,omitempty"`    // "dm" | "wiki-comment"
	Sender  string `json:"sender,omitempty"`  // "Claude", "Claude (cron)"
	Snippet string `json:"snippet,omitempty"` // first ~200 chars of body
}

var (
	mu      sync.Mutex
	clients = map[chan string]struct{}{}
)

// Subscribe returns a channel receiving JSON-encoded events.
// Call the returned cancel function to unsubscribe.
func Subscribe() (<-chan string, func()) {
	ch := make(chan string, 8)
	mu.Lock()
	clients[ch] = struct{}{}
	mu.Unlock()
	return ch, func() {
		mu.Lock()
		delete(clients, ch)
		mu.Unlock()
		close(ch)
	}
}

// Broadcast fans an event out to every subscriber. Slow clients drop.
func Broadcast(ev Event) {
	data, err := json.Marshal(ev)
	if err != nil {
		return
	}
	s := string(data)
	mu.Lock()
	defer mu.Unlock()
	for ch := range clients {
		select {
		case ch <- s:
		default:
		}
	}
}
