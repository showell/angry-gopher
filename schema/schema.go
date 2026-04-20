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
-- harness to stage narrow test scenarios.
CREATE TABLE IF NOT EXISTS lynrummy_puzzle_seeds (
    session_id INTEGER PRIMARY KEY REFERENCES lynrummy_elm_sessions(id),
    initial_state_json TEXT NOT NULL
);
`
