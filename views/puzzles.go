// Puzzles — a standalone Elm app that hosts a vertical list
// of curated LynRummy puzzles. Always within-a-turn: no dealer,
// no deck, no turn cycling. No sign-on / login form: Lyn Rummy
// is a solo game (see project_solo_game_decision.md), so the
// "your name" gate that BOARD_LAB used for cross-user
// comparison was retired.
//
// Go surface:
//
//   GET  /gopher/puzzles/                                       page (HTML chrome)
//   GET  /gopher/puzzles/puzzles.js                             compiled Elm
//   GET  /gopher/puzzles/catalog                                {session_id, puzzles}
//   POST /gopher/puzzles/sessions/<id>/<puzzle_name>/action     write action
//   POST /gopher/puzzles/sessions/<id>/<puzzle_name>/annotate   write annotation
//
// Puzzle-session ids are allocated from their own counter
// (next-puzzle-session-id.txt) and live in their own on-disk
// namespace (data/lynrummy-elm/puzzle-sessions/<id>/...),
// distinct from full-game sessions. Each action write lands
// at puzzle-sessions/<id>/<puzzle_name>/actions/<seq>.json;
// annotations land alongside under .../annotations/<seq>.json
// with a per-puzzle seq picked server-side because the Elm
// side doesn't track an annotation seq counter.
//
// Path segments are URL-driven, not body-peeked: the handler
// reads session_id and puzzle_name from the URL only. The
// body carries the action / annotation payload verbatim.

package views

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// PuzzlesJSPath — the Puzzles app's compiled JS lives alongside
// the Main app's elm.js since the unification 2026-04-27. Both
// entry points (Main.elm, Puzzles.elm) compile into the same
// games/lynrummy/elm/ directory.
var PuzzlesJSPath = "games/lynrummy/elm/puzzles.js"

// PuzzlesCatalogPath — the catalog JSON the Puzzles gallery
// loads. Frozen as of 2026-05-04 (the legacy Python generator
// retired with the rest of the python/ subtree); refresh by
// writing a TS generator from scratch.
var PuzzlesCatalogPath = "games/lynrummy/puzzles/puzzles.json"

