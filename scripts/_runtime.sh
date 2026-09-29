# shellcheck shell=bash
# Sourced FIRST by run.sh, stop.sh, logs.sh and scripts/* — resolves the container CLI once, so every
# call site reads `$RUNTIME run` / `$RUNTIME compose` instead of hard-coding `docker`.
#
# Why a variable rather than a `docker` shim on PATH: a shim is per-machine, invisible in the repo, and
# silently changes what every other tool on the box does too. RUNTIME is per-checkout, lives in .env
# next to every other knob (BUILDER_TAG, DUPLO_TARGET…), and is visible in the one place a reader of
# these scripts already looks.
#
# WHAT COUNTS AS A RUNTIME HERE
# Every value below is a *client CLI* that speaks Docker's command grammar — `run`, `pull`, `build`,
# `info`, `version`, `image inspect` — AND ships a `compose` subcommand, because this kit drives the
# whole stack through Compose. That is the entire contract; anything meeting it can be added to
# _RUNTIME_SUPPORTED — but check the dispatch split in scripts/_builder.sh first, because `compose run`
# is not usable on every CLI that meets the contract, and the fallback branch there assumes a
# finch-shaped CLI.
#
#   docker   the default, and what the kit was written against.
#   podman   daemonless; rootless by default. See the uid note on runtime_builder_ids below.
#
# finch is TEMPORARILY de-listed, pending validation — it is not auto-detected and RUNTIME=finch is
# rejected. This is a claim-reduction, not a removal: every finch code path is still here and still
# correct, including the compose-bypass dispatch in scripts/_builder.sh and its notes on the three
# ways finch's `compose` fails silently. Re-enable by putting `finch` back in the array below; nothing
# else needs touching. The reason for de-listing is the same one that removed nerdctl: the kit should
# not advertise a runtime nobody is currently exercising.
#
# nerdctl is deliberately NOT here, and is not coming back. finch is the supported way to drive
# containerd in this kit: it is nerdctl plus the VM and the defaults that make it work on macOS and
# Windows, which is where anyone here is running containerd in the first place. Bare nerdctl was listed
# once and never exercised, and it shares finch's compose limitations without finch's setup. A
# native-Linux containerd user can still pin RUNTIME to a CLI of their choice by adding it back here —
# see the note above about the builder's dispatch split.
#
# runc is deliberately NOT here, though it was asked for. It is a *low-level OCI runtime*: it executes
# an already-unpacked bundle (a rootfs plus config.json) given by path, and has no concept of an image,
# a registry, a network or a compose file — `runc run busybox:1.36` cannot work, because runc never
# resolves an image name. It is the layer the CLIs above call *underneath* (this machine's podman drives
# `crun`, runc's C rewrite, via `--runtime`). Choosing the low-level runtime is a different knob from
# choosing the client, so runtime_resolve rejects it with that explanation rather than emitting commands
# that would fail later with something unrecognisable.

# The order here is also the auto-detect precedence: docker first, so a machine that has always had
# Docker keeps behaving exactly as it did before this file existed.
#
# NOTE: precedence is by PRESENCE, not by liveness (see runtime_detect) — so an installed-but-stopped
# docker still wins over a running podman, and the build then fails rather than falling through. Pin
# RUNTIME in .env on a machine that has both. Installing Docker alongside an existing podman is the
# common way to land on the wrong one without noticing.
_RUNTIME_SUPPORTED=(docker podman)

