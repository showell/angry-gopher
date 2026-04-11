// Package schema is the single source of truth for the Angry Gopher
// database schema. Both the server (db.go) and the import tool
// (cmd/import) use this to create tables.
package schema

const Core = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    api_key TEXT NOT NULL DEFAULT '',
    is_admin INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS channels (
    channel_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    channel_weekly_traffic INTEGER NOT NULL DEFAULT 0,
    invite_only INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS channel_descriptions (
    channel_id INTEGER PRIMARY KEY REFERENCES channels(channel_id),
    markdown TEXT NOT NULL DEFAULT '',
    html TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS subscriptions (
    user_id INTEGER NOT NULL REFERENCES users(id),
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    PRIMARY KEY (user_id, channel_id)
);

CREATE TABLE IF NOT EXISTS topics (
    topic_id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    topic_name TEXT NOT NULL,
    UNIQUE(channel_id, topic_name)
);

CREATE TABLE IF NOT EXISTS message_content (
    content_id INTEGER PRIMARY KEY AUTOINCREMENT,
    markdown TEXT NOT NULL,
    html TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id INTEGER NOT NULL REFERENCES message_content(content_id),
    sender_id INTEGER NOT NULL REFERENCES users(id),
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    topic_id INTEGER NOT NULL REFERENCES topics(topic_id),
    timestamp INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS reactions (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    emoji_name TEXT NOT NULL,
    emoji_code TEXT NOT NULL,
    PRIMARY KEY (message_id, user_id, emoji_code)
);

CREATE TABLE IF NOT EXISTS unreads (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS invites (
    token TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS starred_messages (
    message_id INTEGER NOT NULL REFERENCES messages(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS buddies (
    user_id INTEGER NOT NULL REFERENCES users(id),
    buddy_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (user_id, buddy_id)
);

CREATE TABLE IF NOT EXISTS muted_users (
    user_id INTEGER NOT NULL REFERENCES users(id),
    muted_user_id INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (user_id, muted_user_id)
);

CREATE TABLE IF NOT EXISTS muted_topics (
    user_id INTEGER NOT NULL REFERENCES users(id),
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    topic_name TEXT NOT NULL,
    PRIMARY KEY (user_id, channel_id, topic_name)
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

CREATE TABLE IF NOT EXISTS github_repos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    channel_id INTEGER NOT NULL REFERENCES channels(channel_id),
    default_topic TEXT NOT NULL DEFAULT '',
    prefix TEXT NOT NULL DEFAULT '',
    UNIQUE(owner, name)
);

CREATE TABLE IF NOT EXISTS games (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game_type TEXT NOT NULL DEFAULT 'lynrummy',
    player1_id INTEGER NOT NULL REFERENCES users(id),
    player2_id INTEGER,
    created_at INTEGER NOT NULL,
    puzzle_name TEXT,
    status TEXT NOT NULL DEFAULT 'waiting'
);

CREATE TABLE IF NOT EXISTS game_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id INTEGER NOT NULL REFERENCES games(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

-- Full-text search via trigram tokenizer. Enables substring
-- matching on any 3+ character sequence, including URLs and
-- code snippets. Keyed by content_id so results join cleanly
-- back to messages.
CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
    content,
    content_id UNINDEXED,
    tokenize='trigram'
);

-- Indexes for search and pagination.
-- The (channel_id, id DESC) index is critical: without it, SQLite
-- uses the channel_id index for filtering but loses the ability to
-- walk the PK in reverse for LIMIT queries, turning 40µs pagination
-- into 500ms full scans at 10M rows.
CREATE INDEX IF NOT EXISTS idx_messages_channel_id_desc ON messages(channel_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_messages_channel_topic ON messages(channel_id, topic_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);

CREATE TABLE IF NOT EXISTS server_sessions (
    generation INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    git_commit TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS user_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    generation INTEGER NOT NULL REFERENCES server_sessions(generation),
    logged_in_at TEXT NOT NULL
);
`
