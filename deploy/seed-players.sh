#!/bin/bash
# Seeds the LOCAL player store from the chat account store (2026-09-16).
#
# /game and /puzzles no longer resolve identity through the account store — they
# read {data_dir}/players (see zig-server/src/player.zig). Both identities ride
# the same `gopher_uid` cookie, so every returning visitor already presents the
# id their games are filed under; what the new store lacks is their NAME. This
# copies it across, once, so nobody is asked to re-register and no game history
# is orphaned.
#
# READS the account store, WRITES only under the data dir. Idempotent: an
# existing name is left alone, so re-running never overwrites a name someone has
# since changed at /play.
#
# Usage: deploy/seed-players.sh <data_dir> [auth_dir]
#   e.g. deploy/seed-players.sh ~/AngryGopher/prod ~/Auth
set -euo pipefail

DATA="${1:?usage: seed-players.sh <data_dir> [auth_dir]}"
AUTH="${2:-$HOME/Auth}"
PLAYERS="$DATA/players"

[ -d "$AUTH" ] || { echo "no account store at $AUTH" >&2; exit 1; }

mkdir -p "$PLAYERS"

seeded=0
kept=0
for d in "$AUTH"/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    # Account ids are bare decimals; anything else is not an account.
    case "$id" in (*[!0-9]*) continue ;; esac
    [ -f "$d/name" ] || continue

    if [ -f "$PLAYERS/$id/name" ]; then
        kept=$((kept + 1))
        continue
    fi
    mkdir -p "$PLAYERS/$id"
    cp "$d/name" "$PLAYERS/$id/name"
    seeded=$((seeded + 1))
done

# The counter is only ever read for LOCALLY minted ids, which are spelled p<n>
# and so can never collide with the decimal ids seeded above.
[ -f "$PLAYERS/next-id.txt" ] || printf '1\n' > "$PLAYERS/next-id.txt"

echo "Seeded $seeded player(s) from $AUTH, kept $kept already present."
echo "Players with Lyn Rummy data:"
for d in "$DATA"/lynrummy/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    printf '  %-6s %s\n' "$id" "$(cat "$PLAYERS/$id/name" 2>/dev/null || echo '(NO PLAYER ROW — would be asked for a name)')"
done