# Self-contained .env read. _target.sh defines an identical `_envv`, but this file is sourced by run.sh
# and stop.sh too, which never source _target.sh — and it must work before either has run. Same
# DUPLO_ENV_FILE convention, same `|| true` so a missing key yields empty instead of tripping the
# callers' `set -euo pipefail`.
_RUNTIME_ENV_FILE="${DUPLO_ENV_FILE:-.env}"
_runtime_envv() { grep -E "^$1=" "$_RUNTIME_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Strip the three accidents a hand- or Windows-edited .env leaves behind. Same three cases, and the same
# reasoning, as builder_clean_value in _builder.sh — duplicated rather than shared because that file is
# sourced only by the two build scripts, and this one has to stand alone.
_runtime_clean() {
  local v="${1-}"
  v="${v//$'\r'/}"                                    # CRLF line endings
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; esac # "quoted"
  case "$v" in \'*\') v="${v#\'}"; v="${v%\'}" ;; esac # 'quoted'
  v="${v#"${v%%[![:space:]]*}"}"                      # leading whitespace
  v="${v%"${v##*[![:space:]]}"}"                      # trailing whitespace
  printf '%s' "$v"
}

# runtime_detect -> first supported CLI on PATH, or empty.
#
# Presence only — no daemon check. Whether the thing actually answers is a separate question with a
# separate message (run.sh's preflight, builder_probe_runtime), and conflating them here would make an
# unstarted Docker Desktop silently fall through to podman.
runtime_detect() {
  local r
  for r in "${_RUNTIME_SUPPORTED[@]}"; do
    command -v "$r" >/dev/null 2>&1 && { printf '%s' "$r"; return; }
  done
  printf ''
}

# runtime_requested -> the explicitly requested runtime (environment, else .env), or empty when the
# choice is being left to auto-detection.
#
# The distinction matters to the build path: "you asked for X and X is unusable" is a hard error,
# because silently building with something else is not what was asked for — whereas "nothing found"
# can legitimately fall back to a native toolchain build.
runtime_requested() { _runtime_clean "${RUNTIME:-$(_runtime_envv RUNTIME)}"; }

# runtime_resolve -> sets and exports RUNTIME; returns 1 with a message on stderr if it cannot.
#
# Precedence: environment → .env → auto-detect. Exported because the build path hands the choice down
# to a nested `$RUNTIME compose run` invocation of these same scripts, and an unexported RUNTIME there
# would silently re-detect and could pick a different CLI than the one the caller asked for.
#
# Idempotent: sourcing this file twice (build-extension.sh sources _builder.sh, which sources this) must
# not re-run detection or re-print anything.
runtime_resolve() {
  [ -n "${_RUNTIME_RESOLVED:-}" ] && return 0

  local want; want="$(_runtime_clean "${RUNTIME:-$(_runtime_envv RUNTIME)}")"

  if [ -z "$want" ]; then
    want="$(runtime_detect)"
    if [ -z "$want" ]; then
      echo "ERROR: no container runtime found on PATH." >&2
      echo "       This kit needs one of: ${_RUNTIME_SUPPORTED[*]} — each with a 'compose' subcommand." >&2
      echo "       Install one, or set RUNTIME=<cli> in .env if yours is under a different name." >&2
      return 1
    fi
  fi

  # runc and its drop-in siblings get their own message: "unsupported runtime: runc" would read as an
  # oversight, and the person would reasonably try to fix it by installing runc — which is very likely
  # already installed, and still will not work.
  case "$want" in
    runc|crun|youki|gvisor|runsc|kata-runtime)
      echo "ERROR: '$want' is a low-level OCI runtime, not a container CLI, so it cannot drive this kit." >&2
      echo "       It runs an unpacked bundle handed to it by path — it has no images, registries," >&2
      echo "       networks or compose, so there is no '$want run <image>' or '$want compose up'." >&2
      echo "       It is what the CLI below uses underneath; to select it, tell that CLI:" >&2
      echo "         RUNTIME=podman  and  podman --runtime $want …   (or docker's default-runtime)" >&2
      echo "       Set RUNTIME to one of: ${_RUNTIME_SUPPORTED[*]}" >&2
      return 1 ;;
  esac

  local r ok=0
  for r in "${_RUNTIME_SUPPORTED[@]}"; do [ "$want" = "$r" ] && { ok=1; break; }; done
  if [ "$ok" != 1 ]; then
    echo "ERROR: RUNTIME='$want' is not a supported container CLI." >&2
    echo "       Supported: ${_RUNTIME_SUPPORTED[*]}" >&2
    echo "       (A runtime qualifies if it speaks Docker's CLI grammar and has a 'compose' subcommand.)" >&2
    return 1
  fi

  if ! command -v "$want" >/dev/null 2>&1; then
    echo "ERROR: RUNTIME='$want' was requested but '$want' is not on PATH." >&2
    return 1
  fi

  RUNTIME="$want"; export RUNTIME
  _RUNTIME_RESOLVED=1

  # podman routes `podman compose` to an external provider (podman-compose or docker-compose) and prints
  # a four-line banner about having done so, to stderr, on EVERY call. This kit makes many compose calls
  # per run, and the banner is noise the user cannot act on. Only set the opt-out when it is unset, so
  # anyone who genuinely wants the banner can keep it.
  [ "$RUNTIME" = podman ] && : "${PODMAN_COMPOSE_WARNING_LOGS:=false}" && export PODMAN_COMPOSE_WARNING_LOGS

  return 0
}

# runtime_is_rootless_podman -> 1 or 0.
#
# Only podman can answer yes: docker's rootless mode still presents a daemon that owns the uid mapping,
# so the ownership problem below does not arise there. Cached because runtime_builder_ids is called on
# the hot path of every build and this shells out.
runtime_is_rootless_podman() {
  if [ -z "${_RUNTIME_ROOTLESS:-}" ]; then
    if [ "${RUNTIME:-docker}" = podman ] \
       && [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ]; then
      _RUNTIME_ROOTLESS=1
    else
      _RUNTIME_ROOTLESS=0
    fi
  fi
  printf '%s' "$_RUNTIME_ROOTLESS"
}

# runtime_builder_ids -> the "<uid> <gid>" pair to run the builder container as, so that the bundle it
# writes into the bind-mounted checkout ends up owned by the person who started the build.
#
# THE ANSWER IS NOT `id -u` EVERYWHERE, and this is the one place the runtimes genuinely diverge.
#
# Docker: the daemon runs as real root, so container uid N writes files owned by host uid N. Passing
# `id -u` is both correct and necessary — without it the bundle comes out root-owned.
#
# Rootless podman: the container is inside a user namespace where the host user is already mapped to
# uid 0, and the subuid range (/etc/subuid, typically 100000+) supplies every other id. So:
#   - container uid 0     -> host uid 1000   (the caller — what we want)
#   - container uid 1000  -> host uid 101000 (a subuid the caller cannot even write as)
# Passing `id -u` there is actively harmful: measured on podman 5.7, the build cannot create files in
# the mounted checkout at all, and anything it does create is owned by an id the caller cannot chown or
# delete without `podman unshare`. Asking for uid 0 is what yields caller-owned output.
#
# The alternative — `--userns=keep-id` with the real uid — needs a flag that has no Compose equivalent
# here, whereas this needs no change to docker-compose.yml at all.
runtime_builder_ids() {
  if [ "$(runtime_is_rootless_podman)" = 1 ]; then
    printf '0 0'
  else
    printf '%s %s' "$(id -u)" "$(id -g)"
  fi
}

# runtime_compose_project -> the compose project name these scripts' containers are labelled with.
#
# Compose's own default rule: the base directory name, lowercased, with everything outside [a-z0-9_-]
# dropped. COMPOSE_PROJECT_NAME overrides it, for both implementations.
runtime_compose_project() {
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then printf '%s' "$COMPOSE_PROJECT_NAME"; return; fi
  basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

# runtime_compose_running_services -> this project's RUNNING compose services, one name per line.
#
# Empty output means "none running". A NON-ZERO RETURN means the question could not be answered at all,
# which callers must not conflate with "none" — see builder_studio_state, whose three-way answer exists
# for exactly this reason.
#
# Two implementations, because `compose ps` is where the CLIs diverge most. docker compose takes
# `--status running --services`; podman-compose 1.5 supports neither (its entire `ps` grammar is `-q`
# and `--format`) and exits 2 with a usage dump. Left as one call, that silently made switch-llm.sh
# conclude the agent was never running and skip the recreate — a wrong answer, not a visible failure.
#
# The fallback asks the RUNTIME rather than the compose wrapper: both implementations stamp the same
# com.docker.compose.{project,service} labels on every container they create (verified against
# podman-compose 1.5), and `ps --filter label=` with `{{.Label "…"}}` behaves identically in both CLIs.
# Trying the native form first means docker's behaviour is unchanged, down to the exit status.
runtime_compose_running_services() {
  local out
  if out="$("${RUNTIME:?}" compose ps --status running --services 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  "$RUNTIME" ps --filter "label=com.docker.compose.project=$(runtime_compose_project)" \
                --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null
}

# runtime_label -> a human name for messages, e.g. "podman (rootless)". Purely cosmetic: a message that
# says "Docker" on a podman box sends people to debug the wrong thing.
runtime_label() {
  if [ "$(runtime_is_rootless_podman)" = 1 ]; then printf 'podman (rootless)'
  else printf '%s' "${RUNTIME:-docker}"; fi
}

# ── podman machine sizing ─────────────────────────────────────────────────────
# On macOS and Windows podman runs containers inside a VM whose memory is fixed at machine-create time
# and is NOT elastic the way Docker Desktop's is. That one ceiling is shared by the whole stack (six
# containers) AND by every extension build — and the Angular Native-Federation build is the hungriest
# thing the kit runs: esbuild bundling the federation artifacts is what hits the wall first.
#
# It fails badly enough to be worth pre-empting. The OOM kill surfaces as a bare `Killed`, then ~100
# lines of Go "fatal error: all goroutines are asleep - deadlock!" out of esbuild, and finally
# `exit status 137` — which is the only part that means "out of memory", and it is the last line anyone
# reads. Spending a few milliseconds here to say it in one sentence is a good trade.
#
# The floor is a JUDGEMENT CALL, not a measurement. The two known data points are: a 2 GiB machine with
# the stack up reliably OOMs the frontend build, and 8 GiB completes it comfortably. Nothing between was
# measured. 6 GiB is set as the hard floor (~4 GiB left for a build once the stack is running) and 8 GiB
# is what the message recommends. Both are overridable in .env for anyone whose workload disagrees.
_RUNTIME_MIN_MEMORY_MIB=6144
_RUNTIME_MIN_CPUS=4

# runtime_machine_check -> 0 when there is nothing to complain about, 1 when the VM is too small to
# build in. Undersized memory is the failure; CPU count only earns a warning, since a slow build still
# produces a bundle.
#
# Scoped to podman deliberately. Docker's VM is managed by Docker Desktop, whose memory is a GUI setting
# this script cannot read. A podman on native Linux has no
# machine at all (`machine list` yields []) and returns 0 — there is no VM to size.
#
# Reads the CONFIGURED size via `machine list`, not the live one via `podman info`: machine list answers
# for a STOPPED machine too (so the check still fires on the very run that would start it), and the
# configured number is the one `podman machine set` changes.
#
# python3, not jq: run.sh hard-requires python3 and never requires jq, and this file is sourced by
# run.sh, stop.sh and logs.sh. Any failure to read or parse returns 0 — this check exists to give a
# better message than exit 137, never to become a new way for the kit to refuse to start.
runtime_machine_check() {
  [ "${RUNTIME:-}" = podman ] || return 0
  command -v podman >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local min_mem min_cpus raw parsed name mib cpus running
  min_mem="$(_runtime_clean "$(_runtime_envv PODMAN_MIN_MEMORY_MIB)")"
  min_cpus="$(_runtime_clean "$(_runtime_envv PODMAN_MIN_CPUS)")"
  # Fall back to the built-in floor on anything that isn't a plain positive integer, rather than letting
  # a typo'd .env value silently disable the check (empty compares as smaller than everything).
  case "$min_mem"  in ''|*[!0-9]*) min_mem=$_RUNTIME_MIN_MEMORY_MIB ;; esac
  case "$min_cpus" in ''|*[!0-9]*) min_cpus=$_RUNTIME_MIN_CPUS ;; esac

  raw="$(podman machine list --format json 2>/dev/null)" || return 0
  [ -n "$raw" ] || return 0

  parsed="$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    ms = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(ms, list) or not ms:
    sys.exit(0)

# The machine this run will actually talk to: the running one, else the default, else whatever is first.
m = next((x for x in ms if x.get("Running")), None) \
    or next((x for x in ms if x.get("Default")), None) \
    or ms[0]

try:
    mem = int(str(m.get("Memory", "0")).strip() or 0)
except ValueError:
    sys.exit(0)
if mem <= 0:
    sys.exit(0)
# Current podman reports Memory as a byte count rendered as a STRING; some older builds reported MiB.
# A value below 1 MiB can only be the latter, so treat it as already-MiB rather than rounding to zero.
mib = mem // (1024 * 1024) if mem >= (1 << 20) else mem

try:
    cpus = int(m.get("CPUs") or 0)
except (TypeError, ValueError):
    cpus = 0

print("%s\t%d\t%d\t%d" % (m.get("Name", "podman-machine-default"), mib, cpus,
                          1 if m.get("Running") else 0))
' 2>/dev/null)" || return 0
  [ -n "$parsed" ] || return 0

  IFS=$'\t' read -r name mib cpus running <<EOF
$parsed
EOF
  [ -n "$mib" ] || return 0

  if [ "$cpus" -gt 0 ] && [ "$cpus" -lt "$min_cpus" ]; then
    echo "Note: podman machine '$name' has $cpus CPU(s); $min_cpus+ makes builds noticeably faster." >&2
  fi

  [ "$mib" -lt "$min_mem" ] || return 0

  # What to actually suggest. 8 GiB is the comfortable figure, but a raised PODMAN_MIN_MEMORY_MIB must
  # win — otherwise the message demands 16 GiB and then hands over a command that sets 8.
  local rec_mem=8192
  [ "$min_mem" -gt "$rec_mem" ] && rec_mem="$min_mem"

  # `podman machine set` writes every flag it is given, so the suggested --cpus must never be LOWER than
  # what the machine already has: a 6-CPU machine that is merely short on memory would otherwise be told
  # to downgrade itself to the 4-CPU floor. Unknown CPU count (0) falls back to the floor.
  local rec_cpus="$min_cpus"
  [ "$cpus" -gt "$rec_cpus" ] && rec_cpus="$cpus"

  # The stop/set/start dance is spelled out because `podman machine set --memory` refuses to run against
  # a started machine, and because stopping it takes the whole stack down with it — someone mid-session
  # deserves to know that before they paste the command, not after.
  cat >&2 <<MSG
The podman machine is too small to build in.

  machine:   $name ($([ "$running" = 1 ] && echo running || echo stopped))
  memory:    $((mib / 1024)) GiB ($mib MiB)
  required:  $((min_mem / 1024)) GiB ($min_mem MiB) minimum, $((rec_mem / 1024)) GiB recommended

That ceiling is shared by this stack's six containers and by every extension build. The Angular
frontend build is what runs out first, and when it does the only clue is 'exit status 137' at the
end of a Go stack trace — so this stops here instead.

Resize it (this STOPS the machine, taking any running containers with it, then brings it back):

    podman machine stop
    podman machine set --memory $rec_mem --cpus $rec_cpus
    podman machine start
    ./run.sh

Then re-run this script. If you are certain a smaller machine is right for your workload, set
PODMAN_MIN_MEMORY_MIB in .env to lower the floor.
MSG
  return 1
}

