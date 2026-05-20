// Full-game Elm client view. Serves the compiled Elm app and
// exposes a deliberately-dumb HTTP surface for session data.
//
// The server is a URL-keyed file store: Elm POSTs land under the
// player's session subtree (last-write-wins per URL), with
// sequential session-id allocation the ONE smart exception. Elm
// derives current state locally; agents read the on-disk action log
// directly when they need state.
//
// This module owns the full-game surface (`/game/...`). It also
// hosts the TS engine JS bundle constants (`EngineJSPath`,
// `EngineGlueJSPath`) for the full-game Hint button.
package views

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ElmLynRummyDir is the repo-relative directory containing the
// Elm source + compiled elm.js. Set by main; default assumes
// Gopher runs from the angry-gopher repo root.
var ElmLynRummyDir = "games/lynrummy/elm"

// EngineJSPath — esbuild-bundled TS engine. Built by
// ops/build_engine_js (called transitively by ops/build_elm).
// Served at /game/engine.js for the full-game Hint button.
var EngineJSPath = "games/lynrummy/elm/engine.js"

// EngineGlueJSPath — small JS shim that bridges Elm ports to
// the TS engine bundle. Lives next to engine.js.
var EngineGlueJSPath = "games/lynrummy/elm/engine_glue.js"

// HandleGame dispatches /game/*. The switch below is the route
// table; per-handler comments name each route's wire shape.
func HandleGame(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/game")
	sub = strings.TrimPrefix(sub, "/")
	user := CurrentUser(r)
	switch {
	case sub == "" || sub == "/":
		lynrummyElmPlay(w, user)
	case sub == "elm.js":
		lynrummyElmJS(w)
	case sub == "engine.js":
		serveJS(w, EngineJSPath, "engine.js not found — run `ops/build_engine_js`")
	case sub == "engine_glue.js":
		serveJS(w, EngineGlueJSPath, "engine_glue.js not found — check the file exists at "+EngineGlueJSPath)
	case sub == "new-session":
		lynrummyElmNewSession(w, r, user)
	case sub == "sessions":
		lynrummyElmSessionsList(w, user)
	case sub == "api/sessions":
		lynrummyElmSessionsJSON(w, user)
	case strings.HasPrefix(sub, "sessions/"):
		handleSessionRoute(w, r, user, strings.TrimPrefix(sub, "sessions/"))
	default:
		// /game/<id> — resume a session by numeric id.
		id, err := strconv.ParseInt(strings.TrimRight(sub, "/"), 10, 64)
		if err != nil || id <= 0 {
			http.NotFound(w, r)
			return
		}
		lynrummyElmPlayWithSession(w, user, id)
	}
}

// handleSessionRoute fans out the per-session URL space. The
// switch below is the route table.
func handleSessionRoute(w http.ResponseWriter, r *http.Request, user, rest string) {
	parts := strings.Split(rest, "/")
	idStr := parts[0]
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return
	}

	switch {
	case len(parts) == 1:
		lynrummyElmSessionDetail(w, user, id)
	case len(parts) == 2 && parts[1] == "actions":
		if r.Method == http.MethodPost {
			lynrummyElmAppendSessionLine(w, r, user, id, "actions")
		} else {
			lynrummyElmSessionBootstrap(w, user, id)
		}
	case len(parts) == 2 && parts[1] == "annotations":
		lynrummyElmAppendSessionLine(w, r, user, id, "annotations")
	default:
		http.NotFound(w, r)
	}
}

// --- Session creation ---

// lynrummyElmNewSession creates a fresh full-game session.
// Request body is text/plain: Elm's DSL-encoded GameState. The
// server allocates an id, prepends `created_at` (server-owned),
// writes the merged DSL to <session>/meta, and returns the id
// as JSON. The game-state DSL itself is stored verbatim — the
// server doesn't parse or validate it.
func lynrummyElmNewSession(w http.ResponseWriter, r *http.Request, user string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	gameStateDSL, ok := readLimitedBody(w, r, user, maxNewSessionBytes)
	if !ok {
		return
	}

	id, err := AllocateSessionID(user)
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}

	meta := SessionMeta{
		CreatedAt:    time.Now().Unix(),
		Label:        "",
		GameStateDSL: string(gameStateDSL),
	}
	if err := WriteSessionFile(user, id, "meta", []byte(FormatSessionMeta(meta))); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	resp := map[string]any{"session_id": id}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(resp)
}

// --- Action / annotation writes (the dumb path) ---

