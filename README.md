# Angry Gopher

A small, dependency-light server that hosts **Lyn Rummy** (a
single-human card game — Elm client + TypeScript agent) and a private
**chat** surface, plus a small admin view. Storage is plain files on
disk — **no database**. In prod it ships as one self-contained
embedded binary behind Caddy (TLS) under systemd; see
[`deploy/README.md`](deploy/README.md).

> **The server is the zig implementation in [`zig-server/`](zig-server/)** —
> see [`SERVER.md`](SERVER.md). (It was ported from a Go original, now removed;
> the routes, layout, and DSL below describe the live zig server.)

## Quick start

```bash
bash ops/start        # zig server on :9001
```

`ops/start` is the canonical dev loop: it kills anything on :9001,
rebuilds the Elm/TS bundles (`ops/build_elm`) and the zig binary —
which embeds those bundles (see `zig-server/build.zig`) — then relaunches
and waits for the port to respond. Always use it; don't hand-roll
`zig build run`.

The server needs `GOPHER_CONFIG` pointing at a config file (`data_dir` +
auth); `ops/start` uses `~/AngryGopher/gopher.conf`. All persistent data
lives under that `data_dir`, outside the source tree — the tree is freely
rm-able without touching data, and vice versa.

## Local config & identity

The config is a flat `key = value` file (`#` comments). The zig server
honors exactly **two** keys — everything else (including any `port =`
line) is ignored; the listen port is hardcoded to `:9001` in
`zig-server/src/server.zig`.

```
data_dir = /home/steve/AngryGopher/prod   # all writable state lives here
auth_dir = /home/steve/Auth               # account store; defaults to ~/Auth
```

`data_dir` holds three trees: `{data_dir}/lynrummy`, `/chat`, `/users`.
`auth_dir` is the shared account store — one directory per uid
(`{auth_dir}/<id>/{name,password,api-key}`) plus `next-id.txt` for
allocation. One uid is the same person across every surface. With the
config above, `~/Auth/1` resolves to **Steve (uid 1)**, so a browser hits
`/chat` as Steve rather than getting bounced to `/login`.

### Reading chat as the agent (uid 3)

Claude is **uid 3**, an API-key-only agent. To read what Steve sent on a
given topic, act *as* Claude against the dogfooded reference client
(`chat/chat_client.py`). The conversation key pairs the two principals
(Steve `1` × Claude `3` → conv `1_3`); a topic is a named session.

```bash
# List this key-holder's conversations + sessions (partner × topic matrix):
GOPHER_API_KEY="$(cat ~/Auth/3/api-key)" \
  python3 chat/chat_client.py conversations http://localhost:9001

# Read one topic (partner=1 Steve, session="yo"):
GOPHER_API_KEY="$(cat ~/Auth/3/api-key)" \
  python3 chat/chat_client.py fetch http://localhost:9001 1 yo
```

**Local vs prod keys differ.** The *local* agent key is
`~/Auth/3/api-key`; the *prod* agent key is `~/claude_gopher_api_key`
(and Steve's prod key is `~/.gopher_api_key`). Use the local store's key
against `http://localhost:9001`, and the prod key against
`https://lynrummy.com` — they are not interchangeable.

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

Every request goes through a login gate: no resolvable
identity → redirect to `/login`. Login sets a `gopher_uid` cookie;
members additionally get a signed session cookie. Bot **API keys are
read-only** — a keyed request may only GET/HEAD.

## Layout

| Where | Role |
|---|---|
| [`zig-server/`](zig-server/) | **the server (zig)** — every surface (home, login, chat, docs, Lyn Rummy `/game` + `/puzzles`, driving, `/admin`, `/settings`) as per-module handlers in `src/*.zig` over the shared data tree; front-end assets embedded via `build.zig`. See [`SERVER.md`](SERVER.md). |
| `chat/` | the embedded chat **client** (`chat.js`) + the reference API client / example bot (`chat_client.py`: discover, read, post) |
| `games/lynrummy/elm/` | the autonomous Elm client (dealer + referee + UI) |
| `games/lynrummy/ts/` | the TypeScript agent — the strategic brain (solver + self-play) |
| `ops/` | the build / run / test scripts (`ops/list` enumerates them) |
| `deploy/` | Caddyfile, systemd unit, deploy runbook |

The server is dumb URL-keyed file storage; the strategic brain is the
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
ops/start              Start the zig server on :9001 (rebuild + relaunch)
ops/list               List ops commands
ops/check              Pre-commit gate (~35s warm): check_zig + test_ts + test_elm + test_docs + test_css
ops/check_full         Milestone gate: ops/check + agent self-play
ops/check_zig          zig server compiles + unit tests (~6s)
ops/check_markdown     Markdown dialect regression (~3s)
ops/test_ts            Fast TS gate (~15s)
ops/test_elm           Fast Elm gate (~4s)
ops/test_docs          Fast docs gate (~1s): doc_xref --all (dead links/paths)
ops/deploy             Build + ship to the prod droplet (see deploy/README.md)
```

Don't hand-compose `zig build` / `elm make` / `tsc` — the ops
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
