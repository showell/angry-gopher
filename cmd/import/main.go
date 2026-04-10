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
	"sort"
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

// A parsed message ready for insertion. We buffer all messages
// during the fetch phase and sort by timestamp before inserting,
// so that auto-increment IDs increase monotonically with time.
// This preserves the "higher ID = more recent" invariant that
// Angry Cat relies on for sorting.
type parsedMessage struct {
	zulipID   int
	senderID  int // gopher ID
	channelID int // gopher ID
	topic     string
	markdown  string
	html      string
	timestamp int64
}

func importMessages(zulip *ZulipClient, db *sql.DB, batchSize int, maxBatches int) {
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

	// --- Phase 1: Fetch all messages into a buffer ---
	//
	// We fetch newest-first (Zulip's default for num_before) and
	// buffer everything. After fetching, we sort by timestamp
	// ascending so that the insert phase assigns auto-increment
	// IDs in chronological order.

	var buffer []parsedMessage
	anchor := "newest"
	totalSkipped := 0
	reachedCutoff := false

	batchCount := 0
	for !reachedCutoff {
		if maxBatches > 0 && batchCount >= maxBatches {
			log.Printf("  Reached batch limit (%d)", maxBatches)
			break
		}
		batchCount++
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

		oldestID := 0
		batchAccepted := 0

		for _, m := range messagesRaw {
			msg := m.(map[string]interface{})
			zulipMsgID := int(msg["id"].(float64))
			timestamp := int64(msg["timestamp"].(float64))
			msgType := msg["type"].(string)

			if oldestID == 0 || zulipMsgID < oldestID {
				oldestID = zulipMsgID
			}

			if timestamp < cutoffTimestamp {
				reachedCutoff = true
				continue
			}

			if msgType != "stream" {
				totalSkipped++
				continue
			}

			var alreadyDone int
			db.QueryRow(`SELECT COUNT(*) FROM zulip_message_map WHERE zulip_id = ?`, zulipMsgID).Scan(&alreadyDone)
			if alreadyDone > 0 {
				continue
			}

			senderGopherID := userMap[int(msg["sender_id"].(float64))]
			channelGopherID := channelMap[int(msg["stream_id"].(float64))]

			if senderGopherID == 0 || channelGopherID == 0 {
				totalSkipped++
				continue
			}

			markdown := msg["content"].(string)
			buffer = append(buffer, parsedMessage{
				zulipID:   zulipMsgID,
				senderID:  senderGopherID,
				channelID: channelGopherID,
				topic:     msg["subject"].(string),
				markdown:  markdown,
				html:      renderMarkdown(markdown),
				timestamp: timestamp,
			})
			batchAccepted++
		}

		log.Printf("  Batch: %d fetched, %d accepted (oldest_id=%d)",
			len(messagesRaw), batchAccepted, oldestID)

		anchor = strconv.Itoa(oldestID)
		time.Sleep(500 * time.Millisecond)
	}

	// --- Phase 2: Sort by timestamp ascending ---
	//
	// This ensures auto-increment IDs match chronological order.
	sort.Slice(buffer, func(i, j int) bool {
		return buffer[i].timestamp < buffer[j].timestamp
	})

	log.Printf("Inserting %d messages in chronological order...", len(buffer))

	// --- Phase 3: Insert in order ---
	totalImported := 0
	for _, pm := range buffer {
		tx, err := db.Begin()
		if err != nil {
			log.Printf("  TX begin error: %v", err)
			continue
		}

		var topicID int64
		err = tx.QueryRow(
			`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = ?`,
			pm.channelID, pm.topic,
		).Scan(&topicID)
		if err != nil {
			res, err := tx.Exec(
				`INSERT INTO topics (channel_id, topic_name) VALUES (?, ?)`,
				pm.channelID, pm.topic)
			if err != nil {
				tx.Rollback()
				continue
			}
			topicID, _ = res.LastInsertId()
		}

		contentRes, err := tx.Exec(
			`INSERT INTO message_content (markdown, html) VALUES (?, ?)`,
			pm.markdown, pm.html)
		if err != nil {
			tx.Rollback()
			continue
		}
		contentID, _ := contentRes.LastInsertId()

		msgRes, err := tx.Exec(
			`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
			contentID, pm.senderID, pm.channelID, topicID, pm.timestamp)
		if err != nil {
			tx.Rollback()
			continue
		}
		gopherMsgID, _ := msgRes.LastInsertId()

		tx.Exec(`INSERT INTO zulip_message_map (zulip_id, gopher_id) VALUES (?, ?)`,
			pm.zulipID, gopherMsgID)

		tx.Commit()
		totalImported++
	}

	log.Printf("Done: %d messages imported, %d skipped", totalImported, totalSkipped)
}

// --- Welcome message ---

// addWelcomeMessage inserts a single welcome message into the
// first public channel. Gives the user something to see when
// they first load Angry Cat after an import.
func addWelcomeMessage(db *sql.DB) {
	var channelID int
	var channelName string
	err := db.QueryRow(
		`SELECT channel_id, name FROM channels WHERE invite_only = 0 ORDER BY channel_id LIMIT 1`,
	).Scan(&channelID, &channelName)
	if err != nil {
		log.Println("  No public channel for welcome message")
		return
	}

	var senderID int
	db.QueryRow(`SELECT id FROM users WHERE is_admin = 1 LIMIT 1`).Scan(&senderID)
	if senderID == 0 {
		db.QueryRow(`SELECT id FROM users LIMIT 1`).Scan(&senderID)
	}

	db.Exec(`INSERT OR IGNORE INTO topics (channel_id, topic_name) VALUES (?, 'welcome')`, channelID)
	var topicID int
	db.QueryRow(`SELECT topic_id FROM topics WHERE channel_id = ? AND topic_name = 'welcome'`, channelID).Scan(&topicID)

	markdown := fmt.Sprintf("Welcome to **#%s**! The database has been freshly imported.", channelName)
	html := renderMarkdown(markdown)
	result, _ := db.Exec(`INSERT INTO message_content (markdown, html) VALUES (?, ?)`, markdown, html)
	contentID, _ := result.LastInsertId()

	now := time.Now().Unix()
	db.Exec(`INSERT INTO messages (content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?)`,
		contentID, senderID, channelID, topicID, now)

	log.Printf("Welcome message added to #%s > welcome", channelName)
}

// serverIsRunning probes the Gopher server's version endpoint.
// If it responds, the server is alive and we should NOT import
// (the running server would have a stale DB handle after we
// replace the database file).
func serverIsRunning(config *ImportConfig) bool {
	// The server URL isn't in the import config, but the DB path
	// tells us the root. For now, try localhost on common ports.
	for _, port := range []string{"9000", "9001"} {
		resp, err := http.Get("http://localhost:" + port + "/gopher/version")
		if err == nil {
			resp.Body.Close()
			log.Printf("Server detected on port %s", port)
			return true
		}
	}
	return false
}

// --- Main ---

func main() {
	configPath := flag.String("config", "", "Path to import config JSON")
	mode := flag.String("mode", "full", "Import mode: empty, tiny, full")
	flag.Parse()

	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "Usage: go run ./cmd/import -config config.json [-mode empty|tiny|full]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "Modes:")
		fmt.Fprintln(os.Stderr, "  empty  Create schema only, no data (for testing)")
		fmt.Fprintln(os.Stderr, "  tiny   Import channels + subscriptions + 2 message batches + welcome")
		fmt.Fprintln(os.Stderr, "  full   Full import from Zulip back to January + welcome (default)")
		os.Exit(1)
	}

	config, err := loadImportConfig(*configPath)
	if err != nil {
		log.Fatalf("Config error: %v", err)
	}

	// Refuse to run if the Gopher server is already listening on the
	// configured port. Importing while the server is running leads to
	// stale DB handles and confusing credential mismatches.
	if serverIsRunning(config) {
		log.Fatalf("Angry Gopher appears to be running (port responded). Stop the server before importing.")
	}

	db, err := sql.Open("sqlite", config.GopherDB)
	if err != nil {
		log.Fatalf("Cannot open DB: %v", err)
	}
	db.SetMaxOpenConns(1)
	db.Exec("PRAGMA busy_timeout = 5000")

	log.Printf("Mode:       %s", *mode)
	log.Printf("Gopher DB:  %s", config.GopherDB)

	ensureSchema(db)

	if *mode == "empty" {
		log.Println("Schema created. No data imported.")
		log.Println("=== Import complete ===")
		return
	}

	zulip := NewZulipClient(config)

	log.Printf("Zulip:      %s (as %s)", config.ZulipURL, config.ZulipEmail)
	log.Printf("Batch size: %d", config.BatchSize)

	importUsers(zulip, db)
	importChannels(zulip, db)
	importSubscriptions(db)

	maxBatches := 0
	if *mode == "tiny" {
		maxBatches = 2
	}
	importMessages(zulip, db, config.BatchSize, maxBatches)

	addWelcomeMessage(db)

	log.Println("=== Import complete ===")
}
