# Troubleshooting

Symptoms you can grep for, why they happen, and how to fix them. For questions you have *before* something
breaks — licensing, data, platform support — see [faq.md](faq.md).

> ### 🔒 Redact before you paste
>
> `.env` holds live secrets: `ANTHROPIC_API_KEY`, `AWS_SECRET_ACCESS_KEY`, `DUPLO_ADMIN_TOKEN`,
> `Authentication__LocalAdminPassword`, and `Licensing__Token` (your license, issued to you and not
> re-issuable). Container logs can echo configuration too. **Remove every one of them before pasting logs,
> `.env`, or command output into an issue, a chat, or a support request.**

- [Install and startup](#install-and-startup)
- [Licensing](#licensing)
- [LLM provider](#llm-provider)
- [Providers: AWS and Kubernetes](#providers-aws-and-kubernetes)
- [Extensions](#extensions)
- [State and reset](#state-and-reset)
- [Getting help](#getting-help)

---

## Install and startup

### `./run.sh` exits immediately naming something missing

**Symptom** — the run stops on its first line:

```
This kit needs a couple of things that aren't here yet:
  • python3 — not on PATH. macOS: brew install python3 ...
```

**Why** — `run.sh` checks its two host prerequisites before it touches anything: `python3` (it is the
`.env` editor and the JSON parser for every API call the setup makes) and a container runtime
(`docker` or `podman` — auto-detected, or pinned with `RUNTIME` in `.env`),
including its `compose` v2 *subcommand* — the standalone `docker-compose` v1 binary does not satisfy
it, and podman needs a compose provider installed alongside it (`podman-compose`). Every
missing item is listed in one pass, so the list is the whole list.

**Fix** — install what it names, per [prerequisites](getting-started/prerequisites.md), and re-run.
`./run.sh --help` is answered before the check, so it keeps working meanwhile.

**Confirm**

```bash
python3 --version && docker compose version
```

An unreachable runtime is only a warning at this stage; it becomes a real error later, at
`compose pull`.

### A port is already in use

**Symptom** — `./run.sh` fails during startup:

```
Error response from daemon: driver failed programming external connectivity on endpoint
duplo-ui: Bind for 0.0.0.0:4210 failed: port is already allocated
```

**Why** — the dev kit's ports are mostly offset from the platform's standard ports so both can run at once,
but a port can still be taken by something else on your machine. The defaults are `STUDIO_PORT=60031`,
`UI_PORT=4210`, `AGENT_PORT=8010`, `MONGO_PORT=27018`, `XTERM_PORT=6061`, `QDRANT_PORT=6333`.

`QDRANT_PORT` is the exception to the offset: 6333 is Qdrant's own default, so a Qdrant you already run
locally will hold it. `compose up -d` is not guarded against this — one clashing port aborts the
whole run — so move it in `.env` before starting.

**Fix** — find what holds the port, then either stop it or move the dev kit:

```bash
lsof -nP -iTCP:4210 -sTCP:LISTEN     # who has it?
```

To move the dev kit, edit the `*_PORT` value in `.env` and re-run `./run.sh`. Do **not** simply delete the
line — an unset `*_PORT` falls back to the *unoffset* platform default (`UI_PORT` becomes 4200, not 4210),
which is more likely to collide, not less.

**Confirm**

```bash
docker compose ps        # every service Up
curl -fsS http://localhost:4210 >/dev/null && echo "UI is answering"
```

### podman-specific

All of these are handled by the scripts; they are listed because you will meet them the moment you run
a `compose` command *by hand* under podman, and the errors do not say what is actually wrong.

| Symptom | Cause | What to do |
| --- | --- | --- |
| `missing services [builder]` | podman-compose does not implicitly enable a service's `profiles` the way `docker compose run` does, and `builder` sits behind the `tools` profile. `COMPOSE_PROFILES=tools` does **not** help — podman-compose ignores that variable. | Name it: `podman compose --profile tools run --rm --no-deps builder …` |
| `invalid reference format` on an image ending in `}` | podman-compose 1.5 stops at the first `}` of a nested `${A:-${B}}` and appends the rest literally. | Already removed from `docker-compose.yml`; don't reintroduce nesting — `tests/test-runtime.sh` checks for it. |
| `compose ps` exits 2 with a usage dump | podman-compose's `ps` has no `--services` or `--status`; its whole grammar is `-q` and `--format`. | The scripts use `runtime_compose_running_services` (in `scripts/_runtime.sh`), which falls back to filtering on the `com.docker.compose.*` labels that both implementations set. |
| An extension bundle in `dist/` is owned by uid 101000 and you cannot delete it | Rootless podman maps *your* uid to container uid 0, so passing a real `--user 1000` lands on an unwritable subuid. | The build scripts pass `0:0` under rootless podman automatically. For an already-broken directory: `podman unshare rm -rf dist`. |
| `rootless netns: kill network process: permission denied` on container teardown | A podman rootless cleanup quirk. Cosmetic — it is printed after the container has already exited, and the exit status is still propagated correctly. | Ignore it. |

`host.docker.internal` works under podman: the `extra_hosts: host-gateway` entry in `docker-compose.yml`
maps it, and podman additionally provides `host.containers.internal` for the same address.

### `./run.sh` hangs on "Waiting for studio" (Apple Silicon)

> `run.sh` catches this before it happens — `runtime_rosetta_check` in `scripts/_runtime.sh` stops the
> run with the fix below. You should only reach this entry if the check could not reach the machine to
> judge it (it stays silent rather than guessing), or on a version of the kit that predates it.

**Symptom** — minutes of dots, then a failure that blames the wrong thing:

```
==> Waiting for studio at http://localhost:60031 ...........................
==> Minting permanent admin API token…
Login failed for you@example.com — check the admin email/password (./run.sh --reset to re-enter).
```

The studio container looks healthy — `podman ps` reports `Up`. Its log does not:

```
at Program.<Main>$(String[] args) in /src/Duplo.ai.studio/Program.cs:line 255
qemu: uncaught target signal 6 (Aborted) - core dumped
```

**Why** — `STUDIO_PLATFORM` is pinning the studio image to amd64 on an arm64 host, so it runs under QEMU
user-mode emulation, which cannot run .NET's JIT/reflection. The process takes `SIGABRT` while
`MapControllers()` walks controller attributes at startup. The crash does not take PID 1 down promptly,
so the container stays `Up`, `/healthz` never answers, and the wait loop burns ~4.5 minutes before
failing on the login step — which has nothing to do with it.

**Fix — remove the pin.** Studio releases publish arm64 alongside amd64, so an unset `STUDIO_PLATFORM`
pulls the native image and there is nothing to emulate:

```bash
grep -n '^STUDIO_PLATFORM=' .env     # if this prints anything, that is the problem
sed -i '' '/^STUDIO_PLATFORM=/d' .env
./run.sh
```

`./run.sh` removes a stale `STUDIO_PLATFORM=linux/amd64` for you on its next run, but only when it can
see you never changed it yourself (`.env.defaults` has to agree). A value you set by hand is always left
alone — so if you pinned it deliberately, the line above is the deliberate way to unpin it.

**If the tag really is amd64-only** — a private or mirrored registry that carries one arch — then
unsetting changes nothing and you do need Rosetta. Check what your tag actually publishes:

```bash
podman manifest inspect "quay.io/duplocloud/backend:$(grep '^STUDIO_TAG=' .env | cut -d= -f2)" \
  | grep architecture
```

With no `arm64` in that list, either use Docker Desktop (it ships Rosetta itself, with nothing to
configure) or give the podman machine an `applehv` provider with Rosetta enabled — `applehv` is the only
provider that supports it, and the provider is fixed when the machine is created, so switching means
recreating the VM.

**Confirm the fix:**

```bash
./run.sh
curl -fsS http://localhost:60031/healthz && echo " studio is answering"
podman logs devkit-duplo-ai-studio-1 2>&1 | grep -c 'uncaught target signal'   # must be 0
```

> **If you have both runtimes installed, check which one you are actually using.** `runtime_detect` in
> `scripts/_runtime.sh` walks `docker podman` and takes the first on `PATH` — presence only, with no
> daemon check — so installing Docker silently takes precedence over podman. A podman machine can be up
> and correctly configured while `./run.sh` uses Docker. Pin it deliberately:
>
> ```bash
> bash -c 'source scripts/_runtime.sh; echo "using: $(runtime_detect)"'   # what it will pick
> echo 'RUNTIME=podman' >> .env                                           # force podman
> ```

### More entries belong here

Image pull failures and `<runtime> login quay.io`, and insufficient memory or disk. Add them as they are
hit — with the verbatim error string.

---

## Licensing

The one rule behind every entry below: DuploCloud issues **exactly one license per email address**, and it
is never re-issued. So nothing here asks you to try a different address, and `run.sh` never throws a license
away — it saves the request id in `.env` and re-fetches. See
[configuration.md § Licensing](configuration.md#licensing) for the variables.

### The run is waiting for a verification link

```
==> Check your email: you@yourcompany.com has to be verified before this run can continue.
    waiting......
```

Expected. Click the link DuploCloud emailed that address and the run continues on its own. If it gives up:

```
  ✖ Timed out after 2 minute(s) waiting for you@yourcompany.com to be verified.
```

Nothing is lost. Click the link whenever it arrives, then re-run `./run.sh` — it resumes from the request id
saved as `LICENSE_TRIAL_UUID` and no second email is sent. Check spam before assuming the email is missing.

### The verification email never arrives (I mistyped my address)

Waiting won't help: the link went to an address you can't read. Re-run with the address you meant.

```
./run.sh --email you@yourcompany.com
==> Admin email changed (was you@yourcomapny.com, now you@yourcompany.com).
    Discarding the pending license request for you@yourcomapny.com — it can only ever verify that address.
==> Verifying your email address you@yourcompany.com…
```

`run.sh` stores the address a request was made for as `LICENSE_REQUEST_EMAIL`, next to the id itself. Give it a
different admin email and the stale id is dropped instead of polled, so a new request goes to the corrected
address. Nothing is given up — the typo'd request never had a license attached, and the one-trial-per-address
rule applies per address, so the address you actually own still has its trial. You don't need
`--reset-license` for this.

A different wording means the server, not you, was the holdup:

```
  ✖ Gave up after 2 minute(s) — https://console.duplocloud.com never answered.
```

That is a reachability problem — proxy, VPN, or an outage. Re-run once you can reach that URL; no email is
involved. (It is `https://console.duplocloud.com` unless you set `LICENSE_API_URL` in `.env` to override it.)

### My address is already registered

```
==> you@yourcompany.com is already registered — recovering your existing license.
```

Also expected, and not an error: a re-clone, a `--reset-license`, or a blanked `Licensing__Token` all land
here. The server emails you a confirmation link, and clicking it releases the **same** license to this dev
kit. Nothing is re-issued and the expiry does not change.

If the link lapses before you click it:

```
  ✖ the confirmation link expired before it was clicked
    Re-run ./run.sh and DuploCloud will email you a fresh link.
```

If you already hold the JWT, skip the round trip entirely with `./run.sh --license <jwt>`.

### The license server rejected my email

Work and personal addresses are both accepted; privacy-relay and disposable domains are not. Re-run with a
different address — `./run.sh --email you@example.com`. A rejected address is not spent, so this is safe to
correct.

### The license is for the wrong address

```
    ⚠ this license was issued to someone@elsewhere.com, not you@yourcompany.com — the studio enforces the license's email claim.
```

A warning, not a failure — but the stack will not authorize. Either sign in as the licensed address
(`Authentication__LocalAdminEmail`) or get a license for the one you are using.

### `Licensing__Token` is not a readable JWT

```
    ⚠ Licensing__Token in .env is not a readable JWT — replace it with ./run.sh --license <jwt>.
```

Usually a paste that picked up quotes or a line break. The token is validated exactly as given, because it is
stored exactly as given: pass the bare three-segment string. If you no longer have it, blank the
`Licensing__Token` line and re-run — the saved ids pull the same license back down.

### The license expired

```
    ⚠ License expired on 2026-09-01 12:00 UTC — contact DuploCloud to renew (it will not be re-issued for this email).
```

`run.sh` warns from seven days out and never blocks on this. Renewal is a conversation with DuploCloud —
see [SUPPORT.md](../SUPPORT.md); re-running the script cannot produce a second license.

### `--reset-license` refused to run

```
  ✖ --reset-license blanks Licensing__Token, and this run can't prompt you to paste it back (--non-interactive was passed).
```

Deliberate: unattended, there would be nobody to click the recovery link. Save the JWT it printed and pass it
back with `--license <jwt>`, or drop `-y` and run from a terminal. If you only meant to wipe the DB, plain
`--reset` keeps the license.

---

## LLM provider

*Not yet documented.* This section covers which provider is actually in use given the
`ANTHROPIC_API_KEY` → gateway → Azure → Bedrock precedence, quota and rate-limit errors, and gateway, Azure and Bedrock
specifics. See [configuration.md](configuration.md#llm-provider) for how the variables resolve today.

---

## Providers: AWS and Kubernetes

Failures wiring a cloud or cluster provider to the agent. The step-by-step setup is
[connect-aws.md](getting-started/connect-aws.md) and
[connect-kubernetes.md](getting-started/connect-kubernetes.md); each page carries the quick fixes for
its own steps. What follows is the ones that need more than a line.

### The credential is rejected the moment the agent uses it

**Symptom** — an AWS-scoped ticket fails immediately, with one of:

```
InvalidClientTokenId: The security token included in the request is invalid
SignatureDoesNotMatch: The request signature we calculated does not match the signature you provided
```

**Why** — these are two different failures that look alike. `InvalidClientTokenId` means the **access
key ID** is wrong, or the key has been deleted or deactivated in IAM. `SignatureDoesNotMatch` means the
ID is fine but the **secret** is wrong — most often a trailing space or a truncated paste, because the
secret is shown exactly once and is usually copied by hand.

**Fix** — re-enter the credential rather than trying to spot the difference by eye. In IAM, confirm the
key still exists and is Active under the `duplocloud-devkit` user's **Security credentials**. If you no
longer have the secret, create a new access key and delete the old one — a secret cannot be recovered.

### The agent authenticates but reports that nothing exists

**Symptom** — the ticket succeeds, and the agent reports no buckets, no instances, no resources at all,
in an account you know is not empty.

**Why** — the credential is valid and the call is working. The scope is pointed at a different region
from the one your resources are in. Most AWS APIs are regional and return an empty set rather than an
error for a region you have never used.

**Fix** — open **Providers** → your provider → **Scope**, and check the **Region**. It must be the
region the resources actually live in. Note that a few services are global — S3 bucket *listing* is,
which is why `list my S3 buckets` can succeed while everything else looks empty.

### Kubernetes: the token works, then stops after about an hour

**Symptom** — EKS-scoped tickets work initially, then begin failing with `Unauthorized`.

**Why** — the token was minted with `kubectl create token`, which issues a **bound** token with a short
lifetime (one hour by default). It is not a durable credential.

**Fix** — create a long-lived ServiceAccount token Secret instead, as
[connect-kubernetes.md](getting-started/connect-kubernetes.md) describes, and replace the credential's
**Token** with the value read out of that Secret.

### Kubernetes: connection refused, or the request times out

**Symptom** — EKS-scoped tickets fail with a connection refused or a timeout against the cluster
endpoint, while `kubectl` works fine from your laptop.

**Why** — the cluster's API endpoint is private. `kubectl` reaches it because your laptop is on the VPN
or inside the VPC; the dev-kit containers are not necessarily on the same network path.

**Fix** — the kit must be able to reach the endpoint from inside its containers. Either put the host on
the VPN and confirm the container can reach it, or use a cluster whose endpoint is public. Confirm with:

```bash
docker compose exec duplo-ai-studio curl -sk -o /dev/null -w '%{http_code}\n' <cluster-endpoint>/version
```

A `401` is success here — it means you reached the API server and it declined the anonymous request.
A hang or a connection error means the endpoint is not reachable.

### Kubernetes: certificate signed by unknown authority

**Symptom** —

```
x509: certificate signed by unknown authority
```

**Why** — the provider's **Base64 Certificate Data** is missing or does not match the cluster.

**Fix** — re-read it from the cluster and paste it in unchanged. The AWS CLI already returns it
base64-encoded, which is the form the field expects, so do not decode it first:

```bash
aws eks describe-cluster --name <your-cluster-name> \
  --query 'cluster.certificateAuthority.data' --output text
```

### A scope you created does not appear when filing a ticket

**Symptom** — the provider, credential, and scope all exist and look right, but the scope is absent from
the **Select Scopes** dropdown on **HelpDesk** → **Add Ticket**, and **Create Ticket** stays disabled.

**Why** — creating a scope does not make it usable. A ticket may only select scopes that have been
**attached to a workspace**. Creating the scope pops up an **Attach Scope to Workspaces** dialog, and
that dialog has a **Skip** button — take Skip, and you are left with a scope that exists, looks
correct on every listing, and cannot be selected anywhere.

**Fix** — re-open the scope and attach it to **extension-dev** from the same dialog. The sidebar's
**Scopes** page lists what the current workspace can already use, so a scope missing from that list is
one that was never attached.

Note that scope is a *required* field on every ticket, so this is not a step you can skip and come back
to — a ticket filed without a scope cannot be submitted at all, and one filed with the wrong scope
cannot be corrected afterwards.

### More entries belong here

`AccessDenied` on every AWS call (the `ReadOnlyAccess` policy did not attach) and the
`system:serviceaccount:kube-system:duplocloud-agent cannot list` RBAC failure. Add them as they are
hit — with the verbatim error string.

---

## Extensions

### The extension build cannot reach the host SDK

**Symptom** — `./scripts/build-extension.sh` fails early:

```
ERROR: could not read the host SDK version from http://localhost:60031/v1/aiservicedesk/extensions/sdk-version
       Response (first 300 chars):
       Check DUPLO_HOST is the AI Helpdesk studio base URL (serving /v1/aiservicedesk), is reachable
       from CI, uses https, and has no trailing path.
       These endpoints require a token (they are no longer anonymous): a 401 here means DUPLO_TOKEN /
       DUPLO_ADMIN_TOKEN is missing or expired.
```

**Why** — extensions compile against the SDK published by the *running* platform, so the studio has to be
up and reachable at the resolved base URL before a build can start. With `DUPLO_TARGET=local` that URL is
`http://localhost:$STUDIO_PORT`; with `remote` it is `DUPLO_HOST`.

**Fix**

- **Local** — confirm the stack is running and the port matches `.env`:

  ```bash
  ./logs.sh --no-follow duplo-ai-studio     # or: <your runtime> compose ps
  grep STUDIO_PORT .env
  ```

  If the studio is not `Up`, start it with `./run.sh` and check `./logs.sh duplo-ai-studio`.
- **Remote** — confirm `DUPLO_HOST` is the studio base URL with **no trailing path**, uses https, and is
  reachable from where the build runs. Confirm `DUPLO_TOKEN` is an Administrator bearer token.

**Confirm**

```bash
curl -fsS -H "Authorization: Bearer $(grep ^DUPLO_ADMIN_TOKEN= .env | cut -d= -f2-)" \
  http://localhost:60031/v1/aiservicedesk/extensions/sdk-version
```

A version string like `{"version":"1.0.6"}` means the build will get past this step. The SDK feed is
**authenticated** — without the header you get a 401, which is not the same problem as the studio being down.
For that, `curl -fsS http://localhost:60031/healthz` answers anonymously.

### The build warns it cannot see the studio, then works anyway

**Symptom** — `./scripts/build-extension.sh` prints a warning, then the build carries on and succeeds:

```
WARNING: no running duplo-ai-studio in this compose project (docker compose scopes services
         per project) … will try the published host port instead:
         http://host.docker.internal:60031
```

**Why** — the build and the stack are on **different container runtimes**. Compose scopes services per
project *per runtime*, so a build running under docker cannot see a studio that was started under podman,
or the reverse. It is easy to end up here because detection is presence-based and docker-first: you may
have started the stack with `RUNTIME=podman ./run.sh` while the build, run without that variable,
auto-detects docker.

**This is usually benign.** The fallback URL reaches the studio through its *published host port* — the
same port your browser uses — so the SDK fetch still succeeds and the bundle builds correctly. Treat it as
noise unless the build actually fails on the SDK step, which is the previous entry.

**Confirm the fallback route is alive** — from inside a container on the build's runtime:

```bash
RT=docker      # the runtime the BUILD uses, not the stack's
IMG=$(grep ^BUILDER_IMAGE= .env | cut -d= -f2-)
PORT=$(grep ^STUDIO_PORT= .env | cut -d= -f2-); PORT=${PORT:-60021}
$RT run --rm --add-host host.docker.internal:host-gateway "$IMG" \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://host.docker.internal:$PORT/v1/aiservicedesk/extensions/sdk-version"
```

**`401` means the route is fine.** The SDK feed is authenticated, so an unauthenticated request from inside
the container is *supposed* to be rejected — reaching a 401 proves the network path works. A connection
error or `000` is the real failure. Do not read the 401 as the problem.

**Silence it** — put both on the same runtime, e.g. `echo 'RUNTIME=podman' >> .env`, so the build and the
stack share a compose project. The builder image is cached per runtime, so the first build after switching
pays a one-time pull.

### The extension's page never loads in the portal

The portal loads extension remotes with Native Federation and reads a `remoteEntry.json`. Check, in
order:

1. `manifest.json`'s `frontend.remote.remoteEntry` ends in `remoteEntry.json` — not the Webpack-era
   `.js` entry, which this host cannot load.
2. `frontend/dist/remoteEntry.json` exists after `npm run build`. If you see `frontend/dist/browser/`
   instead, `angular.json`'s `outputPath` is missing `"browser": ""`.
3. `manifest.json`'s `frontend.remote.remoteName` equals the `name` in `frontend/dist/remoteEntry.json`.
4. No other installed extension uses the same `remoteName` — duplicates alias to whichever loaded first.

All four are checked at once by:

```bash
node scripts/verify-remote-federation.js <extension-dir>
```

### `NullInjectorError` / `NG0201` from a library component

A package with `forRoot()` providers or DI tokens is being bundled privately by the remote instead of
shared with the host. Check your `frontend/federation.config.js` `shared` block against the host's
`duplo-ui/portal/federation.shared.js`: agreement is per entry — every package you share must use the
host's version — but your list stays a **subset** of the host's, never a copy (the host also shares
packages your extension doesn't depend on, e.g. `yaml`, and `lookupVersion()` throws if you copy those in).

There is no standalone dev server. Extension frontends are remotes loaded into the portal, so use the
build → deploy → hot-load loop:

```bash
./scripts/build-extension.sh  extensions/<name>
./scripts/deploy-extension.sh extensions/<name>/dist/extension.zip
```

See [Build your first extension](getting-started/build-your-first-extension.md).

### More entries belong here

Per-language build failures, a deploy that succeeds without the resource type appearing, provisioning
tickets that fire but fail, extensions gone after `stop.sh --wipe`, and a required scope that is not
configured.

Two failures the scripts already explain well when they happen:

- **Naming validation** — `build-extension.sh` prints a `✗` line per violation, then
  `ERROR: extension naming validation failed — fix the ✗ items above (reference/00-naming.md).`
  REST segments must start with `extensions/`, Mongo collections must be prefixed `extension_`, and
  template `Hello`/`hw-` identifiers must be renamed.
- **No credentials resolved** — `No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote)
  in .env.` means `run.sh` has not completed, or you are on `remote` without a token.

---

## State and reset

Which command destroys what is documented once, in
[cli-reference.md](cli-reference.md#what-each-command-destroys). In short: `./stop.sh` keeps volumes,
`./stop.sh --wipe` destroys them, and `./run.sh --reset` destroys them *and* blanks your configured `.env`
values. Your `extensions/` directory is never touched by any of them.

### The admin login fails while minting the token

**Symptom** — `./run.sh` gets as far as the token step, then stops:

```
Login failed for you@example.com — check the admin email/password (./run.sh --reset to re-enter).
```

**Why** — `run.sh` mints a permanent admin API token by logging into the studio with
`Authentication__LocalAdminEmail` and `Authentication__LocalAdminPassword` from `.env`. Those credentials
do not match the account in the database. The usual cause is `.env` being edited, replaced, or re-copied
from `.env.example` after the database was already created — the database keeps the original password.

**Fix** — either put the original credentials back in `.env`, or start over:

```bash
./run.sh --reset
```

> `--reset` destroys the database, every loaded extension, and the file store, and blanks your configured
> `.env` values. Reach for it only when you do not need the current state.

**Confirm** — `run.sh` reaches:

```
    stored DUPLO_ADMIN_TOKEN (never-expiring).
```

and `grep DUPLO_ADMIN_TOKEN .env` shows a non-empty value.

---

## Getting help

Read [SUPPORT.md](../SUPPORT.md) first — it lists exactly what to include so the first reply is useful
rather than a request for more detail.

**Redact `.env` values before pasting anything.** See the warning at the top of this page.

Security vulnerabilities do **not** go in a public issue. Email `ai-reporting@duplocloud.net` — see
[SECURITY.md](../SECURITY.md).
