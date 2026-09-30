# shellcheck shell=bash
# Sourced by scripts/build-extension.sh and scripts/build-all.sh — decides whether a build runs on the
# caller's machine or inside the builder container, and launches the container when it should.
#
# Why a container at all: the dev-kit's runtime is entirely containerized, but the build was not — it
# hard-required `jq dotnet npm zip curl unzip` on the developer's laptop (and `jq` isn't shipped by
# macOS, so it was an undeclared prerequisite that failed at line 15). A compose-capable container CLI
# is now the only prerequisite.
#
# Every container command here goes through $RUNTIME (see scripts/_runtime.sh, sourced below) rather
# than a literal `docker`, so the same build works under docker or podman.
#
# REQUIRES scripts/_target.sh, sourced FIRST: this file uses its `_envv` (to read .env for BUILDER_IMAGE /
# BUILDER_PULL / BUILDER_TAG / STUDIO_PORT) and its `_TARGET`. Both current callers do source it first;
# that is a requirement of sourcing this file, not an accident of their layout.

# BASH_SOURCE, not $0: $0 is whichever script sourced this one, and build-extension.sh may be invoked
# from any cwd. _runtime.sh is idempotent, so sourcing it here as well as in run.sh costs nothing.
# shellcheck source=scripts/_runtime.sh
. "${BASH_SOURCE[0]%/*}/_runtime.sh"

# builder_truthy <value> -> echoes 1 or 0; returns 1 (no output) if <value> isn't a boolean at all.
#
# Accepts the spellings a human actually types into an env var, case-insensitively, because
# DUPLO_BUILD_NATIVE is documented as a boolean and `DUPLO_BUILD_NATIVE=true` silently getting a
# *container* build would defeat the whole point of an escape hatch. Unset/empty is false — that's the
# normal "env var not set" case, not an error. Anything else is genuine garbage and is rejected rather
# than coerced, so a typo (or a probe in Task 3 that starts echoing something unexpected) fails loudly.
builder_truthy() {
  case "$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)      echo 1 ;;
    0|false|no|off|'')  echo 0 ;;
    *)                  return 1 ;;
  esac
}

# builder_mode <force_native> <in_container> <have_toolchain> <have_runtime> -> native|container|error:<why>
#
# Kept as a pure function of four booleans (no `command -v`, no filesystem probes) so the whole
# decision matrix can be exercised without a container runtime, a platform, or a toolchain.
builder_mode() {
  # Normalize every argument up front, before any branch is taken, so a bad value can't be silently
  # read as false by whichever comparison happens to see it first. Separate declaration from assignment:
  # `local x=$(cmd)` masks the command's exit status behind `local`'s own, so the || would never fire.
  local force_native in_container have_toolchain have_runtime
  force_native=$(builder_truthy "${1-}")   || { echo error:badarg; return; }
  in_container=$(builder_truthy "${2-}")   || { echo error:badarg; return; }
  have_toolchain=$(builder_truthy "${3-}") || { echo error:badarg; return; }
  have_runtime=$(builder_truthy "${4-}")   || { echo error:badarg; return; }

  # The explicit escape hatch outranks everything: --native / DUPLO_BUILD_NATIVE=1 means the caller
  # has their own toolchain and wants it used, so don't second-guess them.
  [ "$force_native" = 1 ] && { echo native; return; }

  # Already inside a container. Nesting is not an option — the agent container has a container CLI but
  # no socket to talk to, so builder_probe_runtime's reachability check fails — and it isn't needed either,
  # because the agent image ships the whole toolchain. This is the branch the agent's build takes. It is
  # also the branch the re-launched build takes inside the builder image, which stops the wrapper recursing.
  if [ "$in_container" = 1 ]; then
    [ "$have_toolchain" = 1 ] && { echo native; return; }
    echo error:toolchain; return
  fi

  # A host with a working runtime: containerize, even if a local toolchain exists, so that laptop, CI
  # and agent builds all use one pinned toolchain. `--native` is there for anyone who wants their own.
  [ "$have_runtime" = 1 ] && { echo container; return; }

  # No runtime. A complete local toolchain still works, so degrade gracefully rather than fail (this
  # keeps a runtime-less CI runner building).
  [ "$have_toolchain" = 1 ] && { echo native; return; }
  echo error:runtime
}

