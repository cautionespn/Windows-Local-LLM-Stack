<!--
  Generated from 30-windows-spec.md in the maintainer's private meta repository
  (Local-LLM-Stack-Meta) by tools/export_prompt.py. Do not edit here:
  change the spec there and export again.
-->

> **About this file.** This is the complete specification Windows-Local-LLM-Stack is built
> from: give it to Claude with an empty folder to rebuild the repository,
> or with this repository to change it. It names some companion documents
> (`01-shared-core.md`, `40-ci-and-testing.md`, `50-release-runbook.md`,
> `60-lessons-learned.md`, `80-backlog.md`). Those live in the maintainer's
> private meta repository. The rules they share with this spec are copied
> in below; the rest are the maintainer's working notes.

# 30 — Rebuild spec: Windows-Local-LLM-Stack (`llmstack-windows.ps1` v1.0.1)

**Use this prompt to rebuild the repository from an empty folder, or to change it.**
- Give the whole file to Claude with the instruction: *"Build (or update) the repository described here. Follow it exactly; where it is silent, ask."*
- It is self-contained. The `SHARED` blocks are kept identical to `01-shared-core.md`.
- **Option names.** The shared blocks write options as `--kebab-case`; this script uses PowerShell switches with the same meaning:

  | Shared block | This script |
  |---|---|
  | `--sync-models` | `-SyncModels` |
  | `--check-models` | `-CheckModels` |
  | `--refresh-catalog` | `-RefreshCatalog` |
  | `--refresh-catalog-apply` | `-RefreshCatalogApply` |
  | `--discover` | `-Discover` |
  | `--recommend` | `-Recommend` |
  | `--update` | `-Update` |
  | `--yes` | `-Yes` |

  The spelling applies **inside strings too**. The REVIEW header written into proposals is `# --- Suggested by -RefreshCatalog: set every REVIEW field, then delete '# REVIEW: ' ---`, and a Pester test asserts it. The proposal hints use `Compare-Object` and `Move-Item -Force`, and messages say `-SyncModels`.

| | |
|---|---|
| Repository | `cautionespn/Windows-Local-LLM-Stack` (public, GPL v3) |
| Current version | 1.0.1 (2026-10-01; release `1.0.1` to be published by Chris). Previous: 1.0.0, tag `1.0.0` on `ef5b4b3`, released 2026-10-01 |
| Catalogue generation | 3.4.0 |
| Verified on | CI: real install, re-run, declining Docker Desktop, restart, benchmark, sync and uninstall on **Windows 11 Enterprise ARM64** (build 26200, `windows-11-arm`) and **Windows Server 2025 x64** (`windows-latest`, plus update); 63 Pester tests on 5.1 and 7 |
| Not verified | local SearXNG in Docker Desktop and the Docker Desktop install (hosted Windows runners cannot run Linux containers), real GPU hardware, Windows 11 x64 (no hosted runner) |

---

## 1. Objective

The deliverables are:
- one PowerShell script that provisions the stack on Windows 11;
- a GitHub-style README;
- workflows that lint the script, unit-test it with Pester, and **really install** it on hosted runners.

## 2. Target environment

- **Windows 11, amd64 and arm64.**
  - Refuse build < 22000 and server SKUs (ProductType ≠ 1).
  - `LLMSTACK_ALLOW_SERVER=1` accepts Server, for CI only.
- **Windows PowerShell 5.1 is the baseline**; the script also runs unchanged on 7.4+. Do not use:
  - `??` or `?:`
  - pipeline chains (`&&`, `||`)
  - `ForEach-Object -Parallel`
  - `-SkipHttpErrorCheck` or `-StatusCodeVariable`
  - `ConvertFrom-Json -AsHashtable`
  - 3-argument `Join-Path`
- **ASCII only**, in the script and the tests. 5.1 reads a file without a BOM as ANSI. CI enforces this.
- **Elevation.**
  - Install, update, uninstall, start and stop assert Administrator up front.
  - Catalogue writes need it too. A non-admin `-RefreshCatalog` fails when writing the proposal.
  - **`-SyncModels` does not need it.** Pulls and removals go through the Ollama service. Only replacing an outdated catalogue writes to the data folder. When that offer would be made and `Test-LlmDataWritable` is false, print the generation lines, then `Replacing it needs Administrator. To be offered the replacement, run -SyncModels from an elevated PowerShell. Carrying on with your catalogue.` and continue without asking.
  - `-Help` says: install, update, uninstall, start and stop need an elevated PowerShell; `-SyncModels` needs one only to replace an outdated catalogue.
  - `-Recommend`, `-Status` and `-Benchmark` don't.
  - Never self-elevate: a new window loses the output. Say how to open an elevated prompt instead.
- **Running it:** `powershell -ExecutionPolicy Bypass -File .\llmstack-windows.ps1`, or `Unblock-File` first, because of the Mark-of-the-Web.
- **Test hooks:**
  - `LLMSTACK_DATA_DIR` replaces `%ProgramData%\llmstack`.
  - `LLMSTACK_PROGRAM_DIR` replaces `%ProgramFiles%\llmstack`.
  - Build the default paths with `[IO.Path]::Combine`, not `Join-Path`, which fails on a missing drive.

## 3. Deliverables

1. **`llmstack-windows.ps1`:** one file, starting with a `<# ... #>` header and `[CmdletBinding()] param(...)`.
2. **`README.md`.**
3. **`tests/llmstack.Tests.ps1`:** Pester 6 (§14).
4. **`PSScriptAnalyzerSettings.psd1`:**
   - `Severity` Error and Warning.
   - It excludes only these rules, each with its reason:
     - `PSAvoidUsingWriteHost`: interactive coloured output, which tests read on stream 6.
     - `PSUseShouldProcessForStateChangingFunctions`: the script has its own confirmations.
     - `PSUseSingularNouns`: private helper names.
