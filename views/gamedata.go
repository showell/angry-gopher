// gamedata: filesystem-backed storage for LynRummy session data.
//
// The Go server is a dumb URL-keyed file store for LynRummy.
// POSTs land at paths under games/lynrummy/data/ that mirror
// the URL the Elm client hit. Last-write-wins per URL. The
// only "smart" exception is sequential session-id allocation
// via a per-namespace counter file.
//
// Two top-level namespaces, each with its own id counter:
//
//   games/lynrummy/data/
//     next-session-id.txt                  # counter for full-game sessions
//     next-puzzle-session-id.txt           # counter for puzzle sessions
//     lynrummy-elm/
//       sessions/<id>/                     # full-game sessions
//         meta.json                        # {label, deck_seed, created_at, [initial_state]}
//         actions/<seq>.json               # full-game action; Elm assigns seq
//         annotations/<seq>.json           # full-game annotation (rare)
//       puzzle-sessions/<id>/              # puzzle gallery sessions
//         meta.json                        # {label, created_at}
//         <puzzle_name>/
//           actions/<seq>.json             # per-puzzle seq from Elm Play instance
//           annotations/<seq>.json         # per-puzzle seq picked server-side
//
// Puzzle sessions live in their own namespace because they
// are not resumable (single page-load attempts) and host many
// puzzles per session; per-puzzle subdirs keep each puzzle's
// seq=1 from clobbering its siblings. Full-game sessions stay
// flat (one game per session, one seq counter).
//
// Helpers below are deliberately thin — read/write/list with
// auto-mkdirs. Handlers compose them.
package views

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// GameDataRoot is the on-disk root for all LynRummy session
// data. Relative to repo root; Go server runs from there.
const GameDataRoot = "games/lynrummy/data"

const lynrummyElmRoot = GameDataRoot + "/lynrummy-elm"

// nextSessionIDPath is the full-game counter file. A single
// file rather than per-table sequences keeps allocation cheap
// and visible.
var nextSessionIDPath = filepath.Join(GameDataRoot, "next-session-id.txt")

// nextPuzzleSessionIDPath is the puzzle-session counter file.
// Distinct from the full-game counter so the two namespaces
// allocate independently.
var nextPuzzleSessionIDPath = filepath.Join(GameDataRoot, "next-puzzle-session-id.txt")

// sessionIDMu serializes counter increments. Single-process
// server; a mutex is sufficient. Shared across both counters
// since contention is negligible and the lock scope is tiny.
var sessionIDMu sync.Mutex

// allocateID is the shared counter-bump primitive. Reads the
// counter file, returns the current value, writes value+1.
// Auto-creates the file on first call.
func allocateID(path string) (int64, error) {
	sessionIDMu.Lock()
	defer sessionIDMu.Unlock()

	if err := os.MkdirAll(GameDataRoot, 0755); err != nil {
		return 0, err
	}

	var n int64
	body, err := os.ReadFile(path)
	if err == nil {
		if parsed, perr := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64); perr == nil {
			n = parsed
		}
	}
	if n < 1 {
		n = 1
	}
	next := n + 1
	if err := os.WriteFile(path, []byte(strconv.FormatInt(next, 10)+"\n"), 0644); err != nil {
		return 0, err
	}
	return n, nil
}

// AllocateSessionID returns the next sequential full-game
// session id, 1-based, persisted via
// games/lynrummy/data/next-session-id.txt.
func AllocateSessionID() (int64, error) {
	return allocateID(nextSessionIDPath)
}

// AllocatePuzzleSessionID returns the next sequential
// puzzle-session id, 1-based, persisted via
// games/lynrummy/data/next-puzzle-session-id.txt. Independent
// of the full-game counter.
func AllocatePuzzleSessionID() (int64, error) {
	return allocateID(nextPuzzleSessionIDPath)
}

// SessionDir returns the on-disk directory for a full-game
// session.
func SessionDir(sessionID int64) string {
	return filepath.Join(lynrummyElmRoot, "sessions", strconv.FormatInt(sessionID, 10))
}

// PuzzleSessionDir returns the on-disk directory for a
// puzzle-gallery session.
func PuzzleSessionDir(sessionID int64) string {
	return filepath.Join(lynrummyElmRoot, "puzzle-sessions", strconv.FormatInt(sessionID, 10))
}

