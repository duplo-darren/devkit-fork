#!/usr/bin/env bash
# Tests for builder_resolve_image in scripts/_builder.sh — which toolchain image a build runs in.
# Uses a stub `docker` on PATH and a throwaway .env; never pulls. Usage: ./tests/test-builder-image.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# Stand-in for _target.sh's .env reader, pointed at a temp file.
ENV="$TMP/.env"; : > "$ENV"
_envv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }

. ./scripts/_builder.sh || { echo "scripts/_builder.sh not found"; exit 1; }
# builder_dispatch resolves RUNTIME before it ever calls builder_resolve_image. Calling the resolver directly
# skips that, so point it at the stub here.
RUNTIME=docker

resolve() { ( unset BUILDER_IMAGE BUILDER_TAG BUILDER_PULL; eval "$1"; builder_resolve_image >/dev/null 2>&1; echo "$BUILDER_IMAGE" ); }

echo "builder image:"

t "defaults to the digest-pinned toolchain image"
: > "$ENV"; got="$(resolve :)"
if [[ "$got" =~ ^quay\.io/duplocloud/duplo-extension-builder@sha256:[0-9a-f]{64}$ ]]; then ok; else bad "$got"; fi

t "docker-compose.yml falls back to the same pinned image"
: > "$ENV"; got="$(resolve :)"
if grep -qF -- "\${BUILDER_IMAGE:-$got}" docker-compose.yml; then ok; else bad "compose does not default to $got"; fi

t "BUILDER_TAG in .env still selects a tag"
printf 'BUILDER_TAG=1.2.3\n' > "$ENV"; got="$(resolve :)"
if [ "$got" = "quay.io/duplocloud/duplo-extension-builder:1.2.3" ]; then ok; else bad "$got"; fi

t "BUILDER_TAG=latest, left over in an older .env, still takes the pinned image"
: > "$ENV"; pinned="$(resolve :)"
printf 'BUILDER_TAG=latest\n' > "$ENV"; got="$(resolve :)"
if [ "$got" = "$pinned" ]; then ok; else bad "$got"; fi

t "BUILDER_IMAGE in the environment still replaces the image outright"
: > "$ENV"; got="$(resolve 'export BUILDER_IMAGE=example.com/mine:1')"
if [ "$got" = "example.com/mine:1" ]; then ok; else bad "$got"; fi

echo
echo "dispatch with a RUNTIME that this environment lacks (.env is bind-mounted into the builder):"

# Stub toolchain, deliberately no docker/podman on PATH. builder_dispatch is run in a subshell because its
# error paths `exit`; the container marker is faked, as there is no real container to be in.
mkdir -p "$TMP/tc"; for x in jq dotnet npm zip curl unzip; do printf '#!/bin/sh\nexit 0\n' > "$TMP/tc/$x"; chmod +x "$TMP/tc/$x"; done
dispatch() { ( PATH="$TMP/tc:/usr/bin:/bin"; unset RUNTIME DUPLO_BUILD_NATIVE; eval "$1"
               builder_probe_in_container() { echo "$INCONT"; }
               ( builder_dispatch scripts/build-extension.sh x >/dev/null 2>&1 ); echo $? ); }
printf 'RUNTIME=podman\n' > "$ENV"

t "inside a container, RUNTIME=podman from .env does not abort the build"
got="$(INCONT=1 dispatch :)"; if [ "$got" = 0 ]; then ok; else bad "exit $got"; fi

t "DUPLO_BUILD_NATIVE=1 outranks a missing RUNTIME"
got="$(INCONT=0 dispatch 'export DUPLO_BUILD_NATIVE=1')"; if [ "$got" = 0 ]; then ok; else bad "exit $got"; fi

t "on a host, a named-but-missing RUNTIME is still fatal"
got="$(INCONT=0 dispatch :)"; if [ "$got" = 1 ]; then ok; else bad "exit $got"; fi
: > "$ENV"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
