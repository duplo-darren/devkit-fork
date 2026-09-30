#!/usr/bin/env bash
# Interactive, idempotent setup + start for the DuploCloud Extension Dev Kit.
#
#   ./run.sh                       first run prompts for email and requests a trial license. You are emailed
#                                  a verification link: click it and the license is issued and picked up
#                                  automatically (this run waits up to 2 minutes for it). Then it prompts
#                                  for password/LLM provider and starts everything; later runs are
#                                  silent (no prompts). They also adopt any changed framework defaults
#                                  (image tags/platform) from .env.example, keeping your overrides.
#   ./run.sh --reset               wipe the DB + all configured values (incl. provider credentials) and
#                                  start fresh. This is the ONLY thing that clears credentials from .env —
#                                  normal restarts never touch them; use --reset to switch providers cleanly.
#                                  Your license is left alone: it is not stack state, and DuploCloud issues
#                                  exactly ONE per email address, so there is nothing to gain by discarding it.
#   ./run.sh --reset-license       forget the license too (the JWT and the ids it can be re-fetched from).
#                                  Prints the JWT first: DuploCloud will NOT issue a second one for this
#                                  address. Restore it with --license <jwt>, or let a later run recover it —
#                                  it asks the server to email you a link that releases the same license.
#                                  Combine with --reset, or use alone to re-license (with --license, or a
#                                  new --email).
#   ./run.sh --license <jwt>       use a license JWT you already have (no licensing call is made).
#   ./run.sh --email <addr>        set/correct the admin email. While a license request is still unverified
#                                  this also replaces it: the saved request id can only verify the address it
#                                  was made for, so a new address drops it and requests again. That is how you
#                                  get out of a mistyped email whose verification link you never received.
#   ./run.sh --email a@b.com --password 'pw' --model anthropic --anthropic-key sk-...   non-interactive.
#   ./run.sh --model bedrock --aws-access-key-id AKIA... --aws-secret-access-key ... [--aws-session-token ...] [--aws-region us-west-2]
#   ./run.sh --model bedrock-instance-role [--aws-region us-east-1]   Bedrock via this EC2 instance's IAM role (no keys).
#   ./run.sh --model subscription --subscription-token sk-ant-oat01-...   run on your own Claude Code
#                                  subscription instead of a billed API key (mint the token with
#                                  `claude setup-token` on this machine). Local development only: it
#                                  authenticates as you and counts against your Claude Code limits.
#                                  Ticket titles are not generated on this path (title LLM is Bedrock-only).
#   ./run.sh --model gateway --gateway-url https://openrouter.ai/api --gateway-token sk-or-... [--gateway-model anthropic/claude-sonnet-5]
#                                  any Anthropic-compatible LLM gateway (OpenRouter, Bifrost, LiteLLM, …). Optional
#                                  Sets a 262144-token context window and a 200000 compact threshold (a gateway
#                                  usually serves model ids the CLI does not know, which otherwise have none);
#                                  override with --gateway-max-context-tokens N / --gateway-compact-window N, and
#                                  see --gateway-disable-betas 1 for Snowflake Cortex (see .env.example).
#
# Already running and just want to switch providers (e.g. Bedrock → an LLM gateway) without wiping the
# DB? Use ./scripts/switch-llm.sh instead of --reset — see its --help.
#
# On an EC2 host the provider prompt first probes whether the instance role can actually invoke Bedrock
# (scripts/detect-bedrock.sh) and, if so, offers that as a third, keyless option.
#
# On completion it has: obtained a trial license for your admin email (Licensing__Token in .env),
# pulled+started the stack, minted a permanent admin API token into .env
# (DUPLO_ADMIN_TOKEN), and created a 'extension-dev' workspace (EXTENSION_DEV_WORKSPACE_ID). All values persist in .env.
set -euo pipefail
cd "$(dirname "$0")"
ENV=.env
. ./scripts/_runtime.sh          # → $RUNTIME (docker | podman); resolved in preflight
. ./scripts/_provider_gateway.sh
. ./scripts/_provider_subscription.sh
. ./scripts/_studio_api.sh

# ── flags ────────────────────────────────────────────────────────────────────
RESET=0; RESET_LICENSE=0; NONINTERACTIVE=0
F_EMAIL=""; F_PASSWORD=""; F_MODEL=""; F_ANTHROPIC=""; F_LICENSE=""
F_AWS_KEY=""; F_AWS_SECRET=""; F_AWS_TOKEN=""; F_AWS_REGION=""
F_GATEWAY_URL=""; F_GATEWAY_TOKEN=""; F_GATEWAY_MODEL=""
F_GATEWAY_DISABLE_BETAS=""; F_GATEWAY_MAX_CONTEXT=""; F_GATEWAY_COMPACT_WINDOW=""
F_SUBSCRIPTION_TOKEN=""; F_SUBSCRIPTION_MODEL=""
F_STUDIO_TAG=""; F_UI_TAG=""; F_AGENT_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1 ;;
    # Independent of --reset: the license is not stack state. Alone it re-licenses this install without
    # touching the DB; together with --reset it makes the wipe total.
    --reset-license) RESET_LICENSE=1 ;;
    --non-interactive|-y) NONINTERACTIVE=1 ;;
    # Accepted and ignored: the license server no longer takes terms_accepted, so there is nothing to
    # accept here. Kept parseable (rather than falling through to "Unknown flag") so an existing scripted
    # invocation doesn't start failing on an upgrade.
    --accept-terms) ;;
    --email) F_EMAIL="$2"; shift ;;
    --password) F_PASSWORD="$2"; shift ;;
    # ${2-} (not $2): with no operand at all, a bare $2 dies at "unbound variable" under `set -u` before
    # the -n test could print the friendly message this check exists for.
    --license) [ -n "${2-}" ] || { echo "--license needs a JWT." >&2; exit 1; }; F_LICENSE="$2"; shift ;;
    --model) F_MODEL="$2"; shift ;;
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
    --studio-tag) F_STUDIO_TAG="$2"; shift ;;
    --ui-tag) F_UI_TAG="$2"; shift ;;
    --agent-tag) F_AGENT_TAG="$2"; shift ;;
    -h|--help) sed -n '2,/^[^#]/p' "$0" | grep -E '^#( |$)' | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── .env must exist before anything reads it ──────────────────────────────────
# Ahead of the prerequisite checks deliberately: runtime_resolve below reads RUNTIME from .env and then
# memoises its answer for the whole run. Creating .env after that point meant a first run on a box with
# both CLIs installed auto-detected docker and ignored RUNTIME=podman — set in .env or shipped in
# .env.example — for both podman preflights, `compose pull` and `compose up`. Needs neither python3 nor
# $RUNTIME, so it is safe this early.
[ -f "$ENV" ] || { [ -f .env.example ] && cp .env.example "$ENV" || touch "$ENV"; }

# ── prerequisites ────────────────────────────────────────────────────────────
# Checked here, after flag parsing (so --help still works on a bare machine) and before the first line
# that needs either one — setenv() below is already python3. Both are hard requirements, so report every
# problem in one pass rather than making the user re-run to discover the next one.
#
#   python3  every .env write and every JSON response in this script and in scripts/ is parsed with it.
#            No version floor: only the stdlib (json, sys, os, datetime, base64) is used, so anything
#            still called python3 is new enough.
#   RUNTIME  the whole stack, and every extension build, runs in containers. Which CLI drives them is
#            resolved by scripts/_runtime.sh (RUNTIME in the environment or .env, else auto-detected);
#            it must provide a v2-style `compose` subcommand. The standalone `docker-compose` v1 binary
#            is not used.
#
# The daemon-not-running case is a warning, not an error: `$RUNTIME compose pull` further down reports
# it far better than we can, and failing here would block the flag-only paths that never touch it.
MISSING=""
command -v python3 >/dev/null 2>&1 || MISSING="${MISSING}
  • python3 — not on PATH. macOS: brew install python3 (or install Xcode command line tools).
    Debian/Ubuntu: sudo apt-get install -y python3. RHEL/Amazon Linux: sudo dnf install -y python3."

# runtime_resolve must run in THIS shell, not a command substitution: it sets RUNTIME as a side effect,
# which a subshell would discard. So its diagnostics go straight to stderr rather than into $MISSING —
# the one-pass property is preserved by deferring the exit until python3 has been reported too.
RUNTIME_OK=1
runtime_resolve || RUNTIME_OK=0
if [ "$RUNTIME_OK" = 1 ] && ! "$RUNTIME" compose version >/dev/null 2>&1; then
  # The CLI exists but has no `compose` subcommand: Compose v1 only, or a plugin-less install. For
  # podman that usually means the podman-compose (or docker-compose) provider is missing, since podman
  # shells out to one rather than implementing compose itself.
  MISSING="${MISSING}
  • $RUNTIME compose — '$RUNTIME compose version' failed. A v2-style compose subcommand is required;
    the standalone docker-compose v1 binary is not enough.
      docker  — install the Compose v2 plugin, or upgrade Docker Desktop.
      podman  — it shells out to a compose provider rather than implementing compose itself.
                Podman Desktop can install one for you, or: brew install podman-compose"
  # Before reciting prerequisites, check whether another supported runtime is simply ready. Hit in
  # practice with RUNTIME=podman pinned in .env, podman's socket broken, and docker up with compose v2:
  # the advice above is all correct and all irrelevant when a working runtime is already installed.
  _calt="$(runtime_alternatives_compose)"
  _pinned="$(runtime_requested)"
  for _c in $_calt; do
    if [ -n "$_pinned" ]; then
      MISSING="${MISSING}
    $_c is installed, responding, and has compose. RUNTIME is currently pinned to '$_pinned' — that
    pin outranks auto-detection, which would have chosen $_c. Change it in .env:
        RUNTIME=$_c"
    else
      MISSING="${MISSING}
    $_c is installed, responding, and has compose. Set it in .env:
        echo 'RUNTIME=$_c' >> .env"
    fi
    MISSING="${MISSING}
    Set it in .env rather than per-command: run.sh, the build scripts, logs.sh and stop.sh each
    resolve the runtime independently, so a one-off on the command line leaves the next command on
    the other runtime."
  done
  unset _calt _pinned _c
fi
if [ -n "$MISSING" ]; then
  echo "This kit needs a couple of things that aren't here yet:$MISSING" >&2
  RUNTIME_OK=0
fi
[ "$RUNTIME_OK" = 1 ] || exit 1
# If the resolved runtime is not answering, say so — and if another supported one IS, name it. Detection
# is presence-based, so a stopped Docker Desktop alongside a healthy podman resolves to docker and then
# fails at 'Pulling images' with nothing pointing at the way out.
if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "Note: $RUNTIME doesn't look ready (daemon not running, or no connection) — sort that out before this gets to 'Pulling images'." >&2
  _alt="$(runtime_alternatives)"
  if [ -n "$_alt" ]; then
    for _a in $_alt; do
      echo "      $_a is installed and responding. To use it, set it in .env — every script reads it" >&2
      echo "      there, and a one-off on the command line would leave the next command elsewhere:" >&2
      echo "          echo 'RUNTIME=$_a' >> .env" >&2
    done
  fi
  unset _alt _a
