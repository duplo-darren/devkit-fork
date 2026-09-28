#!/usr/bin/env bash
# Switch the running dev-kit agent between LLM providers (anthropic / bedrock / bedrock-instance-role /
# gateway) without ./run.sh --reset — no DB wipe, no re-licensing. Just an .env rewrite, an agent
# container recreate, and an LLM re-registration in the studio.
#
# WHY a separate script: run.sh's provider arms only run once, on first setup — the values they write
# are then "configured" and later runs never touch them (see run.sh's own header). --reset is the only
# existing way to change provider, and it wipes the whole stack to do it. This script does just the
# provider swap.
#
# Usage:
#   ./scripts/switch-llm.sh anthropic [--anthropic-key K]
#   ./scripts/switch-llm.sh bedrock   [--aws-access-key-id ..] [--aws-secret-access-key ..] \
#                                     [--aws-session-token ..] [--aws-region ..]
#   ./scripts/switch-llm.sh bedrock-instance-role [--aws-region ..]
#   ./scripts/switch-llm.sh subscription [--subscription-token T] [--subscription-model M]
#   ./scripts/switch-llm.sh gateway   [--gateway-url U] [--gateway-token T] [--gateway-model M] \
#                                     [--gateway-disable-betas 1] [--gateway-max-context-tokens N] \
#                                     [--gateway-compact-window N]
#   ./scripts/switch-llm.sh status
#
# Each provider owns a fixed set of .env keys. Switching AWAY from a provider stashes its current,
# non-empty keys into _STASH_<PROVIDER>_<KEY>= lines (so switching back later needs no re-entry) and blanks the
# live keys — blanking is load-bearing, exactly like run.sh's own arms: the agent picks its provider by
# precedence ANTHROPIC_API_KEY → gateway (ANTHROPIC_BASE_URL) → Bedrock (docker-compose.yml), so a
# leftover key from the old provider would silently keep winning. Switching TO a provider restores its
# stash if one exists, otherwise falls through to flags, then .env, then an interactive prompt — same
# resolution order run.sh uses.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=.env
[ -f "$ENV" ] || { echo "No .env found — run ./run.sh first to set up the stack." >&2; exit 1; }
. ./scripts/_runtime.sh          # → $RUNTIME (docker | podman)
. ./scripts/_provider_gateway.sh
. ./scripts/_provider_subscription.sh
runtime_resolve || exit 1

NONINTERACTIVE=0
F_ANTHROPIC=""; F_AWS_KEY=""; F_AWS_SECRET=""; F_AWS_TOKEN=""; F_AWS_REGION=""
F_GATEWAY_URL=""; F_GATEWAY_TOKEN=""; F_GATEWAY_MODEL=""
F_GATEWAY_DISABLE_BETAS=""; F_GATEWAY_MAX_CONTEXT=""; F_GATEWAY_COMPACT_WINDOW=""
F_SUBSCRIPTION_TOKEN=""; F_SUBSCRIPTION_MODEL=""

TARGET="${1-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive|-y) NONINTERACTIVE=1 ;;
    --anthropic-key) F_ANTHROPIC="$2"; shift ;;
    --aws-access-key-id) F_AWS_KEY="$2"; shift ;;
    --aws-secret-access-key) F_AWS_SECRET="$2"; shift ;;
    --aws-session-token) F_AWS_TOKEN="$2"; shift ;;
    --aws-region) F_AWS_REGION="$2"; shift ;;
    --subscription-token) F_SUBSCRIPTION_TOKEN="$2"; shift ;;
    --subscription-model) F_SUBSCRIPTION_MODEL="$2"; shift ;;
    --gateway-url) F_GATEWAY_URL="$2"; shift ;;
    --gateway-token) F_GATEWAY_TOKEN="$2"; shift ;;
    --gateway-model) F_GATEWAY_MODEL="$2"; shift ;;
    --gateway-disable-betas) F_GATEWAY_DISABLE_BETAS="$2"; shift ;;
    --gateway-max-context-tokens) F_GATEWAY_MAX_CONTEXT="$2"; shift ;;
    --gateway-compact-window) F_GATEWAY_COMPACT_WINDOW="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep -E '^#( |$)' | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
setenv() {
  python3 - "$ENV" "$1" "${2-}" <<'PY'
import sys
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().splitlines()
out=[];found=False
for ln in lines:
    if ln.startswith(k+"="): out.append(f"{k}={v}"); found=True
    else: out.append(ln)
if not found: out.append(f"{k}={v}")
open(p,"w").write("\n".join(out)+"\n")
PY
}
# A value the user typed at a `resolve` prompt below; --anthropic-key etc. already come through as flags.
resolve() { # flagval envkey prompt secret?
  local cur="$1" envkey="$2" prompt="$3" secret="${4-}"
  [ -z "$cur" ] && cur="$(getenv "$envkey")"
  while [ -z "$cur" ]; do
    [ "$NONINTERACTIVE" = 1 ] && { echo "Missing $envkey — pass it as a flag (non-interactive)." >&2; exit 1; }
    if [ "$secret" = secret ]; then read -rs -p "$prompt: " cur; echo >&2; else read -r -p "$prompt: " cur; fi
  done
  printf '%s' "$cur"
}