# Normalised host CPU architecture: amd64 | arm64 | whatever uname said. Its own function so the rosetta
# preflight's policy can be exercised from a test on any host.
_runtime_host_arch() {
  local m; m="$(uname -m 2>/dev/null)"
  case "$m" in
    x86_64|amd64)  printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *)             printf '%s' "$m" ;;
  esac
}

# runtime_rosetta_active -> 0 Rosetta is live in the podman machine, 1 definitively not, 2 could not tell.
#
# The binfmt handler list is the ONLY honest source. `podman machine inspect` reports the flag the VM was
# last STARTED with, which goes stale the moment containers.conf changes; the handler either exists in the
# running kernel or it does not. The cost is that a stopped or unreachable machine cannot be judged at all
# — hence 2, which the caller treats as "say nothing".
runtime_rosetta_active() {
  command -v podman >/dev/null 2>&1 || return 2
  local handlers
  handlers="$(podman machine ssh 'ls /proc/sys/fs/binfmt_misc/' 2>/dev/null)" || return 2
  [ -n "$handlers" ] || return 2
  printf '%s\n' "$handlers" | grep -qx 'rosetta' && return 0
  return 1
}

# _runtime_machine_vmtype -> the VMType of the machine this run would talk to, or empty.
#
# The impure half of the provider question, split out for the same reason as runtime_rosetta_active: it
# needs podman and a machine, and the policy that consumes it must be testable without either. Same
# machine-selection rule as runtime_machine_check (running, else default, else first) so both checks
# always talk about the same VM. Anything unreadable is empty, never a guess.
_runtime_machine_vmtype() {
  command -v podman  >/dev/null 2>&1 || { printf ''; return; }
  command -v python3 >/dev/null 2>&1 || { printf ''; return; }
  podman machine list --format json 2>/dev/null | python3 -c '
import json, sys
try:
    ms = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(ms, list) or not ms:
    sys.exit(0)
m = next((x for x in ms if x.get("Running")), None) \
    or next((x for x in ms if x.get("Default")), None) \
    or ms[0]
sys.stdout.write(str(m.get("VMType") or ""))
' 2>/dev/null || printf ''
}

