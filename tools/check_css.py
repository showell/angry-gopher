#!/usr/bin/env python3
"""
CSS class-hygiene audit.

Walks every <style>...</style> block in zig-server/src/*.zig, extracts each
.classname token, and checks whether the rest of the repo (zig outside its
own <style> blocks, plus JS / Elm / Markdown / HTML) references it. Any
class with zero references is dead CSS — exits non-zero with a list.

Designed to be the cheap commit-time hygiene check: ~1s, stdlib-only, no
config files. The single escape hatch is the KNOWN_DYNAMIC set below — add
a class there (with a one-line "why") only when its name is composed at
runtime and never appears verbatim in the source.

Scope is intentionally narrow:
  - Class selectors only (not element/attribute/pseudo selectors). Classes
    are >95% of the rot surface.
  - "Is this class referenced anywhere?", not "are any of its declarations
    overridden". Rule-level dead-CSS is a different (harder) problem.
  - Substring search, not a CSS parser. Our class names are distinctive
    enough that this hasn't bitten; if a too-generic name causes a false
    positive, rename it.
"""
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

# Classes whose name is composed at use-site (e.g. JS does `'view-' + v`),
# so a verbatim substring search can't find them. Add ONLY after verifying
# the consumer truly never writes the full name; the comment is the receipt.
KNOWN_DYNAMIC: set[str] = {
    # (empty — every class currently in the CSS appears verbatim somewhere)
}

STYLE_BLOCK = re.compile(r"<style>(.*?)</style>", re.DOTALL)
CLASS_TOKEN = re.compile(r"\.([A-Za-z_][\w-]*)")
SKIP_DIRS = {".git", "node_modules", "elm-stuff"}
CONSUMER_GLOBS = ("*.zig", "*.js", "*.elm", "*.md", "*.html")


def collect_css_classes() -> dict[str, set[str]]:
    """class-name -> set of defining files (relative paths)."""
    defs: dict[str, set[str]] = {}
    for zf in (REPO / "zig-server" / "src").rglob("*.zig"):
        text = zf.read_text()
        for m in STYLE_BLOCK.finditer(text):
            for cm in CLASS_TOKEN.finditer(m.group(1)):
                defs.setdefault(cm.group(1), set()).add(
                    str(zf.relative_to(REPO))
                )
    return defs


def collect_consumer_text() -> str:
    """Concatenate every consumer file; .zig has its <style> blocks stripped
    so a class only counts as 'referenced' if something OUTSIDE the CSS
    source mentions it."""
    chunks: list[str] = []
    for ext in CONSUMER_GLOBS:
        for path in REPO.rglob(ext):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            text = path.read_text(errors="replace")
            if path.suffix == ".zig":
                text = STYLE_BLOCK.sub("", text)
            chunks.append(text)
    return "\n".join(chunks)


def main() -> int:
    defs = collect_css_classes()
    consumers = collect_consumer_text()
    unused: list[tuple[str, list[str]]] = []
    for name in sorted(defs):
        if name in KNOWN_DYNAMIC:
            continue
        # Lookarounds (not \b — \b treats `-` as a boundary, so `chat-msg`
        # would falsely match inside `chat-msg-foo`).
        pat = r"(?<![\w-])" + re.escape(name) + r"(?![\w-])"
        if not re.search(pat, consumers):
            unused.append((name, sorted(defs[name])))
    if unused:
        print(
            f"check_css: {len(unused)} unused class(es) — "
            "delete from CSS, or add to KNOWN_DYNAMIC if composed at runtime:"
        )
        for name, where in unused:
            print(f"  .{name}    [defined in: {', '.join(where)}]")
        return 1
    print(f"check_css: all {len(defs)} CSS classes referenced.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
