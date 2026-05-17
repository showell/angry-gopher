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

// puzzleCatalogPath — curated puzzle catalog with positioned
// boards. Catalog is pure DSL: `puzzle <name>` headers, each
// followed by indented `at (left, top): cards` lines that pass
// straight through to Elm's Lib.BoardDsl on the wire. The whole
// file ships at page load; the Elm client renders one puzzle at
// a time with Prev/Next navigation.
const puzzleCatalogPath = "games/lynrummy/conformance/curated_4line_puzzles.dsl"

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

// indentLines prefixes every non-empty line of `src` with two
// spaces — turns a flat block into a body under a `<key>:`
// header. Empty lines pass through unchanged.
func indentLines(src string) string {
	lines := strings.Split(src, "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = "  " + l
		}
	}
	return strings.Join(lines, "\n")
}

// loadCatalog reads the catalog file and returns its body —
// `puzzle <name>` headers + indented `at (...)` lines, with
// comments and blank lines stripped. The Elm client parses
// this verbatim under a `catalog:` block in the page flag.
func loadCatalog() (string, error) {
	data, err := os.ReadFile(puzzleCatalogPath)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", puzzleCatalogPath, err)
	}
	var kept []string
	for _, raw := range strings.Split(string(data), "\n") {
		// Strip line comments (matches the DSL parsers
		// downstream so what we ship matches what gets parsed).
		line := raw
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimRight(line, " \t")
		if strings.TrimSpace(line) == "" {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n"), nil
}

// puzzlePage allocates a puzzle session, loads the full puzzle
// catalog, writes meta, and renders the HTML host with both
// `session_id` and the full catalog baked into the Elm flags.
// Zero post-load round trips before play.
//
// The flag carries a `catalog:` block — a sequence of
// `puzzle <name>` chunks each followed by indented
// `at (left, top): cards` lines. Elm's Lib.PuzzleFlagDsl slices
// the block into per-puzzle boards and lets the user navigate
// among them with Prev/Next.
func puzzlePage(w http.ResponseWriter) {
	catalogDSL, err := loadCatalog()
	if err != nil {
		http.Error(w, "load catalog: "+err.Error(), http.StatusInternalServerError)
		return
	}

	id, err := AllocatePuzzleSessionID()
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// meta DSL: server-owned scalars at the top, then a
	// snapshot of the catalog this session was bound to. The
	// catalog file can change between sessions; snapshotting
	// keeps each session replayable by `puzzle <idx>` index
	// even after the on-disk catalog drifts.
	metaDSL := fmt.Sprintf(
		"created_at: %d\n\ncatalog:\n%s\n",
		time.Now().Unix(),
		indentLines(catalogDSL),
	)
	if err := WritePuzzleSessionFile(id, "meta", []byte(metaDSL)); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Flag is one DSL string — `session_id:` scalar then a
	// `catalog:` block. Elm's Lib.PuzzleFlagDsl parses it whole.
	flagDSL := fmt.Sprintf(
		"session_id: %d\n\ncatalog:\n%s\n",
		id,
		indentLines(catalogDSL),
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
