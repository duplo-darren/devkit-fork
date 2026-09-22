#!/usr/bin/env bash
# Checks the container-runtime abstraction in scripts/_runtime.sh, and that nothing in the kit has
# gone back to calling `docker` directly.
#
# Static + pure-function checks only: nothing here starts the stack, pulls an image, or needs any
# particular runtime to be installed — so it runs the same on a docker laptop, a podman box and CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Resolution is exercised in a subshell per case: runtime_resolve exports RUNTIME and memoises itself,
# so cases would otherwise contaminate each other. DUPLO_ENV_FILE=/dev/null keeps a developer's real
# .env (which may pin RUNTIME) out of the auto-detect cases.
res() { # res <env-assignments> -> prints "<rc>|<RUNTIME>"
  ( eval "$1"; export DUPLO_ENV_FILE=/dev/null
    . ./scripts/_runtime.sh
    if runtime_resolve 2>/dev/null; then printf '0|%s' "$RUNTIME"; else printf '1|'; fi )
}

echo "container runtime abstraction:"

t "_runtime.sh is syntactically valid and sourcing it defines the API"
if bash -n scripts/_runtime.sh 2>/dev/null && \
   ( . ./scripts/_runtime.sh
     for f in runtime_detect runtime_resolve runtime_requested runtime_builder_ids \
              runtime_is_rootless_podman runtime_compose_project runtime_compose_running_services \
              runtime_label; do
       declare -F "$f" >/dev/null || exit 1
     done ); then ok; else bad "missing function(s)"; fi

t "every supported runtime is accepted when present on PATH"
MISS=""
for r in docker podman nerdctl finch; do
  command -v "$r" >/dev/null 2>&1 || continue          # only assert about what's installed here
  [ "$(res "RUNTIME=$r")" = "0|$r" ] || MISS="$MISS $r"
done
if [ -z "$MISS" ]; then ok; else bad "rejected:$MISS"; fi

t "runc and friends are rejected as low-level OCI runtimes, not silently accepted"
MISS=""
for r in runc crun youki runsc; do
  [ "$(res "RUNTIME=$r")" = "1|" ] || MISS="$MISS $r"
done
if [ -z "$MISS" ]; then ok; else bad "not rejected:$MISS"; fi

t "the runc rejection explains itself rather than saying 'unsupported'"
MSG="$( ( export DUPLO_ENV_FILE=/dev/null RUNTIME=runc
          . ./scripts/_runtime.sh; runtime_resolve ) 2>&1 )"
if grep -q 'low-level OCI runtime' <<<"$MSG" && grep -q 'compose' <<<"$MSG" && grep -q 'podman' <<<"$MSG"
then ok; else bad "unhelpful message: $MSG"; fi

t "an unknown runtime is rejected"
if [ "$(res "RUNTIME=nosuchruntime")" = "1|" ]; then ok; else bad "accepted"; fi

t "a requested-but-absent runtime is rejected rather than falling back to another"
if command -v nerdctl >/dev/null 2>&1; then ok   # can't test: it IS present
elif [ "$(res "RUNTIME=nerdctl")" = "1|" ]; then ok
else bad "fell back instead of failing"; fi

t "values are cleaned of quotes, whitespace and CRs before use"
R="$(res 'RUNTIME=" podman "')"
if ! command -v podman >/dev/null 2>&1; then ok      # nothing to assert on a podman-less box
elif [ "$R" = "0|podman" ]; then ok; else bad "got '$R'"; fi

t "auto-detect picks an installed runtime, preferring docker"
R="$(res 'unset RUNTIME')"
EXPECT=""; for r in docker podman nerdctl finch; do command -v "$r" >/dev/null 2>&1 && { EXPECT="$r"; break; }; done
if [ -z "$EXPECT" ]; then ok                          # no runtime installed: nothing to prefer
elif [ "$R" = "0|$EXPECT" ]; then ok; else bad "got '$R', expected '0|$EXPECT'"; fi