fi

# Sized-VM check. Separate from the MISSING one-pass above because it needs RUNTIME already resolved,
# and it is a hard failure by design: an undersized podman machine does not stop the stack from coming
# up, it silently poisons every extension build later with an OOM kill that reports itself as a Go
# deadlock and 'exit status 137'. A no-op on docker and on a machine-less podman.
runtime_machine_check || exit 1

# Stale-amd64-pin preflight. Same shape and the same reason as the sized-VM check above: on Apple Silicon
# a podman machine without Rosetta hands amd64 binaries to QEMU, which cannot run the studio's .NET
# runtime — and every layer of that failure lies. The container reports "Up", /healthz simply never
# answers, and the wait loop further down burns 4.5 minutes before exiting on "Login failed", which
# points at credentials. Catching it here turns all of that into one accurate message.
#
# Studio images publish arm64 now, so this fires only on an EXPLICIT amd64 STUDIO_PLATFORM — a stale .env
# the migration above declined to touch, or a single-arch registry. A no-op on docker, on an amd64 host,
# and whenever the platform is unset or already native.
runtime_rosetta_check || exit 1

# ── .env helpers (line-based; safe for tokens/keys with special chars) ────────
getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
setenv() {
  python3 - "$ENV" "$1" "${2-}" <<'PY'
import sys
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().splitlines()
out=[];found=False
for ln in lines:
    if ln.startswith(k+"="): out.append(f"{k}={v}");found=True
    else: out.append(ln)
if not found: out.append(f"{k}={v}")
open(p,"w").write("\n".join(out)+"\n")
PY
}
getfrom() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# ── license helpers ──────────────────────────────────────────────────────────
# A license is an RS256 JWT from the license server. We never verify its signature here —
# the studio does that with the server's published key (GET $LICENSE_API_URL/api/licenses/public-key/).
# These helpers only read the payload so we can warn about expiry and reject mis-pasted input.
fmt_ts() { python3 -c 'import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))' "$1" 2>/dev/null || printf '%s' "$1"; }
# Prints "<exp>\t<email>\t<iss>"; non-zero if the token isn't a parseable JWT.
jwt_claims() {
  T="$1" python3 - <<'PY' 2>/dev/null
import base64,json,os,re,sys
t=os.environ["T"]
# Validate the token EXACTLY as given — no .strip(), no normalization — so the bytes we validate are the
# bytes the caller stores. base64.urlsafe_b64decode() defaults to validate=False, which silently DISCARDS
# every character outside the base64url alphabet, so it happily "decoded" a token wrapped in quotes or
# broken across lines by a paste. Validating a normalized string while storing the raw one is what let a
# wrapped or quoted --license reach .env — an embedded newline there writes a bare line with no '=' and
# breaks compose's env_file parsing for the whole stack. (\Z, not $: Python's $ also matches just before a
# trailing newline, which would reopen exactly this hole for one character.)
if not re.match(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\Z',t): sys.exit(1)
parts=t.split(".")
def seg(s): return json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4)))
try: seg(parts[0]); p=seg(parts[1])
except Exception: sys.exit(1)
if not isinstance(p,dict): sys.exit(1)
# Strip tabs from each claim: a tab inside e.g. the email would shift the fields, so jwt_ok's `cut -f3`
# would read the issuer out of the email and accept a token it should have rejected.
def f(v): return str(v).replace("\t"," ")
print("%s\t%s\t%s"%(f(p.get("exp","")),f(p.get("email","")),f(p.get("iss",""))))
PY
}
# True if $1 looks like a license JWT: right shape, decodable payload, carries an email claim.
# We deliberately do NOT pin the issuer. This check exists to catch a truncated or mis-pasted token,
# not a forgery — it can't do the latter anyway, since verifying the signature is the studio's job with
# the server's published key. Pinning `iss` bought no security and did real damage: when the license
# server was rebranded (duplocloud-ai-studio → duplocloud-console) every freshly issued trial was
# rejected here AFTER the server had already spent that address on it.
jwt_ok() {
  local c; c="$(jwt_claims "$1")" || return 1
  [ -n "$(printf '%s' "$c" | cut -f2)" ]
}
# Warn (never fail) about an expired or soon-expiring license. Sets LICENSE_STATUS for the summary.
LICENSE_STATUS=""
license_warn_expiry() {
  local c exp now days
  if ! c="$(jwt_claims "$1")"; then
    LICENSE_STATUS="unreadable"
    echo "    ⚠ Licensing__Token in .env is not a readable JWT — replace it with ./run.sh --license <jwt>." >&2
    return 0
  fi
  exp="$(printf '%s' "$c" | cut -f1)"
  # Treat empty, non-numeric, and implausibly long exp values as "no expiry": anything past 64-bit makes
  # the `-le` test below print "integer expression expected" at the user, and a millisecond-epoch exp (13
  # digits) would date-format into a raw number like "1787691259000". 12 '?' rejects 12+ digits; a real
  # second-epoch is 10 digits today and 11 covers to the year 5138.
  case "$exp" in ''|*[!0-9]*|????????????*) LICENSE_STATUS="no expiry"; return 0 ;; esac
  now="$(date +%s)"
  if [ "$exp" -le "$now" ]; then
    LICENSE_STATUS="EXPIRED $(fmt_ts "$exp")"
    echo "    ⚠ License expired on $(fmt_ts "$exp") — contact DuploCloud to renew (it will not be re-issued for this email)." >&2
  else
    days=$(( (exp - now) / 86400 ))
    LICENSE_STATUS="valid"
    if [ "$days" -le 7 ]; then
      echo "    ⚠ License expires in $days day(s) — $(fmt_ts "$exp")." >&2
    fi
  fi
}
# POST the trial request. Always exits 0; prints exactly one tab-separated line:
#   OK<TAB><jwt><TAB><expires_at>   issued outright (the server has email verification turned off)
#   PENDING<TAB><uuid>              accepted, pending email verification — poll <uuid> with license_poll
#   ISSUED<TAB><message><TAB><recover-path>  one trial per email — already used. <recover-path> is set when
#                                   the server says that trial is recoverable; recover it rather than asking
#                                   the user for a JWT they may never have been sent.
#   EMAIL<TAB><message>             email rejected (privacy-relay or disposable domain, malformed, …)
#   ERR<TAB><message>               anything else, including transport failure
license_request() { # email api-url
  E="$1" U="$2" python3 - <<'PY'
import json,os,re,urllib.error,urllib.request
email=os.environ["E"]; base=os.environ["U"].rstrip("/")
company=email.split("@")[-1]                      # the license server only needs *a* company; the domain is it
# Collapse ALL whitespace in every field: a stray \r from an HTML error page can erase the start of the
# line on a terminal, and a newline would break the one-line contract. JWTs contain no whitespace, so
# this is lossless for the token. Length-capping is applied to messages only (below) — never here, or a
# real ~800-character license would be silently truncated into garbage.
def out(*f): print("\t".join(" ".join(str(x).split()) for x in f))
# A hand-edited LICENSE_API_URL with no scheme makes Request() raise ValueError. Catch it here rather
# than in the tails below, where it would be misreported as an unparseable response.
if not base.lower().startswith(("http://","https://")):
    out("ERR","could not reach %s (LICENSE_API_URL has no http:// or https:// scheme)"%base)
    raise SystemExit(0)
UUID_RE=r'^[0-9a-fA-F-]{36}\Z'
try:
    req=urllib.request.Request(base+"/api/licenses/trial/",
        data=json.dumps({"email":email,"company":company}).encode(),
        headers={"Content-Type":"application/json",
                 "User-Agent":"duplo-ai-extension-devkit run.sh"},method="POST")
    with urllib.request.urlopen(req,timeout=20) as r:
        status=r.status; loc=r.headers.get("Location") or ""; d=json.loads(r.read() or b"{}")
    if not isinstance(d,dict): d={}
    tok=d.get("license")
    if tok:
        out("OK",tok,d.get("expires_at") or "")
    else:
        # No license in the body means the server has email verification on and the trial is pending.
        # It hands us a uuid to poll — in the body, or as the Location header of the created resource.
        u=str(d.get("uuid") or "").strip() or loc.rstrip("/").rsplit("/",1)[-1].strip()
        if re.match(UUID_RE,u): out("PENDING",u)
        else: out("ERR","DuploCloud returned HTTP %s with no license and no request id to poll"%status)
except urllib.error.HTTPError as e:                    # must stay first — HTTPError subclasses URLError
    raw=e.read().decode("utf-8","replace")
    try: d=json.loads(raw)
    except Exception: d=None
    msgs=[]
    if isinstance(d,dict):
        for k,v in d.items():
            if k in ("uuid","recoverable","recover_url"): continue   # machine fields, not prose
            if isinstance(v,list): msgs.extend(str(x) for x in v)
            else: msgs.append(str(v))
    msg=(" ".join(msgs) or raw.strip() or "HTTP %s"%e.code)[:400]   # cap: a 3 KB HTML page is not a message
    low=msg.lower()
    # Match "already issued" loosely. A rewording that fell through to EMAIL would prompt for a
    # DIFFERENT address and burn a second trial — and trials are never re-issued.
    if e.code==400 and "already" in low and ("issued" in low or "trial" in low):
        # The server marks the duplicates it can recover and names the endpoint to POST to. Accept only a
        # same-origin absolute path: we send an email address to whatever this says, so a full URL — or a
        # protocol-relative //host/path — is refused, not followed.
        rec=""
        if isinstance(d,dict) and d.get("recoverable") is True:
            p=str(d.get("recover_url") or "").strip()
            if p.startswith("/") and not p.startswith("//"): rec=p
        out("ISSUED",msg,rec)
    elif e.code==400 and isinstance(d,dict) and "email" in d: out("EMAIL",msg)
    else: out("ERR","DuploCloud returned HTTP %s: %s"%(e.code,msg))
except (urllib.error.URLError,OSError) as e:           # DNS, refused, timeout, TLS — we never got a reply
    out("ERR","could not reach DuploCloud at %s (%s)"%(base,e))
except Exception as e:                                 # we got a reply but couldn't parse it (proxy/SSO page)
    out("ERR","DuploCloud at %s returned a response we couldn't read (%s)"%(base,e))
PY
}
# POST the recovery request: ask the server to email the licensee a link that releases their existing
# license to this dev kit. Always exits 0; prints exactly one tab-separated line:
#   OK<TAB><recovery-uuid>   accepted — poll it with license_poll … recovery
#   NONE<TAB><message>       the server has nothing recoverable for this address
#   ERR<TAB><message>        anything else, including transport failure
# The server reuses a live pending recovery rather than creating a second one, so calling this twice for the
# same address does not send two emails — which is what lets a timed-out run simply be re-run.
license_recover() { # email api-url recover-path
  E="$1" U="$2" P="$3" python3 - <<'PY'
import json,os,re,urllib.error,urllib.request
email=os.environ["E"]; base=os.environ["U"].rstrip("/"); path=os.environ["P"]
def out(*f): print("\t".join(" ".join(str(x).split()) for x in f))
if not base.lower().startswith(("http://","https://")):
    out("ERR","could not reach %s (LICENSE_API_URL has no http:// or https:// scheme)"%base)
    raise SystemExit(0)
# Belt and braces — license_request already refused anything else, and this is where the address is sent.
if not path.startswith("/") or path.startswith("//"):
    out("ERR","DuploCloud named a recovery endpoint we won't post to: %.60s"%path)
    raise SystemExit(0)
try:
    req=urllib.request.Request(base+path,data=json.dumps({"email":email}).encode(),
        headers={"Content-Type":"application/json",
                 "User-Agent":"duplo-ai-extension-devkit run.sh"},method="POST")
    with urllib.request.urlopen(req,timeout=20) as r:
        status=r.status; loc=r.headers.get("Location") or ""; d=json.loads(r.read() or b"{}")
    if not isinstance(d,dict): d={}
    u=str(d.get("recovery_uuid") or "").strip() or loc.rstrip("/").rsplit("/",1)[-1].strip()
    if re.match(r'^[0-9a-fA-F-]{36}\Z',u): out("OK",u)
    else: out("ERR","DuploCloud returned HTTP %s with no recovery id to poll"%status)
except urllib.error.HTTPError as e:                    # must stay first — HTTPError subclasses URLError
    raw=e.read().decode("utf-8","replace")
    try: d=json.loads(raw)
    except Exception: d=None
    msg=(str(d.get("detail") or "") if isinstance(d,dict) else "") or raw.strip() or "HTTP %s"%e.code
    msg=" ".join(msg.split())[:400]                    # cap: an HTML error page is not a message
    if   e.code==404: out("NONE",msg)
    elif e.code==429: out("ERR","rate-limited by DuploCloud (HTTP 429)")
    else: out("ERR","DuploCloud returned HTTP %s: %s"%(e.code,msg))
except (urllib.error.URLError,OSError) as e:           # DNS, refused, timeout, TLS — we never got a reply
    out("ERR","could not reach DuploCloud at %s (%s)"%(base,e))
except Exception as e:                                 # we got a reply but couldn't parse it (proxy/SSO page)
    out("ERR","DuploCloud at %s returned a response we couldn't read (%s)"%(base,e))
PY
}
# GET the state of one pending trial, or of one pending recovery — two endpoints with the same shape and
# two different words for "done", normalized here onto one set of outcomes so the caller needn't care.
# Always exits 0; prints exactly one tab-separated line:
#   ACTIVE<TAB><jwt><TAB><expires_at>   verified (trial) or approved (recovery) — the license is in hand
#   PENDING<TAB>                        still waiting on the emailed link
#   REVOKED<TAB><message>               terminal: this trial was revoked
#   EXPIRED<TAB><message>               recovery only: the confirmation link lapsed unclicked
#   GONE<TAB><message>                  this server doesn't know that id (404)
#   ERR<TAB><message>                   transient/unknown — the caller keeps polling until its deadline
license_poll() { # uuid api-url [trial|recovery]
  ID="$1" U="$2" KIND="${3:-trial}" python3 - <<'PY'
import json,os,re,urllib.error,urllib.request
uid=os.environ["ID"]; base=os.environ["U"].rstrip("/"); kind=os.environ.get("KIND","trial")
def out(*f): print("\t".join(" ".join(str(x).split()) for x in f))
# The id goes straight into a URL path, and it can come from a hand-edited .env — accept only the shape
# the license server documents (^[0-9a-f-]{36}$) rather than URL-encoding whatever we were handed.
if not re.match(r'^[0-9a-fA-F-]{36}\Z',uid):
    out("GONE","'%.60s' is not a license request id"%uid); raise SystemExit(0)
if not base.lower().startswith(("http://","https://")):
    out("ERR","could not reach %s (LICENSE_API_URL has no http:// or https:// scheme)"%base)
    raise SystemExit(0)
try:
    sub="trial/recover/" if kind=="recovery" else "trial/"
    req=urllib.request.Request(base+"/api/licenses/"+sub+uid+"/",
        headers={"Accept":"application/json","User-Agent":"duplo-ai-extension-devkit run.sh"})
    with urllib.request.urlopen(req,timeout=20) as r:
        status=r.status; d=json.loads(r.read() or b"{}")
    if not isinstance(d,dict): d={}
    st=str(d.get("status") or "").strip().lower(); tok=d.get("license")
    if kind=="recovery":
        # A recovery is approved by the licensee clicking the emailed link; approval releases the SAME
        # stored token, so this lands on ACTIVE exactly like a verified trial does.
        if   st=="approved" and tok: out("ACTIVE",tok,d.get("expires_at") or "")
        elif st=="approved":         out("ERR","DuploCloud reports the recovery approved but returned no license")
        elif st=="expired":          out("EXPIRED","the confirmation link expired before it was clicked")
        else:                        out("PENDING","")
    elif st=="active" and tok: out("ACTIVE",tok,d.get("expires_at") or "")
    elif st=="active":         out("ERR","DuploCloud reports the request active but returned no license")
    elif st=="revoked":        out("REVOKED","DuploCloud reports this license as revoked")
    # pending, blank, or a status this script predates: keep waiting. Guessing "terminal" for an
    # unrecognized value would abandon a license that is about to be issued.
    else:                      out("PENDING","")
except urllib.error.HTTPError as e:                    # must stay first — HTTPError subclasses URLError
    body=e.read().decode("utf-8","replace").strip()[:200]
    if e.code==404: out("GONE","DuploCloud has no %s with id %s"%("recovery" if kind=="recovery" else "request",uid))
    elif e.code==429: out("ERR","rate-limited by DuploCloud (HTTP 429)")
    else: out("ERR","DuploCloud returned HTTP %s: %s"%(e.code,body or "no body"))
except (urllib.error.URLError,OSError) as e:           # DNS, refused, timeout, TLS — we never got a reply
    out("ERR","could not reach DuploCloud at %s (%s)"%(base,e))
except Exception as e:                                 # we got a reply but couldn't parse it (proxy/SSO page)
    out("ERR","DuploCloud at %s returned a response we couldn't read (%s)"%(base,e))
PY
}
# How long to wait for the verification click, and how often to ask. Overridable only to exercise the
# timeout path against a mock — there is deliberately no flag for either. The license server throttles this
# endpoint at 120/min per IP, so keep the interval well clear of that.
LICENSE_WAIT_SECS="${LICENSE_WAIT_SECS:-120}"
LICENSE_POLL_SECS="${LICENSE_POLL_SECS:-4}"
if [ "$LICENSE_WAIT_SECS" -ge 60 ]; then LICENSE_WAIT_HUMAN="$((LICENSE_WAIT_SECS / 60)) minute(s)"
else LICENSE_WAIT_HUMAN="$LICENSE_WAIT_SECS seconds"; fi
# Warn (never fail) when the license's email claim isn't the admin email we're configuring: the studio
# enforces the claim, so such a license silently won't authorize this install.
license_email_warn() {
  local le; le="$(jwt_claims "$1" | cut -f2 || true)"
  if [ -n "$le" ] && [ "$le" != "$EMAIL" ]; then
    echo "    ⚠ this license was issued to $le, not $EMAIL — the studio enforces the license's email claim." >&2
  fi
}
# Fetch the license behind one id — a trial request, or a recovery of a license this address already has —
# waiting for the emailed link to be clicked if it hasn't been yet. On success stores the JWT and sets LIC.
# Returns: 0 stored · 1 timed out · 2 terminal (revoked) · 3 unknown id · 4 the recovery link expired.
#
# The same id is polled in two very different situations: a request made seconds ago (nobody has clicked
# anything yet) and a license issued weeks ago that we're simply re-reading. Only the first needs "go check
# your email", and telling the second one to click a link it already clicked is how this read as broken. So
# the guidance is printed lazily — on the first PENDING, when it becomes true — and callers say nothing about
# verification up front. LICENSE_WAIT_SAW_PENDING records which situation it turned out to be, so the
# timeout message can be honest about whether we were waiting on you or on the server.
LICENSE_WAIT_SAW_PENDING=0
license_wait() { # uuid [trial|recovery]
  local id="$1" kind="${2:-trial}" deadline now resp rkind msg last="" waited=0 told=0
  LICENSE_WAIT_SAW_PENDING=0
  deadline=$(( $(date +%s) + LICENSE_WAIT_SECS ))
  while :; do
    resp="$(license_poll "$id" "$LICENSE_API" "$kind" || true)"
    rkind="$(printf '%s' "$resp" | cut -f1)"; msg="$(printf '%s' "$resp" | cut -f2)"
    case "$rkind" in
      ACTIVE)
        # Close the dot line if one is open (a first-poll hit never printed a "waiting" prefix), and word it
        # for what we were actually waiting on: a click, or just the server picking up the phone.
        if [ "$waited" = 1 ]; then printf ' '; else printf '    '; fi
        if [ "$LICENSE_WAIT_SAW_PENDING" = 1 ]; then
          if [ "$kind" = recovery ]; then echo "approved."; else echo "verified."; fi
        else echo "got it."; fi
        # Shape-check before it lands in .env: an unusable value written here would be sticky forever,
        # since every later run short-circuits on a non-empty Licensing__Token.
        jwt_ok "$msg" || {
          echo "  ✖ DuploCloud returned something that isn't a readable license JWT — not writing it to .env." >&2
          printf '    It said: %.200s\n' "${msg:-<empty>}" >&2
          echo "    Re-run ./run.sh: DuploCloud emails you a link that recovers this license. If you have" >&2
          echo "    the JWT already, supply it with ./run.sh --license <jwt>; otherwise contact DuploCloud." >&2
          exit 1; }
        setenv Licensing__Token "$msg"; LIC="$msg"
        license_email_warn "$LIC"
        license_warn_expiry "$LIC"
        return 0 ;;
      REVOKED) [ "$waited" = 1 ] && echo; echo "  ✖ $msg" >&2; return 2 ;;
      GONE)    [ "$waited" = 1 ] && echo; echo "  ✖ $msg" >&2; return 3 ;;
      EXPIRED) [ "$waited" = 1 ] && echo; echo "  ✖ $msg" >&2; return 4 ;;
      PENDING) LICENSE_WAIT_SAW_PENDING=1 ;;
      # Transport blips, a 429, a proxy hiccup: remember the last one and keep waiting. Only the deadline
      # ends the loop — a license that arrives on the next poll is worth more than a prompt fired early.
      ERR)     last="$msg" ;;
    esac
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && break
    # Say what we're waiting on the moment we know it — which needn't be the first poll, since a transport
    # blip can precede the first PENDING. If dots are already running, close that line before the notice
    # and open a fresh one after it.
    if [ "$told" = 0 ] && [ "$LICENSE_WAIT_SAW_PENDING" = 1 ]; then
      told=1
      [ "$waited" = 1 ] && { echo; waited=0; }
      if [ "$kind" = recovery ]; then
        echo "==> Check your email: we sent $EMAIL a confirmation link."
        echo "    Click it and press Approve — this run then continues on its own,"
        echo "    waiting up to $LICENSE_WAIT_HUMAN."
      else
        echo "==> Check your email: $EMAIL has to be verified before this run can continue."
        echo "    Click the verification link you were emailed — this run then continues on its own,"
        echo "    waiting up to $LICENSE_WAIT_HUMAN."
      fi
    fi
    if [ "$waited" = 0 ]; then waited=1; printf '    waiting'; fi
    printf '.'
    sleep "$LICENSE_POLL_SECS"
  done
  [ "$waited" = 1 ] && echo
  [ -n "$last" ] && echo "    (last response: $last)" >&2
  return 1
}
# What to print when license_wait gives up. $1 = return code, $2 = the id it polled, $3 = kind.
license_wait_failed() { # rc id [trial|recovery]
  local kind="${3:-trial}"
  case "$1" in
    2) echo "    That license can't be used. Contact DuploCloud for a license, or supply one you already" >&2
       echo "    have with ./run.sh --license <jwt>." >&2 ;;
    3) echo "    Nothing to wait for at ${LICENSE_API}. If you have a license already, supply it with" >&2
       echo "    ./run.sh --license <jwt>." >&2 ;;
    # The link lapsed unclicked. Cheap to fix and worth saying so plainly: one re-run sends a new one.
    4) echo "    Re-run ./run.sh and DuploCloud will email you a fresh link." >&2 ;;
    # Two different timeouts wearing one exit code. Blaming an unclicked link when the truth is that the
    # license server never answered sends people hunting through their spam folder for a problem that
    # isn't there — so only claim a pending verification if we actually saw one.
    *) if [ "$kind" = recovery ]; then
         echo "  ✖ Timed out after $LICENSE_WAIT_HUMAN waiting for the confirmation link to be clicked." >&2
         echo "    Nothing is lost. Click the link emailed to $EMAIL, then re-run ./run.sh: it resumes from" >&2
         echo "    recovery $2 (saved in .env), so a link clicked late still works and no second email is sent." >&2
       elif [ "$LICENSE_WAIT_SAW_PENDING" = 1 ]; then
         echo "  ✖ Timed out after $LICENSE_WAIT_HUMAN waiting for $EMAIL to be verified." >&2
         echo "    Nothing is lost: your verification is still pending, and completes the moment you" >&2
         echo "    click the link you were emailed. Then do either:" >&2
         echo "      ./run.sh                  — picks the license up automatically (request id $2, saved in .env)" >&2
         echo "      ./run.sh --license <jwt>  — if you already have the JWT" >&2
         # The other reason no link ever arrives, and the one the two lines above make worse by implying the
         # only thing to do is wait. Say it here, on the screen the mistyped address actually produces.
         echo "    Mistyped the address? ./run.sh --email <correct address> — that discards this request" >&2
         echo "    and starts a new one. (Nothing was issued to $EMAIL, so nothing is given up.)" >&2
       else
         echo "  ✖ Gave up after $LICENSE_WAIT_HUMAN — $LICENSE_API never answered." >&2
         echo "    Nothing is lost: request id $2 is saved in .env. Re-run ./run.sh once you can reach it," >&2
         echo "    or supply the JWT with ./run.sh --license <jwt> if you already have it." >&2
       fi ;;
  esac
}

