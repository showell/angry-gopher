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
	"angry-gopher/messages"
	"angry-gopher/reactions"
	"angry-gopher/respond"
	"angry-gopher/users"
)

const listenAddr = ":9000"

func main() {
	initDB("angry_gopher.db")

	// Wire up package-level DB references.
	auth.DB = DB
	users.DB = DB
	channels.DB = DB
	messages.DB = DB
	flags.DB = DB
	reactions.DB = DB

	// Wire up markdown rendering to avoid circular imports.
	channels.RenderMarkdown = renderMarkdown
	messages.RenderMarkdown = renderMarkdown

	// API endpoints.
	http.HandleFunc("/api/v1/register", withCORS(events.HandleRegister))
	http.HandleFunc("/api/v1/events", withCORS(events.HandleEvents))
	http.HandleFunc("/api/v1/users", withCORS(users.HandleUsers))
	http.HandleFunc("/api/v1/users/me/subscriptions", withCORS(channels.HandleSubscriptions))
	http.HandleFunc("/api/v1/messages", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			messages.HandleGetMessages(w, r)
		case "POST":
			messages.HandleSendMessage(w, r)
		default:
			respond.Error(w, "Method not allowed")
		}
	}))
	http.HandleFunc("/api/v1/messages/flags", withCORS(flags.HandleUpdateFlags))
	// Routes under /api/v1/messages/ need a dispatcher since Go's
	// default mux matches by longest prefix. Paths like
	// /api/v1/messages/123/reactions land here.
	http.HandleFunc("/api/v1/messages/", withCORS(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/reactions") {
			reactions.HandleReaction(w, r)
		} else if r.Method == "PATCH" {
			messages.HandleEditMessage(w, r)
		} else {
			respond.Error(w, "Unknown messages sub-endpoint")
		}
	}))
	http.HandleFunc("/api/v1/streams/", withCORS(channels.HandleUpdateChannel))

	// File uploads.
	http.HandleFunc("/api/v1/user_uploads", withCORS(handleUpload))
	http.HandleFunc("/api/v1/user_uploads/", withCORS(handleUploadTempURL))
	http.HandleFunc("/user_uploads/", withCORS(handleServeUpload))

	// Admin UI.
	http.HandleFunc("/admin/", adminHandler)

	// Catch-all for unimplemented endpoints.
	http.HandleFunc("/", withCORS(handleUnimplemented))

	fmt.Printf("Angry Gopher listening on %s\n", listenAddr)
	fmt.Printf("Admin UI at http://localhost%s/admin/\n", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
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
		handler(w, r)
	}
}
