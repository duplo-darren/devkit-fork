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
# _RUNTIME_SUPPORTED without touching another line.
#
#   docker   the default, and what the kit was written against.
#   podman   daemonless; rootless by default. See the uid note on runtime_builder_ids below.
#   nerdctl  containerd's CLI.
#   finch    AWS's macOS/Windows wrapper around nerdctl in a VM.
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
_RUNTIME_SUPPORTED=(docker podman nerdctl finch)

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
