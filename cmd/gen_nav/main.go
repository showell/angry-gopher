// Generates a static HTML nav page with message counts.
// Run once, open the output in a browser.
//
// Usage:
//   go run ./cmd/gen_nav -db /tmp/gopher_bench.db -out /tmp/nav.html
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"html"
	"log"
	"os"

	_ "modernc.org/sqlite"
)

func main() {
	dbPath := flag.String("db", "/tmp/gopher_bench.db", "database path")
	outPath := flag.String("out", "/tmp/nav.html", "output HTML file")
	flag.Parse()

	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	rows, err := db.Query(`
		SELECT c.channel_id, c.name, t.topic_name, COUNT(m.id) AS msg_count
		FROM topics t
		JOIN channels c ON t.channel_id = c.channel_id
		LEFT JOIN messages m ON m.topic_id = t.topic_id
		GROUP BY t.topic_id
		ORDER BY c.name, msg_count DESC`)
	if err != nil {
		log.Fatal(err)
	}
	defer rows.Close()

	f, err := os.Create(*outPath)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()

	fmt.Fprint(f, `<!DOCTYPE html>
<html><head><title>Message Nav</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 700px; }
h2 { color: #000080; margin-top: 20px; }
a { color: #000080; }
.count { color: #888; margin-left: 4px; }
ul { list-style: none; padding-left: 0; }
li { padding: 2px 0; }
</style>
</head><body>
<h1>Message Nav</h1>
`)

	currentChannel := ""
	for rows.Next() {
		var chID, count int
		var chName, topicName string
		rows.Scan(&chID, &chName, &topicName, &count)

		if chName != currentChannel {
			if currentChannel != "" {
				fmt.Fprint(f, "</ul>\n")
			}
			fmt.Fprintf(f, "<h2>#%s</h2>\n<ul>\n", html.EscapeString(chName))
			currentChannel = chName
		}

		url := fmt.Sprintf("http://localhost:9000/gopher/messages?channel_id=%d&topic=%s",
			chID, topicName)
		fmt.Fprintf(f, `<li><a href="%s">%s</a><span class="count">(%d)</span></li>`+"\n",
			html.EscapeString(url), html.EscapeString(topicName), count)
	}
	if currentChannel != "" {
		fmt.Fprint(f, "</ul>\n")
	}

	fmt.Fprint(f, "</body></html>\n")
	log.Printf("Written to %s", *outPath)
}
