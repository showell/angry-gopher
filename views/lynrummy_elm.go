// LynRummy Elm client view. Serves the compiled Elm app from
// games/lynrummy/elm-port-docs/ through Gopher. Standalone
// client in V1 — no server round-trip, no auth, no real
// game state. Just "Steve can reach the new client via the
// Gopher URL."
//
// label: SPIKE (lynrummy-elm-integration)
package views

import (
	"database/sql"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"angry-gopher/games/lynrummy"
)

// ElmLynRummyDir is the repo-relative directory containing the
// Elm source + compiled elm.js. Set by main; default assumes
// Gopher runs from the angry-gopher repo root.
var ElmLynRummyDir = "games/lynrummy/elm-port-docs"

// HandleLynRummyElm dispatches /gopher/lynrummy-elm/*.
func HandleLynRummyElm(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/lynrummy-elm")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		lynrummyElmPlay(w)
	case sub == "elm.js":
		lynrummyElmJS(w)
	case sub == "actions":
		lynrummyElmActions(w, r)
	case sub == "new-session":
		lynrummyElmNewSession(w, r)
	case sub == "sessions":
		lynrummyElmSessionsList(w)
	case strings.HasPrefix(sub, "sessions/"):
		lynrummyElmSessionDetail(w, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

// lynrummyElmNewSession creates a fresh session row and returns
// its id. Called by the Elm client on boot; client stores the id
// and includes it with every subsequent action POST.
func lynrummyElmNewSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	now := time.Now().Unix()
	res, err := DB.Exec(`INSERT INTO lynrummy_elm_sessions (created_at) VALUES (?)`, now)
	if err != nil {
		http.Error(w, "insert session: "+err.Error(), http.StatusInternalServerError)
		return
	}
	id, err := res.LastInsertId()
	if err != nil {
		http.Error(w, "lastinsertid: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("lynrummy-elm session: new id=%d", id)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprintf(w, `{"session_id":%d}`, id)
}

// lynrummyElmActions receives a WireAction from the Elm client
// and persists it. Expects ?session=<id> query param. V1
// scaffolding: no auth. Broadcast to an opponent arrives with
// the multi-player work.
func lynrummyElmActions(w http.ResponseWriter, r *http.Request) {
	log.Printf("lynrummy-elm action: HIT method=%s content-type=%s origin=%s",
		r.Method, r.Header.Get("Content-Type"), r.Header.Get("Origin"))
	if r.Method != http.MethodPost {
		log.Printf("lynrummy-elm action: rejected non-POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("lynrummy-elm action: read body err=%v", err)
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	action, err := lynrummy.DecodeWireAction(body)
	if err != nil {
		log.Printf("lynrummy-elm action: decode err=%v body=%s", err, body)
		http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
		return
	}
	sessionIDStr := r.URL.Query().Get("session")
	sessionID, err := strconv.ParseInt(sessionIDStr, 10, 64)
	if err != nil || sessionID <= 0 {
		log.Printf("lynrummy-elm action: bad/missing session param=%q", sessionIDStr)
		http.Error(w, "missing or bad ?session=<id>", http.StatusBadRequest)
		return
	}

	// Sequence number = count of prior actions in this session + 1.
	var nextSeq int64
	if err := DB.QueryRow(
		`SELECT COALESCE(MAX(seq), 0) + 1 FROM lynrummy_elm_actions WHERE session_id = ?`,
		sessionID,
	).Scan(&nextSeq); err != nil {
		log.Printf("lynrummy-elm action: seq lookup err=%v", err)
		http.Error(w, "seq lookup: "+err.Error(), http.StatusInternalServerError)
		return
	}

	if _, err := DB.Exec(
		`INSERT INTO lynrummy_elm_actions (session_id, seq, action_kind, action_json, created_at) VALUES (?, ?, ?, ?, ?)`,
		sessionID, nextSeq, action.ActionKind(), string(body), time.Now().Unix(),
	); err != nil {
		log.Printf("lynrummy-elm action: insert err=%v", err)
		http.Error(w, "insert: "+err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("lynrummy-elm action: session=%d seq=%d kind=%s payload=%s",
		sessionID, nextSeq, action.ActionKind(), body)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprintf(w, `{"ok":true,"seq":%d}`, nextSeq)
}

// --- Sessions browser ---

func lynrummyElmSessionsList(w http.ResponseWriter) {
	rows, err := DB.Query(`
		SELECT s.id, s.created_at, s.label,
		       (SELECT COUNT(*) FROM lynrummy_elm_actions WHERE session_id = s.id) AS n
		FROM lynrummy_elm_sessions s
		ORDER BY s.id DESC
		LIMIT 200`)
	if err != nil {
		http.Error(w, "query: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

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
<p class="muted">Newest first. Each session is one page-load of the Elm client.</p>
<table><tr><th>id</th><th>created</th><th class="n">actions</th><th>label</th></tr>`)
	anyRows := false
	for rows.Next() {
		var id, createdAt int64
		var n int
		var label string
		if err := rows.Scan(&id, &createdAt, &label, &n); err != nil {
			continue
		}
		anyRows = true
		ts := time.Unix(createdAt, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		fmt.Fprintf(w,
			`<tr><td><a href="/gopher/lynrummy-elm/sessions/%d">#%d</a></td><td>%s</td><td class="n">%d</td><td>%s</td></tr>`,
			id, id, html.EscapeString(ts), n, html.EscapeString(label))
	}
	if !anyRows {
		fmt.Fprint(w, `<tr><td colspan="4" class="muted">No sessions yet.</td></tr>`)
	}
	fmt.Fprint(w, `</table></body></html>`)
}

func lynrummyElmSessionDetail(w http.ResponseWriter, idStr string) {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, nil)
		return
	}
	var createdAt int64
	var label string
	err = DB.QueryRow(`SELECT created_at, label FROM lynrummy_elm_sessions WHERE id = ?`, id).
		Scan(&createdAt, &label)
	if err == sql.ErrNoRows {
		http.NotFound(w, nil)
		return
	}
	if err != nil {
		http.Error(w, "query session: "+err.Error(), http.StatusInternalServerError)
		return
	}

	rows, err := DB.Query(
		`SELECT seq, action_kind, action_json, created_at FROM lynrummy_elm_actions WHERE session_id = ? ORDER BY seq`,
		id,
	)
	if err != nil {
		http.Error(w, "query actions: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	eastern, _ := time.LoadLocation("America/New_York")
	ts := time.Unix(createdAt, 0).In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>LynRummy Elm session #%d</title>
<style>
body { font-family: sans-serif; margin: 60px auto; max-width: 860px; padding: 0 24px; }
h1 { color: #000080; margin-bottom: 4px; }
.sub { color: #666; margin-bottom: 24px; font-size: 14px; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #eee; vertical-align: top; }
th { background: #f4f4ec; }
td.seq { font-variant-numeric: tabular-nums; color: #888; }
td.kind { color: #000080; font-weight: bold; }
td.payload { font-family: monospace; font-size: 12px; color: #444; }
.muted { color: #888; }
</style>
</head><body>
<nav><a href="/gopher/lynrummy-elm/sessions">← All sessions</a> &nbsp;·&nbsp; <a href="/gopher/lynrummy-elm/">Play</a></nav>
<h1>Session #%d</h1>
<p class="sub">Started %s%s</p>
<table><tr><th>seq</th><th>kind</th><th>payload</th></tr>`,
		id, id, html.EscapeString(ts), labelSuffix(label))

	anyRows := false
	for rows.Next() {
		var seq int64
		var kind, payload string
		var createdAt int64
		if err := rows.Scan(&seq, &kind, &payload, &createdAt); err != nil {
			continue
		}
		anyRows = true
		fmt.Fprintf(w,
			`<tr><td class="seq">%d</td><td class="kind">%s</td><td class="payload">%s</td></tr>`,
			seq, html.EscapeString(kind), html.EscapeString(payload))
	}
	if !anyRows {
		fmt.Fprint(w, `<tr><td colspan="3" class="muted">No actions recorded yet. Play some.</td></tr>`)
	}
	fmt.Fprint(w, `</table></body></html>`)
}

func labelSuffix(label string) string {
	if label == "" {
		return ""
	}
	return " · " + html.EscapeString(label)
}

func lynrummyElmPlay(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html>
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
  <a href="/gopher/wiki/gopher/games/lynrummy/elm-port-docs/">Elm source</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/gopher/lynrummy-elm/elm.js"></script>
<script>
  Elm.Main.init({ node: document.getElementById("root") });
</script>
</div>
</body></html>`)
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
