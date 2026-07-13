# Angry Gopher

This is the source for **[lynrummy.com](https://lynrummy.com)** — Steve
Howell's personal website. Every line of code here was written by Claude.
"Angry Gopher" is a dated inside joke; don't ask.

The site is a handful of small apps served from **one self-contained zig
binary** — no database, storage is plain files on disk, deployed behind
Caddy (TLS) under systemd. Each app has its own README as the canonical
home for its design intent; this file is the developer/agent map of the
whole thing.

## The apps

The home page (`/`) is a launch pad for seven apps. In display order:

| App | Path | What it is | Stack | README |
|---|---|---|---|---|
| **Seattle Delivery** | `/delivery` | A CVRP route-planning sim — eight trucks fan out across a not-to-scale Seattle. Watch a hand-built Clarke-Wright solver think. | TypeScript | [`delivery/README.md`](delivery/README.md) |
| **Safari Screensaver** | `/driving` | A self-driving first-person motorcycle ride down a winding road, drawn from rider-relative coordinates. A Zig core (compiled to WebAssembly) computes the geometry; a tiny JS blitter fills the polygons. | Zig (WASM) + JS | [`games/driving/README.md`](games/driving/README.md) |
| **Chat** | `/chat` | Real-time chat, docs, and channels over Server-Sent Events — the live surface we use daily; a multi-page app still mostly rendered on the front end. | JavaScript + Zig | [`chat/README.md`](chat/README.md) |
| **Blog** | `/blog` | Notes on building the site, rendered from repo markdown by a hand-written engine. | Zig | [`blog/README.md`](blog/README.md) |
| **Lyn Rummy** | `/game` | Two-player rummy against an agent that knows the rules — a TS referee engine with an Elm UI, speaking a DSL over the wire. | TypeScript + Elm | [`games/lynrummy/README.md`](games/lynrummy/README.md) |
| **Lyn Rummy Puzzles** | `/puzzles` | A single mid-game board to solve; shares the rules engine, with deterministic undo and replay. | TypeScript + Elm | [`games/lynrummy/elm/src/Puzzle/README.md`](games/lynrummy/elm/src/Puzzle/README.md) |
| **Chess Toys** | `/chess` | The newest addition: Knight's Tour and Eight Queens as watchable, scrubbable backtracking searches — each search narrates onto an event tape, and the sources themselves are exhibited at `/chess/code`. | Zig (WASM) + JS | [`games/chess/README.md`](games/chess/README.md) |

> **The server is the zig implementation in [`zig-server/`](zig-server/)** —
> see [`SERVER.md`](SERVER.md). (It was ported from a Go original, now removed;
> the routes, layout, and DSL below describe the live zig server.)

The rest of this README is for developers and agents working on the code.

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

## Toolchain

Dependencies are few, but three compilers must be present to build fresh.
We pin these versions:

| Tool | Version | Builds | Install |
|---|---|---|---|
| **Zig** | 0.16.0 | the server (`zig-server/`) + the Safari Screensaver's WASM core (`games/driving/wasm/` → `games/driving/safari.wasm`) + the Chess Toys' WASM cores (`games/chess/*.zig` → `games/chess/*.wasm`) | system install — `zig version` |
| **Elm** | 0.19.1 | the Lyn Rummy client | `npm install` in `games/lynrummy/elm/` (pinned in its `package.json`) |
| **TypeScript** | 6.0.3 | the Delivery client + the Lyn Rummy agent/engine | `npm install` in `delivery/` and `games/lynrummy/ts/` (pinned in each `package.json`) |
| **Node** | 24 | runs the TS directly + hosts the npm-installed `elm`/`tsc` | system install — `node --version` |

TypeScript runs two ways, and only one of them is transpiled:

- **Node-side** — the agent solver and its tests run the `.ts` files
  *directly* via Node's type-stripping, never transpiled (so a Node new
  enough for that is required; dev uses v24).
- **Browser-side** — two bundles **are** transpiled (`esbuild` bundles
  each into one IIFE JS file, `@embedFile`d into the zig binary at compile
  time). One is a *pure-TypeScript client that does it all*: the Delivery sim
  (`delivery/main.ts` → `delivery/app.js`) builds its own canvas and owns
  every line of its on-screen behavior — no Elm, no server logic. The other
  is the opposite shape: the Lyn Rummy engine
  (`games/lynrummy/ts/elm_api/engine_entry.ts` → `games/lynrummy/elm/engine.js`)
  is *only* the solver/referee brain plus occasional DOM glue, while Elm owns
  the UI. `ops/build_delivery` / `ops/build_engine_js` run these (alongside the
  Elm output); `esbuild` is a pinned local devDependency (calling its binary
  directly skips `npx`'s ~1s-per-call resolution tax). (The Safari Screensaver
  *used* to be a third pure-TS client; it's now a Zig→WASM core + a JS blitter
  — `ops/build_safari_wasm` — and no longer transpiled. The `.ts` source is
  kept as the port reference; see `HISTORY.md`.)

