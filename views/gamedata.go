// gamedata: filesystem-backed storage for LynRummy session
// data. Dumb URL-keyed file store under games/lynrummy/data/;
// meta is last-write-wins, action/annotation files are append-
// only. Sequential session-id allocation via a per-namespace
// counter is the one smart exception.
//
// Per-line atomicity comes from POSIX append semantics (writes
// < PIPE_BUF are atomic); Lyn Rummy lines are well under 4 kB.
//
// Helpers below are thin (append / read with auto-mkdir);
// handlers compose them.
package views

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// GameDataRoot is the on-disk root for all LynRummy session data,
// set by SetDataRoot at startup. The default is repo-relative, for
// tooling/tests that run without a config. One level down is the
// username: everything for a player lives under {root}/{user}/.
var GameDataRoot = "games/lynrummy/data"

// SetDataRoot points session storage at the configured data dir.
// Called once at startup from main.
func SetDataRoot(root string) {
	GameDataRoot = root
}

// userRoot is {GameDataRoot}/{user} — a player's whole subtree.
func userRoot(user string) string {
	return filepath.Join(GameDataRoot, user)
}

// lynrummyElmRoot is the full-game namespace for a player.
func lynrummyElmRoot(user string) string {
	return filepath.Join(userRoot(user), "lynrummy-elm")
}

// puzzleRoot is the puzzle namespace for a player. The agent reads
// on-disk solutions to learn from past plays — same motivation as
// the full-game corpus.
func puzzleRoot(user string) string {
	return filepath.Join(userRoot(user), "puzzle")
}

// nextSessionIDPath is a player's full-game counter file.
func nextSessionIDPath(user string) string {
	return filepath.Join(userRoot(user), "next-session-id.txt")
}

// nextPuzzleIDPath is a player's puzzle counter file.
func nextPuzzleIDPath(user string) string {
	return filepath.Join(userRoot(user), "next-puzzle-id.txt")
}

// sessionIDMu serializes counter increments. Single-process
// server; a mutex is sufficient.
var sessionIDMu sync.Mutex

// allocateID is the shared counter-bump primitive. Reads the
// counter file, returns the current value, writes value+1.
// Auto-creates the file on first call.
func allocateID(path string) (int64, error) {
	sessionIDMu.Lock()
	defer sessionIDMu.Unlock()

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
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

// AllocateSessionID returns the next sequential full-game session
// id for a player, 1-based, persisted via their next-session-id.txt.
func AllocateSessionID(user string) (int64, error) {
	return allocateID(nextSessionIDPath(user))
}

// AllocatePuzzleSessionID returns the next sequential puzzle session
// id for a player, 1-based, persisted via their next-puzzle-id.txt.
func AllocatePuzzleSessionID(user string) (int64, error) {
	return allocateID(nextPuzzleIDPath(user))
}

// PuzzleSessionDir returns the on-disk directory for a puzzle
// session.
func PuzzleSessionDir(user string, sessionID int64) string {
	return filepath.Join(puzzleRoot(user), "sessions", strconv.FormatInt(sessionID, 10))
}

// WritePuzzleSessionFile writes body to <puzzle-session-dir>/<rel>,
// creating parent dirs as needed.
func WritePuzzleSessionFile(user string, sessionID int64, rel string, body []byte) error {
	full := filepath.Join(PuzzleSessionDir(user, sessionID), rel)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		return err
	}
	return os.WriteFile(full, body, 0644)
}

// PuzzleSessionExists reports whether a puzzle session
// directory is on disk.
func PuzzleSessionExists(user string, sessionID int64) bool {
	info, err := os.Stat(PuzzleSessionDir(user, sessionID))
	return err == nil && info.IsDir()
}

// AppendPuzzleSessionLine appends one line to
// <puzzle-session-dir>/<rel>.
func AppendPuzzleSessionLine(user string, sessionID int64, rel string, body []byte) error {
	return AppendJSONLLine(filepath.Join(PuzzleSessionDir(user, sessionID), rel), body)
}

// SessionDir returns the on-disk directory for a full-game
// session.
func SessionDir(user string, sessionID int64) string {
	return filepath.Join(lynrummyElmRoot(user), "sessions", strconv.FormatInt(sessionID, 10))
}

// WriteSessionFile writes body to <session-dir>/<rel>, creating
// parent dirs as needed. `rel` is a relative path like `meta`.
func WriteSessionFile(user string, sessionID int64, rel string, body []byte) error {
	full := filepath.Join(SessionDir(user, sessionID), rel)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		return err
	}
	return os.WriteFile(full, body, 0644)
}

