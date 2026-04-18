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

CREATE TABLE IF NOT EXISTS dm_conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id_1 INTEGER NOT NULL REFERENCES users(id),
    user_id_2 INTEGER NOT NULL REFERENCES users(id),
    UNIQUE(user_id_1, user_id_2)
);

CREATE TABLE IF NOT EXISTS dm_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES dm_conversations(id),
    sender_id INTEGER NOT NULL REFERENCES users(id),
    content_id INTEGER NOT NULL REFERENCES message_content(content_id),
    timestamp INTEGER NOT NULL
);

-- CRITTER_STUDIES: telemetry from Elm critter-study sessions.
CREATE TABLE IF NOT EXISTS critter_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    study TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    saved_at TEXT NOT NULL,
    payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_critter_sessions_study ON critter_sessions(study, id DESC);

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
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_lynrummy_elm_actions_session ON lynrummy_elm_actions(session_id, seq);
`
