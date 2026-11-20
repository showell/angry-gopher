# Angry Gopher

This is the source for **[lynrummy.com](https://lynrummy.com)**, Steve
Howell's personal website. "Angry Gopher" is a dated inside joke.

The code here was written by AI coding agents (Claude), with human supervision.
Point an agent at this repo to extend it.

The site is a handful of small apps served from **one self-contained zig
binary** that keeps its data as plain files on disk. Each app has its own
README as the home of its design; this file is the map of the whole.

## Where it runs

lynrummy.com runs this server compiled into
[zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel), a
kernel that runs the program on bare hardware, behind Caddy for TLS. The
metal stack is deprecated: its last release is tagged `last-on-metal`, here
and in zig-metal-unikernel, and the program is moving to a regular Linux
host.

- **This repo is the program.** Every route, page and app is written and
  tested here, on Linux (`ops/start`, `ops/check`).
- **The library is webbox**, in `zig-server/webbox/`: the serving, the
  store, the cookies ([`zig-server/webbox/README.md`](zig-server/webbox/README.md)).
- **The chat's markdown dialect and its browser client** are sibling
  checkouts, chat-markdown and chat-client; `zig-server/build.zig.zon` names
  every sibling the build reads.
- **`zig-server/src` stays portable to metal.** Server code reaches the host
  only through the seam in [`docs/SEAM.md`](docs/SEAM.md);
  `tools/lint_portable.shale` (run by `ops/check_zig`) fails a change that
  reaches around it.
- **The two hosts are one machine, by contract.** Linux runs one handler at
  a time, as metal's single loop does. Every bound on a request is in
  [`zig-server/src/limits.zig`](zig-server/src/limits.zig), which both hosts
  size their buffers from and `tools/check_caddy_limits.py` holds the
  Caddyfile to.
- **`/version`** reports the running build's `commit`.

Releasing is in zig-metal-unikernel's `DEPLOY.md`; prod's Caddy and the
Linux host are in [`deploy/README.md`](deploy/README.md).

## The apps

The home page (`/`) is a launch pad for the apps. Their order and cards live
in `pages/home.txt`, which `/gallery` (`zig-server/src/gallery.zig`) also
reads.

- **Shale** (`/shale/`): a landing page and an in-browser tutorial for
  [Shale](https://github.com/showell/shale), a small scripting language for
  agents. `ops/build_shale_web` builds the pages from the sibling shale
  checkout into `learn_shale/` (a build output).
- **Safari Screensaver** (`/driving`): a self-driving motorcycle ride down a
  winding road; a Zig core in WebAssembly computes the geometry and a small
  JS blitter draws it. [`games/driving/README.md`](games/driving/README.md)
- **Chat** (`/chat`): real-time chat, docs and channels over Server-Sent
  Events. It is retired in favour of roc-chat, and lynrummy.com's `/chat`
  redirects to chat.lynrummy.com (`deploy/Caddyfile`). The code stays here
  as a reference. [`chat/README.md`](chat/README.md)
- **Seattle Delivery** (`/delivery`): eight trucks routed across Seattle by a
  Clarke-Wright solver in Zig (WebAssembly), drawn by a TS client.
  [`delivery/README.md`](delivery/README.md)
- **Lyn Rummy** (`/game`): two-player rummy against an agent. A Zig solver
  (WebAssembly) picks the plays and hints, a TS layer turns them into table
  gestures, and an Elm UI plays them, all speaking one short text grammar
  for moves (the DSL). [`games/lynrummy/README.md`](games/lynrummy/README.md)
- **Lyn Rummy Puzzles** (`/puzzles`): one mid-game board to solve, with the
  game's solver and rules, undo and replay.
  [`games/lynrummy/elm/src/Puzzle/README.md`](games/lynrummy/elm/src/Puzzle/README.md)
- **Chess Toys** (`/chess`): the Knight's Tour and Eight Queens as
  backtracking searches you can watch and scrub, with their sources at
  `/chess/code`. [`games/chess/README.md`](games/chess/README.md)

The server is [`zig-server/`](zig-server/); its
[`README.md`](zig-server/README.md) covers the internals.

## Quick start

```bash
bash ops/start        # zig server on :9001
```

The build needs chat-markdown and chat-client cloned beside this repo
(`zig-server/build.zig.zon` names them). The shale checkout goes beside it
too, with its `shale` binary on `PATH`: `ops/check_zig` runs Shale's doc
check and this repo's Shale lints, and `ops/build_shale_web` builds the
`/shale/` pages from it.

`ops/start` is the dev loop: it frees :9001, rebuilds the front-end bundles
and WASM cores (`ops/build_embedded` runs every builder that
`zig-server/assets.zon` names), builds the zig binary that embeds them,
relaunches it and waits for the port. Use it in place of a hand-run
`zig build run`.

`GOPHER_CONFIG` names a config file (`data_dir` and auth); unset, the server
uses repo-relative defaults (webbox's `linux_config.zig`). `ops/start` uses
`~/AngryGopher/gopher.conf`. All persistent data lives under `data_dir`,
outside the source tree, so either can be deleted apart from the other.

## Toolchain

- **Zig**, at the version `zig-server/build.zig.zon` names
  (`minimum_zig_version`): the server and every WebAssembly core.
- **Node 22.18 or later**, the first release that strips TypeScript's types
  with no flag: the TS tests and the self-play harness run the `.ts` files
  directly.
- **Elm, TypeScript and esbuild**, project-local and pinned by each
  `package-lock.json`: run `npm install` in `games/lynrummy/elm/`,
  `games/lynrummy/ts/`, `delivery/` and `games/driving/`.
- **`libx11-dev` and `libxrender-dev`**, for `ops/build_safari_download`
  alone (the native Linux Safari binary, which `ops/build_downloads` runs).

Two browser bundles are TypeScript, bundled by `esbuild` into the zig
binary: the Delivery client and the Lyn Rummy engine layer. `tsc` only
typechecks (`npm run typecheck`). In both apps the thinking is a Zig solver
compiled to WebAssembly; `HISTORY.md` says where each app sits between Zig
and TS, and why.

### Fresh box, in order

Each of these is otherwise learned from a failing build.

1. **Node 22.18 or later.**
2. **`npm install` in all four package directories.**
3. **Zig**, on `PATH`. Every `ops/build_*` script and the server use it.
4. **The X11 headers**, for `ops/build_safari_download` only. Missing, they
   show as `unable to find dynamic system library 'X11'`.
   `ops/build_downloads` fills `downloads/`, a built `.site` directory of
   `zig-server/assets.zon`; `ops/start` runs without it (the two download
   links 404 until it runs).
5. **The WASM cores before `zig build`.** `zig-server/build.zig` embeds
   `games/driving/safari.wasm` and `games/chess/{knight,queens}.wasm`, which
   are gitignored, so `ops/build_safari_wasm` and `ops/build_chess_wasm` run
   first (`ops/start` does). The missing file shows as `failed to check
   cache: '…/safari.wasm' file_hash FileNotFound`. The two solver WASMs are
   committed; `ops/build_delivery_wasm` and `ops/build_lynrummy_wasm`
   rebuild them after an edit to their zig.

## Local config & identity

The config is a flat `key = value` file (`#` comments). The server reads
two keys, `data_dir` and `auth_dir`, and ignores the rest:

```
data_dir = /home/you/AngryGopher/local   # all writable state lives here
auth_dir = /home/you/Auth                # account store; defaults to ~/Auth
```

The environment variables, named in `zig-server/src/server.zig`:

- `GOPHER_CONFIG`: the config file (above).
- `GOPHER_PORT`: the listen port, `:9001` by default.
- `GOPHER_BIND`: the listen address.
- `GOPHER_TRUSTED_PROXY`: whose `X-Forwarded-For` names the client
  (default `127.0.0.1`, the local Caddy).
- `GOPHER_KEEPALIVE_MS`: how long a quiet SSE stream waits before a ping;
  for tests.
- `GOPHER_GAME_FLOOR=off`: turns off the game store's free-space floor, for
  a test host whose data sits on a full disk.

`data_dir` holds four trees, `lynrummy`, `chat`, `users` and `players`
(`roots.zig`). `auth_dir` is the account store: one directory per uid
(`{auth_dir}/<id>/{name,password,api-key}`) plus `next-id.txt`. One uid is
the same person across every surface.

**Keep server data outside the repository.** With `data_dir`, `auth_dir`
and the config file outside the checkout, the tree can be deleted while the
data stays, and credentials stay out of git.

### User types & the identity progression

The site asks for a password only at the chat, which holds private data:

**STRANGER → PLAYER → FULL MEMBER**

- **Stranger**: browses the public surfaces (e.g. `/driving`).
- **Player**: a name, with no password, in the local player store
  (`{data_dir}/players/<id>/name`, `player.zig`). A name entered at `/play`
  is enough for **Lyn Rummy** and the puzzles. Anyone may type any name.
  The `gopher_uid` cookie is signed (`uid_cookie.zig`), so a hand-made one
  names no one. Chat, settings, admin and uploads all need a full member.
- **Full member**: an account in `{auth_dir}` with a password, required for
  **chat**. Logging in mirrors the member into the player store under the
  same id, so their game history follows them.

A player id is spelled `p<n>` and an account id is a bare decimal. Both ride
the same `gopher_uid` cookie, and the account resolver reads it only when
it is all digits, so a player is never read as a chat principal.

`/login/full` (`login.zig`) handles logging in and creating an account.

Two accounts stand apart:

- **Admin**: **uid 1**, the first account. Both admin screens (`/admin`
  for chat, `/admin/lynrummy` for the game) check for uid 1 in
  `admin_ui.requireAdmin`.
- **Agent**: **uid 3** (Claude), a full member that authenticates by API key
  (read and write, never admin). See "Reading chat as the agent" below.

### Bootstrapping a fresh environment

From an empty `data_dir` and `auth_dir`, three steps. Account ids are
allocated `1, 2, 3, …` in registration order. **Convention: uid 1 and 2 are
people; uid 3 is the agent (Claude).**

**1. Seed the session secret.** Session cookies and every player's
`gopher_uid` are signed with `{data_dir}/chat/_session_secret`. The server
reads this file and leaves creating it to you: until it exists,
registration answers 500 ("session unavailable") and `/play` sets no
cookie. (`/admin/secret` replaces one that exists.) Seed it once with at
least 32 random bytes:

```bash
mkdir -p "$DATA_DIR/chat"
head -c 48 /dev/urandom > "$DATA_DIR/chat/_session_secret"
chmod 600 "$DATA_DIR/chat/_session_secret"
```

**2. Register the accounts in order.** Each registration POST sent with no
cookie allocates the next id. Use the browser at `/login/full`, or curl:

```bash
for who in Admin Friend Claude; do      # → uid 1, 2, 3
  curl -s -o /dev/null -X POST http://localhost:9001/login/full \
    --data-urlencode "name=$who" \
    --data-urlencode "password=CHANGEME-$who" \
    --data-urlencode "confirm=CHANGEME-$who" \
    --data-urlencode "next=/"
done
```

This writes `{auth_dir}/<id>/{name,password}`.

**3. Give the agent an API key.** Log in as Claude, then
`POST /settings/apikey` (in the browser: `/settings` → *Generate key*). The
key lands at `{auth_dir}/3/api-key`, and the agent sends it as
`Authorization: Bearer <key>`:

```bash
JAR=$(mktemp)
curl -s -o /dev/null -c "$JAR" -X POST http://localhost:9001/login/full \
  --data-urlencode "name=Claude" --data-urlencode "password=CHANGEME-Claude" --data-urlencode "next=/"
curl -s -o /dev/null -b "$JAR" -X POST http://localhost:9001/settings/apikey
cat "$AUTH_DIR/3/api-key"   # 3-<32 hex>
```

### Reading chat as the agent (uid 3)

The reference client, `chat/chat_client.py`, reads chat as the key's
holder. A conversation key pairs two principals (uid 1 × uid 3 → conv
`1_3`); a topic is a named session.

```bash
# This key-holder's conversations and sessions:
GOPHER_API_KEY="$(cat ~/Auth/3/api-key)" \
  python3 chat/chat_client.py conversations http://localhost:9001

# One topic (partner 1, session "yo"):
GOPHER_API_KEY="$(cat ~/Auth/3/api-key)" \
  python3 chat/chat_client.py fetch http://localhost:9001 1 yo
```

A key belongs to the account store that made it, so a local key works
against the local server alone.

## Routes

The dispatch is `route()` in `zig-server/src/router.zig`, one prefix match
per surface. The map:

| Path | What |
|---|---|
| `/` | Home / launch pad (public) |
| `/shale/` | Shale's landing page and in-browser tutorial (public; `shale_page.zig`) |
| `/delivery` | Seattle Delivery sim (public) |
| `/driving`, `/safari_download`, `/downloads` | Safari Screensaver, its native-download page and artifacts (public) |
| `/chess` | Chess Toys: `/chess/knight`, `/chess/queens`, sources at `/chess/code` (public) |
| `/game`, `/puzzles` | Lyn Rummy: full game (player name required), puzzle client |
| `/chat`, `/channel/<name>` | DMs and channels over SSE, `/chat/docs` authoring; `/chat/recent`, `/chat/images`, `/chat/code`, `/chat/search`, `/chat/msg/<id>` (members only; `chat.zig`) |
| `/settings` | Per-user settings, API-key generation among them (members) |
| `/play`, `/login/full`, `/logout` | Name-only player login / member password login |
| `/admin` | The chat roster and API keys (`/admin/apikey`); `/admin/host` (the running server), `/admin/log` (the log as text), `/admin/backup` (an archive of `data/` and `auth/`), `/admin/secret` (change the session secret), `/admin/retire` (retire old topics and users), `/admin/search?key=` (every chat message containing `key`); `/admin/lynrummy` (the game roster). All uid 1 |
| `/gallery`, `/images` | Home-page app emblems and brand assets (public) |
| `/steve-resume` | Server-owned markdown page and a pre-built PDF |
| `/version`, `/debug/mem` | Build version JSON; live allocator counters (the leak smoke detector) |

Most surfaces are public: they resolve the viewer only to label the top
bar. The gates are per surface: Lyn Rummy asks for a player name, and chat
requires a full member. `/play` and login set a signed `__Host-gopher_uid`
cookie; members also get a signed session cookie, `__Host-gopher_auth`. An
**API key** (`Authorization: Bearer`) resolves to its principal as a
session does, read and write as that uid, so uid 1's key is admin.

### The admin routes, in more detail

- **`/admin/log`** narrows by `since=`, `until=`, `request=`, `path=` and
  `boot=` (webbox's `admin_log.zig`).
- **`/admin/retire`** is two steps: a dry run that lists what would go, then
  a confirm. Like `/admin/backup` and `/admin/secret`, it asks for the
  password again.
- **`/admin/search`** reads every transcript the admin can see, unindexed,
  and holds the turn while it does: every other request waits.

## Layout

| Where | Role |
|---|---|
| [`zig-server/`](zig-server/) | **the server (zig)**: every surface as per-module handlers in `src/*.zig` over the shared data tree, with the front-end assets embedded by `build.zig` ([`zig-server/README.md`](zig-server/README.md)) |
| `chat/` | the chat's README and the reference API client and example bot (`chat_client.py`: discover, read, post) |
| `delivery/` | the Delivery display client (TS) and `delivery/zig/`, the CVRP solver, compiled to `solver.wasm` and gated bit-exact against the TS reference solver (`ops/check_delivery`) |
| `games/lynrummy/elm/` | the Elm client (dealer, referee, UI) |
| `games/lynrummy/zig/` | the solver: hints, certificates, Player Two and the self-play sim, compiled to `solver.wasm` |
| `games/lynrummy/ts/` | the DSL and geometry layer (the gestures for the solver's plays) and the self-play harness |
| `ops/` | the build, run and test scripts (`ops/list` lists them) |
| `deploy/` | prod's Caddyfile, the Linux host's systemd unit and runbook |

The server is kept simple, URL-keyed file storage plus the per-surface
handlers, and the logic lives in the client wherever it can. In Lyn Rummy
the solver runs as WASM in the browser, the TS layer turns its answers into
table gestures, and the Elm client owns the game; its
[`README`](games/lynrummy/README.md) covers that split and the DSL.

**Small screens** (the chat surfaces) are laid out client-side. One JS
module, `Viewport` (chat-client's viewport.js), owns the single breakpoint
and exposes it as an `html.vp-narrow` class for CSS and `onChange` for JS.
The nav drawer (chrome_drawer.js) and the chat page's mobile layout
(chat_responsive.js) key off it; the server (`chat_chrome.zig`) ships the
desktop top bar and loads the widgets.

## Ops & testing

The gates, cheapest first (`ops/list` gives each one's rough time):

```
ops/test_docs          Docs gate: doc_xref --all (dead links/paths)
ops/test_elm           Elm client suite
ops/test_ts            TS suite
ops/check_zig          zig server compiles + the lints + the Caddy limits + every unit test, here and webbox's
ops/check_chat         Chat gate: check_common + test_chat
ops/check_lynrummy     Lyn Rummy gate: check_common + test_elm + test_ts + check_solver
ops/check              Pre-commit gate: check_common + test_elm + test_ts + test_chat + check_safari + check_chess + check_solver
ops/check_full         Milestone gate: ops/check + the heavy conformance suites + agent self-play + benches
ops/check_delivery     Delivery zig-solver conformance, run after editing it
```

`ops/start` starts the server and `ops/deploy` is the Linux deploy
([`deploy/README.md`](deploy/README.md)). The ops scripts hold the
sequencing, the prerequisites and the cross-language consistency checks, so
use them in place of bare `zig build`, `elm make` or `tsc`.

## Where to find more

- One app's design: its README, linked in [The apps](#the-apps).
- Lyn Rummy's rules and architecture:
  [`games/lynrummy/RULES.md`](games/lynrummy/RULES.md),
  [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md).
- Per-file knowledge lives in each module's top-of-file comment, and the
  commit history records the design decisions.
