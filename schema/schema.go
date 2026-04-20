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
    -- Behaviorist telemetry for drag-derived actions (Split,
    -- MergeStack, MergeHand, PlaceHand, MoveStack). JSON blob with
    -- raw pointer path, pointer type, viewport at drag start, and
    -- devicePixelRatio. NULL for non-drag actions (CompleteTurn,
    -- Undo, PlayTrick, TrickResult) and for pre-telemetry rows.
    gesture_metadata TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_actions_session ON lynrummy_elm_actions(session_id, seq);
`
