# crudgen — CRUD DSL compiler (spike, 2026-04-14)

Compiles `views/*.claude` DSL files into `views/*.go` HTTP handler
source. Opt-in: only files explicitly passed on the CLI compile.
Deleting the `.claude` file un-opts the page back to hand-written Go.

## Current status

**Proven end-to-end** with one screen: `views/buddies.claude` →
`views/buddies.go`. GET renders correct HTML (preamble + table + toggle
forms); POST toggles buddy rows and 303-redirects. Verified via live
curl against a running Gopher.

Regen time: ~0.2s. Generated Go compiles clean. Buddies .claude is
28 lines; generated .go is ~70 lines (vs 98 lines hand-written).

## Primitives implemented

- **Page metadata.** `path`, `title`, `subtitle`, `auth: user`, `handler: <GoFuncName>`.
- **View with preamble.** `preamble.text` with `{name}` placeholders, `count: SELECT ...` sub-queries filling placeholders.
- **View with table.** `query:` (multi-line SQL with `$user` / `$<field>` substitution), `columns:` (named header → render-call), `empty:` message.
- **Column renderers.** `text(field)`, `toggle_form(flag, post=..., field=..., value=...)`.
- **Handler.** `when: method=POST`, `field <name>: int required` | `string required`, `action: toggle_row { table, match }`, `redirect:`.

## Remaining screens in the spike (what's needed)

Each additional screen introduces grammar extensions. None are
conceptually hard — they're all "add one more primitive." The
order reflects increasing extension load.

| Screen | New primitives needed |
|---|---|
| **channels** | `channel_link(id, name)` column; `bool_text(col, truthy, falsy)` column; form field primitives `text`, `textarea`, `checkbox`; hidden-field support; action `insert_row { table, columns }` |
| **users** | Inline form-in-list-view (current "edit own name"); `user_link(id, name)` column (already have a Go helper); row-style conditional (`highlight_if: id == $user`); **detail view** (`view detail when: id`); related-data block (sub-query against `subscriptions`) |
| **invites-view** | `auth: admin` branch (infrastructure exists; just needs the handler gate); date-typed field; handler that does `INSERT` with computed expiry |
| **game-lobby** | Owner-gated form (`[owner: player1_id, player2_id]`); admin-gated form alongside owner-gated; form field `value=<col>`; **escape hatch** for replay view (see below) |

## Escape-hatch patterns (for game-lobby's replay)

Replay view is 300+ lines of canvas/JS/SSE that is NOT CRUD-shaped.
The right design:

- **`include_script: replay.js`** — DSL declares, tool emits `<script src=>` on page load.
- **`after_render: go_func_name`** — named Go function in a sibling `games_extras.go` gets called; can emit arbitrary HTML. Replay's canvas scaffold goes there.
- **`custom_view <name>: <go_func>`** — entire view delegates to a hand-written Go function. Use when DSL can't express it at all.

None of these are implemented yet — they're the planned extension.

## Design decisions locked in

1. **Opt-in at the file level.** Not a framework switch. `.claude` is source of truth when present; generated `.go` is overwritten without hesitation. Deleting `.claude` unsticks the page.
2. **One `.claude` → one `.go`.** No multi-page files. Review is per-file.
3. **Generator knows a small library of primitives.** Unknown primitive = compile error with actionable message. Adding a primitive is a Go code change in the emitter.
4. **SQL stays SQL.** No SQL builder DSL. Raw SQL with `$user` / `$<field>` placeholder substitution.
5. **Preamble text wraps in `<p>...</p>` automatically.** Convenience; table columns do not.
6. **Generated Go is idiomatic.** Looks like hand-written code when diffed.

## What the spike did NOT prove

- Whether the grammar stays clean at 5+ screens, or collapses under special-case proliferation.
- Whether the escape hatch for replay is ergonomic.
- Whether `.claude` files are pleasant to edit at scale (vs. just viewing one in isolation).
- Whether generated code readability holds up for more complex pages.

## To resume the spike

1. Pick next screen — order suggested above (channels → users → invites-view → game-lobby).
2. For each grammar extension, update `cmd/crudgen/main.go` and re-verify buddies still compiles (no regression).
3. After two more screens, re-evaluate: is the DSL converging (primitives stabilizing) or diverging (each screen adds unique primitives)?

## Regenerate

```bash
go run ./cmd/crudgen ./views/*.claude
```

## References

- Spike proposal + design: conversation 2026-04-14.
- Memory: `feedback_trust_codegen_layers.md` — multi-layer codegen is within Claude's wheelhouse.
- TASKS.md entry: "Replace fixture system with code-generation from a mainstream language" — CRUD DSL is the sibling of that work; fixturegen already landed in `cmd/fixturegen/`.