5. **Workflows:**
   - `.github/workflows/ci.yml`.
   - `.github/workflows/release-asset.yml`:
     - Reads the version with `grep "^\$Script:ScriptVersion = " | cut -d"'" -f2`.
     - Runs an ASCII check.
     - Attaches the script.
   - `.github/actionlint.yaml`: declares the `windows-11-arm` label, which actionlint 1.7.7 does not know.
6. **`LICENSE`:** GPL v3.
7. **`PROMPT.md`:** this file, exported with `tools/export_prompt.py` from the meta repo (a short preamble says the files it names live in the maintainer's private meta repo). Never edit it by hand; change this spec and export again.

## 4. Stack and why

| Component | How it runs |
|---|---|
| Ollama | Windows service `llmstack-ollama`, wrapped by **shawl**, virtual account `NT SERVICE\llmstack-ollama` |
| Open WebUI | Windows service `llmstack-openwebui` via shawl, virtual account `NT SERVICE\llmstack-openwebui`, uv-managed venv (Python **3.11 on amd64, 3.12 on arm64**: PyTorch's Windows-on-Arm wheels need 3.12) |
| SearXNG | **Docker Desktop** container: runs only after someone signs in. Or remote (`-SearxngUrl`), or off (`-NoWebSearch`) |
| shawl v1.9.0 | `shawl-v1.9.0-win64.zip` from GitHub (x64; runs under emulation on ARM64) |
| uv | latest `uv-x86_64-pc-windows-msvc.zip` / `uv-aarch64-pc-windows-msvc.zip` |

**Why these choices** (Chris decided the two marked):
- **Ollama has no Windows service mode.** `OllamaSetup.exe` is a per-user tray app. The portable `ollama-windows-<arch>.zip` is the documented basis for running it as a service.
- **Service wrapper: shawl** *(Chris)*. Rejected alternatives:
  - NSSM is unmaintained and flagged by Defender as a PUA.
  - Servy is heavier.
  - A scheduled task needs a stored password and restarts poorly.
- **SearXNG: Docker Desktop** *(Chris)*, with the sign-in limitation stated plainly. Rejected alternatives:
  - WSL cannot start from Session 0 (WSL#9231).
  - A Hyper-V VM needs Pro or higher and is heavy.
- **No winget.** It is unreliable on runners. Download pinned GitHub release assets with `curl.exe` and verify each against GitHub's published SHA-256 `digest`.

## 5. Ollama

**Download.**
- `https://github.com/ollama/ollama/releases/latest/download/ollama-windows-<arch>.zip`, or `.../download/v<ver>/...` with `-OllamaVersion`.
- On amd64 with an AMD GPU, also `ollama-windows-amd64-rocm.zip`.
- Asset metadata comes from `api.github.com`. Send `Authorization: Bearer $env:GITHUB_TOKEN` when set (CI); unauthenticated calls are limited to 60 an hour.
- The API call sends `User-Agent: llmstack-windows` with a 30 s timeout. If it fails, warn and download without a checksum.
- Downloads use `curl.exe -fL --retry 3 --max-time 3600`, with `--progress-bar`, or `-sS` when output is redirected.
- A checksum mismatch deletes the file and stops.
- The Ollama download is skipped when the installed version satisfies any `-OllamaVersion` pin; `-Update` forces it.

**Install.**
- Stop the service.
- **Delete `%ProgramFiles%\llmstack\ollama` and re-extract**; never overlay.
- Extract with `tar.exe -xf`. `Expand-Archive` on 5.1 is far too slow for 1.5 GB.

**Service** (§7, `Install-LlmService`):
- Exe `ollama.exe serve`, with cwd set to the Ollama directory.
- Env `OLLAMA_HOST=127.0.0.1:11434` and `OLLAMA_MODELS=%ProgramData%\llmstack\ollama\models`.
- After the service exists, `icacls <models> /grant "NT SERVICE\llmstack-ollama:(OI)(CI)M"`, and the same for `logs`.
- Start it, then wait up to 60 s for `/api/version`.

**PATH.** Add `%ProgramFiles%\llmstack\ollama` and `\bin` to the machine `Path`.

**The Ollama desktop app.**
- Its Startup shortcut (`C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk`) launches a server competing for port 11434.
- Offer to rename it to `Ollama.lnk.disabled-by-llmstack` and stop `ollama app`. `-Yes` never answers this.

**GPU drivers are never installed.** Report missing ones with a vendor link.

## 6. Open WebUI and SearXNG

**Open WebUI.**
- uv runs with `UV_PYTHON_INSTALL_DIR=%ProgramFiles%\llmstack\python`, `UV_CACHE_DIR=%ProgramData%\llmstack\uv-cache`, `UV_PYTHON_PREFERENCE=only-managed` and `UV_NO_PROGRESS=1`.
- Steps:
  1. `uv venv --python <3.11|3.12> %ProgramFiles%\llmstack\openwebui-venv`
  2. `uv pip install --python <venv>\Scripts\python.exe --upgrade torch --index-url https://download.pytorch.org/whl/cpu`
  3. `--upgrade-package open-webui open-webui`

**The secret key.**
- Never on the command line or in the service registry environment: `sc qc` and the registry are readable by any user.
- Open WebUI reads `.webui_secret_key` from its **working directory** when `WEBUI_SECRET_KEY` is unset. This was verified in open-webui 0.11.4's `__init__.py`.
- So write that file once (32 random bytes as 64 hex characters from `RandomNumberGenerator`) in `%ProgramData%\llmstack\open-webui`, and reuse it.
- That folder's ACL is `/inheritance:r`, granting `*S-1-5-32-544` (Administrators) F, `*S-1-5-18` (SYSTEM) F, and `NT SERVICE\llmstack-openwebui` M. Use SIDs so it works in every display language.

**The service.**
- `open-webui.exe serve --host 0.0.0.0 --port <port>`, with cwd set to the data folder.
- Env:
  - `DATA_DIR`
  - `HF_HOME=<data>\cache\huggingface`
  - `OLLAMA_BASE_URL=http://127.0.0.1:11434`
  - `ENABLE_WEB_SEARCH=true|false`
  - `PYTHONUTF8=1`
  - `WEB_SEARCH_ENGINE=searxng` and `SEARXNG_QUERY_URL=<url>/search?q=<query>`, unless web search is off.
- Depends on `llmstack-ollama`.
- Grant the account M on `<data>\logs` (for shawl) and on `<venv>\Lib\site-packages\open_webui\static`, which Open WebUI rewrites at every start.

**Firewall.** Rule `llmstack Open WebUI`: inbound TCP on the port, **Private profile only**. Recreate it on every install.

**SearXNG, local mode.**
- Settings are as on Ubuntu, written once.
- `%ProgramData%\llmstack\compose.yaml`:
  - project `llmstack`, service `searxng`, container `llmstack-searxng`
  - `docker.io/searxng/searxng:latest`, `restart: unless-stopped`
  - port `127.0.0.1:<port>:8080`
  - volume `<data>/searxng:/etc/searxng`, with **forward slashes**
- If Docker Desktop (`%ProgramFiles%\Docker\Docker\Docker Desktop.exe`) is missing, `Request-LlmDockerDesktop` asks **right after the install's go-ahead and before anything is configured**, so Open WebUI and `config.json` reflect the answer:
  - Explain WSL 2, the size, the restart, and the Docker Subscription Service Agreement (free for personal use and small businesses).
  - Ask separately; **`-Yes` never answers this**, and with no answer (EOF) it is no.
  - **No** sets `SearxngMode` to `off` for this run and later ones (it is saved in `config.json`), so Open WebUI gets `ENABLE_WEB_SEARCH=false` and no SearXNG URL, and later re-runs stop asking. It prints `Web search is off. To turn on local search later, re-run with -SearxngPort <port> (it asks about Docker Desktop again), or use -SearxngUrl. If Open WebUI has already run, also turn web search off under Admin Panel > Settings > Web Search: it applies these settings only on its first start.`
  - **Yes** keeps `local` and sets `$Script:InstallDockerDesktop`. At the SearXNG step, download `https://desktop.docker.com/win/main/<amd64|arm64>/Docker%20Desktop%20Installer.exe` and run `install --quiet --accept-license`. A non-zero installer exit only warns. Then say to sign out, start Docker Desktop and re-run. Open WebUI stays configured for local search, which starts working once SearXNG is up.
- Find the Docker CLI at `%ProgramFiles%\Docker\Docker\resources\bin\docker.exe`, falling back to PATH. Readiness means `docker info --format {{.OSType}}` succeeds.
- If Docker Desktop is installed but not running, start it through `explorer.exe`, which drops the elevated token, and poll every 3 s for up to 180 s.
- Then run `docker compose -f <file> up -d --remove-orphans`, and wait up to 60 s for SearXNG JSON.
- Tell the user to keep "Start Docker Desktop when you sign in" on.

**Web-search settings** are ConfigVars, applied at first launch only.

## 7. Services (shawl)

`Install-LlmService` recreates the service on every run, so changed settings always apply:
1. Stop the service, `sc.exe delete` it, and wait up to 30 s for it to disappear. If it doesn't, tell the user to close services.msc and Event Viewer.
2. `shawl add --name <n> --restart --stop-timeout 10000 --kill-process-tree --log-dir <data>\logs [--cwd ..] [--env K=V ...] [--dependencies ..] -- <exe> <args>`
3. `sc.exe config <n> start= auto obj= "NT SERVICE\<n>" DisplayName= "<display>"`. Each `key=` and its value are separate arguments.
4. `sc.exe description <n> "<text>"`
5. `sc.exe failure <n> reset= 86400 actions= restart/5000/restart/5000/restart/5000`

A virtual account exists only once its service does, so set the ACLs after creating the service.

## 8. Files and commands

| Path | Contents |
|---|---|
| `%ProgramData%\llmstack\config.json` | `WebUIPort`, `SearxngMode` (`local`/`remote`/`off`), `SearxngUrl`, `SearxngPort`, `ScriptVersion` |
| `%ProgramData%\llmstack\models.catalog` | catalogue |
| `%ProgramData%\llmstack\open-webui\` | data and `.webui_secret_key` (restricted); backups beside it as `open-webui.backup-YYYYMMDD-HHMMSS` |
| `%ProgramData%\llmstack\ollama\models\` | models |
| `%ProgramData%\llmstack\searxng\settings.yml`, `compose.yaml` | SearXNG |
| `%ProgramData%\llmstack\logs\` | shawl logs |
| `%ProgramFiles%\llmstack\{ollama,bin,python,openwebui-venv}` | programs; `bin` holds shawl, uv and the commands |
| `%ProgramFiles%\llmstack\llmstack-windows.ps1` | installed copy that the commands run |

**ACLs.**
- `%ProgramData%\llmstack` gets `/inheritance:r`, with Administrators and SYSTEM F and Users RX.
- Catalogue writes therefore need Administrator.
- Read-only modes without a catalogue use the built-in text in memory.

**Commands** (`bin\*.cmd`, ASCII, CRLF):
- Each runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\llmstack-windows.ps1" <mode>`.
- `llmstatus` runs `-Status`, `llmstart` `-Start`, `llmstop` `-Stop`, and `llmupgrade` `-Update %*`.

## 9. Modes and parameters

**Modes:**
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
- `-Start`
- `-Stop`
- `-Version`
- `-Help`

**Options:**
- `-SearxngUrl URL`
- `-SearxngPort N` (8888)
- `-NoWebSearch`
- `-WebUIPort N` (8080)
- `-Model TAG`
- `-NoModel`
- `-OllamaVersion X.Y.Z`
- `-Yes`
- `-Discover`

**Validation.**
- At most one mode; none means `-Install`.
- `-OllamaVersion` matches `^\d+\.\d+\.\d+(-rc\d+)?$`.
- `-Model` matches `^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]+)?$`.
- `-SearxngUrl` and `-NoWebSearch` are mutually exclusive.
- Ports are 1–65535. `-WebUIPort` and `-SearxngPort` stay `[int]`, but "given" means bound: `$Script:Opt` holds the value when `$PSBoundParameters.ContainsKey(...)` and `$null` otherwise. `Invoke-LlmMain` validates every given port before dispatching, in every mode, so `-SearxngPort 0` and `-WebUIPort 65536` are rejected even with `-CheckModels`. `Resolve-LlmSettings` applies a port only when it is not `$null`.

**Implementation rules.**
- **Parameters** are copied once into `$Script:Opt`, and functions read only that. This avoids PSScriptAnalyzer's unused-parameter false positives and lets tests set options directly.
- **Errors.** `Stop-LlmStack "msg"` throws `"LLMSTACK: msg"`. Main catches it, prints `ERROR: msg` in red, and exits 1. Other errors also print their position. If the install had started, add the partial-state note and the log location. Functions never call `exit`.
- **Dot-sourcing.** The tests dot-source the script, so when it is dot-sourced it defines functions and runs nothing: `if ($MyInvocation.InvocationName -ne '.') { ... }`. Inside that block, set `Set-StrictMode -Version 2`, `$ErrorActionPreference='Stop'` and `$ProgressPreference='SilentlyContinue'`, then call `Invoke-LlmMain` in a try/catch. `Invoke-LlmMain` turns on TLS 1.2 before dispatching. `-Version` uses `Write-Output`; everything else uses `Write-Host`.
- **Native commands** run through `Invoke-LlmNative`, which returns `{Code, Output}`, or `Invoke-LlmNativeLive`, which streams output and returns the code. Both:
  - set `$ErrorActionPreference='Continue'` locally, because stderr under Stop is terminating on 5.1;
  - check `Get-Command` first, returning 9009 when the command is missing;
  - always call `curl.exe`, never `curl`, which is an alias on 5.1.
- **Prompts.** `Read-LlmAnswer` reads `[Console]::In.ReadLine()` when stdin is redirected, else `Read-Host`; EOF means no. `Confirm-Llm` and `Confirm-LlmInstall` (honours `-Yes`) sit on top of it.
- **Output.** `Write-LlmLine`, `Write-LlmLog` (`==> `), `Write-LlmWarn` and `Write-LlmOk` (`OK  `) all use `Write-Host`.

**Install flow.**
1. Settings.
2. Admin check.
3. System detection, the OS check and `curl.exe`/`tar.exe`/`icacls.exe`/`sc.exe` checks.
4. The report.
5. Port checks (`Get-NetTCPConnection`). Check the WebUI port, **11434**, and the SearXNG port in local mode. Holders that look like ours are not warned about: `python`, `open-webui`, `ollama` and `shawl`; and for SearXNG, `docker`, `wslrelay` and `com.docker`.
6. The model choice.
7. `Confirm-LlmInstall`.
8. `Request-LlmDockerDesktop` (local mode with Docker Desktop missing only; see §6).
9. The Ollama app conflict.
10. Directories and the data-root ACL.
11. The catalogue and config.
12. shawl.
13. Ollama.
14. Open WebUI.
15. SearXNG (installing Docker Desktop here if the answer was yes).
16. Commands and PATH.
17. The model pull, through `Invoke-LlmGuardedPull`: on Ctrl-C it prints `Pull interrupted. Re-run to resume the download.`
18. Wait up to 420 s for Open WebUI.
19. The summary, with the sign-in note in local mode.

**`Invoke-LlmGuardedPull -Tag <t> -InterruptMessage <m>`** runs `ollama pull` through `Invoke-LlmNativeLive` and returns its exit code. It wraps the call in `try { ...; $done = $true } catch { $failed = $true; throw } finally { if (-not $done -and -not $failed) { Write-LlmWarn $m } }`. A pipeline stop (Ctrl-C) skips `catch` and runs `finally`, so only an interruption prints the message; an ordinary error is rethrown silently. `-SyncModels` uses it with the shared message.

**`-Update`:**
- Stop Open WebUI and back up the data.
- Force Ollama.
- Upgrade the packages, then start the service even if the upgrade failed.
- Docker Desktop running: `compose pull` and `up -d`.
- Wait 300 s.
- Report the catalogue age, run `-CheckModels`, and print the daily pick.

**`-Uninstall`.** Begin, then six steps, each asking:
1. The services and the firewall rule.
2. The SearXNG container and image, if Docker Desktop is running.
3. `%ProgramFiles%\llmstack`, with its PATH entries.
4. Data (twice), then the backups.
5. Models.
6. The rest of the data folder; then remove it if empty.

GPU drivers and Docker Desktop are never touched.

**`-Benchmark`.** As on Ubuntu, using `Invoke-RestMethod`; read `size`/`size_vram` from `/api/ps` `models`.

<!-- SHARED:sync -->
### `--sync-models` (shared contract)

This mode brings installed models in line with the current picks. **The safety property is order: every chosen pull must succeed before anything is removed.** Every change needs a yes, every prompt defaults to no, and bare Enter means no.

1. **Daemon check.** `ollama list` must succeed. Otherwise say "Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed." and exit 1.
2. **Catalogue lineage.** If the `Catalogue-Generation` marker is missing or older than the built-in generation:
   - Explain that newer models will not appear until the catalogue is replaced.
   - Say that a backup is kept and hand-added rows can be copied back.
   - Say that adding the current marker line stops the offer.
   - Then ask "Back up your catalogue and replace it with the built-in one?"
3. **Picks.** Compute every role's pick and collapse them to one line per unique tag, listing every role it serves. Treat a tag with no `:` as `:latest` everywhere. Show each pick as:

   ```
     <tag padded 30> <size> GB  <arch>  <state>  <roles>
   ```

   The state is one of:
   - `not installed`
   - `current`: the `ollama list` ID equals the first 12 hex characters of the SHA-256 of the manifest the registry serves for the tag.
   - `outdated`: the two differ.
   - `unchecked`: the registry was unreachable or the manifest could not be fetched.

   If no role has a pick, warn "Nothing in the catalogue fits this machine, so there is nothing to sync." and exit 0, before any registry check.

   Otherwise check reachability once. If the registry is unreachable, print "(Registry unreachable: installed picks were not checked for newer builds.)" and carry on.
4. **Choose.** Go through the picks in order:
   - For each `not installed` pick: "Pull <tag> (about <size> GB) for: <roles>?"
   - For each `outdated` pick: "Update <tag> for: <roles>? Your build is older than the registry's (download up to <size> GB)."
5. **Removal candidates** are installed models that are no current pick. Declining a pick's pull never makes it a removal candidate. If nothing is chosen and there are no candidates, say "Nothing to do: ..." and exit 0.
6. **Disk check.** Updates count at full size. If free disk is less than the chosen sizes plus 10 GB:
   - Warn, and say "Nothing was changed. To free space first, run --sync-models again, decline every pull, and answer yes to the removals you want."
   - Exit 1.
7. **Pull** everything chosen. On Ctrl-C during a pull, say "Pull interrupted. Nothing was removed. Re-run to resume the download." and stop: bash traps `INT`; PowerShell, where a stop skips `catch` but runs `finally`, prints it from a `finally` guarded by "not done and no ordinary error". If any pull fails, list the failures, say "no models were removed", and exit 1.
8. **Remove**, one model at a time:
   - Show the model's name and size.
   - If `ollama show` lists an `embedding` capability, warn that Open WebUI may use it for document search.
   - Ask "Remove <model>?"
9. **Summary.** Print a `SYNC COMPLETE` banner, then the Pulled, Updated, Removed and "Kept, not a current pick" lists, each showing `(none)` when empty. If anything was removed, add a reminder to choose a new default model in Open WebUI.

When stdin is a list of answers, as in tests, loops that prompt must not consume that list. In bash, iterate over fd 3.
<!-- /SHARED:sync -->

<!-- SHARED:registry -->
### Registry checks and catalogue maintenance (shared contract)

**Endpoint.** `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`, with header `Accept: application/vnd.docker.distribution.manifest.v2+json`.
- 200 means live and 404 means dead; no auth is needed.
- Any other status, a timeout or a network error means **unknown**.

**Fail-soft, always.**
- An unknown never changes the catalogue.
- Every call has a timeout of 8–15 s.
- Reachability is checked once up front by probing `llama3.3:70b`. **Any 200 or 404 counts as reachable**, so the check survives that tag being retired. If the registry is unreachable, the mode reports that and exits 0 with nothing written.
- CI depends on this.

**`--check-models`.**
- Probes every tag and prints a LIVE/DEAD/???? line for each, then a summary.
- **Only if at least one VERIFIED value changes** (200 sets `yes`, 404 sets `no`), it takes a timestamped backup (`models.catalog.backup-YYYYMMDD-HHMMSS`) and rewrites the file.
- Otherwise, if any tag is dead, it points at `--refresh-catalog`.

**`--refresh-catalog`.** Writes `models.catalog.proposed` beside the live file and never touches the live file.
- Walk the live file **in order**. Comments and blank lines pass through untouched, so headings keep their rows.
- A live row is rewritten with `VERIFIED=yes`. MIN_RAM, ARCH, ROLE and NOTES are preserved verbatim; they are human judgment.
- A dead row is commented out **in place**: `# DEAD (404 at registry, review/remove): <row with VERIFIED=no>`.
- An unknown row passes through unchanged.
- Candidates are found by probing `<family>:<size>` and `<family>:<size>-instruct` for each catalogue family. The sizes are 1.5b 3b 4b 7b 8b 9b 11b 12b 14b 22b 27b 30b 32b 34b 70b 72b. Only tags that are live and not already present count.
- With `--discover`, the script also scrapes `https://ollama.com/library` for family names and keeps those whose `:latest` is live. The scrape is fragile HTML, so it is wholly optional and fail-soft.
- Each candidate is appended **only as a comment**: `# REVIEW: REVIEW|<tag>|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.`
  - The first one is preceded by `# --- Suggested by --refresh-catalog: set every REVIEW field, then delete '# REVIEW: ' ---`. That header is never repeated.
  - A candidate already present as a `# REVIEW:` line is not suggested again.
- The proposal leaves `Last-Updated` alone.
- Field trimming must not mangle apostrophes. In bash that means parameter expansion, never `xargs`.

**`--refresh-catalog-apply`.**
- Builds a proposal **in this run**. A leftover `.proposed` file from an earlier run is never applied, notably when the registry is now unreachable.
- Shows the diff and asks, defaulting to no.
- On yes: backs up, replaces the live file, sets `Last-Updated` to today, and deletes the proposal.

**`--update`** runs `--check-models` after updating.
<!-- /SHARED:registry -->

Registry probes use `curl.exe -s -o NUL -w "%{http_code}"`. Manifest IDs come from `Get-FileHash -Algorithm SHA256` of the downloaded manifest.

## 10. Hardware detection and sizing (Windows)

Every probe is one small function, so tests mock exactly one thing each:

| Function | Reads |
|---|---|
| `Get-LlmOsInfo` | `Win32_OperatingSystem`: Caption, BuildNumber, ProductType |
| `Get-LlmArch` | `PROCESSOR_ARCHITEW6432`, else `PROCESSOR_ARCHITECTURE` (`AMD64`→amd64, `ARM64`→arm64) |
| `Get-LlmCpuInfo` | `Win32_Processor` |
| `Get-LlmRamBytes` | `Win32_ComputerSystem.TotalPhysicalMemory` as **raw bytes**; `Get-LlmSystem` rounds to the nearest GiB, and the Pester mock returns bytes |
| `Get-LlmDimmSpeed` | highest `Win32_PhysicalMemory.ConfiguredClockSpeed`, else `Speed` (0 in VMs) |
| `Get-LlmDiskFreeGB` | `IO.DriveInfo` of the data root |
| `Get-LlmVideoControllers` | `Win32_VideoController`: Name, PNPDeviceID, ConfigManagerErrorCode |
| `Get-LlmRegistryVram` | the display class key `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000..`: `MatchingDeviceId`, `DriverDesc`, and bytes via `Get-LlmVramBytes` (QWORD `HardwareInformation.qwMemorySize`, else `MemorySize`; REG_BINARY handled) |
| `Get-LlmNvidiaSmi` | `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits` rows |

**Never use `AdapterRAM`:** it is a 32-bit field capped at 4 GB. WMIC is removed in 24H2, so use `Get-CimInstance` only.

**Vendors.**
- The vendor comes from `PNPDeviceID`: `VEN_10DE` NVIDIA, `VEN_1002` AMD, `VEN_8086` Intel, anything else "other".
- A controller has no driver when its error code ≠ 0 or its name matches `Basic Display`.
- **NVIDIA:** from `nvidia-smi` when it works. A controller row is skipped only when `nvidia-smi` returned rows **and** that controller's driver is healthy. Any other NVIDIA controller becomes a `no-driver` row.
- **AMD:** VRAM comes from the registry key whose `MatchingDeviceId` prefixes the PNP ID, or whose `DriverDesc` equals the name. Under 2048 MiB means integrated.
- **Intel and other:** unsized.

**Pool and budgets.**
- The pool is the largest discrete NVIDIA or AMD card with runtime `ok`.
- With a pool: budget = VRAM × 0.75, no cap.
- Without: budget = RAM × 0.70; bandwidth = (MT/s, or 3200) × 8 × 2 ÷ 1000; cap = bandwidth × 0.65 ÷ 8.
- **Number formatting is invariant culture** throughout.
- Bandwidth label: "read from SMBIOS" or "assumed; DIMM speed unreadable".

**Pinned picks:** as on Ubuntu (20-ubuntu-spec §9), with the same numbers. Windows has only two runtime states, `ok` and `no-driver`, with no ROCm/Vulkan split. The AMD case shows "driver working", and there is no "AMD with no ROCm or Vulkan" case. The runtime texts:

| Vendor:state | Text |
|---|---|
| `nvidia:ok`, `amd:ok` | "driver working" |
| `nvidia:no-driver` | "NO DRIVER (nvidia-smi not working)" |
| `amd:no-driver` | "NO DRIVER" |
| Intel | "Vulkan only; VRAM not used for sizing" |
| Other | "not used by Ollama" |

<!-- SHARED:catalogue -->
### Model catalogue (shared contract, generation 3.4.0)

**Format.** One plain-text file. Pipe-delimited and hand-editable:
- `#` starts a comment.
- Blank lines are ignored.
- CRLF line endings are accepted on read.
- Files are written with LF.

Each data row is:

```
MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
```

| Column | Meaning |
|---|---|
| `MIN_RAM_GB` | Minimum **system** RAM (machine class). Compared with system RAM even when a GPU sizes the picks. |
| `TAG` | Exact Ollama tag, `name:tag`. Never invent one. |
| `SIZE_GB` | Download size of that exact tag. May be a decimal (`7.6`). |
| `ARCH` | `dense` or `moe`. |
| `ROLE` | `daily`, `reasoning`, `coding`, `vision` or `light`. |
| `VERIFIED` | `yes` only if the tag was confirmed in the Ollama registry; otherwise `no`. |
| `NOTES` | Free text, worded per platform. Never parsed. |

**Number handling.**
- Never feed a catalogue value to integer arithmetic.
- Compare sizes as decimals, culture-invariant: awk in bash, `[double]::Parse` with `InvariantCulture` in PowerShell.
- A row whose `MIN_RAM_GB` or `SIZE_GB` is not numeric (for example still `REVIEW`) is never picked.

**Header lines.**
- **`# Last-Updated: YYYY-MM-DD`** records when a *person* last reviewed the file.
  - Graded: under 90 days is recent; 90 to 180 is worth a look; over 180 is very likely stale.
  - `--recommend` and `--update` report the grade.
  - No tooling changes this line, except a confirmed `--refresh-catalog-apply`, which sets it to today.
- **`# Catalogue-Generation: X.Y.Z`** records which built-in catalogue the file descends from.
  - It is the MacOS-Local-LLM-Stack version in which the built-in rows last changed. That is currently **3.4.0**.
  - It is shared by all three repositories and bumped in all three together, only when the rows change.
  - A missing or older marker means "predates the built-in catalogue". `--recommend` notes it, and `--sync-models` offers a backed-up replacement.
  - Lineage is never judged from `Last-Updated`.

**Lifecycle.**
- The script writes the built-in catalogue on first use if none exists.
- It never overwrites an existing catalogue silently.
- What a read-only mode does when it cannot write differs per platform; each spec says which:
  - macOS: the catalogue is in the user's home, so it can always write.
  - Ubuntu: uses a temporary copy, deleted on exit.
  - Windows: uses the built-in text in memory.

**Selection.** Within each role, the **largest** entry that passes all three gates wins:
1. `SIZE_GB` ≤ the budget.
2. System RAM ≥ `MIN_RAM_GB`.
3. Dense entries only, and only when the platform defines a dense cap:
   - `SIZE_GB` ≤ dense cap.
   - Dense cap (GB) = bandwidth (GB/s) × 0.65 ÷ 8 tok/s.
   - Named constants: `DENSE_EFFICIENCY_PCT=65` (a percentage, divided by 100) and `DENSE_MIN_TPS=8`; on Windows, `$Script:DenseEfficiencyPct` and `$Script:DenseMinTps`.
   - MoE entries are exempt: only their active experts are read per token.

The bandwidth gate is the only MoE preference. Do not hard-prefer MoE: a dense model that passes may be better than any MoE that fits. Within a role, size tracks quality, so never list several quantizations of one model. Roles are shown in this order: daily, reasoning, coding, vision, light. The install pulls the daily pick, or the light pick when no daily pick fits.

**Built-in rows, generation 3.4.0.** These columns are identical on every platform; only NOTES differ.

| MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED |
|---|---|---|---|---|---|
| 4 | granite4.2:3b | 2.2 | dense | light | yes |
| 8 | qwen3.5:4b | 3.4 | dense | daily | yes |
| 16 | gemma4:12b | 7.6 | dense | daily | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | daily | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | daily | yes |
| 8 | qwen3.5:4b | 3.4 | dense | reasoning | yes |
| 16 | gemma4:12b | 7.6 | dense | reasoning | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | reasoning | yes |
| 32 | qwen3.8:27b | 18 | dense | reasoning | yes |
| 8 | qwen3.5:4b | 3.4 | dense | coding | yes |
| 16 | qwen3.5:9b | 6.6 | dense | coding | yes |
| 24 | devstral-small-2:24b | 15 | dense | coding | yes |
| 32 | qwen3.6:35b-a3b-coding | 23 | moe | coding | yes |
| 8 | qwen3.5:4b | 3.4 | dense | vision | yes |
| 16 | gemma4:12b | 7.6 | dense | vision | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | vision | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | vision | yes |

The file groups these under comment headings: `# --- Light ...`, `# --- Daily drivers ...`, `# --- Reasoning ...`, `# --- Coding ...` and `# --- Vision ...`. Above them is a header that explains the format, the two header lines, the three gates, why architecture matters, and the VERIFIED column. All tags were verified live against the registry on 2026-09-30 and are re-checked by CI on every push.
<!-- /SHARED:catalogue -->

**NOTES.** These are identical to the Ubuntu rows; see 20-ubuntu-spec §9. The built-in catalogue text is a here-string. **Return it with CRLF converted to LF**: a CRLF checkout on Windows otherwise leaks `\r` into lines. Interpolate the generation and date.

## 11. Failure modes to pre-empt

1. 5.1 and non-ASCII source.
2. The `AdapterRAM` cap.
3. The secret must stay out of `sc qc` and the registry.
4. The Ollama tray app holds port 11434.
5. The Mark-of-the-Web.
6. `$ProgressPreference` must be SilentlyContinue around web calls.
7. TLS 1.2 on 5.1.
8. `curl.exe`, never `curl`.
9. A virtual account exists only after its service does.
10. Timeouts everywhere.
11. Parse decimals with invariant culture.
12. Native stderr under Stop is terminating on 5.1 (`Invoke-LlmNative`).
13. `$LASTEXITCODE` is unset under StrictMode until a native command has run.
14. Don't Join-Path onto a missing drive.

## 12. Documentation

The README covers:
- what it installs, requirements and the Quick start (elevated; `curl.exe -fLO`, `Unblock-File`);
- **the verification table**;
- **web search and signing in**;
- modes, options, sizing, GPUs, the catalogue, sync and benchmark;
- commands (with which need elevation), update, uninstall, file layout;
- ports and firewall (Private only, and how to widen it), security, troubleshooting, FAQ (why not OllamaSetup; why shawl), design notes, development and changelog.

## 13. Working style

<!-- SHARED:working-style -->
### Working style (shared)

- State assumptions and design decisions before writing code. Name the options, weigh the trade-offs and justify the choice.
- Push back on risk or unneeded complexity instead of complying silently.
- Verify current facts (package names, image tags, model tags, endpoints, versions) instead of relying on recall. Say which ones were verified and which were not. **Never invent model tags.**
- Say plainly what is and is not verified, in the README too. A path tested only against stubs is not verified on real hardware.
- Deliver complete files, never diffs.
- Lint and test before delivering.
- Comment *why*, not *what*, especially at each workaround.
- Every network call has a timeout. Readiness polls real endpoints instead of sleeping.
- Every prompt defaults to no. Deleting Open WebUI data (accounts and chats) takes two confirmations; every other removal takes one. `--yes` (or `-Yes`) answers only the install's own go-ahead, never a removal, an uninstall, a driver install or a third-party licence.
- Idempotent: re-running is safe and never overwrites user data or the secret key.
<!-- /SHARED:working-style -->

## 14. CI

**Lint** (`windows-latest`):
- Parse both files with `[System.Management.Automation.Language.Parser]::ParseFile` under **both** `powershell` (5.1) and `pwsh`.
- ASCII check on the script, the tests and `PSScriptAnalyzerSettings.psd1`, emitting an `::error file=..,line=..` per offending line.
- The header version equals `$ScriptVersion`.
- PSScriptAnalyzer 1.25.0, **one file per call**. `-Path` takes a single string, and an array fails the step.

**actionlint** (`ubuntu-24.04`, 1.7.7).

**Unit** (`windows-latest`, matrix shell `powershell`/`pwsh`):
- Install Pester **6.2.0**: `Install-PackageProvider NuGet` on 5.1, `-SkipPublisherCheck`. The runner's own Pester is older.
- A matrix value cannot be used as `shell:`, so use two steps with `if:`.
- Run with `New-PesterConfiguration` (`Run.PassThru`) and print one single-line `::error::` annotation per failed container and test, so causes show on the run page.

**Catalogue** (`ubuntu-24.04`):
- Extract the rows from the here-string.
- Live tag guard.
- A `continue-on-error` diff against the latest Linux release's rows.

**End to end** (matrix `windows-latest`, `windows-11-arm`; both required):
- Env: `LLMSTACK_ALLOW_SERVER=1`, `MODEL=smollm2:135m`, `GITHUB_TOKEN`.
- `shell: powershell` (5.1).

Steps:
1. Install with `-Yes -Model $env:MODEL -NoWebSearch`, teeing the log and annotating `ERROR` and `WARNING` lines on failure.
2. Each service is Running, Auto and under `NT SERVICE\<name>`.
3. 11434 listens on 127.0.0.1 only. Open WebUI answers. The model is listed.
4. The secret's ACL excludes Users, Authenticated Users and Everyone, and it is 64 hex characters.
5. The firewall rule is Private-only.
6. The service command line holds no secret and does hold `ENABLE_WEB_SEARCH=false`.
7. `llmstatus.cmd` shows two UPs.
8. A re-run keeps the secret.
8a. **Declining Docker Desktop** (skipped with a notice if `Docker Desktop.exe` exists): pipe `n` into a child `powershell.exe ... -File .\llmstack-windows.ps1 -Yes -Model $env:MODEL -SearxngPort 8888`. It exits 0 and prints `Web search is off.`; `config.json` has `SearxngMode` `off`; the Open WebUI service command line has `ENABLE_WEB_SEARCH=false` and no `SEARXNG_QUERY_URL`.
9. Restart the services.
10. `-Benchmark` prints a row.
11. Sync with piped `n` answers.
12. `-Update` (x64 only).
13. Uninstall with piped `y` answers, then check that no service, folder, firewall rule, PATH entry or listening port is left.
14. On failure, print the logs, with their last 4 lines as `::warning::` annotations.

Job timeouts: lint 10 min, unit 15, catalogue 5, end-to-end 75. The sync and uninstall steps pipe 20 `n` and 40 `y` answers into a child `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` process.

**CI Pass** needs every job.

## 15. Pester layout (`tests/llmstack.Tests.ps1`)

**Setup.**
- **Root `BeforeAll`:**
  - Dot-source the script and save `$Script:Opt`.
  - Define the helpers:
    - `Set-Hw` (fake hardware table)
    - `New-Ctl`, `New-Vram`
    - `New-Data` (fresh data folder under `$TestDrive`, re-pointing every `$Script:` path)
    - `Get-Out` (captures stream 6 plus a `THROWN:` line with the `LLMSTACK: ` prefix stripped)
    - `Set-Answers` (a queue)
    - `Get-FakeId`
    - `Set-Catalog`
- **One outer `Describe`** wraps everything. **Pester allows `BeforeEach` only inside a block.** Its `BeforeEach`:
  - resets `$Script:Opt`, `$Script:Cfg` and the program paths;
  - creates new data;
  - mocks every probe from `$Script:Hw`, plus `Test-LlmAdmin` and `Read-LlmAnswer`;
  - mocks `Get-LlmHttpStatus` (a fake registry from `$Script:Live`, with `llama3.3:70b` always live), `Test-LlmRegistryReachable`, `Get-LlmRegistryManifestId` and `Find-LlmNewFamilies`;
  - mocks `Invoke-LlmOllama` (list, show and rm, logging calls) and `Invoke-LlmNativeLive` (pulls).
- **The `Read-LlmAnswer` mock prints its prompt**, as the real one does, so tests can assert on the questions.
- **Pester 6 mocks do not fall through to the real command.** Never mock `Test-Path` with a filter; create real files instead. Never test a function that `BeforeEach` mocks; factor the logic into an unmocked helper, such as `Get-LlmVramBytes`.

**Describes:**
- **metadata and CLI:** ASCII, header version, mode exclusivity, validation, settings precedence, help;
- **hardware:** every case in Ubuntu §9, plus Windows 10 refused, Server gated by the env var, `de-DE` culture and the unsupported-OS install;
- **catalogue:** format, never overwritten, in-memory when not writable, no Last-Updated, CRLF, REVIEW rows, staleness;
- **sync:** all the shared-contract cases;
- **refresh:** the same cases as the other ports;
- **status;**
- **services and secrets:**
  - shawl and `sc.exe` arguments captured;
  - the secret is never in the env and is reused;
  - `-NoWebSearch`;
  - key randomness;
  - the `.cmd` files;
  - the compose file has no backslashes;
  - Docker Desktop is never installed without an explicit yes, even with `-Yes`;
  - declining Docker Desktop saves `off` and gives Open WebUI `ENABLE_WEB_SEARCH=false` and no SearXNG URL, and the message names `-SearxngPort`;
  - accepting keeps `local` and installs at the SearXNG step.
- `BeforeEach` also resets `$Script:InstallDockerDesktop` to `$false`.
- **1.0.1 additions:**
  - `-SearxngPort 0` and `-WebUIPort 65536` are rejected by `Invoke-LlmMain`, also with `-CheckModels`; an unbound port leaves the config value;
  - a non-admin `-SyncModels` with an old catalogue explains, does not ask, does not write, and still pulls;
  - `-Help` no longer says sync needs elevation;
  - `Invoke-LlmGuardedPull`: a normal exit code is returned without the message; an ordinary error is rethrown without it; a pipeline stop, run in a child PowerShell (the same edition as the test) that dot-sources the script and overrides `Invoke-LlmNativeLive` to throw `PipelineStoppedException`, prints the message and nothing after it. A real stop would end the Pester run, hence the child process.

Total: 63 tests (54 in 1.0.0).

## Appendix — Version history

| Version | Change |
|---|---|
| 1.0.1 (2026-10-01) | Ctrl-C during pulls prints the interrupted message (backlog 4b); declining Docker Desktop turns web search off before Open WebUI is configured (4c); ports validated when given, in every mode (4d); `-SyncModels` needs no elevation and explains instead of failing when a catalogue replacement would need it (4e); `PROMPT.md` exported from this spec |
| 1.0.0 (2026-09-30) | First version; PR #1 merged as `ef5b4b3`. CI fixes before merge: root `BeforeEach`; analyzer per file; failures as annotations; arm64 job made required; LF-only built-in catalogue; `Get-LlmVramBytes`; the prompt mock prints its question |
