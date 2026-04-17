# Serving from Gopher

*Forward plan, 2026-04-17 evening. Prep for the last task of
the day: make the Elm LynRummy client reachable through the
Gopher UI. Two-part shape — today's bar (get it working at
all) and tomorrow's (real integration and deployment).*

**← Prev:** [The Fast Day](the_fast_day.md)
**→ Next:** [Insights from First Few Days of Essay Workflow](insights_from_first_few_days_of_essay_workflow.md)

---

## Part 1: Get it working at all

The Elm client today is served by a Python `http.server` on
port 8788 out of `games/lynrummy/elm-port-docs/`. Two files:
`index.html` + `elm.js`. The server is trivial; Gopher can
replace it in a few dozen lines.

Minimum path:

- **Route.** A new handler under `views/` — probably
  `lynrummy_elm.go` — that responds to
  `/gopher/lynrummy-elm/` and `/gopher/lynrummy-elm/elm.js`.
  Returns the `index.html` and `elm.js` respectively, served
  from disk at `games/lynrummy/elm-port-docs/`.
- **Build step.** `elm.js` is gitignored. The easiest path
  is to add an `elm make` call to `ops/start` so the file is
  produced fresh on every server start. Gopher then serves
  the file from disk without an embed step. No new runtime
  dependency on Gopher's side — just add Elm to the start
  script's prerequisites.
- **Link.** A tile / link on the Gopher landing page
  pointing at `/gopher/lynrummy-elm/`. Audience is Steve
  first, so findability matters. The memory says
  findability=10 for dev-harness tooling; a prominent link
  on the landing page meets that.
- **Verify.** Browse to `http://localhost:9000/gopher/lynrummy-elm/`,
  see the hand+board, drag a card, confirm the drag-merge
  and place-as-singleton paths both work. If they do, we're
  done with Part 1.

That's the bar. No auth, no game state from the server, no
opponent, no turns. Just "the thing we built today, but
served by Gopher."

One detail to watch: the Elm app uses `Browser.element` which
mounts on a node whose position is part of the viewport
layout. Gopher's layout (headers, wiki chrome, sidebars) will
wrap around the `/gopher/lynrummy-elm/` page. Either the Elm
client gets its own chrome-free full-page view (preferable,
since the drag math assumes a clean coordinate frame) or the
Gopher wrapper does the right thing with `position: fixed`.
I'd bias toward the former — same pattern as `wiki.go`'s
`"/gopher/code/"` path that serves raw-ish document views.

Scope note: I'm not porting the existing Angry Cat LynRummy
into this; the Angry Cat path at port 8000 stays alive and
untouched. This is a *second* client, added, not a
replacement.

## Part 2: Next steps — real integration and deployment

Part 1 gives us a static Elm app at a Gopher URL. Real
integration means the Elm client actually plays games the
Gopher server knows about. That's a substantially bigger
piece of work and belongs to a future session, but naming
the shape now keeps the scope honest.

The list, roughly:

- **Player context.** The Elm client needs to know who's
  playing and which game. That arrives via Elm flags
  (`Browser.element`'s `init` argument), populated by the
  Gopher HTML wrapper with the logged-in user's session and
  the game ID from the URL. Gopher already knows this — the
  integration is a JSON payload into the script init call.
- **Initial game state.** Currently the Elm model loads
  `Dealer.initialBoard` + `Dealer.openingHand`. Real play
  loads board + hand + opponent-count + score from Gopher,
  also via flags (or via a first Http request the Elm app
  makes on mount). Decoders for `Board` / `Hand` / `Player`
  need to be written; the JSON formats already exist
  server-side (and the ported `wire_validation` modules
  would land here).
- **Actions round-trip.** Today's drag commits are local —
  the Elm model mutates, the screen updates, nothing
  leaves. Real play sends a `PlayerAction` to Gopher
  (HTTP POST), Gopher validates, persists, and confirms.
  The Elm client applies the confirmed change. This is
  where the deferred `gopher_game_helper` / `protocol_validation`
  modules come into scope.
- **Server push.** Opponent moves arrive without a user
  action on our side. SSE is the existing pattern in
  Gopher (the bell channel uses it). LynRummy events would
  ride a similar channel; the Elm `subscriptions` add an
  `EventSource` port.
- **Turn logic.** Deferred in the current build. Returns
  when the Elm model gains a `Player` record alongside
  `Hand` and `Board`. Bigger change because it affects
  which interactions are legal (you can't drag during your
  opponent's turn).
- **Deployment.** Gopher is a single Go binary today.
  Embedding `elm.js` via `go:embed` would make it truly
  single-binary-deployable; the cost is a full rebuild on
  Elm changes. For dev, file-system serving is fine; for
  a deploy, `go:embed` is the clean answer.

None of Part 2 is today's work. What matters for tonight is
that Part 1 lands — the integration exists, the surface is
reachable through Gopher, and the Elm client proves it can
live under that roof. Tomorrow-us starts from a URL that
works.

## Shape of today's work

- Add `views/lynrummy_elm.go` (probably 30-50 LOC).
- Register route in `views/registry.go`.
- Add Elm build to `ops/start`.
- Add link to the Gopher landing page.
- Verify in-browser. Commit.

Time estimate: 30–45 minutes if nothing surprises us. Main
unknown is how Gopher's existing landing / chrome wants the
new link integrated — I'll look at `wiki.go`'s landing
emitter for precedent.

— C.
