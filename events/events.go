// Package events manages the event queue system. Each registered client
// gets a queue. Handlers push events to all queues, and the /events
// endpoint long-polls until events arrive or timeout.
package events

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"angry-gopher/respond"
)

type queue struct {
	id     string
	events []map[string]interface{}
	lastID int
	mu     sync.Mutex
	notify chan struct{}
}

var (
	queues      = map[string]*queue{}
	queuesMu    sync.Mutex
	nextQueueID int
)

func newQueue() *queue {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	nextQueueID++
	q := &queue{
		id:     fmt.Sprintf("gopher-%d", nextQueueID),
		lastID: -1,
		notify: make(chan struct{}, 1),
	}
	queues[q.id] = q
	return q
}

// PushToAll sends an event to every registered queue.
func PushToAll(event map[string]interface{}) {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	for _, q := range queues {
		q.mu.Lock()
		q.lastID++
		// Copy the event so each queue gets its own event ID.
		cp := make(map[string]interface{})
		for k, v := range event {
			cp[k] = v
		}
		cp["id"] = q.lastID
		q.events = append(q.events, cp)
		q.mu.Unlock()
		select {
		case q.notify <- struct{}{}:
		default:
		}
	}
}

// HandleRegister handles POST /api/v1/register.
func HandleRegister(w http.ResponseWriter, r *http.Request) {
	q := newQueue()
	log.Printf("[api] Registered event queue: %s", q.id)
	respond.Success(w, map[string]interface{}{
		"queue_id":      q.id,
		"last_event_id": -1,
	})
}

// HandleEvents handles GET /api/v1/events (long-poll).
func HandleEvents(w http.ResponseWriter, r *http.Request) {
	queueID := r.URL.Query().Get("queue_id")
	lastEventIDStr := r.URL.Query().Get("last_event_id")
	lastEventID, _ := strconv.Atoi(lastEventIDStr)

	queuesMu.Lock()
	q, ok := queues[queueID]
	queuesMu.Unlock()

	if !ok {
		respond.WriteJSON(w, map[string]interface{}{
			"result": "error",
			"msg":    "Bad event queue id: " + queueID,
			"code":   "BAD_EVENT_QUEUE_ID",
		})
		return
	}

	pending := collectPending(q, lastEventID)

	if len(pending) > 0 {
		respond.Success(w, map[string]interface{}{"events": pending})
		return
	}

	// Long-poll: wait up to 50 seconds for new events.
	select {
	case <-q.notify:
	case <-time.After(50 * time.Second):
	}

	pending = collectPending(q, lastEventID)

	if len(pending) == 0 {
		pending = []map[string]interface{}{
			{"type": "heartbeat", "id": lastEventID + 1},
		}
	}

	respond.Success(w, map[string]interface{}{"events": pending})
}

func collectPending(q *queue, afterID int) []map[string]interface{} {
	q.mu.Lock()
	defer q.mu.Unlock()
	var pending []map[string]interface{}
	for _, ev := range q.events {
		if ev["id"].(int) > afterID {
			pending = append(pending, ev)
		}
	}
	return pending
}