# The tools build-extension.sh has always required. One list, used both to decide (builder_probe_toolchain)
# and to report (builder_missing_tools), so the error message can never name a different set than the check.
_BUILDER_TOOLS=(jq dotnet npm zip curl unzip)

# --- Probes: the impure half. Each answers one of builder_mode's four booleans. -------------------

# Files that exist only inside a container. A list rather than an inline chain so the set is data (like
# _BUILDER_TOOLS above) and the probe's positive branch is testable on a machine that is not a container.
#   /.dockerenv        — written by Docker into every container it creates.
#   /run/.containerenv — podman's equivalent. Podman does NOT write /.dockerenv, so without this entry
#                        the probe answers 0 inside podman, which is the dangerous direction: the wrapper
#                        would then try to nest a build in a container that has no Docker socket.
_BUILDER_CONTAINER_MARKERS=(/.dockerenv /run/.containerenv)

builder_probe_in_container() {
  local m
  for m in "${_BUILDER_CONTAINER_MARKERS[@]}"; do
    [ -f "$m" ] && { echo 1; return; }
  done
  # Pre-cgroup-v2 fallback, and only that. Under cgroup v2 (Debian 11+, Ubuntu 21.10+, Fedora 31+ — i.e.
  # most current Linux) /proc/1/cgroup reads "0::/" inside a container as well as outside, so this pattern
  # matches nothing and carries no weight there; it still fires on older hosts, which is why it stays.
  grep -qaE '(docker|containerd|podman|kubepods)' /proc/1/cgroup 2>/dev/null && echo 1 || echo 0
}

builder_probe_toolchain() {
  local t
  for t in "${_BUILDER_TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 || { echo 0; return; }
  done
  echo 1
}

builder_probe_runtime() {
  # The CLI existing is not enough — the agent image HAS a client binary and nothing to talk to, so
  # `command -v` alone would answer 1 there and send the build looking for a socket that isn't mounted.
  # Only a runtime that actually answers counts.
  #
  # `version --format` rather than `info`: rendering any part of the SERVER block requires contacting
  # the server, so it proves exactly as much, and it is ~25x cheaper (measured 0.042s vs 1.074s).
  # builder_dispatch evaluates all four probes as *arguments* to builder_mode, so bash runs this one
  # even when --native has already decided the answer — and build-all.sh --native pays it once per
  # extension. Podman is daemonless, but it implements the same query (reporting its own version as
  # the server), so one probe covers every supported runtime.
  #
  # `{{json .Server}}` and NOT `{{.Server.Version}}`: the server struct is not the same shape across
  # the supported CLIs. docker and podman put a version string at .Server.Version; finch (nerdctl
  # underneath) does not have that field at all — its server block nests the component versions
  # instead, so the narrower template dies in the template engine rather than on the wire:
  #
  #   finch version --format '{{.Server.Version}}'
  #     fatal: template: version:1:9: executing "version" at <.Server.Version>:
  #            can't evaluate field Version in type main.NerdctlServerOutput
  #
  # That is indistinguishable from an unreachable runtime here, so a perfectly healthy finch was
  # reported as "no container runtime is available" and the build refused to run. Asking for the whole
  # object renders on all four and still fails when nothing answers — a stopped podman machine exits
  # 125 (printing `null`) and a stopped Docker Desktop errors the same way, so the probe stays honest.
  [ -n "${RUNTIME:-}" ] || { echo 0; return; }
  command -v "$RUNTIME" >/dev/null 2>&1 || { echo 0; return; }
  if "$RUNTIME" version --format '{{json .Server}}' >/dev/null 2>&1; then echo 1; else echo 0; fi
}

