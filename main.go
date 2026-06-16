// Angry Gopher — HTTP server for Lyn Rummy: the Elm client (full
// game + puzzle surface), private chat, login, and admin.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"angry-gopher/server/chat"
	"angry-gopher/server/lynrummy"
	"angry-gopher/server/users"
	"angry-gopher/server/platform"
)

func buildMux() http.Handler {
	mux := http.NewServeMux()
	RegisterPages(mux)
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

	lynrummy.SetDataRoot(config.SessionsDataRoot())
	chat.SetChatRoot(config.ChatDataRoot())
	users.SetUsersRoot(config.UsersDataRoot())
	users.SetAuthRoot(config.AuthDataRoot())
	users.SetSessionSecretDir(config.ChatDataRoot())
	platform.SetAssets(assets)
	platform.SetVersion(gitCommit)

	handler := buildMux()

	fmt.Printf("Angry Gopher\n")
	fmt.Printf("  Data dir: %s\n", config.DataDir)
	fmt.Printf("  Listening on %s\n", config.ListenAddr())

	// Timeouts bound how long a slow/idle client can tie up a
	// connection (slowloris). Caddy fronts the server for TLS and
	// outer body limits beyond our per-handler caps.
	//
	// No WriteTimeout on purpose: it's a hard deadline on the WHOLE
	// response write, so it closes the socket mid-stream on anything
	// large or long-lived — a big image to a slow client truncates
	// ("corrupt or truncated"), and every SSE stream would die at 30s.
	// (The SSE handlers already clear it per-request in sse.go.)
	// ReadHeaderTimeout is the timeout that actually guards against
	// slowloris; WriteTimeout was the wrong tool for a server that
	// serves large files and infinite event streams.
	srv := &http.Server{
		Addr:              config.ListenAddr(),
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

func handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	// `commit` is the build identity (the -ldflags BUILD_ID): it lets ops/start
	// confirm the freshly-built binary is the one actually serving, so a stale or
	// not-restarted server can't masquerade as a successful rebuild.
	json.NewEncoder(w).Encode(map[string]interface{}{
		"result":  "success",
		"version": "0.1",
		"commit":  gitCommit,
	})
}

// Set at build time via -ldflags "-X main.gitCommit=...".
var gitCommit = "dev"
