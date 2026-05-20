// Angry Gopher — HTTP server for the LynRummy Elm client (full
// game + puzzle surface) and the Claude-essay pointer page.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"angry-gopher/views"
)

func buildMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/gopher/version", handleVersion)

	// HTML views (Basic auth, no middleware). Single source of truth.
	views.RegisterPages(mux)

	// Admin overview (session stats from the filesystem). Protect via
	// the reverse proxy (e.g. nginx basic-auth) in front of Gopher.
	mux.HandleFunc("/admin", views.HandleAdmin)
	mux.HandleFunc("/admin/", views.HandleAdmin)

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/gopher/", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	return mux
}

func main() {
	configPath := os.Getenv("GOPHER_CONFIG")
	if configPath == "" {
		os.Stderr.WriteString(`
Angry Gopher requires GOPHER_CONFIG pointing to a config file.

Example config (~/AngryGopher/gopher.conf):

  # Angry Gopher server config
  port     = 9000
  data_dir = /home/steve/AngryGopher/prod

  # Zulip login pings
  zulip_url     = https://example.zulipchat.com
  zulip_email   = bot@example.com
  zulip_api_key = ...

Usage:

  GOPHER_CONFIG=~/AngryGopher/gopher.conf ./gopher-server
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
	views.SetDataRoot(config.SessionsDataRoot())

	mux := buildMux()

	fmt.Printf("Angry Gopher\n")
	fmt.Printf("  Data dir: %s\n", config.DataDir)
	fmt.Printf("  Listening on %s\n", config.ListenAddr())
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