`tsc` itself only ever typechecks (`npm run typecheck`) — it never emits
the JS that ships. Elm, `tsc`, and `esbuild` are all project-local (run
from each package's `node_modules/.bin`), so a fresh checkout needs
`npm install` in `games/lynrummy/elm/`, `games/lynrummy/ts/`, and
`delivery/`.

## Local config & identity

The config is a flat `key = value` file (`#` comments). The zig server
honors exactly **two** keys — everything else (including any `port =`
line) is ignored; the listen port is hardcoded to `:9001` in
`zig-server/src/server.zig`.

```
data_dir = /home/steve/AngryGopher/local  # all writable state lives here
auth_dir = /home/steve/Auth               # account store; defaults to ~/Auth
```

`data_dir` holds three trees: `{data_dir}/lynrummy`, `/chat`, `/users`.
`auth_dir` is the shared account store — one directory per uid
(`{auth_dir}/<id>/{name,password,api-key}`) plus `next-id.txt` for
allocation. One uid is the same person across every surface. With the
config above, `~/Auth/1` resolves to **Steve (uid 1)**, so a browser hits
`/chat` as Steve rather than getting bounced to `/login`.

**Policy: keep server data OUTSIDE the repository.** Point `data_dir` and
`auth_dir` at paths outside the source tree (e.g. `~/AngryGopher/…` and
`~/Auth`, as above) — never inside the checkout. The tree stays freely
rm-able without touching data, accounts/credentials never risk being
committed, and there's nothing to `.gitignore`. The config file itself
also lives outside the repo (`ops/start` defaults to
`~/AngryGopher/gopher.conf`).

### User types & the identity progression

The site optimizes for frictionless exploration, asking for a password
only where it must — at the chat boundary, which holds private data. That
produces a natural progression:

**STRANGER → GUEST → FULL MEMBER**

- **Stranger** — no cookie, no account. Can browse public surfaces (e.g.
  `/driving`).
- **Guest** — a name, no password (`{auth_dir}/<id>/` has `name` only).
  You become one by entering a name at `/login`; enough to play **Lyn
  Rummy**, which needs a unique name to track game history but no
  password. Names are unique, so a guest can't take a member's name.
- **Full member** — a guest who has set a password (`name` + `password`),
  or a stranger who registered directly. Required for **chat**. A guest
  upgrades *in place* — same uid, so game history carries over.

Many users skip the middle step and go **straight from stranger to full
member** — anyone who heads to chat without playing Lyn Rummy first. The
`/login/full` page handles all three on-ramps (see `login.zig`): a
stranger picks *Log in* or *Create account*; a cookied guest just sets a
password; an existing member verifies one.

Two accounts stand apart from this progression:

- **Admin** — **uid 1** (Steve). The first account; `/admin` is
  hardcoded to uid 1 (`admin.zig`), not a per-account flag.
- **Agent** — **uid 3** (Claude). A full member that authenticates by API
  key instead of a browser session (read + write, never admin). See
  "Reading chat as the agent" below.

### Bootstrapping a fresh environment

Starting from an empty `data_dir` + `auth_dir` (no accounts yet), there
are three steps. Account ids are allocated `1, 2, 3, …` in registration
order (the counter floors at 1). **Convention: uid 1 and 2 are people;
uid 3 is the agent (Claude).**

**1. Seed the session secret.** Members get a *signed* session cookie,
keyed by `{data_dir}/chat/_session_secret`. The server *reads* this file
but never creates it — so registration 500s ("session unavailable")
until it exists. Seed it once with ≥ 32 random bytes:

```bash
mkdir -p "$DATA_DIR/chat"
head -c 48 /dev/urandom > "$DATA_DIR/chat/_session_secret"
chmod 600 "$DATA_DIR/chat/_session_secret"
```

**2. Register the accounts in order.** Each registration POST *without a
cookie* allocates the next id, so order is what assigns the uids. Do it
in the browser at `/login/full` (enter a name + password twice), or by
curl:

```bash
for who in Steve apoorva Claude; do      # → uid 1, 2, 3
  curl -s -o /dev/null -X POST http://localhost:9001/login/full \
    --data-urlencode "name=$who" \
    --data-urlencode "password=CHANGEME-$who" \
    --data-urlencode "confirm=CHANGEME-$who" \
    --data-urlencode "next=/"
done
```

This writes `{auth_dir}/<id>/{name,password}`.

**3. Give the agent an API key.** The agent (uid 3) authenticates by key,
not cookie — but it generates that key like any member: log in as Claude,
then `POST /settings/apikey` (in the browser: `/settings` → *Generate
key*). The key lands at `{auth_dir}/3/api-key` and is what the agent
hands over as `Authorization: Bearer <key>`:

```bash
JAR=$(mktemp)
curl -s -o /dev/null -c "$JAR" -X POST http://localhost:9001/login/full \
  --data-urlencode "name=Claude" --data-urlencode "password=CHANGEME-Claude" --data-urlencode "next=/"
curl -s -o /dev/null -b "$JAR" -X POST http://localhost:9001/settings/apikey
cat "$AUTH_DIR/3/api-key"   # 3-<32 hex>
```

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

The authoritative dispatch is `route()` in `zig-server/src/server.zig`
(one prefix match per surface — read it for the full story). The map:

| Path | What |
|---|---|
| `/` | Home / launch pad (public; viewer resolved for the top bar, never gated) |
| `/delivery` | Seattle Delivery sim (public) |
| `/driving`, `/safari_download`, `/downloads` | Safari Screensaver + its native-download landing page and artifacts (public) |
| `/chess` | Chess Toys: `/chess/knight`, `/chess/queens`, sources at `/chess/code` (public) |
| `/game`, `/puzzles`, `/tutorial` | Lyn Rummy: full game (guest name required), puzzle client, beginner tutorial (tutorial public) |
| `/chat`, `/channel/<name>` | DMs + channels over SSE, `/chat/docs` authoring (members only) |
| `/blog` | Blog (public; posting a comment mints a guest) |
| `/learn` | Interactive site tutorial (public) |
| `/settings` | Per-user settings incl. API-key generation (members) |
| `/login`, `/login/full`, `/logout` | Guest name login / member password login |
| `/admin` | Session + user overview (hardcoded to uid 1) |
| `/gallery`, `/images` | Home-page app emblems / brand assets (public) |
| `/steve-resume` | Server-owned markdown page + pre-built PDF |
| `/version`, `/debug/mem` | Build version JSON; live allocator counters (the leak smoke detector) |

There is no site-wide login gate — most surfaces are deliberately
public and ungated (they resolve the viewer only to label the top
bar). The gates that exist are per-surface: Lyn Rummy asks for a guest
name, chat requires a full member. Login sets a `gopher_uid` cookie;
members additionally get a signed session cookie. An **API key**
(`Authorization: Bearer`) resolves to its principal exactly like a
session — read + write as that uid, never admin.

## Layout

| Where | Role |
|---|---|
| [`zig-server/`](zig-server/) | **the server (zig)** — every surface (home, login, chat, docs, Lyn Rummy `/game` + `/puzzles`, driving, `/admin`, `/settings`) as per-module handlers in `src/*.zig` over the shared data tree; front-end assets embedded via `build.zig`. See [`SERVER.md`](SERVER.md). |
| `chat/` | the embedded chat **client** (`chat.js`) + the reference API client / example bot (`chat_client.py`: discover, read, post) |
| `games/lynrummy/elm/` | the autonomous Elm client (dealer + referee + UI) |
| `games/lynrummy/ts/` | the TypeScript agent — the strategic brain (solver + self-play) |
| `ops/` | the build / run / test scripts (`ops/list` enumerates them) |
| `deploy/` | Caddyfile, systemd unit, deploy runbook |

The server stays deliberately dumb — URL-keyed file storage plus the
per-surface handlers — and pushes logic to the client wherever it can.
Lyn Rummy is the clearest case: the strategic brain is the TS agent, and
the Elm client owns the full game (dealer, referee, UI). Its
[`README`](games/lynrummy/README.md) covers that split and the
DSL-over-the-wire idea in full.

**Responsive / mobile** (the chat surfaces — our mobile user is Apoorva;
Steve is desktop-only). Small-screen layout is decided client-side. One JS
authority, `Viewport` (`chat/viewport.js`), owns the single breakpoint and
exposes it two ways — an `html.vp-narrow` class for CSS and `onChange` for
JS — so the number lives in exactly one place. The shared nav drawer
(`chrome_drawer.js`) and the chat page's mobile layout (`chat_responsive.js`)
both key off it; the server (`chrome.zig`) just ships the desktop top bar and
loads the widgets. Start at `Viewport` and follow the breadcrumbs.

## Ops & testing

```
ops/start              Start the zig server on :9001 (rebuild + relaunch)
ops/list               List ops commands
ops/check              Pre-commit gate (~40s warm): check_common + test_elm + test_ts + test_chat + check_safari + check_chess + check_solver
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
| Any one app's design intent | its README — see [The apps](#the-apps) above |
| The server internals (routing, modules) | [`SERVER.md`](SERVER.md) |
| Lyn Rummy rules / architecture | [`games/lynrummy/RULES.md`](games/lynrummy/RULES.md), [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md) |
| Deploy / host setup | [`deploy/README.md`](deploy/README.md) |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

Per-file domain knowledge lives in module top-of-file comments. Commit
history is the authoritative design-decision record.
