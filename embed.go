package main

import "embed"

// Front-end assets baked into the binary so the server is fully
// self-contained — no working-dir or relative-path dependency at
// runtime, and the "missing elm.js" failure mode is gone. The three
// .js bundles are produced by ops/build_elm and MUST exist before
// `go build`; engine_glue.js, chat.js, docs.js, and the puzzle catalogs
// are committed.
//
//go:embed games/lynrummy/elm/elm.js
//go:embed games/lynrummy/elm/puzzle.js
//go:embed games/lynrummy/elm/engine.js
//go:embed games/lynrummy/elm/engine_glue.js
//go:embed chat/chat.js
//go:embed chat/styles.js
//go:embed chat/chat_compose.js
//go:embed chat/chat_image_popup.js
//go:embed chat/chat_code_popup.js
//go:embed chat/chat_help.js
//go:embed chat/message.js
//go:embed chat/message_view.js
//go:embed chat/nav_stack.js
//go:embed chat/middle_pane.js
//go:embed chat/chat_left_sidebar.js
//go:embed chat/chat_add_topic.js
//go:embed chat/chat_drag_to_pin.js
//go:embed chat/chat_right_sidebar.js
//go:embed chat/chat_search.js
//go:embed chat/docs.js
//go:embed chat/notify.js
//go:embed chat/recent.js
//go:embed chat/images.js
//go:embed chat/code.js
//go:embed learn/learn.js
//go:embed learn/callback_log.js
//go:embed learn/fake_host.js
//go:embed images/cat_professor.webp
//go:embed games/lynrummy/conformance/curated_1line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_2line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_3line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_4line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_5line_puzzles.dsl
//go:embed games/lynrummy/conformance/curated_6line_puzzles.dsl
var assets embed.FS