# ── pre-flight: license checks (run before ANYTHING is written) ───────────────
# A license is not re-issuable: the server issues exactly ONE trial per email address. It is, however,
# RECOVERABLE — the server will email the licensee a link that releases the same license to this dev kit —
# so a lost token costs a click, not the address. Never assume the JWT itself reached their inbox: the
# server can be configured not to email license contents at all.
# The --reset-license guard below is the one that MUST run here, ahead of the block it guards, while .env is
# still untouched — moving it after would mean refusing a clear that had already happened. The --license shape
# check is hoisted for a different reason: validating it here rather than where it's consumed is what lets
# the guard read `[ -n "$F_LICENSE" ]` as "a usable license was supplied"; validated later, a mistyped
# --license would blank the old token first and reject the new one second, leaving you with neither.
if [ -n "$F_LICENSE" ]; then
  jwt_ok "$F_LICENSE" || { echo "--license doesn't parse as a license JWT (expected three dot-separated segments whose payload carries an email claim)." >&2
    echo "  Pass the bare token only — no surrounding quotes, spaces, or line breaks. It is validated exactly as given, because it is stored exactly as given." >&2
    exit 1; }
fi
# --reset-license discards every way back to your license — the JWT and both ids it can be re-pulled from.
# That's fine when a human can read the token we echo and put it back, but not when no one is watching.
# Recovery has since softened the consequence: the re-request would take the already-issued 400 and enter
# recovery rather than dead-end. The guard is kept anyway, deliberately — recovery costs the licensee an
# email round-trip, and a blind run has nobody to click the link — so refuse when we can't prompt (-y, or no
# tty) and no replacement license was supplied. There is no LICENSE_TRIAL_UUID / LICENSE_RECOVERY_UUID
# exemption: those ids are exactly what this flag throws away, so they can't also make throwing them away safe.
if [ "$RESET_LICENSE" = 1 ] && [ -z "$F_LICENSE" ]; then
  RESET_BLIND=""
  if [ "$NONINTERACTIVE" = 1 ]; then RESET_BLIND="--non-interactive was passed"
  elif [ ! -t 0 ]; then RESET_BLIND="stdin is not a terminal"; fi
  # Read here and again as OLDLIC in the --reset-license block below. Nothing between the two reads writes
  # Licensing__Token (the adopt-defaults block only touches $DEFAULT_KEYS), so the two agree by
  # construction — if that ever stops being true, this guard's "there is something here to clear" decision
  # and the value the clear block echoes would disagree.
  RESETLIC="$(getenv Licensing__Token)"
  if [ -n "$RESET_BLIND" ] && [ -n "$RESETLIC" ]; then
    echo "  ✖ --reset-license blanks Licensing__Token, and this run can't prompt you to paste it back ($RESET_BLIND)." >&2
    echo "    DuploCloud issues only ONE license per email address and will not re-issue this one:" >&2
    echo "    $RESETLIC" >&2
    echo "    Re-run with the same flags plus --license <jwt> (that value), or drop -y and run from a" >&2
    echo "    terminal, where a later run can recover the same license by emailing you a link." >&2
    echo "    (If you only meant to wipe the DB and start over, drop --reset-license: plain --reset keeps your license.)" >&2
    exit 1
  fi
