// Per-user Code transcript — every message-with-code-blocks the viewer
// can see, across all their conversations + sessions, collected into one
// forward-chronological feed (oldest first; new entries append at the
// bottom). Mirrors images.go in shape.
//
// Storage:
//   {ChatDataRoot}/users/<uid>/code.md
//
// On-disk entry uses the chat-transcript header pattern; the captured
// code blocks are stored verbatim as triple-backtick fenced sections.
//
//   Sent by apoorva at 2026-05-29T01:56:58Z, source MSG_obsidianweb_42 in 1_2:
//   ```python
//   def foo():
//       return 1
//   ```
//   -------------
//   Sent by Steve at 2026-05-30T14:46:10Z, source MSG_general1_5 in 1_2:
//   ```rust
//   fn main() {}
//   ```
//
// Write path: AppendChatMessage calls PublishChatCode on every message;
// if the body contains triple-backtick fenced code blocks, the entry
// appends to BOTH conv participants' code.md and an SSE event publishes
// to any live viewer. Read path: page render reads the file, splits on
// separator, emits in on-disk order (oldest first).
//
// PRODUCT_DECISION: only triple-backtick fences count. `~~~` is the
// quote-reply marker in this codebase; including it would drag every
// quote-replied message into the Code feed.

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

const codeSep = "\n\n-------------\n\n"

type codeBlock struct {
	Lang string
	Body string
}

type codeEntry struct {
	SourceID string
	From     string
	Conv     string
	At       time.Time
	Blocks   []codeBlock
}

func userCodePath(uid string) string {
	return filepath.Join(ChatDataRoot, "users", uid, "code.md")
}

// extractCodeBlocks walks `body` line by line, tracking fence state.
//
// PRODUCT_DECISION: line-based walker, not a regex. Fences are line-anchored
// (must start at column 0); open/close pairing is a state machine, not a
// pattern. Naturally handles unclosed fences (content extends to end-of-body,
// matching goldmark's rendering) and quote-reply skip (state, not pattern).
//
// PRODUCT_DECISION: tilde fences are included EXCEPT `~~~ quote` (the
// quote-reply marker). Steve sometimes types `~~~ go` or `~~~ python`
// to introduce a code block; those count too.
//
// PRODUCT_DECISION: per CommonMark, a closing fence is the marker char(s)
// only — info text is NOT allowed on the close. So `~~~quote` (info text
// "quote") is NOT a closing fence; it's content. This matters for a
// `~~~ quote\n~~~quote\n...\n~~~\n` quote-of-a-quote pattern, where the
// outer fence's body legitimately contains a line starting with `~~~`.
func extractCodeBlocks(body string) []codeBlock {
	var out []codeBlock
	lines := strings.Split(body, "\n")
	i := 0
	for i < len(lines) {
		line := lines[i]
		var markerChar byte
		var lang string
		switch {
		case strings.HasPrefix(line, "```"):
			markerChar = '`'
			lang = strings.TrimSpace(line[3:])
		case strings.HasPrefix(line, "~~~"):
			markerChar = '~'
			lang = strings.TrimSpace(line[3:])
		default:
			i++
			continue
		}
		isQuote := markerChar == '~' && lang == "quote"
		start := i + 1
		j := start
		if isQuote {
			// Nesting-aware close: handles `~~~ quote\n~~~quote\n...\n~~~\n...\n~~~`.
			depth := 1
			for j < len(lines) {
				if isCloseFence(lines[j], markerChar) {
					depth--
					if depth == 0 {
						break
					}
				} else if strings.HasPrefix(lines[j], "~~~") {
					depth++
				}
				j++
			}
		} else {
			for j < len(lines) && !isCloseFence(lines[j], markerChar) {
				j++
			}
		}
		if !isQuote {
			content := strings.Join(lines[start:j], "\n")
			out = append(out, codeBlock{Lang: lang, Body: content})
		}
		i = j + 1
	}
	return out
}

func isCloseFence(line string, markerChar byte) bool {
	stripped := strings.TrimRight(line, " \t")
	if len(stripped) < 3 {
		return false
	}
	for i := 0; i < len(stripped); i++ {
		if stripped[i] != markerChar {
			return false
		}
	}
	return true
}

func formatCodeEntry(e codeEntry) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Sent by %s at %s, source MSG_%s in %s:\n",
		e.From, e.At.UTC().Format(time.RFC3339), e.SourceID, e.Conv)
	for i, blk := range e.Blocks {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString("```")
		b.WriteString(blk.Lang)
		b.WriteString("\n")
		b.WriteString(blk.Body)
		b.WriteString("\n```")
	}
	return b.String()
}

