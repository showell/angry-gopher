// Import tool — fetches data from a Zulip server (Le Big Mac) and
// populates an Angry Gopher production database (Le Big Gopher).
//
// Usage:
//   go run ./cmd/import -config import_config.json
//
// Creates the Gopher schema if needed, so the server doesn't have
// to run first. Safe to rerun — mapping tables track progress.

package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	goldhtml "github.com/yuin/goldmark/renderer/html"

	"bytes"

	_ "modernc.org/sqlite"
)

var md = goldmark.New(
	goldmark.WithRendererOptions(goldhtml.WithUnsafe()),
	goldmark.WithExtensions(extension.GFM),
)

func renderMarkdown(source string) string {
	var buf bytes.Buffer
	if err := md.Convert([]byte(source), &buf); err != nil {
		return "<p>" + source + "</p>"
	}
	return buf.String()
}

// --- Config ---

type ImportConfig struct {
	ZulipURL    string `json:"zulip_url"`
	ZulipEmail  string `json:"zulip_email"`
	ZulipAPIKey string `json:"zulip_api_key"`
	GopherDB    string `json:"gopher_db"`
	BatchSize   int    `json:"batch_size"`
}

func loadImportConfig(path string) (*ImportConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c ImportConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	if c.ZulipURL == "" || c.ZulipEmail == "" || c.ZulipAPIKey == "" || c.GopherDB == "" {
		return nil, fmt.Errorf("required: zulip_url, zulip_email, zulip_api_key, gopher_db")
	}
	if c.BatchSize == 0 {
		c.BatchSize = 10
	}
	return &c, nil
}

// --- Zulip API client ---

type ZulipClient struct {
	baseURL    string
	authHeader string
}

func NewZulipClient(config *ImportConfig) *ZulipClient {
	auth := base64.StdEncoding.EncodeToString(
		[]byte(config.ZulipEmail + ":" + config.ZulipAPIKey))
	return &ZulipClient{
		baseURL:    config.ZulipURL,
		authHeader: "Basic " + auth,
	}
}

func (z *ZulipClient) get(path string, params url.Values) (map[string]interface{}, error) {
	u := z.baseURL + "/api/v1/" + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}

	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("Authorization", z.authHeader)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 429 {
		retryAfter := resp.Header.Get("Retry-After")
		wait := 2.0
		if retryAfter != "" {
			fmt.Sscanf(retryAfter, "%f", &wait)
		}
		log.Printf("  Rate limited, waiting %.0fs...", wait)
		time.Sleep(time.Duration(wait) * time.Second)
		return z.get(path, params)
	}

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	json.Unmarshal(body, &result)

	if result["result"] != "success" {
		return nil, fmt.Errorf("Zulip API error: %v", result["msg"])
	}
	return result, nil
}

// --- Helpers ---

func generateAPIKey() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

var targetHumans = map[string]bool{
	"showell30@yahoo.com":      true,
	"apoorvavpendse@gmail.com": true,
}

var targetByName = map[string]bool{
	"Debbie Benton": true,
}

// --- Schema ---

const gopherSchema = `
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
CREATE TABLE IF NOT EXISTS invites (
    token TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
`

const importSchema = `
CREATE TABLE IF NOT EXISTS zulip_users (
    zulip_id INTEGER PRIMARY KEY,
    gopher_id INTEGER,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    is_bot INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS staged_bots (
    zulip_id INTEGER PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    owner_email TEXT
);
CREATE TABLE IF NOT EXISTS zulip_message_map (
    zulip_id INTEGER PRIMARY KEY,
    gopher_id INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS zulip_channels (
    zulip_id INTEGER PRIMARY KEY,
    gopher_id INTEGER,
    name TEXT NOT NULL
);
`

func ensureSchema(db *sql.DB) {
	if _, err := db.Exec(gopherSchema); err != nil {
		log.Fatalf("Failed to create Gopher schema: %v", err)
	}
	if _, err := db.Exec(importSchema); err != nil {
		log.Fatalf("Failed to create import schema: %v", err)
	}
}

// --- Stage 1: Users ---

