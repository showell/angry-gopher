#!/usr/bin/env node
// check_js_syntax — syntax-check many JS files in ONE node process.
//
// vm.Script COMPILES (parses) without running, so undefined browser globals
// (window/document/...) are irrelevant — this only catches syntax errors,
// exactly like `node --check`, but without paying ~40ms of node startup per
// file. Replaces the per-file `node --check` spawn loop in ops/test_chat.
//
// Usage: node tools/check_js_syntax.mjs <file.js> [<file.js> ...]
import { readFileSync } from "node:fs";
import vm from "node:vm";

const files = process.argv.slice(2);
let failed = 0;
for (const f of files) {
  try {
    new vm.Script(readFileSync(f, "utf8"), { filename: f });
  } catch (e) {
    console.error(`  SYNTAX ERROR  ${f}: ${e.message}`);
    failed++;
  }
}
if (failed) {
  console.error(`${failed} of ${files.length} file(s) failed syntax check`);
  process.exit(1);
}
console.log(`syntax OK: ${files.length} files`);
