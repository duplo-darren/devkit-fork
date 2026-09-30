# FAQ

Questions people ask before they have a problem. If something is already broken, start with
[troubleshooting.md](troubleshooting.md).

## Licensing and use

### Can I use this in production?

No. The dev kit and the container images it runs are licensed for **local development only**. See
[TERMS.md](../TERMS.md). For a production license, contact **sales@duplocloud.net**.

### What does the license actually let me do?

Two different things are in this repo:

- **The dev-kit source is Apache-2.0.** Everything DuploCloud authored here — `run.sh`, `scripts/`,
  `samples/`, `docker-compose.yml`, `nginx/`, `.claude/` — you can clone, modify, and redistribute. See
  [LICENSE](../LICENSE).
- **The container images and the vendored UI library are not.** The `quay.io/duplocloud/*` images and the
  `@duplocloud-internal/ng-common-lib` tarball are proprietary, licensed under [TERMS.md](../TERMS.md), and
  may not be modified. You may build extensions against the library and ship what your build bundles into a
  compiled extension; you may not republish, repackage, or modify it.

[NOTICE](../NOTICE) is the full boundary, and Apache-2.0 §4(d) requires you to keep it in any
redistribution.

### Who owns the extensions I write?

You do. DuploCloud claims no rights in anything you write under `extensions/`. See [NOTICE](../NOTICE).

### Can I contribute back?

Improvements to the *framework* are welcome. Your own extensions belong in your repo, not upstream. See
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Running it

### Do I need a DuploCloud account?

No account, but three things: the ability to pull `quay.io/duplocloud/*` (run `docker login quay.io` if the
pull is denied), an LLM key for the agent — Anthropic, Azure AI Foundry, or AWS Bedrock — and an **email
address you can receive mail at**, because the stack is licensed. On an EC2 instance whose IAM role can already invoke Bedrock,
`run.sh` offers a keyless option and you need no LLM key at all.

### Do I need a license key, and where does it come from?

Yes, and `./run.sh` gets it for you. On first run it requests a trial license for the admin email you enter
and writes the JWT into `.env` as `Licensing__Token`; the studio reads it from there. You have to click a
verification link emailed to that address, so use one you can read right now — work or personal is fine, but
privacy-relay and disposable domains are rejected — and expect
one interactive moment on a first install.

The server issues **one license per address** and never a second, so `run.sh` is built never to need one: it
reuses what it has, resumes an interrupted verification, and recovers a license an address already holds by
emailing you a confirmation link. Full behavior in
[configuration.md § Licensing](configuration.md#licensing); symptoms and fixes in
[troubleshooting.md § Licensing](troubleshooting.md#licensing).

### Can I use it against an existing DuploCloud platform?

Yes. Set `DUPLO_TARGET=remote` with `DUPLO_HOST` and `DUPLO_TOKEN` (an Administrator bearer token) in
`.env`. The same scripts then build and deploy against that platform instead of the local stack. See
[configuration.md](configuration.md#build-and-deploy-target).

### Can I run it on Windows, WSL, or an ARM Mac?

- **ARM Macs (Apple Silicon)** — yes, natively. Studio images publish arm64 alongside amd64 and the
  platform is unpinned, so the native image is pulled and nothing is emulated.
- **Windows and WSL** — not verified. Docker Compose v2 and `python3` are the only hard requirements and
  the scripts are POSIX shell, so WSL2 is the likely path, but nobody has confirmed it end to end. If you
  try it, please say how it went.

### What are the prerequisites?

Docker with Compose v2, `python3`, an LLM key, and an email address you can receive mail at (the license
verification link goes there). That is the whole list — building an extension needs nothing extra on your
machine, because the build runs in a container. See [Prerequisites](getting-started/prerequisites.md).

### Do I need .NET and Node installed to build an extension?

No. `./scripts/build-extension.sh` runs the build inside a toolchain container that ships .NET SDK 8 and
Node 22, and starts it for you; the first build pulls that image, or builds it locally from
`build/Dockerfile.builder` if the pull fails. If you already have a toolchain and would rather use it, pass
`--native` or set `DUPLO_BUILD_NATIVE=1`.

### Will this clash with a DuploCloud platform I already run locally?

No. Every port is deliberately offset — 4210 instead of 4200, 60031 instead of 60021, and so on — so both
stacks can run at the same time. See [configuration.md](configuration.md#host-ports).

## Keeping up to date

### How do I take framework updates?

`./scripts/upgrade_dev_kit.sh --version <branch|tag>`. It refreshes framework-owned paths and never touches
`extensions/` or `.env`. See [upgrading.md](upgrading.md).

### Will an upgrade overwrite my extensions?

No. `extensions/` is not in the framework allowlist, and neither is `.env`. Docs you add under `docs/` also
survive — that directory is merged, not mirrored.

## Data and privacy

### Do you see my data?

The stack runs entirely on your machine. Three things leave it:

- **Your LLM provider.** The agent sends prompts to Anthropic, Azure, or Bedrock using the key **you**
  supply, under that provider's terms.
- **Usage metrics**, if you opt in inside the UI — see the next question and [PRIVACY.md](../PRIVACY.md).
- **Image pulls** from `quay.io`.

Your tickets, extensions, and platform data stay in your local Mongo and file store.

### What is collected?

The portal sends product usage metrics to DuploCloud via Mixpanel **only if you opt in inside the UI**. It
is **not anonymous** — the metrics are tied to the email you sign in with, along with your username, roles,
and email domain. What is sent is which features you used and the *names* of objects you created, not
their contents. [PRIVACY.md](../PRIVACY.md) enumerates every event and property.

The dev kit itself has no metrics prompt or setting; the consent lives in the product UI.

### What happens when my trial expires?

`./run.sh` starts warning seven days out and tells you the exact expiry date; after that it prints
`⚠ License expired on <date>` on every run. It never blocks or refuses to start on your behalf — enforcement
is the studio's, from the license's own claims.

Renewal is a conversation with DuploCloud, not a re-run: the license server issues exactly one license per
email address and will not issue a second one for yours. Contact **sales@duplocloud.net** (or see
[SUPPORT.md](../SUPPORT.md)), and if you are handed a new JWT, install it with `./run.sh --license <jwt>`.

## Getting help

### Something is broken — where do I start?

[troubleshooting.md](troubleshooting.md), then [SUPPORT.md](../SUPPORT.md) for what to include when you
ask. Redact your `.env` values before pasting anything.

### I found a security issue.

Do not open a public issue. Email `ai-reporting@duplocloud.net` — see [SECURITY.md](../SECURITY.md).