func importUsers(zulip *ZulipClient, db *sql.DB) {
	log.Println("=== Stage 1: Users ===")

	result, err := zulip.get("users", nil)
	if err != nil {
		log.Fatalf("Failed to fetch users: %v", err)
	}

	members := result["members"].([]interface{})
	log.Printf("Zulip has %d users total", len(members))

	humanCount := 0
	botCount := 0

	for _, m := range members {
		user := m.(map[string]interface{})
		email := user["email"].(string)
		fullName := user["full_name"].(string)
		zulipID := int(user["user_id"].(float64))
		isBot := user["is_bot"].(bool)

		if isBot {
			// Zulip bot fields: bot_type (int), bot_owner_id (int).
			// bot_owner (string email) may or may not be present.
			ownerID := 0
			if v, ok := user["bot_owner_id"]; ok && v != nil {
				ownerID = int(v.(float64))
			}

			// Check if the bot's owner is one of our target humans
			// by looking up the owner's zulip_id in our mapping.
			var ownerEmail string
			db.QueryRow(`SELECT email FROM zulip_users WHERE zulip_id = ?`, ownerID).Scan(&ownerEmail)
			isOurs := targetHumans[ownerEmail]

			if isOurs {
				botType := 0
				if v, ok := user["bot_type"]; ok && v != nil {
					botType = int(v.(float64))
				}
				db.Exec(`INSERT OR IGNORE INTO staged_bots (zulip_id, email, full_name, owner_email) VALUES (?, ?, ?, ?)`,
					zulipID, email, fullName, ownerEmail)
				db.Exec(`INSERT OR REPLACE INTO zulip_users (zulip_id, email, full_name, is_bot) VALUES (?, ?, ?, 1)`,
					zulipID, email, fullName)
				botCount++
				log.Printf("  Staged bot: %s (type=%d, owner_id=%d → %s)", fullName, botType, ownerID, ownerEmail)
			}
			continue
		}

		if !targetHumans[email] && !targetByName[fullName] {
			continue
		}

		var existing int
		db.QueryRow(`SELECT COUNT(*) FROM zulip_users WHERE zulip_id = ?`, zulipID).Scan(&existing)
		if existing > 0 {
			log.Printf("  Already imported: %s (%s)", fullName, email)
			continue
		}

		isAdmin := false
		if v, ok := user["is_admin"]; ok {
			isAdmin = v.(bool)
		}
		isAdminInt := 0
		if isAdmin {
			isAdminInt = 1
		}

		apiKey := generateAPIKey()

		insertResult, err := db.Exec(
			`INSERT INTO users (email, full_name, api_key, is_admin) VALUES (?, ?, ?, ?)`,
			email, fullName, apiKey, isAdminInt)
		if err != nil {
			log.Printf("  Failed to insert user %s: %v", email, err)
			continue
		}
		gopherID, _ := insertResult.LastInsertId()

		db.Exec(`INSERT INTO zulip_users (zulip_id, gopher_id, email, full_name, is_bot) VALUES (?, ?, ?, ?, 0)`,
			zulipID, gopherID, email, fullName)

		log.Printf("  Imported: %s (%s) → gopher_id=%d", fullName, email, gopherID)
		humanCount++
	}

	log.Printf("Done: %d humans imported, %d bots staged", humanCount, botCount)
}

// --- Stage 2: Channels and subscriptions ---

// Debbie only gets subscribed to these channels (by Zulip name).
var debbieChannels = map[string]bool{
	"Debbie/Steve":          true,
	"Howell/Miller Family":  true,
}

func importChannels(zulip *ZulipClient, db *sql.DB) {
	log.Println("=== Stage 2: Channels ===")

	result, err := zulip.get("users/me/subscriptions", nil)
	if err != nil {
		log.Fatalf("Failed to fetch subscriptions: %v", err)
	}

	subs := result["subscriptions"].([]interface{})
	log.Printf("Steve has %d subscriptions on Zulip", len(subs))

	channelCount := 0

	for _, s := range subs {
		sub := s.(map[string]interface{})
		name := sub["name"].(string)
		zulipID := int(sub["stream_id"].(float64))
		description := ""
		if v, ok := sub["description"]; ok && v != nil {
			description = v.(string)
		}
		inviteOnly := false
		if v, ok := sub["invite_only"]; ok {
			inviteOnly = v.(bool)
		}

		// Idempotent: skip if already mapped.
		var existing int
		db.QueryRow(`SELECT COUNT(*) FROM zulip_channels WHERE zulip_id = ?`, zulipID).Scan(&existing)
		if existing > 0 {
			continue
		}

		inviteOnlyInt := 0
		if inviteOnly {
			inviteOnlyInt = 1
		}

		insertResult, err := db.Exec(
			`INSERT INTO channels (name, invite_only) VALUES (?, ?)`,
			name, inviteOnlyInt)
		if err != nil {
			log.Printf("  Failed to insert channel %s: %v", name, err)
			continue
		}
		gopherID, _ := insertResult.LastInsertId()

		if description != "" {
			renderedDescription := renderMarkdown(description)
			db.Exec(
				`INSERT INTO channel_descriptions (channel_id, markdown, html) VALUES (?, ?, ?)`,
				gopherID, description, renderedDescription)
		}

		db.Exec(`INSERT INTO zulip_channels (zulip_id, gopher_id, name) VALUES (?, ?, ?)`,
			zulipID, gopherID, name)

		log.Printf("  Imported channel: %s (zulip=%d → gopher=%d, private=%v)",
			name, zulipID, gopherID, inviteOnly)
		channelCount++
	}

	log.Printf("Done: %d channels imported", channelCount)
}

