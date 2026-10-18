//! **THE ELM APPS' POINTER TRANSPORT**: the script a page runs after its
//! Elm app starts, so a drag reaches Elm (Browser.Events has no pointer
//! subscriptions). A pointerdown captures a touch or pen pointer, so a
//! finger drag survives the card re-rendering mid-drag; the active
//! pointer's moves and its up go to the app's `pointerMoved` and
//! `pointerUp` ports. Lyn Rummy's page and the puzzles' splice it in where
//! each wrote it out (shale's cookbook/zig/clones.shale found the two).

/// The script, as a page's `<script>` holds it: `app` is the Elm app.
pub const js =
    \\  (function () {
    \\    var captureEl = document.documentElement;
    \\    var tracked = null;
    \\    function sample(e) {
    \\      return { x: Math.round(e.clientX), y: Math.round(e.clientY), t: Math.floor(e.timeStamp) };
    \\    }
    \\    document.addEventListener("pointerdown", function (e) {
    \\      tracked = e.pointerId;
    \\      // Capture touch/pen so a finger-drag survives the card re-rendering
    \\      // mid-drag. Mouse needs no capture (document sees every move) and
    \\      // capturing a mouse pointer can interfere with button clicks.
    \\      if (e.pointerType !== "mouse") {
    \\        try { captureEl.setPointerCapture(e.pointerId); } catch (err) {}
    \\      }
    \\    });
    \\    document.addEventListener("pointermove", function (e) {
    \\      if (e.pointerId === tracked) app.ports.pointerMoved.send(sample(e));
    \\    });
    \\    function end(e) {
    \\      if (e.pointerId !== tracked) return;
    \\      tracked = null;
    \\      app.ports.pointerUp.send(sample(e));
    \\    }
    \\    document.addEventListener("pointerup", end);
    \\    document.addEventListener("pointercancel", end);
    \\  })();
;
