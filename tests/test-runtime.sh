#!/usr/bin/env bash
# Checks the container-runtime abstraction in scripts/_runtime.sh, and that nothing in the kit has
# gone back to calling `docker` directly.
#
# Static + pure-function checks only: nothing here starts the stack, pulls an image, or needs any
# particular runtime to be installed — so it runs the same on a docker laptop, a podman box and CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Resolution is exercised in a subshell per case: runtime_resolve exports RUNTIME and memoises itself,
# so cases would otherwise contaminate each other. DUPLO_ENV_FILE=/dev/null keeps a developer's real
# .env (which may pin RUNTIME) out of the auto-detect cases.
res() { # res <env-assignments> -> prints "<rc>|<RUNTIME>"
  ( eval "$1"; export DUPLO_ENV_FILE=/dev/null
    . ./scripts/_runtime.sh
    if runtime_resolve 2>/dev/null; then printf '0|%s' "$RUNTIME"; else printf '1|'; fi )
}

echo "container runtime abstraction:"

t "_runtime.sh is syntactically valid and sourcing it defines the API"
if bash -n scripts/_runtime.sh 2>/dev/null && \
   ( . ./scripts/_runtime.sh
     for f in runtime_detect runtime_resolve runtime_requested runtime_builder_ids \
              runtime_is_rootless_podman runtime_compose_project runtime_compose_running_services \
              runtime_label runtime_rosetta_check; do
       declare -F "$f" >/dev/null || exit 1
     done ); then ok; else bad "missing function(s)"; fi

t "every supported runtime is accepted when present on PATH"
MISS=""
for r in docker podman; do
  command -v "$r" >/dev/null 2>&1 || continue          # only assert about what's installed here
  [ "$(res "RUNTIME=$r")" = "0|$r" ] || MISS="$MISS $r"
done
if [ -z "$MISS" ]; then ok; else bad "rejected:$MISS"; fi

t "runc and friends are rejected as low-level OCI runtimes, not silently accepted"
MISS=""
for r in runc crun youki runsc; do
  [ "$(res "RUNTIME=$r")" = "1|" ] || MISS="$MISS $r"
done
if [ -z "$MISS" ]; then ok; else bad "not rejected:$MISS"; fi

t "the runc rejection explains itself rather than saying 'unsupported'"
MSG="$( ( export DUPLO_ENV_FILE=/dev/null RUNTIME=runc
          . ./scripts/_runtime.sh; runtime_resolve ) 2>&1 )"
if grep -q 'low-level OCI runtime' <<<"$MSG" && grep -q 'compose' <<<"$MSG" && grep -q 'podman' <<<"$MSG"
then ok; else bad "unhelpful message: $MSG"; fi

t "an unknown runtime is rejected"
if [ "$(res "RUNTIME=nosuchruntime")" = "1|" ]; then ok; else bad "accepted"; fi

t "a requested-but-absent runtime is rejected rather than falling back to another"
# Must name a SUPPORTED runtime that happens not to be installed here — an unsupported name would be
# rejected by the wrong branch and the test would pass while proving nothing. Which one that is differs
# per machine, so find it rather than hard-coding one.
ABSENT=""
for r in docker podman; do
  command -v "$r" >/dev/null 2>&1 || { ABSENT="$r"; break; }
done
if [ -z "$ABSENT" ]; then ok                     # every supported runtime is installed here
elif [ "$(res "RUNTIME=$ABSENT")" = "1|" ]; then ok
else bad "fell back instead of failing"; fi

t "values are cleaned of quotes, whitespace and CRs before use"
R="$(res 'RUNTIME=" podman "')"
if ! command -v podman >/dev/null 2>&1; then ok      # nothing to assert on a podman-less box
elif [ "$R" = "0|podman" ]; then ok; else bad "got '$R'"; fi

t "auto-detect picks an installed runtime, preferring docker"
R="$(res 'unset RUNTIME')"
EXPECT=""; for r in docker podman; do command -v "$r" >/dev/null 2>&1 && { EXPECT="$r"; break; }; done
if [ -z "$EXPECT" ]; then ok                          # no runtime installed: nothing to prefer
elif [ "$R" = "0|$EXPECT" ]; then ok; else bad "got '$R', expected '0|$EXPECT'"; fi

