# Adding a new op kind to the DSL conformance pipeline

The DSL has a small fixed set of ops today (`validate_game_move`,
`enumerate_moves`, `solve`, `replay_invariant`, …). Adding a *scenario*
that uses an existing op is one .dsl edit. Adding a brand-new *op kind*
costs more: it's the axis this doc is about.

A new op kind needs four things, in roughly this order:

1. **Registry row** in `cmd/fixturegen/main.go` — declares which targets
   (Go / Elm / Python) run this op and points at the per-target emitters.
2. **Per-target emitter functions** — Go and/or Elm test-body codegen.
   Python is interpreted, so there's no codegen — the runner reads the
   JSON fixtures at runtime.
3. **Python runner entry** in `games/lynrummy/python/test_dsl_conformance.py`
   — only if the op runs in Python.
4. **Maybe parser + AST extensions** — only if the op needs new
   scenario fields (a new block like `helper:` or a new expectation
   like `expect.foo:`). Most new ops reuse existing fields.

A registry-validation gate fails loud at fixturegen-time if you forget
step 1, and a manifest cross-check fails loud at Python-test-time if
steps 1 and 3 disagree. So the costly forgot-to-update-the-other-side
failure mode is gone.

## The minimum viable recipe

Adding an op `my_op` that runs in Elm + Python (the most common case
— the referee is the only Go-side citizen):

### 1. Append to `opRegistry` in `cmd/fixturegen/main.go`

```go
{
    Name:    "my_op",
    Elm:     true,
    Python:  true,
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

### 3. Add a Python runner

In `games/lynrummy/python/test_dsl_conformance.py`:

```python
def _run_my_op(sc):
    # ... read fields off sc, run the Python equivalent, assert ...
    return ok, msg

DISPATCH = {
    ...,
    "my_op": _run_my_op,
}
```

The DISPATCH dict is checked against the registry at startup —
if you set `Python: true` and forget to add the runner, the test
script exits non-zero with a clear "registry says python should
handle" message before running any scenarios.

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
- Emits the Go test file (only ops with `Go: true`).
- Emits the Elm test module (only ops with `Elm: true`).
- Emits `conformance_fixtures.json` (only ops with `Python: true`).
- Emits `conformance_ops.json` — the manifest the Python runner
  uses for cross-checking.
- Runs `go build` on the generated Go package.
- Verifies regen idempotence.

### 6. Run the gates

```
python3 games/lynrummy/python/test_dsl_conformance.py
cd games/lynrummy/elm && ./check.sh
```

Both must pass green.

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
- **Python-visible field** — extend `jsonScenario` / `jsonExpect`
  and `toJSONScenario`. Field names use `snake_case` JSON tags
  to match the dict shape Python already uses.

## When the op is referee-only (Go + Elm)

Set `Go: true, Elm: true` and write both `EmitGo` and `EmitElm`.
Don't set `Python: true` — the referee is server-side only and
isn't part of the Python contract.

## Why a registry?

Before this refactor, "which targets run this op?" was encoded in
three independent places:

- `goSupportedOps` map (Go filter)
- `pythonSupportedOps` map (JSON filter)
- the implicit "default → Expect.pass" branch in `elmScenarioBody`'s
  switch (Elm "filter")

Adding an op meant editing at least three locations correctly, with
no machine-checked cross-link. The registry collapses that to one row
per op and adds two cheap gates (registry-vs-scenarios at gen-time,
manifest-vs-DISPATCH at Python startup) that turn forgotten-edit bugs
into loud startup errors.

## Why no Python codegen?

Python is interpreted: the runner can dispatch off a string at runtime.
Codegen would buy nothing and add a re-generate step. The JSON fixtures
are the Python contract; the manifest is the Python reachability check.

## Files involved

- `cmd/fixturegen/main.go` — registry, parser, all three emitters.
- `games/lynrummy/conformance/scenarios/*.dsl` — scenario sources.
- `games/lynrummy/referee_conformance_test.go` — generated Go tests.
- `games/lynrummy/elm/tests/Game/DslConformanceTest.elm` — generated Elm tests.
- `games/lynrummy/python/conformance_fixtures.json` — generated Python fixtures.
- `games/lynrummy/python/conformance_ops.json` — generated ops manifest (registry's eyes for Python).
- `games/lynrummy/python/test_dsl_conformance.py` — Python runner + DISPATCH.
