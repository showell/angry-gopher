# TS → Elm porting handbook

Concrete patterns and transformations for porting TypeScript
code to Elm. Paired with `~/showell_repos/claude-collab/agent_collab/PORTING_CHEAT_SHEET.md` (general
methodology); this doc is the specific answer sheet for this
language pair. Extend as we learn more.

Understand the cross-cutting patterns of the language first;
the tables afterward are the mechanical translation reference.

---

## Cross-cutting patterns

### Explicit shapes

TS lets you lie about shapes (`as any`, optional fields,
implicit `undefined`). Elm won't. During port, many places
where TS got away with implicit shape assumptions need explicit
choices: is this field always present? what if it's absent?
does this function return early on null? These are *port-time
decisions* that Elm's compiler will force you to make.

### Derive, don't store

TS classes often precompute and store values at construction
(e.g., `stack.stack_type` is computed in the constructor and
stored). Default in Elm: derive on demand via a function
(`stackType stack`). Don't carry state that's a pure function
of other state — Elm's immutability eliminates the "they got
out of sync" class of bugs only if you *don't store the
duplicate*.

### TS enums are ints in a trench coat

TS numeric enums are just ints with name aliases. Arithmetic
works directly. Elm's sum types don't have numeric values;
every time you want arithmetic, you need a `toInt` helper.
Most of the time you don't need it — pattern match instead.
When you *do* need it (e.g., `valueDistance` in LynRummy),
write the helper once and use it explicitly.

### Explicit state flow

**State-flow audit belongs early in discovery.** Before writing
Elm, map where state lives in the source: which variables are
captured in closures, which are mutated in place, which flow
through return values. That map is a direct predictor of port
difficulty. LynRummy's audit was trivial — the referee already
used diff-based stateless moves and only `seeded_rand` used
closure-captured mutation. A harder port would surface dozens
of closures-with-mutation up front.

**Closure-captured mutation is the main red flag.** A TS closure
that captures N variables and mutates them across calls is the
hardest pattern to port. Each captured variable becomes part of
an explicit state record in Elm. N captured = at least N extra
parameters (or a named Settings record). The work is mechanical
once you see it; the shock is usually seeing how much implicit
state was hiding.

