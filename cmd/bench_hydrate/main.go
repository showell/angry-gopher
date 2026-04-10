// Hydration benchmarks — tests the two-trip pattern and IN clause limits.
//
// Usage:
//   go run ./cmd/bench_hydrate
//   go run ./cmd/bench_hydrate -limit-test
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const dbPath = "/tmp/gopher_bench.db"

func main() {
	limitTest := flag.Bool("limit-test", false, "test IN clause with increasing sizes up to 1M")
	flag.Parse()

	if *limitTest {
		runLimitTest()
	} else {
		runHydrationBench()
	}
}

func openDB() *sql.DB {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	return db
}

func runLimitTest() {
	db := openDB()
	defer db.Close()

	rows, _ := db.Query(`SELECT id FROM messages ORDER BY id LIMIT 1000000`)
	var allIDs []int
	for rows.Next() {
		var id int
		rows.Scan(&id)
		allIDs = append(allIDs, id)
	}
	rows.Close()
	fmt.Printf("Loaded %d message IDs\n\n", len(allIDs))

	sizes := []int{100, 500, 1000, 5000, 10000, 50000, 100000, 250000, 500000, 1000000}

	for _, n := range sizes {
		if n > len(allIDs) {
			break
		}
		ids := allIDs[:n]

		placeholders := make([]string, n)
		args := make([]interface{}, n)
		for i, id := range ids {
			placeholders[i] = "?"
			args[i] = id
		}
		query := fmt.Sprintf(
			`SELECT m.id, mc.html FROM messages m
			 JOIN message_content mc ON m.content_id = mc.content_id
			 WHERE m.id IN (%s)`,
			strings.Join(placeholders, ","))

		start := time.Now()
		rows, err := db.Query(query, args...)
		if err != nil {
			fmt.Printf("%8d IDs: ERROR — %v\n", n, err)
			continue
		}
		count := 0
		for rows.Next() {
			var id int
			var html string
			rows.Scan(&id, &html)
			count++
		}
		rows.Close()
		elapsed := time.Since(start)

		perRow := time.Duration(0)
		if count > 0 {
			perRow = elapsed / time.Duration(count)
		}
		fmt.Printf("%8d IDs: %d rows in %s  (%s/row)\n", n, count, elapsed, perRow)
	}
}

func runHydrationBench() {
	db := openDB()
	defer db.Close()

	fmt.Println("--- All rows in channel+topic ---")

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
	fmt.Printf("IDs only:    %d ids in %s\n", len(ids), time.Since(start))

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
	fmt.Printf("Full join:   %d rows in %s\n", count, time.Since(start))

	start = time.Now()
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
	fmt.Printf("Hydrate IN:  %d rows in %s\n", count, time.Since(start))

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
