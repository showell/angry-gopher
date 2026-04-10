// Package events manages the event queue system. Each registered client
// gets a queue tied to their user ID. When events are pushed, a filter
// function determines which queues receive each event based on the
// queue owner's permissions.
package events

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

type queue struct {
	id     string
	userID int
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

func newQueue(userID int) *queue {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	nextQueueID++
	q := &queue{
		id:     fmt.Sprintf("gopher-%d", nextQueueID),
		userID: userID,
		lastID: -1,
		notify: make(chan struct{}, 1),
	}
	queues[q.id] = q
	return q
}

func pushToQueue(q *queue, event map[string]interface{}) {
	q.mu.Lock()
	q.lastID++
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

// PushToAll sends an event to every registered queue unconditionally.
// Use this for events where access has already been validated or
// that are relevant to all users (e.g. flag updates on the sender's
// own messages, heartbeats).
func PushToAll(event map[string]interface{}) {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	for _, q := range queues {
		pushToQueue(q, event)
	}
}

// PushFiltered sends an event only to queues whose owner passes the
// filter. The filter receives the queue owner's user ID and returns
// true if the event should be delivered. Use this for events that
// depend on channel access (e.g. new messages in private channels).
func PushFiltered(event map[string]interface{}, filter func(userID int) bool) {
	queuesMu.Lock()
	defer queuesMu.Unlock()
	for _, q := range queues {
		if filter(q.userID) {
			pushToQueue(q, event)
		}
	}
}

// HandleRegister handles POST /api/v1/register.
func HandleRegister(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	q := newQueue(userID)
	log.Printf("[api] Registered event queue: %s (user %d)", q.id, userID)
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

	// Return whatever we have — possibly empty. We no longer
	// fabricate heartbeat events because their IDs collided with
	// real event IDs: the heartbeat used lastEventID+1, which is
	// the same ID the next real event would get from q.lastID++.
	// The client advanced past that ID, causing the real event to
	// be silently skipped on the next poll.
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
