// Chat image uploads. POST /chat/c/<conv>/<sid>/upload stores an image in
// that session's uploads sidecar (sessions/<sid>.uploads/) under a random
// unguessable name (extension derived from sniffed magic bytes, never the
// client's filename) and returns the path-style URL
// /chat/c/<conv>/<sid>/uploads/<file>. GET on that URL serves it, enforcing
// that the requester is a participant of the conversation — so image access
// matches message access.
package chat

import (
	"angry-gopher/server/users"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"  // register the gif decoder for image.DecodeConfig
	_ "image/jpeg" // register the jpeg decoder
	_ "image/png"  // register the png decoder
	"io"
	"net/http"
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

// HandleChatUpload accepts one image for /chat/c/<conv>/<sid>.
func HandleChatUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, conv, sessionID, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	partner, _ := OtherInConv(user.ID, conv)
	serveUpload(w, r, user, DMConv(user.ID, partner), sessionID)
}

// HandleChannelUpload accepts one image for /channel/<name>/<topic>.
func HandleChannelUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	serveUpload(w, r, user, c, sid)
}

// serveUpload is the shared image-upload path used by DM and channel
// uploads. Validates type + size, reserves the user's lifetime quota,
// writes to the conv's UploadsDir, returns the URL + dimensions.
func serveUpload(w http.ResponseWriter, r *http.Request, user users.User, c Conv, sid string) {
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
	dir := c.UploadsDir(sid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		http.Error(w, "mkdir: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Decode pixel dimensions from the header bytes (no full-image alloc).
	// Width+height let the client write an <img width=H height=W> tag whose
	// aspect-ratio reserves layout space while the image decodes, killing
	// the "scroll lands too high" jank on initial chat load.
	width, height := 0, 0
	if cfg, _, derr := image.DecodeConfig(bytes.NewReader(data)); derr == nil {
		width, height = cfg.Width, cfg.Height
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"url":    c.topicURL(sid) + "/uploads/" + name,
		"name":   header.Filename,
		"width":  width,
		"height": height,
	})
}

// HandleChatFile serves an uploaded image at
// /chat/c/<conv>/<sid>/uploads/<filename>.
func HandleChatFile(w http.ResponseWriter, r *http.Request) {
	_, conv, sessionID, ok := chatPathSession(w, r)
	if !ok {
		return
	}
	user := users.CurrentUser(r)
	partner, _ := OtherInConv(user.ID, conv)
	serveUploadedFile(w, r, DMConv(user.ID, partner), sessionID)
}

// HandleChannelFile serves an uploaded image at
// /channel/<name>/<topic>/uploads/<file>.
func HandleChannelFile(w http.ResponseWriter, r *http.Request) {
	_, c, sid, ok := channelPathTopic(w, r)
	if !ok {
		return
	}
	serveUploadedFile(w, r, c, sid)
}

func serveUploadedFile(w http.ResponseWriter, r *http.Request, c Conv, sid string) {
	name := r.PathValue("file")
	if !chatUploadName.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	ext := name[strings.LastIndexByte(name, '.')+1:]
	w.Header().Set("Content-Type", chatImageContentType[ext])
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeFile(w, r, filepath.Join(c.UploadsDir(sid), name))
}
