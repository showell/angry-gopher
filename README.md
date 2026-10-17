# Angry Gopher

This is the source for **[lynrummy.com](https://lynrummy.com)** — Steve
Howell's personal website. Every line of code here was written by Claude.
"Angry Gopher" is a dated inside joke; don't ask.

The site is a handful of small apps served from **one self-contained zig
binary** — no database, storage is plain files on disk — served by
zig-metal-unikernel behind Caddy (TLS); see "Where it runs" below. Each app has its own README as the canonical
home for its design intent; this file is the developer/agent map of the
whole thing.

## Where it runs: on zig-metal-unikernel

**lynrummy.com is served by [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)**,
this repo's zig server compiled into a kernel with no operating system under
it, on its own DigitalOcean droplet. The two repos stay separate:

- **This repo is the program.** Every route, page and app is written and
  tested here, on Linux, as always (`ops/start`, `ops/check`).
- **The library is [zig-webbox](https://github.com/showell/zig-webbox)**, a
  sibling checkout (`../zig-webbox`): the serving, the store, the cookies.
  This repo's server is an application of it, as Dog Park is.
- **zig-metal-unikernel is the machine.** Its build compiles `zig-server/src` and
  zig-webbox from their sibling checkouts as they are, and hands them metal's
  own `Io` as `host_io` (std's here: zig-webbox's `host_io_std.zig`),
  rewriting no line;
  its gates judge metal against this repo's Linux build, page by page, and
  run metal-vmm (test-only). Its `DEPLOY.md` says how a release reaches
  the droplet, and the way back.
- **A change to the program reaches the site as a new zig-metal-unikernel image**,
  not through `ops/deploy`. The old Linux droplet still runs Caddy (TLS,
  body caps), which proxies to metal over the private network
  (`deploy/Caddyfile`); its own zig server is **stopped and must stay
  stopped**. `ops/deploy` fails closed: it restarts that server only when
  `~/linux-serves` is on prod (`deploy/README.md`).
- **The way back is the previous zig-metal-unikernel image** on the same volume
  (zig-metal-unikernel's `DEPLOY.md`, "The way back"). Restarting the Linux server (zig-metal-unikernel's `CUTOVER.md`) is
  the last resort: its data is a copy frozen at the 2026-10-04 cutover, so
  everything written since would be lost.
- **Keep `zig-server/src` portable to metal.** Server code reaches the host
  only through the seam in [`docs/SEAM.md`](docs/SEAM.md);
  `tools/lint_portable.py` (run by `ops/check_zig`) fails a change that
  reaches around it. A change ships only after zig-metal-unikernel's gates pass on
  it.
- **The two hosts are one machine, by contract** (zig-metal-unikernel `HOST.md`,
  `STORE.md`): Linux runs **one handler at a time** as metal's single loop
  does (the turn in webbox's `linux_host.zig`); every bound on a request is in
  [`zig-server/src/limits.zig`](zig-server/src/limits.zig), which both hosts
  size their buffers from and `tools/check_caddy_limits.py` holds the
  Caddyfile to; and zig-webbox's `store.zig` answers the same on Linux and on metal, which
  zig-metal-unikernel's `zig build store-judge` checks operation by operation.
- **Which commit is live:** `https://lynrummy.com/version` reports the running
  build's `commit`; `git tag --points-at <commit>` names its release
  (zig-metal-unikernel's README, "Where it stands", says how to read the rest).
  Its `version` field is a constant (`home.zig`), so `commit` is the field that
  names a build. The other fields: `result`, `rejects` (the edge's reject
  counters), `mem` (the live-byte meter), `login_throttle`, `now_ms`,
  `started_ms`.

## The apps

The home page (`/`) is a launch pad for six apps, in the display order
below. **That order lives in `pages/home.txt` and nowhere else is
authoritative** — this table mirrors it by hand; `/gallery`
(`zig-server/src/gallery.zig`) derives its cards from the file at request
time. If they disagree, `pages/home.txt` is right.

| App | Path | What it is | Stack | README |
|---|---|---|---|---|
| **Safari Screensaver** | `/driving` | A self-driving first-person motorcycle ride down a winding road, drawn from rider-relative coordinates. A Zig core (compiled to WebAssembly) computes the geometry; a tiny JS blitter fills the polygons. | Zig (WASM) + JS | [`games/driving/README.md`](games/driving/README.md) |
| **Chat** | `/chat` | Real-time chat, docs, and channels over Server-Sent Events — the live surface we use daily; a multi-page app still mostly rendered on the front end. | JavaScript + Zig | [`chat/README.md`](chat/README.md) |
| **Seattle Delivery** | `/delivery` | A CVRP route-planning sim — eight trucks fan out across a not-to-scale Seattle. Watch a hand-built Clarke-Wright solver think. A Zig solver (compiled to WASM) plans the routes; the TS client draws and animates them. | Zig (WASM) + TS | [`delivery/README.md`](delivery/README.md) |
| **Lyn Rummy** | `/game` | Two-player rummy against an agent that knows the rules — a Zig solver (compiled to WASM) picks the plays and hints, a TS layer turns them into table gestures, an Elm UI plays them, all speaking one short text grammar for moves and sessions (the DSL) over the wire. | Zig (WASM) + Elm + TS | [`games/lynrummy/README.md`](games/lynrummy/README.md) |
| **Lyn Rummy Puzzles** | `/puzzles` | A single mid-game board to solve; shares the solver and rules, with deterministic undo and replay. | Zig (WASM) + Elm + TS | [`games/lynrummy/elm/src/Puzzle/README.md`](games/lynrummy/elm/src/Puzzle/README.md) |
| **Chess Toys** | `/chess` | Knight's Tour and Eight Queens as watchable, scrubbable backtracking searches — each search narrates onto an event tape, and the sources themselves are exhibited at `/chess/code`. | Zig (WASM) + JS | [`games/chess/README.md`](games/chess/README.md) |

> **The server is the zig implementation in [`zig-server/`](zig-server/)** —
> see [`zig-server/README.md`](zig-server/README.md).

The rest of this README is for developers and agents working on the code.

## Quick start

```bash
bash ops/start        # zig server on :9001
```

The build needs [zig-webbox](https://github.com/showell/zig-webbox) cloned
beside this repo (`../zig-webbox`): `zig-server/build.zig.zon` names it, and
`ops/check_zig` runs its tests too.

`ops/start` is the canonical dev loop: it kills anything on :9001,
rebuilds the front-end bundles and WASM cores (`ops/build_embedded` runs
every builder that `zig-server/assets.zon` names: `ops/build_elm`,
`ops/build_delivery`, `ops/build_safari_wasm`, `ops/build_chess_wasm`) and
the zig binary — which embeds them (see `zig-server/build.zig`) — then relaunches
and waits for the port to respond. Always use it; don't hand-roll
`zig build run`.

`GOPHER_CONFIG` names a config file (`data_dir` + auth); unset, the server
uses repo-relative defaults (`linux_config.zig`). `ops/start` uses
`~/AngryGopher/gopher.conf`. All persistent data
lives under that `data_dir`, outside the source tree — the tree is freely
rm-able without touching data, and vice versa.

## Toolchain

Dependencies are few, but these must be present to build fresh. The npm
packages are pinned by each directory's committed `package-lock.json`:

| Tool | Version | Builds | Install |
|---|---|---|---|
| **Zig** | 0.16.0 | the server (`zig-server/`) + the Lyn Rummy solver's WASM build (`games/lynrummy/zig/` → `solver.wasm`) + the Safari Screensaver's WASM core (`games/driving/wasm/` → `games/driving/safari.wasm`) + the Delivery solver's WASM build (`delivery/zig/` → `delivery/solver.wasm`) + the Chess Toys' WASM cores (`games/chess/*.zig` → `games/chess/*.wasm`) | system install — `zig version` |
| **Elm** | 0.19.1 | the Lyn Rummy client | `npm install` in `games/lynrummy/elm/` |
| **TypeScript** | 6.0.3 | the Delivery display client + the Lyn Rummy DSL/geometry layer and test harnesses (both solvers are zig; each `.ts` solver stays as the port reference) | `npm install` in `delivery/`, `games/lynrummy/ts/` and `games/driving/` |
| **Node** | 22.18 or later | runs the TS directly + hosts the npm-installed `elm`/`tsc` | system install — `node --version` |
| **X11 dev headers** | — | only `ops/build_safari_download`, the free-standing Linux Safari binary | `apt install libx11-dev libxrender-dev` (see below) |

TypeScript runs two ways, and only one of them is transpiled:

- **Node-side** — the TS engine's tests and the self-play harness run the
  `.ts` files *directly* via Node's type-stripping, never transpiled. Node
  22.18 is the first release that strips types without a flag, so it is the
  floor.
- **Browser-side** — two bundles **are** transpiled (`esbuild` bundles
  each into one IIFE JS file, `@embedFile`d into the zig binary at compile
  time), and both pair with a zig brain. The Delivery sim
  (`delivery/main.ts` → `delivery/app.js`) builds its own canvas and owns
  the whole display — but the *solver* runs in `delivery/solver.wasm`
  (`delivery/zig/`, `ops/build_delivery_wasm`), which the bundle calls for
  each shift's plan. The Lyn Rummy engine bundle
  (`games/lynrummy/ts/elm_api/engine_entry.ts` → `games/lynrummy/elm/engine.js`)
  is a supporting layer, not a client — the *thinking* (hints, the one-line
  "why nothing plays" explanations the code calls futility certificates, the
  agent opponent) lives in the zig solver compiled to `solver.wasm`, and the
  TS bundle translates its answers into the DSL and table gestures
  (locations, drag paths) while Elm owns the UI. `ops/build_delivery` /
  `ops/build_engine_js` run these (alongside the Elm output); `esbuild` is a
  pinned local devDependency (calling its binary directly skips `npx`'s
  ~1s-per-call resolution tax). The Safari Screensaver is a Zig→WASM core
  plus a JS blitter (`ops/build_safari_wasm`), not transpiled; `HISTORY.md`
  says where Safari and Delivery sit on the zig↔TS spectrum and why
  (Chess Toys is in its own README).

`tsc` itself only ever typechecks (`npm run typecheck`) — it never emits
the JS that ships. Elm, `tsc`, and `esbuild` are all project-local (run
from each package's `node_modules/.bin`), so a fresh checkout needs
`npm install` in **four** places: `games/lynrummy/elm/`,
`games/lynrummy/ts/`, `delivery/`, and `games/driving/`.

### Fresh box, in order

Each of these is otherwise learned from a failing build.

1. **Node 22.18 or later**, for the node-side TS above.
2. **`npm install` in all four package directories.**
3. **Zig 0.16.0**, on `PATH`. Every `ops/build_*` script and the server
   itself go through it.
4. **`libx11-dev` and `libxrender-dev`**, and only for
   `ops/build_safari_download`. `games/driving/build.zig:61-62` links exactly
   `X11` and `Xrender`; nothing else in the tree needs a system library.
   `ops/start` does not build it; `ops/deploy`'s Linux path does, after the
   front-end bundles and before the server. The error is
   `unable to find dynamic system library 'X11'`.
5. **The WASM cores before `zig build`.** `zig-server/build.zig` `@embedFile`s
   three artifacts that a fresh clone does not have (they are gitignored) —
   `games/driving/safari.wasm` and `games/chess/{knight,queens}.wasm` — so
   `ops/build_safari_wasm` and `ops/build_chess_wasm` must run first
   (`ops/start` does). The two solver WASMs,
   `delivery/solver.wasm` and `games/lynrummy/zig/solver.wasm`, are
   committed; rebuild them with `ops/build_delivery_wasm` and
   `ops/build_lynrummy_wasm` only after editing their zig. The failure is
   `failed to check cache: '…/safari.wasm' file_hash FileNotFound`, which does
   not name the script that produces it.

## Local config & identity

The config is a flat `key = value` file (`#` comments). The zig server
honors exactly **two** keys — everything else (including any `port =`
line) is ignored. The environment variables, all named in
`zig-server/src/server.zig`:

- `GOPHER_CONFIG`: the config file (above).
- `GOPHER_PORT`: the listen port, `:9001` unless set.
- `GOPHER_BIND`: the listen address.
- `GOPHER_TRUSTED_PROXY`: whose `X-Forwarded-For` names the client
  (default `127.0.0.1`, the local Caddy).
- `GOPHER_KEEPALIVE_MS`: how long a quiet SSE stream waits before a ping;
  for tests.
- `GOPHER_GAME_FLOOR=off`: turns off the game store's free-space floor, for
  a test host whose data sits on a full disk.

webbox's `linux_host.zig` reads the first five; `server.zig` reads the last.

```
data_dir = /home/steve/AngryGopher/local  # all writable state lives here
auth_dir = /home/steve/Auth               # account store; defaults to ~/Auth
```

`data_dir` holds four trees: `{data_dir}/lynrummy`, `/chat`, `/users`,
`/players` (`roots.zig` points them all).
`auth_dir` is the shared account store — one directory per uid
(`{auth_dir}/<id>/{name,password,api-key}`) plus `next-id.txt` for
allocation. One uid is the same person across every surface. With the
config above, `~/Auth/1` resolves to **Steve (uid 1)**, so a browser hits
`/chat` as Steve rather than getting bounced to `/login/full`.

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

**STRANGER → PLAYER → FULL MEMBER**

- **Stranger** — no cookie, no identity. Can browse public surfaces (e.g.
  `/driving`).
- **Player** — a name, no password, in the LOCAL player store
  (`{data_dir}/players/<id>/name`, see `player.zig`). You become one by
  entering a name at `/play`; enough for **Lyn Rummy** and the puzzles,
  which need somewhere to file a board and a name to print on it.
  **Names are not reserved**, so anyone may type any name. The
  `gopher_uid` cookie is signed (`uid_cookie.zig`), so one set by hand
  names no one; a legacy unsigned cookie is re-signed once, inside its
  window. Nothing behind a real gate — chat, settings, admin, uploads —
  resolves through this tier.
- **Full member** — an account in `{auth_dir}` with a password. Required
  for **chat**. Logging in mirrors the member into the player store under
  the same id, so their game history follows them.

A locally-minted player id is spelled `p<n>`; an account id is a bare
decimal. The two identities ride the same `gopher_uid` cookie, so the
spellings are disjoint on purpose: the account resolver reads that cookie
only when it is all digits, so a player can never be read as a chat
principal.

The `/login/full` page handles the member on-ramps (see `login.zig`): a
stranger picks *Log in* or *Create account*, and an existing member
verifies a password.

Two accounts stand apart from this progression:

- **Admin** — **uid 1** (Steve). The first account; both admin screens
  (`/admin` for chat, `/admin/lynrummy` for the game) are hardcoded to
  uid 1 via `admin_ui.requireAdmin`, not a per-account flag.
- **Agent** — **uid 3** (Claude). A full member that authenticates by API
  key instead of a browser session (read + write, never admin). See
  "Reading chat as the agent" below.

### Bootstrapping a fresh environment

Starting from an empty `data_dir` + `auth_dir` (no accounts yet), there
are three steps. Account ids are allocated `1, 2, 3, …` in registration
order (the counter floors at 1). **Convention: uid 1 and 2 are people;
uid 3 is the agent (Claude).**

**1. Seed the session secret.** Members get a *signed* session cookie,
keyed by `{data_dir}/chat/_session_secret`, and so is every player's
`gopher_uid`. The server *reads* this file but never creates the first
one — so registration 500s ("session unavailable"), and `/play` sets no
cookie, until it exists. (`/admin/secret` replaces one that exists;
SECRET-LEAK.md in zig-metal-unikernel says when.) Seed it once with ≥ 32 random bytes:

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
`~/Auth/3/api-key`; the *prod* agent key is `~/.claude_gopher_api_key`
(and Steve's prod key is `~/.gopher_api_key`). Use the local store's key
against `http://localhost:9001`, and the prod key against
`https://lynrummy.com` — they are not interchangeable.

## Routes

The authoritative dispatch is `route()` in `zig-server/src/router.zig`
(one prefix match per surface — read it for the full story). The map:

| Path | What |
|---|---|
| `/` | Home / launch pad (public; viewer resolved for the top bar, never gated) |
| `/delivery` | Seattle Delivery sim (public) |
| `/driving`, `/safari_download`, `/downloads` | Safari Screensaver + its native-download landing page and artifacts (public) |
| `/chess` | Chess Toys: `/chess/knight`, `/chess/queens`, sources at `/chess/code` (public) |
| `/game`, `/puzzles` | Lyn Rummy: full game (player name required), puzzle client |
| `/chat`, `/channel/<name>` | DMs + channels over SSE, `/chat/docs` authoring; `/chat/recent`, `/chat/images`, `/chat/code`, `/chat/links`, `/chat/search`, `/chat/msg/<id>` (members only; `chat.zig`) |
| `/settings` | Per-user settings incl. API-key generation (members) |
| `/play`, `/login/full`, `/logout` | Name-only player login / member password login |
| `/admin` | The chat roster and API keys (`/admin/apikey`); `/admin/host` (the running server), `/admin/log` (the log as text), `/admin/backup` (an archive of `data/` and `auth/`), `/admin/secret` (change the session secret), `/admin/retire` (retire old topics and users), `/admin/search?key=` (every chat message containing `key`); `/admin/lynrummy` (the game roster); `/admin/script` (a signed Shale script, below) and `/admin/script-key`. All hardcoded to uid 1 |
| `/gallery`, `/images` | Home-page app emblems / brand assets (public) |
| `/steve-resume` | Server-owned markdown page + pre-built PDF |
| `/version`, `/debug/mem` | Build version JSON; live allocator counters (the leak smoke detector) |

There is no site-wide login gate — most surfaces are deliberately
public and ungated (they resolve the viewer only to label the top
bar). The gates that exist are per-surface: Lyn Rummy asks for a player
name, chat requires a full member. `/play` and login set a signed
`gopher_uid` cookie; members additionally get a signed session cookie,
`gopher_auth`. An **API key**
(`Authorization: Bearer`) resolves to its principal exactly like a
session — read + write as that uid. uid 1's key is therefore admin, and it
is the only credential `/admin/script` takes.

### The admin routes, in more detail

- **`/admin/log`** narrows by `since=`, `until=`, `request=`, `path=` and
  `boot=` (zig-webbox's `admin_log.zig`).
- **`/admin/retire`** is two steps: a dry run that lists what would go, then
  a confirm. Like `/admin/backup` and `/admin/secret`, it asks for the
  password again.
- **`/admin/search`** reads every transcript the admin can see, with no
  index, and holds the turn while it does: every other request waits.
- **`/admin/script`** takes two locks: the admin's API key as
  `Authorization: Bearer` (a session cookie is not enough), then an Ed25519
  signature on the envelope, checked against the public key in
  `{auth_dir}/shale.conf`; with no key there the route refuses. A
  `mode=background` run is answered at once and stepped between requests on
  both hosts, one at a time; `GET /admin/script` shows its state and output,
  and `mode=kill` ends it. The language is zig-webbox's [`SHALE.md`](https://github.com/showell/zig-webbox/blob/master/docs/SHALE.md); how
  to sign and send a script is zig-metal-unikernel's `DEPLOY.md`.

## Layout

| Where | Role |
|---|---|
| [`zig-server/`](zig-server/) | **the server (zig)** — every surface (home, login, chat, docs, Lyn Rummy `/game` + `/puzzles`, driving, `/admin`, `/settings`) as per-module handlers in `src/*.zig` over the shared data tree; front-end assets embedded via `build.zig`. See [`zig-server/README.md`](zig-server/README.md). |
| `chat/` | the embedded chat **client** (`chat.js`) + the reference API client / example bot (`chat_client.py`: discover, read, post) |
| `delivery/` | the Delivery display client (TS) + `delivery/zig/` — the CVRP solver, compiled to `solver.wasm`, gated bit-exact against the retired TS solver (`ops/check_delivery`) |
| `games/lynrummy/elm/` | the autonomous Elm client (dealer + referee + UI) |
| `games/lynrummy/zig/` | the solver — the strategic brain (hints, certificates, Player Two, self-play sim), compiled to `solver.wasm` for the browser |
| `games/lynrummy/ts/` | the original TypeScript engine, mostly retired — still the DSL/geometry layer (gesture choreography for the zig solver's plays) + the self-play harness |
| `ops/` | the build / run / test scripts (`ops/list` enumerates them) |
| `deploy/` | prod's Caddyfile, the Linux fallback's systemd unit and runbook |

The server stays deliberately dumb — URL-keyed file storage plus the
per-surface handlers — and pushes logic to the client wherever it can.
Lyn Rummy is the clearest case: the strategic brain is the zig solver
running as WASM in the browser, the TS layer turns its answers into table
gestures, and the Elm client owns the full game (dealer, referee, UI). Its
[`README`](games/lynrummy/README.md) covers that split and the
DSL-over-the-wire idea in full.

**Responsive / mobile** (the chat surfaces — our mobile user is Apoorva;
Steve is desktop-only). Small-screen layout is decided client-side. One JS
authority, `Viewport` (`chat/viewport.js`), owns the single breakpoint and
exposes it two ways — an `html.vp-narrow` class for CSS and `onChange` for
JS — so the number lives in exactly one place. The shared nav drawer
(`chrome_drawer.js`) and the chat page's mobile layout (`chat_responsive.js`)
both key off it; the server (`chat_chrome.zig`) just ships the desktop top bar and
loads the widgets. Start at `Viewport` and follow the breadcrumbs.

## Ops & testing

The gates, cheapest first (`ops/list` gives each one's rough time):

```
ops/test_docs          Docs gate: doc_xref --all (dead links/paths)
ops/test_elm           Elm client suite
ops/test_ts            TS suite
ops/check_zig          zig server compiles + the lints + the Caddy limits + every unit test, here and zig-webbox's
ops/check_chat         Chat gate: check_common + test_chat
ops/check_lynrummy     Lyn Rummy gate: check_common + test_elm + test_ts + check_solver
ops/check              Pre-commit gate: check_common + test_elm + test_ts + test_chat + check_safari + check_chess + check_solver
ops/check_full         Milestone gate: ops/check + the heavy conformance suites + agent self-play + benches
```

Standalone, run after editing their part:

```
ops/check_markdown     Markdown dialect regression
ops/check_delivery     Delivery zig-solver conformance: native gold check +
                       the built solver.wasm driven over every gold shift
```

The rest:

```
ops/start              Start the zig server on :9001 (rebuild + relaunch)
ops/list               List ops commands
ops/deploy             While metal serves: copy prod's watchdog only. The full
                       Linux build + ship runs only with ~/linux-serves on prod
                       (see deploy/README.md)
```

Don't hand-compose `zig build` / `elm make` / `tsc` — the ops
scripts encode sequencing, prerequisites, and the cross-language
consistency checks that bare commands silently skip.

## Where to find more

| Looking for… | Read |
|---|---|
| Any one app's design intent | its README — see [The apps](#the-apps) above |
| The server internals (routing, modules) | [`zig-server/README.md`](zig-server/README.md) |
| Lyn Rummy rules / architecture | [`games/lynrummy/RULES.md`](games/lynrummy/RULES.md), [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md) |
| Releasing to lynrummy.com | zig-metal-unikernel's `DEPLOY.md` |
| The Linux fallback host, prod's Caddy | [`deploy/README.md`](deploy/README.md) |
| Agent-collaboration conventions | `~/showell_repos/claude-collab/agent_collab/` |

Per-file domain knowledge lives in module top-of-file comments. Commit
history is the authoritative design-decision record.
