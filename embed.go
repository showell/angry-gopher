package main

import "embed"

// Front-end assets baked into the binary so the server is fully
// self-contained — no working-dir or relative-path dependency at
// runtime, and the "missing elm.js" failure mode is gone. The three
// .js bundles are produced by ops/build_elm and MUST exist before
// `go build`; engine_glue.js and the puzzle catalogs are committed.
//
//go:embed games/lynrummy/elm/elm.js
//go:embed games/lynrummy/elm/puzzle.js
//go:embed games/lynrummy/elm/engine.js
//go:embed games/lynrummy/elm/engine_glue.js
//go:embed games/lynrummy/conformance/curated_2line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_3line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_4line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_5line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_6line_puzzles.dsl
var assets embed.FS
