#!/usr/bin/env bash
# Stop the platform. Volumes are kept (loaded extensions + data survive). Pass --wipe to remove them.
set -euo pipefail
cd "$(dirname "$0")"
. ./scripts/_runtime.sh          # → $RUNTIME (docker | podman | nerdctl | finch)
runtime_resolve || exit 1

if [ "${1:-}" = "--wipe" ]; then
  echo "==> Stopping and REMOVING volumes (extensions, mongo, file store will be lost)…"
  "$RUNTIME" compose down -v
else
  echo "==> Stopping (volumes kept; extensions replay on next ./run.sh)…"
  "$RUNTIME" compose down
fi
