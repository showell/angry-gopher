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

CREATE TABLE IF NOT EXISTS games (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game_type TEXT NOT NULL DEFAULT 'lynrummy',
    player1_id INTEGER NOT NULL REFERENCES users(id),
    player2_id INTEGER,
    created_at INTEGER NOT NULL,
    puzzle_name TEXT,
    status TEXT NOT NULL DEFAULT 'waiting',
    label TEXT NOT NULL DEFAULT '',
    archived INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS game_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id INTEGER NOT NULL REFERENCES games(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

-- LynRummy-specific: structured metadata about each play (trick used,
-- human-readable description, cards involved, per-trick detail).
-- Strategic layer — generic game_events still stores the mechanical
-- board diff and hand-cards-to-release payload.
CREATE TABLE IF NOT EXISTS lynrummy_plays (
    event_id INTEGER PRIMARY KEY REFERENCES game_events(id),
    game_id INTEGER NOT NULL REFERENCES games(id),
    player INTEGER NOT NULL,
    trick_id TEXT NOT NULL,
    description TEXT NOT NULL,
    hand_cards_json TEXT NOT NULL,
    board_cards_json TEXT NOT NULL,
    detail_json TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_lynrummy_plays_game ON lynrummy_plays(game_id, event_id);
CREATE INDEX IF NOT EXISTS idx_lynrummy_plays_trick ON lynrummy_plays(trick_id);

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
    label TEXT NOT NULL DEFAULT ''
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
