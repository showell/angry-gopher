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

	"angry-gopher/server/admin"
	"angry-gopher/server/chat"
	"angry-gopher/server/lynrummy"
	"angry-gopher/server/web"
)

func buildMux() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/version", handleVersion)

	// HTML pages, incl. the home/lobby at "/". Single source of truth.
	RegisterPages(mux)

	// Name login/logout (login sets the gopher_uid cookie; logout
	// clears it). /login/full sets a member password session.
	mux.HandleFunc("/login", handleLogin)
	mux.HandleFunc("/login/full", handleLoginFull)
	mux.HandleFunc("/logout", handleLogout)

	// Admin overview (session stats from the filesystem). Goes through
	// the login gate, then requires the user's admin flag (see HandleAdmin).
	mux.HandleFunc("/admin", admin.HandleAdmin)
	mux.HandleFunc("/admin/", admin.HandleAdmin)

	return withLoginGate(mux)
}

// withLoginGate makes login mandatory: any request without a resolvable
// identity is redirected to /login, except for the exempt paths (login/
// logout, the version check).
func withLoginGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// API keys are read-only: a request that authenticates via a key
		// may only GET/HEAD. Enforced centrally so no mutating endpoint
		// can be reached with a key, whatever it is.
		if web.IsAPIKeyAuth(r) && r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "API keys are read-only", http.StatusForbidden)
			return
		}
		if loginExempt(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		// web.CurrentUser resolves the identity (member session is
		// authoritative; a guest uid is honored only if it's a real
		// non-member user; a member uid without a session is a forge
		// attempt and resolves to none). No identity → log in.
		if web.CurrentUser(r).ID == "" {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func loginExempt(path string) bool {
	switch path {
	case "/login", "/login/full", "/logout", "/version":
		return true
	}
	// /admin is intentionally not exempt: it goes through the gate and
	// then requires the admin flag (see admin.HandleAdmin).
	return false
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
	web.SetUsersRoot(config.UsersDataRoot())
	web.SetSessionSecretDir(config.ChatDataRoot())
	web.SetAssets(assets)
	web.SetVersion(gitCommit)

	handler := buildMux()

	fmt.Printf("Angry Gopher\n")
	fmt.Printf("  Data dir: %s\n", config.DataDir)
	fmt.Printf("  Listening on %s\n", config.ListenAddr())

	// Timeouts bound how long a slow/idle client can tie up a
	// connection (slowloris). Caddy fronts the server for TLS and
	// outer body limits beyond our per-handler caps.
	srv := &http.Server{
		Addr:              config.ListenAddr(),
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

func handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"result":  "success",
		"version": "0.1",
	})
}

// Set at build time via -ldflags "-X main.gitCommit=...".
var gitCommit = "dev"