# builder_runtime_message <resolved-runtime> <alternatives> <missing-tools> <was-requested>
#
# Formats the "this build cannot be containerized" failure. Pure — it probes nothing — so every branch
# below is exercised in the tests on any machine.
#
# One message used to cover three situations and got two of them wrong. It said "Install docker or
# podman" to anyone who had merely not started Docker Desktop, which is the most common way to arrive
# here, and to anyone running a perfectly healthy podman that detection had passed over. What is
# actually true differs per case, so the text does too:
#
#   nothing on PATH            -> installing really is the fix
#   present but not answering   -> start it
#   ...and another one answers  -> use that one, with the command that does it
builder_runtime_message() {
  local rt="${1-}" alts="${2-}" missing="${3-}" requested="${4-0}" a

  if [ -z "$rt" ]; then
    echo "ERROR: no container runtime found on PATH, and the local toolchain is incomplete." >&2
    echo "       Missing: ${missing:-(none)}" >&2
    echo "       Install docker or podman (each needs a v2-style 'compose' subcommand) — that is the" >&2
    echo "       only prerequisite — or install the toolchain yourself and re-run with --native." >&2
    return
  fi

  if [ "$requested" = 1 ]; then
    echo "ERROR: '$rt' was requested (RUNTIME) but is not responding, so this build cannot be" >&2
    echo "       containerized." >&2
  else
    echo "ERROR: '$rt' was auto-detected but is not responding, so this build cannot be containerized." >&2
    echo "       Detection tests whether a CLI is on PATH, not whether it is running." >&2
  fi

  if [ -n "$alts" ]; then
    echo "" >&2
    # shellcheck disable=SC2086  # deliberate word-split: alts is a space-separated list
    for a in $alts; do
      if [ "$requested" = 1 ]; then
        echo "       $a is installed and responding. RUNTIME is pinned to '$rt' — change it in .env:" >&2
      else
        echo "       $a is installed and responding. Set it in .env:" >&2
      fi
      echo "" >&2
      echo "           RUNTIME=$a" >&2
      echo "" >&2
      echo "       In .env and not on the command line: run.sh, the build scripts, logs.sh and stop.sh" >&2
      echo "       each resolve the runtime independently, so a one-off would leave the next command on" >&2
      echo "       the other runtime — which is how a build ends up unable to see the running studio." >&2
    done
    echo "" >&2
    echo "       ...or start $rt and re-run." >&2
  else
    echo "" >&2
    case "$rt" in
      docker) echo "       Start it and re-run — on macOS, launch Docker Desktop and wait for it to" >&2
              echo "       report Running." >&2 ;;
      podman) echo "       Start it and re-run:  podman machine start" >&2 ;;
      *)      echo "       Start it and re-run." >&2 ;;
    esac
  fi

  echo "" >&2
  echo "       Or build with a toolchain you installed yourself: --native (missing now: ${missing:-none})" >&2
}

builder_missing_tools() {
  local t out=""
  for t in "${_BUILDER_TOOLS[@]}"; do
    command -v "$t" >/dev/null 2>&1 || out="$out $t"
  done
  printf '%s' "${out# }"
}

# --- Image resolution ----------------------------------------------------------------------------

