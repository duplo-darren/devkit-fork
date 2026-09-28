#!/usr/bin/env bash
# Detect whether this machine is an AWS EC2 instance whose *instance role* can invoke Bedrock.
#
# WHY: on an EC2 dev box the instance profile is usually already allowed to call Bedrock, so the
# dev kit needs no long-lived AWS keys at all — the agent container's credential chain falls through
# to IMDS. run.sh calls this to offer that as a provider option before asking for keys.
#
# Usage: ./scripts/detect-bedrock.sh [model-id] [region]
#   model-id  the Bedrock model/inference-profile actually invoked (default us.anthropic.claude-sonnet-5)
#   region    force a region instead of probing the instance region (then us-east-1, us-west-2)
#
# Prints eval-able KEY=VALUE lines on stdout, human-readable progress on stderr.
#   BEDROCK_AVAILABLE=0|1   BEDROCK_REASON=<why not>   BEDROCK_REGION=<region that worked>
#   AWS_INSTANCE_ID, AWS_ROLE, AWS_REGION_DETECTED, CONTAINER_IMDS=ok|blocked|unknown
# Exit 0 only when the instance role can invoke the model. No AWS CLI or boto3 required
# (stdlib SigV4) — the probe is a real Converse call with maxTokens=1, so it proves *invoke*
# permission rather than just the presence of a role.
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/_runtime.sh
. ./scripts/_runtime.sh          # → $RUNTIME (docker | podman)

MODEL_ID="${1:-us.anthropic.claude-sonnet-5}"
FORCE_REGION="${2:-}"

# The whole probe is python3; without it we can still answer the question ("no") in the documented
# format. Callers parse stdout, so exiting silently would leave them with nothing to report.
if ! command -v python3 >/dev/null 2>&1; then
  echo "BEDROCK_AVAILABLE=0"
  echo "BEDROCK_REASON=python3 not found on PATH (required for the probe)"
  exit 1
fi

OUT="$(MODEL_ID="$MODEL_ID" FORCE_REGION="$FORCE_REGION" python3 - <<'PY'
import datetime, hashlib, hmac, json, os, sys, urllib.error, urllib.request

MODEL = os.environ["MODEL_ID"]
FORCE = os.environ.get("FORCE_REGION", "")
IMDS = "http://169.254.169.254/latest"
emit = lambda k, v: print(f"{k}={v}")
# NOTE: this whole block is a quoted heredoc inside "$(...)", which bash 3.2 (stock macOS) mis-parses
# if it contains a single apostrophe — it swallows the rest of the file looking for a closing quote.
# So: no apostrophes below this line, in code OR comments. Hence this named constant for the empty
# string, used where an inline two-quote literal would otherwise appear.
EMPTY = ""


def imds(path, token=None, method="GET", ttl=None, timeout=1.5):
    """One IMDS call. Short timeout: off-EC2 this address blackholes rather than refusing."""
    req = urllib.request.Request(IMDS + path, method=method)
    if token:
        req.add_header("X-aws-ec2-metadata-token", token)
    if ttl:
        req.add_header("X-aws-ec2-metadata-token-ttl-seconds", str(ttl))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode()


def fail(reason):
    emit("BEDROCK_AVAILABLE", 0)
    emit("BEDROCK_REASON", reason)
    sys.exit(1)


# ── 1. IMDSv2 token — this is the "are we on EC2 at all" test ────────────────
try:
    token = imds("/api/token", method="PUT", ttl=900)
except Exception as e:
    fail(f"not an EC2 instance (IMDS unreachable: {type(e).__name__})")

# ── 2. instance facts (best-effort; only the role + region are load-bearing) ──
def soft(path):
    try:
        return imds(path, token).strip()
    except Exception:
        return ""

instance_id, detected_region = soft("/meta-data/instance-id"), soft("/meta-data/placement/region")
if instance_id:
    emit("AWS_INSTANCE_ID", instance_id)
if detected_region:
    emit("AWS_REGION_DETECTED", detected_region)

# ── 3. instance-role credentials ─────────────────────────────────────────────
role = soft("/meta-data/iam/security-credentials/").splitlines()
role = role[0].strip() if role else ""
if not role:
    fail("EC2 instance has no IAM instance profile attached")
emit("AWS_ROLE", role)
try:
    creds = json.loads(imds(f"/meta-data/iam/security-credentials/{role}", token, timeout=3))
    ak, sk, st = creds["AccessKeyId"], creds["SecretAccessKey"], creds.get("Token", "")
except Exception as e:
    fail(f"could not read credentials for role {role} ({type(e).__name__})")


