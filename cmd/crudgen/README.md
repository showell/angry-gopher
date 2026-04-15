# crudgen — CRUD DSL compiler (spike)

**As-of:** 2026-04-15
**Confidence:** Tentative — spike artifact; original worked example (buddies) was ripped along with the feature; generator still builds but has no live production consumer.
**Durability:** Revisit next time CRUD DSL work is picked up. Likely will be re-evaluated from scratch.

## What it is

Compiles `views/*.claude` DSL files into `views/*.go` HTTP handler source. Opt-in per file: only files explicitly passed on the CLI compile. Deleting the `.claude` file un-opts the page back to hand-written Go.

## Primitives implemented

- **Page metadata.** `path`, `title`, `subtitle`, `auth: user`, `handler: <GoFuncName>`.
- **View with preamble.** `preamble.text` with `{name}` placeholders, `count: SELECT ...` sub-queries filling placeholders.
- **View with table.** `query:` (multi-line SQL with `$user` / `$<field>` substitution), `columns:` (named header → render-call), `empty:` message.
- **Column renderers.** `text(field)`, `toggle_form(flag, post=..., field=..., value=...)`.
- **Handler.** `when: method=POST`, `field <name>: int required` | `string required`, `action: toggle_row { table, match }`, `redirect:`.

## Design decisions (Firm within the spike)

1. **Opt-in at the file level.** Not a framework switch. `.claude` is source of truth when present; generated `.go` is overwritten without hesitation. Deleting `.claude` unsticks the page.
2. **One `.claude` → one `.go`.** No multi-page files. Review is per-file.
3. **Generator knows a small library of primitives.** Unknown primitive = compile error with actionable message.
4. **SQL stays SQL.** No SQL builder DSL. Raw SQL with `$user` / `$<field>` placeholder substitution.
5. **Generated Go is idiomatic.** Looks like hand-written code when diffed.

## What's unresolved

- Whether the grammar stays clean at more screens, or collapses under special-case proliferation — no longer has a worked example to extend from.
- Whether escape hatches (`include_script:`, `after_render:`, `custom_view:`) are ergonomic. None implemented.
- Whether `.claude` files are pleasant to edit at scale.

## Regenerate

```bash
go run ./cmd/crudgen ./views/*.claude
```

## References

- Memory: `feedback_trust_codegen_layers.md` — multi-layer codegen is within Claude's wheelhouse.
- Sibling: `cmd/fixturegen/` — shipped codegen system for LynRummy conformance; uses the same mechanism + discipline.