t "runtime_requested distinguishes an explicit choice from auto-detect"
A="$( ( export DUPLO_ENV_FILE=/dev/null; unset RUNTIME; . ./scripts/_runtime.sh; runtime_requested ) )"
B="$( ( export DUPLO_ENV_FILE=/dev/null RUNTIME=podman; . ./scripts/_runtime.sh; runtime_requested ) )"
if [ -z "$A" ] && [ "$B" = podman ]; then ok; else bad "auto='$A' explicit='$B'"; fi

# Rosetta preflight. The two impure parts — what the host CPU is, and whether the podman machine has a
# rosetta binfmt handler — are separate functions precisely so the POLICY can be exercised here without
# podman, a VM, or an Apple Silicon host. Redefining them after sourcing is the seam.
ros() { # ros <host-arch> <studio-platform> <probe-rc> [runtime] -> "<rc>|<first line of stderr>"
  ( HA="$1"; PL="$2"; PRC="$3"
    export DUPLO_ENV_FILE=/dev/null RUNTIME="${4:-podman}" STUDIO_PLATFORM="$PL"
    # Pin the provider inputs too: left alone, the check reads the developer's real containers.conf and
    # shells out to podman, and these cases would then answer differently on an applehv laptop than on
    # CI. The provider's own behaviour is asserted through rosmsg below, where it is set explicitly.
    export CONTAINERS_CONF=/dev/null; unset CONTAINERS_MACHINE_PROVIDER
    . ./scripts/_runtime.sh
    eval "_runtime_host_arch() { printf '%s' '$HA'; }"
    eval "runtime_rosetta_active() { return $PRC; }"
    _runtime_machine_vmtype() { printf ''; }
    ERR="$(runtime_rosetta_check 2>&1 >/dev/null)"; RC=$?
    printf '%s|%s' "$RC" "$(printf '%s' "$ERR" | head -1)" )
}

# The remediation the check prints depends on what containers.conf already says. Appending a second
# [machine] table to an existing file is a TOML "key already defined" error that stops podman dead, so
# the advice must never be one-size-fits-all. CONTAINERS_CONF is podman's own override, so pointing it
# at a fixture is both faithful and testable.
conf() { # conf <file-contents-or-NONE> -> the state word
  ( F=/dev/null
    if [ "$1" != NONE ]; then F="$(mktemp)"; printf '%s' "$1" > "$F"; else F="$(mktemp -u)"; fi
    export CONTAINERS_CONF="$F"
    . ./scripts/_runtime.sh
    _runtime_rosetta_conf_state )
}

t "conf state reports absent when containers.conf does not exist"
[ "$(conf NONE)" = absent ] && ok || bad "got '$(conf NONE)'"

t "conf state reports enabled when [machine] already sets rosetta = true"
R="$(conf '[containers]
[machine]
rosetta = true
[network]
')"
[ "$R" = enabled ] && ok || bad "got '$R'"

t "conf state reports disabled when [machine] explicitly sets rosetta = false"
R="$(conf '[machine]
rosetta = false
')"
[ "$R" = disabled ] && ok || bad "got '$R'"

t "conf state reports no-key when [machine] exists without a rosetta key"
R="$(conf '[containers]
[machine]
cpus = 4
')"
[ "$R" = no-key ] && ok || bad "got '$R'"

t "conf state finds [machine] when the header carries a trailing comment"
# `[machine]   # my settings` is valid TOML. Anchoring the scan on end-of-line after the header hid the
# section, and the resulting no-machine advice tells the user to ADD [machine] — a duplicate-key error
# that stops podman outright, on a user whose config was already correct.
R="$(conf '[containers]
[machine]   # my settings
rosetta = true
')"
[ "$R" = enabled ] && ok || bad "got '$R' (a commented header must not read as a missing section)"

t "conf state reports no-machine when the file exists with no [machine] section"
R="$(conf '[containers]
[engine]
env = []
')"
[ "$R" = no-machine ] && ok || bad "got '$R'"

