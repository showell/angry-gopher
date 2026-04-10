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

	"angry-gopher/flags"
	"angry-gopher/messages"

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

CREATE TABLE IF NOT EXISTS channel_descriptions (
    channel_id INTEGER PRIMARY KEY REFERENCES channels(channel_id),
    markdown TEXT NOT NULL DEFAULT '',
    html TEXT NOT NULL DEFAULT ''
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

CREATE TABLE IF NOT EXISTS invites (
    token TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS starred_messages (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS buddies (
    user_id INTEGER NOT NULL REFERENCES users(id),
    buddy_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (user_id, buddy_id)
);
`

func initDB(path string) {
	var err error
	if DB != nil {
		DB.Close()
	}

	// For file-based databases, start fresh on every server restart
	// so we always get a clean slate with seeded data.
	// Only delete if GOPHER_RESET_DB=1 is set — prevents accidental
	// destruction of a production database.
	if path != ":memory:" {
		if os.Getenv("GOPHER_RESET_DB") == "1" {
			os.Remove(path)
		}
	}

	DB, err = sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	// Single connection: serializes all access, no lock contention,
	// no WAL/SHM files. Sufficient for our low-traffic server.
	DB.SetMaxOpenConns(1)

	// For file-based DBs, tell SQLite to retry for up to 5 seconds
	// if the database is busy, rather than failing immediately.
	if path != ":memory:" {
		DB.Exec("PRAGMA busy_timeout = 5000")
	}

	_, err = DB.Exec(schema)
	if err != nil {
		log.Fatalf("Failed to create schema: %v", err)
	}

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
	// Users: 1=Steve, 2=Apoorva, 3=Claude, 4=Joe
	// Channels: 1=Angry Cat (private), 2=Angry Gopher (private), 3=ChitChat (public)

	send := func(senderID, channelID int, topic, markdown string) int64 {
		id, err := messages.SendMessage(senderID, channelID, topic, markdown)
		if err != nil {
			log.Printf("Failed to seed message: %v", err)
		}
		return id
	}

	steve, apoorva, claude, joe := 1, 2, 3, 4
	angryCat, angryGopher, chitChat := 1, 2, 3

	// --- ChitChat > welcome ---
	m1 := send(claude, chitChat, "welcome", "Welcome to Angry Gopher! All systems are go.")
	send(steve, chitChat, "welcome", "Thanks @**Claude**! Excited to be here.")
	send(apoorva, chitChat, "welcome", "Hello everyone!")
	send(joe, chitChat, "welcome", "Hey, Joe here. What's this place about?")
	send(steve, chitChat, "welcome", "Welcome Joe! This is our chat server.")

	// --- ChitChat > random ---
	send(apoorva, chitChat, "random", "Anyone want to grab lunch?")
	send(steve, chitChat, "random", "Sure, I'm in!")
	send(claude, chitChat, "random", "I don't eat, but have fun!")
	send(joe, chitChat, "random", "Pizza sounds good to me.")

	// --- Angry Cat > design ---
	m10 := send(steve, angryCat, "design", "I think we should redesign the channel chooser.")
	send(apoorva, angryCat, "design", "Agreed. The current one is hard to navigate with many channels.")
	m12 := send(claude, angryCat, "design", "I can help prototype some options. What about a **tree view**?")
	send(steve, angryCat, "design", "Tree view could work. Let's discuss more tomorrow.")

	// --- Angry Gopher > test messages ---
	send(claude, angryGopher, "test messages", "## Basic formatting\n\n"+
		"Here is **bold text**, *italic text*, and ~~strikethrough~~.\n\n"+
		"A simple list:\n- First item\n- Second item\n- Third item\n\n"+
		"And some `inline code` plus two code blocks.\n\n"+
		"Fenced with triple backticks (no language):\n```\nthe quick brown fox\njumps over the lazy dog\n```\n\n"+
		"Fenced with tildes and a language tag:\n~~~ py\ndef greet(name):\n    print(f\"Hello, {name}!\")\n~~~")

	send(claude, angryGopher, "test messages", "## Valid links\n\n"+
		"Mention: @**Steve Howell**\n\n"+
		"Channel link: #**ChitChat**\n\n"+
		"Topic link: #**ChitChat>welcome**\n\n"+
		fmt.Sprintf("Message link: #**ChitChat>welcome@%d**", m1))

	send(claude, angryGopher, "test messages", "## Invalid links\n\n"+
		"Unknown user: @**Nobody Special**\n\n"+
		"Unknown channel: #**NoSuchChannel**\n\n"+
		"Unknown topic: #**Angry Gopher>no such topic**")

	send(claude, angryGopher, "test messages", "## Image test\n\n"+
		"Here is a test image: [gopher.png](/user_uploads/1/gopher.png)")

	// --- Angry Gopher > dev log ---
	send(claude, angryGopher, "dev log", "Implemented message flags (read/unread, starred).")
	send(claude, angryGopher, "dev log", "Added emoji reactions support. Only unicode for now.")
	m21 := send(steve, angryGopher, "dev log", "Nice work @**Claude**! The reactions look great.")
	send(claude, angryGopher, "dev log", "Channel permissions are in place. Private channels are now enforced.")
	send(apoorva, angryGopher, "dev log", "I tested the invite system — it works perfectly.")
	send(claude, angryGopher, "dev log", "Presence tracking is live. The Buddies plugin shows who's online.")
	m25 := send(steve, angryGopher, "dev log", "Let's deploy this soon. Really happy with the progress.")
	send(claude, angryGopher, "dev log", "Agreed! I'll prepare the deployment checklist.")

	// Star 5 messages for Steve.
	for _, msgID := range []int64{m1, m10, m12, m21, m25} {
		flags.StarMessage(int(msgID), steve)
	}

	seedTestImage()
}

func seedTestImage() {
	if uploadsDir == "" {
		return // tests don't use uploads
	}
	dir := filepath.Join(uploadsDir, "1")
	os.MkdirAll(dir, 0755)

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
