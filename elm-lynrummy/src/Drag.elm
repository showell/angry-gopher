module Drag exposing
    ( Kinematics
    , MousePos
    , advanceMouseSample
    , commitLockState
    , initKinematics
    , isLockedWithHysteresis
    , kinematicsLogFields
    , lockThresholdRatio
    , mouseDecoder
    , projectedRect
    , projectedWithCap
    , rectOverlapArea
    , rectsOverlap
    , velocityAlpha
    )

{-| Drag physics primitives. Shared by all gesture plugins so
they all behave the same way wrt momentum projection, hysteresis,
and velocity smoothing.

These values were measured empirically — see STUDY_RESULTS.md.
Don't change them casually; they're load-bearing on the user-
calibrated feel.
-}

import Json.Decode as D
import Json.Encode as E
import Layout exposing (Placement)



-- VALUES SHIPPED FROM EXPERIMENT 3 (2026-04-13)


{-| Initial-lock threshold: dragged card must cover at least this
fraction of a landing zone to lock. 0.50 gives "got there" feel
without requiring pixel precision.
-}
lockThresholdRatio : Float
lockThresholdRatio =
    0.5


{-| EMA alpha for velocity smoothing in mousemove samples. 0.30 is
responsive without jitter from single-pixel wiggles.
-}
velocityAlpha : Float
velocityAlpha =
    0.3



-- SHARED EVENT DECODING


type alias MousePos =
    { x : Int, y : Int }


mouseDecoder : D.Decoder MousePos
mouseDecoder =
    D.map2 (\x y -> { x = x, y = y })
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)



-- HYSTERESIS-AWARE LOCK


{-| Lock with hysteresis. `wasLocked` is the prior state — if
true, we use the (looser) `unlockRatio` so a small pull-back
doesn't immediately drop the lock and cause ghost flicker. If
false, we use the (tighter) `lockRatio` to require real overlap
before initial lock.

Pass `lockThresholdRatio` explicitly as `lockRatio` for the
shipped default; StackMerge varies this per-condition for the
strict-vs-tolerant axis.
-}
isLockedWithHysteresis :
    Bool
    -> Float
    -> Float
    -> { a | x : Int, y : Int, w : Int, h : Int }
    -> { b | x : Int, y : Int, w : Int, h : Int }
    -> Bool
isLockedWithHysteresis wasLocked lockRatio unlockRatio dragRect landing =
    let
        ratio =
            if wasLocked then
                unlockRatio

            else
                lockRatio
    in
    toFloat (rectOverlapArea dragRect landing)
        >= toFloat (landing.w * landing.h)
        * ratio



-- PROJECTION


{-| Project a drag rect forward along its velocity vector by
`lookahead` milliseconds. Used only for hit-testing, not
rendering — the card is drawn where the mouse is, but the game
asks "where is the player aiming?" when deciding lock.

Equivalent to `projectedWithCap` with `capPx = 0` (no cap).
-}
projectedRect :
    { a | x : Int, y : Int, w : Int, h : Int }
    -> Float
    -> Float
    -> Float
    -> { x : Int, y : Int, w : Int, h : Int }
projectedRect r vx vy lookahead =
    projectedWithCap r vx vy lookahead 0


{-| Project as `projectedRect` but optionally clamp the
projection magnitude to `capPx`. If capPx is 0, no clamping.
The cap addresses the "fast drag overshoots the wing" issue.
-}
projectedWithCap :
    { a | x : Int, y : Int, w : Int, h : Int }
    -> Float
    -> Float
    -> Float
    -> Float
    -> { x : Int, y : Int, w : Int, h : Int }
projectedWithCap r vx vy lookahead capPx =
    let
        offX =
            vx * lookahead

        offY =
            vy * lookahead

        mag =
            sqrt (offX * offX + offY * offY)

        scale =
            if capPx > 0 && mag > capPx then
                capPx / mag

            else
                1
    in
    { x = r.x + round (offX * scale)
    , y = r.y + round (offY * scale)
    , w = r.w
    , h = r.h
    }



