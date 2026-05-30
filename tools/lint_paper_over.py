#!/usr/bin/env python3
"""
Paper-over linter for Claude's dialect of JS.

Two rules, both flagging the same antipattern from a different angle:
defensive code that silently absorbs a problem instead of being
transparent when an invariant is broken. The principle: defensive
programming is fine — silent defensive programming hides bugs.

  silent-catch          try{...}catch(_){ return; } or catch(_){} —
                        a thrown exception is swallowed with no log,
                        no rethrow, no side effect.

  null-undefined-check  x === null / x !== null / x == undefined / etc.
                        Catches the explicit null-or-undefined guard
                        pattern. Half of these are real "absence is
                        legitimate" sentinels; half are paper-over for
                        an invariant that holds. Reading the call site
                        is the only way to tell, and that's the point.

Escape hatches, in order of preference:

  1. Allowlist (preferred). Two small allowlists at the top of this file:

       SILENT_CATCH_METHOD_ALLOWLIST    method names whose browser-API
                                        contract documents the throw
       NULL_CHECK_PROPERTY_ALLOWLIST    DOM property names whose API
                                        contract returns null as a
                                        legitimate value

     A try block whose every top-level statement is a method call
     against an allowlisted method, or a null-check whose other side is
     a member access on an allowlisted property, passes.

  2. Inline `lint:<rule-name> <reason>` comment annotation on the
     same line as the violation. Required reason — at least one
     whitespace-separated word after the rule name. The reason is the
     contract the next reader is held to; rotting it is the next
     reader's job.

Run zero-arg: parses chat/*.js, prints `file:line:col: <rule>: <src>`
for each violation, exits 1 on any. Allowlist + annotation expansions
happen here, not at the lint script's call site.
"""

import re
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import jsparse

REPO = pathlib.Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# Allowlists. Each entry is one line: name, then a comment giving the
# documented browser/DOM behavior that makes the pattern non-silencing.
# Adding to these lists is a deliberate act — when in doubt, prefer the
# inline `lint:` annotation so the receipt sits at the call site.
# ---------------------------------------------------------------------------

SILENT_CATCH_METHOD_ALLOWLIST = {
    # pointer-capture: throws if the pointer isn't capturable (already
    # released, foreign target). The contract is "best effort"; there's
    # no recovery action.
    "setPointerCapture",
    "releasePointerCapture",
}

NULL_CHECK_PROPERTY_ALLOWLIST = {
    # DOM `offsetParent` is null when the element is display:none (or
    # detached). Code checking it for null is reading the documented
    # "is this rendered?" signal.
    "offsetParent",
}


# ---------------------------------------------------------------------------
# Annotation matcher. `lint:<rule-name> <reason>` inside any comment.
# Reason is required — without it the line stays flagged.
# ---------------------------------------------------------------------------

LINT_ANNOTATION_RE = re.compile(r"lint:([\w-]+)\s+([\w-]+)")


def has_lint_annotation(line_text: str, rule: str) -> bool:
    """A `lint:<rule> <reason>` annotation exempts the line. The reason
    must be `[\\w-]+` (alphanumeric + hyphens — slug-style) so a stray
    `*/` or punctuation can't accidentally count."""
    for m in LINT_ANNOTATION_RE.finditer(line_text):
        if m.group(1) == rule:
            return True
    return False


# ---------------------------------------------------------------------------
# Rule checkers. Each returns a violation dict or None.
# ---------------------------------------------------------------------------

def check_silent_catch(try_node, lines, path):
    h = try_node["handler"]
    if h is None:
        return None
    body = h["body"]["body"]
    is_silent = (
        len(body) == 0
        or (len(body) == 1 and body[0]["kind"] == "Return")
    )
    if not is_silent:
        return None
    if _try_calls_only_allowlisted(try_node["block"], SILENT_CATCH_METHOD_ALLOWLIST):
        return None
    line, col = try_node["loc"]
    src = lines[line - 1].strip()
    if has_lint_annotation(lines[line - 1], "silent-catch"):
        return None
    return {
        "rule": "silent-catch", "file": path,
        "line": line, "col": col, "src": src,
    }


def _try_calls_only_allowlisted(block_node, allowlist):
    """True iff every top-level statement in `block_node`'s body is an
    expression statement whose outermost call is a member call against
    an allowlisted method name. Strict on purpose — a try that wraps an
    allowlisted call AND something else stays flagged."""
    body = block_node["body"]
    if not body:
        return False  # empty try block is not auto-allowed
    for stmt in body:
        if stmt["kind"] != "Expression":
            return False
        expr = stmt["expr"]
        if expr["kind"] != "Call":
            return False
        callee = expr["callee"]
        if callee["kind"] != "Member" or callee["computed"]:
            return False
        if callee["property"] not in allowlist:
            return False
    return True


def check_null_undefined(binary_node, lines, path):
    if binary_node["op"] not in ("===", "!==", "==", "!="):
        return None
    left = binary_node["left"]
    right = binary_node["right"]
    if left["kind"] in ("Null", "Undefined"):
        other = right
    elif right["kind"] in ("Null", "Undefined"):
        other = left
    else:
        return None
    # Allowlist: comparing a DOM-contract null property.
    if other["kind"] == "Member" and not other["computed"]:
        if other["property"] in NULL_CHECK_PROPERTY_ALLOWLIST:
            return None
    line, col = binary_node["loc"]
    src = lines[line - 1].strip()
    if has_lint_annotation(lines[line - 1], "null-undefined-check"):
        return None
    return {
        "rule": "null-undefined-check", "file": path,
        "line": line, "col": col, "src": src,
    }


# ---------------------------------------------------------------------------
# File walker + driver
# ---------------------------------------------------------------------------

def find_violations(path: pathlib.Path) -> list[dict]:
    src = path.read_text()
    lines = src.splitlines()
    prog = jsparse.parse(src)
    out: list[dict] = []
    for node in jsparse.walk(prog):
        if node["kind"] == "Try":
            v = check_silent_catch(node, lines, path)
            if v: out.append(v)
        elif node["kind"] == "Binary":
            v = check_null_undefined(node, lines, path)
            if v: out.append(v)
    return out


def main() -> int:
    files = sorted((REPO / "chat").glob("*.js"))
    all_violations: list[dict] = []
    for path in files:
        all_violations.extend(find_violations(path))
    all_violations.sort(key=lambda v: (str(v["file"]), v["line"], v["col"]))
    for v in all_violations:
        rel = v["file"].relative_to(REPO)
        print(f"{rel}:{v['line']}:{v['col']}: {v['rule']}: {v['src']}")
    if all_violations:
        from collections import Counter
        by_rule = Counter(v["rule"] for v in all_violations)
        print(file=sys.stderr)
        print(f"{len(all_violations)} paper-over violation(s):", file=sys.stderr)
        for rule, count in sorted(by_rule.items()):
            print(f"  {count:3d} {rule}", file=sys.stderr)
        print(file=sys.stderr)
        print("Exemption options: add to the allowlist at the top of", file=sys.stderr)
        print("tools/lint_paper_over.py, or annotate the line with", file=sys.stderr)
        print("`// lint:<rule-name> <reason>`.", file=sys.stderr)
        return 1
    print(f"No paper-over violations across {len(files)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
