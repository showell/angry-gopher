# Shared sandbox lifecycle for the leak stress harness. Sourced by ops/stress and
# ops/stress_selftest (after _paths.sh, which sets GOPHER_DIR).
#
# Spins a HERMETIC server instance in a /tmp sandbox on a side port (GOPHER_PORT),
# so the real :9001 dev server and the real local data tree are never touched. The
# harness reads GOPHER_PORT too, so it hammers the sandbox instance.
#
#   stress_sandbox_up [zig-build-args...]   build + launch the sandbox server
#                                           (callers pass e.g. -Dfake_leak=true);
#                                           sets SANDBOX_DIR, SERVER_PID; exports
#                                           GOPHER_PORT.
#   stress_sandbox_down                     kill the server, remove the sandbox.
#
# Pair stress_sandbox_down with a `trap ... EXIT` so a crash still tears down.

STRESS_PORT="${STRESS_PORT:-9002}"

stress_fail() { echo "stress: $1" >&2; exit 2; }

stress_sandbox_up() {
    # /tmp is assumed to exist with ample space; fail loudly if that's not true.
    { [ -d /tmp ] && [ -w /tmp ]; } || stress_fail "/tmp is missing or not writable — the harness needs a sandbox there."
    SANDBOX_DIR="$(mktemp -d /tmp/gopher-stress.XXXXXX)" || stress_fail "could not create a /tmp sandbox directory."

    # A throwaway data + auth tree. The session secret is opaque random bytes (no
    # schema, so nothing to drift) — needed once the harness registers a member.
    mkdir -p "$SANDBOX_DIR/data/chat" "$SANDBOX_DIR/auth"
    head -c 32 /dev/urandom > "$SANDBOX_DIR/data/chat/_session_secret"
    cat > "$SANDBOX_DIR/gopher.conf" <<EOF
data_dir = $SANDBOX_DIR/data
auth_dir = $SANDBOX_DIR/auth
EOF

    # The server @embedFiles the front-end bundles, so build them first. Build the
    # harness into zig-out, and the server into the sandbox (so a -Dfake_leak build
    # never clobbers the real zig-out/bin/zig-server, and it's auto-cleaned).
    ( cd "$GOPHER_DIR/zig-server" \
        && "$GOPHER_DIR/ops/build_safari_wasm" \
        && "$GOPHER_DIR/ops/build_elm" \
        && zig build stress \
        && zig build "$@" -p "$SANDBOX_DIR/srv" )

    # Launch from the repo root so the read-only blog/posts default resolves; point
    # data + auth at the sandbox; listen on the side port.
    lsof -ti:"$STRESS_PORT" | xargs kill -9 2>/dev/null || true
    ( cd "$GOPHER_DIR" \
        && GOPHER_PORT="$STRESS_PORT" GOPHER_CONFIG="$SANDBOX_DIR/gopher.conf" \
           nohup "$SANDBOX_DIR/srv/bin/zig-server" > "$SANDBOX_DIR/server.log" 2>&1 & echo $! > "$SANDBOX_DIR/server.pid" )
    SERVER_PID="$(cat "$SANDBOX_DIR/server.pid")"
    export GOPHER_PORT="$STRESS_PORT"

    for _ in $(seq 1 20); do
        curl -s "http://localhost:$STRESS_PORT/debug/mem" >/dev/null 2>&1 && return 0
        kill -0 "$SERVER_PID" 2>/dev/null || stress_fail "sandbox server died on startup — see $SANDBOX_DIR/server.log"
        sleep 0.3
    done
    stress_fail "sandbox server never answered on :$STRESS_PORT — see $SANDBOX_DIR/server.log"
}

stress_sandbox_down() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "${STRESS_PORT:-}" ] && { lsof -ti:"$STRESS_PORT" | xargs kill -9 2>/dev/null || true; }
    [ -n "${SANDBOX_DIR:-}" ] && rm -rf "$SANDBOX_DIR"
}
