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
	"angry-gopher/server/platform"
	"bytes"
	"encoding/json"
	"fmt"
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
// AppendChatMessage when the markdown contains ``` fenced blocks. Lock
// order: chatMu (held) → codeFileMu (per-user, leaf).
func PublishChatCode(conv, sid string, msg ChatMessage) {
	blocks := extractCodeBlocks(msg.Markdown)
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
		codeBus.publish(uid, codeSSEEvent{
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
	user := users.CurrentUser(r)
	entries, err := readCodeForUser(user.ID)
	if err != nil {
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	chatPageHeader(w, "Code", user, "code")
	fmt.Fprint(w, `<div class="chat-notify" id="chat-notify"></div>`)
	fmt.Fprint(w, `<div id="code-mount"></div>`)
	emitCodeData(w, entries)
	fmt.Fprintf(w,
		`<script src="/chat/styles.js?v=%s"></script>`+
			`<script src="/chat/chat_code_popup.js?v=%s"></script>`+
			`<script src="/chat/code.js?v=%s"></script>`+
			`<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(platform.AssetVersion), url.QueryEscape(platform.AssetVersion),
		url.QueryEscape(platform.AssetVersion), url.QueryEscape(platform.AssetVersion))
	platform.PageFooter(w)
}

// emitCodeData ships the initial transcript as inline JSON next to the
// mount slot. The shape matches codeSSEEvent, so the client uses ONE
// builder for both the first-paint entries and the live SSE upserts.
func emitCodeData(w http.ResponseWriter, entries []codeEntry) {
	payload := make([]codeSSEEvent, len(entries))
	for i, e := range entries {
		payload[i] = codeSSEEvent{
			SourceID: e.SourceID,
			From:     e.From,
			Conv:     e.Conv,
			At:       e.At,
			Blocks:   blocksToWire(e.Blocks),
		}
	}
	blob, err := json.Marshal(payload)
	if err != nil {
		return
	}
	// PRODUCT_DECISION: escape `</` so the JSON can't accidentally close
	// the surrounding <script> tag.
	blob = bytes.ReplaceAll(blob, []byte("</"), []byte(`<\/`))
	fmt.Fprintf(w, `<script id="code-data" type="application/json">%s</script>`, blob)
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

type codeSSEEvent struct {
	SourceID string          `json:"source_id"`
	From     string          `json:"from"`
	Conv     string          `json:"conv"`
	At       time.Time       `json:"at"`
	Blocks   []codeBlockWire `json:"blocks"`
}

// codeBus is keyed by viewer user id.
var codeBus = newSubBus[codeSSEEvent]()

// Per-user file mutex so concurrent appends serialize.
var (
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

// HandleCodeStream serves GET /chat/code/stream.
func HandleCodeStream(w http.ResponseWriter, r *http.Request) {
	user := users.CurrentUser(r)
	serveSSE(w, r, func() (<-chan codeSSEEvent, func()) {
		return codeBus.open(user.ID)
	})
}

// CodeJSPath is the embedded Code-page client.
var CodeJSPath = "chat/code.js"

// HandleCodeJS serves the Code-page client.
func HandleCodeJS(w http.ResponseWriter, r *http.Request) {
	platform.ServeJS(w, CodeJSPath, "code.js missing from the binary")
}
