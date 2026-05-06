// Puzzle V1 — single read-only puzzle surface.
//
// /gopher/puzzle/         → HTML host page
// /gopher/puzzle/puzzle.js → compiled Elm
//
// Built fresh post-puzzle-rip 2026-05-06: minimum viable
// puzzle, no interaction, no persistence, no engine. The
// Elm app loads, draws three hard-coded stacks via
// `Main.BoardView.viewBoard`, and stops there. Future
// iterations add interaction surface + extract more
// components from the game side.

package views

import (
	"fmt"
	"net/http"
	"strings"
)

// PuzzleJSPath — the Puzzle V1 client's compiled JS lives
// alongside elm.js in the unified Elm project.
var PuzzleJSPath = "games/lynrummy/elm/puzzle.js"

// HandlePuzzle dispatches /gopher/puzzle/*.
func HandlePuzzle(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/puzzle")
	sub = strings.TrimPrefix(sub, "/")
	switch sub {
	case "", "/":
		puzzlePage(w)
	case "puzzle.js":
		serveJS(w, PuzzleJSPath, "puzzle.js not found — run `ops/build_elm`")
	default:
		http.NotFound(w, r)
	}
}

func puzzlePage(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>Puzzle</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
</style>
</head><body>
<div id="root"></div>
<script src="/gopher/puzzle/puzzle.js"></script>
<script>
  Elm.Puzzle.init({ node: document.getElementById("root") });
</script>
</body></html>`)
}
