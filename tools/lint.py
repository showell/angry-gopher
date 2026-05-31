#!/usr/bin/env python3
"""
Linter for Claude's dialect of JS, riding on tools/jsparse.py's AST.

The point is to automate the kinds of checks Steve already does by
grep — without comment-text false positives — and add a couple of
patterns grep can't easily express (like "every name in the AST that's
declared but never used").

Three rules today:

  silent-catch          try{...}catch(_){ return; } or catch(_){} —
                        a thrown exception is swallowed with no log,
                        no rethrow, no side effect.

  null-undefined-check  x === null / x !== null / x == undefined / etc.
                        Catches the explicit null-or-undefined guard
                        pattern. Half of these are real "absence is
                        legitimate" sentinels; half are paper-over for
                        an invariant that holds — reading the call site
                        is the only way to tell, and that's the point.

  dead-code             A `function foo(){...}` or `var foo=...` whose
                        name is never referenced as a free identifier
                        anywhere else in the same file. (Member access
                        `x.foo` doesn't count — different namespace.)
                        Per-file, not per-scope; shadowing is rare in
                        this dialect, and a false positive is cheaper
                        than the scope analysis would be.

  called-once           A `function foo(){...}` whose name appears
                        exactly once elsewhere — i.e. it has a single
                        call site. Usually a candidate for inlining
                        (the indirection costs a hop without naming a
                        non-obvious concept; see
                        games/lynrummy/BOUNDARIES.md). Exempted when
                        the single reference is via an IIFE export
                        object (`return { foo: foo }` = key + value =
                        2 references, so exports don't fire).

Escape hatches, in order of preference:

  1. Allowlist (preferred). Small named sets at the top of this file:

       SILENT_CATCH_METHOD_ALLOWLIST    method names whose browser-API
                                        contract documents the throw
       NULL_CHECK_PROPERTY_ALLOWLIST    DOM property names whose API
                                        contract returns null as a
                                        legitimate value
       DEAD_CODE_NAME_ALLOWLIST         identifier names that are only
                                        referenced dynamically (a rare
                                        breed in this codebase)

  2. Inline `lint:<rule-name> <reason>` comment annotation on the
     same line as the violation. Required reason — one alphanumeric
     word minimum. The reason is the contract the next reader is held
     to; rotting it is the next reader's job.

Run zero-arg: parses chat/*.js, prints `file:line:col: <rule>: <msg>`
for each violation, exits 1 on any. Allowlist + annotation expansions
happen here, not at the script's call site.
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

DEAD_CODE_NAME_ALLOWLIST: set[str] = {
    # Add here only when an identifier is referenced dynamically (e.g.
    # called via a string name through an event-handler-attribute, or
    # picked up by reflection). Each addition gets a comment with the
    # actual receipt.
}

CALLED_ONCE_NAME_ALLOWLIST: set[str] = {
    # Add here only when the single-call function is genuinely
    # load-bearing for naming an abstraction (the name IS the
    # documentation), not just a convenience wrapper. Each addition
    # gets a comment.
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


def line_or_predecessor_annotation(lines: list[str], line_num: int, rule: str) -> bool:
    """Annotations may live on the same line as the violation (trailing
    comment) OR on the line immediately above (leading comment). Both
    forms read naturally."""
    if has_lint_annotation(lines[line_num - 1], rule):
        return True
    if line_num >= 2 and has_lint_annotation(lines[line_num - 2], rule):
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
    if line_or_predecessor_annotation(lines, line, "silent-catch"):
        return None
    return {
        "rule": "silent-catch", "file": path,
        "line": line, "col": col, "msg": src,
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
    if line_or_predecessor_annotation(lines, line, "null-undefined-check"):
        return None
    return {
        "rule": "null-undefined-check", "file": path,
        "line": line, "col": col, "msg": src,
    }


def check_dead_code(prog, lines, path):
    """Per-file scan: collect every FunctionDecl + VarDeclarator name,
    collect every Identifier reference, flag declarations whose name has
    no Identifier site anywhere in the file. Per-file (not per-scope) on
    purpose — this dialect rarely shadows, and the few false positives
    are cheaper than the scope analysis would be."""
    decls: list[tuple[str, str, dict]] = []  # (kind_label, name, loc)
    used: set[str] = set()
    for n in jsparse.walk(prog):
        if n["kind"] == "FunctionDecl":
            decls.append(("function", n["name"], n["loc"]))
        elif n["kind"] == "VarDeclarator":
            decls.append(("var", n["name"], n["loc"]))
        elif n["kind"] == "Identifier":
            used.add(n["name"])
    out = []
    for decl_kind, name, (line, col) in decls:
        if name in used:
            continue
        if name in DEAD_CODE_NAME_ALLOWLIST:
            continue
        if line_or_predecessor_annotation(lines, line, "dead-code"):
            continue
        out.append({
            "rule": "dead-code", "file": path,
            "line": line, "col": col,
            "msg": f"{decl_kind} '{name}' declared but never referenced  |  {lines[line - 1].strip()}",
        })
    return out


# ---------------------------------------------------------------------------
# File walker + driver
# ---------------------------------------------------------------------------

def _walk_with_parents(node, parent=None):
    """Like jsparse.walk but yields (node, parent) so checks can ask
    about syntactic context (e.g. is this Identifier the callee of a
    Call, or just one of its args / a property value)."""
    if isinstance(node, dict) and "kind" in node:
        yield node, parent
        for v in node.values():
            yield from _walk_with_parents(v, node)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_with_parents(item, parent)


def check_called_once(prog, lines, path):
    """Flag every FunctionDecl that has exactly ONE direct call site and
    no other references. "Direct call" = Identifier appears as a Call's
    callee (`foo()`); callback uses (`addEventListener('x', foo)`),
    property values (`{ x: foo }`), and timer arguments (`setTimeout(foo)`)
    don't count as direct calls and naturally exempt callbacks from
    firing. See games/lynrummy/BOUNDARIES.md diagnostic 3 for the
    inline-vs-extract calibration."""
    from collections import Counter
    decls: list[tuple[str, dict]] = []
    direct_calls: Counter[str] = Counter()
    all_refs:    Counter[str] = Counter()
    for n, parent in _walk_with_parents(prog):
        if not isinstance(n, dict): continue
        if n.get("kind") == "FunctionDecl":
            decls.append((n["name"], n["loc"]))
        elif n.get("kind") == "Identifier":
            name = n["name"]
            all_refs[name] += 1
            if (parent is not None
                    and parent.get("kind") == "Call"
                    and parent.get("callee") is n):
                direct_calls[name] += 1
    out = []
    for name, (line, col) in decls:
        if direct_calls[name] != 1 or all_refs[name] != 1:
            continue
        if name in CALLED_ONCE_NAME_ALLOWLIST:
            continue
        if line_or_predecessor_annotation(lines, line, "called-once"):
            continue
        out.append({
            "rule": "called-once", "file": path,
            "line": line, "col": col,
            "msg": f"function '{name}' called exactly once  |  {lines[line - 1].strip()}",
        })
    return out


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
    out.extend(check_dead_code(prog, lines, path))
    out.extend(check_called_once(prog, lines, path))
    return out


def main() -> int:
    files = sorted((REPO / "chat").glob("*.js"))
    all_violations: list[dict] = []
    for path in files:
        all_violations.extend(find_violations(path))
    all_violations.sort(key=lambda v: (str(v["file"]), v["line"], v["col"]))
    for v in all_violations:
        rel = v["file"].relative_to(REPO)
        print(f"{rel}:{v['line']}:{v['col']}: {v['rule']}: {v['msg']}")
    if all_violations:
        from collections import Counter
        by_rule = Counter(v["rule"] for v in all_violations)
        print(file=sys.stderr)
        print(f"{len(all_violations)} lint violation(s):", file=sys.stderr)
        for rule, count in sorted(by_rule.items()):
            print(f"  {count:3d} {rule}", file=sys.stderr)
        print(file=sys.stderr)
        print("Exemption options: add to the allowlist at the top of", file=sys.stderr)
        print("tools/lint.py, or annotate the line with", file=sys.stderr)
        print("`// lint:<rule-name> <reason>`.", file=sys.stderr)
        return 1
    print(f"No lint violations across {len(files)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