# _envv is a raw `grep | cut`, so whatever follows the `=` in .env survives verbatim: a CRLF-edited file
# yields "v1<CR>", a quoted value yields "\"v1\"", trailing spaces stay spaces. Every runtime rejects all
# three with "invalid reference format". Strip the three that are unambiguously accidental rather than fail on
# them — nobody means to pin a tag whose name contains a carriage return.
builder_clean_value() {
  local v="${1-}"
  v="${v//$'\r'/}"                                    # CRLF line endings
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; esac # "quoted"
  case "$v" in \'*\') v="${v#\'}"; v="${v%\'}" ;; esac # 'quoted'
  v="${v#"${v%%[![:space:]]*}"}"                      # leading whitespace
  v="${v%"${v##*[![:space:]]}"}"                      # trailing whitespace
  printf '%s' "$v"
}

# Resolve BUILDER_IMAGE, pulling (or, if that fails, building locally) so `$RUNTIME compose run` finds it.
# A local fallback keeps the dev-kit usable before the image is published, and for anyone without quay
# access. Every success path EXPORTS the name: compose reads it from the environment, and an unexported
# one means compose silently falls back to the `${BUILDER_IMAGE:-quay…}` default in docker-compose.yml —
# i.e. runs a different image than the one that was just resolved.
#
# Caching: an image that is already local is used as-is, without contacting the registry, so a warm build
# never pays for a pull. The cost is that a MOVING tag is never refreshed — and BUILDER_TAG=latest, our
# default, is exactly that, on an image whose content is a .NET SDK. BUILDER_PULL=1 forces the re-pull;
# without it the only recourse would be `$RUNTIME rmi`.
#
# Both knobs are read from the environment AND from .env (via _envv), because compose interpolates
# docker-compose.yml against .env too: if .env's BUILDER_IMAGE were ignored here, compose would honour it
# while this function exported a different name over the top of it.
# Shared tail of both pull attempts: a pull that failed while a copy is already local is a warning, not an
# error — "offline with BUILDER_PULL=1 set" is the ordinary way to get here, and a stale toolchain beats no
# build. Returns 0 when BUILDER_IMAGE is usable as-is.
builder_keep_local_copy() { # builder_keep_local_copy <pull-error-text>
  "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || return 1
  echo "WARNING: could not re-pull $BUILDER_IMAGE, using the local copy." >&2
  echo "         $RUNTIME pull said: $(printf '%s' "${1-}" | tail -1)" >&2
}

builder_resolve_image() {
  # The raw value is kept for the error message: BUILDER_PULL may have come from .env rather than the
  # environment, and naming a value the user cannot see in their shell is not a diagnostic.
  local force_pull raw_pull
  raw_pull="$(builder_clean_value "${BUILDER_PULL:-$(_envv BUILDER_PULL)}")"
  force_pull="$(builder_truthy "$raw_pull")" || {
    echo "ERROR: BUILDER_PULL must be a boolean (1/true/yes/on or 0/false/no/off); got '$raw_pull'." >&2
    return 1
  }

  local img pull_err
  img="$(builder_clean_value "${BUILDER_IMAGE:-$(_envv BUILDER_IMAGE)}")"
  if [ -n "$img" ]; then
    BUILDER_IMAGE="$img"; export BUILDER_IMAGE
    if [ "$force_pull" != 1 ] && "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then return 0; fi
    pull_err="$("$RUNTIME" pull -q "$BUILDER_IMAGE" 2>&1)" && return 0
    builder_keep_local_copy "$pull_err" && return 0
    # A pinned image that cannot be obtained is fatal: the caller named one specific image, so quietly
    # building a different one would not be doing what they asked.
    echo "ERROR: BUILDER_IMAGE=$BUILDER_IMAGE is neither present locally nor pullable." >&2
    echo "       $RUNTIME pull said: $(printf '%s' "$pull_err" | tail -1)" >&2
    return 1
  fi

  local tag; tag="$(builder_clean_value "$(_envv BUILDER_TAG)")"; tag="${tag:-latest}"
  # OCI tag grammar: [A-Za-z0-9_][A-Za-z0-9._-]{0,127}. Checked here because the alternative is
  # a pull that fails for an unobvious reason and a silent fall-through to building something else.
  case "$tag" in
    *[!A-Za-z0-9._-]* | [!A-Za-z0-9_]* )
      echo "ERROR: BUILDER_TAG is not a valid image tag: $(printf '%q' "$tag")" >&2
      echo "       Tags are [A-Za-z0-9_][A-Za-z0-9._-]* — check .env for quotes, stray whitespace or" >&2
      echo "       Windows line endings." >&2
      return 1 ;;
  esac
  BUILDER_IMAGE="quay.io/duplocloud/duplo-extension-builder:$tag"; export BUILDER_IMAGE
  if [ "$force_pull" != 1 ] && "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then return 0; fi

  echo "==> Fetching the build toolchain image ($BUILDER_IMAGE)" >&2
  pull_err="$("$RUNTIME" pull -q "$BUILDER_IMAGE" 2>&1)" && return 0
  builder_keep_local_copy "$pull_err" && return 0

  # Not published, or no quay access — build it from the Dockerfile that ships in this repo. `build` is
  # the context, not `.`: the Dockerfile COPYs nothing from the context, so sending the whole repo
  # (samples/, packages/, node_modules/) to the builder would be pure waste.
  #
  # The pull error is reported, not swallowed: "unauthorized", "manifest unknown" and a registry rate
  # limit all land here, and they are the difference between "the image isn't published yet" (fine, build
  # it) and "your credentials expired" (which a two-minute local build silently papers over).
  echo "    pull failed: $(printf '%s' "$pull_err" | tail -1)" >&2
  BUILDER_IMAGE="duplo-extension-builder:local"; export BUILDER_IMAGE
  "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 && return 0
  echo "    building it locally from build/Dockerfile.builder instead (one time, ~2 min)" >&2
  "$RUNTIME" build -q -f build/Dockerfile.builder -t "$BUILDER_IMAGE" build >/dev/null \
    || { echo "ERROR: could not build the builder image from build/Dockerfile.builder" >&2; return 1; }
}

