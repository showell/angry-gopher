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
