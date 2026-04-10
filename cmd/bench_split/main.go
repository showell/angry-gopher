// Benchmark split DB: index-only DB vs content DB.
// Creates two databases from the bench data:
//   /tmp/gopher_index.db  — messages, topics, users (no content)
//   /tmp/gopher_content.db — message_content only
// Then compares query performance.
package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
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

func main() {
	source, _ := sql.Open("sqlite", "/tmp/gopher_bench.db")
	defer source.Close()
	source.SetMaxOpenConns(1)

	// --- Build split databases ---
	if _, err := os.Stat("/tmp/gopher_index.db"); os.IsNotExist(err) {
		log.Println("Building index DB...")
		buildIndexDB(source)
	} else {
		log.Println("Index DB exists, reusing")
	}

	if _, err := os.Stat("/tmp/gopher_content.db"); os.IsNotExist(err) {
		log.Println("Building content DB...")
		buildContentDB(source)
	} else {
		log.Println("Content DB exists, reusing")
	}

	// --- File sizes ---
	for _, path := range []string{"/tmp/gopher_bench.db", "/tmp/gopher_index.db", "/tmp/gopher_content.db"} {
		info, _ := os.Stat(path)
		fmt.Printf("  %-30s %6.1f MB\n", path, float64(info.Size())/1024/1024)
	}
	fmt.Println()

	// --- Benchmark: ID query on index-only DB ---
	indexDB, _ := sql.Open("sqlite", "/tmp/gopher_index.db")
	defer indexDB.Close()
	indexDB.SetMaxOpenConns(1)
	indexDB.Exec("PRAGMA mmap_size = 1073741824")

	contentDB, _ := sql.Open("sqlite", "/tmp/gopher_content.db")
	defer contentDB.Close()
	contentDB.SetMaxOpenConns(1)
	contentDB.Exec("PRAGMA mmap_size = 1073741824")

	// Also open the combined DB for comparison.
	combinedDB, _ := sql.Open("sqlite", "/tmp/gopher_bench.db")
	defer combinedDB.Close()
	combinedDB.SetMaxOpenConns(1)
	combinedDB.Exec("PRAGMA mmap_size = 1073741824")

	fmt.Println("=== ID query (channel+topic, 23K results) ===")

	// Combined DB.
	for run := 0; run < 3; run++ {
		start := time.Now()
		ids := queryIDs(combinedDB)
		fmt.Printf("  combined  run%d: %d IDs in %s\n", run, len(ids), time.Since(start).Truncate(time.Microsecond))
	}

	// Index-only DB.
	for run := 0; run < 3; run++ {
		start := time.Now()
		ids := queryIDs(indexDB)
		fmt.Printf("  index-only run%d: %d IDs in %s\n", run, len(ids), time.Since(start).Truncate(time.Microsecond))
	}
	fmt.Println()

	// --- Benchmark: full hydration, split vs combined ---
	ids := queryIDs(indexDB)
	fmt.Printf("=== Full hydration (%d messages) ===\n", len(ids))

	// Combined: query with joins.
	for run := 0; run < 3; run++ {
		dur := hydrateCombined(combinedDB, ids)
		fmt.Printf("  combined   run%d: %s\n", run, dur.Truncate(time.Microsecond))
	}

	// Split: IDs from index, content from content DB.
	for run := 0; run < 3; run++ {
		dur := hydrateSplit(indexDB, contentDB, ids)
		fmt.Printf("  split      run%d: %s\n", run, dur.Truncate(time.Microsecond))
	}
}

func queryIDs(db *sql.DB) []int {
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
	return ids
}

func hydrateCombined(db *sql.DB, ids []int) time.Duration {
	counter := &Counter{}
	start := time.Now()

	for i := 0; i < len(ids); i += 500 {
		end := i + 500
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

		rows, _ := db.Query(fmt.Sprintf(`
			SELECT u.full_name, mc.html
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			JOIN message_content mc ON m.content_id = mc.content_id
			WHERE m.id IN (%s)`, strings.Join(placeholders, ",")), args...)

		for rows.Next() {
			var name, html string
			rows.Scan(&name, &html)
			fmt.Fprintf(counter, "%s%s", name, html)
		}
		rows.Close()
	}

	_ = counter.cnt
	return time.Since(start)
}

