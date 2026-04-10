// Test all 6 permutations of WHERE clause ordering for
// channel + topic + sender to see if SQLite's query planner
// picks different plans.
package main

import (
	"database/sql"
	"fmt"
	"log"
	"time"

	_ "modernc.org/sqlite"
)

func main() {
	db, err := sql.Open("sqlite", "/tmp/gopher_bench.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	var totalMessages int
	db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&totalMessages)
	fmt.Printf("Database: %d messages\n", totalMessages)

	// List indexes.
	rows, _ := db.Query(`SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'`)
	for rows.Next() {
		var name string
		rows.Scan(&name)
		fmt.Printf("  Index: %s\n", name)
	}
	rows.Close()
	fmt.Println()

	// All 6 permutations of (channel, topic, sender).
	type perm struct {
		name string
		sql  string
	}

	perms := []perm{
		{
			"channel, topic, sender",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1' AND m.sender_id = 1
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"channel, sender, topic",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.channel_id = 1 AND m.sender_id = 1 AND t.topic_name = 'general topic 1'
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"topic, channel, sender",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE t.topic_name = 'general topic 1' AND m.channel_id = 1 AND m.sender_id = 1
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"topic, sender, channel",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE t.topic_name = 'general topic 1' AND m.sender_id = 1 AND m.channel_id = 1
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"sender, channel, topic",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.sender_id = 1 AND m.channel_id = 1 AND t.topic_name = 'general topic 1'
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"sender, topic, channel",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.sender_id = 1 AND t.topic_name = 'general topic 1' AND m.channel_id = 1
			 ORDER BY m.id DESC LIMIT 50`,
		},
	}

	// Also get EXPLAIN QUERY PLAN for each.
	for _, p := range perms {
		// Warm up.
		var dummy int
		db.QueryRow(p.sql).Scan(&dummy)

		// Time it (10 iterations).
		iterations := 10
		start := time.Now()
		for i := 0; i < iterations; i++ {
			db.QueryRow(p.sql).Scan(&dummy)
		}
		avg := time.Since(start) / time.Duration(iterations)

		// Get query plan.
		planRows, _ := db.Query("EXPLAIN QUERY PLAN " + p.sql)
		var plans []string
		for planRows.Next() {
			var id, parent, notused int
			var detail string
			planRows.Scan(&id, &parent, &notused, &detail)
			plans = append(plans, detail)
		}
		planRows.Close()

		fmt.Printf("%-30s %10s avg\n", p.name, avg.Truncate(time.Microsecond))
		for _, plan := range plans {
			fmt.Printf("  PLAN: %s\n", plan)
		}
		fmt.Println()
	}
}