# Machine provider. Rosetta is an applehv feature: the libkrun provider's GetRosetta returns false
# unconditionally upstream, so `rosetta = true` under libkrun is read and discarded. The provider is
# therefore part of the diagnosis, not a detail. Resolution order mirrors podman's own, and the podman
# call is its own function so the policy is testable without a VM.
prov() { # prov <env-assignments> <conf-contents-or-NONE> <vmtype-or-NONE> -> the provider word
  ( eval "$1"
    if [ "$2" != NONE ]; then F="$(mktemp)"; printf '%s' "$2" > "$F"; else F="$(mktemp -u)"; fi
    export CONTAINERS_CONF="$F"
    . ./scripts/_runtime.sh
    if [ "$3" != NONE ]; then eval "_runtime_machine_vmtype() { printf '%s' '$3'; }"
    else _runtime_machine_vmtype() { printf ''; }; fi
    _runtime_machine_provider )
}

t "an existing machine's VMType outranks containers.conf, which only describes the NEXT machine"
# `podman machine init --provider applehv` does not write containers.conf, so the two disagree the
# moment anyone passes the flag — and the VM that is running is the one this run will talk to. Reading
# the config first would blame libkrun for a healthy applehv machine and advise destroying it.
R="$(prov 'unset CONTAINERS_MACHINE_PROVIDER' '[machine]
provider = "libkrun"
' applehv)"
[ "$R" = applehv ] && ok || bad "got '$R'"

t "with no machine yet, CONTAINERS_MACHINE_PROVIDER outranks containers.conf"
R="$(prov 'export CONTAINERS_MACHINE_PROVIDER=applehv' '[machine]
provider = "libkrun"
' NONE)"
[ "$R" = applehv ] && ok || bad "got '$R'"

t "with no machine and no environment override, containers.conf says what the next machine will be"
R="$(prov 'unset CONTAINERS_MACHINE_PROVIDER' '[machine]
provider = "libkrun"
' NONE)"
[ "$R" = libkrun ] && ok || bad "got '$R'"

t "machine provider is empty rather than guessed when nothing can say"
R="$(prov 'unset CONTAINERS_MACHINE_PROVIDER' NONE NONE)"
[ -z "$R" ] && ok || bad "got '$R'"

t "rosetta check fails when an amd64 image would run on an arm64 host without Rosetta"
R="$(ros arm64 linux/amd64 1)"
case "$R" in 1\|*[Rr]osetta*) ok ;; *) bad "got '$R'" ;; esac

rosmsg() { # rosmsg <conf-contents-or-NONE> [provider] -> the whole stderr message
  ( C="$1"; P="${2-}"
    if [ "$C" != NONE ]; then F="$(mktemp)"; printf '%s' "$C" > "$F"; else F="$(mktemp -u)"; fi
    export DUPLO_ENV_FILE=/dev/null RUNTIME=podman STUDIO_PLATFORM=linux/amd64 CONTAINERS_CONF="$F"
    . ./scripts/_runtime.sh
    _runtime_host_arch() { printf 'arm64'; }
    runtime_rosetta_active() { return 1; }
    # Unset provider (the default) is the "cannot tell" case: the advice must still stand on the config
    # alone, which is what every pre-existing case below asserts.
    eval "_runtime_machine_provider() { printf '%s' '$P'; }"
    runtime_rosetta_check 2>&1 >/dev/null )
}

# NOTE: capture into a variable, never `rosmsg ... | grep -q`. Under the `set -o pipefail` at the top of
# this file, grep -q exits on first match, SIGPIPEs the writer, and the pipeline reports the writer's
# failure — so the condition reads FALSE precisely when the pattern matched. That silently inverted
# these three assertions when they were first written.
t "the fix never suggests appending a second [machine] table to an existing config"
M="$(rosmsg '[containers]
[machine]
rosetta = false
')"
if printf '%s\n' "$M" | grep -qE '>>[[:space:]]*[^|]*containers\.conf'; then
  bad "tells the user to append a second [machine] table — a TOML duplicate-key error that stops podman"
else ok; fi

