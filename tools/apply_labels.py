#!/usr/bin/env python3
"""apply_labels — write per-file DX labels into .claude companions,
and emit a top-level LABELS.md index.

Each Go source file gets a sibling .claude file (creating one if
needed — passthrough `just_use` directive). The label lives in a
single `# label: LABEL_NAME` comment line inside the .claude.

Re-run whenever labels change. Idempotent.

The label assignments here are Claude's gut reactions from the
2026-04-14 triage pass. Labels are advisory, not authoritative —
edit freely.
"""

import os
import re
from pathlib import Path
from collections import defaultdict

REPO = Path("/home/steve/showell_repos/angry-gopher")

# Label assignments per Go source file. Keys are repo-relative
# paths. Files not listed here are left untouched.
#
# Canonical label set (13): WORKHORSE, TOOL, ELEGANT, CLEAN_INFRA,
# INTRICATE, TINY, CANONICAL, SIMPLE, GENERATED, SCAFFOLD,
# SPRAWLING, ONE_OFF, ROUTER.
LABELS = {
    # Entry points + top-level wiring
    "main.go":             "ONE_OFF",
    "admin.go":            "ROUTER",
    "admin_auth.go":       "CLEAN_INFRA",
    "admin_ops.go":        "WORKHORSE",
    "admin_tables.go":     "WORKHORSE",
    "config.go":           "SIMPLE",
    "db.go":               "CANONICAL",
    "markdown.go":         "CLEAN_INFRA",
    "routes.go":           "SCAFFOLD",

    # Auth / core packages
    "auth/auth.go":                "TINY",
    "channels/channels.go":        "WORKHORSE",
    "dm/dm.go":                    "WORKHORSE",
    "events/events.go":            "CANONICAL",
    "flags/flags.go":              "WORKHORSE",
    "games/games.go":              "WORKHORSE",
    "games/plays.go":              "WORKHORSE",
    "messages/messages.go":        "WORKHORSE",
    "presence/presence.go":        "CLEAN_INFRA",
    "ratelimit/ratelimit.go":      "CLEAN_INFRA",
    "reactions/reactions.go":      "CLEAN_INFRA",
    "respond/respond.go":          "TINY",
    "schema/schema.go":            "CANONICAL",
    "search/search.go":            "WORKHORSE",
    "users/admin.go":              "WORKHORSE",
    "users/users.go":              "WORKHORSE",

    # LynRummy domain
    "lynrummy/board_geometry.go":       "ELEGANT",
    "lynrummy/card.go":                 "ELEGANT",
    "lynrummy/card_stack.go":           "ELEGANT",
    "lynrummy/dealer.go":               "ELEGANT",
    "lynrummy/events.go":               "ELEGANT",
    "lynrummy/referee.go":              "ELEGANT",
    "lynrummy/stack_type.go":           "ELEGANT",
    "lynrummy/tricks/detect.go":        "SIMPLE",
    "lynrummy/tricks/direct_play.go":   "SIMPLE",
    "lynrummy/tricks/hand_stacks.go":   "INTRICATE",
    "lynrummy/tricks/helpers.go":       "CLEAN_INFRA",
    "lynrummy/tricks/loose_card_play.go": "INTRICATE",
    "lynrummy/tricks/pair_peel.go":     "INTRICATE",
    "lynrummy/tricks/peel_for_run.go":  "INTRICATE",
    "lynrummy/tricks/rb_swap.go":       "INTRICATE",
    "lynrummy/tricks/split_for_set.go": "INTRICATE",
    "lynrummy/tricks/trick.go":         "TINY",

    # Views
    "views/channels.go":      "WORKHORSE",
    "views/dm.go":            "WORKHORSE",
    "views/games.go":         "WORKHORSE",
    "views/games_replay.go":  "ONE_OFF",
    "views/helpers.go":       "CANONICAL",
    "views/messages.go":      "WORKHORSE",
    "views/quicknav.go":      "TINY",
    "views/recent.go":        "TINY",
    "views/registry.go":      "CANONICAL",
    "views/registry_generated.go": "GENERATED",
    "views/search.go":        "WORKHORSE",
    "views/sse.go":           "CANONICAL",
    "views/starred.go":       "TINY",
    "views/tour.go":          "TINY",
    "views/unread.go":        "TINY",
    "views/users.go":         "WORKHORSE",

    # Tools
    "cmd/bench_cache/main.go":     "TOOL",
    "cmd/bench_hydrate/main.go":   "TOOL",
    "cmd/bench_or/main.go":        "TOOL",
    "cmd/bench_planner/main.go":   "TOOL",
    "cmd/bench_render/main.go":    "TOOL",
    "cmd/bench_search/main.go":    "TOOL",
    "cmd/bench_split/main.go":     "TOOL",
    "cmd/bench_throughput/main.go": "TOOL",
    "cmd/crudgen/main.go":         "SPRAWLING",
    "cmd/db_query/main.go":        "TOOL",
    "cmd/fixturegen/main.go":      "TOOL",
    "cmd/gen_nav/main.go":         "TOOL",
    "cmd/gen_test_data/main.go":   "TOOL",
    "cmd/health_check/main.go":    "TOOL",
    "cmd/import/main.go":          "ONE_OFF",
    "cmd/stress/main.go":          "TOOL",
}

LABEL_DESCRIPTIONS = {
    "WORKHORSE":  "Ugly but productive. Don't polish, just modify. Edits are easy enough; aesthetic improvements rarely pay.",
    "TOOL":       "Stand-alone utility, diagnostic, or benchmark. Low-stakes; edits ripple nowhere.",
    "ELEGANT":    "Clean and exemplary. Match the style when editing. Use as an example for new work.",
    "CLEAN_INFRA": "Well-factored plumbing. Focused, small, self-contained. Don't bloat it.",
    "INTRICATE":  "Algorithmically dense. Read carefully before editing; test rigorously.",
    "TINY":       "So small the whole thing fits in your head. Edits are trivial; bugs are rare.",
    "CANONICAL":  "Single source of truth for something other code depends on. Edits ripple widely.",
    "SIMPLE":     "Short and obvious. Like TINY but with a bit more going on.",
    "GENERATED":  "Produced by a tool. Do NOT hand-edit; regenerate instead.",
    "SCAFFOLD":   "Wires things together. Easy to miss a connection; trace carefully.",
    "SPRAWLING":  "Big and still growing. Work-in-progress surface area; shape not settled.",
    "ONE_OFF":    "Genuinely unique in this repo. No pattern to match; accept its idiosyncrasy.",
    "ROUTER":     "Top-level dispatcher. Delegates to sub-handlers; low logic density.",
}

LABEL_RE = re.compile(r"^#\s*label\s*:.*$", re.MULTILINE)


def ensure_claude(go_path: Path, label: str) -> str:
    """Create or update the .claude companion. Returns the action
    taken: 'created', 'updated', or 'unchanged'."""
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
    # No label line yet. Append one.
    if existing and not existing.endswith("\n"):
        existing += "\n"
    existing += f"\n# label: {label}\n"
    claude_path.write_text(existing)
    return "updated"


def emit_index() -> str:
    """Generate LABELS.md grouping files by label."""
    by_label: dict[str, list[str]] = defaultdict(list)
    for path, label in sorted(LABELS.items()):
        by_label[label].append(path)

    order = [
        "CANONICAL", "ELEGANT", "CLEAN_INFRA", "SIMPLE", "TINY",
        "INTRICATE", "WORKHORSE",
        "SCAFFOLD", "ROUTER", "GENERATED",
        "TOOL", "SPRAWLING", "ONE_OFF",
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