# _runtime_machine_conf_provider -> the [machine] provider in containers.conf, or empty.
_runtime_machine_conf_provider() {
  local f="${CONTAINERS_CONF:-$HOME/.config/containers/containers.conf}"
  [ -f "$f" ] || { printf ''; return; }
  # Same [machine]-table scan as _runtime_rosetta_conf_state: header to the next [section] or EOF.
  local block
  block="$(awk '/^[[:space:]]*\[machine\][[:space:]]*$/{f=1;next} /^[[:space:]]*\[/{f=0} f' "$f" 2>/dev/null)"
  [ -n "$block" ] || { printf ''; return; }
  # _runtime_clean strips quotes BEFORE trimming whitespace, so ` "applehv"` (the leading space `cut`
  # leaves behind) would keep its quotes. Trim the left side first and the quote is what it sees.
  local v
  v="$(printf '%s' "$block" | grep -E '^[[:space:]]*provider[[:space:]]*=' | tail -1 | cut -d= -f2-)"
  v="${v#"${v%%[![:space:]]*}"}"
  _runtime_clean "$v"
}

# _runtime_machine_provider -> applehv | libkrun | <whatever else> | empty
#
# Which machine provider is in effect, resolved the way podman resolves it: the environment override
# first, then containers.conf, then — for a machine that already exists — what it was actually created
# as. The last one matters because the provider is fixed at `podman machine init`: editing the config
# afterwards changes what the NEXT machine would be, not this one, so the config alone would cheerfully
# report applehv for a libkrun VM that is running right now.
#
# This exists because Rosetta is an applehv feature. Upstream's LibKrunStubber.GetRosetta returns false
# unconditionally, so `rosetta = true` under libkrun is read, discarded, and leaves no trace anywhere
# except the missing binfmt handler — which is exactly the symptom runtime_rosetta_check already sees
# and, until now, mis-diagnosed as "you forgot to restart the machine".
_runtime_machine_provider() {
  local p
  # An existing machine answers first, and outranks both config sources: `podman machine init
  # --provider applehv` does NOT write containers.conf, so the two disagree the moment anyone passes
  # that flag — and it is the running VM, not the file, that this run will talk to. Reading the file
  # first would blame libkrun for a healthy applehv machine and advise destroying it, which is the
  # same class of wrong answer this function exists to stop.
  p="$(_runtime_machine_vmtype)"
  # No machine yet: both remaining sources describe what the NEXT one would be, in podman's own order.
  [ -n "$p" ] || p="$(_runtime_clean "${CONTAINERS_MACHINE_PROVIDER:-}")"
  [ -n "$p" ] || p="$(_runtime_machine_conf_provider)"
  printf '%s' "$p"
}

