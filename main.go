// Angry Gopher — HTTP server for the LynRummy Elm client (full
// game + puzzle surface) and the Claude-essay pointer page.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"angry-gopher/auth"
	"angry-gopher/views"
	"angry-gopher/zulip"
)

func buildMux() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/version", handleVersion)

	// HTML pages, incl. the home/lobby at "/". Single source of truth.
	views.RegisterPages(mux)

	// Name login/logout (login sets the gopher_user cookie + fires a
	// Zulip ping; logout clears it).
	mux.HandleFunc("/login", handleLogin)
	mux.HandleFunc("/login/full", handleLoginFull)
	mux.HandleFunc("/logout", handleLogout)

	// Admin overview (session stats from the filesystem). Protect via
	// the reverse proxy (e.g. nginx basic-auth) in front of Gopher.
	mux.HandleFunc("/admin", views.HandleAdmin)
	mux.HandleFunc("/admin/", views.HandleAdmin)

	return withLoginGate(mux)
}

// withLoginGate makes login mandatory: any request without a valid
// gopher_user cookie is redirected to /login, except for a few
// exempt paths (login/logout itself, the health check, and /admin,
// which the reverse proxy guards instead).
func withLoginGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if loginExempt(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		// A valid member session is always allowed; the signed name is
		// the authoritative identity.
		if name, ok := views.SessionUser(r); ok {
			if !views.UserExists(name) {
				_ = views.ClaimUser(name)
			}
			next.ServeHTTP(w, r)
			return
		}
		// Otherwise a guest: needs a non-reserved identity. A reserved
		// name without a session (stale/forged cookie) isn't honored —
		// send it to log in. Any other logged-in name is implicitly
		// registered so it shows up in the roster.
		guest := auth.CurrentUser(r)
		if guest == auth.DefaultUser || views.IsReserved(guest) {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		if !views.UserExists(guest) {
			_ = views.ClaimUser(guest)
		}
		next.ServeHTTP(w, r)
	})
}

func loginExempt(path string) bool {
	switch path {
	case "/login", "/login/full", "/logout", "/version":
		return true
	}
	return strings.HasPrefix(path, "/admin")
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

	views.SetDataRoot(config.SessionsDataRoot())
	views.SetChatRoot(config.ChatDataRoot())
	views.SetAssets(assets)
	zulip.Configure(zulip.Config{
		URL:    config.ZulipURL,
		Email:  config.ZulipEmail,
		APIKey: config.ZulipAPIKey,
		Stream: config.ZulipStream,
		Topic:  config.ZulipTopic,
	})

	handler := buildMux()

	fmt.Printf("Angry Gopher\n")
	fmt.Printf("  Data dir: %s\n", config.DataDir)
	fmt.Printf("  Listening on %s\n", config.ListenAddr())

	// Timeouts bound how long a slow/idle client can tie up a
	// connection (slowloris). nginx fronts the server for TLS, body
	// limits beyond our per-handler caps, and rate-limiting.
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
var serverStartTime = time.Now()