# Every key each provider owns. Kept in one place so stash/restore and the outgoing-blank step can't
# drift from what each arm below actually writes.
KEYS_anthropic=(ANTHROPIC_API_KEY CLAUDE_MODEL CLAUDE_EXTRA_MODELS)
KEYS_bedrock=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION CLAUDE_MODEL CLAUDE_EXTRA_MODELS)
KEYS_bedrock_instance_role=(AWS_REGION CLAUDE_MODEL CLAUDE_EXTRA_MODELS)
# GATEWAY_KEYS comes from _provider_gateway.sh; CLAUDE_MODEL is set by provider_gateway_configure too.
KEYS_gateway=("${GATEWAY_KEYS[@]}" CLAUDE_MODEL CLAUDE_EXTRA_MODELS)
# SUBSCRIPTION_KEYS comes from _provider_subscription.sh; CLAUDE_MODEL is set by its configure too.
KEYS_subscription=("${SUBSCRIPTION_KEYS[@]}" CLAUDE_MODEL CLAUDE_EXTRA_MODELS)

keys_for() { # provider -> prints the array name to nameref
  case "$1" in
    anthropic) printf '%s\n' "${KEYS_anthropic[@]}" ;;
    bedrock) printf '%s\n' "${KEYS_bedrock[@]}" ;;
    bedrock-instance-role) printf '%s\n' "${KEYS_bedrock_instance_role[@]}" ;;
    gateway) printf '%s\n' "${KEYS_gateway[@]}" ;;
    subscription) printf '%s\n' "${KEYS_subscription[@]}" ;;
  esac
}

known_providers="anthropic bedrock bedrock-instance-role gateway subscription"

# Stash keys are namespaced by provider because some keys are owned by more than one provider —
# CLAUDE_MODEL above all, whose id format differs per provider (us.anthropic.… on Bedrock,
# anthropic/… on a gateway, bare on first-party). A flat _STASH_CLAUDE_MODEL would hand the
# outgoing provider's model straight to the incoming one.
stash_key() { # provider key -> _STASH_<PROVIDER>_<KEY>
  printf '_STASH_%s_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')" "$2"
}
# Read a provider's stashed value. Falls back to the pre-namespacing flat _STASH_<KEY> only for keys
# owned by a single provider, where the flat stash is unambiguous; a shared key's flat stash could
# belong to anyone, so it is ignored.
stash_get() { # provider key
  local v owners=0 p
  v="$(getenv "$(stash_key "$1" "$2")")"
  if [ -z "$v" ]; then
    for p in $known_providers; do
      case " $(keys_for "$p" | tr '\n' ' ') " in *" $2 "*) owners=$((owners+1)) ;; esac
    done
    [ "$owners" = 1 ] && v="$(getenv "_STASH_$2")"
  fi
  printf '%s' "$v"
}

status() {
  local cur; cur="$(getenv DEVKIT_MODEL)"
  echo "Active provider: ${cur:-<none configured — run ./run.sh first>}"
  for p in $known_providers; do
    [ "$p" = "$cur" ] && continue
    local stashed=0
    while IFS= read -r k; do
      [ -n "$(stash_get "$p" "$k")" ] && stashed=1
    done < <(keys_for "$p")
    if [ "$stashed" = 1 ]; then
      echo "  $p: stashed credentials available — switching back needs no re-entry"
    else
      echo "  $p: no stash — switching to it will prompt (or take flags)"
    fi
  done
}

[ -n "$TARGET" ] || { echo "Usage: ./scripts/switch-llm.sh <anthropic|bedrock|bedrock-instance-role|gateway|subscription|status> [flags]" >&2; exit 1; }
TARGET="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')"
[ "$TARGET" = status ] && { status; exit 0; }
case " $known_providers " in *" $TARGET "*) ;; *) echo "Unknown provider '$TARGET' (use anthropic, bedrock, bedrock-instance-role, gateway, subscription, or status)." >&2; exit 1 ;; esac

CURRENT="$(getenv DEVKIT_MODEL)"
if [ "$CURRENT" = "$TARGET" ]; then
  echo "Already on $TARGET — reconfiguring in place (existing values reused unless flags override)." >&2
else
  if [ -n "$CURRENT" ]; then
    echo "==> Stashing $CURRENT credentials…"
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      v="$(getenv "$k")"
      if [ -n "$v" ]; then setenv "$(stash_key "$CURRENT" "$k")" "$v"; fi
      setenv "$k" ""
    done < <(keys_for "$CURRENT")
  fi
  echo "==> Restoring any stashed $TARGET credentials…"
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    sv="$(stash_get "$TARGET" "$k")"
    [ -n "$sv" ] && setenv "$k" "$sv"
  done < <(keys_for "$TARGET")
