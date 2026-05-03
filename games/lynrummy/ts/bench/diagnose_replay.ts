// diagnose_replay.ts — walk a session's action log through a
// minimal hand-tracking eager applier, find the first action that
// references a card not in the current hand. Pinpoints whether the
// transcript-side or Elm-side bookkeeping is the source of the
// "hand_card not in active hand" cascade.
//
// Usage:
//   node bench/diagnose_replay.ts [session_id]   # default 1

import * as fs from "node:fs";
import * as path from "node:path";

const SESSION_ID = process.argv[2] ? parseInt(process.argv[2], 10) : 1;
const SESSIONS_DIR = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../data/lynrummy-elm/sessions",
);
const SESSION_DIR = path.join(SESSIONS_DIR, String(SESSION_ID));

interface JsonCard { value: number; suit: number; origin_deck: number }

function cardKey(c: JsonCard): string {
  return `${c.value},${c.suit},${c.origin_deck}`;
}
function cardLabel(c: JsonCard): string {
  const ranks = "A23456789TJQK";
  const suits = "CDSH";
  return ranks[c.value - 1]! + suits[c.suit]! + (c.origin_deck === 1 ? "'" : "");
}

interface Meta {
  initial_state: {
    hands: { hand_cards: { card: JsonCard; state: number }[] }[];
    deck: JsonCard[];
    active_player_index: number;
  };
}

const meta: Meta = JSON.parse(
  fs.readFileSync(path.join(SESSION_DIR, "meta.json"), "utf8"),
);
const initialHand = meta.initial_state.hands[0]!.hand_cards.map(hc => hc.card);
const initialDeck = meta.initial_state.deck;

let hand: JsonCard[] = [...initialHand];
let deck: JsonCard[] = [...initialDeck];
let turn = 1;
let cardsPlayedThisTurn = 0;

function listFiles(): number[] {
  const dir = path.join(SESSION_DIR, "actions");
  return fs.readdirSync(dir)
    .filter(f => f.endsWith(".json"))
    .map(f => parseInt(f.replace(".json", ""), 10))
    .sort((a, b) => a - b);
}

function dumpHand(): string {
  return hand.map(cardLabel).join(" ");
}

function abort(seq: number, msg: string): never {
  console.error(`\n=== FIRST DIVERGENCE at seq=${seq} (turn=${turn}) ===`);
  console.error(msg);
  console.error(`current hand (${hand.length}): ${dumpHand()}`);
  console.error(`turn ${turn}, cards_played_this_turn=${cardsPlayedThisTurn}, deck_remaining=${deck.length}`);
  process.exit(1);
}

const seqs = listFiles();
for (const seq of seqs) {
  const env = JSON.parse(
    fs.readFileSync(path.join(SESSION_DIR, "actions", `${seq}.json`), "utf8"),
  );
  const a = env.action;
  if (a.action === "place_hand") {
    const want = cardKey(a.hand_card);
    const idx = hand.findIndex(c => cardKey(c) === want);
    if (idx < 0) abort(seq, `place_hand wants ${cardLabel(a.hand_card)} but it's not in hand.`);
    hand.splice(idx, 1);
    cardsPlayedThisTurn++;
  } else if (a.action === "merge_hand") {
    const want = cardKey(a.hand_card);
    const idx = hand.findIndex(c => cardKey(c) === want);
    if (idx < 0) abort(seq, `merge_hand wants ${cardLabel(a.hand_card)} but it's not in hand.`);
    hand.splice(idx, 1);
    cardsPlayedThisTurn++;
  } else if (a.action === "complete_turn") {
    // Mirror Elm's takeDeck: empty-hand → 5, else → 3.
    const drawCount = hand.length === 0 && cardsPlayedThisTurn > 0 ? 5 : 3;
    const cards = deck.slice(0, drawCount);
    deck = deck.slice(drawCount);
    for (const c of cards) hand.push(c);
    console.log(`seq=${seq.toString().padStart(3)} complete_turn  turn=${turn} hand_pre_draw=${hand.length - cards.length} drew=${cards.length} hand_post=${hand.length} deck_remaining=${deck.length}`);
    turn++;
    cardsPlayedThisTurn = 0;
  }
  // split / merge_stack / move_stack don't touch hand or deck.
}

console.log(`\nFinished ${seqs.length} actions through ${turn - 1} turns.`);
console.log(`Final hand (${hand.length}): ${dumpHand()}`);
console.log(`Final deck remaining: ${deck.length}`);