t "an applehv machine whose config is already right points at a restart, not at recreating"
# applehv's StartVM re-reads cfg.Machine.Rosetta from containers.conf on every start and syncs it into
# the machine config, so the key really does take effect without re-initialising. Only the PROVIDER is
# fixed at init. Telling an applehv user to destroy their VM would cost them images and volumes for a
# change a stop/start already makes.
M="$(rosmsg '[machine]
rosetta = true
' applehv)"
if printf '%s\n' "$M" | grep -qi 'already' && printf '%s\n' "$M" | grep -q 'podman machine start' \
   && ! printf '%s\n' "$M" | grep -q 'podman machine rm'; then ok
else bad "got: $(printf '%s' "$M" | sed -n '9,16p' | tr '\n' ' ')"; fi

t "a libkrun machine is diagnosed as the provider, not as a missing or unrestarted config"
M="$(rosmsg '[machine]
provider = "libkrun"
rosetta = true
' libkrun)"
if printf '%s\n' "$M" | grep -q 'applehv' && printf '%s\n' "$M" | grep -qi 'libkrun'; then ok
else bad "never names the provider: $(printf '%s' "$M" | sed -n '5,14p' | tr '\n' ' ')"; fi

t "the libkrun remediation does not send the user back to a config that is already correct"
M="$(rosmsg '[machine]
provider = "libkrun"
rosetta = true
' libkrun)"
if printf '%s\n' "$M" | grep -qi 'rosetta = true.*add\|add.*rosetta = true'; then
  bad "tells them to add a key they already have"
else ok; fi

t "a non-applehv machine is never told a restart will do, because the provider is fixed at init"
# The provider — unlike rosetta — is written at `podman machine init` and never revisited. The old
# footer's "it does NOT need to be recreated, and nothing is lost" is true for applehv and false here,
# and it is the sentence that turns a five-minute fix into an afternoon of recreating the same VM.
M="$(rosmsg '[machine]
provider = "libkrun"
rosetta = true
' libkrun)"
if printf '%s\n' "$M" | grep -qi 'not need to be recreated'; then
  bad "promises a restart is enough for a provider that can never honour the key"
elif printf '%s\n' "$M" | grep -q 'podman machine rm'; then ok
else bad "never tells them to recreate: $(printf '%s' "$M" | sed -n '20,28p' | tr '\n' ' ')"; fi

t "a missing config gets a create command that cannot clobber anything"
M="$(rosmsg NONE)"
# `>` not `>>`: there is no file to append to, and `>>` would be the wrong habit to teach.
if printf '%s\n' "$M" | grep -qE "printf .* > " && printf '%s\n' "$M" | grep -qi 'create it'; then ok
else bad "no safe create command: $(printf '%s' "$M" | sed -n '10,13p' | tr '\n' ' ')"; fi

t "rosetta check is a no-op on docker, which provides Rosetta itself"
R="$(ros arm64 linux/amd64 1 docker)"
[ "$R" = "0|" ] && ok || bad "got '$R'"

t "rosetta check is a no-op for an arm64 studio image, which needs no translation"
R="$(ros arm64 linux/arm64 1)"
[ "$R" = "0|" ] && ok || bad "got '$R'"

t "rosetta check is a no-op on an amd64 host, which needs no translation"
R="$(ros amd64 linux/amd64 1)"
[ "$R" = "0|" ] && ok || bad "got '$R'"

t "rosetta check is a no-op when Rosetta is active"
R="$(ros arm64 linux/amd64 0)"
[ "$R" = "0|" ] && ok || bad "got '$R'"

t "rosetta check stays quiet when the machine cannot be probed rather than crying wolf"
R="$(ros arm64 linux/amd64 2)"
[ "$R" = "0|" ] && ok || bad "got '$R'"

t "rosetta check treats an unset STUDIO_PLATFORM as amd64, matching the compose default"
R="$(ros arm64 "" 1)"
case "$R" in 1\|*[Rr]osetta*) ok ;; *) bad "got '$R'" ;; esac

t "builder ids are the caller's uid/gid on docker, but 0:0 on rootless podman"
IDS="$( ( export DUPLO_ENV_FILE=/dev/null; . ./scripts/_runtime.sh; runtime_resolve 2>/dev/null
          runtime_builder_ids ) )"