# _runtime_rosetta_conf_state -> absent | no-machine | no-key | disabled | enabled
#
# What containers.conf currently says about Rosetta, so the remediation can be specific. It has to be,
# because the obvious advice is actively harmful: appending a second `[machine]` table to a file that
# already has one is a TOML duplicate-key error, and podman then refuses to do ANYTHING —
#
#   Failed to obtain podman configuration: parsing containers.conf: toml: line 11:
#   Key 'machine' has already been defined.
#
# — which is a worse place to be than the missing Rosetta we were trying to fix. The `enabled` state
# matters just as much: config that is already right means the machine simply has not been restarted
# since, and telling someone to re-add a key they already have sends them looking in the wrong place.
#
# CONTAINERS_CONF is podman's own override for this path, so honouring it keeps us reading the same
# file podman will, and lets the tests point at a fixture.
_runtime_rosetta_conf_state() {
  local f="${CONTAINERS_CONF:-$HOME/.config/containers/containers.conf}"
  [ -f "$f" ] || { printf 'absent'; return; }
  # The [machine] table runs from its header to the next [section] header or EOF.
  local block
  block="$(awk '/^[[:space:]]*\[machine\][[:space:]]*$/{f=1;next} /^[[:space:]]*\[/{f=0} f' "$f" 2>/dev/null)"
  [ -n "$block" ] || { grep -qE '^[[:space:]]*\[machine\][[:space:]]*$' "$f" 2>/dev/null \
      && { printf 'no-key'; return; }; printf 'no-machine'; return; }
  case "$(printf '%s' "$block" | grep -E '^[[:space:]]*rosetta[[:space:]]*=' | tail -1)" in
    *true*)  printf 'enabled' ;;
    *false*) printf 'disabled' ;;
    *)       printf 'no-key' ;;
  esac
}

