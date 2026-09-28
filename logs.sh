#!/usr/bin/env bash
# Tail logs. Optional service name: duplo-ai-studio | claude-code-agent | duplo-ui | mongo | xterm
set -euo pipefail
cd "$(dirname "$0")"
. ./scripts/_runtime.sh          # → $RUNTIME (docker | podman)
runtime_resolve || exit 1
exec "$RUNTIME" compose logs -f "$@"
