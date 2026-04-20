#!/usr/bin/env python3
"""apply_labels — write per-file DX labels into .claude companions,
and emit a top-level LABELS.md index.

Each Go source file gets a sibling .claude file (creating one if
needed — passthrough `just_use` directive). The label lives in a
single `# label: LABEL_NAME` comment line inside the .claude.

Re-run whenever labels change. Idempotent.
"""

import re
from pathlib import Path
from collections import defaultdict

REPO = Path("/home/steve/showell_repos/angry-gopher")

# Label assignments per Go source file. Keys are repo-relative
# paths. Files not listed here are left untouched.
LABELS = {
    # Entry points + top-level wiring
    "main.go":             "ONE_OFF",
    "admin.go":            "ROUTER",
    "admin_auth.go":       "CLEAN_INFRA",
    "admin_ops.go":        "WORKHORSE",
    "admin_tables.go":     "WORKHORSE",
    "config.go":           "SIMPLE",
    "db.go":               "CANONICAL",

    # Auth
    "auth/auth.go":              "TINY",
    "schema/schema.go":          "CANONICAL",

    # LynRummy domain
    "games/lynrummy/board_geometry.go":     "ELEGANT",
    "games/lynrummy/card.go":               "ELEGANT",
    "games/lynrummy/card_stack.go":         "ELEGANT",
    "games/lynrummy/dealer.go":             "ELEGANT",
    "games/lynrummy/events.go":             "ELEGANT",
    "games/lynrummy/hand.go":               "WORKHORSE",
    "games/lynrummy/referee.go":            "ELEGANT",
    "games/lynrummy/replay.go":             "WORKHORSE",
    "games/lynrummy/score.go":              "WORKHORSE",
    "games/lynrummy/stack_type.go":         "ELEGANT",
    "games/lynrummy/turn_result.go":        "EARLY",
    "games/lynrummy/wire_action.go":        "WORKHORSE",

    # Views
    "views/claude_landing.go":      "EARLY",
    "views/games.go":               "WORKHORSE",
    "views/helpers.go":              "CANONICAL",
    "views/lynrummy_elm.go":         "SPIKE",
    "views/quicknav.go":             "TINY",
    "views/registry.go":             "CANONICAL",
    "views/registry_generated.go":  "GENERATED",
    "views/tour.go":                 "TINY",
    "views/wiki.go":                 "EARLY",

    # Tools
    "cmd/crudgen/main.go":    "SPRAWLING",
    "cmd/db_query/main.go":   "TOOL",
    "cmd/fixturegen/main.go": "TOOL",
    "cmd/reorg/main.go":      "VESTIGIAL",
}

LABEL_DESCRIPTIONS = {
    "CANONICAL":  "Single source of truth for something other code depends on. Edits ripple widely.",
    "ELEGANT":    "Clean and exemplary. Match the style when editing. Use as an example for new work.",
    "CLEAN_INFRA": "Well-factored plumbing. Focused, small, self-contained. Don't bloat it.",
    "SIMPLE":     "Short and obvious. Like TINY but with a bit more going on.",
    "TINY":       "So small the whole thing fits in your head. Edits are trivial; bugs are rare.",
    "INTRICATE":  "Algorithmically dense. Read carefully before editing; test rigorously.",
    "WORKHORSE":  "Ugly but productive. Don't polish, just modify.",
    "EARLY":      "Kept but not yet stable — survived past SPIKE, still learning its shape.",
    "SPIKE":      "New exploratory work. Expect churn; don't build on top of it yet.",
    "ROUTER":     "Top-level dispatcher. Delegates to sub-handlers; low logic density.",
    "GENERATED":  "Produced by a tool. Do NOT hand-edit; regenerate instead.",
    "TOOL":       "Stand-alone utility, diagnostic, or benchmark. Low-stakes.",
    "SPRAWLING":  "Big and still growing. Work-in-progress surface area.",
    "ONE_OFF":    "Genuinely unique in this repo. No pattern to match.",
    "VESTIGIAL": "Kept for reference; not actively used. Safe to delete when the last reader is gone.",
}

LABEL_RE = re.compile(r"^#\s*label\s*:.*$", re.MULTILINE)


def ensure_claude(go_path: Path, label: str) -> str:
    claude_path = go_path.with_suffix(".claude")
    stem = go_path.name

    if not claude_path.exists():
        content = f"just_use {stem}\n\n# label: {label}\n"
        claude_path.write_text(content)
        return "created"

    existing = claude_path.read_text()
    new_line = f"# label: {label}"
    if LABEL_RE.search(existing):
        if LABEL_RE.search(existing).group(0).strip() == new_line:
            return "unchanged"
        updated = LABEL_RE.sub(new_line, existing, count=1)
        claude_path.write_text(updated)
        return "updated"
    if existing and not existing.endswith("\n"):
        existing += "\n"
    existing += f"\n# label: {label}\n"
    claude_path.write_text(existing)
    return "updated"


def emit_index() -> str:
    by_label: dict[str, list[str]] = defaultdict(list)
    for path, label in sorted(LABELS.items()):
        by_label[label].append(path)

    order = [
        "CANONICAL", "ELEGANT", "CLEAN_INFRA", "SIMPLE", "TINY",
        "INTRICATE", "WORKHORSE", "EARLY", "SPIKE",
        "ROUTER", "GENERATED",
        "TOOL", "SPRAWLING", "ONE_OFF", "VESTIGIAL",
    ]

    out = []
    out.append("# Module label index\n")
    out.append("Generated by `tools/apply_labels.py`. Re-run after label edits.\n")
    out.append("Labels describe *developer experience*, not function — see")
    out.append("`tools/apply_labels.py` docstring for full definitions.\n")

    for label in order:
        if label not in by_label:
            continue
        desc = LABEL_DESCRIPTIONS.get(label, "")
        out.append(f"## {label}  ({len(by_label[label])})")
        if desc:
            out.append(f"*{desc}*\n")
        for p in by_label[label]:
            out.append(f"- `{p}`")
        out.append("")

    out.append("---\n")
    out.append(f"Total labeled files: **{sum(len(v) for v in by_label.values())}**")
    out.append(f"Distinct labels in use: **{len(by_label)}**")
    out.append("")
    return "\n".join(out)


def main() -> None:
    tally = defaultdict(int)
    for rel, label in LABELS.items():
        path = REPO / rel
        if not path.exists():
            print(f"MISSING: {rel}")
            continue
        action = ensure_claude(path, label)
        tally[action] += 1

    print(f"created:   {tally['created']}")
    print(f"updated:   {tally['updated']}")
    print(f"unchanged: {tally['unchanged']}")

    index_path = REPO / "LABELS.md"
    index_path.write_text(emit_index())
    print(f"wrote:     {index_path}")


if __name__ == "__main__":
    main()
