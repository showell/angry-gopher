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
	"time"

	_ "modernc.org/sqlite"
)

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
			ownerEmail := ""
			if v, ok := user["bot_owner"]; ok && v != nil {
				ownerEmail = v.(string)
			}
			if targetHumans[ownerEmail] {
				db.Exec(`INSERT OR IGNORE INTO staged_bots (zulip_id, email, full_name, owner_email) VALUES (?, ?, ?, ?)`,
					zulipID, email, fullName, ownerEmail)
				db.Exec(`INSERT OR REPLACE INTO zulip_users (zulip_id, email, full_name, is_bot) VALUES (?, ?, ?, 1)`,
					zulipID, email, fullName)
				botCount++
				log.Printf("  Staged bot: %s (owner: %s)", fullName, ownerEmail)
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

	log.Println("=== Stage 1 complete ===")
}
