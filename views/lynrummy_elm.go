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
// This module owns ONLY the full-game surface
// (`/gopher/lynrummy-elm/...`). Puzzle sessions live in their
// own top-level namespace at
// `data/lynrummy-elm/puzzle-sessions/...` and are served by
// `views/puzzles.go`. The two namespaces share no helpers
// beyond the file-store primitives in `gamedata.go`.
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

// HandleLynRummyElm dispatches /gopher/lynrummy-elm/*.
//
// Routes:
//   GET  /                              → Elm play page
//   GET  /elm.js                        → compiled Elm
//   GET  /play/<id>                     → Elm play page with session id baked in
//   POST /new-session                   → allocate id, write meta.json
//   POST /sessions/<id>/actions/<seq>   → write body to actions/<seq>.json (DUMB)
//   POST /sessions/<id>/annotations/<seq> → write body to annotations/<seq>.json (DUMB)
//   GET  /sessions                      → HTML list of full-game session dirs
//   GET  /api/sessions                  → JSON list
//   GET  /sessions/<id>                 → HTML detail (file listing)
//   GET  /sessions/<id>/actions         → bundle: {meta, actions[]} for Elm bootstrap
func HandleLynRummyElm(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/lynrummy-elm")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		lynrummyElmPlay(w)
	case sub == "elm.js":
		lynrummyElmJS(w)
	case sub == "engine.js":
		// TS engine bundle — shared with the Puzzles surface.
		// Same file, served under both paths so the full-game
		// page doesn't reach into /gopher/puzzles/ for assets.
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
// "7", "7/actions", "7/actions/3", "7/annotations/1".
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
		lynrummyElmSessionBootstrap(w, id)
	case len(parts) == 3 && parts[1] == "actions":
		lynrummyElmWriteSessionFile(w, r, id, "actions", parts[2])
	case len(parts) == 3 && parts[1] == "annotations":
		lynrummyElmWriteSessionFile(w, r, id, "annotations", parts[2])
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

// lynrummyElmWriteSessionFile is the universal write handler
// for full-game sessions: POST body → file at
// <session>/<sub>/<seqOrName>.json. No parsing, no validation
// beyond "session must exist."
func lynrummyElmWriteSessionFile(w http.ResponseWriter, r *http.Request, sessionID int64, sub, seqOrName string) {
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
	// Filename: numeric input gets .json appended; explicit
	// .json input passes through. Path traversal is rejected.
	name := seqOrName
	if seq, perr := strconv.ParseInt(seqOrName, 10, 64); perr == nil && seq > 0 {
		name = strconv.FormatInt(seq, 10) + ".json"
	}
	if strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.Error(w, "bad filename", http.StatusBadRequest)
		return
	}
	rel := filepath.Join(sub, name)
	if err := WriteSessionFile(sessionID, rel, body); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
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
	files, err := ListActionFiles(sessionID)
	if err != nil {
		http.Error(w, "list actions: "+err.Error(), http.StatusInternalServerError)
		return
	}
	actions := make([]json.RawMessage, 0, len(files))
	for _, name := range files {
		body, err := ReadSessionFile(sessionID, filepath.Join("actions", name))
		if err != nil {
			continue
		}
		actions = append(actions, body)
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
		files, _ := ListActionFiles(id)
		ts := ""
		if t := SessionCreatedAt(meta); t > 0 {
			ts = time.Unix(t, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		}
		fmt.Fprintf(w,
			`<tr><td><a href="/gopher/lynrummy-elm/sessions/%d">#%d</a></td><td>%s</td><td class="n">%d</td><td>%s</td></tr>`,
			id, id, html.EscapeString(ts), len(files), html.EscapeString(SessionLabel(meta)))
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
		files, _ := ListActionFiles(id)
		out = append(out, entry{
			ID:          id,
			CreatedAt:   SessionCreatedAt(meta),
			Label:       SessionLabel(meta),
			ActionCount: len(files),
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
	actionFiles, _ := ListActionFiles(sessionID)
	annotationFiles, _ := ListAnnotationFiles(sessionID)

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
	fmt.Fprintf(w, `<h3>actions/ (%d)</h3><ul>`, len(actionFiles))
	for _, name := range actionFiles {
		fmt.Fprintf(w, `<li>%s</li>`, html.EscapeString(name))
	}
	if len(actionFiles) == 0 {
		fmt.Fprint(w, `<li class="muted">empty</li>`)
	}
	fmt.Fprintf(w, `</ul><h3>annotations/ (%d)</h3><ul>`, len(annotationFiles))
	for _, name := range annotationFiles {
		fmt.Fprintf(w, `<li>%s</li>`, html.EscapeString(name))
	}
	if len(annotationFiles) == 0 {
		fmt.Fprint(w, `<li class="muted">empty</li>`)
	}
	fmt.Fprint(w, `</ul></body></html>`)
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
