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

var (
	mu       sync.Mutex
	statuses = map[int]*UserPresence{}
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
	statuses[userID] = &UserPresence{
		Status:    status,
		Timestamp: time.Now(),
	}
	mu.Unlock()

	respond.Success(w, nil)
}

// HandleGetPresence handles GET /api/v1/users/me/presence.
// Returns presence for all users who have reported recently.
func HandleGetPresence(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	cutoff := time.Now().Add(-OfflineThreshold)

	result := map[string]interface{}{}
	for userID, p := range statuses {
		if p.Timestamp.After(cutoff) {
			result[fmt.Sprintf("%d", userID)] = map[string]interface{}{
				"status":    p.Status,
				"timestamp": p.Timestamp.Unix(),
			}
		}
	}

	respond.Success(w, map[string]interface{}{"presences": result})
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
}
