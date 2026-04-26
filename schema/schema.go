// Package schema is the single source of truth for the Angry Gopher
// database schema. Both the server (db.go) and the import tool
// (cmd/import) use this to create tables.
package schema

const Core = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    full_name TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS message_content (
    content_id INTEGER PRIMARY KEY AUTOINCREMENT,
    markdown TEXT NOT NULL,
    html TEXT NOT NULL
);

-- One row per LynRummy Elm session. deck_seed is non-zero for
-- server-dealt full games and 0 for puzzle / client-dealt
-- sessions (where the initial state lives in
-- lynrummy_puzzle_seeds instead).
CREATE TABLE IF NOT EXISTS lynrummy_elm_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    deck_seed INTEGER NOT NULL DEFAULT 0
);

-- Append-only WireAction log, sequenced per session. Each row
-- is one primitive (split / merge_stack / merge_hand /
-- place_hand / move_stack / complete_turn / undo) as it
-- crossed the wire. gesture_metadata carries pointer-path
-- telemetry for drag-derived actions; NULL otherwise (button
-- clicks, agent-emitted moves, complete_turn).
CREATE TABLE IF NOT EXISTS lynrummy_elm_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES lynrummy_elm_sessions(id),
    seq INTEGER NOT NULL,
    action_kind TEXT NOT NULL,
    action_json TEXT NOT NULL,
    gesture_metadata TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_actions_session ON lynrummy_elm_actions(session_id, seq);

-- Initial state for sessions whose board isn't generated from a
-- deck_seed: BOARD_LAB puzzles, client-dealt full games,
-- Python-harness scenarios. puzzle_name names a catalog puzzle
-- when present and is NULL for one-off client-dealt deals. The
-- name is the join key when grouping every attempt at the same
-- puzzle for analysis.
CREATE TABLE IF NOT EXISTS lynrummy_puzzle_seeds (
    session_id INTEGER PRIMARY KEY REFERENCES lynrummy_elm_sessions(id),
    initial_state_json TEXT NOT NULL,
    puzzle_name TEXT
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_puzzle_seeds_name ON lynrummy_puzzle_seeds(puzzle_name);

-- Free-text notes humans add to a specific puzzle attempt
-- ("mouse slip on seq 2", "agent landing felt off"). Anchored
-- to session_id; puzzle_name is denormalized for tail-reading.
CREATE TABLE IF NOT EXISTS board_lab_annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    puzzle_name TEXT NOT NULL,
    user_name TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_board_lab_annotations_session ON board_lab_annotations(session_id);
`