**The "pre-translation" effect.** When the source author wrote
with Elm-like discipline (pure functions, diff protocols,
explicit state), the port is cheap. When the source is
idiomatic-mutable (React hooks, globals, object-graph mutation),
the port is expensive. LynRummy was written by a past-me who
already thought in FP, so we got the cheap case. This is both a
*calibration* signal ("how hard is this port?") and a
*source-selection* heuristic ("when picking what to port, favor
the FP-discipline ones first").

**Model threading is the big-picture Elm answer.** Small pure
functions take state in, return new state out. At the top level,
Elm's TEA (The Elm Architecture) threads a single `Model`
through `update`. A state-flow port should decide early: is
there a global `Model`? What's in it? Getting this wrong forces
refactoring later.

**The port often wants MORE explicit state than the source had.**
Even where the source could have been less closure-heavy but
wasn't, Elm forces the explicit expression. Opportunity: the
port can be *clearer* than the source because state flow
becomes visible. Don't treat the explicitness as overhead —
treat it as documentation.

---

## Error handling

TS uses exceptions and `null` as failure channels; Elm forces
failures into the type system via `Maybe` and `Result`.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `throw new Error(...)` | `Result Err Ok` or `Maybe` | Parsers that can fail → `Maybe`. Multi-stage validators → `Result` + `andThen` chain. |
| `null` / `undefined` returns | `Maybe` | Most idiomatic conversion. Handle `Nothing` explicitly at the call site. |
| Optional field (`foo?:`) | `Maybe Foo` field, or empty list if the field is list-shaped | Elm records can't have "missing" fields; encode absence explicitly. |
| `try / catch` | `Result.map` / `Result.andThen` chains | Thread errors through pipeline; no ambient throwing. |

## Module structure

Elm namespaces by module (file), not by class, with explicit
exposure lists controlling what's public.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `class Foo { method() ... }` | `module Foo exposing (...)` + record type + module functions | Methods become free functions taking the record as first arg. |
| Private fields (`private x`) | Opaque type + module-level accessors | `type Foo = Foo { x : Int }` then only expose what you want. |
| Getter / setter | Module-level `get` / `set` functions, or record-update syntax | Elm records have structural access; getters are rarely needed. |
| Static methods | Module-level functions (no instance association) | Naming convention only; same module. |
| `import { X } from "./foo"` | `import Foo exposing (X)` or `import Foo` and qualify | Elm forces explicit exposure; no wildcard imports. |

## Traversal

Elm has no loops; collection work is done with `map`, `filter`,
`fold`, or recursion, and all collections are immutable.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `array.map` / `.filter` / `.some` / `.every` | `List.map` / `List.filter` / `List.any` / `List.all` | Direct correspondence. |
| `array.reduce(fn, init)` | `List.foldl fn init list` or `List.foldr` | Argument order differs from TS. `foldl` is left-associative (like TS reduce). |
| `array.slice(start, end)` | `List.take (end - start) (List.drop start list)` | No one-call slice; compose take + drop. |
| `array.concat(other)` | `list ++ other` or `List.concat [a, b]` | Use `++` for two; `List.concat` for many. |
| `array[i]` | `List.head (List.drop i list)` returning `Maybe` | O(n) access; use `Array` type if indexed access matters. |
| `for` loop | Recursion or `List.foldl` / `List.map` etc. | Elm has no imperative loop construct. |
| In-place mutation | Return new value; for stateful operations, pass state as an explicit argument and return new state alongside the result | See the *Explicit state flow* pattern. |

## Custom types

Elm enumerations are sum types (tagged variants), not numeric
values; arithmetic on them requires an explicit `toInt` helper.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| Numeric enum (`enum E { A = 1, B = 2 }`) | Sum type (`type E = A \| B`) + `toInt : E -> Int` helper | Elm enums don't have numeric values; add an explicit `toInt` when arithmetic is needed. |
| String enum | Sum type + `toString` / `fromString` helpers | Same pattern, different conversion functions. |
| Enum with methods | Sum type + module with functions | Methods become free functions pattern-matching on the sum. |

## Structural equality

Equality in Elm is a design question — *which fields should
participate?* — not a mechanical translation. `==` is always
structural across all fields; any exclusion you want is a
custom function you write.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `===` (reference equality) | No equivalent — Elm is structural | Values are compared by content. |
| `a.equals(b)` custom method | `==` on records, or custom `equal : A -> A -> Bool` | Record `==` is structural on all fields; custom equals may need to ignore specific fields (e.g., TS's `str()`-based equality ignoring origin\_deck). |
| String-based equality shortcut (`a.str() === b.str()`) | Explicit field comparison OR mirror the shortcut with care | Check what fields the string representation includes/excludes; the exclusion is often load-bearing (or a latent bug). |

## Wire-format handling

Wire-format lives at a clean *boundary* — between your domain
types and the outside world. Boundaries deserve explicit
treatment; see `~/showell_repos/claude-collab/agent_collab/PORTING_CHEAT_SHEET.md` → "Find the
boundaries."

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `toJSON()` method on a class | Custom encoder function `encodeFoo : Foo -> Value` in the same module, built from `Json.Encode.object`, `.string`, `.int`, etc. | This is what *you write*. Separate from `Json.Encode.encode : Int -> Value -> String`, which is the serialization entry point that produces a string from a `Value`. |
| `from_json()` static on a class | Custom decoder `fooDecoder : Decoder Foo`, composed via `Json.Decode.map`, `.andThen`, `.field`, etc. | This is what *you write*. Serialize in via `Json.Decode.decodeString : Decoder a -> String -> Result Error a` (or `.decodeValue` for a `Value`). Failure is a `Result`, not a throw. |
| Implicit JSON shape | Explicit encoder / decoder pair per type | No ambient serialization; every type that crosses the boundary needs both. Encoder and decoder should be inverse — add a round-trip test. |

## Numbers and bits

Elm separates `Int` and `Float` strictly and has no native
`Math.imul`; bitwise work lives in the `Bitwise` module with
unsigned-vs-signed explicit.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `Math.random()` (non-deterministic) | `Random.Seed` threading | Elm has no ambient random; pass a seed. For cross-language reproducibility, port a deterministic PRNG (e.g., mulberry32). |
| `Math.imul(a, b)` | 16-bit split + `Bitwise.or 0` to truncate | Elm has no native 32-bit signed multiply; emulate by splitting into two 16-bit halves. |
| `x >>> 0` (unsigned 32-bit coerce) | `Bitwise.shiftRightZfBy 0 x` | Forces unsigned interpretation. |
| `x \| 0` (signed 32-bit coerce) | `Bitwise.or 0 x` | Forces int32 interpretation. |
| `Math.floor(f * n)` | `floor (f * toFloat n)` | `floor` returns `Int` in Elm; no coercion needed after. |
| `Math.abs` / `Math.min` / `Math.max` | `abs` / `min` / `max` (built-in) | Direct correspondence; no `Math.` prefix. |
| Int/Float implicit conversion | Explicit `toFloat` / `floor` / `round` | Elm separates the types; conversions must be explicit. |

## String handling

Elm strings are opaque (no indexing); operations live in the
`String` module with the operand-first convention flipped.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| Template strings (`` `${x}` ``) | `"hello " ++ String.fromInt x` | Concatenate with `++`; convert non-strings explicitly. |
| `str.split(",")` | `String.split "," str` | Argument order: separator first. |
| `str.includes(sub)` | `String.contains sub str` | Same pattern. |
| `str[0]` | `String.toList str \|> List.head` returning `Maybe Char` | No string indexing; convert to char list. |

## Module conventions

Elm requires explicit exports (`module X exposing (...)`) and
has no keyword-based `const` / `let` distinction — every
top-level binding is already an immutable value.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| Default exports | Named exports only | Elm requires `module X exposing (name1, name2)`. |
| `const` with computed value at top level | Top-level binding `foo = expr`, optionally preceded by type annotation `foo : T` on its own line | Elm top-level values are all "constants" by default; no keyword needed. |
| Dependency injection via interface | Function taking the dependency as argument | No interfaces; just pass the function or record. |

## UI-layer patterns (added 2026-04-17 during UI port)

These patterns are specific to porting UI code (event loops,
drag/drop, HTTP, DOM construction). The model-layer port didn't
exercise them; the game.ts + drag_drop.ts + plugin.ts layer
does.

### The Elm Architecture (TEA) as the global shape

The top-level of an Elm UI is a `Model` / `Msg` / `update` /
`view` quartet, threaded by `Browser.element` (or
`Browser.application` for multi-page). TS's UI is typically a
class owning state + callbacks — a fundamentally different
shape. Port posture: **don't translate shape; translate
behavior into TEA**. Inventory every piece of mutable state
the TS class owns and place it in `Model`; every
event/callback becomes a `Msg` variant with its payload as the
variant's fields.

### Imperative DOM → declarative view

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `document.createElement("div"); div.appendChild(...)` | `div [] [ ... ]` in `Html msg` | View is a pure function `Model -> Html Msg`. No imperative construction. |
| `element.onclick = handler` | `onClick SomeMsg` in attribute list | Handler dispatches a `Msg`; the update function handles it. |
| `element.style.cssProperty = value` | `style "css-property" value` attribute | Attributes are data, not side effects. |
| DOM-based state reads (`element.value`) | `Msg` carrying the payload from the event decoder | Values flow out via `Html.Events.on "event" decoder` producing a `Msg`. |

### Stateful class → Model + Msg state machine

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| Class with mutable instance fields | Record in `Model`; fields updated via `{ model \| field = newValue }` in `update` | The class identity becomes a sub-record inside `Model`. |
| `this.state = newState` (imperative mutation) | Return `{ model \| state = newState }` from `update` | Always return a new model; never mutate. |
| State machine as `switch (this.phase)` with assignments | `case model.phase of` with explicit returns | Each branch returns the next Model + any Cmds. |
| Class constructor | `init : flags -> ( Model, Cmd Msg )` | Initial model comes from `init`. Any startup effects (HTTP fetch, focus, etc.) go in the Cmd. |

### Drag/drop specifically

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `DragSession` class with `start()`/`move()`/`end()` methods that mutate over the lifetime of a drag | `DragState` variant in Model (`NoDrag`, `Dragging { item : X, offset : Point, ... }`) | Lifecycle expressed as transitions between variants. |
| Global mousemove/mouseup listeners installed on drag start | `Browser.Events.onMouseMove` / `onMouseUp` subscriptions gated by drag state | Subscriptions activate only while dragging. |
| Synchronous collision check inside mousemove handler | `List.filter` over drop targets inside `update` when a `DragMove` Msg arrives | Collision logic moves from callback to update branch. |
| Hand-over via DOM-event bubbling | Msg dispatch with the parent handling the drop explicitly | No bubbling; make the hand-off explicit. |

### Async HTTP (Promise / fetch) → Cmd + Http

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `await fetch(url, { method, body })` | `Http.task { method, url, body, resolver, ... }` wrapped in `Task.attempt ResultMsg` | Returns a `Cmd Msg`; result arrives as a separate `Msg` later. |
| `async function foo() { ... }` chain | Compose `Task` values and `Task.andThen` through the chain | Each step is a pure `Task` description; `Task.attempt` materializes the Cmd. |
| Promise-rejection handling | `Task.onError` or handle the `Err` branch of the `Result` in the result Msg | No throwing; failures are values. |
| `JSON.parse(response)` | `Json.Decode.decodeString decoder body` returning `Result Error a` | Same decoder pattern as wire-format section above. |

### Class-as-singleton → module of functions

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `export const Score = new ScoreSingleton();` + `Score.for_stack(s)` | Module `Score` exposing `forStack : CardStack -> Int` | Drop the object; expose functions. No state to carry, so singleton is gone. |
| Singleton with cached state | Module with functions + a `State` record threaded through calls | If the singleton had state, externalize it; Elm has no module-level mutables. |

### WebXdc-style injected interface → port module or direct function arg

The WebXdc interface in TS is `{ sendUpdate, setUpdateListener, selfAddr, ... }` passed to the game at construction. Elm equivalent:

| TS approach | Elm equivalent | Notes |
|-------------|----------------|-------|
| Constructor takes an interface object | `init` takes a flags record; subsequent effects are `Cmd` | Interface stays external; Elm code describes effects declaratively. |
| Injected `sendEvent(payload)` method | `port sendEvent : Value -> Cmd msg` | Outbound events go through a port. |
| Injected `onEvent(handler)` listener | `port receiveEvent : (Value -> msg) -> Sub msg` | Inbound events come through a subscription port. |

Prefer to avoid ports where an `Http` module Task works. Reserve ports for things Elm can't do natively (DOM focus, WebSocket, localStorage, etc.).

### Decoder-based protocol validation

TS's `protocol_validation.ts` uses `any`-typed runtime checks that accumulate error messages. Elm replaces this with `Json.Decode` pipelines.

| TS approach | Elm equivalent | Notes |
|-------------|----------------|-------|
| `if (typeof card.value !== "number") errors.push(...)` | `Decode.field "value" Decode.int` | Failures are `Result Error a`; no explicit accumulation. |
| Accumulating error list over multiple optional checks | `Json.Decode.Pipeline` with `required` / `optional` | Pipeline-style decoders give good error messages at the first failure. |
| Path-tagged error like `{ message, path: "board[2].card" }` | Elm's default decoder error already carries path info | Use the `Error` type's formatter rather than reinventing path-tagging. |

### When the TS has a "plugin" shell

`game/plugin.ts` is a factory that constructs DOM + wires callbacks. The Elm equivalent is typically `Browser.element` with a `main` function — the plugin boundary disappears into the Elm bootstrap. Port posture: replace plugin.ts with an `Main.elm` that calls `Browser.element`; translate the context-passing into flags.

---

## Test scaffolding

elm-test tests are values, not script-side effects — grouped
via `describe` / `test` and asserted with `Expect`.

| TS pattern | Elm equivalent | Notes |
|------------|----------------|-------|
| `node:assert/strict` IIFE-style tests | `elm-test` with `Test` / `describe` / `test` | Elm tests are values, not script-side effects. |
| `assert.equal(a, b)` | `Expect.equal expected actual` | Note the argument order (expected first). |
| `assert.ok(cond)` | `Expect.equal True cond` or `Expect.notEqual ...` | Elm prefers explicit equality. |
| Inline IIFEs per test block | `describe` group with named tests | More structure; richer reporter output. |