# --- Dispatch ------------------------------------------------------------------------------------

# builder_studio_state -> in-project | absent | unknown
#
# One runtime_compose_running_services call (~0.06s isolated, ~0.11s amortized against a build) — this
# sits in front of every containerized build, so it has to stay a single call. That helper is also what
# keeps the answer correct on podman, whose `compose ps` has no --status/--services flags.
#
# Compose is PROJECT-scoped, and the project defaults to the directory name. So this answers a
# narrower question than "is the platform up": it answers "is the studio on the network this build will
# join". A second checkout (or a git worktree, which is how this repo is developed) is a different
# project, and its running studio is invisible here — hence three states, not two: `absent` is evidence,
# `unknown` (the query itself failed) is not, and they must not lead to the same message.
builder_studio_state() {
  local running
  running="$(runtime_compose_running_services)" || { echo unknown; return; }
  if printf '%s\n' "$running" | grep -qx duplo-ai-studio; then echo in-project; else echo absent; fi
}

# builder_studio_url -> the URL a containerized build should use to reach the studio (stdout), plus a
# warning on stderr if it had to fall back.
#
# In-project, the compose network resolves duplo-ai-studio directly and needs no published port at all.
# Otherwise the published host port is the only way in — that is what reaches a studio belonging to
# another checkout's project, or one started by hand. It is also the safer answer when the state is
# `unknown`: the host port works in BOTH topologies (the stack publishes it either way), whereas the
# compose-network name only works in one.
builder_studio_url() {
  local state; state="$(builder_studio_state)"
  if [ "$state" = in-project ]; then
    printf 'http://duplo-ai-studio:60021'
    return
  fi

  # Matches _target.sh's own default for STUDIO_PORT.
  local port; port="$(builder_clean_value "$(_envv STUDIO_PORT)")"; port="${port:-60021}"
  local url="http://host.docker.internal:$port"

  # Only `absent` earns a warning — and it is non-fatal, because the fallback is a real chance of
  # success rather than a guess, so this says what it is doing instead of refusing to try. `unknown`
  # stays silent: a scary message in front of every build, on no evidence, teaches people to ignore it.
  if [ "$state" = absent ]; then
    echo "WARNING: no running duplo-ai-studio in this compose project ($RUNTIME compose scopes services" >&2
    echo "         per project, and this one is the directory '$(basename "$PWD")'), so the build will" >&2
    echo "         try the published host port instead: $url" >&2
    echo "         That reaches a platform started from another checkout, or by other means. If nothing" >&2
    echo "         is listening there, start this one with ./run.sh. Continuing anyway." >&2
  fi
  printf '%s' "$url"
}

