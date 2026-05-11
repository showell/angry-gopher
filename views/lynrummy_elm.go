// LynRummy Elm client view. Serves the compiled Elm app and
// exposes a deliberately-dumb HTTP surface for full-game
// session data.
//
// As of 2026-04-28 (LEAN_PASS): the server is a URL-keyed
// file store. Elm POSTs land at paths under
// games/lynrummy/data/lynrummy-elm/sessions/ that mirror the
// URL. Last-write-wins per URL. Sequential session-id
// allocation is the ONE smart exception. Replay/score/state
// computation retired — Elm derives current state locally;
// agents read the on-disk action log directly when they need
// state.
//
// This module owns the full-game surface
// (`/gopher/lynrummy-elm/...`). It also hosts the TS engine
// JS bundle constants (`EngineJSPath`, `EngineGlueJSPath`)
// because the full-game Hint button is the surviving consumer
// after the puzzle gallery retired.
package views

import (
	"encoding/json"
	"fmt"
	"html"
	"io"
	mathRand "math/rand"
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
// Served at /gopher/lynrummy-elm/engine.js for the full-game
// Hint button.
var EngineJSPath = "games/lynrummy/elm/engine.js"

// EngineGlueJSPath — small JS shim that bridges Elm ports to
// the TS engine bundle. Lives next to engine.js.
var EngineGlueJSPath = "games/lynrummy/elm/engine_glue.js"

// HandleLynRummyElm dispatches /gopher/lynrummy-elm/*.
//
// Routes:
//   GET  /                              → Elm play page
//   GET  /elm.js                        → compiled Elm
//   GET  /play/<id>                     → Elm play page with session id baked in
//   POST /new-session                   → allocate id, write meta.json
//   POST /sessions/<id>/actions         → append one envelope to actions.jsonl (DUMB)
//   POST /sessions/<id>/annotations     → append one envelope to annotations.jsonl (DUMB)
//   GET  /sessions                      → HTML list of full-game session dirs
//   GET  /api/sessions                  → JSON list
//   GET  /sessions/<id>                 → HTML detail (file listing)
//   GET  /sessions/<id>/actions         → bundle: {meta, actions[]} for Elm bootstrap
//
// Each envelope on actions.jsonl is `{seq, action}` — the seq is
// Elm-authored (rides in the body, not the URL) and the server
// appends verbatim. Order on disk = order Elm sent.
func HandleLynRummyElm(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/lynrummy-elm")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		lynrummyElmPlay(w)
	case sub == "elm.js":
		lynrummyElmJS(w)
	case sub == "engine.js":
		serveJS(w, EngineJSPath, "engine.js not found — run `ops/build_engine_js`")
	case sub == "engine_glue.js":
		serveJS(w, EngineGlueJSPath, "engine_glue.js not found — check the file exists at "+EngineGlueJSPath)
	case sub == "new-session":
		lynrummyElmNewSession(w, r)
	case sub == "sessions":
		lynrummyElmSessionsList(w)
	case sub == "api/sessions":
		lynrummyElmSessionsJSON(w)
	case strings.HasPrefix(sub, "play/"):
		idStr := strings.TrimRight(strings.TrimPrefix(sub, "play/"), "/")
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil || id <= 0 {
			http.NotFound(w, r)
			return
		}
		lynrummyElmPlayWithSession(w, id)
	case strings.HasPrefix(sub, "sessions/"):
		handleSessionRoute(w, r, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

// handleSessionRoute fans out the per-session URL space.
// `rest` is everything after "sessions/" — e.g.
// "7", "7/actions", "7/annotations".
//
// GET  /<id>                bundle (HTML detail)
// GET  /<id>/actions        bootstrap JSON ({meta, actions})
// POST /<id>/actions        append one envelope to actions.jsonl
// POST /<id>/annotations    append one envelope to annotations.jsonl
//
// Seq numbers ride in the POST body now, not the URL — so /actions
// and /annotations are single endpoints distinguished by HTTP method.
func handleSessionRoute(w http.ResponseWriter, r *http.Request, rest string) {
	parts := strings.Split(rest, "/")
	idStr := parts[0]
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return
	}

	switch {
	case len(parts) == 1:
		lynrummyElmSessionDetail(w, id)
	case len(parts) == 2 && parts[1] == "actions":
		if r.Method == http.MethodPost {
			lynrummyElmAppendSessionLine(w, r, id, "actions")
		} else {
			lynrummyElmSessionBootstrap(w, id)
		}
	case len(parts) == 2 && parts[1] == "annotations":
		lynrummyElmAppendSessionLine(w, r, id, "annotations")
	default:
		http.NotFound(w, r)
	}
}

// --- Session creation ---

// lynrummyElmNewSession creates a fresh full-game session. Body
// is optional; if present, may carry `{label, initial_state}`.
// Server allocates id, generates deck_seed (when no
// initial_state), writes meta.json, returns the id.
//
// "Server is dumb" means: anything Elm sends in the body lands
// in meta.json verbatim, alongside the few fields the server
// must own (created_at, deck_seed, session_id is implicit in
// path).
func lynrummyElmNewSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var bodyMap map[string]any
	if r.ContentLength > 0 {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}
		if len(body) > 0 {
			if err := json.Unmarshal(body, &bodyMap); err != nil {
				http.Error(w, "decode body: "+err.Error(), http.StatusBadRequest)
				return
			}
		}
	}
	if bodyMap == nil {
		bodyMap = map[string]any{}
	}

	id, err := AllocateSessionID()
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}

	bodyMap["created_at"] = time.Now().Unix()
	if _, hasInitial := bodyMap["initial_state"]; !hasInitial {
		// Server-dealt: generate a non-zero deck seed so the
		// dealer has a reproducible point of departure. Elm
		// uses this on bootstrap to compute the initial board.
		seed := time.Now().UnixNano()*1_000_003 + mathRand.Int63()
		if seed == 0 {
			seed = 1
		}
		bodyMap["deck_seed"] = seed
	}

	metaJSON, err := json.MarshalIndent(bodyMap, "", "  ")
	if err != nil {
		http.Error(w, "encode meta: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := WriteSessionFile(id, "meta.json", append(metaJSON, '\n')); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	resp := map[string]any{"session_id": id}
	if seed, ok := bodyMap["deck_seed"]; ok {
		resp["deck_seed"] = seed
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(resp)
}

// --- Action / annotation writes (the dumb path) ---

// lynrummyElmAppendSessionLine is the universal write handler
// for full-game sessions: POST body → one appended line in
// <session>/<rel>.jsonl. No parsing, no validation beyond
// "session must exist." `rel` is "actions" or "annotations";
// the seq Elm assigned rides inside the body.
func lynrummyElmAppendSessionLine(w http.ResponseWriter, r *http.Request, sessionID int64, rel string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !SessionExists(sessionID) {
		http.NotFound(w, r)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	// Actions are wire-DSL text lines (rel="actions" → actions.dsl).
	// Annotations stay JSONL — separate concern, different consumer.
	var err2 error
	if rel == "actions" {
		err2 = AppendSessionDslLine(sessionID, rel+".dsl", body)
	} else {
		err2 = AppendSessionLine(sessionID, rel+".jsonl", body)
	}
	if err2 != nil {
		http.Error(w, "append: "+err2.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprint(w, `{"ok":true}`)
}

// --- Session reads ---

// lynrummyElmSessionBootstrap returns the dumb bundle: the
// session's meta blob and its action log, both as the Elm
// client posted them. No initial_state synthesis — Elm derives
// that locally from meta.deck_seed using its own dealer.
//
// Response shape:
//   {"session_id": N, "meta": {...}, "actions": [<envelope>...]}
func lynrummyElmSessionBootstrap(w http.ResponseWriter, sessionID int64) {
	if !SessionExists(sessionID) {
		http.NotFound(w, nil)
		return
	}
	meta, err := ReadSessionMeta(sessionID)
	if err != nil && !os.IsNotExist(err) {
		http.Error(w, "read meta: "+err.Error(), http.StatusInternalServerError)
		return
	}
	actions, err := ReadSessionActionLines(sessionID)
	if err != nil {
		http.Error(w, "read actions: "+err.Error(), http.StatusInternalServerError)
		return
	}

	payload := map[string]any{
		"session_id": sessionID,
		"meta":       meta,
		"actions":    actions,
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(payload)
}

// lynrummyElmSessionsList is the HTML browser of full-game
// session dirs. Puzzle sessions live in a separate namespace
// and are not surfaced here.
func lynrummyElmSessionsList(w http.ResponseWriter) {
	ids, err := ListSessionIDs()
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
<nav><a href="/gopher/">← Gopher home</a> &nbsp;·&nbsp; <a href="/gopher/lynrummy-elm/">Play</a></nav>
<h1>LynRummy Elm sessions</h1>
<p class="muted">Newest first. Sourced from games/lynrummy/data/lynrummy-elm/sessions/.</p>
<table><tr><th>id</th><th>created</th><th class="n">actions</th><th>label</th></tr>`)
	if len(ids) == 0 {
		fmt.Fprint(w, `<tr><td colspan="4" class="muted">No sessions yet.</td></tr>`)
	}
	for _, id := range ids {
		meta, _ := ReadSessionMeta(id)
		count, _ := CountSessionActions(id)
		ts := ""
		if t := SessionCreatedAt(meta); t > 0 {
			ts = time.Unix(t, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		}
		fmt.Fprintf(w,
			`<tr><td><a href="/gopher/lynrummy-elm/sessions/%d">#%d</a></td><td>%s</td><td class="n">%d</td><td>%s</td></tr>`,
			id, id, html.EscapeString(ts), count, html.EscapeString(SessionLabel(meta)))
	}
	fmt.Fprint(w, `</table></body></html>`)
}

// lynrummyElmSessionsJSON is the api/sessions equivalent.
func lynrummyElmSessionsJSON(w http.ResponseWriter) {
	ids, err := ListSessionIDs()
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
		meta, _ := ReadSessionMeta(id)
		count, _ := CountSessionActions(id)
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
func lynrummyElmSessionDetail(w http.ResponseWriter, sessionID int64) {
	if !SessionExists(sessionID) {
		http.NotFound(w, nil)
		return
	}
	meta, _ := ReadSessionMeta(sessionID)
	actionCount, _ := CountSessionActions(sessionID)
	annotationCount, _ := CountJSONLLines(filepath.Join(SessionDir(sessionID), "annotations.jsonl"))

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
<nav><a href="/gopher/lynrummy-elm/sessions">← All sessions</a> &nbsp;·&nbsp; <a href="/gopher/lynrummy-elm/">Play</a></nav>
<h1>Session #%d</h1>
<p class="sub">Started %s%s</p>
<h3>meta.json</h3>`,
		sessionID, sessionID, html.EscapeString(ts), labelSuffix(SessionLabel(meta)))
	if meta != nil {
		pretty, _ := json.MarshalIndent(meta, "", "  ")
		fmt.Fprintf(w, `<pre>%s</pre>`, html.EscapeString(string(pretty)))
	} else {
		fmt.Fprint(w, `<p class="muted">no meta.json</p>`)
	}
	fmt.Fprintf(w, `<p>actions.jsonl: <strong>%d</strong> lines</p>`, actionCount)
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

func lynrummyElmPlay(w http.ResponseWriter) {
	lynrummyElmPlayWithSession(w, 0)
}

func lynrummyElmPlayWithSession(w http.ResponseWriter, sessionID int64) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	flag := "null"
	if sessionID > 0 {
		flag = strconv.FormatInt(sessionID, 10)
	}
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
  <a href="/gopher/">← Gopher home</a>
  <a href="/gopher/game-lobby">Game lobby</a>
  <a href="/gopher/lynrummy-elm/sessions">Sessions</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/gopher/lynrummy-elm/engine.js"></script>
<script src="/gopher/lynrummy-elm/elm.js"></script>
<script src="/gopher/lynrummy-elm/engine_glue.js"></script>
<script>
  var initialSessionId = %s;
  var app = Elm.Main.init({
    node: document.getElementById("root"),
    flags: {
      initialSessionId: initialSessionId,
      seedSource: Date.now(),
    },
  });
  app.ports.setSessionPath.subscribe(function(sid) {
    var url = sid === "" ? "/gopher/lynrummy-elm/"
                         : "/gopher/lynrummy-elm/play/" + sid;
    history.replaceState(null, "", url);
  });
  EngineGlue.attach(app);
</script>
</div>
</body></html>`, flag)
}

func lynrummyElmJS(w http.ResponseWriter) {
	path := filepath.Join(ElmLynRummyDir, "elm.js")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "elm.js not found — run `elm make src/Main.elm --output=elm.js` in "+ElmLynRummyDir, http.StatusNotFound)
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