t "runtime_requested distinguishes an explicit choice from auto-detect"
A="$( ( export DUPLO_ENV_FILE=/dev/null; unset RUNTIME; . ./scripts/_runtime.sh; runtime_requested ) )"
B="$( ( export DUPLO_ENV_FILE=/dev/null RUNTIME=podman; . ./scripts/_runtime.sh; runtime_requested ) )"
if [ -z "$A" ] && [ "$B" = podman ]; then ok; else bad "auto='$A' explicit='$B'"; fi

t "builder ids are the caller's uid/gid on docker, but 0:0 on rootless podman"
IDS="$( ( export DUPLO_ENV_FILE=/dev/null; . ./scripts/_runtime.sh; runtime_resolve 2>/dev/null
          runtime_builder_ids ) )"
if [ -z "$IDS" ]; then bad "no ids"
elif [ "$( ( export DUPLO_ENV_FILE=/dev/null; . ./scripts/_runtime.sh
             runtime_resolve 2>/dev/null; runtime_is_rootless_podman ) )" = 1 ]; then
  [ "$IDS" = "0 0" ] && ok || bad "rootless podman should be '0 0', got '$IDS'"
else
  [ "$IDS" = "$(id -u) $(id -g)" ] && ok || bad "expected '$(id -u) $(id -g)', got '$IDS'"
fi

echo
echo "no stray hard-coded docker calls:"

# The scripts that drive containers. Anything invoking the CLI must go through $RUNTIME so that the
# RUNTIME setting is actually honoured — a single stray `docker compose` silently ignores it.
#
# Detection strips comments AND double-quoted strings before matching: the kit legitimately NAMES these
# CLIs in help and error text ("Install docker, podman, …"), and only an actual invocation matters. A
# command name is never itself inside quotes, so dropping quoted spans cannot hide a real call. The
# `exec`/`command` prefix is matched explicitly — `exec docker compose` is exactly how logs.sh and the
# build dispatcher invoke it, and a check that missed that would pass while testing nothing.
t "no script invokes 'docker'/'podman' as a command instead of \$RUNTIME"
STRAY=""
for f in run.sh stop.sh logs.sh scripts/*.sh tests/*.sh; do
  [ "$f" = tests/test-runtime.sh ] && continue        # this file names them on purpose
  sed -e 's/[[:space:]]*#.*$//' -e 's/"[^"]*"//g' "$f" \
    | grep -qE '(^|[^-[:alnum:]_./$])((exec|command)[[:space:]]+)?(docker|podman|nerdctl|finch)[[:space:]]+(compose|run|pull|build|images?|ps|info|version|rmi?|logs|volume|inspect|exec)\b' \
    && STRAY="$STRAY $f"
done
if [ -z "$STRAY" ]; then ok; else bad "hard-coded CLI in:$STRAY"; fi

t "every script that runs containers sources _runtime.sh and resolves before using \$RUNTIME"
MISS=""
for f in run.sh stop.sh logs.sh scripts/_builder.sh scripts/switch-llm.sh scripts/detect-bedrock.sh; do
  grep -q '_runtime.sh' "$f" || MISS="$MISS $f"
done
if [ -z "$MISS" ]; then ok; else bad "not sourced in:$MISS"; fi

t "the builder run names its compose profile (podman-compose won't infer it)"
if grep -q 'compose --profile tools run' scripts/_builder.sh; then ok
else bad "scripts/_builder.sh must pass --profile tools"; fi

t "docker-compose.yml has no nested \${...\${...}} (podman-compose mis-parses it)"
# Comments are stripped first: the comment above that line documents the broken form on purpose, and
# a comment cannot affect how compose interpolates anything.
if sed 's/[[:space:]]*#.*$//' docker-compose.yml | grep -qE '\$\{[^}]*\$\{'; then
  bad "nested interpolation present"; else ok; fi

t ".env.example documents RUNTIME and says runc is not a valid value"
if grep -q '^#RUNTIME=' .env.example && grep -qi 'runc' .env.example; then ok; else bad ".env.example"; fi

t "bash -n on every shell script in the kit"
BADF=""
for f in run.sh stop.sh logs.sh scripts/*.sh tests/*.sh; do bash -n "$f" 2>/dev/null || BADF="$BADF $f"; done
if [ -z "$BADF" ]; then ok; else bad "syntax:$BADF"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