fi

# Same model ids and defaults run.sh's own arms use, so a model already registered under one provider
# is recognized (or replaced) the same way a fresh ./run.sh setup would.
BEDROCK_MODEL="us.anthropic.claude-sonnet-5"
BEDROCK_EXTRA_MODELS="us.anthropic.claude-opus-5"

case "$TARGET" in
  anthropic)
    KEY="$(resolve "$F_ANTHROPIC" ANTHROPIC_API_KEY 'Anthropic API key' secret)"
    setenv ANTHROPIC_API_KEY "$KEY"
    setenv CLAUDE_MODEL "claude-sonnet-5"
    setenv CLAUDE_EXTRA_MODELS "claude-opus-5"
    [ -z "$(getenv ANTHROPIC_BASE_URL)" ] || echo "    note: ANTHROPIC_BASE_URL is still set in .env — the agent will send your Anthropic key THERE, not to api.anthropic.com. Clear it (./scripts/switch-llm.sh gateway then back, or edit .env) unless that's intended."
    LLM_DESC="direct Anthropic"
    ;;
  bedrock)
    AK="$(resolve "$F_AWS_KEY" AWS_ACCESS_KEY_ID 'AWS access key id')"
    SK="$(resolve "$F_AWS_SECRET" AWS_SECRET_ACCESS_KEY 'AWS secret access key' secret)"
    ST="$F_AWS_TOKEN"; [ -z "$ST" ] && ST="$(getenv AWS_SESSION_TOKEN)"
    RG="$F_AWS_REGION"; [ -z "$RG" ] && RG="$(getenv AWS_REGION)"; [ -z "$RG" ] && RG="us-west-2"
    setenv AWS_ACCESS_KEY_ID "$AK"; setenv AWS_SECRET_ACCESS_KEY "$SK"; setenv AWS_SESSION_TOKEN "$ST"; setenv AWS_REGION "$RG"
    setenv CLAUDE_MODEL "$BEDROCK_MODEL"
    setenv CLAUDE_EXTRA_MODELS "$BEDROCK_EXTRA_MODELS"
    [ -z "$(getenv ANTHROPIC_API_KEY)" ] || echo "    note: ANTHROPIC_API_KEY is still set in .env — the agent prefers it over Bedrock."
    [ -z "$(getenv ANTHROPIC_BASE_URL)" ] || echo "    note: ANTHROPIC_BASE_URL is still set in .env — the agent prefers a gateway over Bedrock."
    LLM_DESC="AWS Bedrock"
    ;;
  bedrock-instance-role)
    RG="$F_AWS_REGION"; [ -z "$RG" ] && RG="$(getenv AWS_REGION)"; [ -z "$RG" ] && RG="us-east-1"
    setenv AWS_REGION "$RG"
    setenv CLAUDE_MODEL "$BEDROCK_MODEL"
    setenv CLAUDE_EXTRA_MODELS "$BEDROCK_EXTRA_MODELS"
    for k in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do setenv "$k" ""; done
    echo "    using EC2 instance role for Bedrock in $RG — no keys stored in .env."
    LLM_DESC="AWS Bedrock via EC2 instance role"
    ;;
  gateway)
    provider_gateway_configure || exit 1
    LLM_DESC="LLM Gateway"
    ;;
  subscription)
    provider_subscription_configure || exit 1
    LLM_DESC="Claude Code subscription"
    ;;
esac

setenv DEVKIT_MODEL "$TARGET"

if ! runtime_compose_running_services | grep -qx claude-code-agent; then
  echo "==> Agent container isn't running — .env is updated; start the stack with ./run.sh to apply it." >&2
  exit 0
fi

echo "==> Recreating the agent with the new provider…"
"$RUNTIME" compose up -d claude-code-agent

echo "==> Registering $(getenv CLAUDE_MODEL) ($LLM_DESC) as the System default LLM…"
if LLM_PROVIDER_LABEL="$LLM_DESC" ./scripts/register-llm.sh; then
  case "$TARGET" in
    gateway) echo "✔ agent now on LLM gateway @ $(getenv ANTHROPIC_BASE_URL) (model: $(getenv CLAUDE_MODEL))" ;;
    bedrock-instance-role) echo "✔ agent now on $LLM_DESC @ $(getenv AWS_REGION)" ;;
    subscription) echo "✔ agent now on your Claude Code subscription (model: $(getenv CLAUDE_MODEL)) — local dev only" ;;
    *) echo "✔ agent now on $LLM_DESC (model: $(getenv CLAUDE_MODEL))" ;;
  esac
else
  echo "    (LLM registration failed — run ./scripts/register-llm.sh manually)" >&2
fi
