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

-- One row per LynRummy Elm session. A session is a single
-- page-load of an Elm client — could be one full-game session
-- or one lab-puzzle session, distinguished by which actions
-- table the session's actions land in (see below).
-- deck_seed is non-zero for server-dealt full games and 0 for
-- puzzle / client-dealt sessions.
CREATE TABLE IF NOT EXISTS lynrummy_elm_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    deck_seed INTEGER NOT NULL DEFAULT 0
);

-- Full-game action log. One row per primitive (split,
-- merge_stack, merge_hand, place_hand, move_stack,
-- complete_turn, undo) crossing the wire during a regular
-- LynRummy game (mostly solitaire). seq is monotonic per
-- session_id. gesture_metadata is NULL for non-pointer actions
-- (button clicks, agent-emitted moves, complete_turn) and a
-- JSON pointer-path blob otherwise — same row kind, just no
-- gesture for those primitives.
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

-- Lab-puzzle action log. Same primitive shape as
-- lynrummy_elm_actions, but every row carries a puzzle_name —
-- one page-load (session_id) hosts attempts at multiple
-- puzzles, so puzzle_name is the disambiguator. seq is
-- monotonic per (session_id, puzzle_name): each puzzle
-- attempt's actions are their own ordered sequence inside the
-- session. gesture_metadata follows the same convention as
-- the full-game table.
CREATE TABLE IF NOT EXISTS lynrummy_elm_puzzle_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES lynrummy_elm_sessions(id),
    puzzle_name TEXT NOT NULL,
    seq INTEGER NOT NULL,
    action_kind TEXT NOT NULL,
    action_json TEXT NOT NULL,
    gesture_metadata TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_puzzle_actions_session ON lynrummy_elm_puzzle_actions(session_id, puzzle_name, seq);
CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_puzzle_actions_name ON lynrummy_elm_puzzle_actions(puzzle_name);

-- Initial state for sessions whose board isn't generated from
-- a deck_seed: client-dealt full games (Python-harness
-- scenarios that bypass the dealer) and the legacy curated
-- BOARD_LAB seeds. The lab no longer writes here — lab
-- catalog content carries puzzle initial states inline, so
-- new lab page-loads don't allocate seed rows. puzzle_name is
-- NULL for the client-dealt path.
CREATE TABLE IF NOT EXISTS lynrummy_puzzle_seeds (
    session_id INTEGER PRIMARY KEY REFERENCES lynrummy_elm_sessions(id),
    initial_state_json TEXT NOT NULL,
    puzzle_name TEXT
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_puzzle_seeds_name ON lynrummy_puzzle_seeds(puzzle_name);

-- Free-text notes humans add to a specific puzzle attempt
-- ("mouse slip on seq 2", "agent landing felt off"). Anchored
-- to session_id; puzzle_name is denormalized for tail-reading.
CREATE TABLE IF NOT EXISTS lynrummy_puzzle_annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    puzzle_name TEXT NOT NULL,
    user_name TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_puzzle_annotations_session ON lynrummy_puzzle_annotations(session_id);
`
