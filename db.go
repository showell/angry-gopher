// Database setup and helpers for Angry Gopher.
// Uses SQLite via modernc.org/sqlite (pure Go, no CGO).

package main

import (
	"database/sql"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"strings"

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

CREATE TABLE IF NOT EXISTS unreads (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS starred_messages (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (message_id, user_id)
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
		seedTestMessages()
	}
}

func seedTestMessages() {
	// Create test topics.
	DB.Exec(`INSERT INTO topics (topic_id, channel_id, topic_name) VALUES (1, 2, 'test messages')`)
	DB.Exec(`INSERT INTO topics (topic_id, channel_id, topic_name) VALUES (2, 3, 'welcome')`)

	// Welcome message in ChitChat.
	seedOneMessage(1, 3, 2, 3, 1712500000, "Welcome to Angry Gopher! All systems are go.")

	// Test messages in Angry Gopher > test messages, sent by Claude (user 3).
	seedOneMessage(2, 3, 2, 1, 1712500060, strings.Join([]string{
		"## Basic formatting",
		"",
		"Here is **bold text**, *italic text*, and ~~strikethrough~~.",
		"",
		"A simple list:",
		"- First item",
		"- Second item",
		"- Third item",
		"",
		"And some `inline code` plus two code blocks.",
		"",
		"Fenced with triple backticks (no language):",
		"```",
		"the quick brown fox",
		"jumps over the lazy dog",
		"```",
		"",
		"Fenced with tildes and a language tag:",
		"~~~ py",
		"def greet(name):",
		`    print(f"Hello, {name}!")`,
		"~~~",
	}, "\n"))

	seedOneMessage(3, 3, 2, 1, 1712500120, strings.Join([]string{
		"## Valid links",
		"",
		"Mention: @**Steve Howell**",
		"",
		"Channel link: #**ChitChat**",
		"",
		"Topic link: #**ChitChat>welcome**",
		"",
		"Message link: #**ChitChat>welcome@1**",
	}, "\n"))

	seedOneMessage(4, 3, 2, 1, 1712500180, strings.Join([]string{
		"## Invalid links",
		"",
		"Unknown user: @**Nobody Special**",
		"",
		"Unknown channel: #**NoSuchChannel**",
		"",
		"Unknown topic: #**Angry Gopher>no such topic**",
	}, "\n"))

	seedOneMessage(5, 3, 2, 1, 1712500240, strings.Join([]string{
		"## Image test",
		"",
		"Here is a test image: [gopher.png](/user_uploads/1/gopher.png)",
	}, "\n"))

	// Create the test image on disk.
	seedTestImage()
}

// seedTestImage creates a small PNG in ~/AngryGopherImages/1/gopher.png
// so the image test message has something to display.
func seedTestImage() {
	dir := filepath.Join(os.Getenv("HOME"), "AngryGopherImages", "1")
	os.MkdirAll(dir, 0755)

	// Create a simple 64x64 teal square.
	img := image.NewRGBA(image.Rect(0, 0, 64, 64))
	teal := color.RGBA{0, 128, 128, 255}
	for y := 0; y < 64; y++ {
		for x := 0; x < 64; x++ {
			img.Set(x, y, teal)
		}
	}

	f, err := os.Create(filepath.Join(dir, "gopher.png"))
	if err != nil {
		log.Printf("Failed to create test image: %v", err)
		return
	}
	defer f.Close()
	png.Encode(f, img)
}

func seedOneMessage(msgID, senderID, channelID, topicID int, timestamp int64, markdown string) {
	html := renderMarkdown(markdown)
	DB.Exec(`INSERT INTO message_content (content_id, markdown, html) VALUES (?, ?, ?)`,
		msgID, markdown, html)
	DB.Exec(`INSERT INTO messages (id, content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)`,
		msgID, msgID, senderID, channelID, topicID, timestamp)
}
