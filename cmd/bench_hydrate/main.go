// Quick hydration benchmark — run manually, not part of test suite.
// go run ./cmd/bench_search/hydrate_test.go
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

	// Step 1: IDs only for channel+topic
	start := time.Now()
	rows, _ := db.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'
		ORDER BY m.id DESC`)
	var ids []int
	for rows.Next() {
		var id int
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	idsOnly := time.Since(start)
	fmt.Printf("IDs only:    %d ids in %s\n", len(ids), idsOnly)

	// Step 2: Full join (IDs + content in one query)
	start = time.Now()
	rows, _ = db.Query(`
		SELECT m.id, mc.html FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		JOIN message_content mc ON m.content_id = mc.content_id
		WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'
		ORDER BY m.id DESC`)
	count := 0
	for rows.Next() {
		var id int
		var html string
		rows.Scan(&id, &html)
		count++
	}
	rows.Close()
	fullJoin := time.Since(start)
	fmt.Printf("Full join:   %d rows in %s\n", count, fullJoin)

	// Step 3: Two-trip hydration — get IDs, then batch-fetch content
	// First get IDs (reuse from step 1)
	start = time.Now()
	rows, _ = db.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'
		ORDER BY m.id DESC`)
	ids = nil
	for rows.Next() {
		var id int
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()

	// Now hydrate in one batch using IN clause
	placeholders := make([]string, len(ids))
	args := make([]interface{}, len(ids))
	for i, id := range ids {
		placeholders[i] = "?"
		args[i] = id
	}
	query := fmt.Sprintf(`
		SELECT m.id, mc.html FROM messages m
		JOIN message_content mc ON m.content_id = mc.content_id
		WHERE m.id IN (%s)`, strings.Join(placeholders, ","))
	rows, _ = db.Query(query, args...)
	count = 0
	for rows.Next() {
		var id int
		var html string
		rows.Scan(&id, &html)
		count++
	}
	rows.Close()
	twoTrip := time.Since(start)
	fmt.Printf("Two-trip:    %d rows in %s\n", count, twoTrip)

	// Step 4: Same but with LIMIT 50 (realistic pagination)
	fmt.Println("\n--- With LIMIT 50 ---")

	start = time.Now()
	rows, _ = db.Query(`
		SELECT m.id FROM messages m
		JOIN topics t ON m.topic_id = t.topic_id
		WHERE m.channel_id = 1 AND t.topic_name = 'general topic 1'
		ORDER BY m.id DESC LIMIT 50`)
	ids = nil
	for rows.Next() {
		var id int
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	fmt.Printf("IDs (50):    %d ids in %s\n", len(ids), time.Since(start))

	start = time.Now()
	placeholders = make([]string, len(ids))
	args = make([]interface{}, len(ids))
	for i, id := range ids {
		placeholders[i] = "?"
		args[i] = id
	}
	query = fmt.Sprintf(`
		SELECT m.id, mc.html FROM messages m
		JOIN message_content mc ON m.content_id = mc.content_id
		WHERE m.id IN (%s)`, strings.Join(placeholders, ","))
	rows, _ = db.Query(query, args...)
	count = 0
	for rows.Next() {
		var id int
		var html string
		rows.Scan(&id, &html)
		count++
	}
	rows.Close()
	fmt.Printf("Hydrate 50:  %d rows in %s\n", count, time.Since(start))
}
