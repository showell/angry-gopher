# Chat

**Welcome to Chat!** This is the private messaging corner of the site — the
surface Steve, Claude, and a handful of family and friends actually use every
day. Log in at [lynrummy.com/chat](https://lynrummy.com/chat) and you get:

- **1:1 DMs** and **group channels** (the live one is `#General`), with messages
  written in **markdown**, updating **live** as people type-and-send.
- **Topics** — each conversation is split into named threads (a "topic" is just a
  named session), so a chat can hold many parallel threads without losing the plot.
- **Images & screencasts** you can drag in, a world-clock you get by clicking any
  timestamp, cross-message references (`MSG_…` links that jump straight to the
  quoted message), and a **keyboard-first** feel — arrows to move, `/` to search,
  `q`/`r` to quote or refer, `t` for the raw transcript.
- Sibling surfaces on the same machinery: **Docs** (`/chat/docs`, markdown
  authoring), **Recent** (`/chat/recent`, your activity feed), and **Images**
  (`/chat/images`, every picture you can see, in one stream).

It's live and dogfooded daily; the architecture has settled. **The code is the
authority** for how anything works — this file is the human orientation, and the
deeper "why" of one of its best ideas lives in the essay linked below.

## The shape of it: a thin backend, behavior in the browser

The one principle that organizes everything: **keep the backend thin.** The
server (written in **Zig**) authenticates you, stores transcripts as plain files,
renders markdown to HTML, and echoes the on-disk structure back over the wire. The
**URL space mirrors the filesystem 1:1**, and the **behavior lives in the
JavaScript** — navigation, the three-pane layout, the keyboard nav, the bubble
rendering. New behavior almost always belongs in the client, not the server.

A few load-bearing ideas worth knowing before you dig in:

- **`Conv` is the unifying abstraction.** A DM is a `Conv` with two members; a
  channel is a `Conv` with N. Every storage path, SSE keyspace, fan-out loop, and
  sidebar payload takes a `Conv` and iterates its members — so DMs and channels
  share one set of machinery and only diverge at the URL and the notify text.
- **Storage is plain files on disk — no database.** Each topic is a markdown file;
  uploads sit beside it. `appendMessage` is the *single* write chokepoint every
  message is born through, and it fans out the live events (message, notify,
  recent, sidebar, images) to every member.
- **Live updates ride Server-Sent Events.** Several per-user and per-conversation
  SSE streams push new messages and activity; the client replays backlog then
  follows live.
- **MPA at the core, SPA-feel from a user-attention layer.** One transcript =
  one topic = one URL, and switching topics is a real page load (bookmarkable,
  refreshable, browser-native back/forward). What makes it *feel* live is a
  separate per-user layer that survives page loads: cross-topic notifications,
  the violet-favicon alert, pinned sessions, and the Recent feed. The unit of
  *identity* is the URL; the unit of *attention* is the user.
- **Markdown is our own dialect.** Rather than pull in a parser, the server hand-rolls
  a small, deliberate markdown engine — that choice (and why it's the right one for a
  project like this) is the subject of the essay
  **"Afford Your Own Markdown Dialect"**:
  [lynrummy.com/blog/afford-your-own-markdown-dialect](https://lynrummy.com/blog/afford-your-own-markdown-dialect).

## This directory — the browser client

`chat/*.js` is the front end: **hand-written JavaScript, no build step**, embedded
into the zig binary (`@embedFile`) and served as-is. It's organized by a deliberate
"workhorse, edges, and substrate" policy:

- **`chat.js` is the workhorse** — URL hash, view switching, SSE orchestration,
  cross-session navigation, and the wiring that holds the modules together.
- **Edges** (`chat_search.js`, `chat_compose.js`, the sidebars, `chat_help.js`, …)
  are stable, self-contained widgets that each own their own DOM *and* CSS.
- **Substrate** (`message.js`, `message_view.js`, `nav_stack.js`, the popups) are
  the shared abstractions — one bubble, the list-of-bubbles widget, the
  back/forward state machine. They self-style, so they drop into other pages
  (even the `/learn` demos) and just work.

The JS is held honest by a homegrown linter: `tools/jsparse.py` parses the (ES5-ish)
dialect we actually write here, and `tools/lint.py` runs rules over the AST
(silent-catch, dead-code, undefined-call, called-once, …). Both run in
`ops/check_chat`.

The **server** side lives over in `zig-server/src/` — `chat.zig` and its focused
neighbors (`chat_page.zig`, `chat_sse.zig`, `conv.zig`, `chrome.zig`, `recent.zig`,
`images.zig`, `docs*.zig`, …). `chat/chat_client.py` is a small Python reference
client for the HTTP API, so other clients (and our backups) have a worked example.

## Running & testing

`ops/start`, then open `/chat`. The subsystem gate is `ops/check_chat` (JS syntax +
the lint pass + the Python client's syntax); the full pre-commit gate is `ops/check`.
Deploy rides `ops/deploy` — Steve's sign-off only.

For the project-level picture (toolchain, the responsive/mobile design, deploy), see
the repo's top-level [`README.md`](../README.md).

Built by Steve and Claude, and used daily with apoorva and Debbie. It's live, but the
code is tidy and the seams are intentional — if you (or an agent you're working with)
want to build on top of what we wrote, start here, then read the server modules.