// lynrummyElmAppendSessionLine is the universal write handler
// for full-game sessions: POST body → one appended line in
// <session>/<rel>.jsonl. No parsing, no validation beyond
// "session must exist." `rel` is "actions" or "annotations";
// the seq Elm assigned rides inside the body.
func lynrummyElmAppendSessionLine(w http.ResponseWriter, r *http.Request, user string, sessionID int64, rel string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !SessionExists(user, sessionID) {
		http.NotFound(w, r)
		return
	}
	body, ok := readLimitedBody(w, r, user, maxAppendBytes)
	if !ok {
		return
	}
	// Actions are wire-DSL text lines (rel="actions" → actions.dsl).
	// Annotations stay JSONL — separate concern, different consumer.
	var err2 error
	if rel == "actions" {
		err2 = AppendSessionDslLine(user, sessionID, rel+".dsl", body)
	} else {
		err2 = AppendSessionLine(user, sessionID, rel+".jsonl", body)
	}
	if err2 != nil {
		http.Error(w, "append: "+err2.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- Session reads ---

// lynrummyElmSessionBootstrap returns the resume bundle as one
// text/plain document: the meta DSL (everything the on-disk
// `meta` file holds), a separator line `---`, then the action
// log DSL. Elm splits on the separator and parses each half.
func lynrummyElmSessionBootstrap(w http.ResponseWriter, user string, sessionID int64) {
	if !SessionExists(user, sessionID) {
		http.NotFound(w, nil)
		return
	}
	metaBytes, err := ReadSessionFile(user, sessionID, "meta")
	if err != nil && !os.IsNotExist(err) {
		http.Error(w, "read meta: "+err.Error(), http.StatusInternalServerError)
		return
	}
	actionsBytes, err := ReadSessionFile(user, sessionID, "actions.dsl")
	if err != nil && !os.IsNotExist(err) {
		http.Error(w, "read actions: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	// meta + "---" separator + actions. The meta file already
	// ends in a newline; the separator line stands alone; the
	// actions file may be empty (fresh session) or end in `\n`.
	w.Write(metaBytes)
	w.Write([]byte("---\n"))
	w.Write(actionsBytes)
}

// lynrummyElmSessionsList is the HTML browser of full-game
// session dirs. Puzzle sessions live in a separate namespace
// and are not surfaced here.
func lynrummyElmSessionsList(w http.ResponseWriter, user string) {
	ids, err := ListSessionIDs(user)
	if err != nil {
		http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// Newest first.
	sort.Slice(ids, func(i, j int) bool { return ids[i] > ids[j] })

	eastern, _ := time.LoadLocation("America/New_York")

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>LynRummy Elm sessions</title>
<style>
body { font-family: sans-serif; margin: 60px auto; max-width: 820px; padding: 0 24px; }
h1 { color: #000080; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #eee; }
th { background: #f4f4ec; }
tr:hover { background: #fafaf6; }
a { color: #000080; }
.muted { color: #888; }
.n { text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head><body>
<nav><a href="/">← Home</a> &nbsp;·&nbsp; <a href="/game">Play</a></nav>
<h1>Your sessions</h1>
<p class="muted">Newest first.</p>
<table><tr><th>id</th><th>created</th><th class="n">actions</th><th>label</th></tr>`)
	if len(ids) == 0 {
		fmt.Fprint(w, `<tr><td colspan="4" class="muted">No sessions yet.</td></tr>`)
	}
	for _, id := range ids {
		meta, _ := ReadSessionMeta(user, id)
		count, _ := CountSessionActions(user, id)
		ts := ""
		if t := SessionCreatedAt(meta); t > 0 {
			ts = time.Unix(t, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		}
		fmt.Fprintf(w,
			`<tr><td><a href="/game/sessions/%d">#%d</a></td><td>%s</td><td class="n">%d</td><td>%s</td></tr>`,
			id, id, html.EscapeString(ts), count, html.EscapeString(SessionLabel(meta)))
	}
	fmt.Fprint(w, `</table></body></html>`)
}

// lynrummyElmSessionsJSON is the api/sessions equivalent.
func lynrummyElmSessionsJSON(w http.ResponseWriter, user string) {
	ids, err := ListSessionIDs(user)
	if err != nil {
		http.Error(w, "list: "+err.Error(), http.StatusInternalServerError)
		return
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] > ids[j] })

	type entry struct {
		ID          int64  `json:"id"`
		CreatedAt   int64  `json:"created_at"`
		Label       string `json:"label"`
		ActionCount int    `json:"action_count"`
	}
	out := []entry{}
	for _, id := range ids {
		meta, _ := ReadSessionMeta(user, id)
		count, _ := CountSessionActions(user, id)
		out = append(out, entry{
			ID:          id,
			CreatedAt:   SessionCreatedAt(meta),
			Label:       SessionLabel(meta),
			ActionCount: count,
		})
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{"sessions": out})
}

// lynrummyElmSessionDetail renders a debug view for a session
// dir. No replay, no score — just lists what's on disk.
func lynrummyElmSessionDetail(w http.ResponseWriter, user string, sessionID int64) {
	if !SessionExists(user, sessionID) {
		http.NotFound(w, nil)
		return
	}
	meta, _ := ReadSessionMeta(user, sessionID)
	actionCount, _ := CountSessionActions(user, sessionID)
	annotationCount, _ := CountTextLines(filepath.Join(SessionDir(user, sessionID), "annotations.jsonl"))

	eastern, _ := time.LoadLocation("America/New_York")
	ts := ""
	if t := SessionCreatedAt(meta); t > 0 {
		ts = time.Unix(t, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>LynRummy Elm session #%d</title>
<style>
body { font-family: sans-serif; margin: 60px auto; max-width: 860px; padding: 0 24px; }
h1 { color: #000080; margin-bottom: 4px; }
.sub { color: #666; margin-bottom: 24px; font-size: 14px; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
.muted { color: #888; }
ul { font-family: monospace; font-size: 13px; }
li { padding: 2px 0; }
pre { background: #f4f4ec; padding: 12px; border: 1px solid #ddd; overflow-x: auto; }
</style>
</head><body>
<nav><a href="/game/sessions">← All sessions</a> &nbsp;·&nbsp; <a href="/game">Play</a></nav>
<h1>Session #%d</h1>
<p class="sub">Started %s%s</p>
<h3>meta</h3>`,
		sessionID, sessionID, html.EscapeString(ts), labelSuffix(SessionLabel(meta)))
	if rawMeta, err := ReadSessionFile(user, sessionID, "meta"); err == nil {
		fmt.Fprintf(w, `<pre>%s</pre>`, html.EscapeString(string(rawMeta)))
	} else {
		fmt.Fprint(w, `<p class="muted">no meta file</p>`)
	}
	fmt.Fprintf(w, `<p>actions.dsl: <strong>%d</strong> lines</p>`, actionCount)
	fmt.Fprintf(w, `<p>annotations.jsonl: <strong>%d</strong> lines</p>`, annotationCount)
	fmt.Fprint(w, `</body></html>`)
}

func labelSuffix(label string) string {
	if label == "" {
		return ""
	}
	return " · " + html.EscapeString(label)
}

// --- Static ---

func lynrummyElmPlay(w http.ResponseWriter, user string) {
	lynrummyElmPlayWithSession(w, user, 0)
}

func lynrummyElmPlayWithSession(w http.ResponseWriter, user string, sessionID int64) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	flag := "null"
	if sessionID > 0 {
		flag = strconv.FormatInt(sessionID, 10)
	}
	playerNameJSON, _ := json.Marshal(user)
	fmt.Fprintf(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>LynRummy (Elm)</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
  .app-nav { padding: 8px 16px; background: #000080; color: white; font-size: 13px; }
  .app-nav a { color: white; text-decoration: none; margin-right: 14px; }
  .app-nav a:hover { text-decoration: underline; }
  .app-main { padding: 0; }
</style>
</head><body>
<div class="app-nav">
  <a href="/">← Home</a>
  <a href="/game/sessions">Sessions</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/game/engine.js"></script>
<script src="/game/elm.js"></script>
<script src="/game/engine_glue.js"></script>
<script>
  var initialSessionId = %s;
  var app = Elm.Game.init({
    node: document.getElementById("root"),
    flags: {
      initialSessionId: initialSessionId,
      seedSource: Date.now(),
      playerName: %s,
    },
  });
  app.ports.setSessionPath.subscribe(function(sid) {
    var url = sid === "" ? "/game" : "/game/" + sid;
    history.replaceState(null, "", url);
  });
  EngineGlue.attach(app);
</script>
</div>
</body></html>`, flag, playerNameJSON)
}

func lynrummyElmJS(w http.ResponseWriter) {
	path := filepath.Join(ElmLynRummyDir, "elm.js")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "elm.js not found — run `elm make src/Game.elm --output=elm.js` in "+ElmLynRummyDir, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}

// serveJS reads `path` and writes it as application/javascript.
// On read failure, returns a 404 with the supplied missing-file
// message (intended to point the developer at the build step
// that produces the asset).
func serveJS(w http.ResponseWriter, path string, missingMsg string) {
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, missingMsg, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}
