// Angry Gopher — a lightweight Zulip-compatible server backed by SQLite.
//
// Serves the Zulip API subset that Angry Cat needs, reading from the
// local database. Fully standalone — no upstream Zulip connection.

package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/dm"
	"angry-gopher/events"
	"angry-gopher/flags"
	"angry-gopher/games"
	"angry-gopher/invites"
	"angry-gopher/messages"
	"angry-gopher/ratelimit"
	"angry-gopher/reactions"
	"angry-gopher/respond"
	"angry-gopher/search"
	"angry-gopher/users"
	"angry-gopher/views"
	"angry-gopher/webhooks"
)

func buildMux() *http.ServeMux {
	mux := http.NewServeMux()
	api := withMiddleware

	// --- Zulip-compatible API ---
	mux.HandleFunc("/api/v1/register", api(events.HandleRegister))
	mux.HandleFunc("/api/v1/events", api(routeEvents))
	mux.HandleFunc("/api/v1/users/me", api(routeOwnUser))
	mux.HandleFunc("/api/v1/users/me/subscriptions/add", api(channels.HandleSubscribe))
	mux.HandleFunc("/api/v1/users/me/subscriptions", api(routeSubscriptions))
	mux.HandleFunc("/api/v1/users/me/presence", api(routePresence))
	mux.HandleFunc("/api/v1/users/by_email", api(users.HandleGetUserByEmail))
	mux.HandleFunc("/api/v1/users/", api(routeUserByID))
	mux.HandleFunc("/api/v1/users", api(routeUsers))
	mux.HandleFunc("/api/v1/settings", api(users.HandleUpdateSettings))
	mux.HandleFunc("/api/v1/search", api(search.HandleSearch))
	mux.HandleFunc("/api/v1/hydrate", api(search.HandleHydrate))
	mux.HandleFunc("/api/v1/messages/render", api(messages.HandleRenderMessage))
	mux.HandleFunc("/api/v1/messages/flags", api(flags.HandleUpdateFlags))
	mux.HandleFunc("/api/v1/messages/", api(routeMessageByID))
	mux.HandleFunc("/api/v1/messages", api(routeMessages))
	mux.HandleFunc("/api/v1/mark_all_as_read", api(flags.HandleMarkAllRead))
	mux.HandleFunc("/api/v1/mark_channel_as_read", api(flags.HandleMarkChannelRead))
	mux.HandleFunc("/api/v1/mark_topic_as_read", api(flags.HandleMarkTopicRead))
	mux.HandleFunc("/api/v1/get_stream_id", api(channels.HandleGetChannelID))
	mux.HandleFunc("/api/v1/streams/", api(routeStreamByID))
	mux.HandleFunc("/api/v1/streams", api(channels.HandleGetAllChannels))
	mux.HandleFunc("/api/v1/dm/conversations", api(dm.HandleConversations))
	mux.HandleFunc("/api/v1/dm/messages", api(dm.HandleMessages))
	mux.HandleFunc("/api/v1/user_uploads/", api(handleUploadTempURL))
	mux.HandleFunc("/api/v1/user_uploads", api(handleUpload))

	// --- Gopher-only API ---
	mux.HandleFunc("/gopher/version", api(handleVersion))
	mux.HandleFunc("/gopher/invites", api(invites.HandleCreateInvite))
	mux.HandleFunc("/gopher/invites/redeem", api(invites.HandleRedeemInvite))
	mux.HandleFunc("/gopher/games/", api(games.HandleGameSub))
	mux.HandleFunc("/gopher/games", api(games.HandleGames))
	mux.HandleFunc("/gopher/plays/", api(games.HandlePlaysRoot))
	mux.HandleFunc("/gopher/webhooks/github", webhooks.HandleGitHub)
	mux.HandleFunc("/gopher/github/repos", api(webhooks.HandleRepos))

	// --- HTML views (Basic auth, no middleware) ---
	// All pages registered from views.Pages (single source of truth).
	views.RegisterPages(mux)

	// --- Static assets ---
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("views/static"))))

	// --- Admin & uploads ---
	mux.HandleFunc("/user_uploads/", api(handleServeUpload))
	mux.HandleFunc("/admin/login", handleAdminLogin)
	mux.HandleFunc("/admin/health", handleHealthCheck)
	mux.HandleFunc("/admin/", adminHandler)
	mux.HandleFunc("/", api(handleUnimplemented))

	return mux
}

