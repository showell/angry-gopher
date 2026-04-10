// Command db_query runs a SQL query against a Gopher database.
//
// Usage:
//
//	go run ./cmd/db_query -db ~/AngryGopher/prod/gopher.db "SELECT email, api_key FROM users WHERE is_admin = 1"
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"strings"

	_ "modernc.org/sqlite"
)

func main() {
	dbPath := flag.String("db", "", "path to SQLite database")
	flag.Parse()

	if *dbPath == "" || flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "Usage: go run ./cmd/db_query -db <path> <SQL>")
		os.Exit(1)
	}

	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cannot open DB: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	query := strings.Join(flag.Args(), " ")
	rows, err := db.Query(query)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Query error: %v\n", err)
		os.Exit(1)
	}
	defer rows.Close()

	cols, _ := rows.Columns()
	fmt.Println(strings.Join(cols, "\t"))

	values := make([]interface{}, len(cols))
	ptrs := make([]interface{}, len(cols))
	for i := range values {
		ptrs[i] = &values[i]
	}

	for rows.Next() {
		rows.Scan(ptrs...)
		parts := make([]string, len(cols))
		for i, v := range values {
			parts[i] = fmt.Sprintf("%v", v)
		}
		fmt.Println(strings.Join(parts, "\t"))
	}
}
