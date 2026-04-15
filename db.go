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
	"time"

	"angry-gopher/flags"
	"angry-gopher/messages"
	"angry-gopher/schema"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

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

	_, err = DB.Exec(schema.Core)
	if err != nil {
		log.Fatalf("Failed to create schema: %v", err)
	}

	fmt.Printf("Database initialized at %s\n", path)
}

func seedData(includeWelcome bool) {
	users := []struct {
		id       int
		fullName string
	}{
		{1, "Steve"},
		{2, "Claude"},
	}
	now := time.Now().Unix()
	for _, u := range users {
		DB.Exec(`INSERT OR IGNORE INTO users (id, full_name, created_at) VALUES (?, ?, ?)`,
			u.id, u.fullName, now)
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

	// Steve and Claude are subscribed to all channels.
	subs := []struct {
		userID    int
		channelID int
	}{
		{1, 1}, {2, 1}, // Angry Cat
		{1, 2}, {2, 2}, // Angry Gopher
		{1, 3}, {2, 3}, // ChitChat
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
	// Users: 1=Steve, 2=Claude
	// Channels: 1=Angry Cat (private), 2=Angry Gopher (private), 3=ChitChat (public)

	send := func(senderID, channelID int, topic, markdown string) int64 {
		id, err := messages.SendMessage(senderID, channelID, topic, markdown)
		if err != nil {
			log.Printf("Failed to seed message: %v", err)
		}
		return id
	}

	steve, claude := 1, 2
	angryCat, angryGopher, chitChat := 1, 2, 3

	// --- ChitChat > welcome ---
	m1 := send(claude, chitChat, "welcome", "Welcome to Angry Gopher! All systems are go.")
	send(steve, chitChat, "welcome", "Thanks @**Claude**! Excited to be here.")

	// --- Angry Cat > design ---
	m10 := send(steve, angryCat, "design", "I think we should redesign the channel chooser.")
	m12 := send(claude, angryCat, "design", "I can help prototype some options. What about a **tree view**?")
	send(steve, angryCat, "design", "Tree view could work. Let's discuss more tomorrow.")

	// --- Angry Gopher > test messages (markdown exerciser) ---
	send(claude, angryGopher, "test messages", "## Basic formatting\n\n"+
		"Here is **bold text**, *italic text*, and ~~strikethrough~~.\n\n"+
		"A simple list:\n- First item\n- Second item\n- Third item\n\n"+
		"And some `inline code` plus two code blocks.\n\n"+
		"Fenced with triple backticks (no language):\n```\nthe quick brown fox\njumps over the lazy dog\n```\n\n"+
		"Fenced with tildes and a language tag:\n~~~ py\ndef greet(name):\n    print(f\"Hello, {name}!\")\n~~~")

	send(claude, angryGopher, "test messages", "## Valid links\n\n"+
		"Mention: @**Steve**\n\n"+
		"Channel link: #**ChitChat**\n\n"+
		"Topic link: #**ChitChat>welcome**\n\n"+
		fmt.Sprintf("Message link: #**ChitChat>welcome@%d**", m1))

	// --- Angry Gopher > dev log ---
	send(claude, angryGopher, "dev log", "Implemented message flags (read/unread, starred).")
	send(claude, angryGopher, "dev log", "Added emoji reactions support. Only unicode for now.")
	m21 := send(steve, angryGopher, "dev log", "Nice work @**Claude**! The reactions look great.")
	m25 := send(steve, angryGopher, "dev log", "Really happy with the progress.")
	send(claude, angryGopher, "dev log", "Agreed!")

	// Star a few messages for Steve.
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
