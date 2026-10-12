// The browser's photo resize decision (chat/chat_compose.js resizePlan):
// each boundary with both its sides in one test.
//
//   node tools/test_chat_resize.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../chat/chat_compose.js', import.meta.url), 'utf8');
const sandbox = { window: {} };
vm.runInNewContext(source, sandbox);
const plan = sandbox.window.ChatCompose.resizePlan;
const MB = 1048576;
const tests = [];
const test = (name, f) => tests.push([name, f]);
const same = (got, want) => assert.deepEqual(got === null ? null : { ...got }, want);

test('the longest side: 2048 px is sent as it is, 2049 is scaled to 2048', () => {
  same(plan('image/jpeg', 1 * MB, 2048, 1500), null);
  same(plan('image/jpeg', 1 * MB, 2049, 1500), { width: 2048, height: 1499, type: 'image/jpeg' });
  same(plan('image/jpeg', 1 * MB, 1500, 2048), null);
  same(plan('image/jpeg', 1 * MB, 1500, 2049), { width: 1499, height: 2048, type: 'image/jpeg' });
});

test('a photo at its size: 1.5 MB is sent as it is, one byte more is re-encoded', () => {
  same(plan('image/jpeg', 1.5 * MB, 1200, 900), null);
  same(plan('image/jpeg', 1.5 * MB + 1, 1200, 900), { width: 1200, height: 900, type: 'image/jpeg' });
  same(plan('image/webp', 1.5 * MB + 1, 1200, 900), { width: 1200, height: 900, type: 'image/jpeg' });
});

test('a PNG is scaled and stays PNG, but is never re-encoded for its bytes alone', () => {
  same(plan('image/png', 9 * MB, 2048, 2048), null);
  same(plan('image/png', 9 * MB, 4096, 2048), { width: 2048, height: 1024, type: 'image/png' });
});

test('a phone photo: 4032 x 3024 at 10 MB becomes 2048 x 1536 JPEG', () => {
  same(plan('image/jpeg', 10 * MB, 4032, 3024), { width: 2048, height: 1536, type: 'image/jpeg' });
});

test('a GIF, a video, or a picture with no size is sent as it is', () => {
  same(plan('image/gif', 9 * MB, 4000, 4000), null);
  same(plan('video/mp4', 90 * MB, 4000, 4000), null);
  same(plan('image/jpeg', 9 * MB, 0, 4000), null);
});

test('a sliver keeps at least one pixel', () => {
  same(plan('image/jpeg', 1 * MB, 100000, 10), { width: 2048, height: 1, type: 'image/jpeg' });
});

let failed = 0;
for (const [name, f] of tests) {
  try { f(); } catch (e) { failed++; console.error(`FAIL ${name}\n${e.message}`); }
}
if (failed) { console.error(`${failed} of ${tests.length} resize tests failed`); process.exit(1); }
console.log(`${tests.length} resize tests passed`);
