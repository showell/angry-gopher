// Chat image uploads. POST /chat/upload?with=<partner> stores an image
// in that conversation's uploads/ dir under a random unguessable name
// (extension derived from sniffed magic bytes, never the client's
// filename) and returns a viewer-independent URL that embeds the
// conversation key. GET /chat/uploads/<key>/<file> serves it, enforcing
// that the requester is a participant of that conversation — so image
// access matches message access.
package chat

import (
	"angry-gopher/server/users"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// maxChatUploadBytes caps a single uploaded image. Caddy's per-route body
// cap (deploy/Caddyfile) must stay at or above this so Gopher is the one
// that enforces it, with a clean message. The cumulative per-user cap is
// users.MaxUploadLifetimeBytes (a user-layer limit).
const maxChatUploadBytes = 10 << 20 // 10 MiB

// chatUploadName is the strict on-disk/served filename: 32 hex chars
// (our random token) plus an allowed image extension. Used to reject
// anything hand-crafted on the serving path.
var chatUploadName = regexp.MustCompile(`^[a-f0-9]{32}\.(png|jpg|gif|webp)$`)

// chatImageContentType maps our extensions back to a Content-Type.
var chatImageContentType = map[string]string{
	"png":  "image/png",
	"jpg":  "image/jpeg",
	"gif":  "image/gif",
	"webp": "image/webp",
}

// detectImageExt sniffs the magic bytes of the four allowed image types
// and returns our canonical extension. We sniff explicitly rather than
// trust the client's Content-Type or filename (and http.DetectContentType
// doesn't reliably cover webp).
func detectImageExt(data []byte) (string, bool) {
	switch {
	case len(data) >= 8 && bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "png", true
	case len(data) >= 3 && bytes.HasPrefix(data, []byte("\xff\xd8\xff")):
		return "jpg", true
	case len(data) >= 6 && (bytes.HasPrefix(data, []byte("GIF87a")) || bytes.HasPrefix(data, []byte("GIF89a"))):
		return "gif", true
	case len(data) >= 12 && bytes.HasPrefix(data, []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")):
		return "webp", true
	}
	return "", false
}

func randUploadToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// HandleChatUpload accepts one image for the conversation with ?with=,
// stores it, and returns {"url":...,"name":...} as JSON.
func HandleChatUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !users.IsMember(r) {
		http.Error(w, "chat requires a member account", http.StatusForbidden)
		return
	}
	user := users.CurrentUser(r)
	partner := strings.TrimSpace(r.URL.Query().Get("with")) // partner user id
	if !validChatPartner(user.ID, partner) {
		http.Error(w, "unknown conversation partner", http.StatusBadRequest)
		return
	}

	// Cap the body (with a little slack for multipart framing); enforce
	// the real image-size limit on the decoded bytes below.
	r.Body = http.MaxBytesReader(w, r.Body, maxChatUploadBytes+1<<20)
	file, header, err := r.FormFile("file")
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "Image too large — the limit is 10 MB.", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "no file", http.StatusBadRequest)
		return
	}
	defer file.Close()

	data, err := io.ReadAll(file)
	if err != nil {
		http.Error(w, "read upload: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(data) > maxChatUploadBytes {
		http.Error(w, "Image too large — the limit is 10 MB.", http.StatusRequestEntityTooLarge)
		return
	}
	ext, ok := detectImageExt(data)
	if !ok {
		http.Error(w, "unsupported image type (png, jpeg, gif, webp only)", http.StatusUnsupportedMediaType)
		return
	}

	// Lifetime per-user upload backstop (reserve before storing).
	if !users.ReserveUploadBytes(user.ID, int64(len(data)), users.MaxUploadLifetimeBytes) {
		http.Error(w, fmt.Sprintf("Upload limit reached — you've used your %d GB image allowance.",
			users.MaxUploadLifetimeBytes>>30), http.StatusForbidden)
		return
	}

	token, err := randUploadToken()
	if err != nil {
		http.Error(w, "token: "+err.Error(), http.StatusInternalServerError)
		return
	}
	name := token + "." + ext
	dir := chatUploadsDir(user.ID, partner)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		http.Error(w, "mkdir: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}

	key := chatPairKey(user.ID, partner)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"url":  "/chat/uploads/" + url.PathEscape(key) + "/" + name,
		"name": header.Filename,
	})
}

// HandleChatFile serves an uploaded image, gated to participants of the
// conversation named in the URL.
func HandleChatFile(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	rest := strings.TrimPrefix(r.URL.Path, "/chat/uploads/")
	key, name, found := strings.Cut(rest, "/")
	if !found || !chatUploadName.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	if !ChatKeyParticipant(key, user.ID) {
		http.NotFound(w, r) // don't reveal whether it exists
		return
	}
	ext := name[strings.LastIndexByte(name, '.')+1:]
	w.Header().Set("Content-Type", chatImageContentType[ext])
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeFile(w, r, filepath.Join(ChatUploadsDirForKey(key), name))
}
