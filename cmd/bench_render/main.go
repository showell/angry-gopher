// Benchmark hydration strategies: IN-clause chunks vs prepared
// statement single-row lookups. Writes output to /dev/null to
// isolate DB + rendering time from network/browser.
package main

import (
	"database/sql"
	"fmt"
	"html"
	"io"
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

	// Get IDs for a big topic.
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
	fmt.Printf("%d IDs to hydrate\n\n", len(ids))

	// Test different approaches.
	for _, count := range []int{200, 1000, 5000, len(ids)} {
		testIDs := ids
		if count < len(ids) {
			testIDs = ids[:count]
		}
		fmt.Printf("=== %d messages ===\n", len(testIDs))

		// Approach 1: IN-clause chunks of various sizes.
		for _, chunkSize := range []int{50, 100, 500, 1000, len(testIDs)} {
			if chunkSize > len(testIDs) {
				continue
			}
			dur, bytes := benchINChunks(db, testIDs, chunkSize)
			fmt.Printf("  IN chunks %-5d: %8s  (%d bytes counted)\n", chunkSize, dur.Truncate(time.Microsecond), bytes)
		}

		// Approach 2: Prepared statement, one row at a time.
		dur, bytes := benchPrepared(db, testIDs)
		fmt.Printf("  Prepared 1-by-1: %8s  (%d bytes counted)\n", dur.Truncate(time.Microsecond), bytes)

		fmt.Println()
	}
}

type Counter struct {
	cnt int64
}

func (c *Counter) Write(p []byte) (int, error) {
	c.cnt += int64(len(p))
	return len(p), nil
}

func renderRow(w io.Writer, senderName, content string, timestamp int64) {
	t := time.Unix(timestamp, 0).Format("Jan 2 15:04")
	fmt.Fprintf(w, `<div><b>%s</b> <span>%s</span><div>%s</div></div>`,
		html.EscapeString(senderName), html.EscapeString(t), content)
}

func benchINChunks(db *sql.DB, ids []int, chunkSize int) (time.Duration, int64) {
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
			renderRow(counter, senderName, content, timestamp)
		}
		rows.Close()
	}

	return time.Since(start), counter.cnt
}

func benchPrepared(db *sql.DB, ids []int) (time.Duration, int64) {
	counter := &Counter{}
	start := time.Now()

	stmt, err := db.Prepare(`
		SELECT m.sender_id, u.full_name, mc.html, m.timestamp
		FROM messages m
		JOIN users u ON m.sender_id = u.id
		JOIN message_content mc ON m.content_id = mc.content_id
		WHERE m.id = ?`)
	if err != nil {
		log.Fatal(err)
	}
	defer stmt.Close()

	for _, id := range ids {
		var senderID int
		var senderName, content string
		var timestamp int64
		err := stmt.QueryRow(id).Scan(&senderID, &senderName, &content, &timestamp)
		if err != nil {
			continue
		}
		renderRow(counter, senderName, content, timestamp)
	}

	return time.Since(start), counter.cnt
}
