# critters/proto — SPIKE

Browser prototypes for new critter-study mechanics, iterated
standalone before any of the Elm engine or the `.claude` DSL
is touched.

Contents are explicitly **SPIKE-labeled** — expect churn, don't
build on top of these files as if they were stable. When a
prototype graduates, it moves into the Elm engine at
`~/showell_repos/elm-critters/` and/or gets a proper study DSL
under `../studies/`.

## Serving

```
cd ~/showell_repos/angry-gopher/games/critters/proto
python3 -m http.server 8788
```

Browse at `http://localhost:8788/<file>.html`.

The main Angry Gopher server (port 9000) does not serve this
directory. Keeping the prototype server on its own port (8788)
avoids cross-contamination.

## Current prototypes

| File | Status | Notes |
|---|---|---|
| `cow_dogs_v2.html` | current canonical (2026-04-17, iter 3) | Drag the dog; cows flee under pressure; bumps impart momentum; physical-recoil visual cue. |
| `cow_dogs_bump_vote.html` | archived exploration | Three-variant A/B/C voting harness that led to Variant C winning for bump visualization. |

## Related work

- Narrative for the V2 cow design: `~/showell_repos/angry-gopher/showell/claude_writings/the_dog_as_opcode.md`
- Concept frame (indirect manipulation): the Cook-Levin VM
  simulator at `~/showell_repos/virtual-machine-go/ui/vm.html`
  and its essay `phase_not_motion.md`.
- Gopher integration side (unchanged by this prototype work):
  `../critters.go` and the study DSLs at `../studies/`.