func wireDB() {
	auth.DB = DB
	users.DB = DB
	channels.DB = DB
	messages.DB = DB
	flags.DB = DB
	reactions.DB = DB
	invites.DB = DB
	games.DB = DB
	channels.RenderMarkdown = renderMarkdown
	dm.DB = DB
	dm.RenderMarkdown = renderMarkdown
	views.DB = DB
	views.RenderMarkdown = renderMarkdown
	search.DB = DB
	webhooks.DB = DB
	messages.RenderMarkdown = renderMarkdown
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

Example config (~/AngryGopher/demo.json):

  {
      "mode": "demo",
      "root": "/home/steve/AngryGopher/demo",
      "port": 9000
  }

Usage:

  GOPHER_CONFIG=~/AngryGopher/prod.json ./gopher-server
  GOPHER_CONFIG=~/AngryGopher/demo.json ./gopher-server

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
	uploadsDir = config.UploadsDir()

	if config.IsDemo() {
		os.Setenv("GOPHER_RESET_DB", "1")
	}

	initDB(config.DBPath())
	wireDB()

	if config.IsDemo() {
		seedData(true)
	}

	ensureBotUsers()
	RefreshLinkifierCache()

	mux := buildMux()

	fmt.Printf("Angry Gopher [%s mode]\n", config.Mode)
	fmt.Printf("  Root:     %s\n", config.Root)
	fmt.Printf("  Database: %s\n", config.DBPath())
	fmt.Printf("  Uploads:  %s\n", config.UploadsDir())
	fmt.Printf("  Listening on %s\n", config.ListenAddr())
	fmt.Printf("  Admin UI: http://localhost:%d/admin/\n", config.Port)
	events.StartReaper(90 * time.Second)
	log.Fatal(http.ListenAndServe(config.ListenAddr(), mux))
}

// --- Gopher-only ---

func handleVersion(w http.ResponseWriter, r *http.Request) {
	respond.Success(w, map[string]interface{}{
		"version": "0.1",
	})
}

// --- File uploads ---

// Set by main() from the config. Tests don't use uploads.
var uploadsDir string

// Set by main() so the admin/ops dashboard can show server info.
var serverConfig *ServerConfig

// Set at build time via -ldflags "-X main.gitCommit=...".
var gitCommit = "dev"
var serverStartTime = time.Now()

func ensureBotUsers() {
	var ghBotID int
	DB.QueryRow(`SELECT id FROM users WHERE email = 'github-bot@gopher.internal'`).Scan(&ghBotID)
	if ghBotID == 0 {
		result, _ := DB.Exec(`INSERT INTO users (email, full_name, api_key, is_admin) VALUES (?, ?, ?, ?)`,
			"github-bot@gopher.internal", "GitHub", "github-bot-key", 0)
		id, _ := result.LastInsertId()
		ghBotID = int(id)
	}
	webhooks.WebhookUserID = ghBotID
	log.Printf("GitHub bot user: id=%d", ghBotID)
}

var (
	nextUploadID   int
	nextUploadIDMu sync.Mutex
)

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		respond.Error(w, "Method not allowed")
		return
	}

	file, header, err := r.FormFile("FILE")
	if err != nil {
		respond.Error(w, "Missing FILE field: "+err.Error())
		return
	}
	defer file.Close()

	nextUploadIDMu.Lock()
	nextUploadID++
	id := nextUploadID
	nextUploadIDMu.Unlock()

	dir := filepath.Join(uploadsDir, strconv.Itoa(id))
	os.MkdirAll(dir, 0755)

	dst, err := os.Create(filepath.Join(dir, header.Filename))
	if err != nil {
		respond.Error(w, "Failed to save file: "+err.Error())
		return
	}
	defer dst.Close()
	io.Copy(dst, file)

	uri := fmt.Sprintf("/user_uploads/%d/%s", id, header.Filename)
	log.Printf("[api] Uploaded %s (%d bytes)", uri, header.Size)

	respond.Success(w, map[string]interface{}{"uri": uri})
}

func handleUploadTempURL(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")
	respond.Success(w, map[string]interface{}{"url": path})
}

func handleServeUpload(w http.ResponseWriter, r *http.Request) {
	rel := strings.TrimPrefix(r.URL.Path, "/user_uploads/")
	filePath := filepath.Join(uploadsDir, rel)

	if strings.Contains(rel, "..") {
		http.NotFound(w, r)
		return
	}

	http.ServeFile(w, r, filePath)
}

// --- Middleware ---

func handleUnimplemented(w http.ResponseWriter, r *http.Request) {
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}
	log.Printf("[unimplemented] %s %s", r.Method, r.URL.Path)
	respond.Error(w, fmt.Sprintf("Endpoint not implemented: %s %s", r.Method, r.URL.Path))
}

func withMiddleware(handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		}
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			log.Printf("%s %s", r.Method, r.URL.Path)
		}

		// Rate limit authenticated users. Skip the check for event
		// polling (passive listener) and unauthenticated requests.
		isEventPoll := r.URL.Path == "/api/v1/events"
		if !isEventPoll && r.Header.Get("Authorization") != "" {
			userID := auth.Authenticate(r)
			if userID != 0 && !ratelimit.Check(userID) {
				w.Header().Set("Retry-After", "60")
				w.WriteHeader(429)
				respond.WriteJSON(w, map[string]interface{}{
					"result": "error",
					"msg":    "Rate limit exceeded",
				})
				return
			}
		}

		handler(w, r)
	}
}