func importSubscriptions(db *sql.DB) {
	log.Println("=== Stage 2b: Subscriptions ===")

	// Look up Gopher user IDs.
	var steveID, apoorvaID, debbieID int
	db.QueryRow(`SELECT gopher_id FROM zulip_users WHERE email = 'showell30@yahoo.com'`).Scan(&steveID)
	db.QueryRow(`SELECT gopher_id FROM zulip_users WHERE email = 'apoorvavpendse@gmail.com'`).Scan(&apoorvaID)
	db.QueryRow(`SELECT gopher_id FROM zulip_users WHERE full_name = 'Debbie Benton'`).Scan(&debbieID)

	if steveID == 0 || apoorvaID == 0 || debbieID == 0 {
		log.Fatalf("Missing user IDs: steve=%d apoorva=%d debbie=%d", steveID, apoorvaID, debbieID)
	}

	rows, err := db.Query(`SELECT gopher_id, name FROM zulip_channels`)
	if err != nil {
		log.Fatalf("Failed to query channels: %v", err)
	}

	type ch struct {
		gopherID int
		name     string
	}
	var channels []ch
	for rows.Next() {
		var c ch
		rows.Scan(&c.gopherID, &c.name)
		channels = append(channels, c)
	}
	rows.Close()

	subCount := 0
	for _, c := range channels {
		// Steve and Apoorva get subscribed to everything.
		db.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, steveID, c.gopherID)
		db.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, apoorvaID, c.gopherID)
		subCount += 2

		// Debbie only gets her two channels.
		if debbieChannels[c.name] {
			db.Exec(`INSERT OR IGNORE INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, debbieID, c.gopherID)
			subCount++
			log.Printf("  Debbie subscribed to: %s", c.name)
		}
	}

	log.Printf("Done: %d subscriptions created", subCount)
}

// --- Stage 3: Messages ---

// cutoffTimestamp is 2026-01-01 00:00:00 UTC. We skip older messages.
var cutoffTimestamp = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).Unix()

func importMessages(zulip *ZulipClient, db *sql.DB, batchSize int) {
	log.Println("=== Stage 3: Messages ===")

	// Build lookup maps from our import tables.
	userMap := make(map[int]int)    // zulip_id → gopher_id
	rows, _ := db.Query(`SELECT zulip_id, gopher_id FROM zulip_users WHERE gopher_id IS NOT NULL`)
	for rows.Next() {
		var zID, gID int
		rows.Scan(&zID, &gID)
		userMap[zID] = gID
	}
	rows.Close()

	channelMap := make(map[int]int) // zulip_id → gopher_id
	rows, _ = db.Query(`SELECT zulip_id, gopher_id FROM zulip_channels`)
	for rows.Next() {
		var zID, gID int
		rows.Scan(&zID, &gID)
		channelMap[zID] = gID
	}
	rows.Close()

	log.Printf("User map: %d entries, Channel map: %d entries", len(userMap), len(channelMap))

	anchor := "newest"
	totalImported := 0
	totalSkipped := 0
	reachedCutoff := false

	for !reachedCutoff {
		params := url.Values{
			"anchor":         {anchor},
			"num_before":     {strconv.Itoa(batchSize)},
			"narrow":         {"[]"},
			"apply_markdown": {"false"},
		}

		result, err := zulip.get("messages", params)
		if err != nil {
			log.Fatalf("Failed to fetch messages: %v", err)
		}

		messagesRaw := result["messages"].([]interface{})
		if len(messagesRaw) == 0 {
			log.Println("  No more messages.")
			break
		}

		// Messages come newest-first when using num_before.
		// Find the oldest in this batch to set the next anchor.
		oldestID := 0
		batchImported := 0

		for _, m := range messagesRaw {
			msg := m.(map[string]interface{})
			zulipMsgID := int(msg["id"].(float64))
			timestamp := int64(msg["timestamp"].(float64))
			msgType := msg["type"].(string)

			// Track oldest for pagination.
			if oldestID == 0 || zulipMsgID < oldestID {
				oldestID = zulipMsgID
			}

			// Stop at 2026 cutoff.
			if timestamp < cutoffTimestamp {
				reachedCutoff = true
				continue
			}

			// Only import stream messages (not DMs).
			if msgType != "stream" {
				totalSkipped++
				continue
			}

			// Already imported?
			var alreadyDone int
			db.QueryRow(`SELECT COUNT(*) FROM zulip_message_map WHERE zulip_id = ?`, zulipMsgID).Scan(&alreadyDone)
			if alreadyDone > 0 {
				continue
			}

			senderZulipID := int(msg["sender_id"].(float64))
			streamZulipID := int(msg["stream_id"].(float64))
			topic := msg["subject"].(string)
			markdown := msg["content"].(string)

			// Map sender and channel to Gopher IDs.
			senderGopherID := userMap[senderZulipID]
			channelGopherID := channelMap[streamZulipID]

			if senderGopherID == 0 {
				// Message from a user we didn't import (not one of our targets).
				// Skip — we only care about messages from our users.
				totalSkipped++
				continue
			}
			if channelGopherID == 0 {
				totalSkipped++
				continue
			}

			// Render markdown to HTML via goldmark.
			html := renderMarkdown(markdown)

			// Insert using a transaction.
			tx, err := db.Begin()
			if err != nil {
				log.Printf("  TX begin error: %v", err)
				continue
			}

			// Find or create topic.
			var topicID int64
			err = tx.QueryRow(
				`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
				channelGopherID, topic,
			).Scan(&topicID)
			if err != nil {
				res, err := tx.Exec(
					`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
					channelGopherID, topic)
				if err != nil {
					tx.Rollback()
					log.Printf("  Topic insert error: %v", err)
					continue
				}
				topicID, _ = res.LastInsertId()
			}

			// Insert content.
			contentRes, err := tx.Exec(
				`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
				markdown, html)
			if err != nil {
				tx.Rollback()
				log.Printf("  Content insert error: %v", err)
				continue
			}
			contentID, _ := contentRes.LastInsertId()

			// Insert message.
			msgRes, err := tx.Exec(
				`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
				contentID, senderGopherID, channelGopherID, topicID, timestamp)
			if err != nil {
				tx.Rollback()
				log.Printf("  Message insert error: %v", err)
				continue
			}
			gopherMsgID, _ := msgRes.LastInsertId()

			// Record mapping.
			tx.Exec(`INSERT INTO zulip_message_map (zulip_id, gopher_id) VALUES (?, ?)`,
				zulipMsgID, gopherMsgID)

			tx.Commit()
			batchImported++
			totalImported++
		}

		log.Printf("  Batch: %d messages fetched, %d imported (oldest_id=%d)",
			len(messagesRaw), batchImported, oldestID)

		// Set anchor for next batch — fetch messages before the oldest.
		anchor = strconv.Itoa(oldestID)

		// Pause between batches to be respectful.
		time.Sleep(500 * time.Millisecond)
	}

	log.Printf("Done: %d messages imported, %d skipped", totalImported, totalSkipped)
}

// --- Main ---

func main() {
	configPath := flag.String("config", "", "Path to import config JSON")
	flag.Parse()

	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "Usage: go run ./cmd/import -config import_config.json")
		os.Exit(1)
	}

	config, err := loadImportConfig(*configPath)
	if err != nil {
		log.Fatalf("Config error: %v", err)
	}

	zulip := NewZulipClient(config)

	db, err := sql.Open("sqlite", config.GopherDB)
	if err != nil {
		log.Fatalf("Cannot open DB: %v", err)
	}
	db.SetMaxOpenConns(1)
	db.Exec("PRAGMA busy_timeout = 5000")

	log.Printf("Zulip:      %s (as %s)", config.ZulipURL, config.ZulipEmail)
	log.Printf("Gopher DB:  %s", config.GopherDB)
	log.Printf("Batch size: %d", config.BatchSize)

	ensureSchema(db)
	importUsers(zulip, db)
	importChannels(zulip, db)
	importSubscriptions(db)
	importMessages(zulip, db, config.BatchSize)

	log.Println("=== Import complete ===")
}
