port module Lib.PointerPorts exposing (pointerMoved, pointerUp)

{-| Pointer move/up samples forwarded from a thin JS shim in the host
pages. Elm reads `pointerdown` itself (for card identity); the shim
captures the pointer on its own pointerdown (synchronously, so fast
taps aren't missed) and forwards move/up here — `Browser.Events` has
no pointer subscriptions, and capture lets a mouse/finger drag survive
leaving the origin element. Only the one active pointer is forwarded
(multitouch-safe).

-}


type alias PointerSample =
    { x : Int, y : Int, t : Int }


{-| Forwarded pointermove samples for the active pointer. -}
port pointerMoved : (PointerSample -> msg) -> Sub msg


{-| Forwarded pointerup / pointercancel for the active pointer. -}
port pointerUp : (PointerSample -> msg) -> Sub msg