fi

# Retire the old amd64 studio pin before the adoption pass below, which rewrites .env.defaults and would
# otherwise destroy the evidence this migration depends on.
runtime_migrate_studio_platform "$ENV" .env.defaults

# ── adopt changed framework defaults from .env.example (survives dev-kit upgrades) ──
# Framework-shipped defaults (image tags, platform) live in .env.example and change on `upgrade_dev_kit.sh`,
# which never touches your .env. We adopt a new default into .env ONLY when you haven't diverged from the
# previously-applied default — a tag you pinned (--studio-tag/--ui-tag/--agent-tag or a hand-edit) is always
# kept. The last-applied defaults are remembered in .env.defaults (git-ignored) so we can tell "you changed
# it" from "the default changed". To re-track a pinned key, delete its line from .env (or .env.defaults).
DEFAULTS_LOCK=.env.defaults
DEFAULT_KEYS="STUDIO_TAG AGENT_TAG UI_TAG XTERM_TAG STUDIO_PLATFORM"   # add ports/DUPLO_TARGET here to track them too
if [ -f .env.example ]; then
  adopted=""
  for k in $DEFAULT_KEYS; do
    ex="$(getfrom .env.example "$k")"; [ -z "$ex" ] && continue        # only track keys the example ships non-blank
    base="$(getfrom "$DEFAULTS_LOCK" "$k")"
    cur="$(getenv "$k")"
    if [ -z "$cur" ] || [ "$cur" = "$base" ]; then                     # untouched by you → follow the example
      if [ "$cur" != "$ex" ]; then setenv "$k" "$ex"; adopted="$adopted $k=$ex"; fi
    fi                                                                  # else: your override → keep it
  done
  # Rewrite the lock to the current example defaults (the new baseline for next time).
  : > "$DEFAULTS_LOCK"
  for k in $DEFAULT_KEYS; do ex="$(getfrom .env.example "$k")"; [ -n "$ex" ] && printf '%s=%s\n' "$k" "$ex" >> "$DEFAULTS_LOCK"; done
  [ -n "$adopted" ] && echo "==> Adopted updated defaults from .env.example:$adopted"
fi

# ── --reset: wipe DB + configured values ──────────────────────────────────────
# Licensing__Token and LICENSE_TRIAL_UUID are deliberately NOT in the cleared-key list: a license is not
# stack state, nothing about a fresh DB invalidates it, and the server will not issue a second one for this
# address. Clearing it here would only mean re-fetching the identical string a moment later — and dead-ending
# whenever that fetch failed. --reset-license (below) is how you ask for it to actually go away.
if [ "$RESET" = 1 ]; then
  echo "==> --reset: tearing down stack + volumes (DB, extensions, file store)…"
  "$RUNTIME" compose down -v 2>/dev/null || true
  for k in Authentication__LocalAdminEmail Authentication__LocalAdminPassword Authentication__SuperUsers \
           DEVKIT_MODEL ANTHROPIC_API_KEY AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
           CLAUDE_MODEL CLAUDE_EXTRA_MODELS "${GATEWAY_KEYS[@]}" "${SUBSCRIPTION_KEYS[@]}" \
           Encryption__MasterKey Authentication__JwtSharedSecret DUPLO_ADMIN_TOKEN EXTENSION_DEV_WORKSPACE_ID \
           EXTENSION_DEV_PERMSET_ID EXTENSION_DEV_PERMSETGROUP_ID \
           QDRANT_PROVIDER_ID QDRANT_SCOPE_ID QDRANT_COLLECTION_ID; do
    setenv "$k" ""
  done
  # Also drop any _STASH_<KEY>= lines scripts/switch-llm.sh left behind for a provider swap — a reset
  # is meant to be total, and a stashed credential surviving it would quietly reappear on the next
  # ./scripts/switch-llm.sh back to that provider.
  for k in $(grep -oE '^_STASH_[A-Za-z0-9_]+' "$ENV" 2>/dev/null || true); do setenv "$k" ""; done
  # Don't advertise keeping the license when --reset-license is about to take it: the block below says so.
  if [ "$RESET_LICENSE" = 1 ]; then echo "    cleared configured values."
  else echo "    cleared configured values (your license is kept)."; fi
