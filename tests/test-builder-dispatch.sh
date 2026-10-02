#!/usr/bin/env bash
# Checks builder_dispatch's runtime-resolution guard: a forced-native build (DUPLO_BUILD_NATIVE=1, which
# is exactly what the builder container's own compose environment sets — see docker-compose.yml's
# `builder` service) must never fail because of a $RUNTIME value it has no intention of using.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "builder_dispatch native-skip guard:"

# dispatch_rc <RUNTIME value> <DUPLO_BUILD_NATIVE value> <podman-on-PATH: 0|1>
#
# Returns (as its own exit status — never captured via $(), since the code under test calls `exit`
# directly on its failure path, which would terminate a command-substitution subshell before any
# echo-the-exit-code line inside it ever ran) whatever builder_dispatch itself exits with.
#
# `command -v podman` is shadowed to simulate the builder container, which has no reason to carry a
# podman binary even when the bind-mounted .env the re-entrant build reads says RUNTIME=podman.
dispatch_rc() {
  ( RV="$1"; NATIVE="$2"; HASPODMAN="$3"
    export DUPLO_ENV_FILE=/dev/null
    [ -n "$RV" ] && export RUNTIME="$RV" || unset RUNTIME
    [ -n "$NATIVE" ] && export DUPLO_BUILD_NATIVE="$NATIVE" || unset DUPLO_BUILD_NATIVE
    command() {
      if [ "${1-}" = -v ] && [ "${2-}" = podman ] && [ "$HASPODMAN" != 1 ]; then return 1; fi
      builtin command "$@"
    }
    . ./scripts/_runtime.sh
    . ./scripts/_builder.sh
    builder_probe_in_container() { echo "$NATIVE"; }
    builder_probe_toolchain()    { echo 1; }
    builder_probe_runtime()      { echo 0; }
    builder_dispatch some-script.sh some-dir
  ) >/dev/null 2>&1
}

t "a forced-native build is unaffected by a \$RUNTIME it cannot resolve"
# This is the exact failure reported from a real build: the builder container's own compose environment
# sets DUPLO_BUILD_NATIVE=1, but the whole repo — .env included — is bind-mounted into it, so the
# re-entrant build.sh invocation reads RUNTIME=podman straight off the host's real .env even though the
# builder image has no podman binary and never needed one.
dispatch_rc podman 1 0; RC=$?
[ "$RC" = 0 ] && ok || bad "forced-native build still fataled on an unresolvable \$RUNTIME (rc=$RC)"

t "a forced-native build is unaffected when nothing is on PATH at all"
dispatch_rc "" 1 0; RC=$?
[ "$RC" = 0 ] && ok || bad "rc=$RC"

t "a HOST build (not forced-native) still fatals when the named runtime cannot be resolved"
# The guard must be scoped to the forced-native case only — a developer on their own machine who pinned
# RUNTIME=podman without installing it still needs the real error, not a silent native fallback they
# never asked for.
dispatch_rc podman "" 0; RC=$?
[ "$RC" != 0 ] && ok || bad "a host build with a genuinely broken \$RUNTIME exited 0 — the guard is too broad"

t "a HOST build with no \$RUNTIME pinned still resolves normally (auto-detect, not skipped)"
dispatch_rc "" "" 1; RC=$?
[ "$RC" = 0 ] && ok || bad "rc=$RC (auto-detect should have found podman and proceeded)"

t "bash -n on the touched files"
if bash -n scripts/_builder.sh 2>/dev/null; then ok; else bad "syntax error"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
