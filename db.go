// Database setup and helpers for Angry Gopher.
// Uses SQLite via modernc.org/sqlite (pure Go, no CGO).

package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

const schema = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    api_key TEXT NOT NULL DEFAULT '',
    is_admin INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS channels (
    channel_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    rendered_description TEXT NOT NULL DEFAULT '',
    channel_weekly_traffic INTEGER NOT NULL DEFAULT 0,
    invite_only INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS subscriptions (
    user_id INTEGER NOT NULL REFERENCES users(id),
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    PRIMARY KEY (user_id, channel_id)
);

CREATE TABLE IF NOT EXISTS topics (
    topic_id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    topic_name TEXT NOT NULL,
    UNIQUE(channel_id, topic_name)
);

CREATE TABLE IF NOT EXISTS message_content (
    content_id INTEGER PRIMARY KEY AUTOINCREMENT,
    markdown TEXT NOT NULL,
    html TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id INTEGER NOT NULL REFERENCES message_content(content_id),
    sender_id INTEGER NOT NULL REFERENCES users(id),
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    topic_id INTEGER NOT NULL REFERENCES topics(topic_id),
    timestamp INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS reactions (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    emoji_name TEXT NOT NULL,
    emoji_code TEXT NOT NULL,
    PRIMARY KEY (message_id, user_id, emoji_code)
);

CREATE TABLE IF NOT EXISTS message_flags (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    flag_name TEXT NOT NULL,
    PRIMARY KEY (message_id, flag_name)
);
`

func initDB(path string) {
	var err error
	if DB != nil {
		DB.Close()
	}

	// For file-based databases, start fresh on every server restart
	// so we always get a clean slate with seeded data.
	if path != ":memory:" {
		os.Remove(path)
	}

	DB, err = sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	// Single connection: serializes all access, no lock contention,
	// no WAL/SHM files. Sufficient for our low-traffic server.
	DB.SetMaxOpenConns(1)

	_, err = DB.Exec(schema)
	if err != nil {
		log.Fatalf("Failed to create schema: %v", err)
	}

	seedData(path != ":memory:")

	fmt.Printf("Database initialized at %s\n", path)
}

func seedData(includeWelcome bool) {
	users := []struct {
		id       int
		email    string
		fullName string
		apiKey   string
		isAdmin  int
	}{
		{1, "steve@example.com", "Steve Howell", "steve-api-key", 1},
		{2, "apoorva@example.com", "Apoorva Pendse", "apoorva-api-key", 0},
		{3, "claude@example.com", "Claude", "claude-api-key", 1},
		{4, "joe@example.com", "Joe Random", "joe-api-key", 0},
	}
	for _, u := range users {
		DB.Exec(`INSERT OR IGNORE INTO users (id, email, full_name, api_key, is_admin) VALUES (?, ?, ?, ?, ?)`,
			u.id, u.email, u.fullName, u.apiKey, u.isAdmin)
	}

	channels := []struct {
		id         int
		name       string
		inviteOnly int
	}{
		{1, "Angry Cat", 1},
		{2, "Angry Gopher", 1},
		{3, "ChitChat", 0},
	}
	for _, ch := range channels {
		DB.Exec(`INSERT OR IGNORE INTO channels (channel_id, name, invite_only) VALUES (?, ?, ?)`,
			ch.id, ch.name, ch.inviteOnly)
	}

	// Steve, Apoorva, and Claude are subscribed to the private channels.
	// All four users are subscribed to ChitChat.
	subs := []struct {
		userID    int
		channelID int
	}{
		{1, 1}, {2, 1}, {3, 1}, // Angry Cat
		{1, 2}, {2, 2}, {3, 2}, // Angry Gopher
		{1, 3}, {2, 3}, {3, 3}, {4, 3}, // ChitChat
	}
	for _, s := range subs {
		DB.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`,
			s.userID, s.channelID)
	}

	if includeWelcome {
		markdown := "Welcome to Angry Gopher! All systems are go."
		DB.Exec(`INSERT OR IGNORE INTO message_content (content_id, markdown, html) VALUES (1, ?, ?)`,
			markdown, renderMarkdown(markdown))
		DB.Exec(`INSERT OR IGNORE INTO topics (topic_id, channel_id, topic_name) VALUES (1, 3, 'welcome')`)
		DB.Exec(`INSERT OR IGNORE INTO messages (id, content_id, sender_id, channel_id, topic_id, timestamp) VALUES (1, 1, 3, 3, 1, ?)`,
			1712500000,
		)
	}
}
