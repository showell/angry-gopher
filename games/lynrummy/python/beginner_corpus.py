"""
beginner_corpus.py — deterministic corpus runner for
beginner.py before/after testing.

Each entry is a (name, board, trouble_card) triple. Runs
beginner_plan against every entry, prints a stable report:

    name : depth : verb1 / verb2 / ... / verbN

Or `: STUCK` if no plan within budget. Final block is the
depth distribution. Output is deterministic across runs of
the same beginner.py — pipe to a file, `git diff` between
runs.

Usage:
    python3 beginner_corpus.py            # print report
    python3 beginner_corpus.py > out.txt  # snapshot
"""

from collections import Counter

import beginner as b


def _verbs_in(plan):
    out = []
    for line, _ in plan:
        out.append(line.split(" ", 1)[0])
    return out


def canonical_4_8_sweep():
    """Original canonical Claude-Complete sweep: drop each
    of the 52 D2 cards onto the 4/8 deck and ask beginner.py
    to clean it up."""
    deck = b.canonical_deck()
    out = []
    for v in range(1, 14):
        for s in range(4):
            t = (v, s, 1)
            name = f"4_8_sweep/{b.label(t)}:1"
            out.append((name, deck, t))
    return out


def _stack(*labels):
    return [b.card(s) for s in labels]


def gap_cases():
    """Hand-constructed cases targeting known gaps. Each
    case is documented with the verb it's gated on."""
    out = []

    # PUSH gap (expected STUCK until push-onto-set lands):
    # trouble = 8C; only 8C neighbors on the board are the
    # 8-set itself. No 7/9 of any color → pull-only boxed in.
    # The fix is push-onto-set absorbing 8C into the 8-set.
    out.append((
        "push/orphan_onto_existing_set",
        [
            _stack("8D", "8S", "8H"),
            _stack("JC", "JD", "JS", "JH"),
            _stack("KC", "KD", "KS", "KH"),
        ],
        b.card("8C:1"),
    ))

    return out


def all_cases():
    return canonical_4_8_sweep() + gap_cases()


def run():
    cases = all_cases()
    by_depth = Counter()
    print(f"# beginner_corpus: {len(cases)} cases")
    print()

    for name, board, trouble_card in cases:
        full = board + [[trouble_card]]
        plan = b.beginner_plan(full, max_compound=6)
        if plan is None:
            by_depth["stuck"] += 1
            print(f"{name} : STUCK")
            continue
        verbs = _verbs_in(plan)
        by_depth[len(plan)] += 1
        print(f"{name} : {len(plan)} : {' / '.join(verbs)}")

    print()
    print("# depth distribution")
    keys = sorted(by_depth.keys(),
                  key=lambda k: (isinstance(k, str), k))
    for k in keys:
        print(f"#  {k:>5}: {by_depth[k]}")


if __name__ == "__main__":
    run()
