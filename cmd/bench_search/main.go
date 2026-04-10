// Command bench_search runs search queries against a test database
// and reports timing. Use with gen_test_data to benchmark indexing.
//
// Usage:
//
//	go run ./cmd/bench_search -db /tmp/gopher_bench.db
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"time"

	_ "modernc.org/sqlite"
)

func main() {
	dbPath := flag.String("db", "", "path to test database")
	flag.Parse()

	if *dbPath == "" {
		log.Fatal("Usage: go run ./cmd/bench_search -db <path>")
	}

	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		log.Fatalf("Cannot open DB: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	var totalMessages int
	db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&totalMessages)
	fmt.Printf("Database: %s (%d messages)\n\n", *dbPath, totalMessages)

	// Check which indexes exist.
	rows, _ := db.Query(`SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'`)
	var indexes []string
	for rows.Next() {
		var name string
		rows.Scan(&name)
		indexes = append(indexes, name)
	}
	rows.Close()
	if len(indexes) == 0 {
		fmt.Println("Indexes: none")
	} else {
		fmt.Printf("Indexes: %v\n", indexes)
	}
	fmt.Println()

	type query struct {
		name string
		sql  string
	}

	queries := []query{
		{
			"Channel filter (general)",
			`SELECT COUNT(*) FROM messages WHERE channel_id = 1`,
		},
		{
			"Channel + topic",
			`SELECT COUNT(*) FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'`,
		},
		{
			"Sender filter",
			`SELECT COUNT(*) FROM messages WHERE sender_id = 1`,
		},
		{
			"Channel + sender",
			`SELECT COUNT(*) FROM messages WHERE channel_id = 1 AND sender_id = 1`,
		},
		{
			"Recent 50 in channel (pagination)",
			`SELECT m.id FROM messages m
			 WHERE m.channel_id = 1
			 ORDER BY m.id DESC LIMIT 50`,
		},
		{
			"Recent 50 in channel+topic",
			`SELECT m.id FROM messages m
			 JOIN topics t ON m.topic_id = t.topic_id
			 WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'
			 ORDER BY m.id DESC LIMIT 50`,
		},
	}

	for _, q := range queries {
		// Run twice — first to warm, second to measure.
		var count int
		db.QueryRow(q.sql).Scan(&count)

		start := time.Now()
		iterations := 10
		for i := 0; i < iterations; i++ {
			db.QueryRow(q.sql).Scan(&count)
		}
		elapsed := time.Since(start)
		avg := elapsed / time.Duration(iterations)

		fmt.Printf("%-40s %6d rows  %8s avg\n", q.name, count, avg.Truncate(time.Microsecond))
	}
}
