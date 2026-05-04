"use strict";
var LynRummyEngine = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // games/lynrummy/ts/src/engine_entry.ts
  var engine_entry_exports = {};
  __export(engine_entry_exports, {
    agentPlay: () => agentPlay,
    findPlay: () => findPlay,
    jsonStack: () => jsonStack,
    solveBoard: () => solveBoard,
    solveStateWithDescs: () => solveStateWithDescs
  });

  // games/lynrummy/ts/src/rules/card.ts
  var RANKS = "A23456789TJQK";
  var SUITS = "CDSH";
  var RED = /* @__PURE__ */ new Set([1, 3]);
  function cardLabel(c) {
    const base = RANKS[c[0] - 1] + SUITS[c[1]];
    return c[2] === 0 ? base : `${base}'`;
  }
  function isRedSuit(s) {
    return RED.has(s);
  }

  // games/lynrummy/ts/src/classified_card_stack.ts
  var KIND_RUN = "run";
  var KIND_RB = "rb";
  var KIND_SET = "set";
  var KIND_PAIR_RUN = "pair_run";
  var KIND_PAIR_RB = "pair_rb";
  var KIND_PAIR_SET = "pair_set";
  var KIND_SINGLETON = "singleton";
  function successor(v) {
    return v === 13 ? 1 : v + 1;
  }
  function classifyPair(cards) {
    const a = cards[0];
    const b = cards[1];
    const av = a[0], asu = a[1];
    const bv = b[0], bsu = b[1];
    if (av === bv) {
      return asu !== bsu ? KIND_PAIR_SET : null;
    }
    if (successor(av) !== bv) return null;
    if (asu === bsu) return KIND_PAIR_RUN;
    if (RED.has(asu) !== RED.has(bsu)) return KIND_PAIR_RB;
    return null;
  }
  function classifyLong(cards) {
    const a0 = cards[0];
    const a1 = cards[1];
    const a0v = a0[0], a0s = a0[1];
    const a1v = a1[0], a1s = a1[1];
    const n = cards.length;
    if (a0v === a1v) {
      if (a0s === a1s) return null;
      const seen = /* @__PURE__ */ new Set([a0s, a1s]);
      for (let i = 2; i < n; i++) {
        const c = cards[i];
        const cv = c[0], cs = c[1];
        if (cv !== a0v || seen.has(cs)) return null;
        seen.add(cs);
      }
      return KIND_SET;
    }
    if (successor(a0v) !== a1v) return null;
    if (a0s === a1s) {
      let prevV2 = a1v;
      for (let i = 2; i < n; i++) {
        const c = cards[i];
        if (c[0] !== successor(prevV2) || c[1] !== a0s) return null;
        prevV2 = c[0];
      }
      return KIND_RUN;
    }
    const a0red = RED.has(a0s);
    const a1red = RED.has(a1s);
    if (a0red === a1red) return null;
    let prevV = a1v;
    let prevRed = a1red;
    for (let i = 2; i < n; i++) {
      const c = cards[i];
      if (c[0] !== successor(prevV)) return null;
      const cRed = RED.has(c[1]);
      if (cRed === prevRed) return null;
      prevV = c[0];
      prevRed = cRed;
    }
    return KIND_RB;
  }
  function classifyRaw(cards) {
    const n = cards.length;
    if (n === 0) return null;
    if (n === 1) return KIND_SINGLETON;
    if (n === 2) return classifyPair(cards);
    return classifyLong(cards);
  }
  function classifyStack(cards) {
    const kind = classifyRaw(cards);
    if (kind === null) return null;
    return { cards, kind, n: cards.length };
  }
  function familyOfKind(kind) {
    switch (kind) {
      case KIND_RUN:
      case KIND_PAIR_RUN:
        return KIND_RUN;
      case KIND_RB:
      case KIND_PAIR_RB:
        return KIND_RB;
      case KIND_SET:
      case KIND_PAIR_SET:
        return KIND_SET;
      default:
        return null;
    }
  }
  function pairOf(family) {
    switch (family) {
      case KIND_RUN:
        return KIND_PAIR_RUN;
      case KIND_RB:
        return KIND_PAIR_RB;
      case KIND_SET:
        return KIND_PAIR_SET;
      default:
        throw new Error(`pairOf: unexpected family ${family}`);
    }
  }
  function familyForTwoCards(c1, c2) {
    const v1 = c1[0], s1 = c1[1];
    const v2 = c2[0], s2 = c2[1];
    if (v1 === v2) {
      if (s1 === s2) return null;
      return KIND_SET;
    }
    if (successor(v1) !== v2) return null;
    if (s1 === s2) return KIND_RUN;
    if (RED.has(s1) !== RED.has(s2)) return KIND_RB;
    return null;
  }
  function kindAfterAbsorbRight(target, card) {
    const targetKind = target.kind;
    const nNew = target.n + 1;
    if (targetKind === KIND_SINGLETON) {
      const only = target.cards[0];
      const family2 = familyForTwoCards(only, card);
      if (family2 === null) return null;
      return pairOf(family2);
    }
    const family = familyOfKind(targetKind);
    const last = target.cards[target.cards.length - 1];
    const av = last[0], asu = last[1];
    const bv = card[0], bsu = card[1];
    if (family === KIND_RUN) {
      if (asu !== bsu || (av === 13 ? 1 : av + 1) !== bv) return null;
    } else if (family === KIND_RB) {
      if ((av === 13 ? 1 : av + 1) !== bv) return null;
      if (RED.has(asu) === RED.has(bsu)) return null;
    } else {
      if (av !== bv || asu === bsu) return null;
      if (nNew > 4) return null;
      for (const c of target.cards) {
        if (c[1] === bsu) return null;
      }
    }
    if (nNew >= 3) return family;
    return pairOf(family);
  }
  function shapeId(value, suit) {
    return value * 4 + suit;
  }
  function extendsForSingleton(only) {
    const v = only[0];
    const s = only[1];
    const succV = v === 13 ? 1 : v + 1;
    const predV = v === 1 ? 13 : v - 1;
    const onlyRed = RED.has(s);
    const left = /* @__PURE__ */ new Map();
    const right = /* @__PURE__ */ new Map();
    left.set(shapeId(predV, s), KIND_PAIR_RUN);
    right.set(shapeId(succV, s), KIND_PAIR_RUN);
    for (let ss = 0; ss < 4; ss++) {
      if (RED.has(ss) !== onlyRed) {
        left.set(shapeId(predV, ss), KIND_PAIR_RB);
        right.set(shapeId(succV, ss), KIND_PAIR_RB);
      }
    }
    const setMap = /* @__PURE__ */ new Map();
    for (let ss = 0; ss < 4; ss++) {
      if (ss !== s) setMap.set(shapeId(v, ss), KIND_PAIR_SET);
    }
    return [left, right, setMap];
  }
  function extendsTables(target) {
    const cards = target.cards;
    const kind = target.kind;
    const n = target.n;
    if (kind === KIND_SINGLETON) {
      return extendsForSingleton(cards[0]);
    }
    const family = familyOfKind(kind);
    const nNew = n + 1;
    const resultKind = nNew >= 3 ? family : pairOf(family);
    if (family === KIND_RUN) {
      const last = cards[cards.length - 1];
      const first = cards[0];
      const succV = last[0] === 13 ? 1 : last[0] + 1;
      const predV = first[0] === 1 ? 13 : first[0] - 1;
      const left = /* @__PURE__ */ new Map([[shapeId(predV, first[1]), resultKind]]);
      const right = /* @__PURE__ */ new Map([[shapeId(succV, last[1]), resultKind]]);
      return [left, right, /* @__PURE__ */ new Map()];
    }
    if (family === KIND_RB) {
      const last = cards[cards.length - 1];
      const first = cards[0];
      const succV = last[0] === 13 ? 1 : last[0] + 1;
      const predV = first[0] === 1 ? 13 : first[0] - 1;
      const lastRed = RED.has(last[1]);
      const firstRed = RED.has(first[1]);
      const left = /* @__PURE__ */ new Map();
      const right = /* @__PURE__ */ new Map();
      for (let s = 0; s < 4; s++) {
        if (RED.has(s) !== firstRed) left.set(shapeId(predV, s), resultKind);
        if (RED.has(s) !== lastRed) right.set(shapeId(succV, s), resultKind);
      }
      return [left, right, /* @__PURE__ */ new Map()];
    }
    if (nNew > 4) {
      return [/* @__PURE__ */ new Map(), /* @__PURE__ */ new Map(), /* @__PURE__ */ new Map()];
    }
    const setValue = cards[0][0];
    const usedSuits = /* @__PURE__ */ new Set();
    for (const c of cards) usedSuits.add(c[1]);
    const setMap = /* @__PURE__ */ new Map();
    for (let s = 0; s < 4; s++) {
      if (!usedSuits.has(s)) setMap.set(shapeId(setValue, s), resultKind);
    }
    return [/* @__PURE__ */ new Map(), /* @__PURE__ */ new Map(), setMap];
  }
  function kindAfterAbsorbLeft(target, card) {
    const targetKind = target.kind;
    const nNew = target.n + 1;
    if (targetKind === KIND_SINGLETON) {
      const only = target.cards[0];
      const family2 = familyForTwoCards(card, only);
      if (family2 === null) return null;
      return pairOf(family2);
    }
    const family = familyOfKind(targetKind);
    const av = card[0], asu = card[1];
    const first = target.cards[0];
    const bv = first[0], bsu = first[1];
    if (family === KIND_RUN) {
      if (asu !== bsu || (av === 13 ? 1 : av + 1) !== bv) return null;
    } else if (family === KIND_RB) {
      if ((av === 13 ? 1 : av + 1) !== bv) return null;
      if (RED.has(asu) === RED.has(bsu)) return null;
    } else {
      if (av !== bv || asu === bsu) return null;
      if (nNew > 4) return null;
      for (const c of target.cards) {
        if (c[1] === asu) return null;
      }
    }
    if (nNew >= 3) return family;
    return pairOf(family);
  }
  function singletonStack(card) {
    return { cards: [card], kind: KIND_SINGLETON, n: 1 };
  }
  function runKindForLength(family, n) {
    if (n >= 3) return family;
    if (n === 2) return pairOf(family);
    if (n === 1) return KIND_SINGLETON;
    throw new Error("zero-length run slice is not a valid stack");
  }
  function setKindForLength(n) {
    if (n >= 3) return KIND_SET;
    if (n === 2) return KIND_PAIR_SET;
    if (n === 1) return KIND_SINGLETON;
    throw new Error("zero-length set slice is not a valid stack");
  }
  function canPeel(stack, i) {
    const n = stack.n;
    if (stack.kind === KIND_SET && n >= 4) return true;
    if ((stack.kind === KIND_RUN || stack.kind === KIND_RB) && n >= 4 && (i === 0 || i === n - 1)) {
      return true;
    }
    return false;
  }
  function canSetPeel(stack, i) {
    return stack.kind === KIND_SET && stack.n === 3 && i >= 0 && i < 3;
  }
  function canPluck(stack, i) {
    if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) return false;
    return 3 <= i && i <= stack.n - 4;
  }
  function canYank(stack, i) {
    if (stack.kind !== KIND_RUN && stack.kind !== KIND_RB) return false;
    const n = stack.n;
    if (i === 0 || i === n - 1 || 3 <= i && i <= n - 4) return false;
    const leftLen = i;
    const rightLen = n - i - 1;
    return Math.max(leftLen, rightLen) >= 3 && Math.min(leftLen, rightLen) >= 1;
  }
  function canSteal(stack, i) {
    if (stack.n === 3) {
      if (stack.kind === KIND_RUN || stack.kind === KIND_RB) {
        return i === 0 || i === 2;
      }
      return stack.kind === KIND_SET;
    }
    if (stack.n === 2) {
      return stack.kind === KIND_PAIR_RUN || stack.kind === KIND_PAIR_RB || stack.kind === KIND_PAIR_SET;
    }
    return false;
  }
  function canSplitOut(stack, i) {
    return (stack.kind === KIND_RUN || stack.kind === KIND_RB) && stack.n === 3 && i === 1;
  }
  function peel(stack, i) {
    if (!canPeel(stack, i)) {
      throw new Error(`canPeel(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    const extracted = singletonStack(stack.cards[i]);
    if (stack.kind === KIND_SET) {
      const rest2 = stack.cards.slice(0, i).concat(stack.cards.slice(i + 1));
      return [extracted, { cards: rest2, kind: setKindForLength(rest2.length), n: rest2.length }];
    }
    const family = stack.kind;
    const rest = i === 0 ? stack.cards.slice(1) : stack.cards.slice(0, -1);
    return [extracted, { cards: rest, kind: runKindForLength(family, rest.length), n: rest.length }];
  }
  function setPeel(stack, i) {
    if (!canSetPeel(stack, i)) {
      throw new Error(`canSetPeel(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    const extracted = singletonStack(stack.cards[i]);
    const rest = stack.cards.slice(0, i).concat(stack.cards.slice(i + 1));
    return [extracted, { cards: rest, kind: KIND_PAIR_SET, n: 2 }];
  }
  function pluck(stack, i) {
    if (!canPluck(stack, i)) {
      throw new Error(`canPluck(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    const family = stack.kind;
    const extracted = singletonStack(stack.cards[i]);
    const leftCards = stack.cards.slice(0, i);
    const rightCards = stack.cards.slice(i + 1);
    return [
      extracted,
      { cards: leftCards, kind: family, n: leftCards.length },
      { cards: rightCards, kind: family, n: rightCards.length }
    ];
  }
  function yank(stack, i) {
    if (!canYank(stack, i)) {
      throw new Error(`canYank(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    const family = stack.kind;
    const extracted = singletonStack(stack.cards[i]);
    const leftCards = stack.cards.slice(0, i);
    const rightCards = stack.cards.slice(i + 1);
    return [
      extracted,
      { cards: leftCards, kind: runKindForLength(family, leftCards.length), n: leftCards.length },
      { cards: rightCards, kind: runKindForLength(family, rightCards.length), n: rightCards.length }
    ];
  }
  function steal(stack, i) {
    if (!canSteal(stack, i)) {
      throw new Error(`canSteal(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    const extracted = singletonStack(stack.cards[i]);
    if (stack.n === 2) {
      const otherIdx = i === 0 ? 1 : 0;
      return [extracted, singletonStack(stack.cards[otherIdx])];
    }
    if (stack.kind === KIND_SET) {
      const others = [];
      for (let j = 0; j < stack.cards.length; j++) {
        if (j !== i) others.push(singletonStack(stack.cards[j]));
      }
      return [extracted, ...others];
    }
    const family = stack.kind;
    const rest = i === 0 ? stack.cards.slice(1) : stack.cards.slice(0, -1);
    return [extracted, { cards: rest, kind: pairOf(family), n: rest.length }];
  }
  function splitOut(stack, i) {
    if (!canSplitOut(stack, i)) {
      throw new Error(`canSplitOut(${stack.kind} len=${stack.n}, ${i}) is False`);
    }
    return [
      singletonStack(stack.cards[1]),
      singletonStack(stack.cards[0]),
      singletonStack(stack.cards[2])
    ];
  }
  function findSpliceCandidates(parent, card) {
    if (parent.kind !== KIND_RUN && parent.kind !== KIND_RB) {
      throw new Error(
        `findSpliceCandidates requires run or rb parent, got ${parent.kind}`
      );
    }
    const n = parent.n;
    if (n < 5) return [];
    const cards = parent.cards;
    const cv = card[0];
    const cs = card[1];
    const family = parent.kind;
    const cRed = RED.has(cs);
    const out = [];
    for (let m = 2; m <= n - 3; m++) {
      const pm = cards[m];
      if (pm[0] !== cv) continue;
      if (family === KIND_RB) {
        if (RED.has(pm[1]) !== cRed) continue;
      } else {
        if (pm[1] !== cs) continue;
      }
      out.push({ side: "left", position: m, leftKind: family, rightKind: family });
      out.push({ side: "right", position: m + 1, leftKind: family, rightKind: family });
    }
    return out;
  }

  // games/lynrummy/ts/src/buckets.ts
  var CARD_PAD = 4;
  function encodeCard(c) {
    const id = (c[0] * 4 + c[1]) * 2 + c[2];
    return id.toString().padStart(CARD_PAD, "0");
  }
  function encodeStackCards(cards) {
    const ids = cards.map(encodeCard);
    ids.sort();
    return ids.join(",");
  }
  function encodeBucket(stacks) {
    const stackStrs = stacks.map((s) => encodeStackCards(s.cards));
    stackStrs.sort();
    return stackStrs.join(";");
  }
  function encodeLineage(lineage) {
    return lineage.map((entry) => entry.map(encodeCard).join(",")).join("~");
  }
  function buildCardOrder(initial) {
    const cardId2 = (c) => (c[0] - 1) * 8 + c[1] * 2 + c[2];
    const cardOrder = [];
    const seen = /* @__PURE__ */ new Set();
    const collect = (stacks) => {
      for (const stack of stacks) for (const c of stack.cards) {
        const id = cardId2(c);
        if (!seen.has(id)) {
          seen.add(id);
          cardOrder.push(id);
        }
      }
    };
    collect(initial.helper);
    collect(initial.trouble);
    collect(initial.growing);
    collect(initial.complete);
    const posOf = new Uint8Array(104);
    posOf.fill(255);
    for (let i = 0; i < cardOrder.length; i++) {
      posOf[cardOrder[i]] = i;
    }
    return { cardOrder, posOf };
  }
  function fastStateSig(b, lineage, posOf, N) {
    const buf = new Uint8Array(N);
    const cardId2 = (c) => (c[0] - 1) * 8 + c[1] * 2 + c[2];
    const writeBucket = (stacks, bucketId) => {
      for (const stack of stacks) {
        const positions = [];
        for (const c of stack.cards) positions.push(posOf[cardId2(c)]);
        positions.sort((a, b2) => a - b2);
        for (let i = 0; i < positions.length; i++) {
          const pos = positions[i];
          const right = i + 1 < positions.length ? positions[i + 1] : 127;
          buf[pos] = bucketId << 7 | right;
        }
      }
    };
    const buf2 = new Uint8Array(2 * N);
    const writeBucket2 = (stacks, bucketId) => {
      for (const stack of stacks) {
        const positions = [];
        for (const c of stack.cards) positions.push(posOf[cardId2(c)]);
        positions.sort((a, b2) => a - b2);
        for (let i = 0; i < positions.length; i++) {
          const pos = positions[i];
          buf2[2 * pos] = bucketId;
          buf2[2 * pos + 1] = i + 1 < positions.length ? positions[i + 1] : 255;
        }
      }
    };
    writeBucket2(b.helper, 0);
    writeBucket2(b.trouble, 1);
    writeBucket2(b.growing, 2);
    writeBucket2(b.complete, 3);
    let result = String.fromCharCode.apply(null, buf2);
    if (lineage !== void 0 && lineage.length > 0) {
      const lbuf = new Uint8Array(lineage.length);
      for (let i = 0; i < lineage.length; i++) {
        lbuf[i] = posOf[cardId2(lineage[i][0])];
      }
      result += "@" + String.fromCharCode.apply(null, lbuf);
    }
    return result;
    void buf;
    void writeBucket;
  }
  function stateSig(b, lineage, uncommittedPairs) {
    const h = encodeBucket(b.helper);
    const t = encodeBucket(b.trouble);
    const g = encodeBucket(b.growing);
    const c = encodeBucket(b.complete);
    const base = `${h}|${t}|${g}|${c}`;
    let withLineage = base;
    if (lineage !== void 0) withLineage = `${base}@${encodeLineage(lineage)}`;
    if (uncommittedPairs === void 0 || uncommittedPairs.size === 0) return withLineage;
    const sortedKeys = [...uncommittedPairs].sort();
    return `${withLineage}#${sortedKeys.join(",")}`;
  }
  function troubleCount(trouble, growing) {
    let n = 0;
    for (const s of trouble) n += s.n;
    for (const s of growing) n += s.n;
    return n;
  }
  function isVictory(trouble, growing) {
    if (trouble.length > 0) return false;
    for (const g of growing) {
      if (g.n < 3) return false;
    }
    return true;
  }
  function classifyBucket(stacks, bucketName) {
    const out = [];
    for (let i = 0; i < stacks.length; i++) {
      const ccs = classifyStack(stacks[i]);
      if (ccs === null) {
        throw new Error(
          `invalid stack in ${bucketName}[${i}]: ${JSON.stringify(stacks[i])} did not classify as run/rb/set/pair_*/singleton`
        );
      }
      out.push(ccs);
    }
    return out;
  }
  function classifyBuckets(buckets) {
    return {
      helper: classifyBucket(buckets.helper, "helper"),
      trouble: classifyBucket(buckets.trouble, "trouble"),
      growing: classifyBucket(buckets.growing, "growing"),
      complete: classifyBucket(buckets.complete, "complete")
    };
  }

  // games/lynrummy/ts/src/move.ts
  function stackLabel(stack) {
    return stack.map(cardLabel).join(" ");
  }
  function describe(desc) {
    switch (desc.type) {
      case "free_pull": {
        const graduated = desc.graduated ? " [\u2192COMPLETE]" : "";
        return `pull ${cardLabel(desc.loose)} onto ${desc.targetBucketBefore} [${stackLabel(desc.targetBefore)}] \u2192 [${stackLabel(desc.result)}]${graduated}`;
      }
      case "extract_absorb": {
        let spawnedStr = "";
        if (desc.spawned.length > 0) {
          spawnedStr += " ; spawn TROUBLE: " + desc.spawned.map((s) => "[" + stackLabel(s) + "]").join(", ");
        }
        if (desc.spawnedGrowing.length > 0) {
          spawnedStr += " ; spawn GROWING: " + desc.spawnedGrowing.map((s) => "[" + stackLabel(s) + "]").join(", ");
        }
        const graduated = desc.graduated ? " [\u2192COMPLETE]" : "";
        return `${desc.verb} ${cardLabel(desc.extCard)} from HELPER [${stackLabel(desc.source)}], absorb onto ${desc.targetBucketBefore} [${stackLabel(desc.targetBefore)}] \u2192 [${stackLabel(desc.result)}]${graduated}${spawnedStr}`;
      }
      case "shift": {
        const p = cardLabel(desc.pCard);
        let pIdx = -1;
        for (let i = 0; i < desc.newSource.length; i++) {
          const c = desc.newSource[i];
          if (c[0] === desc.pCard[0] && c[1] === desc.pCard[1] && c[2] === desc.pCard[2]) {
            pIdx = i;
            break;
          }
        }
        const rest = [];
        for (const c of desc.newSource) {
          if (!(c[0] === desc.pCard[0] && c[1] === desc.pCard[1] && c[2] === desc.pCard[2])) {
            rest.push(c);
          }
        }
        const restLabel = rest.map(cardLabel).join(" ");
        const shifted = pIdx === 0 ? `${p} + ${restLabel}` : `${restLabel} + ${p}`;
        const graduated = desc.graduated ? " [\u2192COMPLETE]" : "";
        return `shift ${p} to pop ${cardLabel(desc.stolen)} [${stackLabel(desc.newDonor)} -> ${shifted}]; absorb onto ${desc.targetBucketBefore} [${stackLabel(desc.targetBefore)}] \u2192 [${stackLabel(desc.merged)}]${graduated}`;
      }
      case "splice": {
        return `splice [${cardLabel(desc.loose)}] into HELPER [${stackLabel(desc.source)}] \u2192 [${stackLabel(desc.leftResult)}] + [${stackLabel(desc.rightResult)}]`;
      }
      case "push": {
        return `push TROUBLE [${stackLabel(desc.troubleBefore)}] onto HELPER [${stackLabel(desc.targetBefore)}] \u2192 [${stackLabel(desc.result)}]`;
      }
      case "decompose": {
        return `decompose TROUBLE [${stackLabel(desc.pairBefore)}] \u2192 [${cardLabel(desc.leftCard)}] + [${cardLabel(desc.rightCard)}]`;
      }
    }
  }

  // games/lynrummy/ts/src/enumerator.ts
  var LEGAL_LEN3_KINDS = /* @__PURE__ */ new Set([KIND_RUN, KIND_RB, KIND_SET]);
  var RUN_FAMILY_KINDS = /* @__PURE__ */ new Set([KIND_RUN, KIND_RB]);
  function dropAt(stacks, idx) {
    return stacks.slice(0, idx).concat(stacks.slice(idx + 1));
  }
  function removeAbsorber(bucketName, idx, trouble, growing) {
    if (bucketName === "trouble") {
      return [dropAt(trouble, idx), [...growing]];
    }
    return [[...trouble], dropAt(growing, idx)];
  }
  function graduate(merged, growing, complete) {
    if (LEGAL_LEN3_KINDS.has(merged.kind)) {
      return [[...growing], [...complete, merged], true];
    }
    return [[...growing, merged], [...complete], false];
  }
  function completionInventory(helper, trouble) {
    const inv = /* @__PURE__ */ new Set();
    for (const stack of helper) {
      for (const c of stack.cards) {
        inv.add(c[0] * 4 + c[1]);
      }
    }
    for (const stack of trouble) {
      if (stack.n === 1) {
        const c = stack.cards[0];
        inv.add(c[0] * 4 + c[1]);
      }
    }
    return inv;
  }
  function completionShapes(partial) {
    const c1 = partial[0];
    const c2 = partial[1];
    const v1 = c1[0], s1 = c1[1];
    const v2 = c2[0], s2 = c2[1];
    const out = /* @__PURE__ */ new Set();
    if (v1 === v2) {
      for (let s = 0; s < 4; s++) {
        if (s !== s1 && s !== s2) out.add(v1 * 4 + s);
      }
      return out;
    }
    const predV = v1 === 1 ? 13 : v1 - 1;
    const succV = v2 === 13 ? 1 : v2 + 1;
    if (s1 === s2) {
      out.add(predV * 4 + s1);
      out.add(succV * 4 + s2);
      return out;
    }
    const s1red = RED.has(s1);
    const s2red = RED.has(s2);
    for (let s = 0; s < 4; s++) {
      if (RED.has(s) !== s1red) out.add(predV * 4 + s);
      if (RED.has(s) !== s2red) out.add(succV * 4 + s);
    }
    return out;
  }
  function hasDoomedThird(partial, inventory) {
    const shapes = completionShapes(partial);
    for (const s of shapes) {
      if (inventory.has(s)) return false;
    }
    return true;
  }
  function admissibleMerged(merged, completionInv) {
    if (merged.n === 2 && hasDoomedThird(merged.cards, completionInv)) {
      return false;
    }
    return true;
  }
  function doExtract(helper, srcIdx, ci, verb) {
    const source = helper[srcIdx];
    const sourceBeforeCards = [...source.cards];
    const { helpers: helperPieces, troubleSpawned, growingSpawned } = extractPieces(source, ci, verb);
    const newHelper = helper.slice(0, srcIdx).concat(helper.slice(srcIdx + 1)).concat(helperPieces);
    return {
      newHelper,
      spawned: troubleSpawned,
      spawnedGrowing: growingSpawned,
      extCard: source.cards[ci],
      sourceBeforeCards
    };
  }
  function extractPieces(source, ci, verb) {
    if (verb === "peel") {
      const [, remnant] = peel(source, ci);
      return { helpers: [remnant], troubleSpawned: [], growingSpawned: [] };
    }
    if (verb === "set_peel") {
      const [, remnant] = setPeel(source, ci);
      return { helpers: [], troubleSpawned: [], growingSpawned: [remnant] };
    }
    if (verb === "pluck") {
      const [, left, right] = pluck(source, ci);
      return { helpers: [left, right], troubleSpawned: [], growingSpawned: [] };
    }
    if (verb === "yank") {
      const [, left, right] = yank(source, ci);
      const helpers = [];
      const troubleSpawned = [];
      const growingSpawned = [];
      for (const piece of [left, right]) {
        if (piece.n >= 3) {
          helpers.push(piece);
        } else if (piece.n === 2) {
          growingSpawned.push(piece);
        } else {
          troubleSpawned.push(piece);
        }
      }
      return { helpers, troubleSpawned, growingSpawned };
    }
    if (verb === "split_out") {
      const [, left, right] = splitOut(source, ci);
      return { helpers: [], troubleSpawned: [left, right], growingSpawned: [] };
    }
    if (verb === "steal") {
      const pieces = steal(source, ci);
      return {
        helpers: [],
        troubleSpawned: pieces.slice(1),
        growingSpawned: []
      };
    }
    throw new Error(`unknown verb ${verb}`);
  }
  function extractableIndex(helper) {
    const out = /* @__PURE__ */ new Map();
    const add = (cards, ci, hi, verb) => {
      const c = cards[ci];
      const key = c[0] * 4 + c[1];
      let arr = out.get(key);
      if (!arr) {
        arr = [];
        out.set(key, arr);
      }
      arr.push({ hi, ci, verb });
    };
    for (let hi = 0; hi < helper.length; hi++) {
      const src = helper[hi];
      const kind = src.kind;
      const n = src.n;
      const cards = src.cards;
      if (kind === KIND_RUN || kind === KIND_RB) {
        if (n === 3) {
          add(cards, 0, hi, "steal");
          add(cards, 1, hi, "split_out");
          add(cards, 2, hi, "steal");
        } else {
          const last = n - 1;
          add(cards, 0, hi, "peel");
          add(cards, last, hi, "peel");
          for (let ci = 1; ci < last; ci++) {
            let verb = null;
            if (3 <= ci && ci <= n - 4) {
              verb = "pluck";
            } else if (Math.max(ci, n - ci - 1) >= 3 && Math.min(ci, n - ci - 1) >= 1) {
              verb = "yank";
            }
            if (verb !== null) add(cards, ci, hi, verb);
          }
        }
      } else if (kind === KIND_SET) {
        if (n >= 4) {
          for (let ci = 0; ci < n; ci++) add(cards, ci, hi, "peel");
        } else if (n === 3) {
          for (let ci = 0; ci < n; ci++) {
            add(cards, ci, hi, "steal");
            add(cards, ci, hi, "set_peel");
          }
        }
      }
    }
    return out;
  }
  function absorbSeqRight(target, cardsToAdd) {
    let current = target;
    for (const c of cardsToAdd) {
      const newKind = kindAfterAbsorbRight(current, c);
      if (newKind === null) return null;
      current = { cards: [...current.cards, c], kind: newKind, n: current.n + 1 };
    }
    return current;
  }
  function absorbSeqLeft(target, cardsToAdd) {
    let current = target;
    for (let i = cardsToAdd.length - 1; i >= 0; i--) {
      const c = cardsToAdd[i];
      const newKind = kindAfterAbsorbLeft(current, c);
      if (newKind === null) return null;
      current = { cards: [c, ...current.cards], kind: newKind, n: current.n + 1 };
    }
    return current;
  }
  function buildAbsorberShapes(trouble, growing) {
    const out = [];
    for (let ti = 0; ti < trouble.length; ti++) {
      const t = trouble[ti];
      const [leftExt, rightExt, setExt] = extendsTables(t);
      out.push({ bucket: "trouble", idx: ti, target: t, leftExt, rightExt, setExt });
    }
    for (let gi = 0; gi < growing.length; gi++) {
      const g = growing[gi];
      const [leftExt, rightExt, setExt] = extendsTables(g);
      out.push({ bucket: "growing", idx: gi, target: g, leftExt, rightExt, setExt });
    }
    return out;
  }
  function eligibleSpliceHelpers(helper) {
    const out = [];
    for (let hi = 0; hi < helper.length; hi++) {
      const h = helper[hi];
      if (h.n >= 4 && RUN_FAMILY_KINDS.has(h.kind)) {
        out.push({ hi, stack: h });
      }
    }
    return out;
  }
  function eligibleShiftHelpers(helper) {
    const out = [];
    for (let hi = 0; hi < helper.length; hi++) {
      const h = helper[hi];
      if (h.n === 3 && RUN_FAMILY_KINDS.has(h.kind)) {
        out.push({ hi, stack: h });
      }
    }
    return out;
  }
  function* enumerateMoves(state) {
    const { helper, trouble, growing, complete } = state;
    const completionInv = completionInventory(helper, trouble);
    if (stateHasDoomedGrowing(growing, completionInv)) {
      return;
    }
    if (stateHasDoomedSingleton(trouble, completionInv)) {
      return;
    }
    const extractable = extractableIndex(helper);
    const spliceHelpers = eligibleSpliceHelpers(helper);
    const shiftHelpers = eligibleShiftHelpers(helper);
    const absorberShapes = buildAbsorberShapes(trouble, growing);
    for (const absorber of absorberShapes) {
      yield* yieldExtractAbsorbs(
        absorber,
        helper,
        trouble,
        growing,
        complete,
        extractable,
        completionInv
      );
      yield* yieldFreePulls(
        absorber,
        helper,
        trouble,
        growing,
        complete,
        completionInv
      );
      yield* yieldPartialSteals(
        absorber,
        helper,
        trouble,
        growing,
        complete,
        completionInv
      );
    }
    yield* yieldShifts(
      absorberShapes,
      helper,
      trouble,
      growing,
      complete,
      shiftHelpers,
      extractable,
      completionInv
    );
    yield* yieldSplices(helper, trouble, growing, complete, spliceHelpers);
    yield* yieldPushes(helper, trouble, growing, complete);
    yield* yieldEngulfs(helper, trouble, growing, complete);
    yield* yieldDecomposes(helper, trouble, growing, complete);
  }
  function stateHasDoomedGrowing(growing, completionInv) {
    for (const g of growing) {
      if (g.n === 2) {
        const shapes = completionShapes(g.cards);
        let alive = false;
        for (const s of shapes) {
          if (completionInv.has(s)) {
            alive = true;
            break;
          }
        }
        if (!alive) return true;
      }
    }
    return false;
  }
  var SINGLETON_DOOM_MODE = "off";
  function singletonPartnerShapes(c) {
    const v = c[0], s = c[1];
    const predV = v === 1 ? 13 : v - 1;
    const succV = v === 13 ? 1 : v + 1;
    const cRed = RED.has(s);
    const out = [];
    out.push(predV * 4 + s);
    out.push(succV * 4 + s);
    for (let s2 = 0; s2 < 4; s2++) {
      if (s2 === s) continue;
      if (RED.has(s2) === cRed) continue;
      out.push(predV * 4 + s2);
      out.push(succV * 4 + s2);
    }
    for (let s2 = 0; s2 < 4; s2++) {
      if (s2 === s) continue;
      out.push(v * 4 + s2);
    }
    return out;
  }
  function completionShapesForHypotheticalPair(c, partnerShape) {
    const cv = c[0], cs = c[1];
    const pv = Math.floor(partnerShape / 4);
    const ps = partnerShape % 4;
    const out = /* @__PURE__ */ new Set();
    if (cv === pv) {
      for (let s = 0; s < 4; s++) {
        if (s !== cs && s !== ps) out.add(cv * 4 + s);
      }
      return out;
    }
    const lowV = cv < pv ? cv : pv;
    const highV = cv < pv ? pv : cv;
    const lowS = cv < pv ? cs : ps;
    const highS = cv < pv ? ps : cs;
    if (cs === ps) {
      const predV2 = lowV === 1 ? 13 : lowV - 1;
      const succV2 = highV === 13 ? 1 : highV + 1;
      out.add(predV2 * 4 + lowS);
      out.add(succV2 * 4 + highS);
      return out;
    }
    const predV = lowV === 1 ? 13 : lowV - 1;
    const succV = highV === 13 ? 1 : highV + 1;
    const lowRed = RED.has(lowS);
    const highRed = RED.has(highS);
    for (let s = 0; s < 4; s++) {
      if (RED.has(s) !== lowRed) out.add(predV * 4 + s);
      if (RED.has(s) !== highRed) out.add(succV * 4 + s);
    }
    return out;
  }
  function singletonHasNoPartner(c, completionInv) {
    const partners = singletonPartnerShapes(c);
    for (const p of partners) {
      if (completionInv.has(p)) return false;
    }
    return true;
  }
  function singletonAllPairsDoomed(c, completionInv) {
    const partners = singletonPartnerShapes(c);
    let foundAnyPartner = false;
    for (const p of partners) {
      if (!completionInv.has(p)) continue;
      foundAnyPartner = true;
      const extenders = completionShapesForHypotheticalPair(c, p);
      for (const e of extenders) {
        if (completionInv.has(e)) return false;
      }
    }
    return foundAnyPartner ? true : true;
  }
  function stateHasDoomedSingleton(trouble, completionInv) {
    if (SINGLETON_DOOM_MODE === "off") return false;
    for (const stack of trouble) {
      if (stack.n !== 1) continue;
      const c = stack.cards[0];
      if (SINGLETON_DOOM_MODE === "low") {
        if (singletonHasNoPartner(c, completionInv)) return true;
      } else if (SINGLETON_DOOM_MODE === "high") {
        if (singletonAllPairsDoomed(c, completionInv)) return true;
      }
    }
    return false;
  }
  function* yieldExtractAbsorbs(absorber, helper, trouble, growing, complete, extractable, completionInv) {
    const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
    const targetCardsList = [...target.cards];
    let ntBase = null;
    let ng = null;
    const shapeUnion = /* @__PURE__ */ new Set();
    for (const k of leftExt.keys()) shapeUnion.add(k);
    for (const k of rightExt.keys()) shapeUnion.add(k);
    for (const k of setExt.keys()) shapeUnion.add(k);
    const sortedShapes = [...shapeUnion].sort((a, b) => a - b);
    for (const shape of sortedShapes) {
      const rightKind = rightExt.get(shape) ?? null;
      const leftKind = leftExt.get(shape) ?? null;
      const setKind = setExt.get(shape) ?? null;
      const entries = extractable.get(shape) ?? [];
      for (const { hi, ci, verb } of entries) {
        const extCard = helper[hi].cards[ci];
        const { newHelper, spawned, spawnedGrowing, sourceBeforeCards } = doExtract(helper, hi, ci, verb);
        const spawnedLists = spawned.map((s) => [...s.cards]);
        const spawnedGrowingLists = spawnedGrowing.map((s) => [...s.cards]);
        if (ntBase === null) {
          const [nt2, gg] = removeAbsorber(bucket, idx, trouble, growing);
          ntBase = nt2;
          ng = gg;
        }
        const nt = [...ntBase, ...spawned];
        const ngWithSpawn = [...ng, ...spawnedGrowing];
        if (rightKind !== null) {
          const merged = absorbRight(target, extCard, rightKind);
          if (admissibleMerged(merged, completionInv)) {
            const [ngFinal, nc, graduated] = graduate(merged, ngWithSpawn, complete);
            const desc = {
              type: "extract_absorb",
              verb,
              source: sourceBeforeCards,
              extCard,
              targetBefore: targetCardsList,
              targetBucketBefore: bucket,
              result: [...merged.cards],
              side: "right",
              graduated,
              spawned: spawnedLists,
              spawnedGrowing: spawnedGrowingLists
            };
            yield [desc, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
          }
        }
        if (leftKind !== null) {
          const merged = absorbLeft(target, extCard, leftKind);
          if (admissibleMerged(merged, completionInv)) {
            const [ngFinal, nc, graduated] = graduate(merged, ngWithSpawn, complete);
            const desc = {
              type: "extract_absorb",
              verb,
              source: sourceBeforeCards,
              extCard,
              targetBefore: targetCardsList,
              targetBucketBefore: bucket,
              result: [...merged.cards],
              side: "left",
              graduated,
              spawned: spawnedLists,
              spawnedGrowing: spawnedGrowingLists
            };
            yield [desc, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
          }
        }
        if (setKind !== null) {
          const mergedR = absorbRight(target, extCard, setKind);
          if (admissibleMerged(mergedR, completionInv)) {
            const [ngFinal, nc, graduated] = graduate(mergedR, ngWithSpawn, complete);
            const desc = {
              type: "extract_absorb",
              verb,
              source: sourceBeforeCards,
              extCard,
              targetBefore: targetCardsList,
              targetBucketBefore: bucket,
              result: [...mergedR.cards],
              side: "right",
              graduated,
              spawned: spawnedLists,
              spawnedGrowing: spawnedGrowingLists
            };
            yield [desc, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
          }
          const mergedL = absorbLeft(target, extCard, setKind);
          if (admissibleMerged(mergedL, completionInv)) {
            const [ngFinal, nc, graduated] = graduate(mergedL, ngWithSpawn, complete);
            const desc = {
              type: "extract_absorb",
              verb,
              source: sourceBeforeCards,
              extCard,
              targetBefore: targetCardsList,
              targetBucketBefore: bucket,
              result: [...mergedL.cards],
              side: "left",
              graduated,
              spawned: spawnedLists,
              spawnedGrowing: spawnedGrowingLists
            };
            yield [desc, { helper: newHelper, trouble: nt, growing: ngFinal, complete: nc }];
          }
        }
      }
    }
  }
  function* yieldPartialSteals(absorber, helper, trouble, growing, complete, completionInv) {
    const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
    const targetCardsList = [...target.cards];
    for (let pi = 0; pi < trouble.length; pi++) {
      const partial = trouble[pi];
      if (partial.n !== 2) continue;
      if (bucket === "trouble" && idx === pi) continue;
      for (let ci = 0; ci < 2; ci++) {
        const extCard = partial.cards[ci];
        const otherCard = partial.cards[1 - ci];
        const leftover = {
          cards: [otherCard],
          kind: "singleton",
          n: 1
        };
        const shape = extCard[0] * 4 + extCard[1];
        const rightKind = rightExt.get(shape) ?? null;
        const leftKind = leftExt.get(shape) ?? null;
        const setKind = setExt.get(shape) ?? null;
        if (rightKind === null && leftKind === null && setKind === null) continue;
        const baseTrouble = [];
        let droppedAbsorber = false;
        let droppedSource = false;
        for (let k = 0; k < trouble.length; k++) {
          if (bucket === "trouble" && idx === k) {
            droppedAbsorber = true;
            continue;
          }
          if (k === pi) {
            droppedSource = true;
            continue;
          }
          baseTrouble.push(trouble[k]);
        }
        void droppedAbsorber;
        void droppedSource;
        baseTrouble.push(leftover);
        const ng = bucket === "growing" ? trouble.length === 0 ? [...growing.slice(0, idx), ...growing.slice(idx + 1)] : [...growing.slice(0, idx), ...growing.slice(idx + 1)] : [...growing];
        const yieldMerge = (merged, side) => {
          if (!admissibleMerged(merged, completionInv)) return;
          const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
          const desc = {
            type: "extract_absorb",
            verb: "steal",
            source: [...partial.cards],
            extCard,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...merged.cards],
            side,
            graduated,
            spawned: [[otherCard]],
            spawnedGrowing: []
          };
          return [desc, { helper: [...helper], trouble: baseTrouble, growing: ngFinal, complete: nc }];
        };
        if (rightKind !== null) {
          const m = absorbRight(target, extCard, rightKind);
          const result = yieldMerge(m, "right");
          if (result) yield result;
        }
        if (leftKind !== null) {
          const m = absorbLeft(target, extCard, leftKind);
          const result = yieldMerge(m, "left");
          if (result) yield result;
        }
        if (setKind !== null) {
          const mR = absorbRight(target, extCard, setKind);
          const r1 = yieldMerge(mR, "right");
          if (r1) yield r1;
          const mL = absorbLeft(target, extCard, setKind);
          const r2 = yieldMerge(mL, "left");
          if (r2) yield r2;
        }
      }
    }
  }
  function* yieldFreePulls(absorber, helper, trouble, growing, complete, completionInv) {
    const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
    const targetCardsList = [...target.cards];
    for (let li = 0; li < trouble.length; li++) {
      const looseStack = trouble[li];
      if (looseStack.n !== 1) continue;
      if (bucket === "trouble" && li === idx) continue;
      const loose = looseStack.cards[0];
      const shapeKey = loose[0] * 4 + loose[1];
      const leftKind = leftExt.get(shapeKey) ?? null;
      const rightKind = rightExt.get(shapeKey) ?? null;
      const setKind = setExt.get(shapeKey) ?? null;
      if (leftKind === null && rightKind === null && setKind === null) continue;
      const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
      let nt;
      if (bucket === "trouble") {
        const liInBase = li > idx ? li - 1 : li;
        nt = dropAt(ntBase, liInBase);
      } else {
        nt = dropAt(ntBase, li);
      }
      if (rightKind !== null) {
        const merged = absorbRight(target, loose, rightKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
          const desc = {
            type: "free_pull",
            loose,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...merged.cards],
            side: "right",
            graduated
          };
          yield [desc, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
      if (leftKind !== null) {
        const merged = absorbLeft(target, loose, leftKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
          const desc = {
            type: "free_pull",
            loose,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...merged.cards],
            side: "left",
            graduated
          };
          yield [desc, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
      if (setKind !== null) {
        const mergedR = absorbRight(target, loose, setKind);
        if (admissibleMerged(mergedR, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(mergedR, ng, complete);
          const desc = {
            type: "free_pull",
            loose,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...mergedR.cards],
            side: "right",
            graduated
          };
          yield [desc, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
        }
        const mergedL = absorbLeft(target, loose, setKind);
        if (admissibleMerged(mergedL, completionInv)) {
          const [ngFinal, nc, graduated] = graduate(mergedL, ng, complete);
          const desc = {
            type: "free_pull",
            loose,
            targetBefore: targetCardsList,
            targetBucketBefore: bucket,
            result: [...mergedL.cards],
            side: "left",
            graduated
          };
          yield [desc, { helper: [...helper], trouble: nt, growing: ngFinal, complete: nc }];
        }
      }
    }
  }
  function* yieldShifts(absorberShapes, helper, trouble, growing, complete, shiftHelpers, extractable, completionInv) {
    for (const absorber of absorberShapes) {
      for (const { hi: srcIdx, stack: source } of shiftHelpers) {
        for (const whichEnd of [0, 2]) {
          yield* yieldShiftsForEndpoint(
            absorber,
            helper,
            trouble,
            growing,
            complete,
            srcIdx,
            source,
            whichEnd,
            extractable,
            completionInv
          );
        }
      }
    }
  }
  function shiftReplacementRequirement(source, whichEnd) {
    let anchor;
    let pValue;
    if (whichEnd === 2) {
      anchor = source.cards[0];
      pValue = anchor[0] === 1 ? 13 : anchor[0] - 1;
    } else {
      anchor = source.cards[2];
      pValue = anchor[0] === 13 ? 1 : anchor[0] + 1;
    }
    const anchorRed = RED.has(anchor[1]);
    let neededSuits;
    if (source.kind === KIND_RUN) {
      neededSuits = [anchor[1]];
    } else {
      neededSuits = [];
      for (let s = 0; s < 4; s++) {
        if (RED.has(s) !== anchorRed) neededSuits.push(s);
      }
    }
    return { pValue, neededSuits };
  }
  function shiftDonorCandidates(helper, srcIdx, pValue, neededSuits, extractable) {
    const out = [];
    for (const pSuit of neededSuits) {
      const entries = extractable.get(pValue * 4 + pSuit) ?? [];
      for (const { hi: donorIdx, ci, verb } of entries) {
        if (verb === "peel" && donorIdx !== srcIdx && helper[donorIdx].n >= 4) {
          out.push([donorIdx, ci]);
        }
      }
    }
    out.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    return out;
  }
  function shiftRebuildSource(source, pCard, whichEnd) {
    let newCards;
    if (whichEnd === 2) {
      newCards = [pCard, source.cards[0], source.cards[1]];
    } else {
      newCards = [source.cards[1], source.cards[2], pCard];
    }
    return classifyStack(newCards);
  }
  function shiftRebuildHelper(helper, srcIdx, donorIdx, newSource, newDonor) {
    let nh = [...helper];
    const indices = [srcIdx, donorIdx].sort((a, b) => b - a);
    for (const i of indices) nh = dropAt(nh, i);
    return [...nh, newSource, newDonor];
  }
  function* yieldShiftsForEndpoint(absorber, helper, trouble, growing, complete, srcIdx, source, whichEnd, extractable, completionInv) {
    const { bucket, idx, target, leftExt, rightExt, setExt } = absorber;
    const stolen = source.cards[whichEnd];
    const shapeKey = stolen[0] * 4 + stolen[1];
    const leftKind = leftExt.get(shapeKey) ?? null;
    const rightKind = rightExt.get(shapeKey) ?? null;
    const setKind = setExt.get(shapeKey) ?? null;
    if (leftKind === null && rightKind === null && setKind === null) return;
    const { pValue, neededSuits } = shiftReplacementRequirement(source, whichEnd);
    const candidates = shiftDonorCandidates(helper, srcIdx, pValue, neededSuits, extractable);
    for (const [donorIdx, ci] of candidates) {
      const donor = helper[donorIdx];
      const pCard = donor.cards[ci];
      const [, newDonor] = peel(donor, ci);
      const newSource = shiftRebuildSource(source, pCard, whichEnd);
      if (newSource === null || newSource.kind !== source.kind) continue;
      const nh = shiftRebuildHelper(helper, srcIdx, donorIdx, newSource, newDonor);
      if (rightKind !== null) {
        const merged = absorbRight(target, stolen, rightKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
          const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
          const desc = {
            type: "shift",
            source: [...source.cards],
            donor: [...donor.cards],
            stolen,
            pCard,
            whichEnd,
            newSource: [...newSource.cards],
            newDonor: [...newDonor.cards],
            targetBefore: [...target.cards],
            targetBucketBefore: bucket,
            merged: [...merged.cards],
            side: "right",
            graduated
          };
          yield [desc, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
        }
      }
      if (leftKind !== null) {
        const merged = absorbLeft(target, stolen, leftKind);
        if (admissibleMerged(merged, completionInv)) {
          const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
          const [ngFinal, nc, graduated] = graduate(merged, ng, complete);
          const desc = {
            type: "shift",
            source: [...source.cards],
            donor: [...donor.cards],
            stolen,
            pCard,
            whichEnd,
            newSource: [...newSource.cards],
            newDonor: [...newDonor.cards],
            targetBefore: [...target.cards],
            targetBucketBefore: bucket,
            merged: [...merged.cards],
            side: "left",
            graduated
          };
          yield [desc, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
        }
      }
      if (setKind !== null) {
        const mergedR = absorbRight(target, stolen, setKind);
        if (admissibleMerged(mergedR, completionInv)) {
          const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
          const [ngFinal, nc, graduated] = graduate(mergedR, ng, complete);
          const desc = {
            type: "shift",
            source: [...source.cards],
            donor: [...donor.cards],
            stolen,
            pCard,
            whichEnd,
            newSource: [...newSource.cards],
            newDonor: [...newDonor.cards],
            targetBefore: [...target.cards],
            targetBucketBefore: bucket,
            merged: [...mergedR.cards],
            side: "right",
            graduated
          };
          yield [desc, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
        }
        const mergedL = absorbLeft(target, stolen, setKind);
        if (admissibleMerged(mergedL, completionInv)) {
          const [ntBase, ng] = removeAbsorber(bucket, idx, trouble, growing);
          const [ngFinal, nc, graduated] = graduate(mergedL, ng, complete);
          const desc = {
            type: "shift",
            source: [...source.cards],
            donor: [...donor.cards],
            stolen,
            pCard,
            whichEnd,
            newSource: [...newSource.cards],
            newDonor: [...newDonor.cards],
            targetBefore: [...target.cards],
            targetBucketBefore: bucket,
            merged: [...mergedL.cards],
            side: "left",
            graduated
          };
          yield [desc, { helper: nh, trouble: ntBase, growing: ngFinal, complete: nc }];
        }
      }
    }
  }
  function* yieldSplices(helper, trouble, growing, complete, spliceHelpers) {
    let growingSnapshot = null;
    let completeSnapshot = null;
    for (let ti = 0; ti < trouble.length; ti++) {
      const t = trouble[ti];
      if (t.n !== 1) continue;
      const loose = t.cards[0];
      for (const { hi, stack: src } of spliceHelpers) {
        for (const cand of findSpliceCandidates(src, loose)) {
          let left;
          let right;
          if (cand.side === "left") {
            [left, right] = splice_left(
              src,
              loose,
              cand.position,
              cand.leftKind,
              cand.rightKind
            );
          } else {
            [left, right] = splice_right(
              src,
              loose,
              cand.position,
              cand.leftKind,
              cand.rightKind
            );
          }
          const nh = [...dropAt(helper, hi), left, right];
          const nt = dropAt(trouble, ti);
          if (growingSnapshot === null) {
            growingSnapshot = [...growing];
            completeSnapshot = [...complete];
          }
          const desc = {
            type: "splice",
            loose,
            source: [...src.cards],
            k: cand.position,
            side: cand.side,
            leftResult: [...left.cards],
            rightResult: [...right.cards]
          };
          yield [desc, { helper: nh, trouble: nt, growing: [...growingSnapshot], complete: [...completeSnapshot] }];
        }
      }
    }
  }
  function* yieldPushes(helper, trouble, growing, complete) {
    for (let ti = 0; ti < trouble.length; ti++) {
      const t = trouble[ti];
      if (t.n > 2) continue;
      for (let hi = 0; hi < helper.length; hi++) {
        const h = helper[hi];
        const mergedR = absorbSeqRight(h, t.cards);
        if (mergedR !== null) {
          const nh = [...dropAt(helper, hi), mergedR];
          const nt = dropAt(trouble, ti);
          const desc = {
            type: "push",
            troubleBefore: [...t.cards],
            targetBefore: [...h.cards],
            result: [...mergedR.cards],
            side: "right"
          };
          yield [desc, { helper: nh, trouble: nt, growing: [...growing], complete: [...complete] }];
        }
        const mergedL = absorbSeqLeft(h, t.cards);
        if (mergedL !== null) {
          const nh = [...dropAt(helper, hi), mergedL];
          const nt = dropAt(trouble, ti);
          const desc = {
            type: "push",
            troubleBefore: [...t.cards],
            targetBefore: [...h.cards],
            result: [...mergedL.cards],
            side: "left"
          };
          yield [desc, { helper: nh, trouble: nt, growing: [...growing], complete: [...complete] }];
        }
      }
    }
  }
  function* yieldEngulfs(helper, trouble, growing, complete) {
    for (let gi = 0; gi < growing.length; gi++) {
      const g = growing[gi];
      for (let hi = 0; hi < helper.length; hi++) {
        const h = helper[hi];
        const mergedR = absorbSeqRight(h, g.cards);
        if (mergedR !== null) {
          const nh = dropAt(helper, hi);
          const ng = dropAt(growing, gi);
          const nc = [...complete, mergedR];
          const desc = {
            type: "push",
            troubleBefore: [...g.cards],
            targetBefore: [...h.cards],
            result: [...mergedR.cards],
            side: "right"
          };
          yield [desc, { helper: nh, trouble: [...trouble], growing: ng, complete: nc }];
        }
        const mergedL = absorbSeqLeft(h, g.cards);
        if (mergedL !== null) {
          const nh = dropAt(helper, hi);
          const ng = dropAt(growing, gi);
          const nc = [...complete, mergedL];
          const desc = {
            type: "push",
            troubleBefore: [...g.cards],
            targetBefore: [...h.cards],
            result: [...mergedL.cards],
            side: "left"
          };
          yield [desc, { helper: nh, trouble: [...trouble], growing: ng, complete: nc }];
        }
      }
    }
  }
  function* yieldDecomposes(helper, trouble, growing, complete) {
    for (let ti = 0; ti < trouble.length; ti++) {
      const t = trouble[ti];
      if (t.n !== 2) continue;
      const left = t.cards[0];
      const right = t.cards[1];
      const leftSingle = { cards: [left], kind: "singleton", n: 1 };
      const rightSingle = { cards: [right], kind: "singleton", n: 1 };
      const newTrouble = [...trouble.slice(0, ti), ...trouble.slice(ti + 1), leftSingle, rightSingle];
      const desc = {
        type: "decompose",
        pairBefore: [...t.cards],
        leftCard: left,
        rightCard: right
      };
      yield [desc, { helper: [...helper], trouble: newTrouble, growing: [...growing], complete: [...complete] }];
    }
  }
  function absorbRight(target, card, newKind) {
    return { cards: [...target.cards, card], kind: newKind, n: target.n + 1 };
  }
  function absorbLeft(target, card, newKind) {
    return { cards: [card, ...target.cards], kind: newKind, n: target.n + 1 };
  }
  function splice_left(stack, card, position, leftKind, rightKind) {
    const leftCards = stack.cards.slice(0, position).concat([card]);
    const rightCards = stack.cards.slice(position);
    return [
      { cards: leftCards, kind: leftKind, n: leftCards.length },
      { cards: rightCards, kind: rightKind, n: rightCards.length }
    ];
  }
  function splice_right(stack, card, position, leftKind, rightKind) {
    const leftCards = stack.cards.slice(0, position);
    const rightCards = [card, ...stack.cards.slice(position)];
    return [
      { cards: leftCards, kind: leftKind, n: leftCards.length },
      { cards: rightCards, kind: rightKind, n: rightCards.length }
    ];
  }

  // games/lynrummy/ts/src/card_neighbors.ts
  function cardId(c) {
    return (c[0] - 1) * 8 + c[1] * 2 + c[2];
  }
  var HELPER = 1;
  var TROUBLE = 2;
  var GROWING = 3;
  var COMPLETE = 4;
  function suitsInColor(red) {
    const out = [];
    for (let s = 0; s < 4; s++) if (RED.has(s) === red) out.push(s);
    return out;
  }
  function combinations3(arr) {
    const out = [];
    for (let i = 0; i < arr.length; i++)
      for (let j = i + 1; j < arr.length; j++)
        for (let k = j + 1; k < arr.length; k++)
          out.push([arr[i], arr[j], arr[k]]);
    return out;
  }
  function buildNeighbors() {
    const out = [];
    for (let i = 0; i < 104; i++) out.push([]);
    function addTriple(c1, c2, c3) {
      const i1 = cardId(c1), i2 = cardId(c2), i3 = cardId(c3);
      out[i1].push([i2, i3]);
      out[i2].push([i1, i3]);
      out[i3].push([i1, i2]);
    }
    for (let v = 1; v <= 13; v++) {
      for (const [s1, s2, s3] of combinations3([0, 1, 2, 3])) {
        for (let d1 = 0; d1 < 2; d1++)
          for (let d2 = 0; d2 < 2; d2++)
            for (let d3 = 0; d3 < 2; d3++)
              addTriple([v, s1, d1], [v, s2, d2], [v, s3, d3]);
      }
    }
    for (let v0 = 1; v0 <= 13; v0++) {
      const v1 = v0 % 13 + 1;
      const v2 = v1 % 13 + 1;
      for (let s = 0; s < 4; s++) {
        for (let d0 = 0; d0 < 2; d0++)
          for (let d1 = 0; d1 < 2; d1++)
            for (let d2 = 0; d2 < 2; d2++)
              addTriple([v0, s, d0], [v1, s, d1], [v2, s, d2]);
      }
    }
    for (let v0 = 1; v0 <= 13; v0++) {
      const v1 = v0 % 13 + 1;
      const v2 = v1 % 13 + 1;
      for (const startRed of [true, false]) {
        const suits0 = suitsInColor(startRed);
        const suits1 = suitsInColor(!startRed);
        const suits2 = suits0;
        for (const s0 of suits0)
          for (const s1 of suits1)
            for (const s2 of suits2)
              for (let d0 = 0; d0 < 2; d0++)
                for (let d1 = 0; d1 < 2; d1++)
                  for (let d2 = 0; d2 < 2; d2++)
                    addTriple([v0, s0, d0], [v1, s1, d1], [v2, s2, d2]);
      }
    }
    return out;
  }
  var NEIGHBORS = buildNeighbors();
  function buildCardLoc(b) {
    const loc = new Uint8Array(104);
    const tag = (stacks, t) => {
      for (const stack of stacks)
        for (const c of stack.cards) loc[cardId(c)] = t;
    };
    tag(b.helper, HELPER);
    tag(b.trouble, TROUBLE);
    tag(b.growing, GROWING);
    tag(b.complete, COMPLETE);
    return loc;
  }
  function isLive(c, cardLoc) {
    const cid = cardId(c);
    const pairs = NEIGHBORS[cid];
    for (const [c1, c2] of pairs) {
      const loc1 = cardLoc[c1];
      const loc2 = cardLoc[c2];
      if (loc1 > 0 && loc1 < 4 && loc2 > 0 && loc2 < 4) return true;
    }
    return false;
  }
  function allTroubleSingletonsLive(b) {
    let hasSingleton = false;
    for (const t of b.trouble) if (t.n === 1) {
      hasSingleton = true;
      break;
    }
    if (!hasSingleton) return true;
    const cardLoc = buildCardLoc(b);
    for (const t of b.trouble) {
      if (t.n !== 1) continue;
      if (!isLive(t.cards[0], cardLoc)) return false;
    }
    return true;
  }
  function anyTroubleSingletonNewlyDoomed(b) {
    let hasSingleton = false;
    for (const t of b.trouble) if (t.n === 1) {
      hasSingleton = true;
      break;
    }
    if (!hasSingleton) return false;
    const cardLoc = buildCardLoc(b);
    for (const t of b.trouble) {
      if (t.n !== 1) continue;
      if (!isLive(t.cards[0], cardLoc)) return true;
    }
    return false;
  }

  // games/lynrummy/ts/src/engine_v2.ts
  var HEURISTICS = {
    /** Lower-bound: each move shrinks trouble+growing by ≤2. Admissible. */
    half_debt: (b) => {
      let n = 0;
      for (const s of b.trouble) n += s.n;
      for (const s of b.growing) n += s.n;
      return Math.ceil(n / 2);
    },
    /** Lower-bound but allow up to 3 cards retired per move (graduating
     *  via a length-3 group from scratch). Tighter (= smaller h), still
     *  admissible. */
    third_debt: (b) => {
      let n = 0;
      for (const s of b.trouble) n += s.n;
      for (const s of b.growing) n += s.n;
      return Math.ceil(n / 3);
    },
    /** Raw trouble-card count. Overestimates → INADMISSIBLE; may miss
     *  optimal but explores fewer states. */
    raw_debt: (b) => {
      let n = 0;
      for (const s of b.trouble) n += s.n;
      for (const s of b.growing) n += s.n;
      return n;
    },
    /** Number of trouble ENTRIES (not cards). Singletons count = pairs.
     *  Roughly "how many subgoals remain." */
    entry_count: (b) => b.trouble.length + b.growing.length,
    /** Mixed: half-debt + small bonus for length-2 partials (they need
     *  extension; length-1 singletons can sometimes be cheaply pushed). */
    weighted: (b) => {
      let cards = 0, partials = 0;
      for (const s of b.trouble) {
        cards += s.n;
        if (s.n === 2) partials++;
      }
      for (const s of b.growing) {
        cards += s.n;
        if (s.n === 2) partials++;
      }
      return Math.ceil(cards / 2) + Math.floor(partials / 2);
    },
    /** Inadmissible: penalize trouble quadratically. 6 cards feels ~5×
     *  worse than 3 cards (per Steve's "Kasparov heuristic"). */
    quadratic: (b) => {
      let n = 0;
      for (const s of b.trouble) n += s.n;
      for (const s of b.growing) n += s.n;
      return Math.ceil(n * n / 6);
    },
    /** Inadmissible: superlinear with a sharper kick above 4 cards. */
    superlinear: (b) => {
      let n = 0;
      for (const s of b.trouble) n += s.n;
      for (const s of b.growing) n += s.n;
      if (n <= 4) return n;
      return 4 + (n - 4) * 3;
    },
    /** Inadmissible: each trouble entry adds a fixed step + linear card
     *  cost. Penalizes "many disjoint subgoals" framing. */
    many_subgoals: (b) => {
      let entries = b.trouble.length + b.growing.length;
      let cards = 0;
      for (const s of b.trouble) cards += s.n;
      for (const s of b.growing) cards += s.n;
      return entries + Math.ceil(cards / 2);
    }
  };
  function solveTurn(initial, opts = {}) {
    const budget = opts.budget ?? 5e4;
    const maxPlanLength = opts.maxPlanLength;
    const h = opts.heuristic ?? HEURISTICS.half_debt;
    const dedup = opts.dedup !== false;
    const useFastSig = opts.sigKind !== "string";
    const cardOrderInfo = useFastSig ? buildCardOrder(initial) : null;
    const sigFn = useFastSig ? (b, lin) => fastStateSig(b, lin, cardOrderInfo.posOf, cardOrderInfo.cardOrder.length) : (b, lin) => stateSig(b, lin);
    const initialQueue = [...initial.trouble, ...initial.growing];
    const pq = new MinHeap((a, b) => a.score - b.score);
    const closed = /* @__PURE__ */ new Set();
    const queueToLineage = (q) => q.map((s) => [...s.cards]);
    pq.push({ buckets: initial, queue: initialQueue, plan: [], score: h(initial) });
    let best = null;
    let visits = 0;
    while (pq.size() > 0 && visits < budget) {
      const cur = pq.pop();
      if (best !== null && cur.plan.length >= best.length) continue;
      if (dedup) {
        const sig = sigFn(cur.buckets, queueToLineage(cur.queue));
        if (closed.has(sig)) continue;
        closed.add(sig);
      }
      void initialQueue;
      visits++;
      if (cur.queue.length === 0) {
        if (isVictory(cur.buckets.trouble, cur.buckets.growing)) {
          if (best === null || cur.plan.length < best.length) best = [...cur.plan];
        }
        continue;
      }
      const focus = cur.queue[0];
      const parentCompleteCount = cur.buckets.complete.length;
      const candidates = enumerateForFocus(cur.buckets, focus, /* @__PURE__ */ new Set());
      for (const cand of candidates) {
        const newPlan = [...cur.plan, { line: describe(cand.desc), desc: cand.desc }];
        if (best !== null && newPlan.length >= best.length) continue;
        if (maxPlanLength !== void 0 && newPlan.length > maxPlanLength) continue;
        if (cand.afterBuckets.complete.length > parentCompleteCount && anyTroubleSingletonNewlyDoomed(cand.afterBuckets)) {
          continue;
        }
        const newQueue = computeQueueAfter(cur.queue, focus, cand, cand.afterBuckets);
        const score = newPlan.length + h(cand.afterBuckets);
        pq.push({ buckets: cand.afterBuckets, queue: newQueue, plan: newPlan, score });
      }
    }
    lastVisits = visits;
    return best;
  }
  function isAlreadyClassified(initial) {
    for (const bucketName of ["helper", "trouble", "growing", "complete"]) {
      const bucket = initial[bucketName];
      if (Array.isArray(bucket) && bucket.length > 0) {
        const first = bucket[0];
        return typeof first === "object" && first !== null && "kind" in first;
      }
    }
    return true;
  }
  function solveStateWithDescs(initial, opts = {}) {
    const maxStates = opts.maxStates ?? 5e4;
    const maxTroubleOuter = opts.maxTroubleOuter ?? 8;
    const classified = isAlreadyClassified(initial) ? initial : classifyBuckets(initial);
    if (troubleCount(classified.trouble, classified.growing) > maxTroubleOuter) {
      return null;
    }
    if (isVictory(classified.trouble, classified.growing)) {
      return [];
    }
    if (!allTroubleSingletonsLive(classified)) {
      return null;
    }
    return solveTurn(classified, {
      budget: maxStates,
      heuristic: opts.heuristic,
      dedup: opts.dedup,
      sigKind: opts.sigKind,
      maxPlanLength: opts.maxPlanLength
    });
  }
  var MinHeap = class {
    a = [];
    cmp;
    constructor(cmp) {
      this.cmp = cmp;
    }
    size() {
      return this.a.length;
    }
    push(x) {
      this.a.push(x);
      let i = this.a.length - 1;
      while (i > 0) {
        const p = i - 1 >> 1;
        if (this.cmp(this.a[i], this.a[p]) < 0) {
          [this.a[i], this.a[p]] = [this.a[p], this.a[i]];
          i = p;
        } else break;
      }
    }
    pop() {
      if (this.a.length === 0) return void 0;
      const top = this.a[0];
      const last = this.a.pop();
      if (this.a.length > 0) {
        this.a[0] = last;
        let i = 0;
        while (true) {
          const l = 2 * i + 1, r = 2 * i + 2;
          let s = i;
          if (l < this.a.length && this.cmp(this.a[l], this.a[s]) < 0) s = l;
          if (r < this.a.length && this.cmp(this.a[r], this.a[s]) < 0) s = r;
          if (s === i) break;
          [this.a[i], this.a[s]] = [this.a[s], this.a[i]];
          i = s;
        }
      }
      return top;
    }
  };
  var lastVisits = 0;
  function enumerateForFocus(buckets, focus, doomedPairs) {
    const candidates = [];
    const focusCards = focus.cards;
    for (const [desc, newBuckets] of enumerateMoves(buckets)) {
      if (!moveTouchesFocus(desc, focusCards)) continue;
      const tier = candidateTier(desc, newBuckets);
      let n = 0;
      for (const s of newBuckets.trouble) n += s.n;
      for (const s of newBuckets.growing) n += s.n;
      const sourceLen = sourceHelperLength(desc);
      candidates.push({ desc, afterBuckets: newBuckets, tier, troubleAfter: n, sourceLen });
    }
    candidates.sort((a, b) => a.tier - b.tier || a.troubleAfter - b.troubleAfter);
    return candidates.map((c) => ({ desc: c.desc, afterBuckets: c.afterBuckets }));
    void doomedPairs;
  }
  function candidateTier(desc, _newBuckets) {
    switch (desc.type) {
      case "extract_absorb":
        if (desc.graduated && desc.spawned.length === 0) return 0;
        return 1;
      case "free_pull":
        return desc.graduated ? 0 : 1;
      case "shift":
        return desc.graduated ? 0 : 1;
      case "push":
        return 0;
      // push consumes trouble, never spawns
      case "splice":
        return 1;
    }
    return 1;
    void _newBuckets;
  }
  function sourceHelperLength(desc) {
    switch (desc.type) {
      case "extract_absorb":
      case "shift":
        return desc.source.length;
      case "splice":
        return desc.source.length;
      case "free_pull":
      case "push":
        return 0;
    }
    return 0;
  }
  function moveTouchesFocus(desc, focus) {
    if (desc.type === "extract_absorb" || desc.type === "shift") {
      return cardsEqual(desc.targetBefore, focus);
    }
    if (desc.type === "free_pull") {
      if (cardsEqual(desc.targetBefore, focus)) return true;
      return focus.length === 1 && cardEqual(focus[0], desc.loose);
    }
    if (desc.type === "splice") {
      return focus.length === 1 && cardEqual(focus[0], desc.loose);
    }
    if (desc.type === "push") {
      return cardsEqual(desc.troubleBefore, focus);
    }
    return false;
  }
  function cardEqual(a, b) {
    return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
  }
  function cardsEqual(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!cardEqual(a[i], b[i])) return false;
    return true;
  }
  function computeQueueAfter(queue, focus, cand, newBuckets) {
    const rest = queue.slice(1);
    const survivingByCards = /* @__PURE__ */ new Map();
    for (const stack of [...newBuckets.trouble, ...newBuckets.growing]) {
      survivingByCards.set(cardsKey(stack.cards), stack);
    }
    const newQueue = [];
    const used = /* @__PURE__ */ new Set();
    for (const e of rest) {
      const k = cardsKey(e.cards);
      if (survivingByCards.has(k) && !used.has(k)) {
        newQueue.push(survivingByCards.get(k));
        used.add(k);
      }
    }
    for (const stack of [...newBuckets.trouble, ...newBuckets.growing]) {
      const k = cardsKey(stack.cards);
      if (used.has(k)) continue;
      newQueue.push(stack);
      used.add(k);
    }
    return newQueue;
    void focus;
    void cand;
  }
  function cardsKey(cards) {
    return cards.map((c) => `${c[0]},${c[1]},${c[2]}`).join("|");
  }

  // games/lynrummy/ts/src/geometry.ts
  var CARD_WIDTH = 27;
  var CARD_PITCH = CARD_WIDTH + 6;
  var CARD_HEIGHT = 40;
  var BOARD_MAX_WIDTH = 800;
  var BOARD_MAX_HEIGHT = 600;
  var BOARD_MARGIN = 7;
  var PLACE_STEP = 10;
  var PACK_GAP_X = 30;
  var PACK_GAP_Y = 30;
  var ANTI_ALIGN_PX = 2;
  var BOARD_START = { left: 24, top: 24 };
  var HUMAN_PREFERRED_ORIGIN = { left: 50, top: 90 };
  function stackWidth(cardCount) {
    if (cardCount <= 0) return 0;
    return CARD_WIDTH + (cardCount - 1) * CARD_PITCH;
  }
  function stackRect(stack) {
    const left = stack.loc.left;
    const top = stack.loc.top;
    return {
      left,
      top,
      right: left + stackWidth(stack.cards.length),
      bottom: top + CARD_HEIGHT
    };
  }
  function rectsOverlap(a, b) {
    return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
  }
  function padRect(r, margin) {
    return {
      left: r.left - margin,
      top: r.top - margin,
      right: r.right + margin,
      bottom: r.bottom + margin
    };
  }
  function antiAlign(left, top, newW, newH) {
    const jl = Math.min(left + ANTI_ALIGN_PX, BOARD_MAX_WIDTH - newW);
    const jt = Math.min(top + ANTI_ALIGN_PX, BOARD_MAX_HEIGHT - newH);
    return { left: jl, top: jt };
  }
  function findOpenLoc(existing, cardCount) {
    const newW = stackWidth(cardCount);
    const newH = CARD_HEIGHT;
    const existingRects = existing.map(stackRect);
    if (existingRects.length === 0) {
      return antiAlign(BOARD_START.left, BOARD_START.top, newW, newH);
    }
    const step = 15;
    const minLeft = BOARD_MARGIN;
    const minTop = BOARD_MARGIN;
    const maxLeft = BOARD_MAX_WIDTH - newW - BOARD_MARGIN;
    const maxTop = BOARD_MAX_HEIGHT - newH - BOARD_MARGIN;
    const startLeft = Math.min(Math.max(HUMAN_PREFERRED_ORIGIN.left, minLeft), maxLeft);
    const startTop = Math.min(Math.max(HUMAN_PREFERRED_ORIGIN.top, minTop), maxTop);
    const clears = (left, top) => {
      const padded = {
        left: left - PACK_GAP_X,
        top: top - PACK_GAP_Y,
        right: left + newW + PACK_GAP_X,
        bottom: top + newH + PACK_GAP_Y
      };
      for (const er of existingRects) if (rectsOverlap(padded, er)) return false;
      return true;
    };
    for (let left = startLeft; left <= maxLeft; left += step) {
      for (let top = startTop; top <= maxTop; top += step) {
        if (clears(left, top)) return antiAlign(left, top, newW, newH);
      }
    }
    for (let left = minLeft; left <= maxLeft; left += step) {
      for (let top = minTop; top <= maxTop; top += step) {
        if (clears(left, top)) return antiAlign(left, top, newW, newH);
      }
    }
    return gridSweepOpenLoc(existingRects, newW, newH);
  }
  function gridSweepOpenLoc(existingRects, newW, newH) {
    for (let top = 0; top + newH <= BOARD_MAX_HEIGHT; top += PLACE_STEP) {
      for (let left = 0; left + newW <= BOARD_MAX_WIDTH; left += PLACE_STEP) {
        const candidate = {
          left: left - BOARD_MARGIN,
          top: top - BOARD_MARGIN,
          right: left + newW + BOARD_MARGIN,
          bottom: top + newH + BOARD_MARGIN
        };
        let clears = true;
        for (const er of existingRects) {
          if (rectsOverlap(candidate, er)) {
            clears = false;
            break;
          }
        }
        if (clears) return { top, left };
      }
    }
    const fallbackTop = Math.max(0, BOARD_MAX_HEIGHT - newH);
    return { top: fallbackTop, left: 0 };
  }
  function outOfBounds(stack) {
    const r = stackRect(stack);
    return r.left < 0 || r.top < 0 || r.right > BOARD_MAX_WIDTH || r.bottom > BOARD_MAX_HEIGHT;
  }
  var PLANNING_MARGIN = 15;
  function findViolation(board, margin = BOARD_MARGIN) {
    for (let i = 0; i < board.length; i++) {
      if (outOfBounds(board[i])) return i;
    }
    const rects = board.map(stackRect);
    for (let i = 0; i < rects.length; i++) {
      const paddedI = padRect(rects[i], margin);
      for (let j = i + 1; j < rects.length; j++) {
        if (rectsOverlap(paddedI, rects[j])) return j;
      }
    }
    return null;
  }
  function findCrowding(board) {
    return findViolation(board, PLANNING_MARGIN);
  }

  // games/lynrummy/ts/src/primitives.ts
  function applySplit(board, si, ci) {
    const stack = board[si];
    const size = stack.cards.length;
    const srcLeft = stack.loc.left;
    const srcTop = stack.loc.top;
    let leftCount;
    let leftLoc;
    let rightLoc;
    if (ci + 1 <= Math.floor(size / 2)) {
      leftCount = ci + 1;
      leftLoc = { top: srcTop - 4, left: srcLeft - 2 };
      rightLoc = { top: srcTop, left: srcLeft + leftCount * CARD_PITCH + 8 };
    } else {
      leftCount = ci;
      leftLoc = { top: srcTop, left: srcLeft - 8 };
      rightLoc = { top: srcTop - 4, left: srcLeft + leftCount * CARD_PITCH + 4 };
    }
    const left = {
      cards: stack.cards.slice(0, leftCount),
      loc: leftLoc
    };
    const right = {
      cards: stack.cards.slice(leftCount),
      loc: rightLoc
    };
    return [...board.slice(0, si), ...board.slice(si + 1), left, right];
  }
  function applyMove(board, si, newLoc) {
    const s = board[si];
    const moved = { cards: s.cards, loc: { ...newLoc } };
    return [...board.slice(0, si), ...board.slice(si + 1), moved];
  }
  function applyMergeStack(board, src, tgt, side) {
    const s = board[src];
    const t = board[tgt];
    let newCards;
    let loc;
    if (side === "left") {
      newCards = [...s.cards, ...t.cards];
      loc = { left: t.loc.left - CARD_PITCH * s.cards.length, top: t.loc.top };
    } else {
      newCards = [...t.cards, ...s.cards];
      loc = { ...t.loc };
    }
    const merged = { cards: newCards, loc };
    const [hi, lo] = src > tgt ? [src, tgt] : [tgt, src];
    const out = [...board];
    out.splice(hi, 1);
    out.splice(lo, 1);
    return [...out, merged];
  }
  function applyMergeHand(board, targetIdx, handCard, side) {
    const t = board[targetIdx];
    let newCards;
    let loc;
    if (side === "left") {
      newCards = [handCard, ...t.cards];
      loc = { left: t.loc.left - CARD_PITCH, top: t.loc.top };
    } else {
      newCards = [...t.cards, handCard];
      loc = { ...t.loc };
    }
    const merged = { cards: newCards, loc };
    return [...board.slice(0, targetIdx), ...board.slice(targetIdx + 1), merged];
  }
  function applyPlaceHand(board, handCard, loc) {
    return [...board, { cards: [handCard], loc: { ...loc } }];
  }
  function applyLocally(board, prim) {
    switch (prim.action) {
      case "split":
        return applySplit(board, prim.stackIndex, prim.cardIndex);
      case "move_stack":
        return applyMove(board, prim.stackIndex, prim.newLoc);
      case "merge_stack":
        return applyMergeStack(board, prim.sourceStack, prim.targetStack, prim.side);
      case "merge_hand":
        return applyMergeHand(board, prim.targetStack, prim.handCard, prim.side);
      case "place_hand":
        return applyPlaceHand(board, prim.handCard, prim.loc);
    }
  }
  function cardEq(a, b) {
    return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
  }
  function cardsEq(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!cardEq(a[i], b[i])) return false;
    return true;
  }
  function findStackIndex(board, cards) {
    for (let i = 0; i < board.length; i++) {
      if (cardsEq(board[i].cards, cards)) return i;
    }
    throw new Error(`stack not found on board: [${cards.map((c) => `${c[0]},${c[1]},${c[2]}`).join(" ")}]`);
  }

  // games/lynrummy/ts/src/verbs.ts
  function flipSide(s) {
    return s === "left" ? "right" : "left";
  }
  function cardKey(c) {
    return `${c[0]},${c[1]},${c[2]}`;
  }
  function expandVerb(desc, board, pendingHand = /* @__PURE__ */ new Set()) {
    switch (desc.type) {
      case "extract_absorb":
        return extractAbsorbPrims(desc, board, pendingHand);
      case "free_pull":
        return freePullPrims(desc, board, pendingHand);
      case "push":
        return pushPrims(desc, board, pendingHand);
      case "splice":
        return splicePrims(desc, board, pendingHand);
      case "shift":
        return shiftPrims(desc, board, pendingHand);
      case "decompose":
        return decomposePrims(desc, board);
    }
  }
  function planSplitAfter(sim, stackContent, k) {
    const n = stackContent.length;
    if (!(k >= 1 && k <= n - 1)) {
      throw new Error(`split-after k=${k} out of range for n=${n}`);
    }
    const ci = k <= Math.floor(n / 2) ? k - 1 : k;
    const si = findStackIndex(sim, stackContent);
    const isInterior = ci !== 0 && ci !== n - 1;
    if (isInterior) {
      const others2 = sim.filter((_, i) => i !== si);
      const newLoc2 = findOpenLoc(others2, n);
      const cur2 = sim[si].loc;
      if (newLoc2.top !== cur2.top || newLoc2.left !== cur2.left) {
        const move2 = { action: "move_stack", stackIndex: si, newLoc: newLoc2 };
        const afterMove2 = applyLocally(sim, move2);
        const newSi2 = findStackIndex(afterMove2, stackContent);
        const split2 = { action: "split", stackIndex: newSi2, cardIndex: ci };
        const post3 = applyLocally(afterMove2, split2);
        return { prims: [move2, split2], sim: post3 };
      }
    }
    const split = { action: "split", stackIndex: si, cardIndex: ci };
    const post = applyLocally(sim, split);
    if (findCrowding(post) === null) {
      return { prims: [split], sim: post };
    }
    const others = sim.filter((_, i) => i !== si);
    const newLoc = findOpenLoc(others, n);
    const cur = sim[si].loc;
    if (newLoc.top === cur.top && newLoc.left === cur.left) {
      return { prims: [split], sim: post };
    }
    const move = { action: "move_stack", stackIndex: si, newLoc };
    const afterMove = applyLocally(sim, move);
    const newSi = findStackIndex(afterMove, stackContent);
    const newSplit = { action: "split", stackIndex: newSi, cardIndex: ci };
    const post2 = applyLocally(afterMove, newSplit);
    return { prims: [move, newSplit], sim: post2 };
  }
  function planMerge(sim, srcContent, tgtContent, side, pendingHand) {
    if (srcContent.length === 1 && pendingHand.has(cardKey(srcContent[0]))) {
      return planMergeHand(sim, srcContent[0], tgtContent, side);
    }
    if (tgtContent.length === 1 && pendingHand.has(cardKey(tgtContent[0]))) {
      return planMergeHand(sim, tgtContent[0], srcContent, flipSide(side));
    }
    let s = srcContent, t = tgtContent, sd = side;
    if (s.length > t.length) {
      [s, t] = [t, s];
      sd = flipSide(sd);
    }
    return planMergeStackOnBoard(sim, s, t, sd);
  }
  function planMergeHand(sim, handCard, tgtContent, side) {
    const tgtIdx = findStackIndex(sim, tgtContent);
    const merge = {
      action: "merge_hand",
      targetStack: tgtIdx,
      handCard,
      side
    };
    const post = applyLocally(sim, merge);
    if (findCrowding(post) === null) {
      return { prims: [merge], sim: post };
    }
    const finalSize = tgtContent.length + 1;
    const others = sim.filter((_, i) => i !== tgtIdx);
    const finalLoc = findOpenLoc(others, finalSize);
    const targetLoc = side === "left" ? { top: finalLoc.top, left: finalLoc.left + CARD_PITCH } : finalLoc;
    const cur = sim[tgtIdx].loc;
    if (targetLoc.top === cur.top && targetLoc.left === cur.left) {
      return { prims: [merge], sim: post };
    }
    const move = {
      action: "move_stack",
      stackIndex: tgtIdx,
      newLoc: targetLoc
    };
    const afterMove = applyLocally(sim, move);
    const newTgtIdx = findStackIndex(afterMove, tgtContent);
    const newMerge = {
      action: "merge_hand",
      targetStack: newTgtIdx,
      handCard,
      side
    };
    const post2 = applyLocally(afterMove, newMerge);
    return { prims: [move, newMerge], sim: post2 };
  }
  function planMergeStackOnBoard(sim, srcContent, tgtContent, side) {
    const srcIdx = findStackIndex(sim, srcContent);
    const tgtIdx = findStackIndex(sim, tgtContent);
    const merge = {
      action: "merge_stack",
      sourceStack: srcIdx,
      targetStack: tgtIdx,
      side
    };
    const post = applyLocally(sim, merge);
    if (findCrowding(post) === null) {
      return { prims: [merge], sim: post };
    }
    const finalSize = srcContent.length + tgtContent.length;
    const others = sim.filter((_, i) => i !== tgtIdx);
    const finalLoc = findOpenLoc(others, finalSize);
    const targetLoc = side === "left" ? {
      top: finalLoc.top,
      left: finalLoc.left + CARD_PITCH * srcContent.length
    } : finalLoc;
    const cur = sim[tgtIdx].loc;
    if (targetLoc.top === cur.top && targetLoc.left === cur.left) {
      return { prims: [merge], sim: post };
    }
    const move = {
      action: "move_stack",
      stackIndex: tgtIdx,
      newLoc: targetLoc
    };
    const afterMove = applyLocally(sim, move);
    const newSrcIdx = findStackIndex(afterMove, srcContent);
    const newTgtIdx = findStackIndex(afterMove, tgtContent);
    const newMerge = {
      action: "merge_stack",
      sourceStack: newSrcIdx,
      targetStack: newTgtIdx,
      side
    };
    const post2 = applyLocally(afterMove, newMerge);
    return { prims: [move, newMerge], sim: post2 };
  }
  function classifyLeaf(cards) {
    const ccs = classifyStack(cards);
    if (ccs === null || ccs.n < 3) return "other";
    if (ccs.kind === "set") return "set";
    if (ccs.kind === "run") return "pure_run";
    if (ccs.kind === "rb") return "rb_run";
    return "other";
  }
  function isolateCard(sim, stackContent, ci) {
    const n = stackContent.length;
    const extCard = stackContent[ci];
    const out = [];
    if (ci === 0 && n > 1) {
      const r = planSplitAfter(sim, stackContent, 1);
      out.push(...r.prims);
      return {
        prims: out,
        sim: r.sim,
        extSingleton: [extCard],
        remnants: [stackContent.slice(1)]
      };
    }
    if (ci === n - 1 && n > 1) {
      const r = planSplitAfter(sim, stackContent, n - 1);
      out.push(...r.prims);
      return {
        prims: out,
        sim: r.sim,
        extSingleton: [extCard],
        remnants: [stackContent.slice(0, n - 1)]
      };
    }
    const a = planSplitAfter(sim, stackContent, ci);
    out.push(...a.prims);
    const rightChunk = stackContent.slice(ci);
    const b = planSplitAfter(a.sim, rightChunk, 1);
    out.push(...b.prims);
    return {
      prims: out,
      sim: b.sim,
      extSingleton: [extCard],
      remnants: [stackContent.slice(0, ci), stackContent.slice(ci + 1)]
    };
  }
  function indexOfCard(arr, target) {
    for (let i = 0; i < arr.length; i++) {
      const c = arr[i];
      if (c[0] === target[0] && c[1] === target[1] && c[2] === target[2]) return i;
    }
    return -1;
  }
  function extractAbsorbPrims(desc, board, pendingHand) {
    const source = desc.source;
    const extCard = desc.extCard;
    const targetBefore = desc.targetBefore;
    const side = desc.side;
    const verb = desc.verb;
    const kind = classifyLeaf(source);
    const ci = indexOfCard(source, extCard);
    let sim = board;
    const out = [];
    let extSingleton = [extCard];
    if (verb === "peel" || verb === "pluck" || verb === "yank" || verb === "split_out" || verb === "set_peel") {
      const iso = isolateCard(sim, source, ci);
      out.push(...iso.prims);
      sim = iso.sim;
      extSingleton = iso.extSingleton;
      if (kind === "set" && iso.remnants.length === 2) {
        const [leftChunk, tailChunk] = iso.remnants;
        const r2 = planMerge(sim, tailChunk, leftChunk, "right", pendingHand);
        out.push(...r2.prims);
        sim = r2.sim;
      }
    } else if (verb === "steal" && (kind === "pure_run" || kind === "rb_run")) {
      const iso = isolateCard(sim, source, ci);
      out.push(...iso.prims);
      sim = iso.sim;
      extSingleton = iso.extSingleton;
    } else if (verb === "steal" && kind === "set") {
      const n = source.length;
      let residue;
      if (ci === n - 1) {
        const r3 = planSplitAfter(sim, source, n - 1);
        out.push(...r3.prims);
        sim = r3.sim;
        residue = source.slice(0, n - 1);
      } else {
        const r3 = planSplitAfter(sim, source, 1);
        out.push(...r3.prims);
        sim = r3.sim;
        residue = source.slice(1);
      }
      const r2 = planSplitAfter(sim, residue, 1);
      out.push(...r2.prims);
      sim = r2.sim;
      extSingleton = [extCard];
    } else if (verb === "steal" && (kind === "pair_run" || kind === "pair_rb" || kind === "pair_set" || kind === "other")) {
      if (source.length !== 2) {
        throw new Error(`steal-from-partial expects length-2 source; got length ${source.length}`);
      }
      const r2 = planSplitAfter(sim, source, 1);
      out.push(...r2.prims);
      sim = r2.sim;
      extSingleton = [extCard];
    } else {
      throw new Error(`verb ${verb} kind ${kind} unsupported`);
    }
    const r = planMerge(sim, extSingleton, targetBefore, side, pendingHand);
    out.push(...r.prims);
    return out;
  }
  function freePullPrims(desc, board, pendingHand) {
    const r = planMerge(board, [desc.loose], desc.targetBefore, desc.side, pendingHand);
    return r.prims;
  }
  function pushPrims(desc, board, pendingHand) {
    const r = planMerge(board, desc.troubleBefore, desc.targetBefore, desc.side, pendingHand);
    return r.prims;
  }
  function splicePrims(desc, board, pendingHand) {
    const loose = desc.loose;
    const src = desc.source;
    const k = desc.k;
    const side = desc.side;
    let sim = board;
    const a = planSplitAfter(sim, src, k);
    sim = a.sim;
    const half = side === "left" ? src.slice(0, k) : src.slice(k);
    const mergeSide = side === "left" ? "right" : "left";
    const b = planMerge(sim, [loose], half, mergeSide, pendingHand);
    return [...a.prims, ...b.prims];
  }
  function shiftPrims(desc, board, pendingHand) {
    const source = desc.source;
    const donor = desc.donor;
    const stolen = desc.stolen;
    const pCard = desc.pCard;
    const whichEnd = desc.whichEnd;
    const targetBefore = desc.targetBefore;
    const side = desc.side;
    let sim = board;
    const out = [];
    const pi = indexOfCard(donor, pCard);
    const kind = classifyLeaf(donor);
    const iso = isolateCard(sim, donor, pi);
    out.push(...iso.prims);
    sim = iso.sim;
    if (kind === "set" && iso.remnants.length === 2) {
      const [leftChunk, tailChunk] = iso.remnants;
      const r = planMerge(sim, tailChunk, leftChunk, "right", pendingHand);
      out.push(...r.prims);
      sim = r.sim;
    }
    let augmentedSource;
    let splitK;
    if (whichEnd === 0) {
      const r = planMerge(sim, [pCard], source, "right", pendingHand);
      out.push(...r.prims);
      sim = r.sim;
      augmentedSource = [...source, pCard];
      splitK = 1;
    } else {
      const r = planMerge(sim, [pCard], source, "left", pendingHand);
      out.push(...r.prims);
      sim = r.sim;
      augmentedSource = [pCard, ...source];
      splitK = source.length;
    }
    const a = planSplitAfter(sim, augmentedSource, splitK);
    out.push(...a.prims);
    sim = a.sim;
    const m = planMerge(sim, [stolen], targetBefore, side, pendingHand);
    out.push(...m.prims);
    return out;
  }
  function decomposePrims(desc, board) {
    const r = planSplitAfter(board, desc.pairBefore, 1);
    return r.prims;
  }

  // games/lynrummy/ts/src/wire_json.ts
  function jsonCard(c) {
    return { value: c[0], suit: c[1], origin_deck: c[2] };
  }
  function jsonBoardCard(c) {
    return { card: jsonCard(c), state: 0 };
  }
  function jsonStack(s) {
    return {
      board_cards: s.cards.map(jsonBoardCard),
      loc: { top: s.loc.top, left: s.loc.left }
    };
  }
  function primToWire(prim, sim) {
    switch (prim.action) {
      case "split":
        return {
          action: "split",
          stack: jsonStack(sim[prim.stackIndex]),
          card_index: prim.cardIndex
        };
      case "merge_stack":
        return {
          action: "merge_stack",
          source: jsonStack(sim[prim.sourceStack]),
          target: jsonStack(sim[prim.targetStack]),
          side: prim.side
        };
      case "merge_hand":
        return {
          action: "merge_hand",
          hand_card: jsonCard(prim.handCard),
          target: jsonStack(sim[prim.targetStack]),
          side: prim.side
        };
      case "place_hand":
        return {
          action: "place_hand",
          hand_card: jsonCard(prim.handCard),
          loc: { top: prim.loc.top, left: prim.loc.left }
        };
      case "move_stack":
        return {
          action: "move_stack",
          stack: jsonStack(sim[prim.stackIndex]),
          new_loc: { top: prim.newLoc.top, left: prim.newLoc.left }
        };
    }
  }

  // games/lynrummy/ts/src/rules/stack_type.ts
  function successor2(v) {
    return v === 13 ? 1 : v + 1;
  }
  function isPartialOk(stack) {
    const n = stack.length;
    if (n === 0) return true;
    if (n === 1) return true;
    if (n >= 3) return classifyStack(stack) !== null;
    const a = stack[0];
    const b = stack[1];
    if (successor2(a[0]) === b[0]) {
      if (a[1] === b[1]) return true;
      if (isRedSuit(a[1]) !== isRedSuit(b[1])) return true;
    }
    if (a[0] === b[0] && a[1] !== b[1]) return true;
    return false;
  }

  // games/lynrummy/ts/src/hand_play.ts
  var PROJECTION_MAX_STATES = 5e3;
  var HINT_MAX_PLAN_LENGTH = 4;
  function findPlay(hand, board, opts = {}) {
    const maxStates = opts.maxStates ?? PROJECTION_MAX_STATES;
    const stats = opts.stats;
    const tStart = performance.now();
    for (let i = 0; i < hand.length; i++) {
      for (let j = i + 1; j < hand.length; j++) {
        const c1 = hand[i];
        const c2 = hand[j];
        if (!isPartialOk([c1, c2])) continue;
        const ordered = findCompletingThird([c1, c2], hand, i, j);
        if (ordered !== null) {
          finishStats(stats, tStart);
          return { placements: ordered, plan: [] };
        }
      }
    }
    const candidates = [];
    for (let i = 0; i < hand.length; i++) {
      for (let j = i + 1; j < hand.length; j++) {
        const c1 = hand[i];
        const c2 = hand[j];
        if (!isPartialOk([c1, c2])) continue;
        const plan = tryProjection(board, [[c1, c2]], maxStates, stats, "pair");
        if (plan !== null) {
          candidates.push({ placements: [c1, c2], plan });
        }
      }
    }
    for (const c of hand) {
      const plan = tryProjection(board, [[c]], maxStates, stats, "singleton");
      if (plan !== null) {
        candidates.push({ placements: [c], plan });
      }
    }
    finishStats(stats, tStart);
    if (candidates.length === 0) return null;
    return candidates.reduce(
      (best, cur) => cur.plan.length < best.plan.length ? cur : best
    );
  }
  function finishStats(stats, tStart) {
    if (stats !== void 0) {
      stats.totalWallMs = performance.now() - tStart;
    }
  }
  function findCompletingThird(pair, hand, pairI, pairJ) {
    for (let k = 0; k < hand.length; k++) {
      if (k === pairI || k === pairJ) continue;
      const c = hand[k];
      if (cardEq2(c, pair[0]) || cardEq2(c, pair[1])) continue;
      const triples = [
        [pair[0], pair[1], c],
        [pair[0], c, pair[1]],
        [c, pair[0], pair[1]]
      ];
      for (const ordered of triples) {
        const ccs = classifyStack(ordered);
        if (ccs !== null && ccs.n >= 3) return ordered;
      }
    }
    return null;
  }
  function cardEq2(a, b) {
    return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
  }
  function tryProjection(board, extraStacks, maxStates, stats, kind) {
    const augmented = [...board, ...extraStacks];
    const helper = [];
    const trouble = [];
    for (const s of augmented) {
      const ccs = classifyStack(s);
      if (ccs === null || ccs.n < 3) {
        trouble.push(s);
      } else {
        helper.push(s);
      }
    }
    const initial = {
      helper,
      trouble,
      growing: [],
      complete: []
    };
    const cards = [];
    for (const s of extraStacks) for (const c of s) cards.push(c);
    if (stats === void 0) {
      const plan2 = solveStateWithDescs(initial, {
        maxTroubleOuter: 10,
        maxStates,
        maxPlanLength: HINT_MAX_PLAN_LENGTH
      });
      return plan2 === null ? null : plan2.map((p) => p.line);
    }
    const t0 = performance.now();
    const plan = solveStateWithDescs(initial, {
      maxTroubleOuter: 10,
      maxStates
    });
    const wallMs = performance.now() - t0;
    stats.projections.push({
      kind,
      cards,
      wallMs,
      foundPlan: plan !== null
    });
    return plan === null ? null : plan.map((p) => p.line);
  }

  // games/lynrummy/ts/src/engine_entry.ts
  function solveBoard(board) {
    return solveBucketsFromCardLists(board);
  }
  function agentPlay(board) {
    const cardLists = board.map((s) => s.cards);
    const plan = solveBucketsFromCardLists(cardLists);
    if (plan === null) return null;
    let sim = board;
    const out = [];
    for (const planLine of plan) {
      const prims = expandVerb(planLine.desc, sim, /* @__PURE__ */ new Set());
      const wireActions = [];
      for (const p of prims) {
        wireActions.push(primToWire(p, sim));
        sim = applyLocally(sim, p);
      }
      out.push({ line: planLine.line, wire_actions: wireActions });
    }
    return out;
  }
  function solveBucketsFromCardLists(board) {
    const helper = [];
    const trouble = [];
    for (const stack of board) {
      const ccs = classifyStack(stack);
      if (ccs !== null && (ccs.kind === KIND_RUN || ccs.kind === KIND_RB || ccs.kind === KIND_SET)) {
        helper.push(stack);
      } else {
        trouble.push(stack);
      }
    }
    return solveStateWithDescs({
      helper,
      trouble,
      growing: [],
      complete: []
    });
  }
  return __toCommonJS(engine_entry_exports);
})();