func parseCodeFile(text string) []codeEntry {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	blocks := strings.Split(text, codeSep)
	out := make([]codeEntry, 0, len(blocks))
	headerRe := regexp.MustCompile(`^Sent by (.+) at (\S+), source MSG_(\S+) in (\S+):$`)
	for _, block := range blocks {
		block = strings.TrimSpace(block)
		if block == "" {
			continue
		}
		nl := strings.Index(block, "\n")
		if nl < 0 {
			continue
		}
		m := headerRe.FindStringSubmatch(block[:nl])
		if m == nil {
			continue
		}
		at, _ := time.Parse(time.RFC3339, m[2])
		blocks := extractCodeBlocks(block[nl+1:])
		if len(blocks) == 0 {
			continue
		}
		out = append(out, codeEntry{
			SourceID: m[3],
			From:     m[1],
			Conv:     m[4],
			At:       at,
			Blocks:   blocks,
		})
	}
	return out
}

func appendCodeEntryLocked(uid string, e codeEntry) error {
	path := userCodePath(uid)
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
		if _, err := f.WriteString(codeSep); err != nil {
			return err
		}
	}
	if _, err := f.WriteString(formatCodeEntry(e)); err != nil {
		return err
	}
	return nil
}

// PublishChatCode fans a code-bearing chat message out to BOTH conv
// participants' code.md files + their live SSE streams. Called from
// AppendChatMessage when the body contains ``` fenced blocks. Lock
// order: chatMu (held) → codeFileMu (per-user, leaf).
func PublishChatCode(conv, sid string, msg ChatMessage) {
	blocks := extractCodeBlocks(msg.Body)
	if len(blocks) == 0 {
		return
	}
	a, b, ok := strings.Cut(conv, "_")
	if !ok || a == "" || b == "" {
		return
	}
	e := codeEntry{
		SourceID: msg.ID,
		From:     msg.From,
		Conv:     conv,
		At:       msg.At,
		Blocks:   blocks,
	}
	for _, uid := range []string{a, b} {
		mu := codeMuFor(uid)
		mu.Lock()
		if err := appendCodeEntryLocked(uid, e); err != nil {
			mu.Unlock()
			continue
		}
		mu.Unlock()
		publishCode(uid, codeSSEEvent{
			SourceID: e.SourceID,
			From:     e.From,
			Conv:     e.Conv,
			At:       e.At,
			Blocks:   blocksToWire(e.Blocks),
		})
	}
}

type codeBlockWire struct {
	Lang string `json:"lang"`
	Body string `json:"body"`
}

func blocksToWire(blks []codeBlock) []codeBlockWire {
	out := make([]codeBlockWire, len(blks))
	for i, blk := range blks {
		out[i] = codeBlockWire{Lang: blk.Lang, Body: blk.Body}
	}
	return out
}

