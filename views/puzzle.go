// Puzzle V3 — drag-aware single-puzzle surface. Standard
// golang routing applies; storage shape mirrors the full game
// (`meta` DSL + `actions.dsl`), under
// `games/lynrummy/data/puzzle/sessions/<id>/`.

package views

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// PuzzleJSPath — the Puzzle V2 client's compiled JS lives
// alongside elm.js in the unified Elm project.
var PuzzleJSPath = "games/lynrummy/elm/puzzle.js"

// puzzleSeedsPath — pre-mined puzzles with positioned boards.
// Catalog is pure DSL: `puzzle <name>` headers, each followed by
// indented `at (top, left): cards` lines that pass straight
// through to Elm's Game.BoardDsl on the wire.
const puzzleSeedsPath = "games/lynrummy/conformance/mined_seeds.dsl"

// featuredPuzzleName — the puzzle every visit currently
// receives. Hardcoded; rotation / catalog selection can be
// added later without changing the wire.
const featuredPuzzleName = "mined_002_5D_5C"

// HandlePuzzle dispatches /gopher/puzzle/*.
func HandlePuzzle(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/puzzle")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		puzzlePage(w)
	case sub == "puzzle.js":
		serveJS(w, PuzzleJSPath, "puzzle.js not found — run `ops/build_elm`")
	case strings.HasPrefix(sub, "sessions/"):
		handlePuzzleSessionRoute(w, r, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

func handlePuzzleSessionRoute(w http.ResponseWriter, r *http.Request, rest string) {
	parts := strings.Split(rest, "/")
	idStr := parts[0]
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return
	}
	switch {
	case len(parts) == 2 && parts[1] == "actions":
		if r.Method == http.MethodPost {
			puzzleAppendAction(w, r, id)
		} else {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	default:
		http.NotFound(w, r)
	}
}

// puzzleAppendAction appends the POST body verbatim as one
// line in `actions.dsl`. The seq prefix is Elm-authored.
func puzzleAppendAction(w http.ResponseWriter, r *http.Request, sessionID int64) {
	if !PuzzleSessionExists(sessionID) {
		http.NotFound(w, r)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := AppendPuzzleSessionDslLine(sessionID, "actions.dsl", body); err != nil {
		http.Error(w, "append: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// loadPuzzleBoard reads mined_seeds.dsl and returns the
// named puzzle's body — the multi-line `at (top, left): cards`
// block that Game.BoardDsl on the Elm side parses. The catalog
// itself isn't JSON, so this is a thin string scan: find the
// `puzzle <name>` header line and return the indented body up
// to the next blank line or `puzzle ` header.
// indentLines prefixes every line of `src` with two spaces —
// turns a flat block of `at (...)` lines into a body under a
// `board:` header. Trailing blank lines are preserved as-is.
func indentLines(src string) string {
	lines := strings.Split(src, "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = "  " + l
		}
	}
	return strings.Join(lines, "\n")
}


func loadPuzzleBoard(name string) (string, error) {
	data, err := os.ReadFile(puzzleSeedsPath)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", puzzleSeedsPath, err)
	}
	header := "puzzle " + name
	var body []string
	inBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		if inBlock {
			if line == "" || strings.HasPrefix(line, "puzzle ") {
				break
			}
			body = append(body, strings.TrimLeft(line, " "))
			continue
		}
		if line == header {
			inBlock = true
		}
	}
	if !inBlock {
		return "", fmt.Errorf("puzzle %q not found in %s", name, puzzleSeedsPath)
	}
	return strings.Join(body, "\n"), nil
}

// puzzlePage allocates a puzzle session, loads the featured
// puzzle's initial board, writes meta.json, and renders the
// HTML host with both `session_id` and `initial_board` baked
// into the Elm flags. Zero post-load round trips before play.
//
// `initial_board` is the multi-line DSL string parsed by
// Game.BoardDsl on the Elm side — same grammar as the .dsl
// fixtures and the action-log wire.
func puzzlePage(w http.ResponseWriter) {
	boardDSL, err := loadPuzzleBoard(featuredPuzzleName)
	if err != nil {
		http.Error(w, "load puzzle: "+err.Error(), http.StatusInternalServerError)
		return
	}

	id, err := AllocatePuzzleSessionID()
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// meta DSL: server-owned scalars at the top, then the
	// `board:` block. Same shape the full-game flow uses, so
	// `cat`-ing the file shows the entire session header in one
	// view — no JSON escaping around the board content.
	metaDSL := fmt.Sprintf(
		"created_at: %d\npuzzle_name: %s\n\nboard:\n%s\n",
		time.Now().Unix(),
		featuredPuzzleName,
		indentLines(boardDSL),
	)
	if err := WritePuzzleSessionFile(id, "meta", []byte(metaDSL)); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Flag is one DSL string — `session_id:` scalar then a
	// `board:` block. Elm's Game.PuzzleFlagDsl parses it whole.
	// Same single-string shape the resume bundle uses for full
	// games, so the JS boundary carries the same canonical text.
	flagDSL := fmt.Sprintf(
		"session_id: %d\n\nboard:\n%s\n",
		id,
		indentLines(boardDSL),
	)
	flagJSON, err := json.Marshal(flagDSL)
	if err != nil {
		http.Error(w, "encode flag: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>Puzzle</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec; }
</style>
</head><body>
<div id="root"></div>
<script src="/gopher/puzzle/puzzle.js"></script>
<script>
  Elm.Puzzle.init({ node: document.getElementById("root"), flags: %s });
</script>
</body></html>`, flagJSON)
}
