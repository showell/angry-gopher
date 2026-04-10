#!/bin/bash
# Run tests with coverage, filtering out exempted files.
#
# Exempted files are listed below. These are either admin/debug
# tools or import utilities with natural integration checks.

EXEMPT=(
    "angry-gopher/admin.go"
    "angry-gopher/cmd/import/main.go"
    "angry-gopher/config.go"
)

set -e

PROFILE=$(mktemp /tmp/cover.XXXXXX)
trap "rm -f $PROFILE ${PROFILE}.filtered" EXIT

cd "$(dirname "$0")"

go test -coverpkg=./... -coverprofile="$PROFILE" ./... 2>&1 \
    | grep -v "^warning:"

# Build a grep pattern that excludes exempted files.
FILTER=""
for f in "${EXEMPT[@]}"; do
    FILTER="${FILTER}|${f}"
done
FILTER="${FILTER:1}"  # strip leading |

# Keep the header (mode: line) and drop exempted files.
head -1 "$PROFILE" > "${PROFILE}.filtered"
tail -n +2 "$PROFILE" | grep -Ev "^(${FILTER})" >> "${PROFILE}.filtered"

echo ""
echo "=== Coverage (exemptions: ${#EXEMPT[@]} files) ==="
go tool cover -func="${PROFILE}.filtered" 2>&1 \
    | grep -v "^warning:"
