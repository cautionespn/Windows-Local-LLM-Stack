# llmstack-windows

A single PowerShell script that turns a Windows 11 PC into a private, self-hosted AI server.

It installs inference, a web front-end and private web search, all running locally. Ollama and Open WebUI are Windows services that start at boot with nobody signed in.

```powershell
.\llmstack-windows.ps1 -Recommend   # see what this PC can run
.\llmstack-windows.ps1              # install it (elevated)
```

This is a port of [MacOS-Local-LLM-Stack](https://github.com/cautionespn/MacOS-Local-LLM-Stack) v3.6.1 and a sibling of [Linux-Local-LLM-Stack](https://github.com/cautionespn/Linux-Local-LLM-Stack). The model catalogue, catalogue maintenance and `-SyncModels` behave the same on all three.

---

## Contents

- [What it installs](#what-it-installs)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What has been verified](#what-has-been-verified)
- [Web search and signing in](#web-search-and-signing-in)
- [Modes](#modes)
- [Options](#options)
- [How models are chosen](#how-models-are-chosen)
- [GPUs](#gpus)
- [The model catalogue](#the-model-catalogue)
- [Syncing models](#syncing-models)
- [Benchmarking](#benchmarking)
- [Commands](#commands)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [File layout](#file-layout)
- [Ports and firewall](#ports-and-firewall)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Design notes](#design-notes)
- [Development](#development)
- [Changelog](#changelog)
- [License](#license)

---

## What it installs

| Component | What it does | How it runs |
|---|---|---|
| [Ollama](https://ollama.com) | Runs the models | Windows service `llmstack-ollama`, account `NT SERVICE\llmstack-ollama` |
| [Open WebUI](https://openwebui.com) | Chat interface in the browser | Windows service `llmstack-openwebui`, in a Python virtualenv, account `NT SERVICE\llmstack-openwebui` |
| [SearXNG](https://docs.searxng.org) | Private metasearch for Open WebUI's web search | Container in [Docker Desktop](https://www.docker.com/products/docker-desktop/), or a SearXNG you already run |
| [shawl](https://github.com/mtkennerly/shawl) | Runs Ollama and Open WebUI as services, restarting them on failure | `bin\shawl.exe` (v1.9.0) |
| [uv](https://docs.astral.sh/uv/) | Fetches Python and installs Open WebUI | `bin\uv.exe` |

It also:
- recommends models for the hardware and pulls the best fit;
- adds `llmstatus`, `llmstart`, `llmstop` and `llmupgrade` to the PATH;
- opens Open WebUI's port on Private networks;
- pre-configures Open WebUI's web search to use SearXNG.

## Requirements

- **Windows 11**, x64 or ARM64. Home, Pro, Enterprise and Education all work; Windows 10 and Server are refused.
- **Windows PowerShell 5.1**, which every Windows 11 PC has, or PowerShell 7.
- **An elevated PowerShell** for install, update, uninstall and sync. `-Recommend`, `-Status` and `-Benchmark` don't need one.
- **Internet access** during install.
- **Disk:**
  - 5 to 45 GB for models, under `C:\ProgramData\llmstack`.
  - About 6 GB for Ollama and Open WebUI, under `C:\Program Files\llmstack`.
- **For local web search:** Docker Desktop, which needs WSL 2 and hardware virtualisation. The script offers to install it. See [Web search and signing in](#web-search-and-signing-in).
- **For GPU acceleration:** an NVIDIA or AMD card with its vendor driver installed. See [GPUs](#gpus).

## Quick start

Open **Windows Terminal (Admin)** or **PowerShell (Admin)**, then:

```powershell
# Download the latest release
curl.exe -fLO https://github.com/cautionespn/Windows-Local-LLM-Stack/releases/latest/download/llmstack-windows.ps1

# Downloaded scripts are blocked by default. Either unblock it once...
Unblock-File .\llmstack-windows.ps1
# ...or run it with: powershell -ExecutionPolicy Bypass -File .\llmstack-windows.ps1

# Inspect the machine first. Installs nothing, downloads nothing.
.\llmstack-windows.ps1 -Recommend

# Install. It shows what it found and asks before changing anything.
.\llmstack-windows.ps1
```

When it finishes, open `http://<this-pc>:8080` and create the first account. **The first account created becomes the administrator**, so do it straight away.

## What has been verified

| Path | Status |
|---|---|
| Install, re-run, restart, sync, benchmark and uninstall on **Windows 11 ARM64** | Verified in CI on every push, on GitHub's `windows-11-arm` runner (Windows 11 Enterprise, build 26200), in Windows PowerShell 5.1 |
| The same, plus update, on x64 | Verified in CI on every push. GitHub's x64 Windows runner is Windows **Server** 2025, which shares Windows 11's code base; there is no hosted Windows 11 x64 runner. |
| Hardware detection and sizing (NVIDIA, AMD, Intel, CPU-only) | Unit-tested with Pester against mocked CIM, registry and `nvidia-smi` data only. Not yet run on real GPU hardware. |
| Local SearXNG in Docker Desktop, and installing Docker Desktop | **Not verified in CI.** GitHub's Windows runners cannot run Linux containers. |
| Declining Docker Desktop turns web search off | Verified in CI on both runners, which don't have Docker Desktop |
| Windows PowerShell 5.1 and PowerShell 7 | Both run the unit tests; the end-to-end runs use 5.1 |

If you run it on real GPU hardware, an issue with the output of `-Recommend` and `-Benchmark` is very welcome.

## Web search and signing in

This is the one real limitation, and it is worth understanding before you install.

**What starts when:**
- **Ollama and Open WebUI** are Windows services. They start at boot, before anyone signs in, and keep running when you sign out.
- **SearXNG** can't run natively on Windows. It runs as a Linux container in Docker Desktop, and Docker Desktop is a desktop app: it starts **when someone signs in**. Until then, chat works but web search returns nothing.

**Where SearXNG can come from:**
- **Local (default).** A SearXNG container in Docker Desktop, bound to `127.0.0.1:8888`.
  - If Docker Desktop isn't installed, the script explains what it involves and asks separately, right after you confirm the install; `-Yes` never answers this. Docker Desktop is free for personal use and small businesses under the [Docker Subscription Service Agreement](https://www.docker.com/legal/docker-subscription-service-agreement/). It needs WSL 2 and usually a restart. Re-run the installer afterwards to start SearXNG.
  - **If you answer no,** web search is turned off, in Open WebUI's service settings and in the saved settings, so later runs don't ask again. To turn local search on later, re-run with `-SearxngPort 8888`, which asks about Docker Desktop again; or use `-SearxngUrl`. If Open WebUI has already run, also turn web search off under **Admin Panel → Settings → Web Search**: Open WebUI applies the service settings only on its first start.
  - Keep **Settings → General → Start Docker Desktop when you sign in** turned on. The container restarts with Docker Desktop.
- **Remote.** `-SearxngUrl http://host:port` points Open WebUI at a SearXNG you already run, such as the one from [Linux-Local-LLM-Stack](https://github.com/cautionespn/Linux-Local-LLM-Stack). No Docker is needed, and search works from boot. That instance must allow the `json` format.
- **Off.** `-NoWebSearch` installs no SearXNG.

Web search settings apply on Open WebUI's **first** start. After that, **Admin Panel → Settings → Web Search** is authoritative.

## Modes

| Mode | What it does |
|---|---|
| `-Install` | Install or repair the stack. The default. Idempotent: safe to re-run, and it never overwrites your data or secret key. |
| `-Recommend` | Show detected hardware and the models that fit. Installs nothing. |
| `-Status` | Show the health of every component. Changes nothing. |
| `-SyncModels` | Pull the recommended models you choose and update outdated builds, then offer each other installed model for removal. |
| `-Benchmark` | Measure real tok/s and the CPU/GPU split for each installed pick. |
| `-Update` | Back up Open WebUI data, then update Ollama, Open WebUI and SearXNG and check the catalogue. |
| `-Uninstall` | Guided teardown. Asks before removing each piece. |
| `-CheckModels` | Check every catalogue tag against the Ollama registry and correct the VERIFIED column. |
| `-RefreshCatalog` | Write `models.catalog.proposed` for review; never touches the live catalogue. Add `-Discover` to look for new model families. |
| `-RefreshCatalogApply` | As above, then apply the proposal after a backup and confirmation. |
| `-Start`, `-Stop` | Start or stop the services (what `llmstart` and `llmstop` run). |
| `-Version`, `-Help` | |

## Options

| Option | Effect |
|---|---|
| `-SearxngUrl URL` | Use an existing SearXNG instead of a local container. |
| `-SearxngPort N` | Host port for the local SearXNG. Default 8888. Also switches web search back to local. |
| `-NoWebSearch` | Install no SearXNG and turn web search off. |
| `-WebUIPort N` | Open WebUI's port. Default 8080. |
| `-Model TAG` | Install (or benchmark) this model instead of the recommendation. |
| `-NoModel` | Install the services without downloading a model. |
| `-OllamaVersion X.Y.Z` | Install this Ollama release instead of the latest. |
| `-Yes` | Answer the install's own "go ahead?" question. It never answers removal, uninstall or Docker Desktop questions. |
| `-Discover` | With the refresh modes: scan the Ollama library for new families. |

Settings are stored in `C:\ProgramData\llmstack\config.json`. A later run reads them, and parameters override them. Ports must be 1–65535 and are checked as soon as the script starts, in every mode.

## How models are chosen

Within each role (daily, reasoning, coding, vision, light), the largest catalogue entry that passes three gates wins:

1. **It fits the budget.**
   - With a usable discrete GPU: 75% of that GPU's VRAM. The rest is left for the context and Ollama's own reservation.
   - Without one: 70% of system RAM.
2. **The machine is big enough.** System RAM is at least the entry's `MIN_RAM_GB`.
3. **It will be fast enough.** This gate applies only without a discrete GPU, and only to dense models.
   - Estimated memory bandwidth must drive the model at 8 tok/s or better.
   - Bandwidth is the configured DIMM speed from `Win32_PhysicalMemory` × 8 bytes × 2 channels. When the speed can't be read, it is taken as 51 GB/s (DDR4-3200).
   - Mixture-of-experts models are exempt.

`-Recommend` prints every number it used. When the estimate and reality disagree, [`-Benchmark`](#benchmarking) measures.

## GPUs

| GPU | What the script does |
|---|---|
| **NVIDIA, driver working** | Reads VRAM from `nvidia-smi`. The card sizes the picks. |
| **NVIDIA or AMD, no driver** (Microsoft Basic Display Adapter) | Says so and links the vendor's driver page. The machine is sized as CPU-only until the driver is installed. The script never installs drivers. |
| **AMD, 2 GB of VRAM or more** | Reads VRAM from the display driver's registry entry. The card sizes the picks. On x64 the script also installs Ollama's ROCm libraries. |
| **AMD integrated** (under 2 GB) | Listed, and the machine is sized as CPU-only. |
| **Intel** | Listed, but never sizes the picks. Intel GPUs run through Ollama's Vulkan backend, and integrated ones share system memory. Integrated GPUs also need `OLLAMA_IGPU_ENABLE=1` (see [FAQ](#faq)). |

With several GPUs, the single largest usable one sizes the picks.

The `AdapterRAM` value in Windows' own hardware report is a 32-bit field that tops out at 4 GB, so the script never uses it.

## The model catalogue

Picks come from `C:\ProgramData\llmstack\models.catalog`, a text file you can edit (elevated):

```
# Format: MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. ...
```

- `# Last-Updated:` records when a person last reviewed the file. The script grades staleness from it.
- `# Catalogue-Generation:` is shared with the macOS and Linux scripts: all three ship identical rows for a given generation. `-SyncModels` offers to replace a catalogue from an older generation, with a backup.
- `-CheckModels`, `-RefreshCatalog` and `-RefreshCatalogApply` keep it current.
  - Dead tags are commented out in place.
  - New variants are suggested only as `# REVIEW:` comments.
  - Only a confirmed apply sets `Last-Updated`.
  - Every registry check is fail-soft: offline, nothing changes.

## Syncing models

```powershell
.\llmstack-windows.ps1 -SyncModels
```

1. It offers to replace a catalogue from an older generation, keeping a backup. Replacing it needs an elevated PowerShell; without one, the sync says so and carries on with your catalogue. Nothing else in the sync needs elevation.
2. It lists the current picks and whether each is installed, current or **outdated**. Outdated means an older build than the registry serves; it is compared by manifest digest, with no download.
3. It asks, one model at a time, which missing picks to pull and which outdated ones to update.
4. It checks disk space, then pulls everything chosen.
5. **Only if every pull succeeded**, it offers each installed model that isn't a current pick for removal, one at a time. It flags embedding models Open WebUI may use for documents.

Every prompt defaults to no. If you press Ctrl-C during a download, it says the pull was interrupted and nothing was removed; re-running resumes the download.

## Benchmarking

```powershell
.\llmstack-windows.ps1 -Benchmark
.\llmstack-windows.ps1 -Benchmark -Model qwen3.5:9b
```

Each model is warmed up once, then generates 128 tokens. Tok/s comes from Ollama's own counters, and the CPU/GPU split from `/api/ps`. A model that doesn't fit entirely on the GPU is flagged: it runs many times slower.

## Commands

These are installed to `C:\Program Files\llmstack\bin`, which is on the PATH. They take effect in new terminals.

| Command | Does | Elevated? |
|---|---|---|
| `llmstatus` | Shows the health of each component | no |
| `llmstart` | Starts everything | yes |
| `llmstop` | Stops everything, freeing the memory models hold | yes |
| `llmupgrade` | Runs `-Update` | yes |

## Updating

```powershell
llmupgrade        # or: .\llmstack-windows.ps1 -Update
```

It copies `C:\ProgramData\llmstack\open-webui` to a timestamped backup first. Then it updates:
- Ollama: the latest release, or `-OllamaVersion`
- Open WebUI: in its virtualenv
- the SearXNG image

It restarts the services and checks the catalogue. Run `-SyncModels` afterwards to update model builds.

## Uninstalling

```powershell
.\llmstack-windows.ps1 -Uninstall
```

Each step asks separately, and pressing Enter skips it:
1. the services and the firewall rule
2. the SearXNG container and image
3. `C:\Program Files\llmstack`, with its PATH entries
4. Open WebUI data (asked twice), then any backups
5. models
6. configuration and logs

Docker Desktop and GPU drivers are never touched. Remove Docker Desktop in **Settings → Apps** if nothing else uses it.

## File layout

| Path | Contents |
|---|---|
| `C:\ProgramData\llmstack\config.json` | Installer settings |
| `C:\ProgramData\llmstack\models.catalog` | Model catalogue |
| `C:\ProgramData\llmstack\open-webui\` | Accounts, chats, uploads and `.webui_secret_key`. Administrators, SYSTEM and the service only. |
| `C:\ProgramData\llmstack\ollama\models\` | Downloaded models |
| `C:\ProgramData\llmstack\searxng\settings.yml`, `compose.yaml` | SearXNG |
| `C:\ProgramData\llmstack\logs\` | Service logs from shawl |
| `C:\Program Files\llmstack\ollama\` | Ollama |
| `C:\Program Files\llmstack\openwebui-venv\`, `python\` | Open WebUI and its Python |
| `C:\Program Files\llmstack\bin\` | shawl, uv and the `llm*` commands |
| `C:\Program Files\llmstack\llmstack-windows.ps1` | The installed copy the commands run |

## Ports and firewall

| Service | Listens on | Reachable from |
|---|---|---|
| Ollama | `127.0.0.1:11434` | This PC only |
| Open WebUI | `0.0.0.0:8080` | Private networks (a firewall rule named `llmstack Open WebUI`) |
| SearXNG (local) | `127.0.0.1:8888` | This PC only |

The firewall rule covers the **Private** profile only. On a network Windows treats as Public, other devices can't connect. Either mark the network Private (**Settings → Network & internet**), or widen the rule with `Set-NetFirewallRule -DisplayName 'llmstack Open WebUI' -Profile Private,Domain`.

## Security

- **Each service has its own account.** Ollama and Open WebUI each run under a virtual account (`NT SERVICE\…`) with rights only to their own folders, never as SYSTEM.
- **The secret key is kept private.**
  - Open WebUI's key is generated once and stored in `.webui_secret_key` in its data folder, which ordinary users can't read.
  - It is never passed on the service command line or put in the registry, because any user can read those with `sc qc`.
- **Only Open WebUI is reachable from the network.** Everything else listens on 127.0.0.1.
- **Downloads are checked.**
  - Ollama, shawl and uv come from their official GitHub releases, and each is checked against the SHA-256 digest GitHub publishes.
  - Python comes from uv's managed builds, and packages come from PyPI and PyTorch's CPU index.

## Troubleshooting

**`running scripts is disabled on this system` or `is not digitally signed`.** Run `Unblock-File .\llmstack-windows.ps1`, or start it with `powershell -ExecutionPolicy Bypass -File .\llmstack-windows.ps1`.

**`... needs Administrator`.** Right-click Windows Terminal or PowerShell, choose **Run as administrator**, and run the command there.

**Open WebUI doesn't answer after install.** Its first start downloads an embedding model and can take several minutes. The logs are in `C:\ProgramData\llmstack\logs`.

**Port 11434 is in use.** The Ollama desktop app starts its own server when you sign in. The installer offers to turn off the app's autostart; the app keeps working against the service.

**Web search returns nothing.** Check that Docker Desktop is running (it starts at sign-in), then run `curl.exe "http://127.0.0.1:8888/search?q=test&format=json"`. If SearXNG answers, check the URL in Admin Panel → Settings → Web Search.

**The GPU isn't used.** Run `-Recommend` and read the GPU lines, then `-Benchmark` and read the PROCESSOR column. The Ollama log in `C:\ProgramData\llmstack\logs` shows which GPU it found.

**`The service ... is marked for deletion`.** Close the Services console and Event Viewer, then re-run.

## FAQ

**Why not the Ollama installer?** `OllamaSetup.exe` installs a tray app for the signed-in user. It isn't a service, so nothing runs until someone signs in. This script uses Ollama's portable release and runs it as a service instead.

**Why shawl?**
- Ollama has no service mode of its own, so something has to wrap it.
- NSSM, the usual choice, is unmaintained and flagged by Microsoft Defender.
- A scheduled task needs a stored password and restarts poorly.
- shawl is maintained, small and scriptable.

**Can it use my Intel or AMD integrated GPU?** Ollama can, through Vulkan, with `OLLAMA_IGPU_ENABLE=1`. It's off by default because shared-memory GPUs are often no faster than the CPU. To try it:
1. Re-create the service with that variable. The simplest way is to add `--env OLLAMA_IGPU_ENABLE=1` to the `llmstack-ollama` service with shawl.
2. Compare with `-Benchmark`.

**Does anything leave the PC?** Only two things: web searches, which go through your own SearXNG, and model downloads from Ollama's registry.

## Design notes

- **One script, three platforms.**
  - The catalogue, registry checks, sync and benchmark logic follow the macOS and Linux scripts function for function, so fixes carry across.
  - The rows are identical; CI warns when they drift from the Linux release.
- **Mockable probes.** Every hardware and system probe is a small function, so the Pester tests mock exactly one thing each.
- **Windows PowerShell 5.1 first.**
  - The script is ASCII-only and avoids 7-only syntax.
  - It uses `curl.exe` and `tar.exe`, which ship with Windows, for downloads and extraction. `Invoke-WebRequest` and `Expand-Archive` are orders of magnitude slower on 5.1 for gigabyte files.

## Development

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path tests -Output Detailed          # no admin, no network
Invoke-ScriptAnalyzer -Path .\llmstack-windows.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

`PROMPT.md` is the full specification the script is built to, exported from the maintainer's spec set; don't edit it by hand. `LLMSTACK_DATA_DIR` and `LLMSTACK_PROGRAM_DIR` move the data and program folders. `LLMSTACK_ALLOW_SERVER=1` lets CI install on Windows Server.

## Changelog

### v1.0.1
- **Declining Docker Desktop now turns web search off.** The question is asked right after you confirm the install, before Open WebUI is configured. Previously Open WebUI was already set up for local search, so answering no left web search switched on but broken. The choice is saved, and the message says how to turn local search on later (`-SearxngPort`). On an install where Open WebUI has already started, also turn web search off in its Admin Panel, as the message says. Verified in CI on both runners.
- **Ctrl-C during a model download** (install or `-SyncModels`) says the pull was interrupted and, for a sync, that nothing was removed, as the macOS and Ubuntu installers do.
- **Ports are checked as soon as the script starts, in every mode.** `-SearxngPort 0` and `-WebUIPort 0` were silently ignored, and the catalogue modes didn't check ports at all.
- **`-SyncModels` doesn't need an elevated PowerShell.** Only replacing an outdated catalogue does; without elevation the sync now explains that and carries on, instead of failing after you answered yes. `-Help` said sync needed elevation; it now says when.
- **Tests:** 63 Pester tests (9 new). The Ctrl-C case runs in a child PowerShell, because a real stop would end the test run.
- **`PROMPT.md`** is now the full rebuild specification.

### v1.0.0
First release. It ports MacOS-Local-LLM-Stack v3.6.1 to Windows 11 (x64, ARM64):
- Ollama and Open WebUI as services under their own virtual accounts
- SearXNG in Docker Desktop
- NVIDIA/AMD/Intel/CPU detection with VRAM-based sizing
- `-Benchmark`
- the shared catalogue generation 3.4.0

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