fi

# ── --reset-license: forget the license and the request id it came from ───────
if [ "$RESET_LICENSE" = 1 ]; then
  # The pre-flight section above has already refused the cases where losing this token would be silent.
  OLDLIC="$(getenv Licensing__Token)"
  # On stderr, not stdout: this is the last chance to see the token before it's cleared, and it has to
  # survive `./run.sh --reset-license > some.log`. It isn't the only copy — a later run can recover the same
  # license by email — but that costs a click, and the server will never issue a second one.
  if [ -n "$OLDLIC" ]; then
    echo "==> Clearing your license. DuploCloud issues only ONE license per email address and won't" >&2
    echo "    re-issue it — restore this value with ./run.sh --license <jwt>, or let a later run" >&2
    echo "    recover it by emailing you a confirmation link:" >&2
    echo "    $OLDLIC" >&2
  fi
  # The request id goes too, and so does any recovery handle: an approved recovery keeps serving the same
  # token, so leaving either behind would make the clear a no-op — the license block would re-pull the very
  # license we just discarded. "Forget the license" has to mean forgetting every handle to it.
  { [ -n "$(getenv LICENSE_TRIAL_UUID)" ] || [ -n "$(getenv LICENSE_RECOVERY_UUID)" ]; } &&
    echo "    (Dropping the request id as well, so nothing re-fetches it.)" >&2
  setenv LICENSE_TRIAL_UUID ""
  setenv LICENSE_RECOVERY_UUID ""
  # The address those ids were requested for goes with them: it exists only to say whose the ids are, so
  # keeping it once they're gone would leave a stale name to compare a future request against.
  setenv LICENSE_REQUEST_EMAIL ""
  # Replace rather than clear-then-maybe-write: the write in the license block is ~90 lines and one
  # email gate away, and a run that exits in between must not leave the key transiently empty.
  if [ -n "$F_LICENSE" ]; then setenv Licensing__Token "$F_LICENSE"; else setenv Licensing__Token ""; fi
  echo "    cleared the license."
fi

# ── resolve a value: flag > .env > prompt ─────────────────────────────────────
resolve() { # flagval envkey prompt [secret]
  local cur="$1" envkey="$2" prompt="$3" secret="${4-}"
  [ -z "$cur" ] && cur="$(getenv "$envkey")"
  if [ -z "$cur" ]; then
    [ "$NONINTERACTIVE" = 1 ] && { echo "Missing $envkey — pass its flag (non-interactive)." >&2; exit 1; }
    if [ "$secret" = secret ]; then read -rs -p "$prompt: " cur; echo >&2; else read -r -p "$prompt: " cur; fi
  fi
  printf '%s' "$cur"
}

# The Bedrock model id the dev kit runs on — also what detect-bedrock.sh probes, so a successful
# probe proves invoke permission on the exact model the agent will call (not just "some" Bedrock access).
# BEDROCK_EXTRA_MODELS are offered alongside it in the ticket LLM picker (not probed — a missing Opus
# inference profile shows up as a failed ticket, not a failed setup).
BEDROCK_PROBE_MODEL="us.anthropic.claude-sonnet-5"
BEDROCK_EXTRA_MODELS="us.anthropic.claude-opus-5"

echo "==> Setup (prompts appear only for values not already set)…"
# Very basic email sanity check: name@example.com (no spaces).
email_valid() { printf '%s' "$1" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; }
# Same address? Compared case-insensitively: mail domains are case-insensitive and plenty of people
# capitalise their own name, so Andy@Example.com and andy@example.com are one person. Only used to decide
# whether a saved license request still belongs to the address in front of us — treating those two as
# different would throw away a perfectly live request over nothing.
email_eq() { # a b
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}
EMAIL="$(resolve "$F_EMAIL" Authentication__LocalAdminEmail 'Admin email')"
while ! email_valid "$EMAIL"; do
  echo "Invalid email address: '${EMAIL:-<empty>}' (expected name@example.com)." >&2
  { [ "$NONINTERACTIVE" = 1 ] || [ -n "$F_EMAIL" ]; } && exit 1
  read -r -p 'Admin email: ' EMAIL
done

# ── license (BEGIN LICENSE BLOCK) ────────────────────────────────────────────
# The dev kit is licensed. The trial license is issued to the admin email above (the company
# is derived from its domain) and stored as Licensing__Token, which the studio container reads
# through docker-compose's env_file (→ Licensing:Token). ONE trial per email address: if the server says it
# already issued one, we recover that license rather than asking for anything — the server emails the
# licensee a link, and clicking it releases the same token to this dev kit.
# The license server verifies the address before it issues anything: the POST returns a trial id and an
# email goes out, and the license only exists once the recipient clicks the link. We save that id as
# LICENSE_TRIAL_UUID (and a recovery's id as LICENSE_RECOVERY_UUID) and poll it, so an interrupted or
# timed-out run resumes instead of starting over — re-requesting is not an option, the second POST just
# takes the already-issued 400.
# The license server is a built-in default, not a shipped .env key — the studio defaults to the same host
# on its side. Setting LICENSE_API_URL in .env still overrides it, for when DuploCloud says to point
# somewhere else; nothing writes that key, so it stays yours once you add it.
LICENSE_API="$(getenv LICENSE_API_URL)"; [ -z "$LICENSE_API" ] && LICENSE_API="https://console.duplocloud.com"
LIC="$(getenv Licensing__Token)"
if [ -n "$F_LICENSE" ]; then
  # Shape already checked in pre-flight (before --reset-license could blank the token it replaces).
  setenv Licensing__Token "$F_LICENSE"; LIC="$F_LICENSE"
  echo "==> License set from --license."
  license_warn_expiry "$LIC"
elif [ -n "$LIC" ]; then
  # Silent on the happy path: a license that is present and fine is not news. license_email_warn and
  # license_warn_expiry print only when something is actually wrong (wrong address, expiring, expired).
  license_email_warn "$LIC"
  license_warn_expiry "$LIC"
else
  # Whose request is it? A saved id is only worth polling if it belongs to the address we are licensing.
  # Mistype the email on the first run and that run stores an id for the typo'd address, the verification
  # mail goes to an inbox nobody reads, and the run times out — leaving behind an id that every later run
  # would re-poll, re-sending to the same wrong address. Correcting the address wouldn't help, not even with
  # --email: the id outranks it. That is a dead end with no way out of the CLI, so close it here. If the
  # address changed, these ids are handles to somebody else's request; drop them and license the address
  # actually in front of us. Nothing is lost — an unverified request holds no license.
  # Only when we have a stored address to compare against: a .env written by an older dev kit carries the ids
  # and no LICENSE_REQUEST_EMAIL, and a resumable request must not be discarded merely because this upgrade
  # can't tell whose it is. An issued license is never in scope — a non-empty Licensing__Token took the branch
  # above, where license_email_warn flags a mismatched address without touching a token the server won't re-issue.
  REQ_EMAIL="$(getenv LICENSE_REQUEST_EMAIL)"
  if [ -n "$REQ_EMAIL" ] && ! email_eq "$REQ_EMAIL" "$EMAIL"; then
    echo "==> Admin email changed (was $REQ_EMAIL, now $EMAIL)."
    echo "    Discarding the pending license request for $REQ_EMAIL — it can only ever verify that address."
    setenv LICENSE_TRIAL_UUID ""
    setenv LICENSE_RECOVERY_UUID ""
    setenv LICENSE_REQUEST_EMAIL ""
  fi
  # Re-fetch first, request second. An id in .env already names a license — issued, or one click away from
  # it — and re-POSTing could only take the already-issued 400 and start the recovery dance over. This is
  # the whole story for a timed-out run, a Ctrl-C during the wait, and a hand-blanked Licensing__Token
  # (blank the line, keep the id, and the next run pulls your license back down).
  #
  # A saved recovery outranks a saved trial id: it is the newer handle, and the one that survives a link
  # clicked after this script gave up waiting. An approved recovery keeps serving the token, so this also
  # quietly re-pulls the license whenever Licensing__Token alone is blanked.
  REC_ID="$(getenv LICENSE_RECOVERY_UUID)"
  if [ -n "$REC_ID" ]; then
    echo "==> Fetching your license (recovery $REC_ID)…"
    WRC=0; license_wait "$REC_ID" recovery || WRC=$?
    case "$WRC" in
      0) : ;;                        # LIC is set — everything below is skipped
      # Unknown id (a changed LICENSE_API_URL, a hand-edited value) or a link that lapsed unclicked: the
      # handle is spent either way. Drop it and fall through — the request below re-enters recovery, and
      # the server emails a fresh link.
      3|4) echo "    Requesting a fresh confirmation link." >&2
           setenv LICENSE_RECOVERY_UUID ""; REC_ID="" ;;
      *) license_wait_failed "$WRC" "$REC_ID" recovery; exit 1 ;;
    esac
  fi
  TRIAL_ID="$(getenv LICENSE_TRIAL_UUID)"
  if [ -z "$LIC" ] && [ -n "$TRIAL_ID" ]; then
    # Deliberately neutral: this id may be an unverified request from a minute ago or a license issued long
    # ago that we're just re-reading, and only the first poll knows which. license_wait prints the
    # check-your-email guidance itself if it turns out to be needed.
    echo "==> Fetching your license (request id $TRIAL_ID)…"
    WRC=0; license_wait "$TRIAL_ID" || WRC=$?
    case "$WRC" in
      0) : ;;                        # LIC is set — the request loop below is skipped
      3) # This server has never heard of that id (wrong LICENSE_API_URL, or a hand-edited value). Drop it
         # and request normally rather than stranding the run on a pointer to nothing.
         echo "    Ignoring it and requesting a fresh license." >&2
         setenv LICENSE_TRIAL_UUID ""; TRIAL_ID="" ;;
      *) license_wait_failed "$WRC" "$TRIAL_ID"; exit 1 ;;
    esac
  fi
