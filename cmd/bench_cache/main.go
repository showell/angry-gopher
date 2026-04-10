// Benchmark SQLite cache and mmap settings.
// Runs the same query twice to see cold vs warm cache.
package main

import (
	"database/sql"
	"fmt"
	"log"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type Counter struct {
	cnt int64
}

func (c *Counter) Write(p []byte) (int, error) {
	c.cnt += int64(len(p))
	return len(p), nil
}

type config struct {
	name     string
	pragmas  []string
}

func main() {
	configs := []config{
		{
			"Default (2MB cache, no mmap)",
			nil,
		},
		{
			"Large cache (200MB)",
			[]string{"PRAGMA cache_size = -200000"},
		},
		{
			"mmap 1GB",
			[]string{"PRAGMA mmap_size = 1073741824"},
		},
		{
			"Large cache + mmap 1GB",
			[]string{
				"PRAGMA cache_size = -200000",
				"PRAGMA mmap_size = 1073741824",
			},
		},
	}

	for _, cfg := range configs {
		fmt.Printf("=== %s ===\n", cfg.name)
		runBench(cfg.pragmas)
		fmt.Println()
	}
}

func runBench(pragmas []string) {
	// Open a fresh connection each time to avoid cross-test caching.
	db, err := sql.Open("sqlite", "/tmp/gopher_bench.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	for _, p := range pragmas {
		db.Exec(p)
	}

	// Get IDs.
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

	// Run hydration 3 times: cold, warm1, warm2.
	for run := 0; run < 3; run++ {
		label := "cold"
		if run > 0 {
			label = fmt.Sprintf("warm%d", run)
		}
		dur := hydrateAll(db, ids, 500)
		fmt.Printf("  %-6s %d msgs in %s\n", label, len(ids), dur.Truncate(time.Microsecond))
	}
}

func hydrateAll(db *sql.DB, ids []int, chunkSize int) time.Duration {
	counter := &Counter{}
	start := time.Now()

	for i := 0; i < len(ids); i += chunkSize {
		end := i + chunkSize
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[i:end]

		placeholders := make([]string, len(chunk))
		args := make([]interface{}, len(chunk))
		for j, id := range chunk {
			placeholders[j] = "?"
			args[j] = id
		}

		rows, err := db.Query(fmt.Sprintf(`
			SELECT m.sender_id, u.full_name, mc.html, m.timestamp
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)
			ORDER BY m.id DESC`, strings.Join(placeholders, ",")), args...)
		if err != nil {
			continue
		}

		for rows.Next() {
			var senderID int
			var senderName, content string
			var timestamp int64
			rows.Scan(&senderID, &senderName, &content, &timestamp)
			fmt.Fprintf(counter, `<div><b>%s</b><div>%s</div></div>`, senderName, content)
		}
		rows.Close()
	}

	_ = counter.cnt
	return time.Since(start)
}
