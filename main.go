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
)

const listenAddr = ":9000"

func main() {
	initDB("angry_gopher.db")

	// API endpoints served from SQLite.
	http.HandleFunc("/api/v1/register", withCORS(handleRegister))
	http.HandleFunc("/api/v1/events", withCORS(handleEvents))
	http.HandleFunc("/api/v1/users", withCORS(handleUsers))
	http.HandleFunc("/api/v1/users/me/subscriptions", withCORS(handleSubscriptions))
	http.HandleFunc("/api/v1/messages", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			handleMessages(w, r)
		case "POST":
			handleSendMessage(w, r)
		default:
			writeJSON(w, errorResponse("Method not allowed"))
		}
	}))
	http.HandleFunc("/api/v1/messages/flags", withCORS(handleUpdateFlags))
	http.HandleFunc("/api/v1/streams/", withCORS(handleUpdateChannel))

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

var uploadsDir = filepath.Join(os.Getenv("HOME"), "AngryGopherImages")

var (
	nextUploadID   int
	nextUploadIDMu sync.Mutex
)

// POST /api/v1/user_uploads — accept a multipart file upload, save it
// to ~/AngryGopherImages/<id>/<filename>, return the URI.
func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeJSON(w, errorResponse("Method not allowed"))
		return
	}

	file, header, err := r.FormFile("FILE")
	if err != nil {
		writeJSON(w, errorResponse("Missing FILE field: "+err.Error()))
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
		writeJSON(w, errorResponse("Failed to save file: "+err.Error()))
		return
	}
	defer dst.Close()
	io.Copy(dst, file)

	uri := fmt.Sprintf("/user_uploads/%d/%s", id, header.Filename)
	log.Printf("[api] Uploaded %s (%d bytes)", uri, header.Size)

	writeJSON(w, map[string]interface{}{
		"result": "success",
		"msg":    "",
		"uri":    uri,
	})
}

// GET /api/v1/user_uploads/<id>/<filename> — Angry Cat calls this to
// get a "temporary" URL for an upload. We just return the direct path.
func handleUploadTempURL(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")
	writeJSON(w, map[string]interface{}{
		"result": "success",
		"msg":    "",
		"url":    path,
	})
}

// GET /user_uploads/<id>/<filename> — serve the file from disk.
func handleServeUpload(w http.ResponseWriter, r *http.Request) {
	rel := strings.TrimPrefix(r.URL.Path, "/user_uploads/")
	filePath := filepath.Join(uploadsDir, rel)

	// Prevent directory traversal.
	if strings.Contains(rel, "..") {
		http.NotFound(w, r)
		return
	}

	http.ServeFile(w, r, filePath)
}

func handleUnimplemented(w http.ResponseWriter, r *http.Request) {
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}
	log.Printf("[unimplemented] %s %s", r.Method, r.URL.Path)
	writeJSON(w, map[string]interface{}{
		"result": "error",
		"msg":    fmt.Sprintf("Endpoint not implemented: %s %s", r.Method, r.URL.Path),
	})
}

// withCORS wraps a handler to add CORS headers and handle preflight.
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
