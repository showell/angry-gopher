package ratelimit

import (
	"testing"
	"time"
)

func reset() {
	mu.Lock()
	defer mu.Unlock()
	requests = map[int][]time.Time{}
}

// injectTimestamps lets tests set up a specific request history
// for a user, so we can test window expiry without sleeping.
func injectTimestamps(userID int, timestamps []time.Time) {
	mu.Lock()
	defer mu.Unlock()
	requests[userID] = timestamps
}

func TestFirstRequestAllowed(t *testing.T) {
	reset()
	if !Check(1) {
		t.Error("first request should be allowed")
	}
}

func TestRequestsUpToLimitAllowed(t *testing.T) {
	reset()
	for i := 0; i < MaxRequests; i++ {
		if !Check(1) {
			t.Fatalf("request %d should be allowed (limit is %d)", i+1, MaxRequests)
		}
	}
}

func TestRequestOverLimitBlocked(t *testing.T) {
	reset()
	for i := 0; i < MaxRequests; i++ {
		Check(1)
	}
	if Check(1) {
		t.Error("request over the limit should be blocked")
	}
}

func TestSeparateUsersHaveIndependentLimits(t *testing.T) {
	reset()
	// Exhaust user 1's limit.
	for i := 0; i < MaxRequests; i++ {
		Check(1)
	}
	// User 2 should still be allowed.
	if !Check(2) {
		t.Error("user 2 should not be affected by user 1's limit")
	}
}

func TestExpiredTimestampsArePruned(t *testing.T) {
	reset()

	// Inject timestamps that are all outside the window.
	old := time.Now().Add(-Window - time.Second)
	timestamps := make([]time.Time, MaxRequests)
	for i := range timestamps {
		timestamps[i] = old
	}
	injectTimestamps(1, timestamps)

	// Even though there are MaxRequests entries, they're all expired.
	// The next request should be allowed.
	if !Check(1) {
		t.Error("request should be allowed after old timestamps expire")
	}
}

func TestMixOfExpiredAndCurrentTimestamps(t *testing.T) {
	reset()

	old := time.Now().Add(-Window - time.Second)
	recent := time.Now().Add(-time.Second)

	// Fill with old timestamps, then add some recent ones.
	timestamps := make([]time.Time, 0, MaxRequests)
	for i := 0; i < MaxRequests-5; i++ {
		timestamps = append(timestamps, old)
	}
	for i := 0; i < 5; i++ {
		timestamps = append(timestamps, recent)
	}
	injectTimestamps(1, timestamps)

	// After pruning, only 5 recent timestamps remain — well under
	// the limit, so the request should be allowed.
	if !Check(1) {
		t.Error("request should be allowed after expired timestamps are pruned")
	}
}

func TestBlockedWhenAllTimestampsAreRecent(t *testing.T) {
	reset()

	recent := time.Now().Add(-time.Second)
	timestamps := make([]time.Time, MaxRequests)
	for i := range timestamps {
		timestamps[i] = recent
	}
	injectTimestamps(1, timestamps)

	if Check(1) {
		t.Error("should be blocked when all timestamps are recent and at limit")
	}
}

func TestRejectedCounterIncrements(t *testing.T) {
	Reset()
	for i := 0; i < MaxRequests; i++ {
		Check(1)
	}

	// Three rejected requests.
	Check(1)
	Check(1)
	Check(1)

	rejected, _ := Stats()
	if rejected != 3 {
		t.Errorf("expected 3 rejections, got %d", rejected)
	}
}

func TestStatsReportsActiveUsers(t *testing.T) {
	Reset()
	Check(1)
	Check(1)
	Check(2)

	_, users := Stats()
	if len(users) != 2 {
		t.Fatalf("expected 2 users in stats, got %d", len(users))
	}

	counts := map[int]int{}
	for _, u := range users {
		counts[u.UserID] = u.RequestsInWindow
	}
	if counts[1] != 2 {
		t.Errorf("user 1: expected 2 requests, got %d", counts[1])
	}
	if counts[2] != 1 {
		t.Errorf("user 2: expected 1 request, got %d", counts[2])
	}
}

func TestStatsExcludesExpiredRequests(t *testing.T) {
	Reset()

	old := time.Now().Add(-Window - time.Second)
	injectTimestamps(1, []time.Time{old, old, old})

	_, users := Stats()
	if len(users) != 0 {
		t.Errorf("expected no active users after expiry, got %v", users)
	}
}

func TestResetClearsRejectedCounter(t *testing.T) {
	Reset()
	for i := 0; i < MaxRequests; i++ {
		Check(1)
	}
	Check(1) // rejected

	rejected, _ := Stats()
	if rejected != 1 {
		t.Fatalf("expected 1 rejection before reset, got %d", rejected)
	}

	Reset()

	rejected, _ = Stats()
	if rejected != 0 {
		t.Errorf("expected 0 rejections after reset, got %d", rejected)
	}
}

func TestResetClearsAllState(t *testing.T) {
	reset()
	for i := 0; i < MaxRequests; i++ {
		Check(1)
	}
	if Check(1) {
		t.Error("should be blocked before reset")
	}

	Reset()

	if !Check(1) {
		t.Error("should be allowed after reset")
	}
}
