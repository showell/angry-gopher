// Angry Gopher — HTTP server for the LynRummy Elm client, plus a
// wiki/source browser and small admin surface. The older
// Zulip-compatible messaging API (events, users, DMs, channels)
// was ripped 2026-04-21; this is a LynRummy server now.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"angry-gopher/auth"
	"angry-gopher/views"
)

func buildMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/gopher/version", handleVersion)

	// HTML views (Basic auth, no middleware). Single source of truth.
	views.RegisterPages(mux)

	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("views/static"))))

	mux.HandleFunc("/admin/login", handleAdminLogin)
	mux.HandleFunc("/admin/health", handleHealthCheck)
	mux.HandleFunc("/admin/", adminHandler)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/gopher/", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	return mux
}

func wireDB() {
	auth.DB = DB
	views.DB = DB
}

func main() {
	configPath := os.Getenv("GOPHER_CONFIG")
	if configPath == "" {
		os.Stderr.WriteString(`
Angry Gopher requires GOPHER_CONFIG pointing to a JSON config file.

Example config (~/AngryGopher/prod.json):

  {
      "mode": "prod",
      "root": "/home/steve/AngryGopher/prod",
      "port": 9000
  }

Usage:

  GOPHER_CONFIG=~/AngryGopher/prod.json ./gopher-server

Backup the production database:

  cp ~/AngryGopher/prod/gopher.db ~/AngryGopher/prod/backup_$(date +%Y%m%d).db
`)
		os.Exit(1)
	}

	config, err := loadConfig(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if err := config.EnsureDirectories(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	serverConfig = config

	initDB(config.DBPath())
	wireDB()

	// Always seed the two canonical users (Steve=1, Claude=2) so the
	// empty-DB case still yields a playable system.
	seedData()

	mux := buildMux()

	fmt.Printf("Angry Gopher [%s mode]\n", config.Mode)
	fmt.Printf("  Root:     %s\n", config.Root)
	fmt.Printf("  Database: %s\n", config.DBPath())
	fmt.Printf("  Listening on %s\n", config.ListenAddr())
	fmt.Printf("  Admin UI: http://localhost:%d/admin/\n", config.Port)
	log.Fatal(http.ListenAndServe(config.ListenAddr(), mux))
}

func handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"result":  "success",
		"version": "0.1",
	})
}

// Set by main() so the admin/ops dashboard can show server info.
var serverConfig *ServerConfig

// Set at build time via -ldflags "-X main.gitCommit=...".
var gitCommit = "dev"
var serverStartTime = time.Now()