# ── 4. SigV4-signed Converse — proves bedrock:InvokeModel on THIS model ───────
def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def converse(region):
    """Return None on success, else a short human-readable reason."""
    host = f"bedrock-runtime.{region}.amazonaws.com"
    path = f"/model/{urllib.request.quote(MODEL, safe=EMPTY)}/converse"
    body = json.dumps({
        "messages": [{"role": "user", "content": [{"text": "ping"}]}],
        "inferenceConfig": {"maxTokens": 1},
    }).encode()
    payload_hash = hashlib.sha256(body).hexdigest()
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")

    headers = {"host": host, "x-amz-content-sha256": payload_hash, "x-amz-date": amzdate}
    if st:
        headers["x-amz-security-token"] = st
    signed = ";".join(sorted(headers))
    # Canonical request: the headers block already ends in \n, which supplies the required blank
    # line before SignedHeaders — do not add another (a stray \n here is a silent 403).
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    canonical = (
        f"POST\n{path}\n\n{canonical_headers}\n{signed}\n{payload_hash}"
    )
    scope = f"{datestamp}/{region}/bedrock/aws4_request"
    to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amzdate, scope, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    k = sign(sign(sign(sign(("AWS4" + sk).encode(), datestamp), region), "bedrock"), "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()

    req = urllib.request.Request(f"https://{host}{path}", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization",
                   f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
                   f"SignedHeaders={signed}, Signature={sig}")
    for hk, hv in headers.items():
        if hk != "host":
            req.add_header(hk, hv)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
        return None
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode()).get("message", "")
        except Exception:
            msg = ""
        return f"HTTP {e.code}: {msg or e.reason}"
    except Exception as e:
        return f"{type(e).__name__}: {e}"


regions, seen = [], set()
for r in ([FORCE] if FORCE else [detected_region, "us-east-1", "us-west-2"]):
    if r and r not in seen:
        seen.add(r)
        regions.append(r)

reasons = []
for r in regions:
    print(f"    probing bedrock-runtime.{r} with {MODEL} …", file=sys.stderr)
    why = converse(r)
    if why is None:
        emit("BEDROCK_AVAILABLE", 1)
        emit("BEDROCK_REGION", r)
        emit("BEDROCK_MODEL", MODEL)
        sys.exit(0)
    reasons.append(f"{r}: {why}")
fail("; ".join(reasons))
PY
)"
RC=$?
printf '%s\n' "$OUT"

# ── 5. Can a *container* reach IMDS? ─────────────────────────────────────────
# The classic trap: IMDSv2 defaults to a PUT-response hop limit of 1, so the host works but
# anything behind the docker bridge (one extra hop) is silently cut off — the agent would then
# start and fail on every turn. busybox:1.36 is already part of the stack (init-perms).
#
# Report WHY we could not check separately from "checked, and it is blocked": only a real blocked
# result means the hop limit. Anything else is our own inability to run the test, and a caller that
# conflated the two would tell you to raise a hop limit that was never the problem.
#   ok | blocked | unknown:<reason>
# Only meaningful if the role itself checked out.
if [ "$RC" = 0 ]; then
  # Quietly: this probe is one line of a diagnostic report, and a runtime that cannot be resolved is
  # already reported as unknown:<reason> below rather than as a failure of the whole report.
  if ! runtime_resolve 2>/dev/null; then
    echo "CONTAINER_IMDS=unknown:no container runtime available"
  elif ! "$RUNTIME" info >/dev/null 2>&1; then
    echo "CONTAINER_IMDS=unknown:$RUNTIME not reachable"
  else
    # The probe runs BEFORE `$RUNTIME compose pull`, so on a fresh box this image is usually not local
    # yet. Pull it quietly rather than reporting a false "blocked".
    "$RUNTIME" image inspect busybox:1.36 >/dev/null 2>&1 || "$RUNTIME" pull -q busybox:1.36 >/dev/null 2>&1 || true
    if ! "$RUNTIME" image inspect busybox:1.36 >/dev/null 2>&1; then
      echo "CONTAINER_IMDS=unknown:could not obtain busybox:1.36 (registry unreachable?)"
    elif "$RUNTIME" run --rm busybox:1.36 sh -c \
        'wget -S -T 3 -O /dev/null http://169.254.169.254/latest/meta-data/ 2>&1 | grep -q "HTTP/"' \
        >/dev/null 2>&1; then
      echo "CONTAINER_IMDS=ok"
    else
      echo "CONTAINER_IMDS=blocked"
    fi
  fi
fi
exit $RC
