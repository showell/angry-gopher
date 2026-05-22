// Puzzles — drag-aware multi-puzzle surface. Catalog ships at page
// load; navigation lives entirely in the Elm client. On-disk shape
// under each player's puzzle/sessions/<id>/:
//
//   meta                       — session-level: created_at + catalog snapshot
//   puzzle_<idx>/actions.dsl   — one file per puzzle the user touched;
//                                lines are `<seq>) <action>` only.

package views

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// PuzzleJSPath — the Puzzle V2 client's compiled JS lives
// alongside elm.js in the unified Elm project.
var PuzzleJSPath = "games/lynrummy/elm/puzzle.js"

// puzzleCatalogPaths — curated puzzle catalogs concatenated in
// order to form the catalog shipped at page load. Catalogs are
// pure DSL: `puzzle <name>` headers, each followed by indented
// `at (left, top): cards` lines that pass straight through to
// Elm's Lib.BoardDsl on the wire. The Elm client renders one
// puzzle at a time with Prev/Next navigation; the 1-indexed
// "Puzzle N" label reflects the concatenated order. Catalogs are
// listed easiest-first, so the ranges are: 1-line Puzzle 1..10,
// 2-line 11..20, 3-line 21..30, 4-line 31..51, 5-line 52..62, and
// 6-line 63..77. The 1-line tier is hand-crafted and kept in its own
// teaching order (not card-count sorted like the mined tiers).
var puzzleCatalogPaths = []string{
	"games/lynrummy/conformance/curated_1line_puzzles.dsl",
	"games/lynrummy/conformance/curated_2line_puzzles.dsl",
	"games/lynrummy/conformance/curated_3line_puzzles.dsl",
	"games/lynrummy/conformance/curated_4line_puzzles.dsl",
	"games/lynrummy/conformance/curated_5line_puzzles.dsl",
	"games/lynrummy/conformance/curated_6line_puzzles.dsl",
}

// HandlePuzzles dispatches /puzzles/*.
func HandlePuzzles(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/puzzles")
	sub = strings.TrimPrefix(sub, "/")
	user := CurrentUser(r)
	switch {
	case sub == "" || sub == "/":
		puzzlePage(w, user)
	case sub == "puzzle.js":
		serveJS(w, PuzzleJSPath, "puzzle.js not found — run `ops/build_elm`")
	case strings.HasPrefix(sub, "sessions/"):
		handlePuzzleSessionRoute(w, r, user, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

func handlePuzzleSessionRoute(w http.ResponseWriter, r *http.Request, user, rest string) {
	parts := strings.Split(rest, "/")
	sessionID, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || sessionID <= 0 {
		http.NotFound(w, r)
		return
	}
	// Only route: POST /sessions/<id>/puzzles/<idx>/actions.
	// Each puzzle's actions append to its own actions.dsl
	// under sessions/<id>/puzzle_<idx>/, so the file shape is
	// just `<seq>) <action>` lines — no cross-puzzle
	// interleaving, no header bookkeeping.
	if len(parts) == 4 && parts[1] == "puzzles" && parts[3] == "actions" && r.Method == http.MethodPost {
		puzzleIdx, err := strconv.Atoi(parts[2])
		if err != nil || puzzleIdx < 0 {
			http.NotFound(w, r)
			return
		}
		puzzleAppendAction(w, r, user, sessionID, puzzleIdx)
		return
	}
	http.NotFound(w, r)
}

// puzzleAppendAction appends the POST body verbatim as one
// line in <session>/puzzle_<idx>/actions.dsl. Storage helper
// creates the per-puzzle directory on first append.
func puzzleAppendAction(w http.ResponseWriter, r *http.Request, user string, sessionID int64, puzzleIdx int) {
	if !PuzzleSessionExists(user, sessionID) {
		http.NotFound(w, r)
		return
	}
	body, ok := readLimitedBody(w, r, user, maxAppendBytes)
	if !ok {
		return
	}
	rel := fmt.Sprintf("puzzle_%d/actions.dsl", puzzleIdx)
	if err := AppendPuzzleSessionDslLine(user, sessionID, rel, body); err != nil {
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

// loadCatalog reads each catalog file in puzzleCatalogPaths,
// strips comments and blank lines, and concatenates the
// surviving lines. The Elm client parses the result verbatim
// under a `catalog:` block in the page flag.
func loadCatalog() (string, error) {
	var kept []string
	for _, p := range puzzleCatalogPaths {
		data, err := readAsset(p)
		if err != nil {
			return "", fmt.Errorf("read %s: %w", p, err)
		}
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
func puzzlePage(w http.ResponseWriter, user string) {
	catalogDSL, err := loadCatalog()
	if err != nil {
		http.Error(w, "load catalog: "+err.Error(), http.StatusInternalServerError)
		return
	}

	id, err := AllocatePuzzleSessionID(user)
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
	if err := WritePuzzleSessionFile(user, id, "meta", []byte(metaDSL)); err != nil {
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
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><title>♦️ Lyn Rummy ♥️</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #f4f4ec;
         touch-action: none; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
</style>
</head><body>
<div id="root"></div>
<script src="/puzzles/puzzle.js"></script>
<script>
  var app = Elm.Puzzle.init({ node: document.getElementById("root"), flags: %s });
  // Pointer transport: pointerdown captures the pointer; move/up are
  // forwarded to Elm. Capture set synchronously (no Elm round-trip) so
  // fast taps aren't missed; only the active pointer is forwarded.
  (function () {
    var captureEl = document.documentElement;
    var tracked = null;
    function sample(e) {
      return { x: Math.round(e.clientX), y: Math.round(e.clientY), t: Math.floor(e.timeStamp) };
    }
    document.addEventListener("pointerdown", function (e) {
      tracked = e.pointerId;
      // Capture touch/pen so a finger-drag survives the card re-rendering
      // mid-drag. Mouse needs no capture (document sees every move) and
      // capturing a mouse pointer can interfere with button clicks.
      if (e.pointerType !== "mouse") {
        try { captureEl.setPointerCapture(e.pointerId); } catch (err) {}
      }
    });
    document.addEventListener("pointermove", function (e) {
      if (e.pointerId === tracked) app.ports.pointerMoved.send(sample(e));
    });
    function end(e) {
      if (e.pointerId !== tracked) return;
      tracked = null;
      app.ports.pointerUp.send(sample(e));
    }
    document.addEventListener("pointerup", end);
    document.addEventListener("pointercancel", end);
  })();
</script>
</body></html>`, flagJSON)
}
