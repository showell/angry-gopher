// Per-user Images transcript — every message-with-images the viewer can
// see (across all their conversations + sessions) collected into one
// forward-chronological feed (oldest first; new entries append at the
// bottom).
//
// Storage:
//   {ChatDataRoot}/users/<uid>/images.md
//
// Each on-disk entry follows the chat-transcript format pattern (text +
// "\n-------------\n" separators), so the file is human-readable. Header
// line names sender, timestamp, source MSG_<sid>_<n>, and conv; image
// tag(s) follow on subsequent lines.
//
//   Sent by apoorva at 2026-05-29T01:56:58Z, source MSG_obsidianweb_42 in 1_2:
//   <img src="..." alt="...">
//   -------------
//   Sent by Steve at 2026-05-30T14:46:10Z, source MSG_general1_5 in 1_2:
//   <img src="...">
//   <img src="...">
//
// Write path: AppendChatMessage calls PublishChatImage on every message;
// if the body contains <img> tags, the entry appends to BOTH conv
// participants' images.md and an SSE event publishes to any live viewer.
//
// Read path: page render reads the file, splits on separator, emits in
// on-disk order (oldest first).

package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// PRODUCT_DECISION: capture every <img ...> tag (case-insensitive). All
// images currently land in bodies as raw HTML (compose's insertAtCursor
// pastes <img src="..." alt="..." ...> after upload); markdown's
// ![alt](url) would render to the same shape via goldmark.
var imageTagRe = regexp.MustCompile(`(?is)<img\s[^>]*>`)

const imagesSep = "\n\n-------------\n\n"

type imagesEntry struct {
	SourceID string   // e.g. "obsidianweb_42"
	From     string
	Conv     string
	At       time.Time // chronological order of source message
	Images   []string  // raw <img ...> tags
}

func userImagesPath(uid string) string {
	return filepath.Join(ChatDataRoot, "users", uid, "images.md")
}

