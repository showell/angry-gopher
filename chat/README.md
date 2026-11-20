# Chat

This is the chat that ran on lynrummy.com: DMs, channels and docs, with
messages in markdown that arrive live. It is retired in favour of roc-chat,
and lynrummy.com's `/chat` redirects to chat.lynrummy.com
(`deploy/Caddyfile`).
The code stays here as a reference and still builds and runs locally.

What it does:

- **DMs and channels**, each split into **topics**, named threads.
- **Emoji** by shortcode, **reactions**, **images and screencasts**, and
  `MSG_…` links that jump to a quoted message.
- **Keyboard-first** use: arrows move, `/` searches, `q` and `r` quote or
  refer, `t` shows the raw transcript.
- **Docs** (`/chat/docs`), **Recent** (`/chat/recent`) and **Images**
  (`/chat/images`), on the same machinery.

## The shape of it

**The backend is thin.** The Zig server authenticates, stores transcripts
as plain files, renders markdown and echoes the on-disk structure back. The
URL space mirrors the filesystem. Behavior lives in the JavaScript client.

- **`Conv` unifies DMs and channels.** A DM is a `Conv` with two members, a
  channel one with many. Storage paths, SSE keys, fan-out and the sidebar all
  take a `Conv`.
- **Storage is plain files.** Each topic is a markdown file, with its uploads
  beside it. Every message is written through `appendMessage`, which fans out
  the live events to every member.
- **Live updates ride Server-Sent Events.** The client replays the backlog,
  then follows live.
- **Each topic is a page.** One topic is one URL, and switching topics is a
  real page load. A per-user layer gives the live feel across pages:
  notifications, the favicon alert, pinned sessions and the Recent feed.

## The pieces

- **The server** is `zig-server/src/chat.zig` and its neighbours
  (`chat_*.zig`, `docs*.zig`, `recent*.zig`, `images*.zig`).
- **The browser client** is its own repository, chat-client, a sibling
  checkout: plain JavaScript, served as written and embedded into the zig
  binary.
  `chat-client-rev` pins the commit this server expects.
- **The markdown dialect** is its own repository too, chat-markdown.
- **`chat/chat_client.py`** is a small Python reference client for the HTTP
  API.

## Running and testing

`ops/start`, then open `/chat`. `ops/check_chat` is the chat gate: it holds
`../chat-client` to the pinned commit, runs the client's own `tools/check`
and checks the Python client's syntax.
