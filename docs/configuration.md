# Configuration

Everything the dev kit reads comes from `.env` in the repo root. Copy it from `.env.example` once
(`cp .env.example .env`); `./run.sh` fills in most of the rest on first run.

> **🔒 `.env` holds live secrets.** An LLM API key, your admin password, and a never-expiring admin API
> token. It is gitignored and must never be committed or pasted into an issue. See
> [SUPPORT.md](../SUPPORT.md) before sharing any output.

- [How `.env` is maintained](#how-env-is-maintained)
- [Container runtime](#container-runtime)
- [Licensing](#licensing)
- [Image tags](#image-tags)
- [Host ports](#host-ports)
- [Knowledge Base](#knowledge-base)
- [Build and deploy target](#build-and-deploy-target)
- [Authentication and platform](#authentication-and-platform)
- [LLM provider](#llm-provider)
- [Created by `run.sh`](#created-by-runsh)

## How `.env` is maintained

You normally do not hand-edit most of this file. `./run.sh` prompts for the email, password, and LLM
provider on first run and writes the rest.

Framework-shipped defaults — the image tags, the studio platform, and the license server URL — live in
`.env.example` and change when you upgrade the dev kit. On every run, `run.sh` adopts a changed default into
your `.env` **only if you have not diverged from the previously-applied default**. A tag you pinned is always
kept. The mechanism is described in [upgrading.md](upgrading.md#how-defaults-are-adopted).

## Container runtime

| Variable | Default | Effect |
| --- | --- | --- |
| `RUNTIME` | *unset* — auto-detect | Which container CLI every script drives. Accepts `docker` or `podman`. |

Docker is the default and needs no configuration. Left unset, the scripts auto-detect by walking the
supported CLIs in order and taking the first one found.

Two things about that detection are worth knowing, because both have cost people time:

- **It tests presence only — there is no daemon check.** A CLI that is installed but not running still
  wins the detection. This is deliberate (`scripts/_runtime.sh`): conflating "installed" with "working"
  would make an unstarted Docker Desktop silently fall through to another runtime, and a build would
  then run somewhere you did not intend.
- **Order is precedence.** Installing Docker alongside an existing podman silently moves you onto Docker.
  A correctly configured podman machine can be up and idle while `./run.sh` uses Docker instead.

Check which one you will actually get, and pin it if you care:

```bash
bash -c 'source scripts/_runtime.sh; echo "using: $(runtime_detect)"'
```

```bash
RUNTIME=podman        # docker | podman
```

An explicitly requested runtime that turns out to be unusable is a **hard error**, not a fallback —
silently building with something other than what you asked for is never right. Auto-detection finding
nothing may still fall back to a native toolchain build.

`RUNTIME` does not select a *low-level* OCI runtime. `runc`, `crun`, `youki` and `runsc` are not valid
values — they run an already-unpacked bundle by path and have no images, registries or compose. Choose
one through your CLI instead (`podman --runtime crun`).

See [prerequisites](getting-started/prerequisites.md#01-a-container-runtime-with-compose-v2) for
install-time requirements, including the podman-specific setup on Apple Silicon.

## Licensing

The dev kit is licensed, and the studio will not serve without a license. `run.sh` handles this on first
run: it requests a **trial license** for your admin email (the company is derived from the address's domain),
DuploCloud emails that address a verification link, and the run waits up to 2 minutes for you to click it
before picking the license up and writing it to `Licensing__Token`.

Use an address you can receive mail at — work or personal is fine, but the license server rejects
privacy-relay and disposable domains — and note that it issues exactly
**one license per email address**. There is no second trial for the same address, so `run.sh` is built to
never need one: a license it already has is reused, an interrupted verification resumes, and an address the
server already knows is **recovered** (the server emails a confirmation link that releases the same license
to this dev kit) rather than re-requested.

The license server itself is not a `.env` key. `run.sh` and the studio each default to
`https://console.duplocloud.com` on their own, so `.env.example` ships neither `LICENSE_API_URL` nor
`Licensing__ConsoleUrl`. Add `LICENSE_API_URL` to `.env` by hand if DuploCloud tells you to point somewhere
else — nothing writes or adopts that key, so your value stays put.

| Variable | Default in `.env.example` | Effect |
| --- | --- | --- |
| `Licensing__Token` | *(blank — `run.sh` fetches it)* | The license JWT, read by the studio as `Licensing:Token`. Blanking just this line is safe: the next run pulls the same license back down using the ids below. |
| `LICENSE_TRIAL_UUID` | *(blank)* | The id of the trial request made for your address. `run.sh` polls it for the license and keeps it afterwards as the handle for re-fetching that same license. |
| `LICENSE_RECOVERY_UUID` | *(blank)* | Set when your address already had a license and `run.sh` recovered it: the id of that recovery. A link you click after the script stops waiting still lands, because a later run resumes from this id. |
| `LICENSE_REQUEST_EMAIL` | *(blank)* | The address the two ids above were requested for. Give `run.sh` a different admin email and it discards those ids rather than polling them — an id can only ever verify the one address, so this is how a mistyped email is recovered from. |

Both `run.sh --reset` and `./stop.sh --wipe` leave the license alone — it is not stack state. Only
`--reset-license` clears it, and it prints the JWT to stderr first because the server will not re-issue it.

If you already hold a license JWT, skip the whole flow with `./run.sh --license <jwt>`. Pass the bare token,
with no surrounding quotes or line breaks: it is validated exactly as given, because it is stored exactly as
given.

## Image tags

Pin the published images the stack runs.

| Variable | Default in `.env.example` | Effect |
| --- | --- | --- |
| `STUDIO_TAG` | `branch-refs-pull-548-merge-663a7586` | The AI HelpDesk studio image (the platform API). Format is `branch-<sanitized-branch>-<short-sha>`. Pinned to a build that enforces `Licensing:Token` — do not roll it back to a pre-licensing tag. |
| `AGENT_TAG` | `main-d27e511` | The `claude-code-agent` image that executes provisioning tickets. A `main` build — it carries no extension-specific changes. |
| `UI_TAG` | `2a949c536be71efd4501dd60ca6fdda4f7b4676a` | The Angular portal image. A `duplo-ui` git SHA, pinned to a build that renders the license state. |
| `XTERM_TAG` | `main-d323e0b` | The in-browser terminal image. |
| `STUDIO_PLATFORM` | *(unset)* | Platform override for the studio image. Leave unset: releases publish amd64 and arm64, so the native image resolves from the manifest. Set it only to force one arch against a single-arch registry — on Apple Silicon that then needs Rosetta. |

`STUDIO_TAG` and `UI_TAG` are required — `run.sh` exits if either is empty:

```
  .env: STUDIO_TAG is not set (pass --studio-tag or set in .env).
```

All three application tags can also be set per run with `--studio-tag`, `--ui-tag`, and `--agent-tag`.
Doing so pins them: they stop tracking `.env.example`.

## Host ports

Offset from the platform's standard ports (60021 / 4200 / 8000 / 27017 / 6060) so this dev kit can run
**alongside** a local DuploCloud platform stack without clashing.

| Variable | Default | Service |
| --- | --- | --- |
| `STUDIO_PORT` | `60031` | Studio API — `http://localhost:60031` |
| `UI_PORT` | `4210` | Portal UI — `http://localhost:4210` |
| `AGENT_PORT` | `8010` | `claude-code-agent` |
| `MONGO_PORT` | `27018` | MongoDB |
| `XTERM_PORT` | `6061` | In-browser terminal |

Change any of these if they still collide with something on your machine, then re-run `./run.sh`.

> **Keep them set.** `docker-compose.yml` and `run.sh` fall back to the *unoffset* platform defaults when a
> `*_PORT` is unset — for example `UI_PORT` falls back to 4200, not 4210. Blanking a port does not mean
> "use the dev-kit default"; it means "use the platform default". If a port is in use, see
> [troubleshooting.md](troubleshooting.md#a-port-is-already-in-use).

## Knowledge Base

A Qdrant vector database runs alongside the rest of the stack, always on, and `run.sh` registers it with
the platform as the `devkit-docs` Knowledge Base — see [architecture.md](architecture.md#the-stack).

| Variable | Default | Effect |
| --- | --- | --- |
| `QDRANT_PORT` | `6333` | Host port for the Qdrant dashboard and REST API — `http://localhost:6333`, published on loopback only. Unlike the ports above this is Qdrant's own default rather than an offset one, so change it if something on your machine already holds 6333. The studio never uses it: in-network it reaches Qdrant at `http://qdrant:6333`. |
| `QDRANT_API_KEY` | `devkit-local-qdrant` | Qdrant's master key. Fixed, and deliberately **not** a secret — Qdrant is reachable only from the compose network and from loopback on this host. `docker-compose.yml` and `scripts/register-qdrant.sh` read this same value, so a first run cannot start the container and the provider record out of step. They can still drift afterwards — see below. |

If you are going to change the key, change it before the first run. `register-qdrant.sh` copies it into the
`local-qdrant` provider record at the moment it creates that record; a later run against a provider that
already exists does not rewrite the credential. Change the key after that first run and the two no longer
match: the container rejects the stored credential, every Qdrant call the studio makes comes back 401, and
the collection retries until it lands in **Failed**. Recovering means putting the old key back, or deleting
the `local-qdrant` provider (with `QDRANT_PROVIDER_ID` in `.env`) and re-running the script.

Uploading documents into the Knowledge Base needs AWS Bedrock, whatever LLM provider the rest of the stack
runs on. The embedding model the studio seeds is Bedrock's `cohere.embed-v4` and the agent ingests with no
other provider, so ingestion needs Bedrock credentials that can invoke that model. `run.sh` registers the
Knowledge Base either way — on the direct-Anthropic path the `devkit-docs` collection still provisions to
Ready and can be browsed from the UI, but each document upload fails.

## Build and deploy target

Where `/duplo-extension` and everything in `scripts/` builds and deploys to. Resolved by
`scripts/_target.sh`.

| Variable | Default | Effect |
| --- | --- | --- |
| `DUPLO_TARGET` | `local` | `local` uses this dev-kit stack at `localhost:$STUDIO_PORT`, authenticated with `DUPLO_ADMIN_TOKEN`. `remote` targets an existing DuploCloud platform. |
| `DUPLO_HOST` | *(empty)* | **Remote only, required.** The AI HelpDesk studio base URL — the host serving `/v1/aiservicedesk`. Use https, with no trailing path. |
| `DUPLO_TOKEN` | *(empty)* | **Remote only, required.** An Administrator bearer token for that platform. |
| `DUPLO_WORKSPACE_ID` | *(empty)* | Remote only. The workspace to author against. If blank, `/duplo-extension` lists the remote's workspaces and asks. |

With `DUPLO_TARGET=remote`, a missing value fails fast:

```
DUPLO_TARGET=remote but DUPLO_HOST is unset in .env.
DUPLO_TARGET=remote but DUPLO_TOKEN is unset in .env.
```

Real environment variables win over the file, so CI can supply `DUPLO_HOST` and `DUPLO_TOKEN` as secrets
with no `.env` present at all. `DUPLO_ENV_FILE=<path>` points the scripts at a different env file, and
`DUPLO_BASE` forces the base URL outright.

## Authentication and platform

Managed by `./run.sh` — leave them blank in a fresh `.env` and let it prompt.

| Variable | Effect |
| --- | --- |
| `Authentication__LocalAdminEmail` | Your UI login. Must also appear in `Authentication__SuperUsers` to get the Administrator role — `run.sh` sets both. |
| `Authentication__LocalAdminPassword` | Your UI password. |
| `Authentication__SuperUsers` | Comma-separated superuser emails. |
| `Authentication__FrontendBaseUrl` | Defaults to `http://localhost:$UI_PORT`. |
| `Authentication__JwtSharedSecret` | Generated once (`openssl rand -hex 32`). Regenerated only on `--reset`. |
| `Encryption__MasterKey` | Generated once (`openssl rand -base64 96`). Regenerated only on `--reset`. |
| `AIStudio__IsMasterDisabled` | `true`. Required for standalone operation with no DuploCloud master. |
| `AIStudio__DevKitMode` | `true`. Dev-kit only: exposes the per-extension **Clean Database** admin action, which drops one extension's data collections. |

## LLM provider

`run.sh` sets these from your `--model` choice. Precedence in the agent is `ANTHROPIC_API_KEY` → gateway
(`ANTHROPIC_BASE_URL` with the key **empty**) → Azure → `CLAUDE_CODE_OAUTH_TOKEN` → Bedrock.

Subscription auth sits next-to-last on purpose: a token exported in someone's shell must never displace a
provider that was configured deliberately. The cost of that ordering is that the `subscription` arm has to
blank `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL`, or either would win the chain and the token would never
be read.

| Variable | Effect |
| --- | --- |
| `DEVKIT_MODEL` | `anthropic`, `bedrock`, `gateway`, `bedrock-instance-role`, or `subscription`. Chooses which credential block below is used. |
| `CLAUDE_MODEL` | The model id the agent calls, and the System default in the ticket LLM picker. `claude-sonnet-5` for Anthropic; `us.anthropic.claude-sonnet-5` for either Bedrock mode; for `gateway`, whatever the gateway calls it (OpenRouter: `anthropic/claude-sonnet-5`); for `subscription`, a first-party id the Claude CLI accepts. Not interchangeable — the direct Anthropic API rejects the `us.*` prefix and Bedrock requires it. |
| `CLAUDE_EXTRA_MODELS` | Comma-separated extra model ids registered alongside `CLAUDE_MODEL` so they show in the picker. `claude-opus-5` for Anthropic and `subscription` (both call the first-party API with bare ids), `us.anthropic.claude-opus-5` for Bedrock, blank for `gateway` (a gateway names models its own way, so only the id you supplied is registered). Registration-only; the agent runs on `CLAUDE_MODEL`. |
| `ANTHROPIC_API_KEY` | Direct Anthropic API key. Blanked by `gateway`: key **and** URL together mean "proxy in front of the real Anthropic API", a different agent code path that would send the gateway's token nowhere useful. |
| `CLAUDE_CODE_OAUTH_TOKEN` | `subscription`: a long-lived Claude Code token from `claude setup-token`, run on your own machine (it needs a browser). Not the short-lived credential in your OS keychain, and not an `sk-ant-api…` API key — those are three different auth schemes to the Claude CLI. Runs the agent on your personal Claude Code subscription, so usage counts against your own limits and every ticket authenticates as you: local development only, never a shared stack. Ticket titles are not generated on this path, since the title LLM is Bedrock-only. |
| `ANTHROPIC_BASE_URL` | `gateway`: base URL of any Anthropic-compatible endpoint — OpenRouter, Bifrost, LiteLLM, Snowflake Cortex. The gateway holds the real provider credentials; Bedrock is never enabled on this path. |
| `ANTHROPIC_AUTH_TOKEN` | `gateway`: bearer token / API key the gateway expects. Blank for an unauthenticated gateway (a local Bifrost, say). |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `gateway` only — `run.sh` sets **262144** when you pick it. Declares the model's real context window. A gateway usually serves model ids the Claude CLI doesn't recognise, and an unrecognised id has no known window, so long sessions fail with a 400 instead of compacting. Override with `--gateway-max-context-tokens`, or edit `.env` (re-runs keep whatever is there). Not set by any other provider — those name models the CLI already knows. |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `gateway` only — `run.sh` sets **200000** when you pick it. The threshold at which a session compacts; keep it below `CLAUDE_CODE_MAX_CONTEXT_TOKENS`. Override with `--gateway-compact-window`. |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | `gateway`, optional and **not** set by default. `1` is required for Snowflake Cortex, which rejects Claude Code's experimental beta headers with `400 invalid beta flag`. OpenRouter, Bifrost and LiteLLM strip those headers themselves and don't need it. |
| `AWS_REGION` | Bedrock region (default `us-west-2`). Set to `us-east-1` even on an Anthropic setup — the agent's title LLM is Bedrock-only, and a valid region stops its client crash-looping on a malformed endpoint. With no AWS credentials the title call simply no-ops and titles are not generated. Under `bedrock-instance-role` this is the **only** AWS value stored, and blanking it forces a re-probe on the next run. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Bedrock credentials. Left blank under `bedrock-instance-role`, deliberately: empty-but-present values do not short-circuit the agent's credential chain, so it falls through to IMDS and picks up the instance role. |
| `AZURE_BASE_URL`, `AZURE_API_KEY`, `AZURE_CLIENT_ID` | Azure AI Foundry, if you use it instead. |

Switching provider does **not** clear the previous provider's credentials — only `./run.sh --reset` does.
Because the precedence above is fixed, a leftover `ANTHROPIC_API_KEY` or `ANTHROPIC_BASE_URL` silently wins
over Bedrock; choosing `bedrock` warns when it finds either still set, and `anthropic` warns about a leftover
`ANTHROPIC_BASE_URL` (your key would be sent there instead of to api.anthropic.com). Two arms do blank
values, and there it is load-bearing rather than hygiene: `bedrock-instance-role` blanks the static AWS keys,
`ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` (anything left in those wins the chain and the instance role
would never be consulted), and `gateway` blanks `ANTHROPIC_API_KEY` (see the table).

`run.sh` also runs `scripts/register-llm.sh` on every provider. The studio ships no LLM model records of
its own, so on a fresh DB the ticket LLM picker has nothing to offer; this registers whatever `CLAUDE_MODEL`
resolved to and makes it the sole System default.

### Bedrock via the EC2 instance role

On an EC2 host, `run.sh` offers a third, keyless provider when it can prove the instance role works.
`scripts/detect-bedrock.sh` makes a real 1-token Converse call against `CLAUDE_MODEL` — so success means
invoke permission on the exact model the agent will call, not just "some" Bedrock access — and separately
checks that a container can reach IMDS.

The probe needs only `python3` and `curl` — SigV4 is signed with the standard library, so no AWS CLI or
boto3 is required. The container check uses `busybox:1.36`, pulling it if it is not local yet (it runs before
`docker compose pull`, so on a fresh instance it usually isn't).

The container check reports three distinct outcomes, and only one of them withholds the option:

| `CONTAINER_IMDS` | Meaning | Effect |
| --- | --- | --- |
| `ok` | A container reached IMDS. | Offered normally. |
| `blocked` | The test ran and failed — the IMDSv2 PUT-response hop limit of 1. | **Withheld.** The stack would start and then fail on every turn. |
| `unknown:<why>` | The test could not run: Docker not installed, daemon unreachable, or `busybox:1.36` unobtainable. | Offered, flagged unverified. |

The distinction matters: an unverifiable check is not evidence of a problem, and treating it as one would hide
a working keyless option behind advice to raise a hop limit that was never the cause. When it really is the
hop limit, raise it with:

```bash
aws ec2 modify-instance-metadata-options --instance-id <id> --http-put-response-hop-limit 2
```

At the interactive prompt a failed probe is non-fatal — it explains why and falls back to the key-based
options. Passing `--model bedrock-instance-role` directly is fatal on failure, since you asked for it —
except for `unknown:<why>`, which warns and proceeds.

## Created by `run.sh`

Written on first run. You should not need to set these by hand.

| Variable | Effect |
| --- | --- |
| `DUPLO_ADMIN_TOKEN` | A never-expiring admin API token, minted by logging in as the admin user. Every script uses it when `DUPLO_TARGET=local`. |
| `EXTENSION_DEV_WORKSPACE_ID` | The auto-created `extension-dev` workspace. |
| `EXTENSION_DEV_PERMSET_ID` | The `extension-dev-access` permission set granting that workspace. |
| `EXTENSION_DEV_PERMSETGROUP_ID` | The `extension-dev-group` assigning your admin user to that permission set. |
| `QDRANT_PROVIDER_ID`, `QDRANT_SCOPE_ID`, `QDRANT_COLLECTION_ID` | The `local-qdrant` provider, the `qdrant` scope over it, and the `devkit-docs` collection, all written by `scripts/register-qdrant.sh`. Cleared by `--reset` with the rest of the stack state, because the records they name go with the database. |

The permission set and group exist because the UI's accessible-workspace list is permission-set based with
no superuser bypass. Without them, login lands on `/app/auth/no-tenant-access` even though the admin token
works against the API.

## Usage metrics

The portal UI asks for consent to send product usage metrics to DuploCloud via Mixpanel. That choice is
made in the UI, not by `run.sh` — there is no dev-kit prompt, flag, or `.env` variable for it, and
`nginx/default.conf` serves the published UI bundle unmodified. [PRIVACY.md](../PRIVACY.md) lists exactly
what is and is not collected.

### `.env.defaults`

A gitignored bookkeeping file, rewritten by `run.sh` on every run. It records the framework defaults last
applied so `run.sh` can distinguish "you changed this" from "the default changed". It is not configuration
— see [upgrading.md](upgrading.md#how-defaults-are-adopted).
