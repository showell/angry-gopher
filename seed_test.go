// Verifies the initial database state created by seedData().
// All other tests depend on this data being correct.

package main

import "testing"

func TestSeedDataUsers(t *testing.T) {
	resetDB()

	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count)
	if count != 4 {
		t.Errorf("expected 4 users, got %d", count)
	}

	var isAdmin int
	DB.QueryRow(`SELECT is_admin FROM users WHERE email = 'steve@example.com'`).Scan(&isAdmin)
	if isAdmin != 1 {
		t.Errorf("Steve should be admin")
	}
	DB.QueryRow(`SELECT is_admin FROM users WHERE email = 'joe@example.com'`).Scan(&isAdmin)
	if isAdmin != 0 {
		t.Errorf("Joe should not be admin")
	}
}

func TestSeedDataChannels(t *testing.T) {
	resetDB()

	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM channels`).Scan(&count)
	if count != 3 {
		t.Errorf("expected 3 channels, got %d", count)
	}

	var inviteOnly int
	DB.QueryRow(`SELECT invite_only FROM channels WHERE name = 'Angry Cat'`).Scan(&inviteOnly)
	if inviteOnly != 1 {
		t.Errorf("Angry Cat should be invite_only")
	}
	DB.QueryRow(`SELECT invite_only FROM channels WHERE name = 'ChitChat'`).Scan(&inviteOnly)
	if inviteOnly != 0 {
		t.Errorf("ChitChat should be public")
	}
}

func TestSeedDataSubscriptions(t *testing.T) {
	resetDB()

	var steveCount int
	DB.QueryRow(`SELECT COUNT(*) FROM subscriptions WHERE user_id = 1`).Scan(&steveCount)
	if steveCount != 3 {
		t.Errorf("Steve should have 3 subscriptions, got %d", steveCount)
	}

	var joeCount int
	DB.QueryRow(`SELECT COUNT(*) FROM subscriptions WHERE user_id = 4`).Scan(&joeCount)
	if joeCount != 1 {
		t.Errorf("Joe should have 1 subscription, got %d", joeCount)
	}
}
