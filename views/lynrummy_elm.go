// LynRummy Elm client view. Serves the compiled Elm app from
// games/lynrummy/elm-port-docs/ through Gopher. Standalone
// client in V1 — no server round-trip, no auth, no real
// game state. Just "Steve can reach the new client via the
// Gopher URL."
//
// label: SPIKE (lynrummy-elm-integration)
package views

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	mathRand "math/rand"
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
	case sub == "new-puzzle-session":
		lynrummyElmNewPuzzleSession(w, r)
	case sub == "sessions":
		lynrummyElmSessionsList(w)
	case sub == "api/sessions":
		lynrummyElmSessionsJSON(w)
	case strings.HasPrefix(sub, "play/"):
		// /gopher/lynrummy-elm/play/<id> — load the Elm client
		// with session <id> pinned server-side. Reload-safe
		// replacement for the old #<id> URL fragment.
		idStr := strings.TrimPrefix(sub, "play/")
		id, err := strconv.ParseInt(strings.TrimRight(idStr, "/"), 10, 64)
		if err != nil || id <= 0 {
			http.NotFound(w, r)
			return
		}
		lynrummyElmPlayWithSession(w, id)
	case strings.HasSuffix(sub, "/state") && strings.HasPrefix(sub, "sessions/"):
		idStr := strings.TrimSuffix(strings.TrimPrefix(sub, "sessions/"), "/state")
		lynrummyElmSessionState(w, idStr)
	case strings.HasSuffix(sub, "/score") && strings.HasPrefix(sub, "sessions/"):
		idStr := strings.TrimSuffix(strings.TrimPrefix(sub, "sessions/"), "/score")
		lynrummyElmSessionScore(w, idStr)
	case strings.HasSuffix(sub, "/turn-log") && strings.HasPrefix(sub, "sessions/"):
		idStr := strings.TrimSuffix(strings.TrimPrefix(sub, "sessions/"), "/turn-log")
		lynrummyElmSessionTurnLog(w, idStr)
	case strings.HasSuffix(sub, "/actions") && strings.HasPrefix(sub, "sessions/"):
		idStr := strings.TrimSuffix(strings.TrimPrefix(sub, "sessions/"), "/actions")
		lynrummyElmSessionActions(w, idStr)
	case strings.HasPrefix(sub, "sessions/"):
		lynrummyElmSessionDetail(w, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

// lynrummyElmNewSession creates a fresh session row and returns
// its id. Called by the Elm client on boot; client stores the id
// and includes it with every subsequent action POST. A
// per-session deck seed is generated here; replays use it so
// each session has its own shuffled deck order — deterministic
// within a session, different across sessions.
func lynrummyElmNewSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Optional body: {"label": "..."}. Empty-body POST (the Elm
	// client path) leaves label as "". Label is a human-readable
	// session handle — agents use it to distinguish their games
	// from Steve's in the sessions list.
	var label string
	if r.ContentLength > 0 {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}
		if len(body) > 0 {
			var req struct {
				Label string `json:"label"`
			}
			if err := json.Unmarshal(body, &req); err != nil {
				http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
				return
			}
			label = req.Label
		}
	}

	now := time.Now().Unix()
	seed := now*1_000_003 + int64(mathRandInt63()) // monotonic + noise
	if seed == 0 {
		seed = 1 // zero means "no shuffle" downstream; force non-zero
	}
	res, err := DB.Exec(
		`INSERT INTO lynrummy_elm_sessions (created_at, label, deck_seed) VALUES (?, ?, ?)`,
		now, label, seed,
	)
	if err != nil {
		http.Error(w, "insert session: "+err.Error(), http.StatusInternalServerError)
		return
	}
	id, err := res.LastInsertId()
	if err != nil {
		http.Error(w, "lastinsertid: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("lynrummy-elm session: new id=%d seed=%d label=%q", id, seed, label)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprintf(w, `{"session_id":%d}`, id)
}

// mathRandInt63 returns a random int63 for seeding. Wraps
// math/rand.Int63 so we keep the import local.
func mathRandInt63() int64 {
	return mathRand.Int63()
}

// lynrummyElmNewPuzzleSession creates a session whose initial state
// is hand-crafted (not the dealer's deal). Body is a JSON envelope:
//
//	{"label": "...", "initial_state": {...State JSON...}}
//
// The state is stored in lynrummy_puzzle_seeds; replaySessionNoHTTP
// returns this state (plus any applied actions) when a row exists.
// Used by the decomposition harness to stage narrow puzzles that
// isolate one trick at a time.
func lynrummyElmNewPuzzleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	var req struct {
		Label        string          `json:"label"`
		InitialState json.RawMessage `json:"initial_state"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.InitialState) == 0 {
		http.Error(w, "missing initial_state", http.StatusBadRequest)
		return
	}

	// Validate that initial_state decodes into a lynrummy.State so
	// we reject malformed puzzles at submit time (not at replay).
	var state lynrummy.State
	if err := json.Unmarshal(req.InitialState, &state); err != nil {
		http.Error(w, "initial_state decode: "+err.Error(), http.StatusBadRequest)
		return
	}

	now := time.Now().Unix()
	// deck_seed is unused for puzzle sessions (the initial state is
	// read from lynrummy_puzzle_seeds). Store 0 as a signal.
	res, err := DB.Exec(
		`INSERT INTO lynrummy_elm_sessions (created_at, label, deck_seed) VALUES (?, ?, 0)`,
		now, req.Label,
	)
	if err != nil {
		http.Error(w, "insert session: "+err.Error(), http.StatusInternalServerError)
		return
	}
	sessionID, err := res.LastInsertId()
	if err != nil {
		http.Error(w, "lastinsertid: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := DB.Exec(
		`INSERT INTO lynrummy_puzzle_seeds (session_id, initial_state_json) VALUES (?, ?)`,
		sessionID, string(req.InitialState),
	); err != nil {
		http.Error(w, "insert puzzle seed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("lynrummy-elm puzzle session: new id=%d label=%q", sessionID, req.Label)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprintf(w, `{"session_id":%d}`, sessionID)
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
	var env struct {
		Action          json.RawMessage `json:"action"`
		GestureMetadata json.RawMessage `json:"gesture_metadata,omitempty"`
	}
	if err := json.Unmarshal(body, &env); err != nil || len(env.Action) == 0 {
		log.Printf("lynrummy-elm action: envelope parse err=%v body=%s", err, body)
		http.Error(w, "expected envelope {action, gesture_metadata?}", http.StatusBadRequest)
		return
	}
	action, err := lynrummy.DecodeWireAction(env.Action)
	if err != nil {
		log.Printf("lynrummy-elm action: decode err=%v action=%s", err, env.Action)
		http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
		return
	}
	sessionIDStr := r.URL.Query().Get("session")
	sessionIDForExpand, _ := strconv.ParseInt(sessionIDStr, 10, 64)

	_ = sessionIDForExpand // PlayTrickAction expansion retired with hints/tricks rip.
	sessionID, err := strconv.ParseInt(sessionIDStr, 10, 64)
	if err != nil || sessionID <= 0 {
		log.Printf("lynrummy-elm action: bad/missing session param=%q", sessionIDStr)
		http.Error(w, "missing or bad ?session=<id>", http.StatusBadRequest)
		return
	}

	// CompleteTurn referee gate + classification. Mirrors
	// Game.maybe_complete_turn in TS game.ts: the board must pass
	// ValidateTurnComplete (geometry + semantics — no incomplete /
	// bogus / dup stacks) before a turn can end. After the gate,
	// classify which variant of success this is so the client can
	// surface a per-branch status message.
	//
	// We also return the EXACT cards the server just dealt to the
	// outgoing player. Client applies the turn transition locally
	// on response receipt — no follow-up /state fetch required.
	// One round-trip, authoritative data in hand.
	var turnResult lynrummy.CompleteTurnResult
	var turnScore, cardsDrawn int
	var dealtCards []lynrummy.Card
	if _, isComplete := action.(lynrummy.CompleteTurnAction); isComplete {
		state, ok, stateErr := replaySessionNoHTTP(sessionID)
		if stateErr != nil {
			log.Printf("lynrummy-elm action: complete_turn replay err=%v", stateErr)
			http.Error(w, "replay: "+stateErr.Error(), http.StatusInternalServerError)
			return
		}
		if !ok {
			http.Error(w, "session not found", http.StatusNotFound)
			return
		}
		bounds := lynrummy.BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 5}
		if refErr := lynrummy.ValidateTurnComplete(state.Board, bounds); refErr != nil {
			log.Printf("lynrummy-elm action: complete_turn rejected session=%d stage=%s msg=%s",
				sessionID, refErr.Stage, refErr.Message)
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, `{"ok":false,"turn_result":%q,"stage":%q,"message":%q}`,
				lynrummy.TurnResultFailure, refErr.Stage, refErr.Message)
			return
		}
		turnResult = lynrummy.ClassifyTurnResult(state, state.VictorAwarded)

		// Apply the transition in-memory so we can report turn_score,
		// cards_drawn, AND the exact cards dealt. The persisted apply
		// happens on the next /state replay; this computation drives
		// the client's single-round-trip transition.
		outgoing := state.ActivePlayerIndex
		post := lynrummy.ApplyAction(lynrummy.CompleteTurnAction{}, state)
		if outgoing < len(post.Scores) && outgoing < len(state.Scores) {
			turnScore = post.Scores[outgoing] - state.Scores[outgoing]
		}
		if outgoing < len(post.Hands) && outgoing < len(state.Hands) {
			preHand := state.Hands[outgoing].HandCards
			postHand := post.Hands[outgoing].HandCards
			cardsDrawn = len(postHand) - len(preHand)
			// New cards are the suffix — ApplyAction appends drawn
			// cards to the outgoing hand in order. Belt-and-braces:
			// take len(post) - len(pre) from the end regardless.
			if cardsDrawn > 0 {
				dealt := postHand[len(postHand)-cardsDrawn:]
				dealtCards = make([]lynrummy.Card, len(dealt))
				for i, hc := range dealt {
					dealtCards[i] = hc.Card
				}
			}
		}
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

	var gestureArg interface{}
	if len(env.GestureMetadata) > 0 && string(env.GestureMetadata) != "null" {
		gestureArg = string(env.GestureMetadata)
	}
	if _, err := DB.Exec(
		`INSERT INTO lynrummy_elm_actions (session_id, seq, action_kind, action_json, gesture_metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		sessionID, nextSeq, action.ActionKind(), string(env.Action), gestureArg, time.Now().Unix(),
	); err != nil {
		log.Printf("lynrummy-elm action: insert err=%v", err)
		http.Error(w, "insert: "+err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("lynrummy-elm action: session=%d seq=%d kind=%s payload=%s gesture=%d",
		sessionID, nextSeq, action.ActionKind(), env.Action, len(env.GestureMetadata))
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if turnResult != "" {
		dealtJSON, err := json.Marshal(dealtCards)
		if err != nil {
			dealtJSON = []byte("[]")
		}
		fmt.Fprintf(w,
			`{"ok":true,"seq":%d,"turn_result":%q,"turn_score":%d,"cards_drawn":%d,"dealt_cards":%s}`,
			nextSeq, turnResult, turnScore, cardsDrawn, dealtJSON)
	} else {
		fmt.Fprintf(w, `{"ok":true,"seq":%d}`, nextSeq)
	}
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

// lynrummyElmSessionsJSON returns the sessions list as JSON for
// the Elm client's lobby view. Mirrors the HTML /sessions
// endpoint's shape (id, created_at, label, action_count) but
// machine-readable.
func lynrummyElmSessionsJSON(w http.ResponseWriter) {
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

	type entry struct {
		ID          int64  `json:"id"`
		CreatedAt   int64  `json:"created_at"`
		Label       string `json:"label"`
		ActionCount int    `json:"action_count"`
	}
	var out []entry
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.ID, &e.CreatedAt, &e.Label, &e.ActionCount); err != nil {
			continue
		}
		out = append(out, e)
	}
	if out == nil {
		out = []entry{}
	}

	payload := struct {
		Sessions []entry `json:"sessions"`
	}{Sessions: out}

	body, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, "marshal: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(body)
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

	// Replay first (opens + closes its own DB query). If we hold
	// the outer rows open across a nested DB.Query, SQLite deadlocks
	// on the shared connection.
	state, ok, _ := replaySessionNoHTTP(id)
	var currentScore int
	var handSize int
	if ok {
		currentScore = lynrummy.ScoreForStacks(state.Board)
		handSize = state.ActiveHand().Size()
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
.stat { display: inline-block; margin-right: 24px; }
.stat b { color: #000080; font-variant-numeric: tabular-nums; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
table { border-collapse: collapse; width: 100%%; }
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
<p class="sub"><span class="stat">Board score <b>%d</b></span><span class="stat">Hand size <b>%d</b></span></p>
<table><tr><th>seq</th><th>kind</th><th>payload</th></tr>`,
		id, id, html.EscapeString(ts), labelSuffix(label), currentScore, handSize)

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

// lynrummyElmSessionState reconstructs the current game state for
// a session by replaying its action log from the initial state.
// JSON response: {"session_id":N,"seq":M,"state":{"board":[...],"hand":{...}}}.
// Python player reads this to know the current board/hand.
func lynrummyElmSessionState(w http.ResponseWriter, idStr string) {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, nil)
		return
	}

	state, ok := replaySession(w, id)
	if !ok {
		return
	}

	var seq int64
	_ = DB.QueryRow(
		`SELECT COALESCE(MAX(seq), 0) FROM lynrummy_elm_actions WHERE session_id = ?`, id,
	).Scan(&seq)

	payload := struct {
		SessionID int64          `json:"session_id"`
		Seq       int64          `json:"seq"`
		State     lynrummy.State `json:"state"`
	}{
		SessionID: id,
		Seq:       seq,
		State:     state,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, "marshal: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(body)
}

// lynrummyElmSessionScore returns the current board-score for a
// session, computed by replaying its action log + summing
// ScoreForStack across the resulting board. Hand value is reported
// as cards-remaining (real hand-score penalty requires turn logic
// that isn't modeled yet). This is the agent's numeric window into
// gameplay — "how much is the current board worth?"
func lynrummyElmSessionScore(w http.ResponseWriter, idStr string) {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, nil)
		return
	}

	state, ok := replaySession(w, id)
	if !ok {
		return
	}

	boardScore := lynrummy.ScoreForStacks(state.Board)

	// Per-stack breakdown helps the caller understand where points
	// are coming from.
	type stackEntry struct {
		Index int    `json:"index"`
		Size  int    `json:"size"`
		Type  string `json:"type"`
		Score int    `json:"score"`
	}
	entries := make([]stackEntry, 0, len(state.Board))
	for i, s := range state.Board {
		entries = append(entries, stackEntry{
			Index: i,
			Size:  s.Size(),
			Type:  string(s.Type()),
			Score: lynrummy.ScoreForStack(s),
		})
	}

	payload := struct {
		SessionID   int64        `json:"session_id"`
		BoardScore  int          `json:"board_score"`
		HandSize    int          `json:"hand_size"`
		PerStack    []stackEntry `json:"per_stack"`
	}{
		SessionID:  id,
		BoardScore: boardScore,
		HandSize:   state.ActiveHand().Size(),
		PerStack:   entries,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, "marshal: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(body)
}

// lynrummyElmSessionActions returns the session's raw action log
// as an ordered list of WireAction JSON blobs, plus the
// pre-first-action initial state. This is what an Elm client
// resuming a session fetches to populate its local `actionLog`
// AND its replay-baseline snapshot — so Instant Replay has
// something to rewind to that matches the session's actual
// seeded deal (rather than the hardcoded Dealer fixtures).
//
// Response shape:
//
//	{
//	  "session_id": N,
//	  "initial_state": { board, hands, deck, ... },
//	  "actions": [<raw WireAction JSON>...]
//	}
//
// The `actions` entries are emitted verbatim from the database —
// the same shape the server decodes via lynrummy.DecodeWireAction,
// and the same shape the Elm client produces via WA.encode.
// The `initial_state` is `lynrummy.InitialStateWithSeed(seed)` —
// the authoritative pre-first-action snapshot.
func lynrummyElmSessionActions(w http.ResponseWriter, idStr string) {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, nil)
		return
	}

	var seed int64
	if err := DB.QueryRow(
		`SELECT deck_seed FROM lynrummy_elm_sessions WHERE id = ?`, id,
	).Scan(&seed); err != nil {
		if err == sql.ErrNoRows {
			http.NotFound(w, nil)
			return
		}
		http.Error(w, "session lookup: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Puzzle sessions override the dealer-derived initial state
	// (same branch as replaySessionNoHTTP). Without this, Instant
	// Replay rewinds to the wrong board.
	var initialJSON []byte
	var puzzleJSON string
	err = DB.QueryRow(
		`SELECT initial_state_json FROM lynrummy_puzzle_seeds WHERE session_id = ?`, id,
	).Scan(&puzzleJSON)
	if err == sql.ErrNoRows {
		initial := lynrummy.InitialStateWithSeed(seed)
		initialJSON, err = json.Marshal(initial)
		if err != nil {
			http.Error(w, "marshal initial: "+err.Error(), http.StatusInternalServerError)
			return
		}
	} else if err != nil {
		http.Error(w, "puzzle seed lookup: "+err.Error(), http.StatusInternalServerError)
		return
	} else {
		initialJSON = []byte(puzzleJSON)
	}

	rows, err := DB.Query(
		`SELECT action_json, gesture_metadata FROM lynrummy_elm_actions WHERE session_id = ? ORDER BY seq`,
		id,
	)
	if err != nil {
		http.Error(w, "query actions: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	// Each action entry is an envelope-shaped object:
	//   {"action": <WireAction>, "gesture_metadata": <nullable>}
	// Same shape as the inbound POST body; keeps capture and
	// replay on the same wire contract.
	var buf bytes.Buffer
	fmt.Fprintf(&buf, `{"session_id":%d,"initial_state":%s,"actions":[`, id, initialJSON)
	first := true
	for rows.Next() {
		var payload string
		var gesture sql.NullString
		if err := rows.Scan(&payload, &gesture); err != nil {
			continue
		}
		if !first {
			buf.WriteByte(',')
		}
		first = false
		buf.WriteByte('{')
		buf.WriteString(`"action":`)
		buf.WriteString(payload)
		if gesture.Valid && gesture.String != "" {
			buf.WriteString(`,"gesture_metadata":`)
			buf.WriteString(gesture.String)
		}
		buf.WriteByte('}')
	}
	buf.WriteString("]}")

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(buf.Bytes())
}

// lynrummyElmSessionTurnLog walks the session's action log,
// grouping actions by CompleteTurn boundary and computing per-turn
// summaries: actions played, cards released from hand, score delta,
// trick ids used. Intended for agent-side analysis and for the
// Elm replay UI.
//
// Note: uses the RAW log (not EffectiveActions), so undone moves
// still appear with their trick annotations. An agent that wants
// only "effective" history can filter post-hoc.
func lynrummyElmSessionTurnLog(w http.ResponseWriter, idStr string) {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, nil)
		return
	}

	var seed int64
	if err := DB.QueryRow(
		`SELECT deck_seed FROM lynrummy_elm_sessions WHERE id = ?`, id,
	).Scan(&seed); err != nil {
		if err == sql.ErrNoRows {
			http.NotFound(w, nil)
			return
		}
		http.Error(w, "session lookup: "+err.Error(), http.StatusInternalServerError)
		return
	}

	rows, err := DB.Query(
		`SELECT seq, action_kind, action_json FROM lynrummy_elm_actions WHERE session_id = ? ORDER BY seq`,
		id,
	)
	if err != nil {
		http.Error(w, "query actions: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type actionEntry struct {
		Seq        int64  `json:"seq"`
		Kind       string `json:"kind"`
		TrickID    string `json:"trick_id,omitempty"`
		ScoreAfter int    `json:"score_after"`
	}
	type turnEntry struct {
		TurnIndex   int           `json:"turn_index"`
		Actions     []actionEntry `json:"actions"`
		ScoreBefore int           `json:"score_before"`
		ScoreAfter  int           `json:"score_after"`
		CardsPlayed int           `json:"cards_played"`
		TurnBonus   int           `json:"turn_bonus"`
	}

	state := lynrummy.InitialStateWithSeed(seed)
	currentTurn := turnEntry{TurnIndex: 0, ScoreBefore: lynrummy.ScoreForStacks(state.Board)}
	var turns []turnEntry

	for rows.Next() {
		var seq int64
		var kind, jsonBytes string
		if err := rows.Scan(&seq, &kind, &jsonBytes); err != nil {
			continue
		}
		action, err := lynrummy.DecodeWireAction([]byte(jsonBytes))
		if err != nil {
			continue
		}

		// Retroactive trick annotation retired 2026-04-18 with the
		// hints/tricks rip. Kind + score is enough for now.
		preActive := state.ActivePlayerIndex
		handBefore := state.Hands[preActive].Size()
		state = lynrummy.ApplyAction(action, state)
		cardsReleased := handBefore - state.Hands[preActive].Size()
		if cardsReleased > 0 {
			currentTurn.CardsPlayed += cardsReleased
		}
		currentTurn.Actions = append(currentTurn.Actions, actionEntry{
			Seq:        seq,
			Kind:       kind,
			ScoreAfter: lynrummy.ScoreForStacks(state.Board),
		})

		if _, isComplete := action.(lynrummy.CompleteTurnAction); isComplete {
			currentTurn.ScoreAfter = lynrummy.ScoreForStacks(state.Board)
			currentTurn.TurnBonus = lynrummy.ScoreForCardsPlayed(currentTurn.CardsPlayed)
			turns = append(turns, currentTurn)
			currentTurn = turnEntry{
				TurnIndex:   state.TurnIndex,
				ScoreBefore: currentTurn.ScoreAfter,
			}
		}
	}
	// Include the in-progress (not-yet-completed) turn if any.
	if len(currentTurn.Actions) > 0 {
		currentTurn.ScoreAfter = lynrummy.ScoreForStacks(state.Board)
		currentTurn.TurnBonus = lynrummy.ScoreForCardsPlayed(currentTurn.CardsPlayed)
		turns = append(turns, currentTurn)
	}

	payload := struct {
		SessionID int64       `json:"session_id"`
		Turns     []turnEntry `json:"turns"`
	}{SessionID: id, Turns: turns}

	body, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, "marshal: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(body)
}

// replaySession is the HTTP-handler version: DB errors become
// HTTP responses. Wraps replaySessionNoHTTP.
func replaySession(w http.ResponseWriter, id int64) (lynrummy.State, bool) {
	state, ok, err := replaySessionNoHTTP(id)
	if err != nil {
		if err == sql.ErrNoRows {
			http.NotFound(w, nil)
		} else {
			http.Error(w, "replay: "+err.Error(), http.StatusInternalServerError)
		}
		return lynrummy.State{}, false
	}
	if !ok {
		http.NotFound(w, nil)
		return lynrummy.State{}, false
	}
	return state, true
}


// replaySessionNoHTTP is the plain data-layer version. Returns
// (state, ok, err). ok=false with nil err means "session not
// found"; non-nil err means "DB problem."
func replaySessionNoHTTP(id int64) (lynrummy.State, bool, error) {
	var seed int64
	err := DB.QueryRow(
		`SELECT deck_seed FROM lynrummy_elm_sessions WHERE id = ?`, id,
	).Scan(&seed)
	if err == sql.ErrNoRows {
		return lynrummy.State{}, false, nil
	}
	if err != nil {
		return lynrummy.State{}, false, err
	}

	// Puzzle sessions override the dealer-derived initial state.
	var puzzleJSON string
	err = DB.QueryRow(
		`SELECT initial_state_json FROM lynrummy_puzzle_seeds WHERE session_id = ?`, id,
	).Scan(&puzzleJSON)
	var initial lynrummy.State
	if err == sql.ErrNoRows {
		initial = lynrummy.InitialStateWithSeed(seed)
	} else if err != nil {
		return lynrummy.State{}, false, err
	} else {
		if err := json.Unmarshal([]byte(puzzleJSON), &initial); err != nil {
			return lynrummy.State{}, false, fmt.Errorf("puzzle state decode: %w", err)
		}
	}

	rows, err := DB.Query(
		`SELECT action_json FROM lynrummy_elm_actions WHERE session_id = ? ORDER BY seq`,
		id,
	)
	if err != nil {
		return lynrummy.State{}, false, err
	}
	defer rows.Close()

	var actions []lynrummy.WireAction
	for rows.Next() {
		var jsonBytes string
		if err := rows.Scan(&jsonBytes); err != nil {
			return lynrummy.State{}, false, err
		}
		action, err := lynrummy.DecodeWireAction([]byte(jsonBytes))
		if err != nil {
			log.Printf("lynrummy-elm replay: decode err=%v session=%d json=%s",
				err, id, jsonBytes)
			continue
		}
		actions = append(actions, action)
	}
	state := initial
	for _, a := range lynrummy.EffectiveActions(actions) {
		state = lynrummy.ApplyAction(a, state)
	}
	return state, true, nil
}

func lynrummyElmPlay(w http.ResponseWriter) {
	lynrummyElmPlayWithSession(w, 0)
}

// lynrummyElmPlayWithSession renders the play page with the
// session id baked into the initial flags. `sessionID == 0`
// means "launcher mode" — Elm boots fresh.
func lynrummyElmPlayWithSession(w http.ResponseWriter, sessionID int64) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	var flag string
	if sessionID > 0 {
		flag = fmt.Sprintf("%d", sessionID)
	} else {
		flag = "null"
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
  <a href="/gopher/wiki/gopher/games/lynrummy/elm-port-docs/">Elm source</a>
</div>
<div class="app-main">
<div id="root"></div>
<script src="/gopher/lynrummy-elm/elm.js"></script>
<script>
  // The session id is baked into the URL path
  // (/gopher/lynrummy-elm/play/<id>) and rendered server-side
  // into initialSessionId. Reload-safe — unlike the old #<id>
  // fragment which required JS-side parsing and was brittle.
  var initialSessionId = %s;
  var app = Elm.Main.init({
    node: document.getElementById("root"),
    flags: { initialSessionId: initialSessionId },
  });
  app.ports.setSessionPath.subscribe(function(sid) {
    var url = sid === "" ? "/gopher/lynrummy-elm/"
                         : "/gopher/lynrummy-elm/play/" + sid;
    history.replaceState(null, "", url);
  });
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