if [ -z "$IDS" ]; then bad "no ids"
elif [ "$( ( export DUPLO_ENV_FILE=/dev/null; . ./scripts/_runtime.sh
             runtime_resolve 2>/dev/null; runtime_is_rootless_podman ) )" = 1 ]; then
  [ "$IDS" = "0 0" ] && ok || bad "rootless podman should be '0 0', got '$IDS'"
else
  [ "$IDS" = "$(id -u) $(id -g)" ] && ok || bad "expected '$(id -u) $(id -g)', got '$IDS'"
fi

echo
echo
echo "runtime failure messages:"

# runtime_alternatives asks, of the runtimes we did NOT pick, which ones actually answer. The reachability
# probe is its own function so the policy is testable with no runtime installed at all — the same seam
# runtime_rosetta_active provides for the Rosetta check.
alts() { # alts <resolved-runtime> <space-separated list that answers> -> runtime_alternatives output
  ( export DUPLO_ENV_FILE=/dev/null RUNTIME="$1"; ANS=" $2 "
    . ./scripts/_runtime.sh
    eval '_runtime_answers() { case "$ANS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }'
    runtime_alternatives )
}

t "alternatives never include the runtime we already resolved to"
[ "$(alts docker 'docker podman')" = podman ] && ok || bad "got '$(alts docker 'docker podman')'"

t "alternatives list only runtimes that actually answer"
[ "$(alts docker '')" = "" ] && ok || bad "got '$(alts docker '')' for a box where nothing answers"

t "alternatives are empty when the only other runtime is installed but dead"
[ "$(alts podman 'podman')" = "" ] && ok || bad "got '$(alts podman 'podman')'"

# A compose-capable alternative is a narrower question than a reachable one: a runtime can answer and
# still have no `compose` subcommand, in which case naming it as the way out would send the user in a
# circle. Both probes are separate functions so this is testable with neither runtime installed.
altsc() { # altsc <resolved> <answers list> <has-compose list> -> runtime_alternatives_compose output
  ( export DUPLO_ENV_FILE=/dev/null RUNTIME="$1"; ANS=" $2 "; CMP=" $3 "
    . ./scripts/_runtime.sh
    eval '_runtime_answers()     { case "$ANS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }'
    eval '_runtime_has_compose() { case "$CMP" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }'
    runtime_alternatives_compose )
}

t "compose alternatives name a runtime that both answers and has compose"
[ "$(altsc podman 'docker podman' 'docker')" = docker ] && ok || bad "got '$(altsc podman 'docker podman' 'docker')'"

t "compose alternatives exclude a runtime that answers but has no compose"
[ "$(altsc podman 'docker' '')" = "" ] && ok || bad "got '$(altsc podman 'docker' '')' — naming it sends the user in a circle"

t "compose alternatives never include the runtime we already resolved to"
[ "$(altsc docker 'docker' 'docker')" = "" ] && ok || bad "got '$(altsc docker 'docker' 'docker')'"

t "run.sh's compose preflight names a compose-capable alternative"
# Hit in practice: .env pinned RUNTIME=podman, podman's socket was broken, docker was up with compose
# v2 — and the failure listed install advice for both runtimes without saying docker would just work.
if grep -B4 -A14 "compose version' failed" run.sh | grep -q 'runtime_alternatives_compose'; then ok
else bad "compose preflight still recites prerequisites instead of naming the working runtime"; fi

# The message itself is pure: given what was resolved, what else answers, and what the toolchain lacks,
# it only formats. No probing, so every case below is exercised on any machine.
msg() { # msg <runtime> <alternatives> <missing-tools> <was-requested> -> the whole message
  ( export DUPLO_ENV_FILE=/dev/null
    . ./scripts/_builder.sh
    builder_runtime_message "$1" "$2" "$3" "$4" 2>&1 )
}

t "case A: an auto-detected but dead runtime names the working alternative and how to use it"
M="$(msg docker podman dotnet 0)"
if grep -q 'podman' <<<"$M" && grep -q 'RUNTIME=podman' <<<"$M" && grep -qiE 'not responding' <<<"$M"
then ok; else bad "$M"; fi

t "case A: it never tells you to install the runtime you already have"
M="$(msg docker podman dotnet 0)"
if grep -qiE 'install docker|install docker or podman' <<<"$M"; then
  bad "tells the user to install docker, which is installed — the whole bug"
