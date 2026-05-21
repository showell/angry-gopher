port module Lib.PointerPorts exposing (pointerMoved, pointerUp, trackPointer)

{-| Pointer transport bridge to a thin JS shim in the host pages.

Elm reads the initial `pointerdown` itself (to learn which card is
under the finger), then asks JS to `setPointerCapture` that pointer
and forward the subsequent move/up samples back here. This can't be
done in pure Elm: `Browser.Events` has no pointer subscriptions, and
a touch pointer is implicitly captured to its origin element — which
can re-render mid-drag — so explicit capture on a stable root is
what keeps a finger-drag alive. The shim forwards only the one
tracked pointer id (multitouch-safe).

-}


type alias PointerSample =
    { x : Int, y : Int, t : Int }


{-| Ask JS to capture this pointer id and forward its move/up
samples until the next pointerup/pointercancel.
-}
port trackPointer : Int -> Cmd msg


{-| Forwarded pointermove samples for the tracked pointer. -}
port pointerMoved : (PointerSample -> msg) -> Sub msg


{-| Forwarded pointerup / pointercancel for the tracked pointer. -}
port pointerUp : (PointerSample -> msg) -> Sub msg