# runtime_rosetta_check -> 0 when there is nothing to complain about, 1 when an amd64 studio image is
# about to be handed to QEMU on an Apple Silicon host.
#
# Why this is a hard failure and not a note: QEMU user-mode cannot run the studio's .NET runtime. It
# aborts inside MapControllers() with SIGABRT, the container stays "Up" because the crash does not take
# PID 1 down promptly, /healthz never answers, and run.sh then spends 4.5 minutes on a dot loop before
# failing with "Login failed" — a message about credentials, for a problem that has nothing to do with
# them. Every layer of that is silent or misleading, so it is caught here instead.
#
# Scoped tightly, because Rosetta is only ever relevant to one combination:
#   - docker is not checked: Docker Desktop provides Rosetta itself, with nothing to configure.
#   - a non-amd64 studio platform needs no translation at all.
#   - a non-arm64 host needs no translation to run amd64.
# Anything it cannot determine returns 0. Like runtime_machine_check, this exists to replace a baffling
# failure with a clear one, never to become a new way for the kit to refuse to start.
runtime_rosetta_check() {
  [ "${RUNTIME:-}" = podman ] || return 0

  local plat host rc
  # Same precedence as runtime_requested: environment wins over .env. The fallback matches the compose
  # default (`platform: ${STUDIO_PLATFORM:-linux/amd64}`), so an unset value is amd64 here too.
  plat="$(_runtime_clean "${STUDIO_PLATFORM:-$(_runtime_envv STUDIO_PLATFORM)}")"
  [ -n "$plat" ] || plat=linux/amd64
  case "$plat" in *amd64*|*x86_64*) ;; *) return 0 ;; esac

  host="$(_runtime_host_arch)"
  [ "$host" = arm64 ] || return 0

  runtime_rosetta_active; rc=$?
  [ "$rc" = 1 ] || return 0

  # The remediation depends on what containers.conf already says. This is not polish: telling someone to
  # append `[machine]` to a file that already has that table produces a TOML duplicate-key error, and
  # podman then refuses to run at all ("Key 'machine' has already been defined") — strictly worse than
  # the missing Rosetta. And when the key is already correct, the file is not the problem: the machine
  # simply has not been restarted since it was set.
  local conf_path conf_dir fix provider after
  conf_path="${CONTAINERS_CONF:-$HOME/.config/containers/containers.conf}"
  conf_dir="$(dirname "$conf_path")"
  provider="$(_runtime_machine_provider)"

  # The provider outranks every conf state, because under anything but applehv the rosetta key is read
  # and thrown away: "your config is already correct, just restart" is then advice that cannot ever come
  # true, and the person dutifully recreates the machine again and again with the same result.
  if [ -n "$provider" ] && [ "$provider" != applehv ]; then
    fix="The machine provider is '$provider', and Rosetta is an applehv feature. podman's $provider