fi
if [ -z "$LIC" ]; then
  # ${…} braces are required: in a UTF-8 locale bash reads the following '…' bytes as part of the
  # variable name, so a bare "$EMAIL…" dies under `set -u` as an unbound variable.
  echo "==> Verifying your email address ${EMAIL}…"
  TRIES=0
  while :; do
    TRIES=$((TRIES+1))
    RESP="$(license_request "$EMAIL" "$LICENSE_API" || true)"
    KIND="$(printf '%s' "$RESP" | cut -f1)"; MSG="$(printf '%s' "$RESP" | cut -f2)"
    case "$KIND" in
      OK)
        # Shape-check the server's own token before it lands in .env. An unusable value written here
        # would be sticky forever: every later run short-circuits on the non-empty token, so the CLI
        # could never recover on its own.
        jwt_ok "$MSG" || {
          echo "  ✖ DuploCloud returned something that isn't a readable license JWT — not writing it to .env." >&2
          printf '    It said: %.200s\n' "${MSG:-<empty>}" >&2   # capped: the license field is not a message
          echo "    This address may still count as used, so don't try another one. Re-run ./run.sh to" >&2
          echo "    recover the license by email link, or contact DuploCloud." >&2
          exit 1; }
        setenv Licensing__Token "$MSG"; LIC="$MSG"
        echo "    done."
        license_warn_expiry "$LIC"
        break ;;
      PENDING)
        # The server accepted the request and emailed a verification link; the license doesn't exist until
        # that link is clicked. Persist the trial id BEFORE waiting: a Ctrl-C, a closed laptop, or the
        # timeout below must all leave behind something the next run can poll, because the address is
        # already spent and a second POST can only 400.
        setenv LICENSE_TRIAL_UUID "$MSG"
        # And the address it was made for, written in the same breath so the two can never disagree. It is the
        # only record of whose request this is: Authentication__LocalAdminEmail isn't written until ~120 lines
        # below, and the timed-out run that makes this id matter exits long before reaching it.
        setenv LICENSE_REQUEST_EMAIL "$EMAIL"
        # No "check your email" banner here: license_wait prints it on the first PENDING, which for a
        # just-created request is the very next line anyway. One copy, printed where it's known to be true.
        WRC=0; license_wait "$MSG" || WRC=$?
        [ "$WRC" = 0 ] || { license_wait_failed "$WRC" "$MSG"; exit 1; }
        break ;;
      EMAIL)
        echo "  ✖ $MSG" >&2
        [ "$NONINTERACTIVE" = 1 ] && { echo "    Re-run with --email <addr> — most work and personal addresses are accepted; privacy-relay and disposable domains are not." >&2; exit 1; }
        [ "$TRIES" -ge 3 ] && { echo "Giving up after $TRIES attempts — re-run with --email <addr>." >&2; exit 1; }
        read -r -p 'Email address: ' EMAIL || { echo "No email provided — re-run with --email <addr>." >&2; exit 1; }
        while ! email_valid "$EMAIL"; do
          echo "Invalid email address: '${EMAIL:-<empty>}' (expected name@example.com)." >&2
          read -r -p 'Email address: ' EMAIL || { echo "No email provided — re-run with --email <addr>." >&2; exit 1; }
        done ;;
      ISSUED)
        # The address already has a trial. When the server can recover it this is not an error the user has
        # to act on — so don't print one: POST the recovery endpoint and the license comes back the moment
        # they click the link it emails. Nothing is re-issued; recovery returns the same token and expiry.
        RECPATH="$(printf '%s' "$RESP" | cut -f3)"
        if [ -z "$RECPATH" ]; then
          # No recovery offered: an older license server, or a trial that was revoked rather than issued.
          echo "  ✖ $MSG" >&2
          echo "    DuploCloud issues one license per address and has no recovery for this one. Supply the" >&2
          echo "    license you already have with ./run.sh --license <jwt>, or contact DuploCloud." >&2
          exit 1
        fi
        echo "==> $EMAIL is already registered — recovering your existing license."
        RRESP="$(license_recover "$EMAIL" "$LICENSE_API" "$RECPATH" || true)"
        RKIND="$(printf '%s' "$RRESP" | cut -f1)"; RMSG="$(printf '%s' "$RRESP" | cut -f2)"
        case "$RKIND" in
          OK) : ;;
          NONE)
            echo "  ✖ $RMSG" >&2
            echo "    Supply the license you already have with ./run.sh --license <jwt>, or contact DuploCloud." >&2
            exit 1 ;;
          *)
            echo "  ✖ ${RMSG:-recovery request failed}" >&2
            echo "    Nothing was lost and nothing was re-issued — re-run ./run.sh once that's resolved." >&2
            exit 1 ;;
        esac
        # Persist the handle BEFORE waiting. A Ctrl-C, a closed laptop, or the timeout below must leave
        # behind the id that lets the next run collect a link clicked late — without it the server would see
        # no pending recovery and email a second link the user has to click all over again.
        setenv LICENSE_RECOVERY_UUID "$RMSG"
        setenv LICENSE_REQUEST_EMAIL "$EMAIL"      # same reason as the trial id above: the handle is per-address
        WRC=0; license_wait "$RMSG" recovery || WRC=$?
        [ "$WRC" = 0 ] || { license_wait_failed "$WRC" "$RMSG" recovery; exit 1; }
        break ;;
      *)
        echo "  ✖ ${MSG:-license request failed}" >&2
        echo "    The dev kit is licensed and can't start without one — fix the above and re-run ./run.sh." >&2
        # Once the token is blank (a --reset-license, a fresh clone) the next run takes the already-issued
        # 400 — which is now the entrance to recovery, not a dead end. Say so, and name the shortcut.
        echo "    If a license already exists for this address, re-running is enough: DuploCloud emails" >&2
        echo "    you a link that recovers it. Or supply the JWT directly: ./run.sh --license <jwt>" >&2
        exit 1 ;;
    esac
  done
fi
# (END LICENSE BLOCK)

PASSWORD="$(resolve "$F_PASSWORD" Authentication__LocalAdminPassword 'Admin password' secret)"
MODEL="$F_MODEL"; [ -z "$MODEL" ] && MODEL="$(getenv DEVKIT_MODEL)"
if [ -z "$MODEL" ]; then
  [ "$NONINTERACTIVE" = 1 ] && { echo "Missing DEVKIT_MODEL — pass --model 1|2|3|4|5|anthropic|bedrock|gateway|bedrock-instance-role|subscription." >&2; exit 1; }
  # On an EC2 dev box the instance profile is usually already allowed to invoke Bedrock, in which
  # case no keys are needed at all — offer that as option 4 but never preselect it. Options 1–3 are
  # fixed regardless of the probe so `--model 3` always means the same thing on every machine.
  echo "==> Checking for AWS Bedrock access via an EC2 instance role…" >&2
  BEDROCK_AVAILABLE=0; BEDROCK_REASON=""; BEDROCK_REGION=""; AWS_ROLE=""; CONTAINER_IMDS=""
  # Every pipeline here needs `|| true`: this script runs under `set -euo pipefail`, and a grep that
  # matches nothing exits 1, which pipefail propagates and set -e turns into a silent abort. The probe
  # legitimately produces no output at all when it can't run (e.g. no python3 on a bare laptop), so
  # without these guards the script would die right here instead of falling back to the key-based menu.
  # Detection is strictly an optimisation — it must never be able to stop you starting the stack.
  IR_OUT="$(./scripts/detect-bedrock.sh "$BEDROCK_PROBE_MODEL" 2>/dev/null || true)"
  IR_VARS="$(printf '%s\n' "$IR_OUT" | grep -E '^(BEDROCK_AVAILABLE|BEDROCK_REGION|AWS_ROLE|CONTAINER_IMDS)=' \
             | sed -E 's/^([A-Z_]+)=(.*)$/\1="\2"/' || true)"
  [ -n "$IR_VARS" ] && eval "$IR_VARS"
  if [ "$BEDROCK_AVAILABLE" != 1 ]; then
    BEDROCK_REASON="$(printf '%s\n' "$IR_OUT" | grep -E '^BEDROCK_REASON=' | cut -d= -f2- | cut -c1-120 || true)"
    [ -n "$BEDROCK_REASON" ] || BEDROCK_REASON="probe produced no result (missing python3?)"
  fi
  # CONTAINER_IMDS is ok | blocked | unknown:<why>. Only a definite `blocked` withholds option 3 —
  # that one means the container test ran and failed (the hop limit), so the role would break at
  # runtime. `unknown:` means we couldn't run the test at all (no runtime yet, daemon down, busybox
  # not pullable); the role itself is proven, so offer it with the caveat rather than hiding a
  # working option because our own check couldn't execute.
  if [ "$BEDROCK_AVAILABLE" = 1 ] && [ "$CONTAINER_IMDS" != blocked ]; then
    IMDS_CAVEAT=""
    case "$CONTAINER_IMDS" in
      ok) printf '    ✔ instance role %s can invoke Bedrock in %s (no keys needed)\n' "$AWS_ROLE" "$BEDROCK_REGION" >&2 ;;
      *)  IMDS_CAVEAT=" — unverified from a container: ${CONTAINER_IMDS#unknown:}"
          printf '    ✔ instance role %s can invoke Bedrock in %s (no keys needed)\n' "$AWS_ROLE" "$BEDROCK_REGION" >&2
          printf '      could not confirm containers can reach IMDS (%s); if the agent later fails to\n' "${CONTAINER_IMDS#unknown:}" >&2
          printf '      authenticate, raise the IMDSv2 hop limit to 2 (see README).\n' >&2 ;;
    esac
    printf 'Select LLM provider:\n  1) anthropic (API key)\n  2) bedrock (AWS keys)\n  3) LLM gateway (OpenRouter, Bifrost, LiteLLM, … — any Anthropic-compatible endpoint)\n  4) bedrock via this EC2 instance role — %s @ %s, no keys%s\n  5) Claude Code subscription (your own, via `claude setup-token`)\n' \
      "$AWS_ROLE" "$BEDROCK_REGION" "$IMDS_CAVEAT" >&2
    read -r -p 'Enter 1, 2, 3, 4 or 5: ' MODEL
  else
    if [ "$BEDROCK_AVAILABLE" = 1 ]; then
      # Host reached IMDS but a container couldn't — almost always the IMDSv2 PUT-response hop limit
      # of 1. Offering the role here would produce a stack that starts and fails on every turn.
      echo "    ✗ instance role works on the host, but containers can't reach IMDS (hop limit) — see below." >&2
      echo "      Fix: aws ec2 modify-instance-metadata-options --instance-id <id> --http-put-response-hop-limit 2" >&2
    else
      echo "    ✗ no usable instance-role Bedrock access${BEDROCK_REASON:+ ($BEDROCK_REASON)}." >&2
    fi
    printf 'Select LLM provider:\n  1) anthropic (API key)\n  2) bedrock (AWS keys)\n  3) LLM gateway (OpenRouter, Bifrost, LiteLLM, … — any Anthropic-compatible endpoint)\n  5) Claude Code subscription (your own, via `claude setup-token`)\n' >&2
    read -r -p 'Enter 1, 2, 3 or 5: ' MODEL
  fi
fi
MODEL="$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')"
# accept numeric from menu/--model/.env
case "$MODEL" in 1) MODEL=anthropic;; 2) MODEL=bedrock;; 3) MODEL=gateway;; 4) MODEL=bedrock-instance-role;; 5) MODEL=subscription;; esac

