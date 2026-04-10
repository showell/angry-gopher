package presence

import (
	"testing"
	"time"
)

func reset() {
	mu.Lock()
	defer mu.Unlock()
	lastSeen = map[int]time.Time{}
}

// setLastSeen lets tests inject a specific timestamp for a user,
// so we can test the offline threshold without sleeping.
func setLastSeen(userID int, t time.Time) {
	mu.Lock()
	defer mu.Unlock()
	lastSeen[userID] = t
}

func TestRecentUserIsOnline(t *testing.T) {
	reset()
	setLastSeen(1, time.Now())

	online := OnlineUserIDs()
	if !contains(online, 1) {
		t.Errorf("user 1 should be online, got %v", online)
	}
}

func TestStaleUserIsOffline(t *testing.T) {
	reset()
	// Last seen 3 minutes ago — past the 2-minute threshold.
	setLastSeen(1, time.Now().Add(-3*time.Minute))

	online := OnlineUserIDs()
	if contains(online, 1) {
		t.Errorf("user 1 should be offline after 3 minutes, got %v", online)
	}
}

func TestUserAtExactThresholdIsOffline(t *testing.T) {
	reset()
	// Exactly at the threshold boundary (plus a tiny margin) should
	// be offline — the check is strictly "after cutoff."
	setLastSeen(1, time.Now().Add(-OfflineThreshold-time.Millisecond))

	online := OnlineUserIDs()
	if contains(online, 1) {
		t.Errorf("user at threshold boundary should be offline, got %v", online)
	}
}

func TestUserJustInsideThresholdIsOnline(t *testing.T) {
	reset()
	// One second inside the threshold — should still be online.
	setLastSeen(1, time.Now().Add(-OfflineThreshold+time.Second))

	online := OnlineUserIDs()
	if !contains(online, 1) {
		t.Errorf("user just inside threshold should be online, got %v", online)
	}
}

func TestMultipleUsersOnlineAndOffline(t *testing.T) {
	reset()
	setLastSeen(1, time.Now())                          // online
	setLastSeen(2, time.Now().Add(-5*time.Minute))       // offline
	setLastSeen(3, time.Now().Add(-30*time.Second))      // online

	online := OnlineUserIDs()
	if !contains(online, 1) {
		t.Errorf("user 1 should be online")
	}
	if contains(online, 2) {
		t.Errorf("user 2 should be offline")
	}
	if !contains(online, 3) {
		t.Errorf("user 3 should be online")
	}
}

func TestGetAllReturnsAllEntries(t *testing.T) {
	reset()
	now := time.Now()
	old := now.Add(-10 * time.Minute)
	setLastSeen(1, now)
	setLastSeen(2, old)

	all := GetAll()
	if len(all) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(all))
	}
	if !all[1].Equal(now) {
		t.Errorf("user 1 timestamp mismatch")
	}
	if !all[2].Equal(old) {
		t.Errorf("user 2 timestamp mismatch")
	}
}

func TestResetClearsAllState(t *testing.T) {
	reset()
	setLastSeen(1, time.Now())
	setLastSeen(2, time.Now())

	Reset()

	all := GetAll()
	if len(all) != 0 {
		t.Errorf("expected empty after reset, got %v", all)
	}
}

// --- helpers ---

func contains(ids []int, target int) bool {
	for _, id := range ids {
		if id == target {
			return true
		}
	}
	return false
}
