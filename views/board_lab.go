// BOARD_LAB — a standalone Elm app that hosts a vertical list
// of curated LynRummy puzzles. Always within-a-turn: no dealer,
// no deck, no turn cycling. Each panel auto-creates a puzzle
// session on page load and embeds a Main.Play instance via the
// existing /gopher/lynrummy-elm/new-puzzle-session endpoint.
//
// label: SPIKE (board-lab)
//
// Go surface here is minimal: serve the page (HTML chrome +
// bootstrap script) and the compiled elm.js. All puzzle-session
// creation + action persistence reuses the lynrummy-elm
// endpoints — no new Go endpoints added for the lab.

package views

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ElmBoardLabDir — compiled elm.js location. Mirrors
// ElmLynRummyDir's convention.
var ElmBoardLabDir = "games/lynrummy/board-lab/elm"

// HandleBoardLab dispatches /gopher/board-lab/*.
func HandleBoardLab(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/board-lab")
	sub = strings.TrimPrefix(sub, "/")
	switch sub {
	case "", "/":
		boardLabPage(w, "play")
	case "review", "review/":
		boardLabPage(w, "review")
	case "elm.js":
		boardLabJS(w)
	case "puzzles":
		boardLabPuzzles(w)
	case "annotate":
		boardLabAnnotate(w, r)
	case "agent-sessions":
		boardLabAgentSessions(w)
	default:
		http.NotFound(w, r)
	}
}

func boardLabPage(w http.ResponseWriter, mode string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	title := "BOARD_LAB"
	if mode == "review" {
		title = "BOARD_LAB — agent review"
	}
	fmt.Fprintf(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>%s</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
  .app-nav { padding: 8px 16px; background: #000080; color: white; font-size: 13px; }
  .app-nav a { color: white; text-decoration: none; margin-right: 14px; }
  .app-nav a:hover { text-decoration: underline; }
</style>
</head><body>
<div class="app-nav">
  <a href="/gopher/">← Gopher home</a>
  <a href="/gopher/game-lobby">Game lobby</a>
  <a href="/gopher/lynrummy-elm/">Play LynRummy</a>
  <a href="/gopher/board-lab/">Play lab</a>
  <a href="/gopher/board-lab/review">Review agent</a>
</div>
<div id="root"></div>
<script src="/gopher/board-lab/elm.js"></script>
<script>
  Elm.Lab.init({
    node: document.getElementById("root"),
    flags: { mode: %q }
  });
</script>
</body></html>`, title, mode)
}

func boardLabJS(w http.ResponseWriter) {
	path := filepath.Join(ElmBoardLabDir, "elm.js")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "elm.js not found — run `./check.sh` in "+ElmBoardLabDir, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}

// boardLabAnnotate accepts POST {session_id, puzzle_name,
// user_name, body} and appends a row to
// `board_lab_annotations`. Session-scoped — every annotation
// is a reply to one specific play. puzzle_name is stored
// alongside so the log tails cleanly without a JOIN on read.
func boardLabAnnotate(w http.ResponseWriter, r *http.Request) {
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
		SessionID  int64  `json:"session_id"`
		PuzzleName string `json:"puzzle_name"`
		UserName   string `json:"user_name"`
		Body       string `json:"body"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.PuzzleName = strings.TrimSpace(req.PuzzleName)
	req.UserName = strings.TrimSpace(req.UserName)
	req.Body = strings.TrimSpace(req.Body)
	if req.SessionID == 0 || req.PuzzleName == "" || req.Body == "" {
		http.Error(w, "session_id, puzzle_name and body are required",
			http.StatusBadRequest)
		return
	}
	if _, err := DB.Exec(
		`INSERT INTO board_lab_annotations (session_id, puzzle_name, user_name, body, created_at) VALUES (?, ?, ?, ?, ?)`,
		req.SessionID, req.PuzzleName, req.UserName, req.Body, time.Now().Unix(),
	); err != nil {
		http.Error(w, "insert: "+err.Error(),
			http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write([]byte(`{"ok":true}`))
}

// boardLabAgentSessions returns the latest "agent:..." session id
// per puzzle_name, so the lab's agent-review mode knows which
// session to replay for each puzzle panel. Shape:
//
//	{"sessions": {"tight_right_edge": 26, "pair_peel": 25, ...}}
//
// Puzzles with no agent attempt are omitted.
func boardLabAgentSessions(w http.ResponseWriter) {
	rows, err := DB.Query(
		`SELECT ps.puzzle_name, MAX(s.id)
		 FROM lynrummy_elm_sessions s
		 JOIN lynrummy_puzzle_seeds ps ON ps.session_id = s.id
		 WHERE s.label LIKE 'agent:%' AND ps.puzzle_name IS NOT NULL
		 GROUP BY ps.puzzle_name`,
	)
	if err != nil {
		http.Error(w, "query: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	out := map[string]int64{}
	for rows.Next() {
		var name string
		var id int64
		if err := rows.Scan(&name, &id); err != nil {
			http.Error(w, "scan: "+err.Error(), http.StatusInternalServerError)
			return
		}
		out[name] = id
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	enc := json.NewEncoder(w)
	_ = enc.Encode(map[string]interface{}{"sessions": out})
}

// boardLabPuzzles serves the Python-generated puzzle catalog.
// The JSON file is written by
// `games/lynrummy/python/board_lab_puzzles.py --write ...`
// as part of `ops/start`. If the file is missing (generator
// didn't run, e.g. fresh checkout), the response is a helpful
// 404 pointing at the command.
func boardLabPuzzles(w http.ResponseWriter) {
	// Catalog lives alongside the Elm project root, one level
	// above `elm/` so it's not confused with elm build output.
	path := filepath.Join(filepath.Dir(ElmBoardLabDir), "puzzles.json")
	data, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "puzzles.json not found — run "+
			"`python3 games/lynrummy/python/board_lab_puzzles.py "+
			"--write games/lynrummy/board-lab/puzzles.json`",
			http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(data)
}
