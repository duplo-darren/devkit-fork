#!/usr/bin/env bash
# Checks that every duplocloud image this kit pins publishes both linux/amd64 and linux/arm64.
#
# WHY: the studio platform pin was dropped (see scripts/_runtime.sh, runtime_rosetta_check) because every
# devkit release now publishes multi-arch — an Apple Silicon host resolves the native layer instead of
# emulating under QEMU. That only stays true if every tag this repo configures actually IS multi-arch.
# Nothing else in the kit checks that: a tag bumped to an amd64-only build would silently fall back to
# emulation on arm64, and the retained Rosetta check would stay quiet, because it only fires on an
# EXPLICIT amd64 pin — an unset platform resolving to a single-arch image looks, to that check, exactly
# like one resolving correctly.
#
# Scope is quay.io/duplocloud/* only (decided 2026-10-01): these are images DuploCloud itself builds and
# has committed to publishing multi-arch, so a failing tag here is a mistake to fix, not a legitimate
# choice to accommodate — unlike scripts/_runtime.sh's Rosetta check, which has to allow for a user's own
# private or mirrored registry and so cannot hard-fail the same way. Third-party images (mongo, qdrant,
# busybox) are out of scope: stable, already multi-arch, and Docker Hub needs an auth dance this does not.
#
# Reads the registry API directly — no docker/podman pull, no runtime, no credentials for a public quay
# repo — so it runs the same on a fork PR (no org secrets) as it does here.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REQUIRED_ARCHES=(amd64 arm64)

# repo:TAG_VAR — the quay repo and the .env.example key holding its tag. Add a line here when a new
# duplocloud image is wired into .env.example; BUILDER_TAG is deliberately absent (defaults to `latest`,
# a moving target — see _should_skip_tag).
IMAGES=(
  "duplocloud/backend:STUDIO_TAG"
  "duplocloud/duplo-agent:AGENT_TAG"
  "duplocloud/duplo-ai-helpdesk-ui:UI_TAG"
  "duplocloud/duplo-xterm:XTERM_TAG"
)

# _tag_value <VAR> [<file>] -> the value of VAR= in <file> (default .env.example), or empty.
# Takes the file as an argument so this is testable against a fixture without touching the real one.
_tag_value() {
  grep -E "^$1=" "${2:-.env.example}" 2>/dev/null | head -1 | cut -d= -f2-
}

# _should_skip_tag <tag> -> a reason to skip it, or empty if it should be checked.
_should_skip_tag() {
  case "${1-}" in
    "")               echo "not set in .env.example" ;;
    latest)           echo "a moving target, not a pinned release" ;;
    *@sha256:*|sha256:*) echo "a digest pin — a single manifest by definition, not an index" ;;
    *) ;;
  esac
}

# _parse_arches -> reads a registry manifest response on stdin, prints the space-separated real
# architectures it lists, or one of UNREADABLE / ERROR:<msg> / SINGLE-ARCH.
#
# "Real" excludes attestation manifests: an OCI index for a multi-arch build typically carries extra
# entries with platform os/architecture "unknown" (SBOM/provenance attestations), which are not
# something this image runs as. Counting them would make this check pass on anything with 2+ manifests.
_parse_arches() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNREADABLE"); sys.exit(0)
if "errors" in d:
    print("ERROR:" + d["errors"][0].get("message", "?")[:80]); sys.exit(0)
ms = d.get("manifests")
if not ms:
    print("SINGLE-ARCH"); sys.exit(0)
arches = sorted({
    m.get("platform", {}).get("architecture")
    for m in ms
    if m.get("platform", {}).get("os") not in (None, "unknown")
})
print(" ".join(a for a in arches if a))
'
}

# _evaluate_manifest -> reads a registry manifest response on stdin, prints one verdict line, returns
# 0 when every REQUIRED_ARCHES entry is present, 1 otherwise (including on empty/unreadable input —
# a network failure must never read as a silent pass).
_evaluate_manifest() {
  local json have missing="" a
  json="$(cat)"
  if [ -z "$json" ]; then echo "no response (network error?)"; return 1; fi
  have="$(printf '%s' "$json" | _parse_arches)"
  case "$have" in
    UNREADABLE) echo "unreadable registry response"; return 1 ;;
    ERROR:*)    echo "registry error: ${have#ERROR:}"; return 1 ;;
    SINGLE-ARCH) echo "single-arch manifest, not a multi-arch index"; return 1 ;;
  esac
  for a in "${REQUIRED_ARCHES[@]}"; do
    case " $have " in *" $a "*) ;; *) missing="$missing $a" ;; esac
  done
  if [ -n "$missing" ]; then echo "missing:$missing (has: ${have:-none})"; return 1; fi
  echo "ok (has: $have)"
}

# _quay_fetch <repo> <tag> -> the registry's manifest response on stdout, or empty on a network failure.
# The one impure function in this file — everything else is pure and covered by tests/test-check-image-arches.sh.
_quay_fetch() {
  curl -sL --max-time 15 \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://quay.io/v2/$1/manifests/$2" 2>/dev/null
}

check_image() { # <repo> <tag> -> prints the verdict, returns 0/1
  _quay_fetch "$1" "$2" | _evaluate_manifest
}

# Only run the check when executed directly — sourcing this (as tests/test-check-image-arches.sh does)
# loads the functions above without triggering any network calls.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  FAIL=0
  echo "Checking duplocloud images publish ${REQUIRED_ARCHES[*]}..."
  for entry in "${IMAGES[@]}"; do
    repo="${entry%%:*}"; var="${entry#*:}"
    tag="$(_tag_value "$var")"
    skip="$(_should_skip_tag "$tag")"
    if [ -n "$skip" ]; then
      echo "  SKIP  $repo:${tag:-<unset>} — $skip"
      continue
    fi
    if result="$(check_image "$repo" "$tag")"; then
      echo "  OK    $repo:$tag — $result"
    else
      echo "  FAIL  $repo:$tag — $result"
      FAIL=1
    fi
  done

  if [ "$FAIL" = 1 ]; then
    echo
    echo "One or more duplocloud images do not publish every required architecture (${REQUIRED_ARCHES[*]})." >&2
    echo "Every devkit release is expected to be multi-arch — fix the tag before merging." >&2
    exit 1
  fi
  echo
  echo "All configured duplocloud images publish ${REQUIRED_ARCHES[*]}."
fi
