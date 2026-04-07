// Package presence tracks which users are online, active, or idle.
//
// Angry Cat sends POST /api/v1/users/me/presence every 60 seconds
// with status "active" or "idle". We store the latest timestamp and
// status per user in memory (not SQLite — presence is ephemeral).
//
// GET /api/v1/users/me/presence returns all users' presence so
// clients can show who is online.
package presence

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"angry-gopher/auth"
	"angry-gopher/events"
	"angry-gopher/respond"
)

// A user is considered offline if we haven't heard from them in
// 2 minutes (they send heartbeats every 60 seconds, so one missed
// heartbeat is tolerated).
const OfflineThreshold = 2 * time.Minute

type UserPresence struct {
	Status    string    // "active" or "idle"
	Timestamp time.Time // when we last heard from them
}

type PresenceEvent struct {
	UserID    int       `json:"user_id"`
	Event     string    `json:"event"` // "came_online" or "went_offline"
	Timestamp time.Time `json:"timestamp"`
}

const maxEventLog = 50

var (
	mu       sync.Mutex
	statuses = map[int]*UserPresence{}
	eventLog []PresenceEvent
)

// HandleUpdatePresence handles POST /api/v1/users/me/presence.
func HandleUpdatePresence(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	status := r.FormValue("status")
	if status != "active" && status != "idle" {
		respond.Error(w, "Invalid status: must be 'active' or 'idle'")
		return
	}

	mu.Lock()
	now := time.Now()
	prev := statuses[userID]

	// Log and broadcast "came_online" if this is a new user or they were offline.
	if prev == nil || now.Sub(prev.Timestamp) > OfflineThreshold {
		appendEvent(PresenceEvent{
			UserID:    userID,
			Event:     "came_online",
			Timestamp: now,
		})
		events.PushToAll(map[string]interface{}{
			"type":    "presence",
			"user_id": userID,
			"status":  "active",
		})
	}

	statuses[userID] = &UserPresence{
		Status:    status,
		Timestamp: now,
	}
	mu.Unlock()

	respond.Success(w, nil)
}

// HandleGetPresence handles GET /api/v1/users/me/presence.
// Returns current presence and recent events.
func HandleGetPresence(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-OfflineThreshold)

	// Check for users who went offline since last check.
	for userID, p := range statuses {
		if p.Status != "offline" && p.Timestamp.Before(cutoff) {
			appendEvent(PresenceEvent{
				UserID:    userID,
				Event:     "went_offline",
				Timestamp: p.Timestamp.Add(OfflineThreshold),
			})
			p.Status = "offline"
			events.PushToAll(map[string]interface{}{
				"type":    "presence",
				"user_id": userID,
				"status":  "offline",
			})
		}
	}

	presences := map[string]interface{}{}
	for userID, p := range statuses {
		if p.Timestamp.After(cutoff) {
			presences[fmt.Sprintf("%d", userID)] = map[string]interface{}{
				"status":    p.Status,
				"timestamp": p.Timestamp.Unix(),
			}
		}
	}

	respond.Success(w, map[string]interface{}{"presences": presences})
}

func appendEvent(e PresenceEvent) {
	eventLog = append(eventLog, e)
	if len(eventLog) > maxEventLog {
		eventLog = eventLog[len(eventLog)-maxEventLog:]
	}
}

// GetAll returns a copy of all presence entries (for the admin UI).
func GetAll() map[int]UserPresence {
	mu.Lock()
	defer mu.Unlock()
	result := make(map[int]UserPresence, len(statuses))
	for userID, p := range statuses {
		result[userID] = *p
	}
	return result
}

// Reset clears all presence state. Used by tests.
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	statuses = map[int]*UserPresence{}
	eventLog = nil
}
