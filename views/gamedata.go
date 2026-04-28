// gamedata: filesystem-backed storage for LynRummy session data.
//
// The Go server is a dumb URL-keyed file store for LynRummy.
// POSTs land at paths under games/lynrummy/data/ that mirror
// the URL the Elm client hit. Last-write-wins per URL. The
// only "smart" exception is sequential session-id allocation
// via a single counter file.
//
// Filesystem layout:
//
//   games/lynrummy/data/
//     next-session-id.txt
//     lynrummy-elm/
//       sessions/<id>/
//         meta.json                 # {label, deck_seed, created_at, [puzzle_name, initial_state]}
//         actions/<seq>.json        # one file per action; Elm assigns seq
//         annotations/<seq>.json    # one file per annotation
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

// nextSessionIDPath is the counter file. A single file rather
// than per-table sequences keeps allocation cheap and visible.
var nextSessionIDPath = filepath.Join(GameDataRoot, "next-session-id.txt")

// sessionIDMu serializes counter increments. Single-process
// server; a mutex is sufficient.
var sessionIDMu sync.Mutex

// AllocateSessionID returns the next sequential session id,
// 1-based, persisted via games/lynrummy/data/next-session-id.txt.
// Auto-creates the file on first call.
func AllocateSessionID() (int64, error) {
	sessionIDMu.Lock()
	defer sessionIDMu.Unlock()

	if err := os.MkdirAll(GameDataRoot, 0755); err != nil {
		return 0, err
	}

	var n int64
	body, err := os.ReadFile(nextSessionIDPath)
	if err == nil {
		if parsed, perr := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64); perr == nil {
			n = parsed
		}
	}
	if n < 1 {
		n = 1
	}
	next := n + 1
	if err := os.WriteFile(nextSessionIDPath, []byte(strconv.FormatInt(next, 10)+"\n"), 0644); err != nil {
		return 0, err
	}
	return n, nil
}

// SessionDir returns the on-disk directory for a session.
func SessionDir(sessionID int64) string {
	return filepath.Join(lynrummyElmRoot, "sessions", strconv.FormatInt(sessionID, 10))
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

// SessionExists reports whether a session directory is on disk.
func SessionExists(sessionID int64) bool {
	info, err := os.Stat(SessionDir(sessionID))
	return err == nil && info.IsDir()
}

// ListSessionIDs returns every session-id directory currently
// on disk, sorted ascending.
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
// session (e.g. ["1.json","2.json",...]). Empty list if no
// actions yet or session missing.
func ListActionFiles(sessionID int64) ([]string, error) {
	return listSessionSubdir(sessionID, "actions")
}

// ListAnnotationFiles is the puzzle-side counterpart.
func ListAnnotationFiles(sessionID int64) ([]string, error) {
	return listSessionSubdir(sessionID, "annotations")
}

func listSessionSubdir(sessionID int64, sub string) ([]string, error) {
	dir := filepath.Join(SessionDir(sessionID), sub)
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