# builder_run_direct <script-relative-path> [args...]
#
# The finch path: run the builder image directly rather than through `compose run`. Its compose
# implementation cannot express this invocation at all — three independent reasons, each verified against
# finch v1.19.0 (nerdctl v2.2.2 underneath), and the first two fail SILENTLY:
#
#  1. INTERPOLATION IGNORES THE SHELL ENVIRONMENT. It reads ${VAR} from the .env file only, so every value
#     builder_dispatch exports falls through to its `:-` default instead. With DUPLO_BASE, DUPLO_UID/GID
#     and BUILDER_IMAGE all exported, `finch compose config` still rendered `DUPLO_BASE: ""`,
#     `user: 1000:1000` and the default image. An empty DUPLO_BASE then resolves in _target.sh to
#     http://localhost:<STUDIO_PORT>, which inside the container is the CONTAINER — so the SDK fetch dies
#     on a URL that looks right; and uid 1000 writes the bundle as an id the caller may not own.
#  2. NO WAY TO SET THE IMAGE. `compose run` takes it from the compose file and has no --image flag, so
#     together with (1) a pinned BUILDER_TAG/BUILDER_IMAGE has no route through at all.
#  3. A TTY IS FORCED. It always allocates one, and every spelling of the opt-out (--tty=false, -t, -T,
#     --no-TTY) is rejected — so a caller whose stdout is not a console (CI, a script, an agent) dies on
#     "provided file is not a console" before the build starts.
#
# `compose --env-file` would have covered 1 and 2 together; finch lists it in `compose --help` but
# mistranslates it into a `-e` that nerdctl rejects underneath, so it is not a way out either.
#
# EVERY FLAG BELOW MIRRORS THE `builder` SERVICE IN docker-compose.yml. That duplication is the price of
# this path — change the service and change this with it.
builder_run_direct() {
  local script="$1"; shift

  # Seeded non-empty on purpose: macOS ships bash 3.2, where expanding an EMPTY array under `set -u`
  # ("${args[@]}") is an unbound-variable error.
  local args
  args=(run --rm -w /work -u "$DUPLO_UID:$DUPLO_GID" -v "$PWD:/work")

  # The per-uid package caches, named exactly as the top-level `volumes:` block names them, so this path
  # and the compose path warm the SAME caches rather than each paying for a cold build.
  args+=(-v "duplo_devkit_nuget_$DUPLO_UID:/cache/nuget")
  args+=(-v "duplo_devkit_npm_$DUPLO_UID:/cache/npm")

  # extra_hosts: the route to a studio that is not on this compose network.
  args+=(--add-host "host.docker.internal:host-gateway")

  # Join the project network ONLY when the studio is in this project — that is exactly the case in which
  # builder_studio_url chose the bare service name http://duplo-ai-studio:60021, which nothing off that
  # network can resolve. When it is absent or unknown the URL is the published host port, which is
  # reachable without joining anything (and the network may not even exist).
  if [ "$(builder_studio_state)" = in-project ]; then
    args+=(--net "$(runtime_compose_project)_default")
  fi

  # platform: ${BUILDER_PLATFORM:-} — omitted entirely when unset, so the build stays on the host's
  # native architecture instead of silently emulating one.
  if [ -n "${BUILDER_PLATFORM:-}" ]; then
    args+=(--platform "$BUILDER_PLATFORM")
  fi

  # The environment: block, value for value. Passed as real flags, which is the whole point: unlike
  # compose interpolation above, `run -e` does not consult .env and cannot silently drop them.
  args+=(-e "DUPLO_BUILD_NATIVE=1")
  args+=(-e "DUPLO_TARGET=${DUPLO_TARGET:-local}")
  args+=(-e "DUPLO_BASE=${DUPLO_BASE:-}")
  args+=(-e "DUPLO_HOST=${DUPLO_HOST:-}")
  args+=(-e "DUPLO_TOKEN=${DUPLO_TOKEN:-}")
  args+=(-e "DUPLO_ADMIN_TOKEN=${DUPLO_ADMIN_TOKEN:-}")

  exec "$RUNTIME" "${args[@]}" "$BUILDER_IMAGE" "$script" "$@"
}

