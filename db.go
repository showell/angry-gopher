// Database setup and helpers for Angry Gopher.
// Uses SQLite via modernc.org/sqlite (pure Go, no CGO).

package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"time"

	"angry-gopher/schema"

	_ "modernc.org/sqlite"
)

var DB *sql.DB

func initDB(path string) {
	var err error
	if DB != nil {
		DB.Close()
	}

	// For file-based databases, start fresh on every server restart
	// so we always get a clean slate with seeded data.
	// Only delete if GOPHER_RESET_DB=1 is set — prevents accidental
	// destruction of a production database.
	if path != ":memory:" {
		if os.Getenv("GOPHER_RESET_DB") == "1" {
			os.Remove(path)
		}
	}

	DB, err = sql.Open("sqlite", path)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	// Single connection: serializes all access, no lock contention,
	// no WAL/SHM files. Sufficient for our low-traffic server.
	DB.SetMaxOpenConns(1)

	// For file-based DBs, tell SQLite to retry for up to 5 seconds
	// if the database is busy, rather than failing immediately.
	if path != ":memory:" {
		DB.Exec("PRAGMA busy_timeout = 5000")
	}

	_, err = DB.Exec(schema.Core)
	if err != nil {
		log.Fatalf("Failed to create schema: %v", err)
	}

	fmt.Printf("Database initialized at %s\n", path)
}

func seedData() {
	users := []struct {
		id       int
		fullName string
	}{
		{1, "Steve"},
		{2, "Claude"},
	}
	now := time.Now().Unix()
	for _, u := range users {
		DB.Exec(`INSERT OR IGNORE INTO users (id, full_name, created_at) VALUES (?, ?, ?)`,
			u.id, u.fullName, now)
	}
}
