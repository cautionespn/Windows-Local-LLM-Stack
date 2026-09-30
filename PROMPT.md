# Prompt: local LLM stack installer for Windows 11

This is a port of [MacOS-Local-LLM-Stack](https://github.com/cautionespn/MacOS-Local-LLM-Stack) (v3.6.1) and a sibling of [Linux-Local-LLM-Stack](https://github.com/cautionespn/Linux-Local-LLM-Stack) (v1.0.0).

The sections are numbered so any one can be amended without rewriting the rest. Add new requirements under the matching section or under §16. Where this spec is silent, the Ubuntu spec's reasoning applies, and after that the macOS spec's.

---

## 1. Objective

The deliverables are:
- a single, shareable PowerShell script that provisions a private, self-hosted LLM stack on Windows 11;
- a GitHub-style `README.md`;
- GitHub Actions workflows that lint the script, unit-test it, and **really install** the stack on a GitHub-hosted Windows runner.

## 2. Target environment

- **Windows 11, amd64 and arm64.**
  - Refuse other Windows versions in preflight: build < 22000, or a server SKU (ProductType ≠ 1).
  - For CI only, the environment variable `LLMSTACK_ALLOW_SERVER=1` accepts Windows Server 2022 or later.
- **PowerShell.**
  - Windows PowerShell **5.1** is the baseline. It is what every Windows 11 machine has.
  - It must also run unchanged on PowerShell 7.4+.
  - That rules out syntax 5.1 doesn't have: `??`, `?:`, `&&`/`||` pipeline chains, `ForEach-Object -Parallel`, and `-SkipHttpErrorCheck`/`-StatusCodeVariable`.
- **ASCII only.**
  - Windows PowerShell 5.1 reads a script without a BOM as the ANSI code page, so any non-ASCII character corrupts it.
  - CI enforces this.
- **Elevation.**
  - Run from an elevated PowerShell. Install, update, uninstall and sync need Administrator.
  - `-Recommend`, `-Status`, `-Benchmark` and `-Help` do not.
  - Never self-elevate: a new elevated window loses the output. Say how to open an elevated prompt instead.
- **How it is run:**
  - `powershell -ExecutionPolicy Bypass -File .\llmstack-windows.ps1`
  - or `Unblock-File` first. The README explains both.
- Nothing is specific to the author's network, user names or drive letters beyond `%ProgramFiles%` and `%ProgramData%`.

## 3. Deliverables

1. `llmstack-windows.ps1`: one file. The installer has no companion scripts.
2. `README.md`: GitHub conventions.
3. `tests/llmstack.Tests.ps1`: Pester 6 unit tests with every system call mocked.
4. `.github/workflows/ci.yml`: lint, unit tests on 5.1 and 7, and end-to-end runs (§15).
5. `.github/workflows/release-asset.yml`: attach the script to each published release.
   - Refuse when the tag and `$ScriptVersion` differ.
   - The Quick start downloads `releases/latest/download/llmstack-windows.ps1`.
6. `PSScriptAnalyzerSettings.psd1`: the only lint configuration. Exclude only rules that actually fire, each with a reason.
7. `LICENSE`: GNU GPL v3. The script header and README say so.

## 4. Stack

| Component | Purpose | How it runs |
|---|---|---|
| Ollama | inference | Windows service `llmstack-ollama`, wrapped by shawl, virtual account `NT SERVICE\llmstack-ollama` |
| Open WebUI | web front-end | uv-managed Python venv, service `llmstack-openwebui` via shawl, virtual account `NT SERVICE\llmstack-openwebui` |
| SearXNG | private web search | container in **Docker Desktop**, or a remote instance, or off |
| shawl | service wrapper | `shawl.exe` pinned release from GitHub, in `%ProgramFiles%\llmstack\bin` |
| uv | Python and packages | pinned-latest release zip from GitHub, in `%ProgramFiles%\llmstack\bin` |

Why these choices (research, 2026-09-30):

**Ollama has no service mode on Windows.**
- The Windows installer (`OllamaSetup.exe`) is a per-user tray app that starts at login.
- The portable `ollama-windows-<arch>.zip` is the documented basis for running it as a service. Ollama's docs point at a service wrapper.

**Service wrapper: shawl v1.9.0** (2026-05-03, `mtkennerly/shawl`, winget `mtkennerly.shawl`).
- It is maintained and small, with a CLI only.
- It takes `--env`, `--cwd`, `--restart`, `--log-dir` and `--stop-timeout`, and `--kill-process-tree` so child processes stop with the service.
- Alternatives rejected:
  - NSSM is unmaintained, and Defender flags it as a PUA.
  - Servy v10.1 is maintained but heavier (GUI and extra features).
  - A scheduled task needs a stored password and `ExecutionTimeLimit PT0S`, and it restarts poorly after a failure.
- Chris chose shawl.

**SearXNG cannot run natively on Windows.**
- WSL cannot start from Session 0 (WSL#9231).
- Docker Desktop runs only after a user logs in.
- A Hyper-V VM (`Set-VM -AutomaticStartAction Start`) would start at boot, but needs Pro/Enterprise/Education and is heavy to build.
- **Chris chose Docker Desktop.** The limitation is stated plainly: web search works only after someone logs in. Ollama and Open WebUI start at boot regardless.

**Open WebUI** supports Python 3.11–3.12 only. uv fetches a managed 3.11 and never touches any system Python. Install PyTorch's CPU build first (open-webui#29490).

**winget is not dependable** on CI runners, and it is absent on some machines. The script downloads pinned GitHub release assets directly and verifies each against the SHA-256 digest GitHub publishes for the asset.

## 5. Ollama

- **Download.**
  - Latest: `https://github.com/ollama/ollama/releases/latest/download/ollama-windows-<arch>.zip`, where `<arch>` is `amd64` or `arm64`.
  - A pinned version: `.../releases/download/v<ver>/...`.
  - Extract to `%ProgramFiles%\llmstack\ollama`.
  - When an AMD GPU is present on amd64, also extract `ollama-windows-amd64-rocm.zip` over the same folder.
  - Use `curl.exe` (shipped with Windows) for downloads, so large files show progress. `Invoke-WebRequest` on 5.1 is slow and buffers in memory.
- **Service.**
  - Create it with shawl: `shawl add --name llmstack-ollama --restart --stop-timeout 10000 --kill-process-tree --log-dir <logs> --env OLLAMA_HOST=127.0.0.1:11434 --env OLLAMA_MODELS=<models> -- <ollama.exe> serve`.
  - Then `sc.exe config llmstack-ollama start= auto obj= "NT SERVICE\llmstack-ollama"` and a description.
  - Also set failure actions: `sc.exe failure ... reset= 86400 actions= restart/5000/restart/5000/restart/5000`.
- **Models** go in `%ProgramData%\llmstack\ollama\models`. The service account gets Modify access; Administrators and SYSTEM keep Full.
- Add `%ProgramFiles%\llmstack\ollama` to the machine `PATH`, so `ollama list` works in new shells. The CLI talks to the service over HTTP.
- **The Ollama desktop app.** If it is installed, its tray app starts `ollama serve` at login and competes for port 11434. Detect it (`%LOCALAPPDATA%\Programs\Ollama`, the Run key, or the Startup shortcut), explain the conflict, and offer to disable its autostart. Never uninstall it.
- **GPU drivers.** Never install one. Report NVIDIA or AMD cards whose driver is missing (Microsoft Basic Display Adapter, or a `ConfigManagerErrorCode` other than 0), and link to the vendor's driver page.

## 6. Open WebUI and SearXNG

**Open WebUI**
- Unpack uv from `uv-<x86_64|aarch64>-pc-windows-msvc.zip` into `%ProgramFiles%\llmstack\bin`.
- Create the venv with `UV_PYTHON_INSTALL_DIR=%ProgramFiles%\llmstack\python` and `UV_CACHE_DIR=%ProgramData%\llmstack\uv-cache`: `uv venv --python 3.11 %ProgramFiles%\llmstack\openwebui-venv`.
- Install `torch` from `https://download.pytorch.org/whl/cpu` with `--upgrade`, then `--upgrade-package open-webui open-webui`.
- **Service `llmstack-openwebui`** runs `<venv>\Scripts\open-webui.exe serve --host 0.0.0.0 --port <port>`.
  - `--cwd` is `%ProgramData%\llmstack\open-webui`.
  - Environment:
    - `DATA_DIR` (that same folder)
    - `OLLAMA_BASE_URL=http://127.0.0.1:11434`
    - `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=searxng` and `SEARXNG_QUERY_URL`
    - `HF_HOME` under the data folder
    - `PYTHONUTF8=1`
  - Depends on `llmstack-ollama`.

**The secret key**
- Never put it on the service command line or in service environment settings: both are readable by any user through `sc qc` and the registry.
- Open WebUI reads `.webui_secret_key` from its working directory when `WEBUI_SECRET_KEY` is unset. This was verified in open-webui 0.11.4's `__init__.py`.
- So the installer writes that file once: 32 random bytes as hex, from `System.Security.Cryptography.RandomNumberGenerator`.
- The data folder is ACL'd to Administrators, SYSTEM and the service account only.
- It is reused on every run.

**Firewall**
- Add an inbound rule, `llmstack Open WebUI`: TCP on the Open WebUI port, **Private profile only**.
- The README explains how to widen it.

**SearXNG, local mode (default)**
- Requires Docker Desktop.
- If Docker Desktop is missing, explain the download size, the WSL 2 requirement, the Docker Subscription Service Agreement (free for personal use and small businesses), and that a restart or sign-out may follow. Then ask separately; `-Yes` never answers this.
  - **Yes:** run the official installer, `Docker Desktop Installer.exe install --quiet --accept-license`, and tell the user to re-run the script after signing back in to finish SearXNG.
  - **No:** web search is disabled. Re-run with `-SearxngUrl`, or later with Docker Desktop.
- If Docker Desktop is installed but not running, start it and wait up to 180 s for `docker info`.
- The container runs from `%ProgramData%\llmstack\compose.yaml`, project `llmstack`:
  - image `docker.io/searxng/searxng:latest`
  - `restart: unless-stopped`
  - port `127.0.0.1:<port>:8080`
  - `%ProgramData%\llmstack\searxng` mounted at `/etc/searxng`
- **Settings** are the same as on Ubuntu: `use_default_settings`, a generated `secret_key`, `limiter: false`, `image_proxy: true`, and formats `html` and `json`.
- **Docker Desktop at sign-in.** It must start at sign-in, which is its default setting. Tell the user where that setting is.

**SearXNG, other modes**
- `-SearxngUrl URL`: remote. No Docker needed.
- `-NoWebSearch`: off, with `ENABLE_WEB_SEARCH=false`.

**Web search settings**
- They are ConfigVars, applied at first launch only. After that, Open WebUI's admin page is authoritative. Say so.

## 7. Files

| Path | Contents |
|---|---|
| `%ProgramData%\llmstack\config.json` | installer settings |
| `%ProgramData%\llmstack\models.catalog` | model catalogue, the same format as the other ports |
| `%ProgramData%\llmstack\open-webui\` | Open WebUI data and `.webui_secret_key` (restricted ACL) |
| `%ProgramData%\llmstack\ollama\models\` | models |
| `%ProgramData%\llmstack\searxng\settings.yml` | SearXNG config |
| `%ProgramData%\llmstack\compose.yaml` | SearXNG container |
| `%ProgramData%\llmstack\logs\` | shawl logs for both services |
| `%ProgramFiles%\llmstack\` | `ollama\`, `bin\` (shawl, uv, commands), `python\`, `openwebui-venv\`, and an installed copy of the script |

**Commands** go in `%ProgramFiles%\llmstack\bin`, which is on the machine `PATH`:
- `llmstatus.cmd`, `llmstart.cmd`, `llmstop.cmd` and `llmupgrade.cmd`.
- Each one calls the installed copy of the script.
- Start, stop and upgrade say so if they are not elevated.

**Test override:** `LLMSTACK_DATA_DIR` replaces `%ProgramData%\llmstack`.

## 8. Modes and parameters

PowerShell-style switches, with the same meanings as the other ports.

**Modes**
- `-Install` (default)
- `-Update`
- `-Status`
- `-Recommend`
- `-SyncModels`
- `-Benchmark`
- `-Uninstall`
- `-CheckModels`
- `-RefreshCatalog`
- `-RefreshCatalogApply`
- `-Version`
- `-Help`

**Options**
- `-SearxngUrl URL`
- `-SearxngPort N` (default 8888)
- `-NoWebSearch`
- `-WebUIPort N` (default 8080)
- `-Model TAG`
- `-NoModel`
- `-OllamaVersion X.Y.Z`
- `-Yes`: answers the install's own go-ahead only. It never answers removals, the uninstall, Docker Desktop or disabling the Ollama app's autostart.
- `-Discover`

**Carried over unchanged:**
- the macOS/Ubuntu rules for the guided uninstall (one piece at a time, default no, data needs two confirmations);
- `-Update` (back up the data first; restart even if a step fails);
- port validation and conflict reporting (`Get-NetTCPConnection -State Listen`);
- the catalogue-maintenance modes;
- `-SyncModels`, including outdated-build detection by manifest digest (`Get-FileHash` of the registry manifest vs the `ollama list` ID);
- `-Benchmark`, via `Invoke-RestMethod` against `/api/generate` and `/api/ps`.

## 9. Hardware detection and sizing

**Sizing: the same rules as Ubuntu**
- The largest usable discrete GPU sizes the picks: 75% of its VRAM, with no dense-speed gate.
- Otherwise: 70% of system RAM, plus the dense gate. Bandwidth = configured DIMM speed × 8 bytes × 2 channels, falling back to DDR4-3200 (51 GB/s).
- MIN_RAM compares with system RAM.

**RAM**
- Size: `Win32_ComputerSystem.TotalPhysicalMemory`, rounded to the nearest GiB.
- DIMM speed: the highest `Win32_PhysicalMemory.ConfiguredClockSpeed` (MT/s), falling back to `Speed`.

**GPUs** come from `Win32_VideoController`: vendor from `PNPDeviceID` (`VEN_10DE`, `VEN_1002`, `VEN_8086`), driver health from `ConfigManagerErrorCode`, and name.

**VRAM**
- `AdapterRAM` is a 32-bit field capped at 4 GB, so it is never used.
- Use the display class key `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000..` value `HardwareInformation.qwMemorySize`, matched to the adapter by `MatchingDeviceId`/`DriverDesc`.
- For NVIDIA, `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits` wins when it works.

**Usable GPUs**
- An NVIDIA card is usable when its driver is healthy.
- An AMD card is usable when its driver is healthy and it has at least 2 GiB of VRAM; less than that is integrated.
- Intel GPUs are listed but never size the picks.

**Tests**
- Every probe is a small function, so Pester mocks one function per probe, and no test reads real hardware.
- WMIC is gone in 24H2, so use `Get-CimInstance` only.

## 10. Catalogue

- **Rows:** identical to the Ubuntu v1.0.0 catalogue in all seven columns, `Catalogue-Generation: 3.4.0`. The Ubuntu NOTES are platform-neutral enough to share.
- **Header comments:** adapted.
- **Line endings:** written with LF. Accept CRLF on read.
- **Refresh-proposal rules:** the same.
- **Lockstep:** keep the generation in step across the three repositories.

## 11. Failure modes to pre-empt

1. Windows PowerShell 5.1 and non-ASCII source (§2).
2. `AdapterRAM` 4 GB cap (§9).
3. The secret key must not reach `sc qc` or the registry (§6).
4. The Ollama tray app holds port 11434 (§5).
5. The Mark-of-the-Web blocks the downloaded script: `Unblock-File` or `-ExecutionPolicy Bypass`.
6. `$ProgressPreference = 'SilentlyContinue'` around any `Invoke-WebRequest`. On 5.1, progress rendering slows downloads by orders of magnitude.
7. TLS 1.2 on 5.1: set `[Net.ServicePointManager]::SecurityProtocol` to include Tls12 before any web call.
8. `curl.exe`, never the `curl` alias. On 5.1, `curl` is `Invoke-WebRequest`.
9. Service virtual accounts exist only once the service does. Create the service, then set the ACLs.
10. Every download has a timeout. Readiness polls real endpoints.
11. Catalogue sizes may be decimal. Parse with `[double]::Parse(x, [Globalization.CultureInfo]::InvariantCulture)`: a comma-decimal locale would otherwise misread `7.6`.

## 12. Script quality

- `Set-StrictMode -Version 2` and `$ErrorActionPreference = 'Stop'`.
- Idempotent.
- PSScriptAnalyzer-clean with the repo settings.
- Colour via `Write-Host -ForegroundColor`, only when the host supports it.
- Comments explain why.
- Functions mirror the bash scripts' names in PowerShell verb-noun form, so fixes can be carried across.

## 13. Documentation

The README covers what it installs, requirements, the Quick start (including the ExecutionPolicy note), a verification table, modes, parameters, sizing and GPUs, the catalogue, sync, benchmark, **the sign-in limitation for web search**, remote SearXNG, commands, updating, uninstalling, file layout, ports and firewall, security, troubleshooting, FAQ, design notes and changelog.

## 14. Working style

As in the other specs:
- State decisions and trade-offs first.
- Verify current facts.
- Never invent model tags.
- Say what is and isn't verified.

## 15. CI

**Lint** (`windows-latest`)
- The PowerShell parser on 5.1 and on 7 reports no errors.
- ASCII-only check.
- PSScriptAnalyzer 1.25.0 with the repo settings.
- actionlint.

**Unit**
- Pester 6.2.0, installed from the Gallery (runners ship an older Pester).
- Runs under `powershell.exe` 5.1 and `pwsh` 7.
- Every system call is mocked: CIM, the registry, `nvidia-smi`, `curl.exe`, `ollama`, `sc.exe`, `shawl` and Docker.
- Cases:
  - the Ubuntu hardware cases, translated to Windows probes
  - the sync, refresh and catalogue-format tests
  - CLI validation

**End to end**
- `windows-latest`, which is Windows Server 2025, run with `LLMSTACK_ALLOW_SERVER=1`.
- `windows-11-arm`, which is real Windows 11. It is marked experimental until it passes, because PyTorch and Open WebUI wheels for Windows arm64 are the risk.
- Steps:
  1. Install with `-Yes -Model smollm2:135m -NoWebSearch`. Linux containers cannot run on hosted Windows runners, so local SearXNG and Docker Desktop are **unverified in CI**; the README says so.
  2. Assert both services are Running and Automatic, and run under their virtual accounts.
  3. Ollama answers on loopback only. Open WebUI answers.
  4. The secret key file ACL excludes Users.
  5. The firewall rule exists.
  6. Re-run the install.
  7. Restart the services.
  8. Run `-Benchmark`.
  9. Run `-SyncModels`, answering no.
  10. Uninstall, answering yes, and assert nothing is left.

## 16. Extensions

<!-- Append refinements below, referencing the section amended. -->