// WriteSessionFile writes body to <session-dir>/<rel>, creating
// parent dirs as needed. `rel` is a relative path like
// "meta.json" or "actions/3.json".
func WriteSessionFile(sessionID int64, rel string, body []byte) error {
	full := filepath.Join(SessionDir(sessionID), rel)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		return err
	}
	return os.WriteFile(full, body, 0644)
}

// ReadSessionFile reads <session-dir>/<rel>. Returns
// (nil, os.ErrNotExist) when the session or file is missing.
func ReadSessionFile(sessionID int64, rel string) ([]byte, error) {
	full := filepath.Join(SessionDir(sessionID), rel)
	return os.ReadFile(full)
}

// SessionExists reports whether a full-game session directory
// is on disk.
func SessionExists(sessionID int64) bool {
	info, err := os.Stat(SessionDir(sessionID))
	return err == nil && info.IsDir()
}

// PuzzleSessionExists reports whether a puzzle-session
// directory is on disk.
func PuzzleSessionExists(sessionID int64) bool {
	info, err := os.Stat(PuzzleSessionDir(sessionID))
	return err == nil && info.IsDir()
}

// WritePuzzleSessionFile writes body to <puzzle-session-dir>/<rel>.
func WritePuzzleSessionFile(sessionID int64, rel string, body []byte) error {
	full := filepath.Join(PuzzleSessionDir(sessionID), rel)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		return err
	}
	return os.WriteFile(full, body, 0644)
}

// ListSessionIDs returns every full-game session-id directory
// currently on disk, sorted ascending.
func ListSessionIDs() ([]int64, error) {
	root := filepath.Join(lynrummyElmRoot, "sessions")
	if _, err := os.Stat(root); os.IsNotExist(err) {
		return nil, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		id, err := strconv.ParseInt(e.Name(), 10, 64)
		if err != nil || id <= 0 {
			continue
		}
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids, nil
}

// ListActionFiles returns the sorted action filenames for a
// full-game session (e.g. ["1.json","2.json",...]). Empty list
// if no actions yet or session missing. Full-game sessions
// keep actions flat; puzzle sessions live in a different dir
// and are not counted here.
func ListActionFiles(sessionID int64) ([]string, error) {
	return listSessionSubdir(sessionID, "actions")
}

// ListAnnotationFiles is the full-game counterpart for
// annotations.
func ListAnnotationFiles(sessionID int64) ([]string, error) {
	return listSessionSubdir(sessionID, "annotations")
}

// ListPuzzleSessionAnnotationFiles returns sorted annotation
// filenames under <puzzle-session>/<puzzleName>/annotations/.
// Used to pick the next seq for a per-puzzle annotation write.
func ListPuzzleSessionAnnotationFiles(sessionID int64, puzzleName string) ([]string, error) {
	dir := filepath.Join(PuzzleSessionDir(sessionID), puzzleName, "annotations")
	return listDir(dir)
}

func listSessionSubdir(sessionID int64, sub string) ([]string, error) {
	dir := filepath.Join(SessionDir(sessionID), sub)
	return listDir(dir)
}

func listDir(dir string) ([]string, error) {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		names = append(names, e.Name())
	}
	// Numeric-aware sort: "10.json" comes after "2.json".
	sort.Slice(names, func(i, j int) bool {
		return seqOf(names[i]) < seqOf(names[j])
	})
	return names, nil
}

// seqOf parses the seq number from a filename like "3.json".
// Returns -1 on parse failure (those sort first; they're noise).
func seqOf(name string) int64 {
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	n, err := strconv.ParseInt(stem, 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// ReadSessionMeta loads <session>/meta.json into a generic map.
// Returns (nil, os.ErrNotExist) when missing.
func ReadSessionMeta(sessionID int64) (map[string]any, error) {
	body, err := ReadSessionFile(sessionID, "meta.json")
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("decode meta.json: %w", err)
	}
	return m, nil
}

// SessionCreatedAt returns the meta's created_at as int64, or
// 0 if absent. Used by HTML lists.
func SessionCreatedAt(meta map[string]any) int64 {
	if v, ok := meta["created_at"]; ok {
		switch x := v.(type) {
		case float64:
			return int64(x)
		case int64:
			return x
		case int:
			return int64(x)
		}
	}
	return 0
}

// SessionLabel returns meta["label"] as string, or "".
func SessionLabel(meta map[string]any) string {
	if v, ok := meta["label"]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