// ReadSessionFile reads <session-dir>/<rel>. Returns
// (nil, os.ErrNotExist) when the session or file is missing.
func ReadSessionFile(user string, sessionID int64, rel string) ([]byte, error) {
	full := filepath.Join(SessionDir(user, sessionID), rel)
	return os.ReadFile(full)
}

// SessionExists reports whether a full-game session directory
// is on disk.
func SessionExists(user string, sessionID int64) bool {
	info, err := os.Stat(SessionDir(user, sessionID))
	return err == nil && info.IsDir()
}

// AppendJSONLLine appends one JSON-encoded line to `path`. The
// body is run through json.Compact first (in case Elm sent
// pretty-printed JSON), then written as compact-body + '\n' in
// a single Write call so POSIX append-atomicity holds. Only
// annotations.jsonl uses this path now — wire-DSL actions take
// AppendTextLine instead.
func AppendJSONLLine(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, body); err != nil {
		return fmt.Errorf("compact: %w", err)
	}
	buf.WriteByte('\n')
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(buf.Bytes())
	return err
}

// AppendSessionLine appends one JSON-encoded line to
// <session-dir>/<rel>; the wire-DSL path uses
// AppendSessionDslLine instead.
func AppendSessionLine(user string, sessionID int64, rel string, body []byte) error {
	return AppendJSONLLine(filepath.Join(SessionDir(user, sessionID), rel), body)
}

// AppendTextLine appends `body` followed by a newline to `path`.
// No JSON validation — `body` is the literal line. Used by the
// wire-DSL action log (actions.dsl).
func AppendTextLine(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	var buf bytes.Buffer
	buf.Write(bytes.TrimRight(body, "\n"))
	buf.WriteByte('\n')
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(buf.Bytes())
	return err
}

// AppendSessionDslLine appends one DSL line to <session-dir>/<rel>
// for a full-game session. Used for actions.dsl on the wire.
func AppendSessionDslLine(user string, sessionID int64, rel string, body []byte) error {
	return AppendTextLine(filepath.Join(SessionDir(user, sessionID), rel), body)
}

// AppendPuzzleSessionDslLine appends one DSL line to a puzzle
// session's <rel> file.
func AppendPuzzleSessionDslLine(user string, sessionID int64, rel string, body []byte) error {
	return AppendTextLine(filepath.Join(PuzzleSessionDir(user, sessionID), rel), body)
}

// ReadTextLines returns the non-empty lines of `path`, or
// ([]string{}, nil) if the file doesn't exist.
func ReadTextLines(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if line != "" {
			out = append(out, line)
		}
	}
	return out, nil
}

// ReadSessionActionLines reads <session>/actions.dsl as a list
// of raw DSL lines.
func ReadSessionActionLines(user string, sessionID int64) ([]string, error) {
	return ReadTextLines(filepath.Join(SessionDir(user, sessionID), "actions.dsl"))
}

// CountTextLines returns the number of non-empty lines in
// `path`, or 0 if the file is missing.
func CountTextLines(path string) (int, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n := 0
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		if len(scanner.Bytes()) > 0 {
			n++
		}
	}
	return n, scanner.Err()
}

// CountSessionActions counts the lines in <session>/actions.dsl.
func CountSessionActions(user string, sessionID int64) (int, error) {
	return CountTextLines(filepath.Join(SessionDir(user, sessionID), "actions.dsl"))
}

// ListSessionIDs returns every full-game session-id directory for a
// player currently on disk, sorted ascending.
func ListSessionIDs(user string) ([]int64, error) {
	root := filepath.Join(lynrummyElmRoot(user), "sessions")
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

// ReadSessionMeta loads <session>/meta (the DSL file) and
// parses out the server-owned scalars. The game-state DSL stays
// verbatim in SessionMeta.GameStateDSL — server never edits it.
// Returns (zero, os.ErrNotExist) when missing.
func ReadSessionMeta(user string, sessionID int64) (SessionMeta, error) {
	body, err := ReadSessionFile(user, sessionID, "meta")
	if err != nil {
		return SessionMeta{}, err
	}
	return ParseSessionMeta(string(body)), nil
}

// SessionCreatedAt returns the meta's created_at, or 0 if
// absent. Used by HTML list pages.
func SessionCreatedAt(meta SessionMeta) int64 {
	return meta.CreatedAt
}

// SessionLabel returns meta.Label, or "".
func SessionLabel(meta SessionMeta) string {
	return meta.Label
}
