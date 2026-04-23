// BOARD_LAB — a standalone Elm app that hosts a vertical list
// of curated LynRummy boards for study/tutorial. Always
// within-a-turn: no dealer, no deck, no turn cycling. Each
// demo is a static `(board, hand)` literal in Elm.
//
// label: SPIKE (board-lab)
//
// V1 surface is minimal: serve the page + compiled elm.js.
// The "Show me" button will eventually POST to a new endpoint
// that runs Python's strategy.choose_play + find_follow_up_merges
// + gesture_synth on the demo's initial state and returns the
// primitive+gesture sequence for Elm's replay walker.

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
  var app = Elm.Main.init({ node: document.getElementById("root") });
  // Opens the main lynrummy-elm puzzle session in a new tab so
  // the lab page stays available for the next puzzle.
  app.ports.openInNewTab.subscribe(function(url) {
    window.open(url, "_blank");
  });
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