func hydrateSplit(indexDB, contentDB *sql.DB, ids []int) time.Duration {
	counter := &Counter{}
	start := time.Now()

	// Step 1: get content_ids and sender_ids from index DB.
	for i := 0; i < len(ids); i += 500 {
		end := i + 500
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

		// Get content_ids from index DB.
		rows, _ := indexDB.Query(fmt.Sprintf(`
			SELECT m.content_id, u.full_name
			FROM messages m
			JOIN users u ON m.sender_id = u.id
			WHERE m.id IN (%s)`, strings.Join(placeholders, ",")), args...)

		type row struct {
			contentID int
			name      string
		}
		var batch []row
		for rows.Next() {
			var r row
			rows.Scan(&r.contentID, &r.name)
			batch = append(batch, r)
		}
		rows.Close()

		// Hydrate content from content DB.
		cPlaceholders := make([]string, len(batch))
		cArgs := make([]interface{}, len(batch))
		for j, r := range batch {
			cPlaceholders[j] = "?"
			cArgs[j] = r.contentID
		}

		cRows, _ := contentDB.Query(fmt.Sprintf(`
			SELECT content_id, html FROM message_content
			WHERE content_id IN (%s)`, strings.Join(cPlaceholders, ",")), cArgs...)

		contentMap := map[int]string{}
		for cRows.Next() {
			var cid int
			var html string
			cRows.Scan(&cid, &html)
			contentMap[cid] = html
		}
		cRows.Close()

		for _, r := range batch {
			fmt.Fprintf(counter, "%s%s", r.name, contentMap[r.contentID])
		}
	}

	_ = counter.cnt
	return time.Since(start)
}

func buildIndexDB(source *sql.DB) {
	os.Remove("/tmp/gopher_index.db")
	db, _ := sql.Open("sqlite", "/tmp/gopher_index.db")
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.Exec("PRAGMA journal_mode=WAL")

	db.Exec(`CREATE TABLE users (id INTEGER PRIMARY KEY, full_name TEXT NOT NULL)`)
	db.Exec(`CREATE TABLE topics (topic_id INTEGER PRIMARY KEY, channel_id INTEGER NOT NULL, topic_name TEXT NOT NULL)`)
	db.Exec(`CREATE TABLE messages (id INTEGER PRIMARY KEY, content_id INTEGER NOT NULL, sender_id INTEGER NOT NULL, channel_id INTEGER NOT NULL, topic_id INTEGER NOT NULL, timestamp INTEGER NOT NULL)`)
	db.Exec(`CREATE INDEX idx_messages_channel_id_desc ON messages(channel_id, id DESC)`)
	db.Exec(`CREATE INDEX idx_messages_channel_topic ON messages(channel_id, topic_id)`)
	db.Exec(`CREATE INDEX idx_messages_sender ON messages(sender_id)`)

	log.Println("  Copying users...")
	rows, _ := source.Query(`SELECT id, full_name FROM users`)
	tx, _ := db.Begin()
	for rows.Next() {
		var id int
		var name string
		rows.Scan(&id, &name)
		tx.Exec(`INSERT INTO users VALUES (?, ?)`, id, name)
	}
	rows.Close()
	tx.Commit()

	log.Println("  Copying topics...")
	rows, _ = source.Query(`SELECT topic_id, channel_id, topic_name FROM topics`)
	tx, _ = db.Begin()
	for rows.Next() {
		var tid, cid int
		var name string
		rows.Scan(&tid, &cid, &name)
		tx.Exec(`INSERT INTO topics VALUES (?, ?, ?)`, tid, cid, name)
	}
	rows.Close()
	tx.Commit()

	log.Println("  Copying messages (no content)...")
	rows, _ = source.Query(`SELECT id, content_id, sender_id, channel_id, topic_id, timestamp FROM messages`)
	tx, _ = db.Begin()
	count := 0
	for rows.Next() {
		var id, cid, sid, chid, tid int
		var ts int64
		rows.Scan(&id, &cid, &sid, &chid, &tid, &ts)
		tx.Exec(`INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?)`, id, cid, sid, chid, tid, ts)
		count++
		if count%100000 == 0 {
			tx.Commit()
			tx, _ = db.Begin()
			log.Printf("    %d messages...", count)
		}
	}
	rows.Close()
	tx.Commit()
	log.Printf("  Done: %d messages", count)
}

func buildContentDB(source *sql.DB) {
	os.Remove("/tmp/gopher_content.db")
	db, _ := sql.Open("sqlite", "/tmp/gopher_content.db")
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.Exec("PRAGMA journal_mode=WAL")

	db.Exec(`CREATE TABLE message_content (content_id INTEGER PRIMARY KEY, html TEXT NOT NULL)`)

	log.Println("  Copying content...")
	rows, _ := source.Query(`SELECT content_id, html FROM message_content`)
	tx, _ := db.Begin()
	count := 0
	for rows.Next() {
		var cid int
		var html string
		rows.Scan(&cid, &html)
		tx.Exec(`INSERT INTO message_content VALUES (?, ?)`, cid, html)
		count++
		if count%100000 == 0 {
			tx.Commit()
			tx, _ = db.Begin()
			log.Printf("    %d rows...", count)
		}
	}
	rows.Close()
	tx.Commit()
	log.Printf("  Done: %d content rows", count)
}
