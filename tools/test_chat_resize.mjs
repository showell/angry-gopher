// The browser's photo resize (chat/chat_compose.js): resizePlan's decision,
// each boundary with both its sides in one test; and shrinkPicture over a
// stubbed DOM, which must hand over a file exactly once whatever fails.
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
  same(plan('image/jpg', 1.5 * MB + 1, 1200, 900), { width: 1200, height: 900, type: 'image/jpeg' });
  same(plan('image/pjpeg', 1.5 * MB + 1, 1200, 900), { width: 1200, height: 900, type: 'image/jpeg' });
});

test('a PNG is scaled and stays PNG, but is never re-encoded for its bytes alone', () => {
  same(plan('image/png', 1 * MB, 1000, 800), null);
  same(plan('image/png', 9 * MB, 2048, 2048), null);
  same(plan('image/png', 9 * MB, 4096, 2048), { width: 2048, height: 1024, type: 'image/png' });
});

test('a phone photo: 4032 x 3024 at 10 MB becomes 2048 x 1536 JPEG', () => {
  same(plan('image/jpeg', 10 * MB, 4032, 3024), { width: 2048, height: 1536, type: 'image/jpeg' });
});

test('a GIF or WebP (maybe animated), a video, or a picture with no size is sent as it is', () => {
  same(plan('image/gif', 9 * MB, 4000, 4000), null);
  same(plan('image/webp', 9 * MB, 4000, 4000), null);
  same(plan('video/mp4', 90 * MB, 4000, 4000), null);
  same(plan('image/jpeg', 9 * MB, 0, 4000), null);
});

test('a sliver keeps at least one pixel', () => {
  same(plan('image/jpeg', 1 * MB, 100000, 10), { width: 2048, height: 1, type: 'image/jpeg' });
});

// shrinkPicture over a stubbed DOM: `dom(o)` builds the browser's pieces
// (o.decode: 'load' | 'error' | 'never'; o.context: false for a null 2D
// context; o.draw: 'throw'; o.blob: a size, null, or 'never'), runs the
// module against them, and returns what was handed over and the timers.
function shrinkWith(file, o) {
  const timers = [];
  const handed = [];
  class FakeImage {
    set src(_) {
      if (o.decode === 'load') { this.naturalWidth = o.w; this.naturalHeight = o.h; this.onload(); }
      else if (o.decode === 'error') this.onerror();
    }
  }
  const canvas = {
    getContext: () => o.context === false ? null : {
      fillRect() {}, drawImage() { if (o.draw === 'throw') throw new Error('draw'); },
    },
    toBlob(cb) { if (o.blob !== 'never') cb(o.blob === null ? null : { size: o.blob }); },
  };
  const box = {
    window: {}, Image: FakeImage,
    URL: { createObjectURL: () => 'blob:x', revokeObjectURL() {} },
    document: { createElement: () => canvas },
    File: class { constructor(parts, name, opts) { this.name = name; this.type = opts.type; this.size = parts[0].size; } },
    setTimeout: (f) => { timers.push(f); return timers.length; },
    clearTimeout() {},
  };
  vm.runInNewContext(source, box);
  box.window.ChatCompose.shrinkPicture(file, (f) => handed.push(f));
  return { handed, timers };
}
const photo = { type: 'image/jpeg', size: 10 * MB, name: 'IMG_1.HEIC.jpeg' };

test('a phone photo that shrinks is handed over once, as a JPEG named .jpg', () => {
  const { handed, timers } = shrinkWith(photo, { decode: 'load', w: 4032, h: 3024, blob: 1 * MB });
  assert.equal(handed.length, 1);
  assert.equal(handed[0].type, 'image/jpeg');
  assert.equal(handed[0].name, 'IMG_1.HEIC.jpg');
  assert.equal(handed[0].size, 1 * MB);
  timers.forEach((f) => f());
  assert.equal(handed.length, 1, 'the watchdog after a hand-over hands nothing more');
});

test('every failure hands over the original, exactly once', () => {
  const cases = {
    'the decode fails': { decode: 'error' },
    'no 2D context (iOS out of canvas memory)': { decode: 'load', w: 4032, h: 3024, context: false },
    'drawing throws': { decode: 'load', w: 4032, h: 3024, draw: 'throw' },
    'toBlob gives nothing': { decode: 'load', w: 4032, h: 3024, blob: null },
    'the shrunk one is no smaller': { decode: 'load', w: 4032, h: 3024, blob: 10 * MB },
    'no resize is planned': { decode: 'load', w: 1200, h: 900 },
  };
  for (const [why, o] of Object.entries(cases)) {
    const { handed, timers } = shrinkWith({ ...photo, size: o.w === 1200 ? 1 * MB : photo.size }, o);
    timers.forEach((f) => f());
    assert.equal(handed.length, 1, why);
    assert.equal(handed[0].type, 'image/jpeg', why);
    assert.equal(handed[0].name, photo.name, why);
  }
});

test('a decode or a toBlob that never answers: nothing until the watchdog, then the original', () => {
  for (const o of [{ decode: 'never' }, { decode: 'load', w: 4032, h: 3024, blob: 'never' }]) {
    const { handed, timers } = shrinkWith(photo, o);
    assert.equal(handed.length, 0);
    assert.equal(timers.length, 1);
    timers[0]();
    assert.deepEqual(handed, [photo]);
  }
});

test('a GIF or WebP is handed over as it is, never decoded', () => {
  for (const type of ['image/gif', 'image/webp', 'video/mp4']) {
    const f = { type, size: 9 * MB, name: 'x' };
    const { handed } = shrinkWith(f, { decode: 'error-if-decoded' });
    assert.deepEqual(handed, [f], type);
  }
});

let failed = 0;
for (const [name, f] of tests) {
  try { f(); } catch (e) { failed++; console.error(`FAIL ${name}\n${e.message}`); }
}
if (failed) { console.error(`${failed} of ${tests.length} resize tests failed`); process.exit(1); }
console.log(`${tests.length} resize tests passed`);
