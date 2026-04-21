module Game.Random exposing
    ( Seed
    , initSeed
    , next
    , nextInt
    , shuffle
    )

{-| Mulberry32 pseudo-random number generator. Ported from
`angry-cat/src/lyn_rummy/core/card.ts`'s `seeded_rand` plus the
Fisher-Yates shuffle helper from the same file.

**Why faithful port?** Cross-language trace equivalence. Seed
42 in Elm produces the same `nextInt` sequence as seed 42 in
TS. That unlocks diff-against-source validation during testing
(PORTING\_NOTES insight #17).

**Elm divergences from TS:**

  - TS returns a stateful closure (`() => number`); Elm threads
    state explicitly via `(Float, Seed)`. The PRNG state is the
    seed, updated on each call.
  - Math.imul equivalent implemented via 16-bit splitting plus
    `Bitwise.or 0` to truncate to 32-bit signed.
  - `Seed` is an opaque wrapper so the caller can't accidentally
    substitute a non-seed Int.

**Implementation reference:**

    // Mulberry32 (public domain, widely reimplemented).
    function seeded_rand(seed) {
        let t = seed >>> 0;
        return function () {
            t = (t + 0x6D2B79F5) >>> 0;
            let r = Math.imul(t ^ (t >>> 15), 1 | t);
            r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
            return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
        };
    }

-}

import Bitwise



-- SEED


type Seed
    = Seed Int


initSeed : Int -> Seed
initSeed n =
    -- Force unsigned-32 interpretation, mirroring `n >>> 0`.
    Seed (Bitwise.shiftRightZfBy 0 n)



-- MULBERRY32


{-| Advance the PRNG by one step. Returns a float in `[0, 1)`
and the new seed.
-}
next : Seed -> ( Float, Seed )
next (Seed t0) =
    let
        -- t = (t + 0x6D2B79F5) >>> 0
        t =
            Bitwise.shiftRightZfBy 0 (t0 + 0x6D2B79F5)

        -- r = imul(t ^ (t >>> 15), 1 | t)
        r1 =
            imul (Bitwise.xor t (Bitwise.shiftRightZfBy 15 t))
                (Bitwise.or 1 t)

        -- r = (r + imul(r ^ (r >>> 7), 61 | r)) ^ r
        r2 =
            Bitwise.xor
                (r1
                    + imul
                        (Bitwise.xor r1 (Bitwise.shiftRightZfBy 7 r1))
                        (Bitwise.or 61 r1)
                )
                r1

        -- return ((r ^ (r >>> 14)) >>> 0) / 4294967296
        asUint =
            Bitwise.shiftRightZfBy 0
                (Bitwise.xor r2 (Bitwise.shiftRightZfBy 14 r2))
    in
    ( toFloat asUint / 4294967296.0, Seed t )


{-| Pull a uniform random integer in `[0, n)`. `n` must be > 0.
If `n <= 0`, returns `0` (caller's responsibility to guard).
-}
nextInt : Int -> Seed -> ( Int, Seed )
nextInt n seed =
    let
        ( f, newSeed ) =
            next seed
    in
    if n <= 0 then
        ( 0, newSeed )

    else
        ( floor (f * toFloat n), newSeed )



-- FISHER-YATES SHUFFLE


{-| Fisher-Yates shuffle using the seeded PRNG. Returns
`(shuffledList, finalSeed)`. Empty list short-circuits.

The TS source's `shuffle` is mutable (in-place swap); the Elm
port uses an Array for O(1) indexed swaps and converts back to
a List.

-}
shuffle : Seed -> List a -> ( List a, Seed )
shuffle seed items =
    case items of
        [] ->
            ( [], seed )

        _ ->
            let
                arr =
                    itemsToArray items

                ( shuffled, finalSeed ) =
                    fisherYates (arraySize arr - 1) seed arr
            in
            ( arrayToList shuffled, finalSeed )


{-| Fisher-Yates iterates i from (length-1) down to 1, swapping
arr[i] with arr[j] where j is a uniform random int in [0, i].
Mirrors the TS source's backward loop.
-}
fisherYates : Int -> Seed -> ItemArray a -> ( ItemArray a, Seed )
fisherYates i seed arr =
    if i <= 0 then
        ( arr, seed )

    else
        let
            ( j, newSeed ) =
                nextInt (i + 1) seed

            swapped =
                swapAt i j arr
        in
        fisherYates (i - 1) newSeed swapped



-- ARRAY HELPERS
--
-- Using `Array` from elm/core directly, aliased so the function
-- signatures read cleanly.


type alias ItemArray a =
    List a -- Backed by a list for simplicity; O(n) swaps, but
    -- deck size is 104 so this is fine. Could upgrade to
    -- elm/core Array if performance matters later.


itemsToArray : List a -> ItemArray a
itemsToArray =
    identity


arrayToList : ItemArray a -> List a
arrayToList =
    identity


arraySize : ItemArray a -> Int
arraySize =
    List.length


swapAt : Int -> Int -> ItemArray a -> ItemArray a
swapAt i j xs =
    if i == j then
        xs

    else
        List.indexedMap
            (\k x ->
                if k == i then
                    List.drop j xs |> List.head |> Maybe.withDefault x

                else if k == j then
                    List.drop i xs |> List.head |> Maybe.withDefault x

                else
                    x
            )
            xs



-- MATH.IMUL EMULATION


{-| 32-bit signed multiplication with wraparound, matching
JavaScript's `Math.imul(a, b)`. Works by splitting each operand
into 16-bit halves and combining.

`Bitwise.or 0 x` forces the result to 32-bit signed, matching
the `| 0` idiom in JS.

-}
imul : Int -> Int -> Int
imul a b =
    let
        aHi =
            Bitwise.shiftRightBy 16 a

        aLo =
            Bitwise.and 0xFFFF a

        bHi =
            Bitwise.shiftRightBy 16 b

        bLo =
            Bitwise.and 0xFFFF b

        low =
            aLo * bLo

        mid =
            aHi * bLo + aLo * bHi
    in
    Bitwise.or 0 (low + Bitwise.shiftLeftBy 16 mid)
