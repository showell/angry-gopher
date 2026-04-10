// Benchmark OR queries: channel+topic filtered by a set of senders.
// Simulates "show me messages in this topic from my buddies."
package main

import (
	"database/sql"
	"fmt"
	"log"
	"strings"
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

	// Get a topic_id for "general topic 1" in channel 1.
	var topicID int
	db.QueryRow(`SELECT topic_id FROM topics WHERE channel_id = 1 AND topic_name = 'general topic 1'`).Scan(&topicID)
	fmt.Printf("Channel 1, topic_id %d ('general topic 1')\n\n", topicID)

	// Simulate different buddy list sizes.
	buddySizes := []int{2, 5, 10, 20}

	type approach struct {
		name string
		fn   func(*sql.DB, int, []int) (int, time.Duration)
	}

	approaches := []approach{
		{"OR chain", queryWithOR},
		{"IN clause", queryWithIN},
		{"JOIN temp", queryWithTempTable},
		{"Subquery IN", queryWithSubqueryIN},
	}

	for _, buddyCount := range buddySizes {
		// Pick buddy IDs: first N users.
		buddies := make([]int, buddyCount)
		for i := range buddies {
			buddies[i] = i + 1
		}

		fmt.Printf("=== %d buddies (users 1-%d) ===\n", buddyCount, buddyCount)

		for _, a := range approaches {
			// Warm up.
			a.fn(db, topicID, buddies)

			// Measure (5 iterations).
			totalTime := time.Duration(0)
			var count int
			for i := 0; i < 5; i++ {
				c, d := a.fn(db, topicID, buddies)
				count = c
				totalTime += d
			}
			avg := totalTime / 5
			fmt.Printf("  %-20s %5d rows  %10s avg\n", a.name, count, avg.Truncate(time.Microsecond))
		}

		// Also test LIMIT 50 with IN clause.
		count, dur := queryWithINLimit50(db, topicID, buddies)
		fmt.Printf("  %-20s %5d rows  %10s avg\n", "IN + LIMIT 50", count, dur.Truncate(time.Microsecond))

		fmt.Println()
	}

	// Compare: no sender filter vs with sender filter.
	fmt.Println("=== Baseline: no sender filter ===")
	start := time.Now()
	var count int
	db.QueryRow(`SELECT COUNT(*) FROM messages m WHERE m.channel_id = 1 AND m.topic_id = ?`, topicID).Scan(&count)
	fmt.Printf("  All senders:       %5d rows  %10s\n", count, time.Since(start).Truncate(time.Microsecond))

	start = time.Now()
	var c2 int
	db.QueryRow(`SELECT COUNT(*) FROM messages m WHERE m.channel_id = 1 AND m.topic_id = ? LIMIT 50`, topicID).Scan(&c2)
	fmt.Printf("  LIMIT 50 (no flt): %5d rows  %10s\n", c2, time.Since(start).Truncate(time.Microsecond))
}

func queryWithOR(db *sql.DB, topicID int, buddies []int) (int, time.Duration) {
	parts := make([]string, len(buddies))
	args := []interface{}{1, topicID}
	for i, id := range buddies {
		parts[i] = "m.sender_id = ?"
		args = append(args, id)
	}
	query := fmt.Sprintf(`SELECT COUNT(*) FROM messages m
		WHERE m.channel_id = ? AND m.topic_id = ? AND (%s)`,
		strings.Join(parts, " OR "))

	start := time.Now()
	var count int
	db.QueryRow(query, args...).Scan(&count)
	return count, time.Since(start)
}

func queryWithIN(db *sql.DB, topicID int, buddies []int) (int, time.Duration) {
	placeholders := make([]string, len(buddies))
	args := []interface{}{1, topicID}
	for i, id := range buddies {
		placeholders[i] = "?"
		args = append(args, id)
	}
	query := fmt.Sprintf(`SELECT COUNT(*) FROM messages m
		WHERE m.channel_id = ? AND m.topic_id = ? AND m.sender_id IN (%s)`,
		strings.Join(placeholders, ","))

	start := time.Now()
	var count int
	db.QueryRow(query, args...).Scan(&count)
	return count, time.Since(start)
}

func queryWithINLimit50(db *sql.DB, topicID int, buddies []int) (int, time.Duration) {
	placeholders := make([]string, len(buddies))
	args := []interface{}{1, topicID}
	for i, id := range buddies {
		placeholders[i] = "?"
		args = append(args, id)
	}
	query := fmt.Sprintf(`SELECT m.id FROM messages m
		WHERE m.channel_id = ? AND m.topic_id = ? AND m.sender_id IN (%s)
		ORDER BY m.id DESC LIMIT 50`,
		strings.Join(placeholders, ","))

	start := time.Now()
	rows, _ := db.Query(query, args...)
	count := 0
	for rows.Next() {
		var id int
		rows.Scan(&id)
		count++
	}
	rows.Close()
	return count, time.Since(start)
}

func queryWithTempTable(db *sql.DB, topicID int, buddies []int) (int, time.Duration) {
	start := time.Now()
	db.Exec("CREATE TEMP TABLE IF NOT EXISTS buddy_ids (id INTEGER PRIMARY KEY)")
	db.Exec("DELETE FROM buddy_ids")
	for _, id := range buddies {
		db.Exec("INSERT INTO buddy_ids VALUES (?)", id)
	}

	var count int
	db.QueryRow(`SELECT COUNT(*) FROM messages m
		WHERE m.channel_id = ? AND m.topic_id = ?
		AND m.sender_id IN (SELECT id FROM buddy_ids)`,
		1, topicID).Scan(&count)
	return count, time.Since(start)
}

func queryWithSubqueryIN(db *sql.DB, topicID int, buddies []int) (int, time.Duration) {
	// Simulate: buddies come from a real table lookup.
	// Use sender_id <= N as a proxy for "is a buddy."
	maxBuddy := buddies[len(buddies)-1]

	start := time.Now()
	var count int
	db.QueryRow(`SELECT COUNT(*) FROM messages m
		WHERE m.channel_id = ? AND m.topic_id = ?
		AND m.sender_id IN (SELECT id FROM users WHERE id <= ?)`,
		1, topicID, maxBuddy).Scan(&count)
	return count, time.Since(start)
}