// formatImagesEntry serializes an entry to its on-disk text form (no
// leading or trailing separator — caller joins with imagesSep). The
// header line carries all metadata; rendering composes the visual
// 3-line header from these fields.
func formatImagesEntry(e imagesEntry) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Sent by %s at %s, source MSG_%s in %s:\n",
		e.From, e.At.UTC().Format(time.RFC3339), e.SourceID, e.Conv)
	for _, tag := range e.Images {
		b.WriteString(tag)
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// parseImagesFile splits a images.md file into entries in on-disk
// (chronological) order.
func parseImagesFile(text string) []imagesEntry {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	blocks := strings.Split(text, imagesSep)
	out := make([]imagesEntry, 0, len(blocks))
	headerRe := regexp.MustCompile(`^Sent by (.+) at (\S+), source MSG_(\S+) in (\S+):$`)
	for _, block := range blocks {
		block = strings.TrimSpace(block)
		if block == "" {
			continue
		}
		lines := strings.Split(block, "\n")
		if len(lines) == 0 {
			continue
		}
		m := headerRe.FindStringSubmatch(lines[0])
		if m == nil {
			continue // malformed entry, skip
		}
		at, _ := time.Parse(time.RFC3339, m[2])
		out = append(out, imagesEntry{
			SourceID: m[3],
			From:     m[1],
			Conv:     m[4],
			At:       at,
			Images:   imageTagRe.FindAllString(strings.Join(lines[1:], "\n"), -1),
		})
	}
	return out
}

// appendImagesEntryLocked writes one entry to a user's images.md, with the
// separator if the file is non-empty. Caller must hold imagesMu for the uid.
func appendImagesEntryLocked(uid string, e imagesEntry) error {
	path := userImagesPath(uid)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if len(existing) > 0 {
		if _, err := f.WriteString(imagesSep); err != nil {
			return err
		}
	}
	if _, err := f.WriteString(formatImagesEntry(e)); err != nil {
		return err
	}
	return nil
}

// PublishChatImage fans an image-bearing chat message out to BOTH conv
// participants' images.md files + their live SSE streams. Called from
// AppendChatMessage when the body contains <img ...> tags. Lock order:
// chatMu (held) → imagesMu (per-user, leaf).
func PublishChatImage(conv, sid string, msg ChatMessage) {
	tags := imageTagRe.FindAllString(msg.Body, -1)
	if len(tags) == 0 {
		return
	}
	a, b, ok := strings.Cut(conv, "_")
	if !ok || a == "" || b == "" {
		return
	}
	e := imagesEntry{
		SourceID: msg.ID,
		From:     msg.From,
		Conv:     conv,
		At:       msg.At,
		Images:   tags,
	}
	for _, uid := range []string{a, b} {
		mu := imagesMuFor(uid)
		mu.Lock()
		if err := appendImagesEntryLocked(uid, e); err != nil {
			mu.Unlock()
			continue
		}
		mu.Unlock()
		publishImages(uid, imagesSSEEvent{
			SourceID: e.SourceID,
			From:     e.From,
			Conv:     e.Conv,
			At:       e.At,
			Images:   e.Images,
		})
	}
}

// HandleImages serves /chat/images: the chrome + the per-user image
// transcript, newest first. Triggers lazy migration on first request.
func HandleImages(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat/images" {
		http.NotFound(w, r)
		return
	}
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape("/chat/images"), http.StatusSeeOther)
		return
	}
	user := users.CurrentUser(r)
	entries, err := readImagesForUser(user.ID)
	if err != nil {
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	chatPageHeader(w, "Images", user, "images")
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)
	fmt.Fprint(w, imagesCSS)
	fmt.Fprint(w, ImagePopupCSS)
	renderImagesList(w, entries)
	fmt.Fprintf(w,
		`<script src="/chat/chat_image_popup.js?v=%s"></script>`+
			`<script src="/chat/images.js?v=%s"></script>`+
			`<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion))
	web.PageFooter(w)
}

func readImagesForUser(uid string) ([]imagesEntry, error) {
	mu := imagesMuFor(uid)
	mu.Lock()
	defer mu.Unlock()
	path := userImagesPath(uid)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return parseImagesFile(string(data)), nil
}

const imagesCSS = `<style>
/* PRODUCT_DECISION: 600px cap matches chat-main, so images render at the
   same widths the user remembers from the feed (natural aspect ratio,
   height-capped at 320px). */
.images-list { list-style: none; padding: 0; margin: 0 auto; max-width: 600px; }
.images-entry { margin: 0 0 28px 0; padding: 14px 16px; border: 1px solid #e0e0e0; border-radius: 6px; background: #fafafa; }
.images-entry-meta { font-size: 15px; color: #333; margin-bottom: 10px; line-height: 1.5; }
.images-entry-meta-line { margin: 1px 0; }
.images-entry-meta a { color: #333; text-decoration: none; }
.images-entry-meta a:hover { text-decoration: underline; }
.images-entry-meta-from { font-weight: 600; }
.images-entry-imgs img { max-width: 100%; max-height: 320px; width: auto; height: auto;
                         display: block; margin: 6px 0; border-radius: 6px; cursor: zoom-in; }
</style>`

// renderImagesList emits the page body in forward-chronological order
// (oldest first, matching the on-disk order). Each <li> carries a
// data-source-id so SSE upserts can append at the bottom without
// rebuilding the whole list.
func renderImagesList(w http.ResponseWriter, entries []imagesEntry) {
	fmt.Fprint(w, `<ul class="images-list" id="images-list"`)
	if len(entries) == 0 {
		fmt.Fprint(w, ` hidden`)
	}
	fmt.Fprint(w, `>`)
	for _, e := range entries {
		writeImagesEntry(w, e)
	}
	fmt.Fprint(w, `</ul>`)
	if len(entries) == 0 {
		fmt.Fprint(w, `<p class="muted" id="images-empty">No images yet.</p>`)
	}
}

func writeImagesEntry(w http.ResponseWriter, e imagesEntry) {
	// Split "<sid>_<n>" → session + index for the deep-link.
	sid, _, ok := splitMsgID(e.SourceID)
	href := "/chat/c/" + e.Conv
	if ok {
		href += "/" + url.PathEscape(sid) + "#msg-" + e.SourceID
	}
	when := e.At.UTC().Format("January 2, 2006 15:04")
	fmt.Fprintf(w,
		`<li class="images-entry" data-source-id="%s"`+
			`><div class="images-entry-meta">`+
			`<div class="images-entry-meta-line"><span class="images-entry-meta-from">Sent by %s</span></div>`+
			`<div class="images-entry-meta-line">%s</div>`+
			`<div class="images-entry-meta-line">From <a href="%s">MSG_%s</a></div>`+
			`</div><div class="images-entry-imgs">`,
		html.EscapeString(e.SourceID),
		html.EscapeString(e.From),
		html.EscapeString(when),
		href, html.EscapeString(e.SourceID))
	for _, tag := range e.Images {
		fmt.Fprint(w, tag)
	}
	fmt.Fprint(w, `</div></li>`)
}

func splitMsgID(msgID string) (sid string, n string, ok bool) {
	cut := strings.LastIndex(msgID, "_")
	if cut <= 0 {
		return "", "", false
	}
	return msgID[:cut], msgID[cut+1:], true
}

// imagesSSEEvent is one image-bearing message ping pushed to a single
// viewer. Encoded as JSON; the client renders the row from these fields.
type imagesSSEEvent struct {
	SourceID string    `json:"source_id"`
	From     string    `json:"from"`
	Conv     string    `json:"conv"`
	At       time.Time `json:"at"`
	Images   []string  `json:"images"`
}

var (
	imagesSubsMu sync.Mutex
	imagesSubs   = map[string]map[chan imagesSSEEvent]struct{}{}
	// Per-user file mutex so the migration walk and live appends serialize.
	imagesFileMu      sync.Mutex
	imagesFileMutexes = map[string]*sync.Mutex{}
)

func imagesMuFor(uid string) *sync.Mutex {
	imagesFileMu.Lock()
	defer imagesFileMu.Unlock()
	mu, ok := imagesFileMutexes[uid]
	if !ok {
		mu = &sync.Mutex{}
		imagesFileMutexes[uid] = mu
	}
	return mu
}

func publishImages(uid string, evt imagesSSEEvent) {
	imagesSubsMu.Lock()
	defer imagesSubsMu.Unlock()
	for ch := range imagesSubs[uid] {
		select {
		case ch <- evt:
		default:
		}
	}
}

func openImages(uid string) (<-chan imagesSSEEvent, func()) {
	ch := make(chan imagesSSEEvent, 16)
	imagesSubsMu.Lock()
	if imagesSubs[uid] == nil {
		imagesSubs[uid] = map[chan imagesSSEEvent]struct{}{}
	}
	imagesSubs[uid][ch] = struct{}{}
	imagesSubsMu.Unlock()
	return ch, func() {
		imagesSubsMu.Lock()
		defer imagesSubsMu.Unlock()
		if subs := imagesSubs[uid]; subs != nil {
			if _, ok := subs[ch]; ok {
				delete(subs, ch)
				close(ch)
			}
			if len(subs) == 0 {
				delete(imagesSubs, uid)
			}
		}
	}
}

// HandleImagesStream is the per-user SSE stream for live image entries
// (GET /chat/images/stream). Mirrors HandleRecentStream — live-only, no
// backlog, 25s ping keepalive.
func HandleImagesStream(w http.ResponseWriter, r *http.Request) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	ch, cancel := openImages(user.ID)
	defer cancel()

	if _, err := fmt.Fprint(w, ": ok\n\n"); err != nil {
		return
	}
	if rc.Flush() != nil {
		return
	}

	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case evt, ok := <-ch:
			if !ok {
				return
			}
			blob, err := json.Marshal(evt)
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", blob); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if rc.Flush() != nil {
				return
			}
		}
	}
}

// ImagesJSPath is the embedded Images-page client.
var ImagesJSPath = "chat/images.js"

// HandleImagesJS serves the Images-page client.
func HandleImagesJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, ImagesJSPath, "images.js missing from the binary")
}
