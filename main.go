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

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/events"
	"angry-gopher/flags"
	"angry-gopher/invites"
	"angry-gopher/messages"
	"angry-gopher/presence"
	"angry-gopher/ratelimit"
	"angry-gopher/reactions"
	"angry-gopher/respond"
	"angry-gopher/users"
)

const listenAddr = ":9000"

func buildMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/v1/register", withCORS(events.HandleRegister))
	mux.HandleFunc("/api/v1/events", withCORS(events.HandleEvents))
	mux.HandleFunc("/api/v1/users", withCORS(users.HandleUsers))
	mux.HandleFunc("/api/v1/users/me/subscriptions", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			channels.HandleSubscriptions(w, r)
		case "POST":
			channels.HandleCreateChannel(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	mux.HandleFunc("/api/v1/messages", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			messages.HandleGetMessages(w, r)
		case "POST":
			messages.HandleSendMessage(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	mux.HandleFunc("/api/v1/messages/flags", withCORS(flags.HandleUpdateFlags))
	mux.HandleFunc("/api/v1/messages/", withCORS(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/reactions") {
			reactions.HandleReaction(w, r)
		} else if r.Method == "PATCH" {
			messages.HandleEditMessage(w, r)
		} else {
			respond.Error(w, "Unknown messages sub-endpoint")
		}
	}))
	mux.HandleFunc("/api/v1/streams/", withCORS(channels.HandleUpdateChannel))
	mux.HandleFunc("/api/v1/invites", withCORS(invites.HandleCreateInvite))
	mux.HandleFunc("/api/v1/invites/redeem", withCORS(invites.HandleRedeemInvite))
	mux.HandleFunc("/api/v1/users/me/presence", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "POST":
			presence.HandleUpdatePresence(w, r)
		case "GET":
			presence.HandleGetPresence(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))

	mux.HandleFunc("/api/v1/user_uploads", withCORS(handleUpload))
	mux.HandleFunc("/api/v1/user_uploads/", withCORS(handleUploadTempURL))
	mux.HandleFunc("/user_uploads/", withCORS(handleServeUpload))
	mux.HandleFunc("/admin/", adminHandler)
	mux.HandleFunc("/", withCORS(handleUnimplemented))

	return mux
}

func main() {
	initDB("angry_gopher.db")

	auth.DB = DB
	users.DB = DB
	channels.DB = DB
	messages.DB = DB
	flags.DB = DB
	reactions.DB = DB
	invites.DB = DB

	channels.RenderMarkdown = renderMarkdown
	messages.RenderMarkdown = renderMarkdown

	seedData(true)

	mux := buildMux()

	fmt.Printf("Angry Gopher listening on %s\n", listenAddr)
	fmt.Printf("Admin UI at http://localhost%s/admin/\n", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}

// --- File uploads ---

var uploadsDir = filepath.Join(os.Getenv("HOME"), "AngryGopherImages")

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

func withCORS(handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
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
