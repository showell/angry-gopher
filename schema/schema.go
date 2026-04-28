// Package schema is the single source of truth for the Angry Gopher
// database schema. The DB now hosts only the seeded users
// table; LynRummy session data lives in
// games/lynrummy/data/ as plain JSON (LEAN_PASS phase 2,
// 2026-04-28).
package schema

const Core = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    full_name TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0
);
`