-- KINEMATICS — shared per-drag bookkeeping
--
-- Every gesture's drag tracks the same things: cursor position,
-- velocity (EMA-smoothed), peak speed, lock-transition counts,
-- mouse-move counts, timestamps. This record + its helpers
-- centralize that bookkeeping so each gesture only has to handle
-- its own gesture-specific fields (offset to the dragged element,
-- card identity, etc.).


type alias Kinematics =
    { mouseX : Int
    , mouseY : Int
    , vx : Float
    , vy : Float
    , lastMs : Int
    , startedAtMs : Int
    , wasLocked : Bool
    , peakSpeed : Float
    , lockTransitions : Int
    , numMoves : Int
    , startMouseX : Int
    , startMouseY : Int
    }


initKinematics : MousePos -> Int -> Kinematics
initKinematics mouse nowMs =
    { mouseX = mouse.x
    , mouseY = mouse.y
    , vx = 0
    , vy = 0
    , lastMs = nowMs
    , startedAtMs = nowMs
    , wasLocked = False
    , peakSpeed = 0
    , lockTransitions = 0
    , numMoves = 0
    , startMouseX = mouse.x
    , startMouseY = mouse.y
    }


{-| Step 1 of a mouse-move update: take a new mouse sample and
fold it into the kinematics — updates position, velocity, peak
speed, move count, last-tick timestamp. Caller then uses the
returned `vx`/`vy` to compute projection, hit-test for lock,
and finally calls `commitLockState` with the new lock state.
-}
advanceMouseSample : MousePos -> Int -> Kinematics -> Kinematics
advanceMouseSample mouse nowMs k =
    let
        dt =
            max 1 (nowMs - k.lastMs)

        instVx =
            toFloat (mouse.x - k.mouseX) / toFloat dt

        instVy =
            toFloat (mouse.y - k.mouseY) / toFloat dt

        newVx =
            velocityAlpha * instVx + (1 - velocityAlpha) * k.vx

        newVy =
            velocityAlpha * instVy + (1 - velocityAlpha) * k.vy

        speed =
            sqrt (newVx * newVx + newVy * newVy)
    in
    { k
        | mouseX = mouse.x
        , mouseY = mouse.y
        , vx = newVx
        , vy = newVy
        , lastMs = nowMs
        , peakSpeed = max k.peakSpeed speed
        , numMoves = k.numMoves + 1
    }


{-| Step 2 of a mouse-move update: write the freshly-computed
lock state into the kinematics, bumping `lockTransitions` if it
flipped. Decoupled from advanceMouseSample because lock detection
is gesture-specific (varies per landing-zone geometry).
-}
commitLockState : Bool -> Kinematics -> Kinematics
commitLockState newLocked k =
    let
        bump =
            if newLocked /= k.wasLocked then
                1

            else
                0
    in
    { k
        | wasLocked = newLocked
        , lockTransitions = k.lockTransitions + bump
    }


{-| Standard kinematics-derived fields for the per-trial JSON
log. Gestures append their own gesture-specific fields to this.
Adding a new universal field (e.g. dwell-on-zone time) only needs
to be done here.
-}
kinematicsLogFields : Kinematics -> List ( String, E.Value )
kinematicsLogFields k =
    [ ( "startX", E.int k.startMouseX )
    , ( "startY", E.int k.startMouseY )
    , ( "releaseVx", E.float k.vx )
    , ( "releaseVy", E.float k.vy )
    , ( "peakSpeed", E.float k.peakSpeed )
    , ( "wasLockedAtRelease", E.bool k.wasLocked )
    , ( "lockTransitions", E.int k.lockTransitions )
    , ( "numMoves", E.int k.numMoves )
    ]



-- RECT MATH


rectsOverlap :
    { a | x : Int, y : Int, w : Int, h : Int }
    -> { b | x : Int, y : Int, w : Int, h : Int }
    -> Bool
rectsOverlap a b =
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y


rectOverlapArea :
    { a | x : Int, y : Int, w : Int, h : Int }
    -> { b | x : Int, y : Int, w : Int, h : Int }
    -> Int
rectOverlapArea a b =
    let
        xOverlap =
            max 0 (min (a.x + a.w) (b.x + b.w) - max a.x b.x)

        yOverlap =
            max 0 (min (a.y + a.h) (b.y + b.h) - max a.y b.y)
    in
    xOverlap * yOverlap
