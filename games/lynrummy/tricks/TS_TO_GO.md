# TS → Go porting handbook (LynRummy tricks)

This document is the *idiom contract* for porting the LynRummy
TrickBag from TypeScript (`angry-cat/src/lyn_rummy/tricks/`) to Go
(`angry-gopher/lynrummy/tricks/`). Extend whenever a new mismatch
surfaces during port. Cross-cutting patterns first; reference
tables second (per the TS_TO_ELM precedent).

**Knobs for this port:** durability=5, urgency=1, fidelity=5,
shared_fixtures=11. Fixtures are the durable artifact; Go code can
be thrown away. Don't slavishly mirror TS structure when Go has a
clearer shape.

---

## Cross-cutting patterns

### 1. Plugin shape

TS declares each trick as a `const foo: Trick = { id, description,
find_plays }` satisfying an `interface Trick`. Go's interface
satisfaction is method-based.

Port target: define `Trick` as a Go interface with methods
`ID() string`, `Description() string`, `FindPlays(hand, board)
[]*Play`. Each trick is a package-level `var DirectPlay =
directPlayTrick{}` with a struct type whose methods are the
interface implementation. Avoid "function field on a struct" —
reads worse in Go.

### 2. `Play` is stateful in TS; make it explicit in Go

TS's `Play` closes over captured locals (hand card, target index,
pre-computed merged stack). Go doesn't have expression-level object
literals with method closures in the same ergonomic way. Solution:
`Play` is a struct with **explicit fields** for the captured state,
and `Apply(board []*CardStack) []HandCard` is a method.

One concrete Play struct per trick (`type directPlay struct{ hc
HandCard; targetIdx int; merged *CardStack }`) — not a single
shared Play with a type tag.

### 3. Serializability for fixtures

TS `Play` is not serializable (contains `apply` function). Go
`Play` is similarly non-serializable. For the **fixture layer**,
define a separate `PlayRecord` struct: `{TrickID, HandCards,
BoardAfter}` — what the fixture captures. Tricks produce `Play`
values; tests apply them and compare the resulting board to
`PlayRecord.BoardAfter`.

Never try to make `Play` itself JSON-round-trippable; the closure
behavior is the point.

### 4. Mutation & slice identity

TS tricks mutate `board` in place: `board[i] = merged`,
`board.push(newStack)`. Go slices are pass-by-value-of-header.
Caller-facing signature: `Apply(board *[]*CardStack) []HandCard`
so `Apply` can `append` and re-slice. Or accept a `Board` type
that wraps `[]*CardStack` and mutate through methods.

Lean toward `*[]*CardStack` for minimal ceremony, matching what
the Go referee already does (`angry-gopher/lynrummy/`). Re-check
when porting `Apply`.

### 5. `null` / `undefined` returns

TS functions return `T | null` or `T | undefined` freely. Go idiom:

- Pointer-or-nil for complex types (`*CardStack`).
- `(T, bool)` pair for simple types where `nil` isn't sensible.
- `(T, error)` when failure carries information (rare here —
  tricks silently return empty on failure).

`extract_card` → `extractCard(...) (*BoardCard, bool)`.
`right_merge` → `rightMerge(...) *CardStack` (nil = no merge).

### 6. Errors / failure returns

Tricks signal "doesn't apply" by returning empty slices. No
exceptions, no error values. Preserve: `FindPlays` returns
`[]*Play` (possibly empty); `Apply` returns `[]HandCard` (empty =
failed).

### 7. Collection ops

No built-in `.map` / `.filter` / spread. Write for-loops. Spread
(`...arr`) becomes `append(dst, src...)`. Array destructuring
becomes multi-value assignment or field access. Don't import a
functional-helpers library just to preserve sight-line with TS.

### 8. Equality for map keys

TS `Map` / `Set` use SameValueZero. Go map keys must be
`comparable`. `Card` (value int, suit int, origin_deck int) is
comparable — use directly. `HandCard` is not comparable (has state
field that may or may not matter for key purposes) — key on `Card`
unless state identity is needed.

### 9. Mutation style for tests

TS tests freely construct board states via `new CardStack(...)`
and mutate. Go equivalent: constructor helpers (`NewCardStack`) and
plain struct literals. The `freshly_played`, `push_new_stack`,
`single_stack_from_card` helpers port directly to functions;
`DUMMY_LOC` becomes a package-level `var`.

### 10. Stateless invariant (preserve explicitly)

TS trick modules export a single const. The invariant "tricks are
stateless" is enforced by convention — the const has no fields.
Go: single zero-sized struct value per trick (`type directPlayTrick
struct{}`), no methods that mutate receiver, no package-level
state inside a trick module. Call this out in each trick file's
doc comment.

---

## Reference tables

### Types

| TS | Go |
|---|---|
| `number` (card value, index) | `int` |
| `string` (trick id, description) | `string` |
| `T \| null` / `T \| undefined` | `*T` (nil sentinel) or `(T, bool)` |
| `readonly T[]` | `[]T` (conventional, no compiler enforcement) |
| `Map<K, V>` | `map[K]V` |
| `Set<T>` | `map[T]struct{}` |
| object literal satisfying interface | struct implementing interface |
| class + `new Foo(...)` | struct + `NewFoo(...)` constructor fn |
| closure over locals | struct with explicit fields + method |

### Enums / constants

TS: `enum CardStackType { SET, PURE_RUN, RED_BLACK_RUN, ... }` or
string unions. Go: `type StackType int` + `iota` constants, or
`type StackType string` for debuggability. **Check what Gopher's
existing LynRummy code already uses and match it** — don't
introduce a second enum style in the same package.

### Unused names

TS needs `void X` to silence "unused import" lint. Go's compiler
refuses unused imports; remove the import. TS `_board` for unused
param is a style thing — Go doesn't error on unused *parameters*
(only locals), so keep the name if it documents intent.

### Testing

TS: custom mini framework. Go: `testing` package + table-driven
tests. Fixtures load from JSON with `encoding/json` and drive the
same table-test pattern. Fixture files live at
`angry-gopher/lynrummy/conformance/tricks/`.

---

## Not-yet-decided

- **Package layout.** One file per trick (parallel to TS) vs single
  package file. Revisit after DIRECT_PLAY lands.
- **Play struct type.** Single shared `Play` (with trick-specific
  fields as `interface{}`) vs per-trick `Play` types (like TS
  closures). Gut: per-trick, because fidelity=5 lets us diverge from
  TS's single-type shape. Decide at first port step.
- **Fixture record shape.** `PlayRecord` exact fields TBD; need to
  see a concrete TS test case before locking.