// HandleCode serves /chat/code: the chrome + the per-user code transcript.
func HandleCode(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat/code" {
		http.NotFound(w, r)
		return
	}
	if !users.IsAuthorized(r) {
		http.Redirect(w, r, "/login/full?next="+url.QueryEscape("/chat/code"), http.StatusSeeOther)
		return
	}
	user := users.CurrentUser(r)
	entries, err := readCodeForUser(user.ID)
	if err != nil {
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	chatPageHeader(w, "Code", user, "code")
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)
	fmt.Fprint(w, codeCSS)
	renderCodeList(w, entries)
	fmt.Fprintf(w,
		`<script src="/chat/chat_code_popup.js?v=%s"></script>`+
			`<script src="/chat/code.js?v=%s"></script>`+
			`<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion), url.QueryEscape(web.AssetVersion))
	web.PageFooter(w)
}

func readCodeForUser(uid string) ([]codeEntry, error) {
	mu := codeMuFor(uid)
	mu.Lock()
	defer mu.Unlock()
	path := userCodePath(uid)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return parseCodeFile(string(data)), nil
}

const codeCSS = `<style>
/* PRODUCT_DECISION: 600px cap matches chat-main + Images, so code reads at
   the same width the user remembers from the feed. */
.code-list { list-style: none; padding: 0; margin: 0 auto; max-width: 600px; }
.code-entry { margin: 0 0 28px 0; padding: 14px 16px; border: 1px solid #e0e0e0; border-radius: 6px; background: #fafafa; }
.code-entry-meta { font-size: 15px; color: #333; margin-bottom: 10px; line-height: 1.5; }
.code-entry-meta-line { margin: 1px 0; }
.code-entry-meta a { color: #333; text-decoration: none; }
.code-entry-meta a:hover { text-decoration: underline; }
.code-entry-meta-from { font-weight: 600; }
.code-block { margin: 8px 0; border: 1px solid #ddd; border-radius: 6px; overflow: hidden; background: #fff; }
.code-block-lang { font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em;
                   color: #888; padding: 4px 12px; background: #faf9f5; border-bottom: 1px solid #eee; }
.code-block pre { margin: 0; padding: 10px 14px; max-height: 360px; overflow: auto;
                  font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 13px;
                  line-height: 1.45; color: #222; cursor: zoom-in; }
</style>`

func renderCodeList(w http.ResponseWriter, entries []codeEntry) {
	fmt.Fprint(w, `<ul class="code-list" id="code-list"`)
	if len(entries) == 0 {
		fmt.Fprint(w, ` hidden`)
	}
	fmt.Fprint(w, `>`)
	for _, e := range entries {
		writeCodeEntry(w, e)
	}
	fmt.Fprint(w, `</ul>`)
	if len(entries) == 0 {
		fmt.Fprint(w, `<p class="muted" id="code-empty">No code blocks yet.</p>`)
	}
}

func writeCodeEntry(w http.ResponseWriter, e codeEntry) {
	sid, _, ok := splitMsgID(e.SourceID)
	href := "/chat/c/" + e.Conv
	if ok {
		href += "/" + url.PathEscape(sid) + "#msg-" + e.SourceID
	}
	when := e.At.UTC().Format("January 2, 2006 15:04")
	fmt.Fprintf(w,
		`<li class="code-entry" data-source-id="%s"`+
			`><div class="code-entry-meta">`+
			`<div class="code-entry-meta-line"><span class="code-entry-meta-from">Sent by %s</span></div>`+
			`<div class="code-entry-meta-line">%s</div>`+
			`<div class="code-entry-meta-line">From <a href="%s">MSG_%s</a></div>`+
			`</div>`,
		html.EscapeString(e.SourceID),
		html.EscapeString(e.From),
		html.EscapeString(when),
		href, html.EscapeString(e.SourceID))
	for _, blk := range e.Blocks {
		writeCodeBlock(w, blk)
	}
	fmt.Fprint(w, `</li>`)
}

func writeCodeBlock(w http.ResponseWriter, blk codeBlock) {
	fmt.Fprint(w, `<div class="code-block">`)
	if blk.Lang != "" {
		fmt.Fprintf(w, `<div class="code-block-lang">%s</div>`, html.EscapeString(blk.Lang))
	}
	fmt.Fprintf(w, `<pre>%s</pre></div>`, html.EscapeString(blk.Body))
}

type codeSSEEvent struct {
	SourceID string          `json:"source_id"`
	From     string          `json:"from"`
	Conv     string          `json:"conv"`
	At       time.Time       `json:"at"`
	Blocks   []codeBlockWire `json:"blocks"`
}

var (
	codeSubsMu sync.Mutex
	codeSubs   = map[string]map[chan codeSSEEvent]struct{}{}
	// Per-user file mutex so concurrent appends serialize.
	codeFileMu      sync.Mutex
	codeFileMutexes = map[string]*sync.Mutex{}
)

func codeMuFor(uid string) *sync.Mutex {
	codeFileMu.Lock()
	defer codeFileMu.Unlock()
	mu, ok := codeFileMutexes[uid]
	if !ok {
		mu = &sync.Mutex{}
		codeFileMutexes[uid] = mu
	}
	return mu
}

func publishCode(uid string, evt codeSSEEvent) {
	codeSubsMu.Lock()
	defer codeSubsMu.Unlock()
	for ch := range codeSubs[uid] {
		select {
		case ch <- evt:
		default:
		}
	}
}

func openCode(uid string) (<-chan codeSSEEvent, func()) {
	ch := make(chan codeSSEEvent, 16)
	codeSubsMu.Lock()
	if codeSubs[uid] == nil {
		codeSubs[uid] = map[chan codeSSEEvent]struct{}{}
	}
	codeSubs[uid][ch] = struct{}{}
	codeSubsMu.Unlock()
	return ch, func() {
		codeSubsMu.Lock()
		defer codeSubsMu.Unlock()
		if subs := codeSubs[uid]; subs != nil {
			if _, ok := subs[ch]; ok {
				delete(subs, ch)
				close(ch)
			}
			if len(subs) == 0 {
				delete(codeSubs, uid)
			}
		}
	}
}

// HandleCodeStream is the per-user SSE stream for live code entries
// (GET /chat/code/stream). Live-only, no backlog, 25s ping keepalive.
func HandleCodeStream(w http.ResponseWriter, r *http.Request) {
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

	ch, cancel := openCode(user.ID)
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

// CodeJSPath is the embedded Code-page client.
var CodeJSPath = "chat/code.js"

// HandleCodeJS serves the Code-page client.
func HandleCodeJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, CodeJSPath, "code.js missing from the binary")
}
