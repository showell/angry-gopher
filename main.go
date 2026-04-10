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
	"angry-gopher/buddies"
	"angry-gopher/channels"
	"angry-gopher/dm"
	"angry-gopher/events"
	"angry-gopher/flags"
	"angry-gopher/games"
	"angry-gopher/invites"
	"angry-gopher/messages"
	"angry-gopher/presence"
	"angry-gopher/ratelimit"
	"angry-gopher/reactions"
	"angry-gopher/respond"
	"angry-gopher/users"
	"angry-gopher/views"
	"angry-gopher/webhooks"
)

func buildMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/v1/server_settings", withMiddleware(handleServerSettings))
	mux.HandleFunc("/api/v1/register", withMiddleware(events.HandleRegister))
	mux.HandleFunc("/api/v1/events", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			events.HandleEvents(w, r)
		case "DELETE":
			events.HandleDeleteQueue(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	mux.HandleFunc("/api/v1/users/me", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" {
			users.HandleDeactivateOwnUser(w, r)
		} else {
			users.HandleGetOwnUser(w, r)
		}
	}))
	mux.HandleFunc("/api/v1/users/me/muted_users/", withMiddleware(users.HandleMuteUser))
	mux.HandleFunc("/api/v1/users/me/muted_users", withMiddleware(users.HandleGetMutedUsers))
	mux.HandleFunc("/api/v1/users/me/muted_topics", withMiddleware(channels.HandleMuteTopic))
	mux.HandleFunc("/api/v1/users/me/subscriptions/add", withMiddleware(channels.HandleSubscribe))
	mux.HandleFunc("/api/v1/users/by_email", withMiddleware(users.HandleGetUserByEmail))
	mux.HandleFunc("/api/v1/users/", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/subscriptions/") {
			channels.HandleGetSubscriptionStatus(w, r)
		} else if strings.HasSuffix(r.URL.Path, "/deactivate") {
			users.HandleDeactivateUser(w, r)
		} else if strings.HasSuffix(r.URL.Path, "/reactivate") {
			users.HandleReactivateUser(w, r)
		} else if strings.HasSuffix(r.URL.Path, "/regenerate_api_key") {
			users.HandleRegenerateAPIKey(w, r)
		} else if r.Method == "PATCH" {
			users.HandleUpdateUser(w, r)
		} else {
			users.HandleGetUser(w, r)
		}
	}))
	mux.HandleFunc("/api/v1/users", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			users.HandleCreateUser(w, r)
		} else {
			users.HandleUsers(w, r)
		}
	}))
	mux.HandleFunc("/api/v1/settings", withMiddleware(users.HandleUpdateSettings))
	mux.HandleFunc("/api/v1/users/me/subscriptions", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			channels.HandleSubscriptions(w, r)
		case "POST":
			channels.HandleCreateChannel(w, r)
		case "DELETE":
			channels.HandleUnsubscribe(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	mux.HandleFunc("/api/v1/messages", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			messages.HandleGetMessages(w, r)
		case "POST":
			messages.HandleSendMessage(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	mux.HandleFunc("/api/v1/messages/render", withMiddleware(messages.HandleRenderMessage))
	mux.HandleFunc("/api/v1/messages/flags", withMiddleware(flags.HandleUpdateFlags))
	mux.HandleFunc("/api/v1/mark_all_as_read", withMiddleware(flags.HandleMarkAllRead))
	mux.HandleFunc("/api/v1/mark_channel_as_read", withMiddleware(flags.HandleMarkChannelRead))
	mux.HandleFunc("/api/v1/mark_topic_as_read", withMiddleware(flags.HandleMarkTopicRead))
	mux.HandleFunc("/api/v1/get_stream_id", withMiddleware(channels.HandleGetChannelID))
	mux.HandleFunc("/api/v1/messages/", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/reactions") {
			reactions.HandleReaction(w, r)
		} else if r.Method == "PATCH" {
			messages.HandleEditMessage(w, r)
		} else if r.Method == "GET" {
			messages.HandleGetSingleMessage(w, r)
		} else if r.Method == "DELETE" {
			messages.HandleDeleteMessage(w, r)
		} else {
			respond.Error(w, "Unknown messages sub-endpoint")
		}
	}))
	mux.HandleFunc("/api/v1/streams", withMiddleware(channels.HandleGetAllChannels))
	mux.HandleFunc("/api/v1/streams/", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/topics") {
			channels.HandleGetTopics(w, r)
		} else if strings.HasSuffix(r.URL.Path, "/subscribers") {
			channels.HandleGetSubscribers(w, r)
		} else if r.Method == "PATCH" {
			channels.HandleUpdateChannel(w, r)
		} else if r.Method == "GET" {
			channels.HandleGetChannel(w, r)
		} else {
			respond.Error(w, "Unknown streams sub-endpoint")
		}
	}))
	// Gopher-only endpoints — not part of the Zulip API.
	mux.HandleFunc("/gopher/version", withMiddleware(handleVersion))
	mux.HandleFunc("/gopher/invites", withMiddleware(invites.HandleCreateInvite))
	mux.HandleFunc("/gopher/invites/redeem", withMiddleware(invites.HandleRedeemInvite))
	mux.HandleFunc("/gopher/games", withMiddleware(games.HandleGames))
	mux.HandleFunc("/gopher/games/", withMiddleware(games.HandleGameSub))
	mux.HandleFunc("/gopher/", views.HandleIndex)
	mux.HandleFunc("/gopher/dm", views.HandleDM)
	mux.HandleFunc("/gopher/messages", views.HandleMessages)
	mux.HandleFunc("/gopher/channels", views.HandleChannels)
	mux.HandleFunc("/gopher/users", views.HandleUsers)
	mux.HandleFunc("/gopher/buddies", views.HandleBuddies)
	mux.HandleFunc("/gopher/github", views.HandleGitHub)
	mux.HandleFunc("/gopher/game-lobby", views.HandleGames)
	mux.HandleFunc("/gopher/invites-view", views.HandleInvites)
	mux.HandleFunc("/gopher/webhooks/github", webhooks.HandleGitHub)
	mux.HandleFunc("/gopher/github/repos", withMiddleware(webhooks.HandleRepos))
	mux.HandleFunc("/api/v1/dm/conversations", withMiddleware(dm.HandleConversations))
	mux.HandleFunc("/api/v1/dm/messages", withMiddleware(dm.HandleMessages))
	mux.HandleFunc("/api/v1/users/me/presence", withMiddleware(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "POST":
			presence.HandleUpdatePresence(w, r)
		case "GET":
			presence.HandleGetPresence(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))

	mux.HandleFunc("/api/v1/buddies", withMiddleware(buddies.HandleBuddies))
	mux.HandleFunc("/api/v1/user_uploads", withMiddleware(handleUpload))
	mux.HandleFunc("/api/v1/user_uploads/", withMiddleware(handleUploadTempURL))
	mux.HandleFunc("/user_uploads/", withMiddleware(handleServeUpload))
	mux.HandleFunc("/admin/login", handleAdminLogin)
	mux.HandleFunc("/admin/health", handleHealthCheck)
	mux.HandleFunc("/admin/", adminHandler)
	mux.HandleFunc("/", withMiddleware(handleUnimplemented))

	return mux
}

func wireDB() {
	auth.DB = DB
	users.DB = DB
	buddies.DB = DB
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
	webhooks.DB = DB
	events.OnRegister = recordUserLogin
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
	recordServerStart()

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

// Current server generation, set by recordServerStart().
var currentGeneration int
var serverStartTime time.Time



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

func handleServerSettings(w http.ResponseWriter, r *http.Request) {
	respond.Success(w, map[string]interface{}{
		"generation": currentGeneration,
	})
}

func recordServerStart() {
	serverStartTime = time.Now()
	result, err := DB.Exec(
		`INSERT INTO server_sessions (started_at, git_commit) VALUES (?, ?)`,
		serverStartTime.Format(time.RFC3339), gitCommit)
	if err != nil {
		log.Printf("Failed to record server start: %v", err)
		return
	}
	gen, _ := result.LastInsertId()
	currentGeneration = int(gen)
	log.Printf("Server generation: %d", currentGeneration)
}

func recordUserLogin(userID int) {
	DB.Exec(`INSERT INTO user_sessions (user_id, generation, logged_in_at) VALUES (?, ?, ?)`,
		userID, currentGeneration, time.Now().Format(time.RFC3339))
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
