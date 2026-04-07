// Tests for per-user rate limiting.

package main

import (
	"testing"

	"angry-gopher/ratelimit"
)

func TestRateLimitAllowsUpToMax(t *testing.T) {
	ratelimit.Reset()

	for i := 0; i < ratelimit.MaxRequests; i++ {
		if !ratelimit.Check(1) {
			t.Fatalf("request %d should be allowed", i+1)
		}
	}
}

func TestRateLimitRejectsAfterMax(t *testing.T) {
	ratelimit.Reset()

	for i := 0; i < ratelimit.MaxRequests; i++ {
		ratelimit.Check(1)
	}

	if ratelimit.Check(1) {
		t.Errorf("request %d should be rejected", ratelimit.MaxRequests+1)
	}
}

func TestRateLimitIsPerUser(t *testing.T) {
	ratelimit.Reset()

	// Exhaust user 1's limit.
	for i := 0; i < ratelimit.MaxRequests; i++ {
		ratelimit.Check(1)
	}

	// User 2 should still be allowed.
	if !ratelimit.Check(2) {
		t.Errorf("user 2 should not be affected by user 1's rate limit")
	}
}
