# DuploCloud Extension Developer Kit

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/duplocloud/devkit?label=release)](https://github.com/duplocloud/devkit/releases)

Run the DuploCloud AI HelpDesk platform on your laptop in containers — then build your own
**Agent** against it. Each Agent you write ships a backend, a UI, and its own provisioning, and
hot-loads into the running platform with no restart.

![The DuploCloud platform running locally, with the New Extension form filled in](docs/images/devkit-new-extension.png)

## Why you'd want it

- **A whole platform, locally.** Six containers, one command.
- **Your own resource types.** Not plugins bolted on the side — they get a REST API, a portal UI, and a
  provisioning workflow, exactly like the built-in types.
- **Hot-load, no restart.** Build, deploy, and the new type is live in the UI seconds later.
- **AI-guided authoring.** `/duplo-extension` in Claude Code scaffolds and builds an Agent from a
  plain-language requirement.

## Quick start

You need **a container runtime with Compose v2** (docker, podman, nerdctl or finch — set `RUNTIME`
in `.env` to pin one, otherwise it is auto-detected), **Python 3**, and access to an LLM. `./run.sh` prompts for
Anthropic, AWS Bedrock, or an Anthropic-compatible LLM gateway (OpenRouter, Bifrost, LiteLLM, …).

```bash
git clone https://github.com/duplocloud/devkit my-agent && cd my-agent
./run.sh
```

First run asks for an admin **email** — use your **work address**, personal domains (gmail.com, …) are not
accepted — and DuploCloud emails you a **verification link**. Click it and the run continues on its own, then
asks for a **password** and an **LLM provider** and brings the stack up, registering your chosen provider's
model as the **System default LLM**. Sign in at
**<http://localhost:4210>**.

That is the platform up. To make it *do* something, pick one:

→ **[Quickstart](docs/quickstart.md)** — connect an AWS account with a read-only access key and ask the
agent real questions about it — "list all S3 buckets" — then build your first Agent: a domain whois lookup
that hot-loads into the platform you just started.

→ **[Getting started](docs/getting-started/README.md)** — the full path, one page at a time: adopting the
repo, connecting AWS and Kubernetes, then building **s3-guard** — an Agent that scans every bucket in a
region against six security rules, charts the violations over time, and fixes the ones you tick.

## What you get

| | |
| --- | --- |
| `docker-compose.yml` | The platform from published images — mongo, qdrant, studio, agent, ui, xterm |
| `.env` / `.env.example` | Image tags, auth, LLM credentials, and the build target |
| `run.sh` `stop.sh` `logs.sh` | Lifecycle |
| `scripts/` | Build, deploy, register, and upgrade |
| `samples/` | Worked reference Agents |
| `.claude/` | The `/duplo-extension` authoring command, its skill, and 20 reference guides |
| `extensions/terraform/` | The real, shipping **Terraform extension** — source, fetched once by `run.sh`, disconnected from git and yours to modify |
| `extensions/<name>/` | **Yours** (subject to our and any third party's rights in the underlying software and technology upon which they are built). The one thing an upgrade never touches |

## Documentation

| Page | What it covers |
| --- | --- |
| [Getting started](docs/getting-started/README.md) | Prerequisites, adopting the repo, and your first extension |
| [Architecture](docs/architecture.md) | How the services fit together and how hot-loading works |
| [Configuration](docs/configuration.md) | Every `.env` variable, its default, and its effect |
| [CLI reference](docs/cli-reference.md) | `run.sh`, `stop.sh`, `logs.sh`, and every script — flags and behavior |
| [Upgrading](docs/upgrading.md) | Taking framework updates without losing your work |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms, causes, and fixes |
| [FAQ](docs/faq.md) | Licensing, data, and platform support |

The full [documentation index](docs/README.md) has everything, including the extension-authoring reference
guides.

## License and use

- **The dev-kit source is open source.** Everything DuploCloud authored here — `run.sh`,
  `scripts/`, `samples/`, `docker-compose.yml`, `nginx/`, `.claude/` — is
  [Apache-2.0](LICENSE). Clone it, modify it, redistribute it. That's the point.
- **The container images are not.** The `quay.io/duplocloud/*` images this kit runs are
  proprietary, licensed separately under [TERMS.md](TERMS.md), and **may not be modified**.
- **The vendored UI library is not, either.** The tarball every sample installs from the repo-root
  `packages/` is the compiled DuploCloud platform UI library
  (`@duplocloud-internal/ng-common-lib`) — proprietary DuploCloud IP, **not open source**,
  and **not covered by the Apache License** despite living under `samples/`. You may build
  your Agents against it and ship the parts your build bundles into a compiled
  Agents; you may not republish, repackage, or modify it. See [TERMS.md](TERMS.md)
  and the `NOTICE` beside each tarball.
- **This kit is for local development only.** As more fully described in the
  [TERMS](TERMS.md), the closed source materials are provided for non-production use only.
- **Going to production?** Contact **sales@duplocloud.net** for a production license.
- **Your Agents are yours.** DuploCloud claims no rights in anything you write under
  `extensions/`. See [NOTICE](NOTICE) for the full breakdown.

## Policies

| Document | What it covers |
| --- | --- |
| [LICENSE](LICENSE) | **Apache-2.0** — the dev-kit source DuploCloud authored (`run.sh`, `scripts/`, `samples/`, `docker-compose.yml`, `nginx/`, `.claude/`). Use, modify, and redistribute freely. Does **not** cover the vendored library tarballs under `packages/` or `**/frontend/vendor/`. |
| [NOTICE](NOTICE) | The boundary: what Apache-2.0 covers, what it doesn't (the container images and the vendored UI library), and the third-party images. Apache-2.0 §4(d) requires you to keep it in any redistribution. |
| [TERMS.md](TERMS.md) | The proprietary pieces that are *not* Apache-licensed: the **`quay.io/duplocloud/*` container images** (local development only, **no modification**, production requires a separate license) and the **vendored `@duplocloud-internal/ng-common-lib` tarball** (build against it and ship what your build bundles — nothing else). Also confirms you own your extensions. |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability. **Email `ai-reporting@duplocloud.net` — don't open a public issue.** |
| [PRIVACY.md](PRIVACY.md) | The usage metrics the UI sends if you opt in, tied to your sign-in email — what is collected and what is not. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PRs improving the *framework* are welcome. Your own extensions stay in your repo and don't belong upstream. |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 — the behaviour expected in issues and pull requests here, and what happens when it isn't met. Report a problem to `ai-reporting@duplocloud.net`. |
| [SUPPORT.md](SUPPORT.md) | Where to get help and what to expect: **GitHub Issues, best effort, no SLA.** Also what belongs somewhere else. |

See [License and use](#license-and-use) above for the short version, or
**sales@duplocloud.net** for a production license.