else ok; fi

t "case A-prime: an EXPLICITLY requested runtime is not described as auto-detected"
M="$(msg docker podman dotnet 1)"
if grep -qi 'auto-detected' <<<"$M"; then bad "implies they did not choose it: $M"
elif grep -qiE 'requested|asked for' <<<"$M" && grep -q 'RUNTIME=podman' <<<"$M"; then ok
else bad "$M"; fi

t "case B: a dead runtime with no alternative says to START it, not to install it"
M="$(msg docker '' dotnet 0)"
if grep -qiE 'install docker' <<<"$M"; then bad "says install, but docker is present: $M"
elif grep -qiE 'start' <<<"$M" && grep -qiE 'not responding|installed but' <<<"$M"; then ok
else bad "$M"; fi

t "case B: the --native escape hatch is offered and names what is missing"
M="$(msg docker '' dotnet 0)"
if grep -q -- '--native' <<<"$M" && grep -q 'dotnet' <<<"$M"; then ok; else bad "$M"; fi

t "case C: with nothing on PATH at all, installing IS the right advice"
M="$(msg '' '' dotnet 0)"
if grep -qiE 'install' <<<"$M" && grep -qiE 'on PATH|found' <<<"$M"; then ok; else bad "$M"; fi

t "case C is distinguishable from case B in the first line"
if [ "$(msg '' '' dotnet 0 | head -1)" != "$(msg docker '' dotnet 0 | head -1)" ]; then ok
else bad "'nothing installed' and 'installed but stopped' open identically"; fi

t "run.sh's not-ready warning names a working alternative when there is one"
if grep -A6 'doesn.t look ready\|not responding' run.sh | grep -q 'runtime_alternatives'; then ok
else bad "run.sh warns the runtime is dead without mentioning the healthy one sitting next to it"; fi

t "run.sh says which runtime it picked on the happy path, not only on failure"
# Presence-based auto-detect means the choice is invisible until something breaks; one line fixes that.
if grep -B4 'Pulling images' run.sh | grep -qE 'runtime_label|using .*RUNTIME|\$RUNTIME"?\)'; then ok
else bad "no runtime announced next to 'Pulling images'"; fi

t "builder_dispatch's error:runtime branch delegates to the message function"
if grep -A4 'error:runtime)' scripts/_builder.sh | grep -q 'builder_runtime_message'; then ok
else bad "the branch still inlines its own text, so none of the above applies to a real build"; fi

echo "no stray hard-coded docker calls:"

