# Reading DragDropHelper

*Written 2026-04-18. A maintainer's read of `DragDropHelper`
in `angry-cat/src/lyn_rummy/game/game.ts`. Audience:
future-Claude and future-Steve, working on the TS codebase.
Frame: "what does this code already do, and what should you
not break when changing it."*

**← Prev:** [For the Next Session](for_the_next_session.md)
**→ Next:** [Splitting a Stack](splitting_a_stack.md)

---

`DragDropHelper` is a singleton class instantiated once at
boot (line 2928) and held in the module-level `DragDropHelper`
binding (line 2457). Three public methods are the entire
surface for the rest of the file: `enable_drag`,
`accept_click`, `accept_drop`. Everything else in the class is
private bookkeeping or local closures inside `enable_drag`.

This document is a careful read of how those three methods —
especially `enable_drag` — disambiguate a click from a drag
when both are live on the same DOM element.

## The data model

Two maps and a counter, on the singleton:

```ts
seq: number;                                      // monotonic key generator
drop_targets: Map<string, DropTarget>;            // drop_key → callbacks
on_click_callbacks: Map<string, () => void>;      // click_key → callback
```

Each of `accept_click` and `accept_drop` allocates a fresh key
via `seq++`, stamps it on the div as a data attribute
(`data-click_key` or `data-drop_key`), and stores the
corresponding callback in the matching map. That's the
registration side, and it's deliberately stupid — no validation,
no duplicate detection, just monotonic keys + stamp + store.

The maps get **fully cleared** on every pointerup
(`reset_internal_data_structures`, called from inside the
pointerup handler at line 2658). The world is then re-rendered
via `PlayerArea.populate()` + `BoardArea.populate()`, which
re-creates every div and re-calls `accept_click` /
`accept_drop` on them. **The maps live for one drag-or-click
gesture and no longer.** This is important — see the
"gotchas" section.

## The two simple methods

`accept_click` (line 2679) and `accept_drop` (line 2688) are
each four lines. They do what the data model implies. Not much
to say about them in isolation. The complexity all lives in
`enable_drag`.

## `enable_drag` — where the disambiguation happens

The body is ~200 lines (2475–2672) and mostly local closures
+ three event listeners on the same div. The closure captures
several pieces of per-gesture state:

```ts
let dragging = false;            // pointer is currently down on us
let drag_started = false;        // pointermove has fired at least once
let active_click_key: string | undefined;  // click intent captured at pointerdown
let active_target: DropTarget | undefined; // currently-hovered drop target
let orig_x, orig_y;              // pointerdown screen position
let orig_top, orig_left;         // pointerdown div position
```

The disambiguation logic centers on `active_click_key`. Three
events touch it:

### pointerdown (line 2551)

```ts
active_click_key = maybe_get_active_click_key(e);
```

`maybe_get_active_click_key` walks `document.elementsFromPoint(clientX, clientY)` and returns the first element under
the cursor whose `data-click_key` is set, or `undefined`.

This is the load-bearing move: **click intent is captured at
pointer-down time, before any motion**. The pointerdown
listener lives on the *outer draggable element* (e.g., a card
stack), but the cursor at that moment may be on an *inner*
element (e.g., a specific card in that stack) which has
registered itself as click-able via `accept_click`. The walk
through `elementsFromPoint` lets the outer listener notice
"there's a click target under the cursor too — remember its
key in case the user doesn't end up dragging."

`pointerdown` also calls `setPointerCapture(e.pointerId)` —
this is what guarantees subsequent move/up events keep firing
on this div even if the cursor wanders off it. Without
capture, drag math breaks the moment the cursor leaves the
original bounds.

`pointerdown` does NOT call `handle_dragstart` or move the
div. That's deferred to the first pointermove. If the user
just clicks (presses and immediately releases), no movement
happens, so no drag-start fires. The visual stays put.

### pointermove (line 2569)

The very first pointermove flips `drag_started = true`, calls
`start_move()` (sets position absolute + z-index 2), sets the
cursor to grabbing, and calls `handle_dragstart()` (which
typically does `StatusBar.inform(...)` and registers
drop-target wings via `display_mergeable_stacks_for`). This is
the lazy commit-to-drag.

Then on every move (including the first):

```ts
move_div(e);
if (dist_squared(e) > 1) active_click_key = undefined;
```

The 1-pixel-squared threshold is the heart of the click/drag
disambiguation. **Move more than ~1 pixel from where you
pressed → the click intent dies.** Stay within 1 pixel → the
click intent survives.

`dist_squared` uses Euclidean distance squared from the
original pointerdown coordinates, so the threshold is *total*
displacement, not per-event delta. A user who jitters back and
forth within 1 pixel keeps their click intent. A user who
moves 2 pixels, even briefly, loses it forever (the variable
is set to `undefined` and never reassigned by pointermove).

The rest of pointermove handles drop-target hover state:
`get_hovered_target()` walks `.drop_target` elements, finds
the first one overlapping the dragged div, and toggles
`on_over`/`on_leave` callbacks via the `active_target` local.

### pointerup (line 2645)

```ts
if (dist_squared(e) > 1) active_click_key = undefined;
```

Same threshold check, applied one more time at pointerup.
Belt and suspenders — pointerup may fire without an
intervening pointermove (very fast tap with cursor drift), and
the move handler's threshold check wouldn't have caught it.

Then `releasePointerCapture(e.pointerId)` and
`process_pointerup()`.

