package views

import (
	"bufio"
	"fmt"
	"strconv"
	"strings"
)

// SessionMeta is the typed shape parsed out of a session's
// `meta` DSL file. CreatedAt and Label are server-owned scalars
// at the top of the file; the rest is the game-state DSL Elm
// authored, kept as a raw string and shipped back on resume.
type SessionMeta struct {
	CreatedAt    int64
	Label        string
	GameStateDSL string
}

// FormatSessionMeta renders the on-disk shape:
//
//	created_at: 1778500538
//	label:
//
//	board:
//	  at ( 20,  70): K♠ A♠ 2♠ 3♠
//	  ...
//
// Server-owned scalars on top, then a blank line, then the
// game-state DSL Elm authored. Game-state DSL is shipped
// verbatim — the server never edits or parses it beyond pass-
// through.
func FormatSessionMeta(m SessionMeta) string {
	var b strings.Builder
	fmt.Fprintf(&b, "created_at: %d\n", m.CreatedAt)
	fmt.Fprintf(&b, "label: %s\n", m.Label)
	b.WriteString("\n")
	b.WriteString(m.GameStateDSL)
	if !strings.HasSuffix(m.GameStateDSL, "\n") {
		b.WriteString("\n")
	}
	return b.String()
}

// ParseSessionMeta reads enough of a meta DSL document to fill
// SessionMeta.{CreatedAt, Label}. Leading `key: value` lines
// up to (and including) the first blank line are treated as
// server-owned scalars; everything after the blank line is the
// game-state DSL and preserved verbatim.
func ParseSessionMeta(src string) SessionMeta {
	var m SessionMeta
	scanner := bufio.NewScanner(strings.NewReader(src))
	bodyStart := 0
	scanned := 0
	consumedHeader := false
	for scanner.Scan() {
		line := scanner.Text()
		scanned += len(line) + 1 // +1 for the consumed newline
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			bodyStart = scanned
			consumedHeader = true
			break
		}
		k, v, ok := splitColon(trimmed)
		if !ok {
			// Reached non-scalar content (a section header like
			// `board:`) without a blank-line separator — treat
			// everything from here on as the body.
			bodyStart = scanned - len(line) - 1
			consumedHeader = true
			break
		}
		applyMetaScalar(&m, k, v)
	}
	if !consumedHeader {
		bodyStart = len(src)
	}
	m.GameStateDSL = src[bodyStart:]
	return m
}

func splitColon(line string) (string, string, bool) {
	i := strings.Index(line, ":")
	if i < 0 {
		return "", "", false
	}
	key := strings.TrimSpace(line[:i])
	val := strings.TrimSpace(line[i+1:])
	// `board:` and `Player ... Hand:` are section headers, not
	// scalars. Empty value AND the key matches one of those =
	// not a scalar.
	if val == "" && (key == "board" || strings.HasSuffix(key, "Hand")) {
		return "", "", false
	}
	return key, val, true
}

func applyMetaScalar(m *SessionMeta, key, val string) {
	switch key {
	case "created_at":
		if n, err := strconv.ParseInt(val, 10, 64); err == nil {
			m.CreatedAt = n
		}
	case "label":
		m.Label = val
	}
	// Unknown scalars are accepted-and-ignored — forward-compat
	// for fields Elm or future server iterations might add.
}
