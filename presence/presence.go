// Package presence tracks which users are online.
//
// Angry Cat sends POST /api/v1/users/me/presence every 60 seconds.
// We store a last_seen timestamp per user in memory. A user is
// considered online if we heard from them within the last 2 minutes.
// GET returns who is currently online.
package presence

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

const OfflineThreshold = 2 * time.Minute

var (
	mu       sync.Mutex
	lastSeen = map[int]time.Time{}
)

// HandleUpdatePresence handles POST /api/v1/users/me/presence.
func HandleUpdatePresence(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Unauthorized")
		return
	}

	mu.Lock()
	lastSeen[userID] = time.Now()
	mu.Unlock()

	respond.Success(w, nil)
}

// HandleGetPresence handles GET /api/v1/users/me/presence.
// Returns all users who have been seen within the offline threshold.
func HandleGetPresence(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	cutoff := time.Now().Add(-OfflineThreshold)

	presences := map[string]interface{}{}
	for userID, ts := range lastSeen {
		if ts.After(cutoff) {
			presences[fmt.Sprintf("%d", userID)] = map[string]interface{}{
				"status":    "active",
				"timestamp": ts.Unix(),
			}
		}
	}

	respond.Success(w, map[string]interface{}{"presences": presences})
}

// GetAll returns all last_seen entries (for the admin UI).
func GetAll() map[int]time.Time {
	mu.Lock()
	defer mu.Unlock()
	result := make(map[int]time.Time, len(lastSeen))
	for userID, ts := range lastSeen {
		result[userID] = ts
	}
	return result
}

// Reset clears all presence state. Used by tests.
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	lastSeen = map[int]time.Time{}
}
