#!/bin/bash
# One-time migration to numeric user ids (2026-05-23).
#
# Maps the two real accounts to ids — Steve=1 (admin), apoorva=2 — copies
# their bcrypt password hashes from chat/_members into the new user
# registry, rekeys their game + chat data, and wipes every other trace.
# Idempotent-ish (guards on existence); safe to re-run.
#
# Usage: deploy/migrate-userids.sh <data_dir>
#   e.g. deploy/migrate-userids.sh ~/AngryGopher/prod
set -euo pipefail

DATA="${1:?usage: migrate-userids.sh <data_dir>}"
LYN="$DATA/lynrummy"
CHAT="$DATA/chat"
USERS="$DATA/users"

echo "Migrating $DATA to user ids..."

# 1. User registry: Steve=1 (admin), apoorva=2.
mkdir -p "$USERS/1" "$USERS/2"
printf 'Steve'   > "$USERS/1/name"
printf 'apoorva' > "$USERS/2/name"
[ -f "$CHAT/_members/Steve" ]   && { cp "$CHAT/_members/Steve"   "$USERS/1/password"; chmod 600 "$USERS/1/password"; }
[ -f "$CHAT/_members/apoorva" ] && { cp "$CHAT/_members/apoorva" "$USERS/2/password"; chmod 600 "$USERS/2/password"; }
printf '1\n' > "$USERS/1/admin"
printf '3\n' > "$USERS/next-id.txt"

# 2. Rekey game data by id.
[ -d "$LYN/Steve" ]   && mv "$LYN/Steve"   "$LYN/1"
[ -d "$LYN/apoorva" ] && mv "$LYN/apoorva" "$LYN/2"

# 3. Rekey the Steve<->apoorva conversation (old key: apoorva_Steve) to 1_2.
[ -d "$CHAT/apoorva_Steve" ] && mv "$CHAT/apoorva_Steve" "$CHAT/1_2"

# 4. Wipe every other trace.
#    lynrummy: keep only the migrated ids 1 and 2.
if [ -d "$LYN" ]; then
  for d in "$LYN"/*; do
    [ -e "$d" ] || continue
    b="$(basename "$d")"
    [ "$b" = "1" ] || [ "$b" = "2" ] || rm -rf "$d"
  done
fi
#    chat: keep only the 1_2 conversation and the session secret.
if [ -d "$CHAT" ]; then
  for d in "$CHAT"/*; do
    [ -e "$d" ] || continue
    b="$(basename "$d")"
    [ "$b" = "1_2" ] || [ "$b" = "_session_secret" ] || rm -rf "$d"
  done
fi

echo "Done. Registry:"
for id in 1 2; do
  printf '  user %s: name=%s member=%s admin=%s\n' "$id" \
    "$(cat "$USERS/$id/name" 2>/dev/null)" \
    "$([ -f "$USERS/$id/password" ] && echo yes || echo no)" \
    "$([ -f "$USERS/$id/admin" ] && echo yes || echo no)"
done