### `process_pointerup` — click takes precedence

The commit-on-release logic, in order:

1. If we have an `active_target` (cursor over a wing), call
   `on_leave` on it for cleanup.
2. **If `active_click_key` is still set, look up its callback
   and call it. Return immediately.**
3. Otherwise this is a real drag. If the div ended up outside
   the board, scold. Otherwise:
   - If `get_hovered_target()` finds a drop target under the
     cursor, call its `on_drop`.
   - Else check `check_stack_proximity(div)`:
     - "overlapping" → scold (cards can't sit on top of each
       other).
     - else → call `handle_ordinary_move()` (place the
       moved card / stack at its new position).

**Step 2 is the click-precedence rule.** If click intent
survived (cursor never moved ≥1px), the click callback fires
and we never reach the drop or move logic. This is what makes
"press on a card in a stack and release without moving" do a
*split* (the card's click handler) rather than a *no-op move*
of the stack.

## The reset cycle

After `process_pointerup`, in this exact order
(line 2656-2670):

1. `reset_internal_data_structures()` — clear both maps.
2. `PlayerArea.populate(); BoardArea.populate();` — re-render
   the world; every div is replaced; every re-rendered card /
   stack / wing re-calls `accept_click` / `accept_drop`,
   re-stamping fresh `data-*_key`s and re-populating the
   maps under fresh `seq` values.
3. Reset local closure state (`dragging = false; drag_started
   = false; active_click_key = undefined; active_target =
   undefined`). The comment marks this as paranoia, since
   step 2 destroyed the divs the closure was bound to.

The order matters and the comment in the code calls it out:
the maps must be cleared *before* the re-render, because the
re-render generates new keys via the same `seq` counter. If
the old entries weren't cleared, the maps would leak entries
that point at divs that no longer exist.

## Gotchas — things to not break

1. **Don't make the rendering smarter without revisiting the
   reset cycle.** The current contract is "every pointerup
   tears everything down and rebuilds." If you switch to
   incremental DOM updates (don't re-create divs that didn't
   change), the click_key and drop_key stamps survive across
   gestures — but the maps get cleared on every pointerup. You
   end up with stamped divs that point at no callback. The
   click handler silently does nothing. Either keep the
   clear+rebuild contract or switch to a different scheme
   entirely (e.g., don't clear maps on pointerup; clear only
   when divs are removed).

2. **Don't change card stacking such that
   `elementsFromPoint` misses the inner card.** If you switch
   the card div to `pointer-events: none`, or wrap it in
   another transparent layer at higher z-index without a
   click_key, the pointerdown's click-key sniff may miss it.
   The click-on-card-to-split feature depends on the click
   target being the topmost element with `data-click_key` at
   the pointer position.

3. **The 1-pixel threshold is tight.** A user with slightly
   shaky hands or a high-DPI touchscreen may unintentionally
   convert clicks to drags. If you need to relax this, change
   `dist_squared(e) > 1` in both pointermove and pointerup.
   Note that it's distance-squared, so the comparison value is
   `pixels²`. Bumping to `> 9` would mean a 3-pixel total
   movement allowance.

4. **`drop_targets.clear()` at pointerdown** (line 2558) is
   defensive. The end-of-pointerup repopulation pass already
   clears+re-registers them, so under nominal flow the
   pointerdown clear is redundant. It's there in case a
   prior gesture didn't complete cleanly (browser dropped a
   pointerup, etc.). Don't remove without auditing for that
   failure mode.

5. **`div.draggable = true`** at line 2483 sets the HTML5
   draggable attribute, but the rest of the listener flow uses
   pointer events, not drag events. The attribute may be
   vestigial — possibly there to suppress browser default
   text-selection, possibly to enable some platform-specific
   default. I haven't traced its effect; leave it alone unless
   you need to.

6. **`setPointerCapture` is critical and easy to break.**
   Don't drop it from pointerdown without replacing the
   guarantee. The drag math assumes pointermove keeps firing
   even when the cursor leaves the original div. Without
   capture, fast drags will lose pointermove events as soon as
   they cross the div's edge.

## Inversion of normal layering

One unusual thing worth naming: the click handler is wired up
via a *listener on the parent draggable element* (the stack),
not on the *target of the click* (the card). The card just
stamps itself with a `data-click_key`. The disambiguation is
entirely the parent's responsibility — the parent decides at
pointer-down time whether a child's click intent should be
honored.

This is the opposite of the usual "child registers a click
listener" pattern. It works here because click and drag are
two interpretations of the *same physical gesture* on the same
piece of geometry. Splitting the listeners between child and
parent would require complex coordination to suppress one when
the other fires. Co-locating them on the parent and using
distance to disambiguate is the cleaner trick.

If you ever add a third gesture (a long-press, say), the
natural place is the same enable_drag closure, with a timer
started at pointerdown that fires the long-press if no
pointerup or pointermove arrives within N ms. Same shape:
parent listener, intent captured at pointerdown, killed by
later events that contradict it.

## Summary

The disambiguation is three lines of logic:

1. At pointerdown, sniff for a `data-click_key` under the
   cursor. Save it.
2. On any pointer movement past 1 pixel, drop the saved
   click_key.
3. At pointerup, if the click_key survived, fire it and skip
   the drop logic; otherwise process as a drag.

Everything else in the file is plumbing for those three lines.
Keep that mental model and the rest of the code reads cleanly.

— C.