# builder_dispatch <script-relative-path> [args...]
# Returns 0 to mean "carry on natively". Otherwise it runs the build in the container and exits with
# the container's status — it never returns in that case.
#
# CALL IT EARLY: before installing any EXIT trap and before creating any temp file. The container path
# ends in `exec`, which replaces this process — so the caller's EXIT trap never fires and anything it
# would have cleaned up is leaked. (The native and error paths do run the trap; only the container path
# skips it.) Both current callers happen to satisfy this because dispatch sits near the top of the
# script, above their traps and mktemps; that is a requirement, not a coincidence to preserve by luck.
builder_dispatch() {
  local script="$1"; shift

  # Precedence: --native (which sets the variable) → the environment → .env → default containerized.
  # Reading .env matters because that is the only per-repo, per-user place to say "this laptop has the
  # toolchain, always build natively" — an exported shell variable is per-shell, and every other knob
  # here (BUILDER_TAG, BUILDER_IMAGE, BUILDER_PULL) is already an .env key. builder_clean_value strips
  # the CR and stray quotes a Windows-edited .env leaves behind, so `DUPLO_BUILD_NATIVE=1` there behaves
  # the same as on the command line. Captured in a variable so the badarg message below can echo the
  # value we actually resolved, which is not necessarily the one in the environment.
  local want_native; want_native="$(builder_clean_value "${DUPLO_BUILD_NATIVE:-$(_envv DUPLO_BUILD_NATIVE)}")"

  # Resolve the CLI before probing. Failure is only fatal when a runtime was NAMED: the caller said
  # which one to use, and quietly building with a different one — or dropping to a native build they
  # did not ask for — is not what they asked for. Auto-detect finding nothing stays silent, because
  # builder_mode's native fallback below still builds on a machine with the full toolchain, and that is
  # what keeps a runtime-less CI runner working. The re-run is to print the specific reason, which was
  # suppressed on the first call.
  runtime_resolve 2>/dev/null || {
    if [ -n "$(runtime_requested)" ]; then runtime_resolve; exit 1; fi
  }

  local mode; mode="$(builder_mode \
    "$want_native" \
    "$(builder_probe_in_container)" \
    "$(builder_probe_toolchain)" \
    "$(builder_probe_runtime)")"

  case "$mode" in
    native) return 0 ;;
    error:toolchain)
      echo "ERROR: missing build tool(s): $(builder_missing_tools)" >&2
      echo "       This is running inside a container with no reachable runtime, so the build cannot be" >&2
      echo "       delegated. Use an image that ships the toolchain (.NET SDK 8 + Node 22), e.g." >&2
      echo "       build/Dockerfile.builder in this repo." >&2
      exit 1 ;;
    error:runtime)
      builder_runtime_message "${RUNTIME:-}" "$(runtime_alternatives)" "$(builder_missing_tools)" \
        "$([ -n "$(runtime_requested)" ] && echo 1 || echo 0)"
      exit 1 ;;
    container) ;;
    # error:badarg, or a mode this function hasn't been taught. The only way to reach it in practice is
    # a non-boolean DUPLO_BUILD_NATIVE, which is exactly the typo builder_truthy refuses to coerce — so
    # say so instead of falling through to a container build the caller may not have asked for.
    *)
      echo "ERROR: could not decide how to build ($mode)." >&2
      echo "       DUPLO_BUILD_NATIVE must be a boolean (1/true/yes/on or 0/false/no/off); got" >&2
      echo "       '$want_native'. Check your environment and the DUPLO_BUILD_NATIVE line in .env." >&2
      exit 1 ;;
  esac

  # Only /work (this checkout) is mounted, so a path that resolves outside it does not exist in the
  # container and the build dies with a confusing "No manifest.json in /Users/you/elsewhere". Say the
  # real thing here. Checked only on the container path — natively those paths work fine, and the
  # arguments are the caller's extension directory, never the script path, which is ours.
  local a
  for a in "$@"; do
    case "$a" in
      /* | ../* | */../* | .. | */..)
        echo "ERROR: '$a' is outside this checkout, and only the checkout is mounted into the build" >&2
        echo "       container (at /work). Use a path relative to the checkout root, e.g." >&2
        echo "       samples/helloworld — or build with --native to use a path anywhere on disk." >&2
        exit 1 ;;
    esac
  done

  # localhost means nothing in here, so a local target needs a real route to the studio: the compose
  # network if it is in this project, the published host port otherwise. Only the URL is overridden —
  # .env is inside the bind mount, so _target.sh still resolves the token itself inside the container.
  #
  # `-z "${DUPLO_BASE:-}"` matters: a caller who set DUPLO_BASE has already said where the platform is
  # (a remote host, a tunnel, a port-forward), and overwriting it would silently redirect their build.
  #
  # Settled BEFORE the image is resolved, because resolving can mean a multi-minute local image build:
  # nobody should sit through that only to then be told their platform isn't running.
  if [ "${_TARGET:-local}" = local ] && [ -z "${DUPLO_BASE:-}" ]; then
    DUPLO_BASE="$(builder_studio_url)"
  fi

  builder_resolve_image || exit 1

  # Run as whichever ids make dist/ come out owned by the caller rather than by root or by an
  # unreachable subuid — BOTH halves: uid alone leaves the group as the compose default, i.e. a bundle
  # the caller's group cannot write. Which ids those are differs per runtime, so the choice lives in
  # runtime_builder_ids (see the long note there: rootless podman needs 0:0, docker needs the real uid).
  read -r DUPLO_UID DUPLO_GID <<<"$(runtime_builder_ids)"
  export DUPLO_UID DUPLO_GID BUILDER_IMAGE DUPLO_BASE DUPLO_TARGET="${_TARGET:-local}"

  echo "==> Building in $BUILDER_IMAGE via $(runtime_label) (uid $DUPLO_UID:$DUPLO_GID)" \
       "— --native to use your own toolchain"
  # --rm: the container is a one-shot. --no-deps: never start the platform as a side effect of a build.
  #
  # --profile tools is REQUIRED, not belt-and-braces: the builder service sits behind that profile, and
  # while `docker compose run` implicitly enables the profiles of the service it was asked to run,
  # podman-compose 1.5 does not — it reports "missing services [builder]" and exits 1. Naming the
  # profile explicitly is a no-op on docker and the only way in on podman. (COMPOSE_PROFILES=tools is
  # NOT an alternative here: podman-compose ignores that variable.)
  #
  # -T (don't allocate a pseudo-TTY) is what makes this safe to exec from a script whose stdio is
  # already a pipe — CI, or an agent. Nothing in a build wants a TTY.
  #
  # TWO DISPATCH PATHS, because `compose run` is only usable on half the supported CLIs. docker and
  # podman keep the original invocation verbatim. finch cannot use compose for this at all: it rejects
  # -T outright ("unknown shorthand flag: 'T' in -T") and then forces a TTY anyway with no opt-out, on
  # top of ignoring the exported DUPLO_BASE/DUPLO_UID/BUILDER_IMAGE entirely — so it runs the image
  # directly instead. builder_run_direct has the evidence for each of those.
  case "$RUNTIME" in
    docker|podman)
      exec "$RUNTIME" compose --profile tools run --rm -T --no-deps builder "$script" "$@" ;;
    *)
      builder_run_direct "$script" "$@" ;;
  esac
}
