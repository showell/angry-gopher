# Shared path discovery for ops scripts.
#
# Sourced by other scripts. Sets:
#   GOPHER_DIR — angry-gopher repo root (derived from this file's location)
#   CAT_DIR    — angry-cat repo root (sibling of angry-gopher by default,
#                overridable via CAT_DIR env var)
#
# Apoorva or anyone else who clones these repos side-by-side doesn't
# need to edit anything — the scripts work from any install location.

GOPHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAT_DIR="${CAT_DIR:-$(dirname "$GOPHER_DIR")/angry-cat}"

# Sanity: GOPHER_DIR is derived from THIS file's location (not cwd), so an ops
# script works from any directory — but if the layout is broken (file moved, no
# repo root), fail loudly here rather than silently operating on the wrong tree.
# The marker is zig-server/build.zig (committed, Go-independent) so this keeps
# working when the old Go tree (go.mod) is removed.
if [ ! -f "$GOPHER_DIR/zig-server/build.zig" ]; then
    echo "ops: cannot locate the angry-gopher repo root (no zig-server/build.zig at '$GOPHER_DIR')" >&2
    exit 1
fi