backend reports Rosetta as unavailable whatever containers.conf says, so a 'rosetta = true'
there is read and discarded — which is why this looks like a config that ought to work.

Set BOTH keys under the SINGLE existing [machine] section of
$conf_path
— never add a second [machine] header, TOML rejects a duplicate table and podman then
refuses to run at all:

    [machine]
    provider = \"applehv\"
    rosetta  = true"
    after="Then recreate the machine. The PROVIDER, unlike the rosetta key, is written at
'podman machine init' and never revisited, so it cannot be changed in place.
Recreating DESTROYS that VM's images and volumes:

    podman machine stop
    podman machine rm -f
    podman machine init --provider applehv --cpus 4 -m 8192 --disk-size 100
    podman machine start
    ./run.sh"
  else
  case "$(_runtime_rosetta_conf_state)" in
    absent)
      fix="No $conf_path yet — create it:

    mkdir -p $conf_dir
    printf '[machine]\\nrosetta = true\\n' > $conf_path" ;;
    no-machine)
      fix="$conf_path exists but has no [machine] section. Open it and ADD this section
(do not append a second one elsewhere in the file):

    [machine]
    rosetta = true" ;;
    no-key)
      fix="$conf_path already has a [machine] section. Add this line UNDER that existing
section — do not add a second [machine] header, TOML rejects a duplicate table and podman
then refuses to start at all:

    rosetta = true" ;;
    disabled)
      fix="$conf_path sets 'rosetta = false' under [machine]. Change that one value to:

    rosetta = true" ;;
    enabled)
      fix="$conf_path ALREADY sets 'rosetta = true' — the file is correct and needs no edit.
