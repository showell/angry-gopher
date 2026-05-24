package web

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// idMu serializes counter increments. Single-process server; a mutex is
// sufficient.
var idMu sync.Mutex

// AllocateID is the shared counter-bump primitive. Reads the counter file,
// returns the current value, writes value+1. Auto-creates the file on first
// call. Used for both user ids and per-user game/puzzle session ids.
func AllocateID(path string) (int64, error) {
	idMu.Lock()
	defer idMu.Unlock()

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
