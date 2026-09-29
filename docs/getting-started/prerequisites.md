# 0. Prerequisites

**What you'll do:** Confirm you have what this kit needs — a container runtime with Compose v2, Python 3,
LLM access, a verified email address, and five free ports.

**What you need first:** Nothing. This is the first page.

The dev kit runs the whole platform from published images. There is no *language* toolchain to install —
no .NET, no Node: every container it starts, and every extension you later build, is built and run inside
a container. The two things that must exist on the host are a container runtime and `python3`, which the
setup scripts use as their JSON and `.env` editor.

---

## 0.1 A container runtime, with Compose v2

Docker is the default and needs no configuration. **podman** is also supported — Docker Desktop,
Colima, Rancher Desktop, plain Docker Engine and rootless podman all work.
What matters is that the runtime is reachable and that its `compose` subcommand (two words) exists.

1. Check both at once — substitute your runtime for `docker`.

   ```bash
   docker --version && docker compose version
   ```

   You should see:

   ```
   Docker version 29.6.1, build 8900f1d
   Docker Compose version v5.2.0
   ```

   Any Compose `v2.x` or newer is fine. If the second line does not print, you have Compose v1 only and
   need the v2 plugin.

2. If you have more than one runtime installed, or want to pin one, set `RUNTIME` in `.env`:

   ```bash
   RUNTIME=podman        # docker | podman
   ```

   Left unset, the scripts auto-detect, trying `docker` then `podman`, and taking the first one
   **installed** — presence only, with no check that it is running. Installing Docker alongside podman
   therefore moves you onto Docker silently. Confirm which you will get:

   ```bash
   bash -c 'source scripts/_runtime.sh; echo "using: $(runtime_detect)"'
   ```

> **podman:** install the compose provider too — podman shells out to one rather than implementing
> compose itself (`sudo apt-get install podman-compose`, or `brew install podman-compose`). Rootless
> podman needs nothing else; the build scripts handle the user-namespace uid mapping for you, so
> extension bundles come out owned by you rather than by root.
>
> **podman on Apple Silicon** needs three more things before the studio will start, because the studio
> image is amd64 on some tags and runs emulated:
>
> 1. **Create the machine with `--provider applehv`.** Rosetta is an applehv feature. podman 6 defaults
>    to **libkrun** on Apple Silicon, and libkrun has no Rosetta support at all — upstream's
>    `LibKrunStubber.GetRosetta` returns false unconditionally, so a `rosetta = true` under libkrun is
>    read and silently discarded, and `podman machine inspect` keeps reporting `Rosetta: false` however
>    many times you edit the config. **Unlike the rosetta key, the provider is fixed at
>    `podman machine init`** — it is the one setting an existing machine cannot be talked out of, so
>    switching means destroying and recreating the VM.
> 2. **Enable Rosetta.** podman does **not** enable it by default, and without it amd64 binaries fall
>    through to QEMU, which cannot run the studio's .NET runtime. Create
>    `~/.config/containers/containers.conf` with `[machine] provider = "applehv"` and
>    `[machine] rosetta = true` before starting the machine (on applehv the rosetta key is re-read on
>    every `podman machine start`, so *that* key only needs a stop/start, not re-creating). **If that
>    file already exists, edit its `[machine]` section — never append a second `[machine]` table, which
>    is a TOML duplicate-key error that stops podman running at all.**
> 3. **Size the machine.** `podman machine init` defaults to 2048 MiB; `run.sh` hard-fails below
>    6144 MiB, because an undersized VM does not stop the stack coming up — it poisons later extension
>    builds with an OOM kill that reports itself as `exit status 137`.
>
> Which makes the whole first-time sequence:
>
> ```bash
> mkdir -p ~/.config/containers
> printf '[machine]\nprovider = "applehv"\nrosetta = true\n' > ~/.config/containers/containers.conf
> podman machine init --provider applehv --cpus 4 -m 8192 --disk-size 100
> podman machine start
> ```
>
> Verify all three before your first run:
>
> ```bash
> podman machine list --format '{{.Name}} {{.VMType}}'  # want applehv, NOT libkrun
> podman machine ssh 'ls /proc/sys/fs/binfmt_misc/'   # want a `rosetta` entry, no `qemu-x86_64`
> podman machine list                                 # want MEMORY >= 6144 MiB
> ```
>
> If the studio hangs on startup anyway, see
> [troubleshooting](../troubleshooting.md#runsh-hangs-on-waiting-for-studio-apple-silicon).
>
> **Not a runtime:** `runc` (and `crun`, `youki`, `runsc`). Those are low-level OCI runtimes that run an
> already-unpacked bundle by path — they have no images, registries or compose, so they cannot drive
> this kit. They are what the CLIs above use underneath; select one via your CLI, e.g.
> `podman --runtime crun`.

## 0.2 Python 3

`run.sh` and everything under `scripts/` shell out to `python3` to rewrite `.env` safely (tokens and keys
contain characters that break `sed`) and to read JSON out of the platform's API. Only the standard
library is used — no `pip install`, no virtualenv, no version floor beyond "it is called `python3`".

```bash
python3 --version
```

macOS ships one with the Xcode command line tools (`xcode-select --install`) or `brew install python3`;
Debian/Ubuntu, `sudo apt-get install -y python3`; RHEL/Amazon Linux, `sudo dnf install -y python3`.

`./run.sh` checks for this and for your container runtime before it does anything else, and names
whatever is missing.

## 0.3 LLM access

The agent needs a model to call. Pick one before you start — `./run.sh` asks for it and will not finish
without LLM access. On an EC2 instance whose role can invoke Bedrock, `./run.sh` offers that role and no
keys are needed.

| Provider | What you need | Where `./run.sh` puts it |
| --- | --- | --- |
| **Anthropic** (simplest) | An API key, `sk-ant-…` | `ANTHROPIC_API_KEY` |
| **AWS Bedrock** | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ `AWS_SESSION_TOKEN` if they are temporary), and a region with Claude enabled | `AWS_*` |
| **LLM gateway** (OpenRouter, Bifrost, LiteLLM, Snowflake Cortex, …) | The gateway's base URL, its API key / token if it needs one, and the model name as the gateway lists it | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_MODEL` |

Those three are the choices in `./run.sh`'s menu. Azure AI Foundry also works, but is configured by hand in
`.env` rather than offered by the prompt. Precedence when more than one is set is
`ANTHROPIC_API_KEY` → gateway → Azure → Bedrock — see
[configuration.md](../configuration.md#llm-provider).

## 0.4 An email address you can read

Setup requires a **verified email address**. `./run.sh` asks for one, DuploCloud emails you a
verification link, and the run waits for you to click it before carrying on. So:

- **Use an address you can read right now.** The install blocks until that email arrives and you click
  the link.
- **Use a work address.** Personal domains are not accepted — you get
  `Re-run with --email <work address> — personal domains are not accepted.` and a chance to retype.

The same address becomes your portal login on the next page.

## 0.5 Free ports

The kit binds five host ports. They are deliberately offset from the platform's standard ports so this kit
can run *alongside* a full local DuploCloud platform.

| Port | Service |
| --- | --- |
| `4210` | Portal UI — `http://localhost:4210` |
| `60031` | Studio API — `http://localhost:60031` |
| `8010` | `claude-code-agent` |
| `27018` | MongoDB |
| `6061` | In-browser terminal (xterm) |

If something on your machine already holds one of them, you do not need to free it — change the matching
`*_PORT` in `.env` on the next page instead. The variables, and the trap in *blanking* one rather than
changing it, are in [configuration.md](../configuration.md#host-ports).

**Next:** [1. Install and sign in](install.md)
