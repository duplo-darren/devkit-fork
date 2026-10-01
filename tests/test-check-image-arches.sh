#!/usr/bin/env bash
# Checks the pure parts of scripts/check-image-arches.sh: manifest parsing, skip-decisions and the
# verdict logic. Nothing here touches the network — the one impure function (_quay_fetch) is exercised
# only by the real workflow run against quay.io, not by this suite.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "image architecture check:"

# Sourced once, at top level: nothing in this file mutates global state (no memoization, no .env
# writes), unlike _runtime.sh, so every test below shares this one load rather than re-sourcing per case.
. ./scripts/check-image-arches.sh

t "script is syntactically valid and sourcing it defines the API"
if bash -n scripts/check-image-arches.sh 2>/dev/null; then
  MISS=""
  for f in _parse_arches _evaluate_manifest _should_skip_tag _tag_value _quay_fetch check_image; do
    declare -F "$f" >/dev/null || MISS="$MISS $f"
  done
  [ -z "$MISS" ] && ok || bad "missing:$MISS"
else bad "bash -n failed"; fi

# ── _parse_arches: given a manifest-list JSON on stdin, which real platforms are present ──────────
t "parses a clean multi-arch index"
JSON='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'
R="$(printf '%s' "$JSON" | _parse_arches)"
[ "$R" = "amd64 arm64" ] && ok || bad "got '$R'"

t "excludes attestation manifests (os/architecture = unknown)"
# This is the real shape quay returns for duplocloud/backend: two real platforms plus two attestation
# entries. Counting the attestation entries as architectures would make the check pass on anything.
JSON='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"unknown","architecture":"unknown"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}'
R="$(printf '%s' "$JSON" | _parse_arches)"
[ "$R" = "amd64 arm64" ] && ok || bad "got '$R' (attestation entries leaked into the result)"

t "reports SINGLE-ARCH for a plain (non-index) manifest"
JSON='{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{}}'
R="$(printf '%s' "$JSON" | _parse_arches)"
[ "$R" = SINGLE-ARCH ] && ok || bad "got '$R'"

t "surfaces a registry error rather than treating it as zero architectures"
JSON='{"errors":[{"message":"manifest unknown"}]}'
R="$(printf '%s' "$JSON" | _parse_arches)"
case "$R" in ERROR:*) ok ;; *) bad "got '$R'" ;; esac

t "reports UNREADABLE on non-JSON input rather than crashing"
R="$(printf 'not json at all' | _parse_arches)"
[ "$R" = UNREADABLE ] && ok || bad "got '$R'"

# ── _evaluate_manifest: parse + compare against REQUIRED_ARCHES + produce the verdict line ────────
t "evaluate passes when both required architectures are present"
JSON='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'
MSG="$(printf '%s' "$JSON" | _evaluate_manifest)"; RC=$?
[ "$RC" = 0 ] && case "$MSG" in *amd64*arm64*|*arm64*amd64*) ok ;; *) bad "wrong message: $MSG" ;; esac \
  || bad "rc=$RC msg='$MSG'"

t "evaluate fails and names what's missing when arm64 is absent"
JSON='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}'
MSG="$(printf '%s' "$JSON" | _evaluate_manifest)"; RC=$?
if [ "$RC" != 0 ] && grep -q arm64 <<<"$MSG"; then ok; else bad "rc=$RC msg='$MSG'"; fi

t "evaluate fails on a single-arch (non-index) manifest"
JSON='{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}'
MSG="$(printf '%s' "$JSON" | _evaluate_manifest)"; RC=$?
[ "$RC" != 0 ] && grep -qi 'single-arch\|not.*index' <<<"$MSG" || bad "rc=$RC msg='$MSG'"
[ "$RC" != 0 ] && ok

t "evaluate fails on an empty response (network error) instead of silently passing"
MSG="$(printf '' | _evaluate_manifest)"; RC=$?
[ "$RC" != 0 ] && ok || bad "empty input passed"

# ── _should_skip_tag: which tags this check declines to validate, and why ──────────────────────────
t "an unset tag is skipped, not treated as a failure"
R="$(_should_skip_tag "")"
[ -n "$R" ] && ok || bad "empty tag was not flagged for skipping"

t "'latest' is skipped — a moving target proves nothing about tomorrow's pull"
R="$(_should_skip_tag "latest")"
[ -n "$R" ] && ok || bad "'latest' was not skipped"

t "a digest pin is skipped — it is a single manifest by definition"
R="$(_should_skip_tag "backend@sha256:abc123")"
[ -n "$R" ] && ok || bad "digest pin was not skipped"

t "an ordinary pinned tag is NOT skipped"
R="$(_should_skip_tag "dev-1.0.6-45708c38")"
[ -z "$R" ] && ok || bad "a real tag was skipped: $R"

# ── _tag_value: reading a *_TAG key out of an .env.example-shaped file ─────────────────────────────
t "_tag_value reads a key from the given file"
F="$(mktemp)"; printf 'STUDIO_TAG=dev-1.0.6-45708c38\nOTHER=x\n' > "$F"
R="$(_tag_value STUDIO_TAG "$F")"; rm -f "$F"
[ "$R" = dev-1.0.6-45708c38 ] && ok || bad "got '$R'"

t "_tag_value returns empty for a key the file does not have"
F="$(mktemp)"; printf 'STUDIO_TAG=x\n' > "$F"
R="$(_tag_value NOT_A_KEY "$F")"; rm -f "$F"
[ -z "$R" ] && ok || bad "got '$R'"

# ── scope: the configured image table is duplocloud-quay-only, per @aboutte's decision ─────────────
t "every configured image is a duplocloud/* repo (no third-party images checked)"
BAD=""
for entry in "${IMAGES[@]}"; do
  repo="${entry%%:*}"
  case "$repo" in duplocloud/*) ;; *) BAD="$BAD $repo" ;; esac
done
if [ -z "$BAD" ]; then ok; else bad "non-duplocloud repo(s) in scope:$BAD"; fi

t "BUILDER_TAG is not checked — it defaults to 'latest', a moving target"
FOUND=""
for entry in "${IMAGES[@]}"; do
  case "$entry" in *:BUILDER_TAG) FOUND=1 ;; esac
done
[ -z "$FOUND" ] && ok || bad "BUILDER_TAG is in the table despite defaulting to latest"

t "every *_TAG the table checks actually exists in .env.example"
MISS=""
for entry in "${IMAGES[@]}"; do
  var="${entry#*:}"
  grep -qE "^$var=" .env.example || MISS="$MISS $var"
done
if [ -z "$MISS" ]; then ok; else bad "table references key(s) .env.example does not define:$MISS"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
