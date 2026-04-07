// Package ratelimit provides per-user rate limiting.
//
// Each user is allowed a fixed number of requests within a sliding
// time window. When the limit is exceeded, Check returns false and
// the caller should respond with 429 Too Many Requests.
package ratelimit

import (
	"sync"
	"time"
)

const (
	MaxRequests = 10
	Window      = 60 * time.Second
)

var (
	mu       sync.Mutex
	requests = map[int][]time.Time{}
)

// Check returns true if the user is within the rate limit.
// It prunes expired timestamps and records the current request.
func Check(userID int) bool {
	mu.Lock()
	defer mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-Window)

	// Prune timestamps older than the window.
	timestamps := requests[userID]
	valid := timestamps[:0]
	for _, ts := range timestamps {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}

	if len(valid) >= MaxRequests {
		requests[userID] = valid
		return false
	}

	requests[userID] = append(valid, now)
	return true
}

// Reset clears all tracked state. Used by tests.
func Reset() {
	mu.Lock()
	defer mu.Unlock()
	requests = map[int][]time.Time{}
}