setenv Authentication__LocalAdminEmail "$EMAIL"
setenv Authentication__LocalAdminPassword "$PASSWORD"
setenv Authentication__SuperUsers "$EMAIL"
setenv DEVKIT_MODEL "$MODEL"
setenv AIStudio__IsMasterDisabled true
[ -n "$(getenv Authentication__FrontendBaseUrl)" ] || setenv Authentication__FrontendBaseUrl "http://localhost:$(getenv UI_PORT 2>/dev/null || echo 4200)"
# Stable secrets: generate once; --reset already blanked them so they regenerate on a fresh DB.
[ -n "$(getenv Encryption__MasterKey)" ] || setenv Encryption__MasterKey "$(openssl rand -base64 96 | tr -d '\n')"
[ -n "$(getenv Authentication__JwtSharedSecret)" ] || setenv Authentication__JwtSharedSecret "$(openssl rand -hex 32)"

if [ "$MODEL" = anthropic ]; then
  KEY="$(resolve "$F_ANTHROPIC" ANTHROPIC_API_KEY 'Anthropic API key' secret)"
  setenv ANTHROPIC_API_KEY "$KEY"
  setenv CLAUDE_MODEL "claude-sonnet-5"
  setenv CLAUDE_EXTRA_MODELS "claude-opus-5"
  # A gateway URL left over from a previous provider choice would make the agent send this key to the
  # gateway instead of api.anthropic.com (key + URL = "proxy in front of Anthropic"). Warn, don't clear.
  [ -z "$(getenv ANTHROPIC_BASE_URL)" ] || echo "    note: ANTHROPIC_BASE_URL is still set in .env — the agent will send your Anthropic key THERE, not to api.anthropic.com. Clear it (or ./run.sh --reset) unless that's intended."
  # Existing AWS creds/region in .env are left untouched (only --reset clears them). The region default
  # is still needed: the agent's title LLM is Bedrock-only, and a valid region keeps its client from
  # crash-looping on a malformed endpoint. With no AWS creds the title call no-ops (caught).
  [ -n "$(getenv AWS_REGION)" ] || setenv AWS_REGION "us-east-1"
elif [ "$MODEL" = bedrock-instance-role ]; then
  # No static keys: the agent's credential chain falls through to IMDS and picks up the instance
  # role. Empty AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (which compose always passes) do NOT
  # short-circuit that chain, so we deliberately blank them rather than unsetting them.
  #
  # This arm (and gateway's ANTHROPIC_API_KEY blank) still blanks credentials outside --reset. That is
  # not credential hygiene (the other arms deliberately leave .env alone) — it is load-bearing: a leftover
  # static key, Anthropic key or gateway URL would win the precedence chain and the instance role would
  # never be consulted.
  RG="$F_AWS_REGION"
  # Re-runs are silent: a region already in .env is reused without re-probing (same as the other
  # providers, which aren't re-validated either). --reset or a blank AWS_REGION forces a fresh probe.
  [ -z "$RG" ] && [ -z "${BEDROCK_REGION:-}" ] && RG="$(getenv AWS_REGION)"
  if [ -z "$RG" ]; then
    # Probe when --model was passed directly (the menu path already resolved a region).
    if [ -z "${BEDROCK_REGION:-}" ]; then
      echo "==> Verifying instance-role Bedrock access…"
      # Unlike the menu path, failing here is correct — you asked for this provider explicitly, so we
      # refuse rather than silently fall back. But still guard the greps (see the note above) so the
      # failure is a clear message and not an abort with no output.
      if ! IR_OUT="$(./scripts/detect-bedrock.sh "$BEDROCK_PROBE_MODEL" 2>/dev/null)"; then
        WHY="$(printf '%s\n' "$IR_OUT" | grep -E '^BEDROCK_REASON=' | cut -d= -f2- || true)"
        echo "Instance-role Bedrock access is not available: ${WHY:-probe produced no result (missing python3?)}" >&2
        echo "Use --model anthropic or --model bedrock with explicit keys." >&2; exit 1
      fi
      IR_VARS="$(printf '%s\n' "$IR_OUT" | grep -E '^(BEDROCK_REGION|AWS_ROLE|CONTAINER_IMDS)=' \
                 | sed -E 's/^([A-Z_]+)=(.*)$/\1="\2"/' || true)"
      [ -n "$IR_VARS" ] && eval "$IR_VARS"
      # Same ok|blocked|unknown:<why> distinction as the menu: refuse only a proven block. An
      # unverifiable check is not evidence of a problem, and you asked for this provider explicitly.
      case "${CONTAINER_IMDS:-}" in
        ok) ;;
        blocked) echo "Containers cannot reach IMDS (IMDSv2 hop limit) — raise --http-put-response-hop-limit to 2, or use explicit keys." >&2; exit 1 ;;
        *) echo "    note: could not verify container IMDS access (${CONTAINER_IMDS#unknown:}) — proceeding. If the agent fails to authenticate, raise the IMDSv2 hop limit to 2." >&2 ;;
      esac
    fi
    RG="$BEDROCK_REGION"
  fi
  for k in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL; do setenv "$k" ""; done
  setenv AWS_REGION "$RG"
  setenv CLAUDE_MODEL "$BEDROCK_PROBE_MODEL"
  setenv CLAUDE_EXTRA_MODELS "$BEDROCK_EXTRA_MODELS"
  echo "    using EC2 instance role${AWS_ROLE:+ ($AWS_ROLE)} for Bedrock in $RG — no keys stored in .env."
elif [ "$MODEL" = bedrock ]; then
  AK="$(resolve "$F_AWS_KEY" AWS_ACCESS_KEY_ID 'AWS access key id')"
  SK="$(resolve "$F_AWS_SECRET" AWS_SECRET_ACCESS_KEY 'AWS secret access key' secret)"
  ST="$F_AWS_TOKEN"; [ -z "$ST" ] && ST="$(getenv AWS_SESSION_TOKEN)"
  RG="$F_AWS_REGION"; [ -z "$RG" ] && RG="$(getenv AWS_REGION)"; [ -z "$RG" ] && RG="us-west-2"
  setenv AWS_ACCESS_KEY_ID "$AK"; setenv AWS_SECRET_ACCESS_KEY "$SK"; setenv AWS_SESSION_TOKEN "$ST"; setenv AWS_REGION "$RG"
  setenv CLAUDE_MODEL "$BEDROCK_PROBE_MODEL"
  setenv CLAUDE_EXTRA_MODELS "$BEDROCK_EXTRA_MODELS"
  # The agent picks its provider by precedence ANTHROPIC_API_KEY → gateway → Azure → Bedrock (docker-compose.yml),
  # so a leftover Anthropic key silently wins over Bedrock. We no longer clear it (only --reset does) — warn.
  [ -z "$(getenv ANTHROPIC_API_KEY)" ] || echo "    note: ANTHROPIC_API_KEY is still set in .env — the agent prefers it over Bedrock. Clear it (or ./run.sh --reset) to force Bedrock."
  [ -z "$(getenv ANTHROPIC_BASE_URL)" ] || echo "    note: ANTHROPIC_BASE_URL is still set in .env — the agent prefers a gateway over Bedrock. Clear it (or ./run.sh --reset) to force Bedrock."
elif [ "$MODEL" = gateway ]; then
  # Prompts, validation and the load-bearing ANTHROPIC_API_KEY blank all live in scripts/_provider_gateway.sh.
  provider_gateway_configure || exit 1
elif [ "$MODEL" = subscription ]; then
  # Prompt, validation and the load-bearing ANTHROPIC_API_KEY/ANTHROPIC_BASE_URL blanks live in
  # scripts/_provider_subscription.sh.
  provider_subscription_configure || exit 1
else
  echo "Unknown model '$MODEL' (use anthropic, bedrock, gateway, bedrock-instance-role, or subscription)." >&2; exit 1
fi

# Optional image-tag overrides
[ -n "$F_STUDIO_TAG" ] && setenv STUDIO_TAG "$F_STUDIO_TAG"
[ -n "$F_UI_TAG" ] && setenv UI_TAG "$F_UI_TAG"
[ -n "$F_AGENT_TAG" ] && setenv AGENT_TAG "$F_AGENT_TAG"
for v in STUDIO_TAG UI_TAG; do
  [ -n "$(getenv "$v")" ] || { echo "  .env: $v is not set (pass --${v%_TAG}-tag or set in .env)." >&2; exit 1; }
done

# ── start the stack ───────────────────────────────────────────────────────────
# Name the runtime here, not only when something breaks: auto-detect is presence-based and docker-first,
# so on a box with both installed the choice is otherwise invisible until it goes wrong.
echo "==> Using $(runtime_label)"
echo "==> Pulling images…"; "$RUNTIME" compose pull
echo "==> Starting…"; "$RUNTIME" compose up -d

STUDIO_PORT="$(getenv STUDIO_PORT)"; [ -z "$STUDIO_PORT" ] && STUDIO_PORT=60021
UI_PORT="$(getenv UI_PORT)"; [ -z "$UI_PORT" ] && UI_PORT=4200
API="http://localhost:$STUDIO_PORT"
echo -n "==> Waiting for studio at $API "
for _ in $(seq 1 90); do
  curl -fsS --max-time 4 "$API/healthz" >/dev/null 2>&1 && { echo " ready."; break; }
  echo -n "."; sleep 3
done

# ── permanent admin token (idempotent) ────────────────────────────────────────
token_ok() { curl -fsS -o /dev/null --max-time 6 "$API/v1/aiservicedesk/admin/extensions" -H "Authorization: Bearer $1" 2>/dev/null; }
TOK="$(getenv DUPLO_ADMIN_TOKEN)"
if [ -z "$TOK" ] || ! token_ok "$TOK"; then
  echo "==> Minting permanent admin API token…"
  JWT="$(curl -fsS --max-time 10 -X POST "$API/api/Account/PasswordLogin" -H "Content-Type: application/json" \
        --data "$(E="$EMAIL" P="$PASSWORD" python3 -c 'import json,os;print(json.dumps({"username":os.environ["E"],"password":os.environ["P"]}))')" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null)"
  [ -n "$JWT" ] || { echo "Login failed for $EMAIL — check the admin email/password (./run.sh --reset to re-enter)." >&2; exit 1; }
  # The server caps active API tokens per user (10). Each mint whose plaintext is lost from .env (a
  # --reset, a fresh .env, a partial run) leaves a stale active token, so re-runs eventually hit the cap
  # and minting 400s. Revoke our own prior 'dev-kit-admin' tokens first so a fresh mint always has room.
  curl -fsS --max-time 10 "$API/v1/aiservicedesk/user/data/apitokens" -H "Authorization: Bearer $JWT" 2>/dev/null \
    | python3 -c 'import sys,json
for t in (json.load(sys.stdin) or []):
    if t.get("name")=="dev-kit-admin" and t.get("isActive"): print(t["id"])' 2>/dev/null \
    | while read -r tid; do
        [ -n "$tid" ] && curl -fsS -o /dev/null -X DELETE "$API/v1/aiservicedesk/user/data/apitokens/$tid" -H "Authorization: Bearer $JWT" 2>/dev/null || true
      done
  RESP="$(curl -sS --max-time 10 -X POST "$API/v1/aiservicedesk/user/data/apitokens" \
        -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
        --data '{"name":"dev-kit-admin","expiresAt":null}' 2>/dev/null)"
  PERM="$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("plainToken",""))' 2>/dev/null)"
  [ -n "$PERM" ] || { echo "Failed to mint API token. Server said: ${RESP:-<no response>}" >&2; exit 1; }
  setenv DUPLO_ADMIN_TOKEN "$PERM"; TOK="$PERM"
  echo "    stored DUPLO_ADMIN_TOKEN (never-expiring)."
