module Lib.LongPress exposing (scheduleTimer)

{-| Long-press timer: the `Cmd` that fires the host's
`LongPressTimerFired` Msg after `holdMs`. The pointerdown
timestamp is echoed back so a late-firing timer can be
distinguished from the press it was scheduled for.
-}

import Process
import Task


holdMs : Float
holdMs =
    400


scheduleTimer : (Int -> msg) -> Int -> Cmd msg
scheduleTimer toMsg startTimeMs =
    Process.sleep holdMs
        |> Task.perform (\_ -> toMsg startTimeMs)