The key is read at every machine start, so the machine simply has not been restarted since." ;;
  esac
  after="Then restart the machine — it does NOT need to be recreated, and nothing is lost. applehv
re-reads the rosetta key from containers.conf on every start and syncs it into the machine:

    podman machine stop
    podman machine start
    ./run.sh"
  fi

  cat >&2 <<MSG
The podman machine has no Rosetta, and the studio image is amd64.

  host:      arm64 (Apple Silicon)
  platform:  $plat  (STUDIO_PLATFORM)
  provider:  ${provider:-unknown}$([ -n "$provider" ] && [ "$provider" != applehv ] && printf '%s' "  — no Rosetta support; applehv is the one that has it")
  emulator:  QEMU — no 'rosetta' handler in the machine's binfmt_misc

amd64 binaries will run under QEMU user-mode emulation, which cannot run the studio's .NET runtime:
it aborts during startup, the container still reports "Up", and the wait for /healthz below would
spin for about 4.5 minutes before failing with a misleading "Login failed" — so this stops here.

$fix

$after

Confirm it took:

    podman machine ssh 'ls /proc/sys/fs/binfmt_misc/'     # want 'rosetta', not 'qemu-x86_64'
    podman machine inspect --format '{{.Rosetta}}'        # want true

Alternatively, avoid emulation: if your studio tag publishes an arm64 variant, set
STUDIO_PLATFORM=linux/arm64 in .env. Docker Desktop is another way out — it ships Rosetta itself.
MSG
  return 1
}
