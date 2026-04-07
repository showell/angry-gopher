// Verifies the initial database state created by seedData().
// Since seed data now uses messages.SendMessage and flags.StarMessage,
// these tests also exercise those code paths.

package main

import (
	"strings"
	"testing"
)

// resetDBWithMessages creates a fresh DB with the full seed data
// including test messages, stars, etc.
func resetDBWithMessages() {
	resetDB()
	seedData(true)
}

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

func TestSeedDataMessages(t *testing.T) {
	resetDBWithMessages()

	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&count)
	if count != 25 {
		t.Errorf("expected 25 messages, got %d", count)
	}
}

func TestSeedDataTopicsCreated(t *testing.T) {
	resetDBWithMessages()

	// SendMessage auto-creates topics, so verify they exist.
	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM topics`).Scan(&count)
	if count != 5 {
		t.Errorf("expected 5 topics, got %d", count)
	}

	// Spot-check a topic name.
	var name string
	DB.QueryRow(`SELECT topic_name FROM topics WHERE channel_id = 3 AND topic_name = 'welcome'`).Scan(&name)
	if name != "welcome" {
		t.Errorf("expected 'welcome' topic in ChitChat")
	}
}

func TestSeedDataContentRendered(t *testing.T) {
	resetDBWithMessages()

	// Every message should have a message_content row with both
	// markdown and html populated.
	var emptyHTML int
	DB.QueryRow(`SELECT COUNT(*) FROM message_content WHERE html = ''`).Scan(&emptyHTML)
	if emptyHTML > 0 {
		t.Errorf("expected all content to have rendered HTML, found %d empty", emptyHTML)
	}

	// The basic formatting message should have been rendered.
	var html string
	DB.QueryRow(`SELECT mc.html FROM message_content mc
		JOIN messages m ON m.content_id = mc.content_id
		WHERE mc.markdown LIKE '%bold text%'`).Scan(&html)
	if !strings.Contains(html, "<strong>bold text</strong>") {
		t.Errorf("expected rendered bold, got %q", html)
	}
}

func TestSeedDataStarredMessages(t *testing.T) {
	resetDBWithMessages()

	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM starred_messages WHERE user_id = 1`).Scan(&count)
	if count != 5 {
		t.Errorf("expected 5 starred messages for Steve, got %d", count)
	}
}

func TestSeedDataMessageDistribution(t *testing.T) {
	resetDBWithMessages()

	// Verify messages are spread across channels.
	type channelCount struct {
		channelID int
		expected  int
	}
	checks := []channelCount{
		{1, 4},  // Angry Cat > design
		{2, 12}, // Angry Gopher > test messages + dev log
		{3, 9},  // ChitChat > welcome + random
	}
	for _, cc := range checks {
		var count int
		DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = ?`, cc.channelID).Scan(&count)
		if count != cc.expected {
			t.Errorf("channel %d: expected %d messages, got %d", cc.channelID, cc.expected, count)
		}
	}
}
