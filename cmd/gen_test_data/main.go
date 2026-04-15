// Command gen_test_data creates a 1M message test database with
// realistic distribution of channels, topics, senders, and timestamps.
//
// Usage:
//
//	go run ./cmd/gen_test_data -db /tmp/gopher_bench.db
//	go run ./cmd/gen_test_data -db /tmp/gopher_bench.db -messages 100000
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"time"

	"angry-gopher/schema"

	_ "modernc.org/sqlite"
)

func main() {
	dbPath := flag.String("db", "", "path for the test database (will be overwritten)")
	msgCount := flag.Int("messages", 1_000_000, "number of messages to generate")
	flag.Parse()

	if *dbPath == "" {
		log.Fatal("Usage: go run ./cmd/gen_test_data -db <path>")
	}

	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		log.Fatalf("Cannot open DB: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.Exec("PRAGMA journal_mode=WAL")
	db.Exec("PRAGMA synchronous=NORMAL")

	log.Println("Creating schema...")
	if _, err := db.Exec(schema.Core); err != nil {
		log.Fatalf("Schema error: %v", err)
	}

	// --- Users ---
	numUsers := 50
	log.Printf("Creating %d users...", numUsers)
	for i := 1; i <= numUsers; i++ {
		db.Exec(`INSERT INTO users (id, email, full_name, api_key, is_admin) VALUES (?, ?, ?, ?, ?)`,
			i,
			fmt.Sprintf("user%d@example.com", i),
			fmt.Sprintf("User %d", i),
			fmt.Sprintf("key-%d", i),
			boolToInt(i <= 3), // first 3 are admins
		)
	}

	// --- Channels ---
	// Mix of high, medium, and low traffic channels.
	type channelDef struct {
		name       string
		inviteOnly int
		weight     int // relative message volume
	}
	channels := []channelDef{
		{"general", 0, 100},
		{"engineering", 0, 80},
		{"design", 0, 50},
		{"product", 0, 40},
		{"random", 0, 70},
		{"ops", 0, 30},
		{"incidents", 0, 20},
		{"hiring", 0, 15},
		{"onboarding", 0, 10},
		{"frontend", 0, 35},
		{"backend", 0, 35},
		{"mobile", 0, 25},
		{"infrastructure", 0, 20},
		{"data-science", 0, 15},
		{"security", 0, 10},
		{"docs", 0, 10},
		{"releases", 0, 15},
		{"customer-feedback", 0, 20},
		{"sales", 0, 10},
		{"marketing", 0, 10},
		{"team-leads", 1, 15},
		{"exec-team", 1, 5},
		{"steve-apoorva", 1, 8},
		{"project-alpha", 0, 25},
		{"project-beta", 0, 20},
		{"project-gamma", 0, 15},
		{"code-review", 0, 30},
		{"testing", 0, 20},
		{"fun-stuff", 0, 25},
		{"music", 0, 5},
	}

	log.Printf("Creating %d channels...", len(channels))
	totalWeight := 0
	for i, ch := range channels {
		db.Exec(`INSERT INTO channels (channel_id, name, invite_only) VALUES (?, ?, ?)`,
			i+1, ch.name, ch.inviteOnly)
		totalWeight += ch.weight
	}

	// Subscribe all users to public channels, random subset to private.
	for i := 1; i <= numUsers; i++ {
		for j, ch := range channels {
			if ch.inviteOnly == 1 {
				if rand.Intn(5) == 0 { // 20% chance
					db.Exec(`INSERT INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, i, j+1)
				}
			} else {
				db.Exec(`INSERT INTO subscriptions (user_id, channel_id) VALUES (?, ?)`, i, j+1)
			}
		}
	}

	// --- Topic generation ---
	// Pre-generate topics per channel. High-weight channels get more topics.
	type topicInfo struct {
		channelID int
		topicID   int64
		name      string
	}
	var allTopics []topicInfo
	topicID := int64(0)

	for i, ch := range channels {
		channelID := i + 1
		numTopics := ch.weight/2 + 5 // roughly 7-55 topics per channel
		for t := 0; t < numTopics; t++ {
			topicID++
			name := fmt.Sprintf("%s topic %d", ch.name, t+1)
			db.Exec(`INSERT INTO topics (topic_id, channel_id, topic_name) VALUES (?, ?, ?)`,
				topicID, channelID, name)
			allTopics = append(allTopics, topicInfo{channelID, topicID, name})
		}
	}
	log.Printf("Created %d topics across %d channels", len(allTopics), len(channels))

	// --- Build weighted channel selection ---
	// Channels with higher weight get proportionally more messages.
	type channelWeight struct {
		channelID int
		topics    []topicInfo
	}
	var weightedChannels []channelWeight
	for i, ch := range channels {
		channelID := i + 1
		var chTopics []topicInfo
		for _, t := range allTopics {
			if t.channelID == channelID {
				chTopics = append(chTopics, t)
			}
		}
		for w := 0; w < ch.weight; w++ {
			weightedChannels = append(weightedChannels, channelWeight{channelID, chTopics})
		}
	}

	// --- User activity weights ---
	// Power law: a few users are very active, most are moderate.
	userWeights := make([]int, numUsers)
	for i := range userWeights {
		if i < 5 {
			userWeights[i] = 20 // top 5 users: very active
		} else if i < 15 {
			userWeights[i] = 10 // next 10: active
		} else if i < 35 {
			userWeights[i] = 5 // next 20: moderate
		} else {
			userWeights[i] = 1 // rest: lurkers
		}
	}
	var weightedUsers []int
	for i, w := range userWeights {
		for j := 0; j < w; j++ {
			weightedUsers = append(weightedUsers, i+1)
		}
	}

	// --- Messages ---
	log.Printf("Generating %d messages...", *msgCount)
	startTime := time.Now().Add(-180 * 24 * time.Hour) // 6 months ago
	timeRange := 180 * 24 * time.Hour

	// Use a transaction for bulk insert performance.
	batchSize := 10000
	tx, _ := db.Begin()
	for i := 0; i < *msgCount; i++ {
		if i > 0 && i%batchSize == 0 {
			tx.Commit()
			tx, _ = db.Begin()
			if i%(batchSize*10) == 0 {
				log.Printf("  %d / %d messages...", i, *msgCount)
			}
		}

		// Pick channel (weighted).
		cw := weightedChannels[rand.Intn(len(weightedChannels))]
		// Pick topic within channel (uniform — topics within a channel
		// are roughly equal, the channel weight handles volume).
		topic := cw.topics[rand.Intn(len(cw.topics))]
		// Pick sender (weighted).
		senderID := weightedUsers[rand.Intn(len(weightedUsers))]
		// Timestamp: biased toward recent (quadratic distribution).
		r := rand.Float64()
		ts := startTime.Add(time.Duration(r*r*float64(timeRange)))

		content := fmt.Sprintf("Message %d in %s", i+1, topic.name)
		html := fmt.Sprintf("<p>%s</p>", content)

		tx.Exec(`INSERT INTO message_content (content_id, markdown, html) VALUES (?, ?, ?)`,
			i+1, content, html)
		tx.Exec(`INSERT INTO messages (id, content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)`,
			i+1, i+1, senderID, topic.channelID, topic.topicID, ts.Unix())
	}
	tx.Commit()

	log.Printf("Done: %d messages in %s", *msgCount, *dbPath)

	// Quick stats.
	var count int
	db.QueryRow(`SELECT COUNT(DISTINCT channel_id) FROM messages`).Scan(&count)
	log.Printf("  Channels with messages: %d", count)
	db.QueryRow(`SELECT COUNT(DISTINCT topic_id) FROM messages`).Scan(&count)
	log.Printf("  Topics with messages: %d", count)
	db.QueryRow(`SELECT COUNT(DISTINCT sender_id) FROM messages`).Scan(&count)
	log.Printf("  Active senders: %d", count)
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