// HandlePuzzles dispatches /gopher/puzzles/*.
func HandlePuzzles(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/puzzles")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		puzzlesPage(w)
	case sub == "puzzles.js":
		puzzlesJS(w)
	case sub == "catalog":
		puzzlesCatalog(w)
	case strings.HasPrefix(sub, "sessions/"):
		handlePuzzleSessionRoute(w, r, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

// handlePuzzleSessionRoute fans out the per-puzzle URL space.
// `rest` is everything after "sessions/" — e.g.
//
//	"7/some-puzzle/action"  → write next-seq action
//	"7/some-puzzle/annotate" → write next-seq annotation
//
// Both segments come from the URL; the body carries only the
// payload. session_id and puzzle_name are validated here; the
// puzzle_name segment is rejected if path-unsafe.
func handlePuzzleSessionRoute(w http.ResponseWriter, r *http.Request, rest string) {
	parts := strings.Split(rest, "/")
	if len(parts) != 3 {
		http.NotFound(w, r)
		return
	}
	idStr, puzzleName, op := parts[0], parts[1], parts[2]

	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return
	}
	if puzzleName == "" || strings.ContainsAny(puzzleName, "/\\") || strings.Contains(puzzleName, "..") {
		http.Error(w, "bad puzzle_name", http.StatusBadRequest)
		return
	}
	if !PuzzleSessionExists(id) {
		http.NotFound(w, r)
		return
	}

	switch op {
	case "action":
		puzzleActionWrite(w, r, id, puzzleName)
	case "annotate":
		puzzleAnnotateWrite(w, r, id, puzzleName)
	default:
		http.NotFound(w, r)
	}
}

// puzzleActionWrite writes the POST body to
// puzzle-sessions/<id>/<puzzle_name>/actions/<seq>.json. The
// seq comes from the URL too — but here it's implicit: Elm
// posts to /action and the server picks the next seq, mirroring
// how annotations work. This keeps the Elm side ignorant of
// per-puzzle seq state across panels.
//
// (We could also accept an explicit seq path segment; we don't
// need to. Last-write-wins per URL would still hold; the
// next-seq pick is the simpler shape.)
func puzzleActionWrite(w http.ResponseWriter, r *http.Request, sessionID int64, puzzleName string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	files, _ := listDir(puzzleSubPath(sessionID, puzzleName, "actions"))
	nextSeq := int64(len(files) + 1)
	rel := puzzleName + "/actions/" + strconv.FormatInt(nextSeq, 10) + ".json"
	if err := WritePuzzleSessionFile(sessionID, rel, body); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprint(w, `{"ok":true}`)
}

// puzzleAnnotateWrite writes a per-puzzle annotation. Server
// picks the next seq under
// puzzle-sessions/<id>/<puzzle_name>/annotations/.
func puzzleAnnotateWrite(w http.ResponseWriter, r *http.Request, sessionID int64, puzzleName string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	files, _ := ListPuzzleSessionAnnotationFiles(sessionID, puzzleName)
	nextSeq := int64(len(files) + 1)
	rel := puzzleName + "/annotations/" + strconv.FormatInt(nextSeq, 10) + ".json"
	if err := WritePuzzleSessionFile(sessionID, rel, body); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write([]byte(`{"ok":true}`))
}

// puzzleSubPath builds <puzzle-session-dir>/<puzzleName>/<sub>.
func puzzleSubPath(sessionID int64, puzzleName, sub string) string {
	return PuzzleSessionDir(sessionID) + "/" + puzzleName + "/" + sub
}

func puzzlesPage(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html>
<html><head><meta charset="utf-8"><title>Puzzles</title>
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
  <a href="/gopher/puzzles/">Puzzles</a>
</div>
<div id="root"></div>
<script src="/gopher/puzzles/puzzles.js"></script>
<script>
  Elm.Puzzles.init({ node: document.getElementById("root") });
</script>
</body></html>`)
}

func puzzlesJS(w http.ResponseWriter) {
	data, err := os.ReadFile(PuzzlesJSPath)
	if err != nil {
		http.Error(w, "puzzles.js not found — run `elm make src/Puzzles.elm --output=puzzles.js` in games/lynrummy/elm/", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Write(data)
}

// puzzlesCatalog serves the puzzle catalog alongside a
// freshly-allocated puzzle-session id. The catalog JSON on
// disk is `{"puzzles": [...]}`. We allocate a session from
// the puzzle-session counter (the one smart exception in our
// otherwise-dumb surface), write a meta.json so the session
// dir is real, and merge the session_id into the response.
func puzzlesCatalog(w http.ResponseWriter) {
	catalogJSON, err := os.ReadFile(PuzzlesCatalogPath)
	if err != nil {
		http.Error(w, "puzzles.json not found — the catalog is "+
			"frozen; ship a fresh games/lynrummy/puzzles/puzzles.json",
			http.StatusNotFound)
		return
	}

	var catalog struct {
		Puzzles []json.RawMessage `json:"puzzles"`
	}
	if err := json.Unmarshal(catalogJSON, &catalog); err != nil {
		log.Printf("puzzles catalog: catalog decode err=%v", err)
		http.Error(w, "catalog decode: "+err.Error(), http.StatusInternalServerError)
		return
	}

	id, err := AllocatePuzzleSessionID()
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}
	meta := map[string]any{
		"label":      "puzzles page-load",
		"created_at": time.Now().Unix(),
	}
	metaJSON, _ := json.MarshalIndent(meta, "", "  ")
	if err := WritePuzzleSessionFile(id, "meta.json", append(metaJSON, '\n')); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	resp := struct {
		SessionID int64             `json:"session_id"`
		Puzzles   []json.RawMessage `json:"puzzles"`
	}{
		SessionID: id,
		Puzzles:   catalog.Puzzles,
	}
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		log.Printf("puzzles catalog: encode err=%v", err)
	}
}
