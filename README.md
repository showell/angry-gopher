# Angry Gopher

A small, dependency-light Go server that hosts **Lyn Rummy** (a
single-human card game — Elm client + TypeScript agent) and a private
**chat** surface, plus a small admin view. Storage is plain files on
disk — **no database**. In prod it ships as one self-contained
`go:embed` binary behind Caddy (TLS) under systemd; see
[`deploy/README.md`](deploy/README.md).

## Quick start

```bash
bash ops/start        # Gopher on :9000
```

`ops/start` is the canonical dev loop: it kills anything on :9000,
rebuilds the Elm/TS bundles (`ops/build_elm`) and the Go binary —
which embeds those bundles (see `embed.go`) — then relaunches and waits
for the port to respond. Always use it; don't hand-roll `go run` /
`nohup ./gopher-server`.

The server needs `GOPHER_CONFIG` pointing at a config file (port +
`data_dir`); `ops/start` uses `~/AngryGopher/gopher.conf`. All
persistent data lives under that `data_dir`, outside the source tree —
the tree is freely rm-able without touching data, and vice versa.

## Routes

| Path | What |
|---|---|
| `/` | Home / launch pad |
| `/game`, `/game/<id>`, `/game/sessions` | Full-game Elm client + session storage |
| `/puzzles` | Single-board puzzle client |
| `/chat` | Private one-on-one chat (members only) |
| `/settings` | Per-user settings (read-only bot API key) |
| `/login`, `/login/full`, `/logout` | Guest name login / member password login |
| `/admin` | Session + user overview (requires the admin flag) |
| `/version` | Build version JSON |

Every request goes through a login gate (`main.go`): no resolvable
identity → redirect to `/login`. Login sets a `gopher_uid` cookie;
members additionally get a signed session cookie. Bot **API keys are
read-only** — a keyed request may only GET/HEAD.

## Layout

| Where | Role |
|---|---|
| `main.go`, `config.go`, `login.go`, `embed.go`, `home.go`, `registry.go` | server entry: config, mux + login gate, name login/logout, embedded assets, the home launch-pad, route registry |
| `auth/` | username validation + the raw identity claim (the numeric user id) |
| `server/web/` | shared base: identity (user registry), sessions, bot API keys, page chrome, embedded-asset serving. Imports neither subsystem. |
| `server/lynrummy/` | Lyn Rummy server: `/game` + `/puzzles` handlers + session file storage. Builds on `web`. |
| `server/chat/` | chat server: handlers, SSE hub + storage, markdown, image uploads, `/settings`. Builds on `web`. |
| `server/admin/` | the cross-cutting `/admin` overview (imports `web` + both subsystems) |
| `chat/` | the embedded chat **client** (`chat.js`) + the reference API client / example bot (`chat_client.py`: discover, read, post) |
| `games/lynrummy/elm/` | the autonomous Elm client (dealer + referee + UI) |
| `games/lynrummy/ts/` | the TypeScript agent — the strategic brain (solver + self-play) |
| `ops/` | the build / run / test scripts (`ops/list` enumerates them) |
| `deploy/` | Caddyfile, systemd unit, deploy runbook |

The Go server is dumb URL-keyed file storage; the strategic brain is the
TS agent, and the Elm client owns the full game (dealer, referee, UI).

## The DSL is the lingua franca

One short, canonical DSL carries the same grammar across all three
runtimes — conformance fixtures, on-disk session files (`meta`,
`actions.dsl`), the new-session wire body, the resume bundle, and agent
transcripts. Sample session header:

```
created_at: 1778500538
label:

board:
  at ( 20,  70): K♠ A♠ 2♠ 3♠
  ...
```

Full grammar tour + examples live in
[`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md)
under "DSL is the lingua franca". Most parsing happens at test time;
conformance is gated by `ops/check`.

## Ops & testing

```
ops/start              Start Gopher on :9000 (rebuild + relaunch)
ops/list               List ops commands
ops/check              Pre-commit gate (~20s warm): test_ts + test_elm + test_go + test_docs
ops/check_full         Milestone gate (~50s warm): ops/check + agent self-play
ops/test_ts            Fast TS gate (~15s)
ops/test_elm           Fast Elm gate (~4s)
ops/test_go            Fast Go gate (~5s)
ops/test_docs          Fast docs gate (~1s): doc_xref --all (dead links/paths)
ops/deploy             Build + ship to the prod droplet (see deploy/README.md)
```

Don't hand-compose `go test ./...` / `elm make` / `tsc` — the ops
scripts encode sequencing, prerequisites, and the cross-language
consistency checks that bare commands silently skip.

## Where to find more

| Looking for… | Read |
|---|---|
| Lyn Rummy docs (top of tree) | [`games/lynrummy/README.md`](games/lynrummy/README.md) |
| Rules of the game | [`games/lynrummy/RULES.md`](games/lynrummy/RULES.md) |
| Load-bearing design decisions | [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md) |
| Build pipeline | [`games/lynrummy/BUILDING.md`](games/lynrummy/BUILDING.md) |
| Deploy / host setup | [`deploy/README.md`](deploy/README.md) |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

Per-file domain knowledge lives in module top-of-file comments. Commit
history is the authoritative design-decision record.
