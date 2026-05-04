# Adding a new op kind to the DSL conformance pipeline

> **To regenerate fixtures: run `ops/check-conformance`.** That script
> invokes fixturegen + runs TS + Elm conformance. Do NOT compose
> `go run ./cmd/fixturegen …` ad-hoc — that's how dev-loop scripts
> drift and Steve loses an hour to resurrection. If you find yourself
> wanting a "smaller" regen-only script, run `ops/list` first; if one
> doesn't exist and you genuinely need it, propose adding it to ops/.

The DSL has a small fixed set of ops today (`validate_game_move`,
`enumerate_moves`, `solve`, `replay_invariant`, …). Adding a *scenario*
that uses an existing op is one .dsl edit. Adding a brand-new *op kind*
costs more: it's the axis this doc is about.

A new op kind needs three or four things, in roughly this order:

1. **Registry row** in `cmd/fixturegen/main.go` — declares which targets
   (Elm / TS) run this op and points at the per-target emitters. The
   `TS` flag means "include in `conformance/fixtures.json`"; the TS
   runner reads that JSON at runtime.
2. **Per-target emitter functions** — Elm test-body codegen. TS reads
   the JSON fixtures at runtime, so there's no TS codegen step.
3. **TS runner entry** in
   `games/lynrummy/ts/test/test_engine_conformance.ts` — only if the
   op needs TS-side coverage (most BFS ops do).
4. **Maybe parser + AST extensions** — only if the op needs new
   scenario fields (a new block like `helper:` or a new expectation
   like `expect.foo:`). Most new ops reuse existing fields.

A registry-validation gate fails loud at fixturegen-time if you
forget step 1.

## The minimum viable recipe

Adding an op `my_op` that runs in Elm + TS (the most common case):

### 1. Append to `opRegistry` in `cmd/fixturegen/main.go`

```go
{
    Name:    "my_op",
    Elm:     true,
    TS:      true,
    EmitElm: elmMyOp,
},
```

### 2. Implement the Elm emitter

```go
func elmMyOp(b *strings.Builder, sc Scenario) {
    fmt.Fprintf(b, "            -- TODO: build inputs from sc, "+
        "call into the Elm module under test, assert.\n"+
        "            Expect.pass")
}
```

Look at `elmEnumerateMoves` or `elmFindOpenLoc` for shorter examples,
`elmReplayInvariant` for a longer one. Helpers like `elmStacks`,
`elmHandCards`, `elmCardLit`, `elmAgentStacks` cover the common
input shapes.

### 3. Add a TS runner entry

In `games/lynrummy/ts/test/test_engine_conformance.ts`, dispatch
the new op shape and assert against `sc.expect`. The dispatcher
reads the same `conformance_fixtures.json` the registry emits.

### 4. Write a scenario in a `.dsl` file

```
scenario my_op_smoke
  desc: shortest sentence that names what this scenario asserts.
  op: my_op
  board:
    at (10,10): AH 2H 3H
  expect:
    foo: bar
```

### 5. Regenerate

```
go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl
```

This:

- Validates the registry covers every op used in `.dsl` files.
- Emits the Elm test module (only ops with `Elm: true`).
- Emits `conformance/fixtures.json` (only ops with `TS: true`).
- Verifies regen idempotence.

### 6. Run the gates

```
ops/check-conformance
```

Runs fixturegen, then TS, then Elm. All must pass green.

## When you also need new scenario fields

Some new ops need data the existing AST doesn't hold (a new block
like `helper:` or a new expectation like `expect.plan_length: N`).
The cost-shape there:

- **New scalar/block field on `Scenario`** — extend the `Scenario`
  struct, add a case to `applyScalarField` (scalar) or
  `applyBlockField` (block). For block fields, you almost always
  want `parseStacks` if it's a list of stacks.
- **New scalar field on `Expectation`** — extend the `Expectation`
  struct and add a case to `parseExpectBlock`. If the field is
  optional, model it as a pointer (`*int`, `*bool`) so emitters
  can detect "was it set?". See `Expect.LogAppended` for the
  pattern.
- **JSON-visible field** — extend `jsonScenario` / `jsonExpect`
  and `toJSONScenario`. Field names use `snake_case` JSON tags.

## When the op is Elm-only

Set `Elm: true` and leave `TS` off — the op only runs in the Elm
test suite.

## Why a registry?

Before this refactor, "which targets run this op?" was encoded in
multiple independent places. The registry collapses that to one row
per op plus a registry-vs-scenarios gate at gen-time that turns
forgotten-edit bugs into loud startup errors.

## Why no TS codegen?

The TS runner reads the JSON fixtures at runtime and dispatches off
the op string — no codegen step needed. The JSON fixtures are the
TS contract.

## Files involved

- `cmd/fixturegen/main.go` — registry, parser, both emitters.
- `games/lynrummy/conformance/scenarios/*.dsl` — scenario sources.
- `games/lynrummy/elm/tests/Game/DslConformanceTest.elm` — generated Elm tests.
- `games/lynrummy/conformance/fixtures.json` — generated JSON fixtures (consumed by TS).
- `games/lynrummy/ts/test/test_engine_conformance.ts` — TS runtime dispatcher.
