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

-- LynRummy Elm client action log. V1 scaffolding: every page load
-- gets a new session; actions posted to /gopher/lynrummy-elm/actions
-- are stored with their WireAction JSON verbatim, sequenced per
-- session.
CREATE TABLE IF NOT EXISTS lynrummy_elm_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    deck_seed INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS lynrummy_elm_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES lynrummy_elm_sessions(id),
    seq INTEGER NOT NULL,
    action_kind TEXT NOT NULL,
    action_json TEXT NOT NULL,
    -- Raw pointer telemetry for every primitive wire action
    -- (split, merge_stack, merge_hand, place_hand, move_stack).
    -- JSON blob with pointer path samples (t, x, y), pointer
    -- type, viewport at drag start, devicePixelRatio. NULL for
    -- non-pointer actions (complete_turn, undo).
    gesture_metadata TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_actions_session ON lynrummy_elm_actions(session_id, seq);

-- Puzzle sessions: sessions whose initial state is hand-crafted
-- (not the dealer's deal). When a row is present for a session_id,
-- replaySessionNoHTTP uses this JSON as the initial state instead
-- of InitialStateWithSeed(deck_seed). Used by the decomposition
-- harness to stage narrow test scenarios AND by BOARD_LAB.
--
-- puzzle_name is the stable machine id of a catalog puzzle (e.g.
-- "tight_right_edge"). NULL for ad-hoc puzzles that aren't in a
-- catalog (e.g. the Python decomposition harness). For BOARD_LAB
-- sessions this is the key linking every solution — human or
-- agent — to the same named puzzle, so SELECT * FROM
-- lynrummy_puzzle_seeds WHERE puzzle_name = ... enumerates
-- attempts for analysis.
CREATE TABLE IF NOT EXISTS lynrummy_puzzle_seeds (
    session_id INTEGER PRIMARY KEY REFERENCES lynrummy_elm_sessions(id),
    initial_state_json TEXT NOT NULL,
    puzzle_name TEXT
);
CREATE INDEX IF NOT EXISTS idx_lynrummy_puzzle_seeds_name ON lynrummy_puzzle_seeds(puzzle_name);

-- BOARD_LAB annotations. A human playing or evaluating a
-- puzzle may want to jot context about a specific attempt
-- (e.g. "mouse slip on seq 2", "agent's landing loc feels
-- off"). One textarea per panel, same shape as the essay
-- comment surface in claude-collab.
--
-- Puzzle-level scoping — annotations attach to the puzzle,
-- not a specific session. Multiple annotations from the
-- same or different users accumulate. user_name lets us
-- filter by who wrote it.
CREATE TABLE IF NOT EXISTS board_lab_annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    puzzle_name TEXT NOT NULL,
    user_name TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_board_lab_annotations_puzzle ON board_lab_annotations(puzzle_name);
`