else
  echo "==> Existing DUPLO_ADMIN_TOKEN is valid — keeping it."
fi

# ── extension-dev workspace (idempotent, never deleted) ──────────────────────────
WS="$(getenv EXTENSION_DEV_WORKSPACE_ID)"
ws_exists() { [ -n "$1" ] && curl -fsS -o /dev/null --max-time 6 "$API/v1/aiservicedesk/admin/data/workspaces/$1" -H "Authorization: Bearer $TOK" 2>/dev/null; }
if ! ws_exists "$WS"; then
  # find existing by name, else create
  WS="$(curl -fsS --max-time 8 "$API/v1/aiservicedesk/admin/data/workspaces" -H "Authorization: Bearer $TOK" 2>/dev/null \
      | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((w["id"] for w in (items or []) if w.get("name")=="extension-dev"), ""))' 2>/dev/null || true)"
  if [ -z "$WS" ]; then
    echo "==> Creating 'extension-dev' workspace…"
    # Everything after this needs the workspace, so a refused create (most often an expired license —
    # the studio answers 400 license_limit_exceeded) stops here with the server's reason, not a traceback.
    WS="$(studio_create_id "$API/v1/aiservicedesk/admin/data/workspaces" '{"name":"extension-dev"}')" \
      || { echo "Could not create the extension-dev workspace — fix the cause above and re-run ./run.sh." >&2; exit 1; }
  fi
  setenv EXTENSION_DEV_WORKSPACE_ID "$WS"
fi
echo "    extension-dev workspace: $WS"

# ── UI workspace access (idempotent) ─────────────────────────────────────────
# The UI's accessible-tenants list is permission-set based (no SuperUser bypass), so the admin user
# needs an explicit permission set granting the workspace + a group assigning them to it. Without this
# the login lands on /app/auth/no-tenant-access even though the admin token can hit the APIs.
data_exists() { [ -n "$1" ] && curl -fsS -o /dev/null --max-time 6 "$API/v1/aiservicedesk/admin/data/$2/$1" -H "Authorization: Bearer $TOK" 2>/dev/null; }
# Name uniqueness is enforced on create, so if the .env id is stale but the DB still holds the record
# (e.g. .env hand-edited without --wipe) look it up by name before creating — mirrors the workspace block.
data_id_by_name() { # collection name
  curl -fsS --max-time 8 "$API/v1/aiservicedesk/admin/data/$1" -H "Authorization: Bearer $TOK" 2>/dev/null \
    | N="$2" python3 -c 'import sys,json,os
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((x["id"] for x in (items or []) if x.get("name")==os.environ["N"]), ""))' 2>/dev/null || true
}
PS="$(getenv EXTENSION_DEV_PERMSET_ID)"
if ! data_exists "$PS" permissionset; then
  PS="$(data_id_by_name permissionset extension-dev-access)"
  if [ -z "$PS" ]; then
    echo "==> Creating 'extension-dev-access' permission set…"
    PS="$(studio_create_id "$API/v1/aiservicedesk/admin/data/permissionset" \
        "$(W="$WS" python3 -c 'import json,os;print(json.dumps({"name":"extension-dev-access","allowedWorkspaces":[{"workspaceId":os.environ["W"]}]}))')")" \
      || echo "    (permission set not created — UI access to the workspace must be granted by hand)" >&2
  fi
  [ -n "$PS" ] && setenv EXTENSION_DEV_PERMSET_ID "$PS"
fi
PSG="$(getenv EXTENSION_DEV_PERMSETGROUP_ID)"
if ! data_exists "$PSG" permissionsetgroup; then
  PSG="$(data_id_by_name permissionsetgroup extension-dev-group)"
  if [ -z "$PSG" ]; then
    echo "==> Assigning $EMAIL to the permission set…"
    PSG="$(studio_create_id "$API/v1/aiservicedesk/admin/data/permissionsetgroup" \
        "$(P="$PS" E="$EMAIL" python3 -c 'import json,os;print(json.dumps({"name":"extension-dev-group","permissionSets":[os.environ["P"]],"userStringHandle":[os.environ["E"]]}))')")" \
      || echo "    (permission set group not created — assign $EMAIL to the permission set by hand)" >&2
  fi
  [ -n "$PSG" ] && setenv EXTENSION_DEV_PERMSETGROUP_ID "$PSG"
fi
echo "    UI access granted to $EMAIL (permission set $PS) — re-login if the workspace isn't listed yet (the assignment is cached)."

# ── register + attach the agent to the extension-dev workspace (idempotent) ──────
# Provisioning tickets are assigned from the workspace's agent list, so the workspace needs an agent.
echo "==> Registering + attaching agent to extension-dev workspace…"
./scripts/register-agent.sh "$WS" || echo "    (agent registration failed — run ./scripts/register-agent.sh $WS manually)"

# ── starter devops skill + persona, attached to the workspace (idempotent) ───────
# A workspace with no persona gives the agent no role, so seed one worked example of the
# Skill → Persona → Workspace chain. Both are adopted by name on later runs, never rewritten, so
# whatever you edit in the UI survives. Non-fatal, like the agent/LLM/KB registrations around it.
PERSONA_LINE=""
echo "==> Registering + attaching 'devops' persona to extension-dev workspace…"
if ./scripts/register-persona.sh "$WS"; then
  PERSONA_LINE="
  Persona   devops (skill: devops) → attached — edit both under AI Admin → Skills / Personas"
else
  echo "    (persona registration failed — run ./scripts/register-persona.sh $WS manually)"
fi

# ── vendor the Terraform extension's source (idempotent, never fatal) ────────────
# Puts the real, shipping Terraform extension's SOURCE in extensions/terraform — no .git, no upstream,
# theirs to edit. Deliberately non-fatal: a private/unreachable source repo, or no network, must not
# stop the platform from coming up. The getting started walkthrough for it is coming soon.
TF_EXT_LINE=""
if [ -d extensions/terraform ]; then
  TF_EXT_LINE="
  Terraform extensions/terraform (source, already present — yours to edit)"
elif ./scripts/fetch-terraform-extension.sh; then
  TF_EXT_LINE="
  Terraform extensions/terraform (source vendored — build + load it with ./scripts/build-extension.sh)"
else
  echo "    (Terraform extension not vendored — re-run ./scripts/fetch-terraform-extension.sh when you can reach the repo)"
fi

# ── register the model the agent runs on as the System default (every provider) ───
# The studio registers no LLM model of its own, so without this the ticket LLM picker has nothing to
# offer whichever provider you picked. register-llm.sh reads CLAUDE_MODEL + CLAUDE_EXTRA_MODELS from .env
# — already set above to the right ids per provider (bare claude-* for direct Anthropic, us.anthropic.*
# for either Bedrock mode) — so the same call registers the correct variants, makes them the only System
# models, and CLAUDE_MODEL the default.
LLM_LINE=""
case "$MODEL" in
  anthropic)             LLM_DESC="direct Anthropic" ;;
  bedrock)               LLM_DESC="AWS Bedrock" ;;
  gateway)               LLM_DESC="LLM Gateway" ;;
  subscription)          LLM_DESC="Claude Code subscription" ;;
  bedrock-instance-role) LLM_DESC="AWS Bedrock via EC2 instance role" ;;
esac
echo "==> Registering $(getenv CLAUDE_MODEL) ($LLM_DESC) as the System default LLM…"
if LLM_PROVIDER_LABEL="$LLM_DESC" ./scripts/register-llm.sh; then
  LLM_LINE="
  LLM       System default → $(getenv CLAUDE_MODEL) ($LLM_DESC)"
  [ -z "$(getenv CLAUDE_EXTRA_MODELS)" ] || LLM_LINE="$LLM_LINE; also available: $(getenv CLAUDE_EXTRA_MODELS)"
else
  echo "    (LLM registration failed — run ./scripts/register-llm.sh manually)"
fi

# ── wire the local Qdrant into a usable Knowledge Base (idempotent) ───────────
# Non-fatal on purpose, like the agent and LLM registrations above: a Knowledge Base that failed to
# configure must never stop the platform coming up.
KB_LINE=""
echo "==> Configuring Qdrant knowledge base…"
KB_RC=0
./scripts/register-qdrant.sh "$WS" || KB_RC=$?
case "$KB_RC" in
  0) KB_LINE="
  KB        collection devkit-docs on local-qdrant (uploads need AWS Bedrock — see docs/configuration.md)" ;;
  # 3 = provider and scope created, collection skipped (no embedding model seeded yet). Not a failure,
  # but the collection does not exist, so the banner must not claim it.
  3) KB_LINE="
  KB        local-qdrant registered; collection skipped — re-run ./scripts/register-qdrant.sh" ;;
  *) echo "    (knowledge base setup failed — run ./scripts/register-qdrant.sh manually)" ;;
esac

PROVIDER_DESC="$MODEL"
[ "$MODEL" = bedrock-instance-role ] && PROVIDER_DESC="bedrock via EC2 instance role${AWS_ROLE:+ ($AWS_ROLE)} @ $(getenv AWS_REGION) — no keys in .env"
[ "$MODEL" = gateway ] && PROVIDER_DESC="LLM gateway @ $(getenv ANTHROPIC_BASE_URL)"
[ "$MODEL" = subscription ] && PROVIDER_DESC="Claude Code subscription (model $(getenv CLAUDE_MODEL)) — your own token, local dev only"

cat <<EOF

✔ Platform ready (provider: $PROVIDER_DESC)
  UI        http://localhost:$UI_PORT     (login: $EMAIL)
  API       $API
  Workspace extension-dev  ($WS)  ·  agent registered + attached
  Token     DUPLO_ADMIN_TOKEN set in .env (permanent)
  License   ${LICENSE_STATUS:-set in .env} (Licensing__Token)$PERSONA_LINE$LLM_LINE$KB_LINE$TF_EXT_LINE

Build & deploy your extension (scripts read the target from .env — no DUPLO_BASE= prefix needed):
  ./scripts/build-extension.sh  extensions/<name>               # your extensions live in extensions/<name>/
  ./scripts/deploy-extension.sh extensions/<name>/dist/extension.zip
  # or build every extension:    ./scripts/build-all.sh
  # or build a bundled sample:   ./scripts/build-extension.sh samples/helloworld
  # re-attach the agent to another workspace: ./scripts/register-agent.sh <workspace-id>
  # attach the devops persona elsewhere:       ./scripts/register-persona.sh <workspace-id>
EOF