# The scripts that drive containers. Anything invoking the CLI must go through $RUNTIME so that the
# RUNTIME setting is actually honoured — a single stray `docker compose` silently ignores it.
#
# Detection strips comments AND double-quoted strings before matching: the kit legitimately NAMES these
# CLIs in help and error text ("Install docker, podman, …"), and only an actual invocation matters. A
# command name is never itself inside quotes, so dropping quoted spans cannot hide a real call. The
# `exec`/`command` prefix is matched explicitly — `exec docker compose` is exactly how logs.sh and the
# build dispatcher invoke it, and a check that missed that would pass while testing nothing.
#
# nerdctl and finch stay in the alternation below even though neither is a SUPPORTED runtime: this is a
# lint against hard-coding any CLI, and hard-coding an unsupported one is worse, not better.
t "no script invokes 'docker'/'podman' as a command instead of \$RUNTIME"
STRAY=""
for f in run.sh stop.sh logs.sh scripts/*.sh tests/*.sh; do
  [ "$f" = tests/test-runtime.sh ] && continue        # this file names them on purpose
  sed -e 's/[[:space:]]*#.*$//' -e 's/"[^"]*"//g' "$f" \
    | grep -qE '(^|[^-[:alnum:]_./$])((exec|command)[[:space:]]+)?(docker|podman|nerdctl|finch)[[:space:]]+(compose|run|pull|build|images?|ps|info|version|rmi?|logs|volume|inspect|exec)\b' \
    && STRAY="$STRAY $f"
done
if [ -z "$STRAY" ]; then ok; else bad "hard-coded CLI in:$STRAY"; fi

t "run.sh runs both podman preflights, and after RUNTIME is resolved"
if MC=$(grep -n '^runtime_machine_check' run.sh | cut -d: -f1) && \
   RC=$(grep -n '^runtime_rosetta_check' run.sh | cut -d: -f1) && \
   RES=$(grep -n 'runtime_resolve' run.sh | head -1 | cut -d: -f1) && \
   [ -n "$MC" ] && [ -n "$RC" ] && [ "$RES" -lt "$MC" ] && [ "$RES" -lt "$RC" ]; then ok
else bad "machine=${MC:-absent} rosetta=${RC:-absent} resolve=${RES:-absent}"; fi

t "every script that runs containers sources _runtime.sh and resolves before using \$RUNTIME"
MISS=""
for f in run.sh stop.sh logs.sh scripts/_builder.sh scripts/switch-llm.sh scripts/detect-bedrock.sh; do
  grep -q '_runtime.sh' "$f" || MISS="$MISS $f"
done
if [ -z "$MISS" ]; then ok; else bad "not sourced in:$MISS"; fi

t "the builder run names its compose profile (podman-compose won't infer it)"
if grep -q 'compose --profile tools run' scripts/_builder.sh; then ok
else bad "scripts/_builder.sh must pass --profile tools"; fi

t "docker-compose.yml has no nested \${...\${...}} (podman-compose mis-parses it)"
# Comments are stripped first: the comment above that line documents the broken form on purpose, and
# a comment cannot affect how compose interpolates anything.
if sed 's/[[:space:]]*#.*$//' docker-compose.yml | grep -qE '\$\{[^}]*\$\{'; then
  bad "nested interpolation present"; else ok; fi

t ".env.example documents RUNTIME and says runc is not a valid value"
if grep -q '^#RUNTIME=' .env.example && grep -qi 'runc' .env.example; then ok; else bad ".env.example"; fi

t "run.sh creates .env before it resolves the runtime"
# runtime_resolve reads RUNTIME from .env and memoises itself, so if .env is created after it runs, a
# first run on a box with both CLIs installed auto-detects docker and ignores RUNTIME=podman entirely --
# for both preflights, `compose pull` and `compose up`.
ENVL="$(grep -n 'cp .env.example' run.sh | head -1 | cut -d: -f1)"
RESL="$(grep -nE '^runtime_resolve' run.sh | head -1 | cut -d: -f1)"
if [ -n "$ENVL" ] && [ -n "$RESL" ] && [ "$ENVL" -lt "$RESL" ]; then ok
else bad ".env created at line ${ENVL:-?} but runtime resolved at ${RESL:-?} -- RUNTIME in .env is ignored on a first run"; fi

t "podman compose guidance names more than one way to get a provider"
# podman needs *a* compose provider, not specifically podman-compose: a docker-compose binary satisfies
# `podman compose` just as well, and Podman Desktop installs one. Naming only the brew package sends
# people to install a second provider they may already have under another name.
MISS=""
for f in run.sh docs/getting-started/prerequisites.md; do
  if grep -q 'podman-compose' "$f" 2>/dev/null; then
    grep -qi 'podman desktop' "$f" 2>/dev/null || MISS="$MISS $f"
  fi
done
if [ -z "$MISS" ]; then ok; else bad "names only podman-compose, no alternative route:$MISS"; fi

t "runtime install guidance names brew only, not apt or dnf"
# Linux is not supported right now, so apt/dnf guidance sends the large majority of users to a command
# that does not exist on their machine.
# Scoped to the podman-compose guidance this PR added; the pre-existing python3 hint is not ours.
HITS="$(grep -n 'podman-compose' run.sh docs/getting-started/prerequisites.md 2>/dev/null | grep -E 'apt|dnf')"
if [ -z "$HITS" ]; then ok; else bad "non-brew install guidance: $HITS"; fi

t "bash -n on every shell script in the kit"
BADF=""
for f in run.sh stop.sh logs.sh scripts/*.sh tests/*.sh; do bash -n "$f" 2>/dev/null || BADF="$BADF $f"; done
if [ -z "$BADF" ]; then ok; else bad "syntax:$BADF"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
