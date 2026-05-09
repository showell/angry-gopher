// Puzzle V2 — drag-aware single-puzzle surface with persisted
// action log.
//
// /gopher/puzzle/                              → HTML host page
// /gopher/puzzle/puzzle.js                     → compiled Elm
// POST /gopher/puzzle/sessions                 → allocate id, write meta.json
// POST /gopher/puzzle/sessions/<id>/actions    → append envelope to actions.jsonl
//
// Storage layout mirrors the full game's:
//   games/lynrummy/data/puzzle/sessions/<id>/
//     meta.json        — {created_at, initial_board}
//     actions.jsonl    — one Elm-sent envelope per line
//
// Wire shape is identical to the full game's actions.jsonl
// envelope: {seq, action: {...}}. The agent reads these on
// disk to study Steve's solutions — same motivation behind the
// full-game session corpus.

package views

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// PuzzleJSPath — the Puzzle V2 client's compiled JS lives
// alongside elm.js in the unified Elm project.
var PuzzleJSPath = "games/lynrummy/elm/puzzle.js"

// HandlePuzzle dispatches /gopher/puzzle/*.
func HandlePuzzle(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/puzzle")
	sub = strings.TrimPrefix(sub, "/")
	switch {
	case sub == "" || sub == "/":
		puzzlePage(w)
	case sub == "puzzle.js":
		serveJS(w, PuzzleJSPath, "puzzle.js not found — run `ops/build_elm`")
	case sub == "sessions":
		puzzleNewSession(w, r)
	case strings.HasPrefix(sub, "sessions/"):
		handlePuzzleSessionRoute(w, r, strings.TrimPrefix(sub, "sessions/"))
	default:
		http.NotFound(w, r)
	}
}

// handlePuzzleSessionRoute fans out the per-session URL space.
//
// POST /<id>/actions   append one envelope to actions.jsonl
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

// puzzleNewSession allocates a fresh puzzle session id. Body
// is optional but typically carries `{initial_board}` so the
// agent can reconstruct the starting state from meta.json
// alone.
func puzzleNewSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var bodyMap map[string]any
	if r.ContentLength > 0 {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
			return
		}
		if len(body) > 0 {
			if err := json.Unmarshal(body, &bodyMap); err != nil {
				http.Error(w, "decode body: "+err.Error(), http.StatusBadRequest)
				return
			}
		}
	}
	if bodyMap == nil {
		bodyMap = map[string]any{}
	}

	id, err := AllocatePuzzleSessionID()
	if err != nil {
		http.Error(w, "alloc id: "+err.Error(), http.StatusInternalServerError)
		return
	}
	bodyMap["created_at"] = time.Now().Unix()

	metaJSON, err := json.MarshalIndent(bodyMap, "", "  ")
	if err != nil {
		http.Error(w, "encode meta: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := WritePuzzleSessionFile(id, "meta.json", append(metaJSON, '\n')); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{"session_id": id})
}

// puzzleAppendAction is the dumb append handler for puzzle
// sessions. POST body → one appended line in actions.jsonl.
// The seq Elm assigned rides inside the body.
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
	if err := AppendPuzzleSessionLine(sessionID, "actions.jsonl", body); err != nil {
		http.Error(w, "append: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprint(w, `{"ok":true}`)
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
