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
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
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
		boardLabPage(w)
	case "elm.js":
		boardLabJS(w)
	case "puzzles":
		boardLabPuzzles(w)
	default:
		http.NotFound(w, r)
	}
}

func boardLabPage(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>BOARD_LAB</title>
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
</div>
<div id="root"></div>
<script src="/gopher/board-lab/elm.js"></script>
<script>
  Elm.Lab.init({ node: document.getElementById("root") });
</script>
</body></html>`)
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
