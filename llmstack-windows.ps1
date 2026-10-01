<#
llmstack-windows.ps1  v1.0.1

A self-contained, private LLM stack for Windows 11.

  Ollama       local inference engine (Windows service, via shawl)
  Open WebUI   web front-end (Windows service, uv-managed Python venv)
  SearXNG      private metasearch for web search (Docker Desktop container)

Ollama and Open WebUI start at boot with nobody signed in. SearXNG runs in
Docker Desktop, which starts only after someone signs in, so web search
works from then on. Model recommendations are sized to the largest usable
GPU's VRAM, or to system RAM and memory bandwidth without one.

Run  .\llmstack-windows.ps1 -Help  for full documentation.

Port of MacOS-Local-LLM-Stack v3.6.1 and Linux-Local-LLM-Stack v1.0.0:
  https://github.com/cautionespn/MacOS-Local-LLM-Stack
  https://github.com/cautionespn/Linux-Local-LLM-Stack

License: GNU General Public License v3.0. See the LICENSE file in
https://github.com/cautionespn/Windows-Local-LLM-Stack for the full text.

This file must stay ASCII: Windows PowerShell 5.1 reads a script without a
byte-order mark in the ANSI code page, and any other character corrupts it.
#>
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Update,
  [switch]$Status,
  [switch]$Recommend,
  [switch]$SyncModels,
  [switch]$Benchmark,
  [switch]$Uninstall,
  [switch]$CheckModels,
  [switch]$RefreshCatalog,
  [switch]$RefreshCatalogApply,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Version,
  [switch]$Help,
  [string]$SearxngUrl = '',
  [int]$SearxngPort = 0,
  [switch]$NoWebSearch,
  [int]$WebUIPort = 0,
  [string]$Model = '',
  [switch]$NoModel,
  [string]$OllamaVersion = '',
  [switch]$Yes,
  [switch]$Discover
)

# Parameters, captured once. Functions read $Script:Opt, never the
# parameter variables, so tests can set options directly.
$Script:Opt = @{
  Install = $Install
  Update = $Update
  Status = $Status
  Recommend = $Recommend
  SyncModels = $SyncModels
  Benchmark = $Benchmark
  Uninstall = $Uninstall
  CheckModels = $CheckModels
  RefreshCatalog = $RefreshCatalog
  RefreshCatalogApply = $RefreshCatalogApply
  Start = $Start
  Stop = $Stop
  Version = $Version
  Help = $Help
  SearxngUrl = $SearxngUrl
  SearxngPort = $null
  NoWebSearch = $NoWebSearch
  WebUIPort = $null
  Model = $Model
  NoModel = $NoModel
  OllamaVersion = $OllamaVersion
  Yes = $Yes
  Discover = $Discover
}
# A port is "given" when it was bound, not when it is non-zero: before
# 1.0.1, -SearxngPort 0 was silently read as "not given".
if ($PSBoundParameters.ContainsKey('SearxngPort')) { $Script:Opt.SearxngPort = $SearxngPort }
if ($PSBoundParameters.ContainsKey('WebUIPort')) { $Script:Opt.WebUIPort = $WebUIPort }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:ScriptName = 'llmstack-windows.ps1'
$Script:ScriptVersion = '1.0.1'
$Script:CatalogDate = '2026-09-30'
# Shared with the macOS and Ubuntu repositories: the MacOS-Local-LLM-Stack
# version in which the built-in catalogue rows last changed. Keep the three
# in step; bump only when the rows in Get-LlmDefaultCatalogText change.
$Script:CatalogGeneration = '3.4.0'
$Script:CatalogWarnDays = 90
$Script:CatalogStaleDays = 180

# Dense-model speed gate, applied only when no discrete GPU sizes the picks:
# tok/s ~= memory bandwidth / model size, and real runs reach about 65%.
$Script:DenseMinTps = 8
$Script:DenseEfficiencyPct = 65
# Share of the sizing pool usable for weights: VRAM keeps a quarter for the
# KV cache and Ollama's reservation; RAM keeps 30% for everything else.
$Script:VramBudgetPct = 75
$Script:RamBudgetPct = 70
# Fallback CPU memory bandwidth: DDR4-3200, two channels.
$Script:DefaultRamMts = 3200
$Script:AssumedChannels = 2

$Script:ShawlVersion = '1.9.0'
$Script:RegistryBase = 'https://registry.ollama.ai/v2/library'
$Script:RegistryAccept = 'application/vnd.docker.distribution.manifest.v2+json'
# Common size tokens probed for newer variants within a catalogue family.
$Script:ProbeSizes = @('1.5b','3b','4b','7b','8b','9b','11b','12b','14b','22b','27b','30b','32b','34b','70b','72b')
$Script:ReviewHeader = "# --- Suggested by -RefreshCatalog: set every REVIEW field, then delete '# REVIEW: ' ---"

$Script:OllamaService = 'llmstack-ollama'
$Script:WebUIService = 'llmstack-openwebui'
$Script:FirewallRule = 'llmstack Open WebUI'
$Script:SearxngImage = 'docker.io/searxng/searxng:latest'
$Script:OllamaApi = 'http://127.0.0.1:11434'

# ---------------------------------------------------------------------------
# Paths. LLMSTACK_DATA_DIR and LLMSTACK_PROGRAM_DIR exist for tests.
# ---------------------------------------------------------------------------
function Get-LlmDefaultRoot([string]$EnvValue, [string]$Fallback) {
  if ($EnvValue) { return $EnvValue }
  return $Fallback
}
$Script:ProgramFilesDir = Get-LlmDefaultRoot $env:ProgramFiles 'C:\Program Files'
$Script:ProgramDataDir = Get-LlmDefaultRoot $env:ProgramData 'C:\ProgramData'
$Script:ProgramRoot = Get-LlmDefaultRoot $env:LLMSTACK_PROGRAM_DIR ([IO.Path]::Combine($Script:ProgramFilesDir, 'llmstack'))
$Script:DataRoot = Get-LlmDefaultRoot $env:LLMSTACK_DATA_DIR ([IO.Path]::Combine($Script:ProgramDataDir, 'llmstack'))

$Script:BinDir = [IO.Path]::Combine($Script:ProgramRoot, 'bin')
$Script:OllamaDir = [IO.Path]::Combine($Script:ProgramRoot, 'ollama')
$Script:OllamaExe = [IO.Path]::Combine($Script:OllamaDir, 'ollama.exe')
$Script:PythonDir = [IO.Path]::Combine($Script:ProgramRoot, 'python')
$Script:VenvDir = [IO.Path]::Combine($Script:ProgramRoot, 'openwebui-venv')
$Script:ShawlExe = [IO.Path]::Combine($Script:BinDir, 'shawl.exe')
$Script:UvExe = [IO.Path]::Combine($Script:BinDir, 'uv.exe')
$Script:InstalledScript = [IO.Path]::Combine($Script:ProgramRoot, $Script:ScriptName)

$Script:ConfigFile = [IO.Path]::Combine($Script:DataRoot, 'config.json')
$Script:CatalogPath = [IO.Path]::Combine($Script:DataRoot, 'models.catalog')
$Script:WebUIDataDir = [IO.Path]::Combine($Script:DataRoot, 'open-webui')
$Script:SecretFile = [IO.Path]::Combine($Script:WebUIDataDir, '.webui_secret_key')
$Script:ModelsDir = [IO.Path]::Combine($Script:DataRoot, 'ollama', 'models')
$Script:SearxngDir = [IO.Path]::Combine($Script:DataRoot, 'searxng')
$Script:SearxngSettings = [IO.Path]::Combine($Script:SearxngDir, 'settings.yml')
$Script:ComposeFile = [IO.Path]::Combine($Script:DataRoot, 'compose.yaml')
$Script:LogDir = [IO.Path]::Combine($Script:DataRoot, 'logs')
$Script:UvCacheDir = [IO.Path]::Combine($Script:DataRoot, 'uv-cache')

# Settings; the config file, then parameters, override these.
$Script:Cfg = [ordered]@{
  WebUIPort   = 8080
  SearxngMode = 'local'    # local | remote | off
  SearxngUrl  = 'http://127.0.0.1:8888'
  SearxngPort = 8888
}
$Script:InstallStarted = $false
$Script:ProposalBuilt = $false

# ---------------------------------------------------------------------------
# Output. Write-Host so colour works on 5.1 and 7; tests read stream 6.
# ---------------------------------------------------------------------------
function Write-LlmLine([string]$Text = '', [string]$Color = '') {
  if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-LlmLog([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-LlmWarn([string]$Text) { Write-Host ''; Write-Host "WARNING: $Text" -ForegroundColor Yellow }
function Write-LlmOk([string]$Text) { Write-Host "OK  $Text" -ForegroundColor Green }

# Errors the user should see as a message, not a stack trace.
function Stop-LlmStack([string]$Text) { throw "LLMSTACK: $Text" }

# ---------------------------------------------------------------------------
# Prompts. Every prompt defaults to no. When stdin is redirected (CI, or
# answers piped in) the answer is read from it, so tests can script them.
# ---------------------------------------------------------------------------
function Read-LlmAnswer([string]$Prompt) {
  Write-Host ''
  Write-Host "$Prompt [y/N]: " -NoNewline
  $reply = $null
  if ([Console]::IsInputRedirected) {
    $reply = [Console]::In.ReadLine()
    if ($null -ne $reply) { Write-Host $reply } else { Write-Host '' }
  } else {
    $reply = Read-Host
  }
  if ($null -eq $reply) { return '' }
  return $reply
}

function Confirm-Llm([string]$Prompt) {
  $r = (Read-LlmAnswer $Prompt).Trim()
  return ($r -eq 'y' -or $r -eq 'yes' -or $r -eq 'Y' -or $r -eq 'YES' -or $r -eq 'Yes')
}

# For the install's own go-ahead only: -Yes answers these.
function Confirm-LlmInstall([string]$Prompt) {
  if ($Script:AssumeYes) {
    Write-Host ''
    Write-Host "$Prompt [y/N]: y (-Yes)"
    return $true
  }
  return (Confirm-Llm $Prompt)
}

# ---------------------------------------------------------------------------
# Native commands. On Windows PowerShell 5.1, a native command writing to
# stderr while $ErrorActionPreference is Stop raises a terminating error, so
# these run with Continue and report the exit code instead.
# ---------------------------------------------------------------------------
function Invoke-LlmNative {
  param([string]$Exe, [string[]]$Arguments = @())
  $ErrorActionPreference = 'Continue'
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ Code = 9009; Output = @("$Exe was not found.") }
  }
  $out = @()
  $code = 0
  try {
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } catch {
    $out = @("$_")
    $code = 9009
  }
  if ($null -eq $code) { $code = 0 }
  return [pscustomobject]@{ Code = [int]$code; Output = @($out) }
}

# Same, but output goes straight to the console (downloads, pulls, pip).
function Invoke-LlmNativeLive {
  param([string]$Exe, [string[]]$Arguments = @())
  $ErrorActionPreference = 'Continue'
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { Write-LlmWarn "$Exe was not found."; return 9009 }
  try {
    & $Exe @Arguments
    $code = $LASTEXITCODE
  } catch {
    Write-LlmWarn "$_"
    $code = 9009
  }
  if ($null -eq $code) { $code = 0 }
  return [int]$code
}

function Test-LlmAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-LlmAdmin([string]$What) {
  if (-not (Test-LlmAdmin)) {
    Stop-LlmStack "$What needs Administrator. Right-click Windows Terminal or PowerShell, choose 'Run as administrator', and run the same command there."
  }
}

function Test-LlmUrl([string]$Url, [int]$TimeoutSec = 3) {
  $r = Invoke-LlmNative 'curl.exe' @('-s', '-o', 'NUL', '--max-time', "$TimeoutSec", $Url)
  return ($r.Code -eq 0)
}

function Wait-LlmUrl([string]$Url, [int]$Seconds, [string]$Label) {
  for ($i = 0; $i -lt $Seconds; $i++) {
    if (Test-LlmUrl $Url) { Write-LlmOk "$Label is answering."; return $true }
    Start-Sleep -Seconds 1
  }
  Write-LlmWarn "$Label is not answering after $Seconds seconds."
  return $false
}

function ConvertTo-LlmDouble([string]$Text) {
  $v = 0.0
  $ok = [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
  if ($ok) { return $v }
  return $null
}

function Format-LlmNumber([double]$Value, [int]$Decimals = 1) {
  return $Value.ToString("F$Decimals", [Globalization.CultureInfo]::InvariantCulture)
}

function Write-LlmTextFile([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Read-LlmTextLines([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $t = [IO.File]::ReadAllText($Path)
  return @($t.Replace("`r`n", "`n").Split("`n"))
}

# ===========================================================================
# MODEL CATALOGUE
# ===========================================================================
# Rows identical to Linux-Local-LLM-Stack v1.0.0 (generation 3.4.0).
function Get-LlmDefaultCatalogText {
  $g = $Script:CatalogGeneration
  $d = $Script:CatalogDate
  # LF only: a checkout with CRLF line endings would otherwise leak CRs.
  return (Get-LlmDefaultCatalogBody $g $d).Replace("`r`n", "`n")
}

function Get-LlmDefaultCatalogBody([string]$g, [string]$d) {
  return @"
# ===========================================================================
# Model catalogue for llmstack-windows.ps1
# ===========================================================================
#
# Last-Updated: $d
# Catalogue-Generation: $g
#
# Last-Updated is when a person last reviewed this file; the script grades
# staleness from it. Catalogue-Generation records which built-in catalogue
# this file descends from; -SyncModels offers to replace the file when the
# script ships a newer generation. If you maintain your own catalogue, keep
# the Catalogue-Generation line current to stop that offer.
#
# Local model releases move quickly. Treat this file as a starting point,
# not an authority, and revise it as new models appear. When you do, update
# the Last-Updated line above; the script reads it and will tell you how
# stale the file has become.
#
# Selection rule used by the script
# -----------------------------------------------------------------------
# Within each role, the largest entry that passes all three gates wins:
#   1. SIZE_GB fits the budget: $($Script:VramBudgetPct) percent of the largest usable
#      GPU's VRAM, or $($Script:RamBudgetPct) percent of system RAM without one.
#   2. The machine has at least MIN_RAM_GB of system RAM.
#   3. Dense entries only, and only without a discrete GPU: estimated
#      RAM bandwidth can generate at $($Script:DenseMinTps) tok/s or better. MoE
#      entries are exempt.
# Because the largest passing entry wins, keep size tracking quality within
# a role, and do not list several quantizations of the same model.
#
# Why architecture matters without a GPU
# -----------------------------------------------------------------------
# On a CPU, token generation is limited by memory bandwidth. A dense
# model reads every parameter for every token. A mixture-of-experts model
# reads only its active experts, so it generates far faster while still
# needing the full weight set resident in memory. Gate 3 is what keeps
# large dense models off machines too slow to drive them. A model that
# fits in a discrete GPU's VRAM is fast either way, so gate 3 is off there.
#
# The VERIFIED column
# -----------------------------------------------------------------------
# yes  the tag was confirmed to exist in the Ollama registry
# no   the tag is plausible but unconfirmed and may fail to pull
#
# Check current tags at https://ollama.com/library and correct this file.
#
# Format: MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
# ===========================================================================
# --- Light (fallback for the smallest machines) ----------------------------
4|granite4.2:3b|2.2|dense|light|yes|IBM Granite 4.2 3B. Tiny and fast, with a thinking mode. The floor: fits machines under 8 GB, such as small VMs.
# --- Daily drivers ---------------------------------------------------------
8|qwen3.5:4b|3.4|dense|daily|yes|Qwen 3.5 4B. Strongest general model under 5 GB. Text and image input.
16|gemma4:12b|7.6|dense|daily|yes|Google Gemma 4 12B. Strong all-rounder for 16 GB machines. Multimodal.
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. The strong MoE that fits a 24 GB budget.
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast even on a CPU. Multimodal. Needs 32 GB of RAM or more.
# --- Reasoning -------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|reasoning|yes|Qwen 3.5 4B with its thinking mode.
16|gemma4:12b|7.6|dense|reasoning|yes|Gemma 4 12B. Strong maths and reasoning for its size.
24|gemma4:26b-a4b-it-qat|16|moe|reasoning|yes|Gemma 4 26B MoE. Reasoning on machines too slow for a dense 27B.
32|qwen3.8:27b|18|dense|reasoning|yes|Qwen 3.8 27B. Top small open model on independent indexes. Dense: fits a 24 GB GPU; on a CPU only fast memory clears the speed gate. Uses many tokens.
# --- Coding ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|coding|yes|Qwen 3.5 4B. Best coding option under 5 GB.
16|qwen3.5:9b|6.6|dense|coding|yes|Qwen 3.5 9B. Stronger agentic coding than Gemma 4 12B.
24|devstral-small-2:24b|15|dense|coding|yes|Mistral Devstral Small 2 24B. Strong agentic coding. Dense: best on a 24 GB GPU.
32|qwen3.6:35b-a3b-coding|23|moe|coding|yes|Qwen 3.6 35B MoE with its coding sampling preset. Same weights as the daily tag.
# --- Vision ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|vision|yes|Qwen 3.5 4B. Image input on the smallest machines.
16|gemma4:12b|7.6|dense|vision|yes|Gemma 4 12B. Image input.
24|gemma4:26b-a4b-it-qat|16|moe|vision|yes|Gemma 4 26B MoE. Image input.
32|qwen3.6:35b-a3b|23|moe|vision|yes|Qwen 3.6 35B MoE. Leads Gemma 4 26B on vision evals.

"@
}

# The catalogue lives in %ProgramData%\llmstack, writable by Administrators
# only. Read-only modes run without elevation and without a catalogue on
# disk use the built-in text in memory and write nothing.
$Script:CatalogInMemory = $false

function Test-LlmDataWritable {
  if (Test-LlmAdmin) { return $true }
  try {
    if (-not (Test-Path -LiteralPath $Script:DataRoot)) { return $false }
    $probe = Join-Path $Script:DataRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch { return $false }
}

function Initialize-LlmCatalog {
  if (Test-Path -LiteralPath $Script:CatalogPath) { $Script:CatalogInMemory = $false; return }
  if (Test-LlmDataWritable) {
    Write-LlmLog "Writing the default model catalogue to $($Script:CatalogPath)"
    Write-LlmTextFile $Script:CatalogPath (Get-LlmDefaultCatalogText)
    $Script:CatalogInMemory = $false
  } else {
    $Script:CatalogInMemory = $true
    Write-LlmLog "No catalogue at $($Script:CatalogPath) yet; using the built-in one (installing writes it)."
  }
}

function Get-LlmCatalogLines {
  if ($Script:CatalogInMemory -or -not (Test-Path -LiteralPath $Script:CatalogPath)) {
    return @((Get-LlmDefaultCatalogText).Replace("`r`n", "`n").Split("`n"))
  }
  return Read-LlmTextLines $Script:CatalogPath
}

# One data row as an object, or $null for comments and blank lines.
function ConvertFrom-LlmCatalogLine([string]$Line) {
  if ($Line -match '^\s*#' -or $Line -match '^\s*$') { return $null }
  $f = $Line.Split('|')
  while ($f.Count -lt 7) { $f += '' }
  $notes = ($f[6..($f.Count - 1)] -join '|').Trim()
  return [pscustomobject]@{
    MinRam   = $f[0].Trim()
    Tag      = $f[1].Trim()
    Size     = $f[2].Trim()
    Arch     = $f[3].Trim()
    Role     = $f[4].Trim()
    Verified = $f[5].Trim()
    Notes    = $notes
  }
}

function Get-LlmCatalogRows {
  $rows = @()
  foreach ($l in (Get-LlmCatalogLines)) {
    $r = ConvertFrom-LlmCatalogLine $l
    if ($null -ne $r) { $rows += $r }
  }
  return $rows
}

function Get-LlmCatalogHeaderValue([string]$Key) {
  foreach ($l in (Get-LlmCatalogLines)) {
    if ($l -match ('^# ' + [regex]::Escape($Key) + ':\s*(\S+)')) { return $Matches[1] }
  }
  return ''
}
function Get-LlmCatalogDate { return (Get-LlmCatalogHeaderValue 'Last-Updated') }
function Get-LlmCatalogGeneration { return (Get-LlmCatalogHeaderValue 'Catalogue-Generation') }

# True if dotted version $A is older than $B.
function Test-LlmVersionLess([string]$A, [string]$B) {
  $x = $A.Split('.'); $y = $B.Split('.')
  $n = [Math]::Max($x.Count, $y.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $xi = 0; $yi = 0
    if ($i -lt $x.Count) { [void][int]::TryParse($x[$i], [ref]$xi) }
    if ($i -lt $y.Count) { [void][int]::TryParse($y[$i], [ref]$yi) }
    if ($xi -lt $yi) { return $true }
    if ($xi -gt $yi) { return $false }
  }
  return $false
}

# True when the catalogue on disk does not descend from the built-in
# generation: its marker is missing or older.
function Test-LlmCatalogPredatesBuiltin {
  $g = Get-LlmCatalogGeneration
  if (-not $g) { return $true }
  return (Test-LlmVersionLess $g $Script:CatalogGeneration)
}

function Get-LlmCatalogAgeDays {
  $d = Get-LlmCatalogDate
  if (-not $d) { return $null }
  $dt = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($d, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return $null }
  return [int][Math]::Floor(((Get-Date).Date - $dt.Date).TotalDays)
}

function Show-LlmCatalogAge {
  $d = Get-LlmCatalogDate
  if (-not $d) {
    Write-LlmWarn "The catalogue has no readable 'Last-Updated:' line."
    Write-LlmLine '    Add one in the form:  # Last-Updated: YYYY-MM-DD'
    return
  }
  $age = Get-LlmCatalogAgeDays
  if ($null -eq $age) { Write-LlmWarn "Could not parse the catalogue date '$d'. Expected YYYY-MM-DD."; return }
  Write-LlmLine ''
  Write-LlmLine "Model catalogue last updated: $d ($age days ago)"
  if ($age -ge $Script:CatalogStaleDays) {
    Write-LlmLine ''
    Write-LlmLine "  This catalogue is over $($Script:CatalogStaleDays) days old and is very likely stale."
    Write-LlmLine '  Local model releases move fast; better options almost certainly'
    Write-LlmLine '  exist now. Review https://ollama.com/library, edit'
    Write-LlmLine "  $($Script:CatalogPath), and bump its Last-Updated line."
  } elseif ($age -ge $Script:CatalogWarnDays) {
    Write-LlmLine ''
    Write-LlmLine "  Worth a look. Over $($Script:CatalogWarnDays) days old, so newer models may be a"
    Write-LlmLine '  better fit for this machine. See https://ollama.com/library'
  } else {
    Write-LlmLine '  Recent enough. No action needed.'
  }
  Write-LlmLine ''
}

function Backup-LlmCatalog {
  if ($Script:CatalogInMemory) { return }
  Copy-Item -LiteralPath $Script:CatalogPath -Destination ($Script:CatalogPath + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
}

# Write the catalogue, or a file beside it. With the catalogue in memory
# (read-only use) nothing is written.
function Save-LlmCatalogText([string]$Path, [string]$Text) {
  if ($Script:CatalogInMemory -or -not (Test-LlmDataWritable)) { Stop-LlmStack 'Changing the catalogue needs Administrator. Run this again from an elevated PowerShell.' }
  Write-LlmTextFile $Path $Text
}

# ===========================================================================
# MODEL REGISTRY VALIDATION & CATALOGUE REFRESH (from the macOS script)
# ===========================================================================
# Every function here is FAIL-SOFT: a network error, timeout, or any status
# other than 200/404 is "unknown" and never changes the live catalogue.
function Get-LlmHttpStatus([string]$Url, [int]$TimeoutSec = 8) {
  $r = Invoke-LlmNative 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', "$TimeoutSec", '-H', "Accept: $($Script:RegistryAccept)", $Url)
  $code = ($r.Output -join '').Trim()
  if ($code -notmatch '^\d{3}$') { return '000' }
  return $code
}

# Echoes LIVE, DEAD, or UNKNOWN.
function Get-LlmRegistryStatus([string]$Tag) {
  $i = $Tag.IndexOf(':')
  if ($i -lt 1) { return 'UNKNOWN' }
  $name = $Tag.Substring(0, $i); $ver = $Tag.Substring($i + 1)
  switch (Get-LlmHttpStatus "$($Script:RegistryBase)/$name/manifests/$ver") {
    '200' { return 'LIVE' }
    '404' { return 'DEAD' }
    default { return 'UNKNOWN' }
  }
}

# True if the registry answers at all (one cheap probe of a known tag).
function Test-LlmRegistryReachable {
  $c = Get-LlmHttpStatus "$($Script:RegistryBase)/llama3.3/manifests/70b"
  return ($c -eq '200' -or $c -eq '404')
}

function Get-LlmCatalogFamilies {
  $f = @()
  foreach ($r in (Get-LlmCatalogRows)) { $f += $r.Tag.Split(':')[0] }
  return @($f | Sort-Object -Unique)
}

function Get-LlmCatalogTags { return @(Get-LlmCatalogRows | ForEach-Object { $_.Tag }) }

function Format-LlmCatalogRow($R, [string]$Verified) {
  return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $R.MinRam, $R.Tag, $R.Size, $R.Arch, $R.Role, $Verified, $R.Notes)
}

# Part A: validate every tag. With -Fix, correct the VERIFIED column in the
# live file (200 -> yes, 404 -> no) after a backup. Always fail-soft.
function Test-LlmCatalogTags([switch]$Fix) {
  Initialize-LlmCatalog
  if (-not (Test-LlmRegistryReachable)) {
    Write-LlmWarn 'Cannot reach the Ollama registry. Skipping tag validation.'
    Write-LlmLine '    The existing catalogue is unchanged; this is not an error.'
    return
  }
  $live = 0; $dead = 0; $unknown = 0; $changed = 0
  $out = New-Object Collections.Generic.List[string]
  Write-LlmLog 'Validating catalogue tags against the Ollama registry'
  foreach ($l in (Get-LlmCatalogLines)) {
    $r = ConvertFrom-LlmCatalogLine $l
    if ($null -eq $r) { $out.Add($l); continue }
    $v = $r.Verified
    switch (Get-LlmRegistryStatus $r.Tag) {
      'LIVE' { $live++; Write-LlmOk "  LIVE  $($r.Tag)"; if ($v -ne 'yes') { $v = 'yes'; $changed++ } }
      'DEAD' { $dead++; Write-LlmWarn "  DEAD  $($r.Tag)  (404 - retired or renamed)"; if ($v -ne 'no') { $v = 'no'; $changed++ } }
      default { $unknown++; Write-LlmLine "  ????  $($r.Tag)  (registry unreachable for this tag)" }
    }
    $out.Add((Format-LlmCatalogRow $r $v))
  }
  Write-LlmLine ''
  Write-LlmLine "Validation summary: $live live, $dead dead, $unknown unknown."
  if ($Fix -and $changed -gt 0 -and -not $Script:CatalogInMemory) {
    Backup-LlmCatalog
    Save-LlmCatalogText $Script:CatalogPath (($out -join "`n").TrimEnd("`n") + "`n")
    Write-LlmOk "Corrected the VERIFIED column on $changed entries. Backup kept."
  } elseif ($dead -gt 0) {
    Write-LlmLine 'Run -RefreshCatalog to produce a cleaned proposal you can review.'
  }
}

# Part B-lite: confirmed new "family:tag" variants of catalogue families.
function Find-LlmFamilyVariants {
  $existing = Get-LlmCatalogTags
  $found = @()
  foreach ($fam in (Get-LlmCatalogFamilies)) {
    foreach ($base in $Script:ProbeSizes) {
      foreach ($suffix in @('', '-instruct')) {
        $cand = "${fam}:$base$suffix"
        if ($existing -contains $cand) { continue }
        if ((Get-LlmRegistryStatus $cand) -eq 'LIVE') { $found += $cand }
      }
    }
  }
  return $found
}

# Part B-full (-Discover): scrape ollama.com/library for new family names.
# Fragile HTML, so wholly fail-soft. Every name is manifest-confirmed.
function Find-LlmNewFamilies {
  $r = Invoke-LlmNative 'curl.exe' @('-s', '--max-time', '15', 'https://ollama.com/library')
  $html = $r.Output -join "`n"
  if ($r.Code -ne 0 -or -not $html) {
    Write-LlmWarn 'Could not fetch the library index; skipping discovery.'
    return @()
  }
  $known = Get-LlmCatalogFamilies
  $names = @([regex]::Matches($html, 'href="/library/([a-zA-Z0-9._-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $found = @()
  foreach ($n in $names) {
    if ($known -contains $n) { continue }
    if ((Get-LlmRegistryStatus "${n}:latest") -eq 'LIVE') { $found += $n }
  }
  return $found
}

# Part B/C core: write models.catalog.proposed beside the live file. Walks
# the live file in order: comments pass through, rows are re-validated in
# place (dead ones commented out), and new candidates are appended only as
# "# REVIEW:" comments, never as live rows. Leaves Last-Updated alone.
function New-LlmCatalogProposal([switch]$DoDiscover) {
  Initialize-LlmCatalog
  $proposed = $Script:CatalogPath + '.proposed'
  if (-not (Test-LlmRegistryReachable)) {
    Write-LlmWarn 'Cannot reach the Ollama registry. No proposal was written.'
    Write-LlmLine '    Try again when the network can reach registry.ollama.ai.'
    return
  }
  Write-LlmLog 'Building a catalogue proposal (live file is not touched)'
  $live = 0; $dead = 0; $added = 0
  $out = New-Object Collections.Generic.List[string]
  $lines = @(Get-LlmCatalogLines)
  # Drop the trailing empty element a final newline leaves.
  if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
  foreach ($l in $lines) {
    $r = ConvertFrom-LlmCatalogLine $l
    if ($null -eq $r) { $out.Add($l); continue }
    switch (Get-LlmRegistryStatus $r.Tag) {
      'LIVE' { $live++; $out.Add((Format-LlmCatalogRow $r 'yes')) }
      'DEAD' { $dead++; $out.Add('# DEAD (404 at registry, review/remove): ' + (Format-LlmCatalogRow $r 'no')) }
      default { $out.Add((Format-LlmCatalogRow $r $r.Verified)) }
    }
  }
  $cands = @(Find-LlmFamilyVariants)
  if ($DoDiscover) { foreach ($f in (Find-LlmNewFamilies)) { $cands += "${f}:latest" } }
  $current = (Get-LlmCatalogLines) -join "`n"
  foreach ($c in $cands) {
    if (-not $c) { continue }
    if ($current.Contains("# REVIEW: REVIEW|$c|")) { continue }
    if (-not $out.Contains($Script:ReviewHeader)) { $out.Add($Script:ReviewHeader) }
    $out.Add("# REVIEW: REVIEW|$c|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.")
    $added++
  }
  Save-LlmCatalogText $proposed (($out -join "`n") + "`n")
  $Script:ProposalBuilt = $true
  Write-LlmLine ''
  Write-LlmOk "Wrote proposal: $proposed"
  Write-LlmLine "Summary: $live live, $dead dead, $added new suggestion(s) added as `"# REVIEW:`" comments."
  Write-LlmLine ''
  Write-LlmLine 'Suggestions never become live rows on their own: set every REVIEW'
  Write-LlmLine 'field and delete the leading "# REVIEW: " to adopt one.'
  Write-LlmLine ''
  Write-LlmLine 'Compare against the live file:'
  Write-LlmLine "  Compare-Object (Get-Content '$($Script:CatalogPath)') (Get-Content '$proposed')"
  Write-LlmLine 'Apply it with -RefreshCatalogApply, or by hand (elevated):'
  Write-LlmLine "  Move-Item -Force '$proposed' '$($Script:CatalogPath)'"
  Write-LlmLine ''
}

# Part C: apply a proposal built in this run, after a diff, backup and yes.
# Confirming the diff is a human review, so Last-Updated is stamped here.
function Invoke-LlmCatalogApply([switch]$DoDiscover) {
  New-LlmCatalogProposal -DoDiscover:$DoDiscover
  $proposed = $Script:CatalogPath + '.proposed'
  if (-not $Script:ProposalBuilt -or -not (Test-Path -LiteralPath $proposed)) {
    Write-LlmWarn 'No new proposal was built, so nothing was applied.'
    return
  }
  Write-LlmLine ''
  $diff = Compare-Object (Read-LlmTextLines $Script:CatalogPath) (Read-LlmTextLines $proposed)
  foreach ($d in $diff) {
    if ($d.SideIndicator -eq '=>') { Write-LlmLine "+ $($d.InputObject)" Green } else { Write-LlmLine "- $($d.InputObject)" Red }
  }
  if (Confirm-Llm 'Replace the live catalogue with this proposal?') {
    Backup-LlmCatalog
    $today = Get-Date -Format 'yyyy-MM-dd'
    $text = ((Read-LlmTextLines $proposed) | ForEach-Object { if ($_ -match '^# Last-Updated:') { "# Last-Updated: $today" } else { $_ } }) -join "`n"
    Save-LlmCatalogText $Script:CatalogPath $text
    Remove-Item -LiteralPath $proposed -Force
    Write-LlmOk 'Catalogue updated and Last-Updated set to today. Backup kept alongside it.'
  } else {
    Write-LlmLog "Left the live catalogue unchanged. Proposal remains at $proposed"
  }
}

# ===========================================================================
# SYSTEM DETECTION
# ===========================================================================
# Each probe is one small function, so tests mock exactly one thing each.
function Get-LlmOsInfo {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  return [pscustomobject]@{ Caption = [string]$os.Caption; Build = [int]$os.BuildNumber; ProductType = [int]$os.ProductType }
}

function Get-LlmArch {
  $a = $env:PROCESSOR_ARCHITEW6432
  if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
  switch ($a) { 'AMD64' { return 'amd64' } 'ARM64' { return 'arm64' } default { return 'unsupported' } }
}

function Get-LlmCpuInfo {
  $p = @(Get-CimInstance -ClassName Win32_Processor)
  $threads = 0
  foreach ($x in $p) { $threads += [int]$x.NumberOfLogicalProcessors }
  $name = 'unknown CPU'
  if ($p.Count -gt 0 -and $p[0].Name) { $name = ([string]$p[0].Name).Trim() }
  return [pscustomobject]@{ Name = $name; Threads = $threads }
}

function Get-LlmRamBytes { return [double](Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory }

# Highest configured DIMM speed in MT/s, or 0 when unreadable (VMs).
function Get-LlmDimmSpeed {
  $best = 0
  foreach ($m in @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue)) {
    $s = 0
    if ($m.ConfiguredClockSpeed) { $s = [int]$m.ConfiguredClockSpeed } elseif ($m.Speed) { $s = [int]$m.Speed }
    if ($s -gt $best) { $best = $s }
  }
  return $best
}

function Get-LlmDiskFreeGB {
  $root = [IO.Path]::GetPathRoot($Script:DataRoot)
  try {
    $d = New-Object IO.DriveInfo($root)
    return [int][Math]::Floor($d.AvailableFreeSpace / 1GB)
  } catch { return 0 }
}

function Get-LlmVideoControllers {
  return @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
    [pscustomobject]@{ Name = [string]$_.Name; PNPDeviceID = [string]$_.PNPDeviceID; ErrorCode = [int]$_.ConfigManagerErrorCode }
  })
}

# Memory size from one display class subkey's values. Newer drivers write a
# QWORD (qwMemorySize); older ones a DWORD or REG_BINARY (MemorySize).
function Get-LlmVramBytes($Props) {
  foreach ($name in @('HardwareInformation.qwMemorySize', 'HardwareInformation.MemorySize')) {
    $prop = $Props.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { continue }
    $v = $prop.Value
    if ($v -is [byte[]]) {
      if ($v.Length -ge 8) { $v = [BitConverter]::ToUInt64($v, 0) } elseif ($v.Length -ge 4) { $v = [BitConverter]::ToUInt32($v, 0) } else { $v = 0 }
    }
    if ([double]$v -gt 0) { return [double]$v }
  }
  return [double]0
}

# VRAM per display adapter from the display class key. AdapterRAM in CIM is
# a 32-bit field capped at 4 GB, so it is never used.
function Get-LlmRegistryVram {
  $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  $list = @()
  foreach ($k in @(Get-ChildItem -Path $class -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
    $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $p) { continue }
    $bytes = Get-LlmVramBytes $p
    $mdid = ''; $desc = ''
    if ($p.PSObject.Properties['MatchingDeviceId']) { $mdid = [string]$p.MatchingDeviceId }
    if ($p.PSObject.Properties['DriverDesc']) { $desc = [string]$p.DriverDesc }
    $list += [pscustomobject]@{ MatchingDeviceId = $mdid; DriverDesc = $desc; Bytes = $bytes }
  }
  return $list
}

# nvidia-smi rows "name, MiB", or empty when it is missing or failing.
function Get-LlmNvidiaSmi {
  $exe = 'nvidia-smi.exe'
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return @() }
  $r = Invoke-LlmNative $exe @('--query-gpu=name,memory.total', '--format=csv,noheader,nounits')
  if ($r.Code -ne 0) { return @() }
  return @($r.Output | Where-Object { $_ -match ',' })
}

function Get-LlmGpuVendor([string]$Pnp) {
  if ($Pnp -match 'VEN_10DE') { return 'nvidia' }
  if ($Pnp -match 'VEN_1002') { return 'amd' }
  if ($Pnp -match 'VEN_8086') { return 'intel' }
  return 'other'
}

# One object per GPU: Vendor, Name, VramMiB, Kind (discrete | integrated |
# unsized), Runtime (ok | no-driver).
function Get-LlmGpus {
  $gpus = @()
  $smi = @(Get-LlmNvidiaSmi)
  foreach ($row in $smi) {
    $parts = $row.Split(',')
    $mib = ConvertTo-LlmDouble ($parts[1].Trim())
    if ($null -eq $mib) { $mib = 0 }
    $gpus += [pscustomobject]@{ Vendor = 'nvidia'; Name = $parts[0].Trim(); VramMiB = [int]$mib; Kind = 'discrete'; Runtime = 'ok' }
  }
  $vram = @(Get-LlmRegistryVram)
  foreach ($c in (Get-LlmVideoControllers)) {
    $vendor = Get-LlmGpuVendor $c.PNPDeviceID
    $noDriver = ($c.ErrorCode -ne 0 -or $c.Name -match 'Basic Display')
    if ($vendor -eq 'nvidia') {
      # With a working driver nvidia-smi already listed these.
      if ($smi.Count -gt 0 -and -not $noDriver) { continue }
      $gpus += [pscustomobject]@{ Vendor = 'nvidia'; Name = $c.Name; VramMiB = 0; Kind = 'discrete'; Runtime = 'no-driver' }
      continue
    }
    $bytes = [double]0
    foreach ($v in $vram) {
      if (($v.MatchingDeviceId -and $c.PNPDeviceID.ToUpper().StartsWith($v.MatchingDeviceId.ToUpper())) -or ($v.DriverDesc -and $v.DriverDesc -eq $c.Name)) {
        if ($v.Bytes -gt $bytes) { $bytes = $v.Bytes }
      }
    }
    $mib = [int][Math]::Floor($bytes / 1MB)
    $rt = 'ok'; if ($noDriver) { $rt = 'no-driver' }
    switch ($vendor) {
      'amd' {
        # A small carve-out is an APU's integrated GPU, not a card.
        $kind = 'discrete'; if ($mib -lt 2048) { $kind = 'integrated' }
        $gpus += [pscustomobject]@{ Vendor = 'amd'; Name = $c.Name; VramMiB = $mib; Kind = $kind; Runtime = $rt }
      }
      'intel' { $gpus += [pscustomobject]@{ Vendor = 'intel'; Name = $c.Name; VramMiB = 0; Kind = 'unsized'; Runtime = $rt } }
      default { $gpus += [pscustomobject]@{ Vendor = 'other'; Name = $c.Name; VramMiB = 0; Kind = 'unsized'; Runtime = $rt } }
    }
  }
  return $gpus
}

function Get-LlmSystem {
  $os = Get-LlmOsInfo
  $cpu = Get-LlmCpuInfo
  $ramGB = [int][Math]::Round((Get-LlmRamBytes) / 1GB)
  if ($ramGB -le 0) { $ramGB = 8 }
  $gpus = @(Get-LlmGpus)
  $pool = $null
  foreach ($g in $gpus) {
    if ($g.Kind -ne 'discrete' -or $g.Runtime -ne 'ok') { continue }
    if ($g.Vendor -ne 'nvidia' -and $g.Vendor -ne 'amd') { continue }
    if ($null -eq $pool -or $g.VramMiB -gt $pool.VramMiB) { $pool = $g }
  }
  $s = [ordered]@{
    OsCaption = $os.Caption; OsBuild = $os.Build; OsProductType = $os.ProductType; Arch = (Get-LlmArch)
    Cpu = $cpu.Name; Threads = $cpu.Threads; RamGB = $ramGB; DiskFreeGB = (Get-LlmDiskFreeGB)
    Gpus = $gpus; PoolKind = 'cpu'; PoolGpu = ''; PoolVramMiB = 0
    BudgetGB = 0.0; DenseCapGB = $null; BandwidthGBs = $null; RamMts = 0; RamMtsSource = ''; Chip = ''
  }
  if ($null -ne $pool -and $pool.VramMiB -gt 0) {
    $s.PoolKind = 'gpu'; $s.PoolGpu = $pool.Name; $s.PoolVramMiB = $pool.VramMiB
    $s.BudgetGB = [Math]::Round($pool.VramMiB / 1024 * $Script:VramBudgetPct / 100, 1)
    $s.Chip = "$($pool.Name), $([Math]::Round($pool.VramMiB / 1024)) GB VRAM"
  } else {
    $s.BudgetGB = [Math]::Round($ramGB * $Script:RamBudgetPct / 100, 1)
    $mts = Get-LlmDimmSpeed
    if ($mts -gt 0) { $s.RamMts = $mts; $s.RamMtsSource = 'read from SMBIOS' }
    else { $s.RamMts = $Script:DefaultRamMts; $s.RamMtsSource = 'assumed; DIMM speed unreadable' }
    $s.BandwidthGBs = [Math]::Round($s.RamMts * 8 * $Script:AssumedChannels / 1000)
    $s.DenseCapGB = [Math]::Round($s.BandwidthGBs * $Script:DenseEfficiencyPct / 100 / $Script:DenseMinTps, 1)
    $s.Chip = "CPU, $ramGB GB RAM"
  }
  return [pscustomobject]$s
}

function Test-LlmOsSupported($Sys) {
  if ($Sys.OsBuild -lt 22000) { return $false }
  if ($Sys.OsProductType -eq 1) { return $true }
  return ($env:LLMSTACK_ALLOW_SERVER -eq '1')
}

# Within each role, the largest entry passing all three gates wins:
#   1. size fits the budget (VRAM share on a GPU, RAM share otherwise)
#   2. system RAM >= MIN_RAM_GB
#   3. dense entries only, and only without a discrete GPU: generation at
#      DenseMinTps or better from estimated RAM bandwidth. MoE is exempt.
function Get-LlmBestForRole($Sys, [string]$Role) {
  $best = $null; $bestSize = -1.0
  foreach ($r in (Get-LlmCatalogRows)) {
    $min = ConvertTo-LlmDouble $r.MinRam
    $size = ConvertTo-LlmDouble $r.Size
    # Unreviewed rows (MIN_RAM or SIZE still "REVIEW") are never picked.
    if ($null -eq $min -or $null -eq $size) { continue }
    if ($r.Role -ne $Role) { continue }
    if ($r.Arch -eq 'dense' -and $null -ne $Sys.DenseCapGB -and $size -gt $Sys.DenseCapGB) { continue }
    if ($min -le $Sys.RamGB -and $size -le $Sys.BudgetGB -and $size -gt $bestSize) {
      $best = $r; $bestSize = $size
    }
  }
  return $best
}

function Get-LlmGpuRuntimeText($G) {
  switch ("$($G.Vendor):$($G.Runtime)") {
    'nvidia:ok' { return 'driver working' }
    'nvidia:no-driver' { return 'NO DRIVER (nvidia-smi not working)' }
    'amd:ok' { return 'driver working' }
    'amd:no-driver' { return 'NO DRIVER' }
    default {
      if ($G.Vendor -eq 'intel') { return 'Vulkan only; VRAM not used for sizing' }
      return 'not used by Ollama'
    }
  }
}

function Show-LlmSystemReport($Sys) {
  $osLine = "  OS:                $($Sys.OsCaption) (build $($Sys.OsBuild), $($Sys.Arch))"
  if (Test-LlmOsSupported $Sys) { Write-LlmLine $osLine } else { Write-LlmLine "$osLine  unsupported: this script targets Windows 11" Yellow }
  Write-LlmLine "  CPU:               $($Sys.Cpu) ($($Sys.Threads) threads)"
  Write-LlmLine "  System RAM:        $($Sys.RamGB) GB"
  Write-LlmLine "  Free disk:         $($Sys.DiskFreeGB) GB (for models, on the $([IO.Path]::GetPathRoot($Script:DataRoot)) drive)"
  if (@($Sys.Gpus).Count -eq 0) {
    Write-LlmLine '  GPUs:              none found'
  } else {
    Write-LlmLine '  GPUs:'
    foreach ($g in $Sys.Gpus) {
      $size = 'VRAM unknown'
      if ($g.VramMiB -gt 0) { $size = (Format-LlmNumber ($g.VramMiB / 1024)) + ' GB' }
      Write-LlmLine "    - $($g.Name)  [$($g.Kind), $size]  $(Get-LlmGpuRuntimeText $g)"
    }
  }
  if ($Sys.PoolKind -eq 'gpu') {
    Write-LlmLine ("  Sizing:            GPU {0}: {1}% of {2} GB VRAM = ~{3} GB for model weights" -f $Sys.PoolGpu, $Script:VramBudgetPct, [Math]::Round($Sys.PoolVramMiB / 1024), (Format-LlmNumber $Sys.BudgetGB))
    Write-LlmLine '                     No dense-speed cap: a model that fits in VRAM runs fast.'
  } else {
    Write-LlmLine ("  Sizing:            CPU and RAM: {0}% of {1} GB = ~{2} GB for model weights" -f $Script:RamBudgetPct, $Sys.RamGB, (Format-LlmNumber $Sys.BudgetGB))
    Write-LlmLine ("  RAM bandwidth:     ~{0} GB/s (DDR {1} MT/s, {2}; {3} channels assumed)" -f $Sys.BandwidthGBs, $Sys.RamMts, $Sys.RamMtsSource, $Script:AssumedChannels)
    Write-LlmLine ("  Dense model cap:   ~{0} GB  (keeps dense models at {1} tok/s or better; MoE exempt)" -f (Format-LlmNumber $Sys.DenseCapGB), $Script:DenseMinTps)
  }
  $v = @($Sys.Gpus | ForEach-Object { "$($_.Vendor):$($_.Runtime)" })
  if ($v -contains 'nvidia:no-driver' -or $v -contains 'amd:no-driver') {
    Write-LlmLine ''
    Write-LlmLine '  A GPU has no working driver, so it is not used for sizing. Install the' Yellow
    Write-LlmLine '  vendor driver: https://www.nvidia.com/drivers or https://www.amd.com/support' Yellow
  }
  if (@($Sys.Gpus | Where-Object { $_.Vendor -eq 'intel' }).Count -gt 0) {
    Write-LlmLine ''
    Write-LlmLine '  Intel GPUs run through Vulkan only, and their memory is shared or not'
    Write-LlmLine '  readable, so they never size the picks. Integrated GPUs also need'
    Write-LlmLine '  OLLAMA_IGPU_ENABLE=1. Use -Benchmark after installing to see real speed.'
  }
}

# ===========================================================================
# CONFIG
# ===========================================================================
function Read-LlmConfig {
  if (-not (Test-Path -LiteralPath $Script:ConfigFile)) { return }
  try {
    $j = [IO.File]::ReadAllText($Script:ConfigFile) | ConvertFrom-Json
    foreach ($k in @($Script:Cfg.Keys)) {
      $p = $j.PSObject.Properties[$k]
      if ($null -ne $p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { $Script:Cfg[$k] = $p.Value }
    }
  } catch {
    Write-LlmWarn "Ignoring an unreadable $($Script:ConfigFile): $_"
  }
}

function Resolve-LlmSettings {
  Read-LlmConfig
  if ($null -ne $Script:Opt.WebUIPort) { Test-LlmPort $Script:Opt.WebUIPort '-WebUIPort'; $Script:Cfg.WebUIPort = $Script:Opt.WebUIPort }
  if ($null -ne $Script:Opt.SearxngPort) {
    Test-LlmPort $Script:Opt.SearxngPort '-SearxngPort'
    $Script:Cfg.SearxngPort = $Script:Opt.SearxngPort; $Script:Cfg.SearxngMode = 'local'
  }
  if ($Script:Cfg.SearxngMode -eq 'local') { $Script:Cfg.SearxngUrl = "http://127.0.0.1:$($Script:Cfg.SearxngPort)" }
  if ($Script:Opt.SearxngUrl) {
    if ($Script:Opt.SearxngUrl -notmatch '^https?://') { Stop-LlmStack '-SearxngUrl must start with http:// or https://' }
    $Script:Cfg.SearxngUrl = $Script:Opt.SearxngUrl.TrimEnd('/'); $Script:Cfg.SearxngMode = 'remote'
  }
  if ($Script:Opt.NoWebSearch) { $Script:Cfg.SearxngMode = 'off' }
  $Script:Cfg.WebUIPort = [int]$Script:Cfg.WebUIPort
  $Script:Cfg.SearxngPort = [int]$Script:Cfg.SearxngPort
}

function Save-LlmConfig {
  $o = [ordered]@{}
  foreach ($k in $Script:Cfg.Keys) { $o[$k] = $Script:Cfg[$k] }
  $o['ScriptVersion'] = $Script:ScriptVersion
  Write-LlmTextFile $Script:ConfigFile (($o | ConvertTo-Json) + "`n")
}

function Test-LlmPort([int]$Port, [string]$Name = 'port') {
  if ($Port -lt 1 -or $Port -gt 65535) { Stop-LlmStack "Invalid port for ${Name}: '$Port' (must be 1-65535)" }
}

# "process (pid)" holding a TCP port, or '' when free.
function Get-LlmPortOwner([int]$Port) {
  $c = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  if ($c.Count -eq 0) { return '' }
  $procId = $c[0].OwningProcess
  $name = 'unknown'
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p) { $name = $p.ProcessName }
  return "$name ($procId)"
}

# ===========================================================================
# RECOMMEND, STATUS, HELP
# ===========================================================================
$Script:Roles = @('daily', 'reasoning', 'coding', 'vision', 'light')

function Show-LlmRecommendations {
  $sys = Get-LlmSystem
  Initialize-LlmCatalog
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  DETECTED SYSTEM'
  Write-LlmLine '==========================================================================='
  Show-LlmSystemReport $sys
  Write-LlmLine '==========================================================================='
  Write-LlmLine 'RECOMMENDED MODELS'
  $found = $false
  foreach ($role in $Script:Roles) {
    $r = Get-LlmBestForRole $sys $role
    if ($null -eq $r) { continue }
    $found = $true
    Write-LlmLine ''
    Write-LlmLine ('  {0,-12} {1}' -f "${role}:", $r.Tag)
    $line = "             $($r.Size) GB, $($r.Arch)"
    if ($r.Verified -ne 'yes') { $line += '  [tag UNVERIFIED]' }
    Write-LlmLine $line
    Write-LlmLine "             $($r.Notes)"
  }
  if (-not $found) { Write-LlmLine ''; Write-LlmLine "  Nothing in the catalogue fits a $(Format-LlmNumber $sys.BudgetGB) GB budget." }
  Show-LlmCatalogAge
  Write-LlmLine "Catalogue file: $($Script:CatalogPath)"
  if ((Test-Path -LiteralPath $Script:CatalogPath) -and (Test-LlmCatalogPredatesBuiltin)) {
    Write-LlmLine ''
    Write-LlmLine "Your catalogue predates the generation $($Script:CatalogGeneration) catalogue built into this"
    Write-LlmLine 'script, so newer models are not considered. -SyncModels offers to'
    Write-LlmLine 'replace it (with a backup).'
  }
  Write-LlmLine 'To pull these picks and review removal of other installed models:'
  Write-LlmLine "  .\$($Script:ScriptName) -SyncModels"
  Write-LlmLine ''
}

function Get-LlmServiceStatus([string]$Name) {
  $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($null -eq $s) { return 'not installed' }
  return [string]$s.Status
}

function Show-LlmStatus {
  $o = 'DOWN'; if (Test-LlmUrl "$($Script:OllamaApi)/api/version") { $o = 'UP' }
  $w = 'DOWN'; if (Test-LlmUrl "http://127.0.0.1:$($Script:Cfg.WebUIPort)") { $w = 'UP' }
  Write-LlmLine ('Ollama      (:11434)   {0,-4}  service: {1}' -f $o, (Get-LlmServiceStatus $Script:OllamaService))
  Write-LlmLine ('Open WebUI  (:{0})    {1,-4}  service: {2}' -f $Script:Cfg.WebUIPort, $w, (Get-LlmServiceStatus $Script:WebUIService))
  switch ($Script:Cfg.SearxngMode) {
    'off' { Write-LlmLine 'SearXNG     (off)      -     web search disabled' }
    default {
      $s = 'DOWN'; if (Test-LlmUrl "$($Script:Cfg.SearxngUrl)/search?q=test&format=json" 5) { $s = 'UP' }
      if ($Script:Cfg.SearxngMode -eq 'local') {
        Write-LlmLine ('SearXNG     (local)    {0,-4}  Docker Desktop container (runs after sign-in)' -f $s)
      } else {
        Write-LlmLine ('SearXNG     (remote)   {0,-4}  {1}' -f $s, $Script:Cfg.SearxngUrl)
      }
    }
  }
  Write-LlmLine ''
}

function Show-LlmHelp {
  $n = $Script:ScriptName
  Write-LlmLine @"
$n v$($Script:ScriptVersion)
NAME
    $n - install and manage a private, self-hosted LLM stack on
    Windows 11 (amd64 and arm64).
SYNOPSIS
    powershell -ExecutionPolicy Bypass -File .\$n [MODE] [OPTIONS]
DESCRIPTION
    Installs Ollama for inference and Open WebUI as the front-end, both as
    Windows services that start at boot with nobody signed in, and SearXNG
    for private web search as a Docker Desktop container. Docker Desktop
    starts only after someone signs in, so web search works from then on.
    Before installing, the script inspects the GPUs, memory and disk, then
    consults a dated model catalogue to recommend models that fit.
    Install, update, uninstall, start and stop need an elevated PowerShell;
    -SyncModels needs one only to replace an outdated catalogue. The
    script is idempotent: re-running is safe and data is never overwritten.
MODES
    -Install        Install or repair the stack. Default.
    -Update         Update Ollama, Open WebUI and SearXNG after backing up
                    Open WebUI data; then check the catalogue.
    -Status         Health of every component. Changes nothing.
    -Recommend      Detected hardware and suitable models. Installs nothing.
    -SyncModels     Bring installed models in line with the recommendations:
                    offers to replace a catalogue whose Catalogue-Generation
                    marker is missing or older than the built-in one, asks
                    which missing picks to pull and which installed picks to
                    update (older build than the registry's), pulls them, and
                    only then offers each other model for removal, one at a
                    time. Every prompt defaults to no. Needs Ollama running.
    -Benchmark      Measure real generation speed (tok/s) and the CPU/GPU
                    split for each installed pick, or for -Model TAG.
    -Uninstall      Guided teardown; asks before removing each piece.
    -CheckModels    Validate catalogue tags against the Ollama registry and
                    correct the VERIFIED column.
    -RefreshCatalog Write models.catalog.proposed: tags re-validated in place,
                    dead ones commented out, newer variants in your families
                    suggested as "# REVIEW:" comments. Never touches the live
                    catalogue. Add -Discover to scan the Ollama library for
                    new families.
    -RefreshCatalogApply
                    As -RefreshCatalog, then replace the live catalogue after
                    a backup and confirmation, setting Last-Updated.
    -Start, -Stop   Start or stop the services (what llmstart and llmstop run).
    -Version        Print the version and exit.
    -Help           Show this text.
OPTIONS
    -SearxngUrl URL Use an existing SearXNG instead of a local container.
    -SearxngPort N  Host port for the local SearXNG. Default 8888.
    -NoWebSearch    Install no SearXNG and turn web search off.
    -WebUIPort N    Port for Open WebUI. Default 8080.
    -Model TAG      Install (or benchmark) this model instead of the pick.
    -NoModel        Install the services without downloading a model.
    -OllamaVersion X.Y.Z
                    Install this Ollama release instead of the latest.
    -Yes            Answer the install's own go-ahead question with yes.
                    Never answers removal, uninstall or Docker Desktop
                    questions.
    -Discover       With the refresh modes: scan for new families.
MODEL SELECTION
    Within each role, the largest catalogue entry passing three gates wins:
      1. Its size fits the budget: $($Script:VramBudgetPct) percent of the largest usable
         GPU's VRAM, or $($Script:RamBudgetPct) percent of system RAM with no usable GPU.
      2. System RAM is at least the entry's MIN_RAM_GB.
      3. Without a discrete GPU, dense models must generate at $($Script:DenseMinTps) tok/s
         or better from estimated RAM bandwidth. MoE models are exempt.
    A usable GPU is an NVIDIA card with a working driver, or an AMD card with
    a working driver and at least 2 GB of VRAM. Intel GPUs never size picks.
FILES
    $($Script:DataRoot)\config.json         settings
    $($Script:DataRoot)\models.catalog      model catalogue, yours to edit
    $($Script:WebUIDataDir)             accounts, chats, secret key
    $($Script:ModelsDir)         downloaded models
    $($Script:DataRoot)\logs                service logs
    $($Script:ProgramRoot)                  Ollama, Open WebUI, tools, commands
NETWORK
    Ollama      127.0.0.1:11434       local only
    Open WebUI  0.0.0.0:8080          firewall rule for the Private profile
    SearXNG     127.0.0.1:8888        local only (local mode)
EXIT STATUS
    0 success; 1 an error occurred and the message says why.
EXAMPLES
    .\$n -Recommend
    .\$n
    .\$n -SearxngUrl http://192.168.1.23:8899
    .\$n -SyncModels
    .\$n -Benchmark
"@
}

# ===========================================================================
# DOWNLOADS
# ===========================================================================
# Metadata for one GitHub release asset: its URL and SHA-256 digest (when
# GitHub publishes one). Tag "latest" means the newest release.
function Get-LlmReleaseAsset([string]$Owner, [string]$Repo, [string]$Tag, [string]$Name) {
  $api = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
  if ($Tag -ne 'latest') { $api = "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" }
  $url = "https://github.com/$Owner/$Repo/releases/latest/download/$Name"
  if ($Tag -ne 'latest') { $url = "https://github.com/$Owner/$Repo/releases/download/$Tag/$Name" }
  $digest = ''
  try {
    $ProgressPreference = 'SilentlyContinue'
    # Unauthenticated API calls are limited to 60 an hour per address;
    # a GITHUB_TOKEN in the environment (as in CI) lifts that.
    $h = @{ 'User-Agent' = 'llmstack-windows' }
    if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $rel = Invoke-RestMethod -Uri $api -TimeoutSec 30 -Headers $h
    foreach ($a in @($rel.assets)) {
      if ($a.name -ne $Name) { continue }
      $url = [string]$a.browser_download_url
      $p = $a.PSObject.Properties['digest']
      if ($null -ne $p -and $p.Value) { $digest = ([string]$p.Value) -replace '^sha256:', '' }
    }
  } catch {
    Write-LlmWarn "Could not read release details for $Owner/$Repo ($_). Downloading without a checksum."
  }
  return [pscustomobject]@{ Url = $url; Sha256 = $digest }
}

function Save-LlmDownload([string]$Url, [string]$Dest, [string]$Sha256 = '') {
  $args2 = @('-fL', '--retry', '3', '--max-time', '3600', '-o', $Dest, $Url)
  if ([Console]::IsOutputRedirected) { $args2 = @('-sS') + $args2 } else { $args2 = @('--progress-bar') + $args2 }
  $code = Invoke-LlmNativeLive 'curl.exe' $args2
  if ($code -ne 0) { Stop-LlmStack "Download failed (curl exit $code): $Url" }
  if ($Sha256) {
    $h = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $Sha256.ToLowerInvariant()) {
      Remove-Item -LiteralPath $Dest -Force
      Stop-LlmStack "Checksum mismatch for $Url (expected $Sha256, got $h). The download was deleted."
    }
    Write-LlmOk 'Checksum verified.'
  }
}

# Extract a zip with Windows' bundled tar.exe: far faster than
# Expand-Archive on Windows PowerShell 5.1 for GB-sized archives.
function Expand-LlmZip([string]$Zip, [string]$Dest) {
  if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
  $code = Invoke-LlmNativeLive 'tar.exe' @('-xf', $Zip, '-C', $Dest)
  if ($code -ne 0) { Stop-LlmStack "Could not extract $Zip (tar exit $code)." }
}

function New-LlmTempDir {
  $d = Join-Path ([IO.Path]::GetTempPath()) ('llmstack-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  return $d
}

# Copy the first file named $Name found under $From to $ToDir.
function Copy-LlmFound([string]$From, [string]$Name, [string]$ToDir) {
  $f = Get-ChildItem -LiteralPath $From -Recurse -Filter $Name -File | Select-Object -First 1
  if ($null -eq $f) { Stop-LlmStack "$Name was not in the downloaded archive." }
  Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $ToDir $Name) -Force
}

function Install-LlmShawl {
  if (Test-Path -LiteralPath $Script:ShawlExe) {
    $r = Invoke-LlmNative $Script:ShawlExe @('--version')
    if (($r.Output -join ' ') -match [regex]::Escape($Script:ShawlVersion)) { Write-LlmLog "shawl $($Script:ShawlVersion) present."; return }
  }
  Write-LlmLog "Installing shawl $($Script:ShawlVersion) (Windows service wrapper)"
  $name = "shawl-v$($Script:ShawlVersion)-win64.zip"
  $a = Get-LlmReleaseAsset 'mtkennerly' 'shawl' "v$($Script:ShawlVersion)" $name
  $t = New-LlmTempDir
  try {
    Save-LlmDownload $a.Url (Join-Path $t $name) $a.Sha256
    Expand-LlmZip (Join-Path $t $name) (Join-Path $t 'x')
    Copy-LlmFound (Join-Path $t 'x') 'shawl.exe' $Script:BinDir
  } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-LlmUv {
  if (Test-Path -LiteralPath $Script:UvExe) { Write-LlmLog 'uv present.'; return }
  Write-LlmLog 'Installing uv (Python and package manager)'
  $triple = 'x86_64-pc-windows-msvc'; if ($Script:Sys.Arch -eq 'arm64') { $triple = 'aarch64-pc-windows-msvc' }
  $name = "uv-$triple.zip"
  $a = Get-LlmReleaseAsset 'astral-sh' 'uv' 'latest' $name
  $t = New-LlmTempDir
  try {
    Save-LlmDownload $a.Url (Join-Path $t $name) $a.Sha256
    Expand-LlmZip (Join-Path $t $name) (Join-Path $t 'x')
    Copy-LlmFound (Join-Path $t 'x') 'uv.exe' $Script:BinDir
  } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# ACCESS CONTROL. SIDs, not names, so it works in every display language.
# ===========================================================================
$Script:SidAdmins = '*S-1-5-32-544'
$Script:SidSystem = '*S-1-5-18'
$Script:SidUsers = '*S-1-5-32-545'

function Invoke-LlmIcacls([string[]]$Arguments) {
  $r = Invoke-LlmNative 'icacls.exe' $Arguments
  if ($r.Code -ne 0) { Stop-LlmStack "icacls failed ($($r.Code)): $($r.Output -join ' ')" }
}

function New-LlmDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# %ProgramData%\llmstack: Administrators and SYSTEM full, Users read.
function Set-LlmDataRootAcl {
  Invoke-LlmIcacls @($Script:DataRoot, '/inheritance:r', '/grant:r', "$($Script:SidAdmins):(OI)(CI)F", "$($Script:SidSystem):(OI)(CI)F", "$($Script:SidUsers):(OI)(CI)RX")
}

# ===========================================================================
# SERVICES (shawl)
# ===========================================================================
function Test-LlmService([string]$Name) { return ($null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)) }

function Remove-LlmService([string]$Name) {
  if (-not (Test-LlmService $Name)) { return }
  Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
  [void](Invoke-LlmNative 'sc.exe' @('delete', $Name))
  for ($i = 0; $i -lt 30; $i++) {
    if (-not (Test-LlmService $Name)) { return }
    Start-Sleep -Seconds 1
  }
  Stop-LlmStack "The service $Name is marked for deletion but still exists. Close Services (services.msc) and any Event Viewer windows, then re-run."
}

# (Re)create a service that runs $Exe through shawl, under its own virtual
# account (NT SERVICE\<name>), starting automatically with restart on
# failure. Recreated each run so a changed setting always takes effect.
function Install-LlmService {
  param([string]$Name, [string]$Display, [string]$Description, [string]$Exe, [string[]]$ExeArgs,
        [string[]]$Environment = @(), [string]$Cwd = '', [string]$DependsOn = '')
  Remove-LlmService $Name
  $a = @('add', '--name', $Name, '--restart', '--stop-timeout', '10000', '--kill-process-tree', '--log-dir', $Script:LogDir)
  if ($Cwd) { $a += @('--cwd', $Cwd) }
  foreach ($e in $Environment) { $a += @('--env', $e) }
  if ($DependsOn) { $a += @('--dependencies', $DependsOn) }
  $a += '--'; $a += $Exe; $a += $ExeArgs
  $r = Invoke-LlmNative $Script:ShawlExe $a
  if ($r.Code -ne 0) { Stop-LlmStack "shawl could not create $Name ($($r.Code)): $($r.Output -join ' ')" }
  foreach ($cmd in @(
      @('config', $Name, 'start=', 'auto', 'obj=', "NT SERVICE\$Name", 'DisplayName=', $Display),
      @('description', $Name, $Description),
      @('failure', $Name, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/5000'))) {
    $r = Invoke-LlmNative 'sc.exe' $cmd
    if ($r.Code -ne 0) { Stop-LlmStack "sc.exe $($cmd[0]) $Name failed ($($r.Code)): $($r.Output -join ' ')" }
  }
}

function Start-LlmService([string]$Name) {
  try { Start-Service -Name $Name } catch { Stop-LlmStack "Could not start $Name ($_). Logs: $($Script:LogDir)" }
}

# ===========================================================================
# OLLAMA
# ===========================================================================
function Get-LlmOllamaExe {
  if (Test-Path -LiteralPath $Script:OllamaExe) { return $Script:OllamaExe }
  $c = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $Script:OllamaExe
}

function Invoke-LlmOllama([string[]]$Arguments) { return (Invoke-LlmNative (Get-LlmOllamaExe) $Arguments) }

# Pulls one model with live progress and returns ollama's exit code. Ctrl-C
# stops the pipeline: PowerShell then skips catch blocks but still runs
# finally, so "not done and no ordinary error" there means an interruption.
function Invoke-LlmGuardedPull([string]$Tag, [string]$InterruptMessage) {
  $done = $false; $failed = $false
  try {
    $code = Invoke-LlmNativeLive (Get-LlmOllamaExe) @('pull', $Tag)
    $done = $true
    return $code
  } catch {
    $failed = $true
    throw
  } finally {
    if (-not $done -and -not $failed) { Write-LlmWarn $InterruptMessage }
  }
}

function Get-LlmInstalledOllamaVersion {
  if (-not (Test-Path -LiteralPath $Script:OllamaExe)) { return '' }
  $r = Invoke-LlmNative $Script:OllamaExe @('-v')
  $m = [regex]::Match(($r.Output -join ' '), '\d+\.\d+\.\d+[^\s]*')
  if ($m.Success) { return $m.Value }
  return ''
}

# The Ollama desktop app starts its own server at sign-in, competing for
# port 11434. Offer to turn off its autostart (never uninstall it).
function Find-LlmOllamaAppStartup {
  $found = @()
  foreach ($u in @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
    $lnk = Join-Path $u.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'
    if (Test-Path -LiteralPath $lnk) { $found += $lnk }
  }
  return $found
}

function Resolve-LlmOllamaAppConflict {
  $links = @(Find-LlmOllamaAppStartup)
  if ($links.Count -eq 0) { return }
  Write-LlmWarn 'The Ollama desktop app is set to start at sign-in for:'
  foreach ($l in $links) { Write-LlmLine "      $l" }
  Write-LlmLine '    It starts its own Ollama server on port 11434, which is this stack''s'
  Write-LlmLine '    port. The app itself keeps working against the service; only its'
  Write-LlmLine '    autostart is turned off. The shortcut is renamed, not deleted.'
  if (Confirm-Llm 'Turn off the Ollama app''s autostart?') {
    foreach ($l in $links) { Rename-Item -LiteralPath $l -NewName 'Ollama.lnk.disabled-by-llmstack' -Force }
    Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-LlmOk 'Autostart turned off.'
  } else {
    Write-LlmLog 'Leaving it. If the app starts first, the service cannot bind port 11434.'
  }
}

function Install-LlmOllama([switch]$Force) {
  $have = Get-LlmInstalledOllamaVersion
  $pinOk = (-not $Script:Opt.OllamaVersion) -or ($have -eq $Script:Opt.OllamaVersion)
  if ($have -and -not $Force -and $pinOk) {
    Write-LlmLog "Ollama $have present."
  } else {
    $tag = 'latest'; if ($Script:Opt.OllamaVersion) { $tag = "v$($Script:Opt.OllamaVersion)" }
    $zips = @("ollama-windows-$($Script:Sys.Arch).zip")
    # AMD cards need the ROCm libraries, shipped separately (amd64 only).
    if ($Script:Sys.Arch -eq 'amd64' -and @($Script:Sys.Gpus | Where-Object { $_.Vendor -eq 'amd' }).Count -gt 0) { $zips += 'ollama-windows-amd64-rocm.zip' }
    $t = New-LlmTempDir
    try {
      foreach ($z in $zips) {
        Write-LlmLog "Downloading $z ($tag). The main archive is about 1.5 GB."
        $a = Get-LlmReleaseAsset 'ollama' 'ollama' $tag $z
        Save-LlmDownload $a.Url (Join-Path $t $z) $a.Sha256
      }
      if (Test-LlmService $Script:OllamaService) { Stop-Service -Name $Script:OllamaService -Force -ErrorAction SilentlyContinue }
      # Replace, never overlay: stale libraries from an older release break it.
      if (Test-Path -LiteralPath $Script:OllamaDir) { Remove-Item -LiteralPath $Script:OllamaDir -Recurse -Force }
      foreach ($z in $zips) { Expand-LlmZip (Join-Path $t $z) $Script:OllamaDir }
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    Write-LlmOk "Ollama $(Get-LlmInstalledOllamaVersion) installed to $($Script:OllamaDir)."
  }
  New-LlmDirectory $Script:ModelsDir
  Install-LlmService -Name $Script:OllamaService -Display 'llmstack Ollama' `
    -Description 'Ollama inference server for llmstack-windows.ps1 (loopback only).' `
    -Exe $Script:OllamaExe -ExeArgs @('serve') -Cwd $Script:OllamaDir `
    -Environment @('OLLAMA_HOST=127.0.0.1:11434', "OLLAMA_MODELS=$($Script:ModelsDir)")
  # The virtual account exists only once its service does.
  Invoke-LlmIcacls @($Script:ModelsDir, '/grant', "NT SERVICE\$($Script:OllamaService):(OI)(CI)M")
  Invoke-LlmIcacls @($Script:LogDir, '/grant', "NT SERVICE\$($Script:OllamaService):(OI)(CI)M")
  Start-LlmService $Script:OllamaService
  if (-not (Wait-LlmUrl "$($Script:OllamaApi)/api/version" 60 'Ollama')) {
    Stop-LlmStack "Ollama did not start. See the logs in $($Script:LogDir)"
  }
}

# ===========================================================================
# OPEN WEBUI
# ===========================================================================
function Get-LlmPythonVersion {
  # PyTorch publishes Windows-on-Arm wheels for Python 3.12 only.
  if ($Script:Sys.Arch -eq 'arm64') { return '3.12' }
  return '3.11'
}

function Invoke-LlmUv([string[]]$Arguments) {
  $saved = @{}
  $vars = @{ UV_PYTHON_INSTALL_DIR = $Script:PythonDir; UV_CACHE_DIR = $Script:UvCacheDir; UV_PYTHON_PREFERENCE = 'only-managed'; UV_NO_PROGRESS = '1' }
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
  try { return (Invoke-LlmNativeLive $Script:UvExe $Arguments) }
  finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
}

# CPU build of torch first, from PyTorch's CPU index: otherwise Open WebUI's
# dependencies pull multi-GB CUDA wheels it does not need (open-webui#29490).
# Then upgrade only open-webui, so the resolver keeps that torch.
function Install-LlmWebUIPackages {
  $py = Join-Path $Script:VenvDir 'Scripts\python.exe'
  if ((Invoke-LlmUv @('pip', 'install', '--python', $py, '--upgrade', 'torch', '--index-url', 'https://download.pytorch.org/whl/cpu')) -ne 0) { return $false }
  if ((Invoke-LlmUv @('pip', 'install', '--python', $py, '--upgrade-package', 'open-webui', 'open-webui')) -ne 0) { return $false }
  return $true
}

function New-LlmSecretKey {
  $b = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-LlmQueryUrl { return "$($Script:Cfg.SearxngUrl.TrimEnd('/'))/search?q=<query>" }

function Install-LlmWebUI {
  Install-LlmUv
  if (-not (Test-Path -LiteralPath (Join-Path $Script:VenvDir 'Scripts\python.exe'))) {
    $pv = Get-LlmPythonVersion
    Write-LlmLog "Creating a Python $pv virtualenv with uv (Open WebUI supports 3.11-3.12 only)"
    if ((Invoke-LlmUv @('venv', '--python', $pv, $Script:VenvDir)) -ne 0) { Stop-LlmStack 'uv could not create the virtualenv.' }
  }
  Write-LlmLog 'Installing Open WebUI into the virtualenv. This is large and takes several minutes.'
  if (-not (Install-LlmWebUIPackages)) { Stop-LlmStack 'Installing Open WebUI failed; see the pip output above.' }
  New-LlmDirectory $Script:WebUIDataDir
  # Open WebUI reads .webui_secret_key from its working directory when
  # WEBUI_SECRET_KEY is unset. A file keeps the key out of the service's
  # command line and registry settings, which any user can read.
  if (Test-Path -LiteralPath $Script:SecretFile) {
    Write-LlmLog 'Reusing the existing Open WebUI secret key.'
  } else {
    Write-LlmLog 'Generating a persistent Open WebUI secret key'
    Write-LlmTextFile $Script:SecretFile (New-LlmSecretKey)
  }
  $search = 'true'; if ($Script:Cfg.SearxngMode -eq 'off') { $search = 'false' }
  $envs = @(
    "DATA_DIR=$($Script:WebUIDataDir)",
    "HF_HOME=$(Join-Path $Script:WebUIDataDir 'cache\huggingface')",
    "OLLAMA_BASE_URL=$($Script:OllamaApi)",
    "ENABLE_WEB_SEARCH=$search",
    'PYTHONUTF8=1')
  if ($Script:Cfg.SearxngMode -ne 'off') { $envs += @('WEB_SEARCH_ENGINE=searxng', "SEARXNG_QUERY_URL=$(Get-LlmQueryUrl)") }
  Install-LlmService -Name $Script:WebUIService -Display 'llmstack Open WebUI' `
    -Description 'Open WebUI for llmstack-windows.ps1.' `
    -Exe (Join-Path $Script:VenvDir 'Scripts\open-webui.exe') `
    -ExeArgs @('serve', '--host', '0.0.0.0', '--port', "$($Script:Cfg.WebUIPort)") `
    -Cwd $Script:WebUIDataDir -Environment $envs -DependsOn $Script:OllamaService
  $acct = "NT SERVICE\$($Script:WebUIService)"
  # Data folder: no access for ordinary users; the secret key lives here.
  Invoke-LlmIcacls @($Script:WebUIDataDir, '/inheritance:r', '/grant:r', "$($Script:SidAdmins):(OI)(CI)F", "$($Script:SidSystem):(OI)(CI)F", "${acct}:(OI)(CI)M")
  Invoke-LlmIcacls @($Script:LogDir, '/grant', "${acct}:(OI)(CI)M")
  # Open WebUI rewrites its static folder in site-packages at every start.
  $static = Join-Path $Script:VenvDir 'Lib\site-packages\open_webui\static'
  if (Test-Path -LiteralPath $static) { Invoke-LlmIcacls @($static, '/grant', "${acct}:(OI)(CI)M") }
  Set-LlmFirewallRule
  Start-LlmService $Script:WebUIService
}

function Set-LlmFirewallRule {
  Get-NetFirewallRule -DisplayName $Script:FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName $Script:FirewallRule -Direction Inbound -Protocol TCP -LocalPort $Script:Cfg.WebUIPort -Profile Private -Action Allow | Out-Null
  Write-LlmOk "Firewall: Open WebUI port $($Script:Cfg.WebUIPort) allowed on Private networks."
}

# ===========================================================================
# SEARXNG (Docker Desktop)
# ===========================================================================
function Get-LlmDockerDesktopExe { return (Join-Path $Script:ProgramFilesDir 'Docker\Docker\Docker Desktop.exe') }
function Get-LlmDockerExe {
  $p = Join-Path $Script:ProgramFilesDir 'Docker\Docker\resources\bin\docker.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  $c = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return ''
}
function Test-LlmDockerRunning {
  $d = Get-LlmDockerExe
  if (-not $d) { return $false }
  return ((Invoke-LlmNative $d @('info', '--format', '{{.OSType}}')).Code -eq 0)
}

function Write-LlmSearxngSettings {
  if (Test-Path -LiteralPath $Script:SearxngSettings) { Write-LlmLog 'SearXNG settings present; keeping them.'; return }
  Write-LlmLog 'Writing SearXNG settings (private instance: JSON on, limiter off)'
  Write-LlmTextFile $Script:SearxngSettings @"
use_default_settings: true
server:
  secret_key: "$(New-LlmSecretKey)"
  # A private instance needs no rate limiter, and so no Valkey.
  limiter: false
  image_proxy: true
search:
  # Open WebUI queries SearXNG for JSON; without it web search returns 403.
  formats:
    - html
    - json
"@
}

function Write-LlmCompose {
  $vol = $Script:SearxngDir.Replace('\', '/')
  Write-LlmTextFile $Script:ComposeFile @"
# Written by llmstack-windows.ps1; regenerated on every install.
name: llmstack
services:
  searxng:
    image: $($Script:SearxngImage)
    container_name: llmstack-searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:$($Script:Cfg.SearxngPort):8080"
    environment:
      SEARXNG_BASE_URL: "http://127.0.0.1:$($Script:Cfg.SearxngPort)/"
    volumes:
      - "${vol}:/etc/searxng"
"@
}

# Local web search without Docker Desktop: ask now, before Open WebUI and
# config.json are written, so both reflect the answer. Before 1.0.1 the
# question came after Open WebUI was configured for local search, so a no
# left web search switched on but broken. -Yes never answers this.
$Script:InstallDockerDesktop = $false
function Request-LlmDockerDesktop {
  $Script:InstallDockerDesktop = $false
  if ($Script:Cfg.SearxngMode -ne 'local') { return }
  if (Test-Path -LiteralPath (Get-LlmDockerDesktopExe)) { return }
  Write-LlmWarn 'Local web search needs Docker Desktop, which is not installed.'
  Write-LlmLine '    Docker Desktop runs SearXNG in a Linux container. It needs WSL 2 and'
  Write-LlmLine '    hardware virtualisation, downloads about 600 MB, may need a restart or'
  Write-LlmLine '    sign-out, and starts only when someone signs in. It is free for personal'
  Write-LlmLine '    use and small businesses under the Docker Subscription Service Agreement:'
  Write-LlmLine '    https://www.docker.com/legal/docker-subscription-service-agreement/'
  if (Confirm-Llm 'Download and install Docker Desktop now?') { $Script:InstallDockerDesktop = $true; return }
  $Script:Cfg.SearxngMode = 'off'
  Write-LlmLog 'Web search is off.'
  Write-LlmLine "    To turn on local search later, re-run with -SearxngPort $($Script:Cfg.SearxngPort) (it asks about"
  Write-LlmLine '    Docker Desktop again), or use -SearxngUrl.'
}

# Returns $true when SearXNG is up (or not wanted), $false when it will be
# finished on a later run.
function Install-LlmSearxng {
  if ($Script:Cfg.SearxngMode -ne 'local') { return $true }
  Write-LlmSearxngSettings
  Write-LlmCompose
  if (-not (Test-Path -LiteralPath (Get-LlmDockerDesktopExe))) {
    if (-not $Script:InstallDockerDesktop) {
      Write-LlmWarn 'Docker Desktop is not installed, so local SearXNG cannot start. Re-run the installer to be asked about installing it.'
      return $false
    }
    $arch = 'amd64'; if ($Script:Sys.Arch -eq 'arm64') { $arch = 'arm64' }
    $t = New-LlmTempDir
    try {
      $inst = Join-Path $t 'DockerDesktopInstaller.exe'
      Save-LlmDownload "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe" $inst
      Write-LlmLog 'Running the Docker Desktop installer (several minutes)'
      $p = Start-Process -FilePath $inst -ArgumentList @('install', '--quiet', '--accept-license') -Wait -PassThru
      if ($p.ExitCode -ne 0) { Write-LlmWarn "The Docker Desktop installer exited with $($p.ExitCode)."; return $false }
    } finally { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    Write-LlmOk 'Docker Desktop installed.'
    Write-LlmLine '    Restart or sign out and back in, start Docker Desktop once to finish its'
    Write-LlmLine '    setup, then re-run this installer to start SearXNG.'
    return $false
  }
  if (-not (Test-LlmDockerRunning)) {
    Write-LlmLog 'Starting Docker Desktop (as the signed-in user) and waiting up to 180 seconds'
    # Through explorer.exe, so it does not inherit this elevated token.
    Start-Process -FilePath 'explorer.exe' -ArgumentList @("`"$(Get-LlmDockerDesktopExe)`"")
    $up = $false
    for ($i = 0; $i -lt 180 -and -not $up; $i += 3) { Start-Sleep -Seconds 3; $up = Test-LlmDockerRunning }
    if (-not $up) {
      Write-LlmWarn 'Docker Desktop did not become ready. Start it, then re-run this installer to start SearXNG.'
      return $false
    }
  }
  Write-LlmLog 'Starting the SearXNG container. The first start downloads the image.'
  $code = Invoke-LlmNativeLive (Get-LlmDockerExe) @('compose', '-f', $Script:ComposeFile, 'up', '-d', '--remove-orphans')
  if ($code -ne 0) { Write-LlmWarn "docker compose failed ($code)."; return $false }
  [void](Wait-LlmUrl "$($Script:Cfg.SearxngUrl)/search?q=test&format=json" 60 'SearXNG')
  return $true
}

# ===========================================================================
# COMMANDS AND PATH
# ===========================================================================
function Add-LlmMachinePath([string]$Dir) {
  $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $parts = @($p.Split(';') | Where-Object { $_ })
  if ($parts -notcontains $Dir) { [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'Machine') }
  if (@($env:Path.Split(';')) -notcontains $Dir) { $env:Path = "$env:Path;$Dir" }
}

function Remove-LlmMachinePath([string]$Dir) {
  $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $parts = @($p.Split(';') | Where-Object { $_ -and $_ -ne $Dir })
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
}

function Install-LlmCommands {
  if ($PSCommandPath -and ($PSCommandPath -ne $Script:InstalledScript)) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $Script:InstalledScript -Force
  }
  $run = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\' + $Script:ScriptName + '"'
  $cmds = [ordered]@{
    'llmstatus'  = "$run -Status"
    'llmstart'   = "$run -Start"
    'llmstop'    = "$run -Stop"
    'llmupgrade' = "$run -Update %*"
  }
  foreach ($k in $cmds.Keys) {
    $body = "@echo off`r`nrem $k - installed by $($Script:ScriptName)`r`n$($cmds[$k])`r`n"
    [IO.File]::WriteAllText((Join-Path $Script:BinDir "$k.cmd"), $body, (New-Object Text.ASCIIEncoding))
  }
  Add-LlmMachinePath $Script:BinDir
  Add-LlmMachinePath $Script:OllamaDir
}

function Start-LlmStack {
  Assert-LlmAdmin 'Starting the services'
  foreach ($s in @($Script:OllamaService, $Script:WebUIService)) { if (Test-LlmService $s) { Start-Service -Name $s } }
  if ($Script:Cfg.SearxngMode -eq 'local' -and (Test-LlmDockerRunning)) {
    [void](Invoke-LlmNative (Get-LlmDockerExe) @('compose', '-f', $Script:ComposeFile, 'up', '-d'))
  }
  Write-LlmLine 'LLM stack started. Open WebUI needs 30 to 90 seconds before it answers.'
}

function Stop-LlmStackServices {
  Assert-LlmAdmin 'Stopping the services'
  foreach ($s in @($Script:WebUIService, $Script:OllamaService)) { if (Test-LlmService $s) { Stop-Service -Name $s -Force } }
  if ($Script:Cfg.SearxngMode -eq 'local' -and (Test-LlmDockerRunning)) {
    [void](Invoke-LlmNative (Get-LlmDockerExe) @('compose', '-f', $Script:ComposeFile, 'stop'))
  }
  Write-LlmLine 'LLM stack stopped.'
}

# ===========================================================================
# SYNC MODELS
# ===========================================================================
# Brings installed models in line with the recommendations. Order is the
# safety property: every chosen pull must succeed before anything is
# removed. Every change needs a yes; every prompt defaults to no.
function ConvertTo-LlmModelName([string]$Name) { if ($Name.Contains(':')) { return $Name }; return "${Name}:latest" }

# Installed models from `ollama list`: Name (normalised), Id, Size.
function Get-LlmInstalledModels {
  $r = Invoke-LlmOllama @('list')
  if ($r.Code -ne 0) { return $null }
  $list = @()
  foreach ($l in @($r.Output | Select-Object -Skip 1)) {
    $f = @(($l.Trim()) -split '\s+')
    if ($f.Count -lt 2 -or -not $f[0]) { continue }
    $size = ''; if ($f.Count -ge 4) { $size = "$($f[2]) $($f[3])" }
    $list += [pscustomobject]@{ Name = (ConvertTo-LlmModelName $f[0]); Id = $f[1]; Size = $size }
  }
  return ,$list
}

function Test-LlmEmbeddingModel([string]$Name) {
  $r = Invoke-LlmOllama @('show', $Name)
  $in = $false
  foreach ($l in $r.Output) {
    if ($l -match '(?i)capabilities') { $in = $true; continue }
    if ($in -and $l -match '^\s*$') { $in = $false }
    if ($in -and $l -match '(?i)embedding') { return $true }
  }
  return $false
}

# The `ollama list` ID is the first 12 hex digits of the SHA-256 of the
# model's manifest, which the registry serves byte for byte. Empty when the
# manifest could not be fetched.
function Get-LlmRegistryManifestId([string]$Tag) {
  $i = $Tag.IndexOf(':')
  $f = [IO.Path]::GetTempFileName()
  try {
    $r = Invoke-LlmNative 'curl.exe' @('-s', '-f', '--max-time', '15', '-H', "Accept: $($Script:RegistryAccept)", '-o', $f, "$($Script:RegistryBase)/$($Tag.Substring(0, $i))/manifests/$($Tag.Substring($i + 1))")
    if ($r.Code -ne 0 -or (Get-Item -LiteralPath $f).Length -eq 0) { return '' }
    return (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant().Substring(0, 12)
  } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Invoke-LlmSync {
  $sys = Get-LlmSystem
  Initialize-LlmCatalog
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  SYNC MODELS'
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  Pulls the recommended models you choose, then offers each installed'
  Write-LlmLine '  model that is not a current pick for removal. Nothing is removed until'
  Write-LlmLine '  every chosen pull has succeeded. All prompts default to NO.'
  Write-LlmLine '==========================================================================='

  # 1. Ollama must be up: pull and rm both go through it.
  $inst = Get-LlmInstalledModels
  if ($null -eq $inst) { Stop-LlmStack 'Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed.' }
  $instNames = @($inst | ForEach-Object { $_.Name })

  # 2. A catalogue that does not descend from the current built-in one hides
  # newer models from the picks. Judged by the generation marker.
  if (-not $Script:CatalogInMemory -and (Test-LlmCatalogPredatesBuiltin)) {
    $gen = Get-LlmCatalogGeneration
    Write-LlmLine ''
    if (-not $gen) {
      Write-LlmLine 'Your model catalogue has no Catalogue-Generation line, so it predates'
      Write-LlmLine "the generation $($Script:CatalogGeneration) catalogue built into this script, or was built by hand."
    } else {
      Write-LlmLine "Your model catalogue is generation $gen; this script ships generation $($Script:CatalogGeneration)."
    }
    Write-LlmLine '    Picks come from your catalogue, so newer models will not appear'
    Write-LlmLine '    until it is replaced. Replacing it keeps a timestamped backup;'
    Write-LlmLine '    copy any rows you added by hand back from that file afterwards.'
    Write-LlmLine '    If you maintain your own catalogue on purpose, answer no and add'
    Write-LlmLine '    this line to it to stop being asked:'
    Write-LlmLine "      # Catalogue-Generation: $($Script:CatalogGeneration)"
    if (-not (Test-LlmDataWritable)) {
      # Pulls and removals go through the Ollama service; only this needs
      # Administrator, so say so instead of failing after a yes.
      Write-LlmLine '    Replacing it needs Administrator. To be offered the replacement, run'
      Write-LlmLine '    -SyncModels from an elevated PowerShell. Carrying on with your catalogue.'
    } elseif (Confirm-Llm 'Back up your catalogue and replace it with the built-in one?') {
      Backup-LlmCatalog
      Save-LlmCatalogText $Script:CatalogPath (Get-LlmDefaultCatalogText)
      Write-LlmOk 'Catalogue replaced. Backup kept alongside it.'
    } else {
      Write-LlmLog 'Keeping your catalogue.'
    }
  }

  # 3. Current picks, one entry per unique tag with every role it serves.
  $picks = New-Object Collections.Generic.List[object]
  foreach ($role in $Script:Roles) {
    $r = Get-LlmBestForRole $sys $role
    if ($null -eq $r) { continue }
    $tag = ConvertTo-LlmModelName $r.Tag
    $existing = $null
    foreach ($p in $picks) { if ($p.Tag -eq $tag) { $existing = $p } }
    if ($null -ne $existing) { $existing.Roles += ", $role" }
    else { $picks.Add([pscustomobject]@{ Tag = $tag; Size = $r.Size; Arch = $r.Arch; Roles = $role; State = '' }) }
  }
  if ($picks.Count -eq 0) {
    Write-LlmWarn 'Nothing in the catalogue fits this machine, so there is nothing to sync.'
    Write-LlmLine '    Run -Recommend for details.'
    return
  }
  $pickTags = @($picks | ForEach-Object { $_.Tag })

  # An installed pick may be an old build of its tag: compare digests with
  # the registry. Fail-soft: unreachable means "unchecked", never an error.
  $reachable = Test-LlmRegistryReachable
  Write-LlmLine ''
  Write-LlmLine "Current picks for this machine ($($sys.Chip)):"
  foreach ($p in $picks) {
    if ($instNames -notcontains $p.Tag) { $p.State = 'not installed' }
    elseif (-not $reachable) { $p.State = 'unchecked' }
    else {
      $lid = ''; foreach ($m in $inst) { if ($m.Name -eq $p.Tag) { $lid = $m.Id } }
      $rid = Get-LlmRegistryManifestId $p.Tag
      if (-not $rid -or -not $lid) { $p.State = 'unchecked' }
      elseif ($rid -eq $lid) { $p.State = 'current' }
      else { $p.State = 'outdated' }
    }
    Write-LlmLine ('  {0,-30} {1,6} GB  {2,-5}  {3,-13}  {4}' -f $p.Tag, $p.Size, $p.Arch, $p.State, $p.Roles)
  }
  if (-not $reachable) { Write-LlmLine '  (Registry unreachable: installed picks were not checked for newer builds.)' }

  # 4. Choose what to pull or update.
  $sel = @()
  foreach ($p in $picks) {
    if ($p.State -eq 'not installed') {
      if (Confirm-Llm "Pull $($p.Tag) (about $($p.Size) GB) for: $($p.Roles)?") { $sel += [pscustomobject]@{ Tag = $p.Tag; Size = $p.Size; Kind = 'pull' } }
    } elseif ($p.State -eq 'outdated') {
      if (Confirm-Llm "Update $($p.Tag) for: $($p.Roles)? Your build is older than the registry's (download up to $($p.Size) GB).") { $sel += [pscustomobject]@{ Tag = $p.Tag; Size = $p.Size; Kind = 'update' } }
    }
  }
  # Removal candidates: installed, and not any role's current pick.
  $cands = @($instNames | Where-Object { $pickTags -notcontains $_ })
  if ($sel.Count -eq 0 -and $cands.Count -eq 0) {
    Write-LlmLine ''
    Write-LlmLine 'Nothing to do: no pulls or updates chosen and no other models installed.'
    Write-LlmLine ''
    return
  }

  # 5. Old and new coexist until the removals, so check disk up front.
  if ($sel.Count -gt 0) {
    $need = 10.0; foreach ($s in $sel) { $need += (ConvertTo-LlmDouble $s.Size) }
    $need = [Math]::Ceiling($need)
    if ($sys.DiskFreeGB -lt $need) {
      Write-LlmWarn "Only $($sys.DiskFreeGB) GB free; the chosen downloads need about $need GB including 10 GB headroom."
      Stop-LlmStack 'Nothing was changed. To free space first, run -SyncModels again, decline every pull, and answer yes to the removals you want.'
    }
  }

  # 6. Pull everything chosen before removing anything.
  $pulled = @(); $updated = @(); $failed = @(); $removed = @(); $kept = @()
  foreach ($s in $sel) {
    Write-LlmLog "Pulling $($s.Tag) (about $($s.Size) GB). Large downloads take a while."
    $code = Invoke-LlmGuardedPull $s.Tag 'Pull interrupted. Nothing was removed. Re-run to resume the download.'
    if ($code -eq 0) {
      if ($s.Kind -eq 'update') { $updated += $s.Tag } else { $pulled += $s.Tag }
      Write-LlmOk "Pulled $($s.Tag)"
    } else {
      $failed += $s.Tag
      Write-LlmWarn "The pull failed for $($s.Tag)"
    }
  }
  if ($failed.Count -gt 0) {
    Write-LlmWarn 'Some pulls failed, so no models were removed:'
    foreach ($f in $failed) { Write-LlmLine "      $f" }
    Stop-LlmStack 'Check the tag at https://ollama.com/library and your network, then re-run.'
  }

  # 7. Offer each non-pick for removal, one at a time.
  if ($cands.Count -gt 0) {
    Write-LlmLine ''
    Write-LlmLine "$($cands.Count) installed model(s) are not a current pick. Each is offered"
    Write-LlmLine 'for removal separately; pressing Enter keeps it.'
    foreach ($m in $cands) {
      $sz = 'size unknown'; foreach ($x in $inst) { if ($x.Name -eq $m -and $x.Size) { $sz = $x.Size } }
      Write-LlmLine ''
      Write-LlmLine "  $m  ($sz)"
      if (Test-LlmEmbeddingModel $m) {
        Write-LlmLine '  Embedding model. Open WebUI may use it for document search;' Yellow
        Write-LlmLine '  removing it can break uploads and knowledge collections.'
      }
      if (Confirm-Llm "Remove ${m}?") {
        if ((Invoke-LlmOllama @('rm', $m)).Code -eq 0) { $removed += $m; Write-LlmOk "Removed $m" }
        else { $kept += $m; Write-LlmWarn "Could not remove $m" }
      } else { $kept += $m }
    }
  }

  # 8. Summary.
  Write-LlmLine ''
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  SYNC COMPLETE'
  Write-LlmLine '==========================================================================='
  foreach ($pair in @(@('Pulled', $pulled), @('Updated', $updated), @('Removed', $removed), @('Kept, not a current pick', $kept))) {
    Write-LlmLine "  $($pair[0]):"
    if (@($pair[1]).Count -gt 0) { foreach ($x in $pair[1]) { Write-LlmLine "    $x" } } else { Write-LlmLine '    (none)' }
  }
  if ($removed.Count -gt 0) {
    Write-LlmLine ''
    Write-LlmLine '  If a removed model was the default in Open WebUI, choose a new'
    Write-LlmLine '  default there. Existing chats remain readable.'
  }
  Write-LlmLine '==========================================================================='
  Write-LlmLine ''
}

# ===========================================================================
# BENCHMARK
# ===========================================================================
# Measured, not estimated: tok/s from Ollama's eval counters, and the
# CPU/GPU split from /api/ps (size vs size_vram).
function Invoke-LlmGenerate([string]$Tag, [int]$Predict, [string]$Prompt) {
  $body = @{ model = $Tag; prompt = $Prompt; stream = $false; options = @{ num_predict = $Predict; temperature = 0 } } | ConvertTo-Json -Depth 4
  return (Invoke-RestMethod -Uri "$($Script:OllamaApi)/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900)
}

function Get-LlmLoadedModels { return @((Invoke-RestMethod -Uri "$($Script:OllamaApi)/api/ps" -TimeoutSec 10).models) }

function Invoke-LlmBenchmark {
  $sys = Get-LlmSystem
  Initialize-LlmCatalog
  if (-not (Test-LlmUrl "$($Script:OllamaApi)/api/version")) { Stop-LlmStack "Ollama is not answering on $($Script:OllamaApi). Start it with llmstart." }
  $inst = Get-LlmInstalledModels
  $names = @(); if ($null -ne $inst) { $names = @($inst | ForEach-Object { $_.Name }) }
  $tags = @()
  if ($Script:Opt.Model) { $tags = @($Script:Opt.Model) }
  else {
    foreach ($role in $Script:Roles) {
      $r = Get-LlmBestForRole $sys $role
      if ($null -eq $r) { continue }
      $t = ConvertTo-LlmModelName $r.Tag
      if ($names -contains $t -and $tags -notcontains $t) { $tags += $t }
    }
  }
  if ($tags.Count -eq 0) { Write-LlmWarn 'None of the current picks is installed. Pull them with -SyncModels, or name one with -Model.'; return }
  Write-LlmLine ''
  Write-LlmLine 'Benchmark: 128 tokens per model, temperature 0. First load includes loading time,'
  Write-LlmLine 'so each model is warmed up once before it is measured.'
  Write-LlmLine ''
  Write-LlmLine ('  {0,-28} {1,9}  {2,-14} {3}' -f 'MODEL', 'TOK/S', 'PROCESSOR', 'VERDICT')
  $arches = @{}; foreach ($r in (Get-LlmCatalogRows)) { $arches[(ConvertTo-LlmModelName $r.Tag)] = $r.Arch }
  foreach ($t in $tags) {
    try {
      [void](Invoke-LlmGenerate $t 1 'Hi')
      $resp = Invoke-LlmGenerate $t 128 'Write a short paragraph about the history of the bicycle.'
    } catch {
      Write-LlmLine ('  {0,-28} {1,9}  {2,-14} {3}' -f $t, '-', '-', "FAILED: $($_.Exception.Message)")
      continue
    }
    $ec = [double]$resp.eval_count; $ed = [double]$resp.eval_duration
    if ($ed -le 0) { Write-LlmLine ('  {0,-28} {1,9}  {2,-14} {3}' -f $t, '-', '-', 'FAILED: no timing in response'); continue }
    $tps = $ec / ($ed / 1e9)
    $pct = '?'
    foreach ($m in (Get-LlmLoadedModels)) {
      if ((ConvertTo-LlmModelName ([string]$m.name)) -eq (ConvertTo-LlmModelName $t) -and [double]$m.size -gt 0) {
        $pct = [string][Math]::Round([double]$m.size_vram * 100 / [double]$m.size)
      }
    }
    $verdict = 'OK'
    $arch = ''; if ($arches.ContainsKey((ConvertTo-LlmModelName $t))) { $arch = $arches[(ConvertTo-LlmModelName $t)] }
    if ($sys.PoolKind -eq 'gpu' -and $pct -ne '?' -and [int]$pct -lt 100) { $verdict = "SPILLS to CPU ($pct% on GPU): expect a large slowdown" }
    elseif ($arch -eq 'dense' -and $tps -lt $Script:DenseMinTps) { $verdict = "SLOW: below $($Script:DenseMinTps) tok/s" }
    Write-LlmLine ('  {0,-28} {1,9}  {2,-14} {3}' -f $t, (Format-LlmNumber $tps), "$pct% GPU", $verdict)
  }
  Write-LlmLine ''
}

# ===========================================================================
# INSTALL
# ===========================================================================
function Invoke-LlmInstall {
  Resolve-LlmSettings
  Assert-LlmAdmin 'Installing'
  Write-LlmLog 'Preflight'
  $Script:Sys = Get-LlmSystem
  if (-not (Test-LlmOsSupported $Script:Sys)) { Stop-LlmStack "This script supports Windows 11 (build 22000 or later, not Server). Detected: $($Script:Sys.OsCaption), build $($Script:Sys.OsBuild)." }
  if ($Script:Sys.Arch -eq 'unsupported') { Stop-LlmStack 'Unsupported CPU architecture. Supported: x64 (amd64) and ARM64.' }
  foreach ($exe in @('curl.exe', 'tar.exe', 'icacls.exe', 'sc.exe')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Stop-LlmStack "$exe is missing; it ships with Windows 11." }
  }
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  DETECTED SYSTEM'
  Write-LlmLine '==========================================================================='
  Show-LlmSystemReport $Script:Sys
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  Services:           Ollama and Open WebUI start at boot (no sign-in needed)'
  switch ($Script:Cfg.SearxngMode) {
    'local' { Write-LlmLine "  Web search:         SearXNG in Docker Desktop on 127.0.0.1:$($Script:Cfg.SearxngPort) (after sign-in)" }
    'remote' { Write-LlmLine "  Web search:         remote SearXNG at $($Script:Cfg.SearxngUrl)" }
    default { Write-LlmLine '  Web search:         off' }
  }
  Write-LlmLine "  Open WebUI:         port $($Script:Cfg.WebUIPort), allowed through the firewall on Private networks"

  foreach ($pair in @(@($Script:Cfg.WebUIPort, 'python', 'open-webui', '-WebUIPort'), @(11434, 'ollama', 'ollama', ''))) {
    $owner = Get-LlmPortOwner $pair[0]
    if ($owner -and $owner -notmatch $pair[1] -and $owner -notmatch 'shawl') {
      Write-LlmWarn "Port $($pair[0]) is already in use by: $owner"
      if ($pair[3]) { Write-LlmLine "    Free it, or re-run with $($pair[3]) <other-port>." } else { Write-LlmLine '    Free it before installing; Ollama must listen there.' }
    }
  }
  if ($Script:Cfg.SearxngMode -eq 'local') {
    $owner = Get-LlmPortOwner $Script:Cfg.SearxngPort
    if ($owner -and $owner -notmatch 'docker|wslrelay|com.docker') { Write-LlmWarn "Port $($Script:Cfg.SearxngPort) is already in use by: $owner. Free it, or re-run with -SearxngPort." }
  }

  Initialize-LlmCatalog
  $modelTag = ''; $doModel = -not $Script:Opt.NoModel
  if (-not $doModel) { Write-LlmLog 'Skipping the model download (-NoModel).' }
  elseif ($Script:Opt.Model) { $modelTag = $Script:Opt.Model; Write-LlmLog "Using the model given on the command line: $modelTag (fit checks skipped)." }
  else {
    $rec = Get-LlmBestForRole $Script:Sys 'daily'
    if ($null -eq $rec) { $rec = Get-LlmBestForRole $Script:Sys 'light' }
    if ($null -eq $rec) { Write-LlmWarn "No catalogue entry fits a $(Format-LlmNumber $Script:Sys.BudgetGB) GB budget. Installing without a model."; $doModel = $false }
    else {
      $modelTag = $rec.Tag
      Write-LlmLine ''
      Write-LlmLine "Recommended model: $($rec.Tag)  ($($rec.Size) GB, $($rec.Arch))"
      Write-LlmLine "  $($rec.Notes)"
      $want = [Math]::Ceiling((ConvertTo-LlmDouble $rec.Size) + 10)
      if ($Script:Sys.DiskFreeGB -lt $want) { Write-LlmWarn "Only $($Script:Sys.DiskFreeGB) GB free; about $want GB is wanted. Re-run with -NoModel to skip the download." }
    }
  }

  if (-not (Confirm-LlmInstall 'Install the stack as shown above?')) { Write-LlmLog 'Cancelled. Nothing was changed.'; return }
  Request-LlmDockerDesktop
  $Script:InstallStarted = $true

  Resolve-LlmOllamaAppConflict
  foreach ($d in @($Script:ProgramRoot, $Script:BinDir, $Script:DataRoot, $Script:LogDir)) { New-LlmDirectory $d }
  Set-LlmDataRootAcl
  Initialize-LlmCatalog
  Save-LlmConfig
  Install-LlmShawl
  Install-LlmOllama
  Install-LlmWebUI
  $searchReady = Install-LlmSearxng
  Install-LlmCommands

  if ($doModel -and $modelTag) {
    $inst = Get-LlmInstalledModels
    $names = @(); if ($null -ne $inst) { $names = @($inst | ForEach-Object { $_.Name }) }
    if ($names -contains (ConvertTo-LlmModelName $modelTag)) { Write-LlmLog "Model already present: $modelTag" }
    else {
      Write-LlmLog "Pulling $modelTag. This is a large download and will take a while."
      if ((Invoke-LlmGuardedPull $modelTag 'Pull interrupted. Re-run to resume the download.') -eq 0) { Write-LlmOk "Model pulled: $modelTag" }
      else { Write-LlmWarn "The pull failed for $modelTag. Everything else installed; pull it later with: ollama pull $modelTag" }
    }
  }

  Write-LlmLog "Verifying services. Open WebUI's first start takes a few minutes."
  [void](Wait-LlmUrl "http://127.0.0.1:$($Script:Cfg.WebUIPort)" 420 'Open WebUI')
  $Script:InstallStarted = $false
  $hostName = [Environment]::MachineName
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  SETUP COMPLETE'
  Write-LlmLine '==========================================================================='
  Write-LlmLine "  Ollama API:   $($Script:OllamaApi)"
  Write-LlmLine "  Open WebUI:   http://$($hostName):$($Script:Cfg.WebUIPort)"
  switch ($Script:Cfg.SearxngMode) {
    'off' { Write-LlmLine '  Web search:   off' }
    default { Write-LlmLine "  SearXNG:      $($Script:Cfg.SearxngUrl)" }
  }
  Write-LlmLine '  Next steps:'
  Write-LlmLine '    1. Open the Open WebUI address and create the admin account now.'
  Write-LlmLine '       The first account created becomes the owner.'
  Write-LlmLine '    2. Web search is pre-configured for this first launch. After that,'
  Write-LlmLine '       Admin Panel > Settings > Web Search is authoritative.'
  Write-LlmLine '    3. llmstatus, llmstart, llmstop and llmupgrade work in new terminals.'
  Write-LlmLine "    4. .\$($Script:ScriptName) -Benchmark measures real speed on this machine."
  if ($Script:Cfg.SearxngMode -eq 'local') {
    Write-LlmLine '    5. SearXNG runs in Docker Desktop, which starts when someone signs in.' Yellow
    Write-LlmLine '       Keep "Start Docker Desktop when you sign in" on (Settings > General).' Yellow
    if (-not $searchReady) { Write-LlmLine '       SearXNG is not running yet: follow the note above, then re-run.' Yellow }
  }
  Write-LlmLine '==========================================================================='
}

# ===========================================================================
# UPDATE
# ===========================================================================
function Invoke-LlmUpdate {
  Resolve-LlmSettings
  Assert-LlmAdmin 'Updating'
  $Script:Sys = Get-LlmSystem
  Initialize-LlmCatalog
  $backup = ''
  if (Test-Path -LiteralPath $Script:WebUIDataDir) {
    $backup = "$($Script:WebUIDataDir).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-LlmLog "Backing up Open WebUI data to $backup"
    if (Test-LlmService $Script:WebUIService) { Stop-Service -Name $Script:WebUIService -Force -ErrorAction SilentlyContinue }
    try { Copy-Item -LiteralPath $Script:WebUIDataDir -Destination $backup -Recurse -Force }
    catch { Stop-LlmStack "Backup failed ($_). Aborting the update." }
  }
  Write-LlmLog 'Updating Ollama'
  try { Install-LlmOllama -Force } catch { Write-LlmWarn "The Ollama update failed ($_). Re-run the installer." }
  Write-LlmLog 'Updating Open WebUI in the virtualenv'
  if (-not (Install-LlmWebUIPackages)) { Write-LlmWarn "The Open WebUI update failed. Data is safe at $backup. Restarting the existing version." }
  if (Test-LlmService $Script:WebUIService) { Start-Service -Name $Script:WebUIService -ErrorAction SilentlyContinue }
  if ($Script:Cfg.SearxngMode -eq 'local' -and (Test-LlmDockerRunning)) {
    Write-LlmLog 'Updating the SearXNG image'
    [void](Invoke-LlmNativeLive (Get-LlmDockerExe) @('compose', '-f', $Script:ComposeFile, 'pull'))
    [void](Invoke-LlmNativeLive (Get-LlmDockerExe) @('compose', '-f', $Script:ComposeFile, 'up', '-d', '--remove-orphans'))
  }
  Write-LlmLog 'Waiting for services'
  [void](Wait-LlmUrl "http://127.0.0.1:$($Script:Cfg.WebUIPort)" 300 'Open WebUI')
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  UPDATE COMPLETE'
  Write-LlmLine '==========================================================================='
  if ($backup) { Write-LlmLine "  Backup retained at: $backup" } else { Write-LlmLine '  Backup retained at: none (no data yet)' }
  Show-LlmCatalogAge
  Test-LlmCatalogTags -Fix
  $r = Get-LlmBestForRole $Script:Sys 'daily'
  if ($null -ne $r) {
    Write-LlmLine "Current daily pick for this machine: $($r.Tag)"
    Write-LlmLine 'Run -SyncModels to pull picks and update outdated builds.'
    Write-LlmLine ''
  }
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
function Remove-LlmPath([string]$Path) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Invoke-LlmUninstall {
  Resolve-LlmSettings
  Assert-LlmAdmin 'Uninstalling'
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  LLM STACK UNINSTALLER'
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  Every piece this script created is offered for removal one at a'
  Write-LlmLine '  time. All prompts default to NO, so pressing Enter skips a step.'
  Write-LlmLine '  Never touched: GPU drivers, Docker Desktop, and anything you decline.'
  Write-LlmLine '==========================================================================='
  if (-not (Confirm-Llm 'Begin uninstall?')) { Write-LlmLog 'Cancelled. Nothing was changed.'; return }

  Write-LlmLog 'Step 1: Stop and remove the services and the firewall rule'
  if (Confirm-Llm 'Stop and remove the llmstack-openwebui and llmstack-ollama services?') {
    Remove-LlmService $Script:WebUIService
    Remove-LlmService $Script:OllamaService
    Get-NetFirewallRule -DisplayName $Script:FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-LlmLog 'Services removed.'
  } else { Write-LlmWarn 'Skipped. Later steps may fail while services still run.' }

  Write-LlmLog 'Step 2: Remove the SearXNG container and image'
  $docker = Get-LlmDockerExe
  if ($docker -and (Test-Path -LiteralPath $Script:ComposeFile) -and (Test-LlmDockerRunning)) {
    if (Confirm-Llm 'Remove the SearXNG container and its image?') {
      [void](Invoke-LlmNative $docker @('compose', '-f', $Script:ComposeFile, 'down', '--remove-orphans'))
      [void](Invoke-LlmNative $docker @('image', 'rm', $Script:SearxngImage))
      Write-LlmLog 'Removed.'
    } else { Write-LlmLog 'Skipped.' }
  } else { Write-LlmLog 'No running Docker Desktop with the SearXNG container.' }

  Write-LlmLog "Step 3: Remove $($Script:ProgramRoot) (Ollama, Open WebUI, Python, tools, commands)"
  if (Test-Path -LiteralPath $Script:ProgramRoot) {
    if (Confirm-Llm "Delete $($Script:ProgramRoot)?") {
      Remove-LlmMachinePath $Script:BinDir
      Remove-LlmMachinePath $Script:OllamaDir
      Remove-LlmPath $Script:ProgramRoot
      Write-LlmLog 'Removed.'
    } else { Write-LlmLog 'Skipped.' }
  } else { Write-LlmLog 'Not present.' }

  Write-LlmLog 'Step 4: Remove Open WebUI data'
  if (Test-Path -LiteralPath $Script:WebUIDataDir) {
    Write-LlmLine "    $($Script:WebUIDataDir)"
    Write-LlmLine ''
    Write-LlmLine '    *** THIS IS YOUR ACCOUNTS, CHAT HISTORY, UPLOADS AND SETTINGS.' Red
    Write-LlmLine '    *** THIS CANNOT BE UNDONE.' Red
    if (Confirm-Llm 'PERMANENTLY delete all Open WebUI data?') {
      if (Confirm-Llm 'Are you certain? This deletes accounts and chat history.') { Remove-LlmPath $Script:WebUIDataDir; Write-LlmLog 'Data removed.' }
      else { Write-LlmLog 'Skipped on second confirmation.' }
    } else { Write-LlmLog "Skipped. Data preserved at $($Script:WebUIDataDir)" }
  } else { Write-LlmLog 'No data folder.' }
  $backups = @(Get-ChildItem -LiteralPath $Script:DataRoot -Directory -Filter 'open-webui.backup-*' -ErrorAction SilentlyContinue)
  if ($backups.Count -gt 0) {
    foreach ($b in $backups) { Write-LlmLine "    $($b.FullName)" }
    if (Confirm-Llm 'Delete ALL of these Open WebUI backups?') { foreach ($b in $backups) { Remove-LlmPath $b.FullName }; Write-LlmLog 'Backups removed.' }
    else { Write-LlmLog 'Skipped.' }
  }

  Write-LlmLog 'Step 5: Remove downloaded models'
  if (Test-Path -LiteralPath $Script:ModelsDir) {
    $bytes = (Get-ChildItem -LiteralPath $Script:ModelsDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }
    Write-LlmLine "    $($Script:ModelsDir)  ($(Format-LlmNumber ($bytes / 1GB)) GB)"
    if (Confirm-Llm 'Delete all downloaded models?') { Remove-LlmPath (Split-Path -Parent $Script:ModelsDir); Write-LlmLog 'Models removed.' }
    else { Write-LlmLog 'Skipped. Models preserved.' }
  } else { Write-LlmLog 'No model folder.' }

  Write-LlmLog 'Step 6: Remove configuration, catalogue, logs and caches'
  $rest = @(Get-ChildItem -LiteralPath $Script:DataRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'open-webui' -and $_.Name -ne 'ollama' -and $_.Name -notlike 'open-webui.backup-*' })
  if ($rest.Count -gt 0) {
    Write-LlmLine "    In $($Script:DataRoot): $(($rest | ForEach-Object { $_.Name }) -join ', ')"
    Write-LlmLine '    (including any edits you made to the catalogue)'
    if (Confirm-Llm 'Delete these?') { foreach ($x in $rest) { Remove-LlmPath $x.FullName }; Write-LlmLog 'Removed.' }
    else { Write-LlmLog 'Skipped.' }
  } else { Write-LlmLog 'Nothing left.' }
  if ((Test-Path -LiteralPath $Script:DataRoot) -and @(Get-ChildItem -LiteralPath $Script:DataRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item -LiteralPath $Script:DataRoot -Force
  }

  Write-LlmLine '==========================================================================='
  Write-LlmLine '  UNINSTALL COMPLETE'
  Write-LlmLine '==========================================================================='
  Write-LlmLine '  Left in place by design: GPU drivers, Docker Desktop (remove it from'
  Write-LlmLine '  Settings > Apps if nothing else uses it), and anything you answered N to.'
  Write-LlmLine '==========================================================================='
}

# ===========================================================================
# MAIN
# ===========================================================================
function Invoke-LlmMain {
  $Script:AssumeYes = [bool]$Script:Opt.Yes
  $modes = @()
  foreach ($m in @('Install', 'Update', 'Status', 'Recommend', 'SyncModels', 'Benchmark', 'Uninstall', 'CheckModels', 'RefreshCatalog', 'RefreshCatalogApply', 'Start', 'Stop', 'Version', 'Help')) {
    if ($Script:Opt[$m]) { $modes += $m }
  }
  if ($modes.Count -gt 1) { Stop-LlmStack "Choose one mode, not $($modes -join ' and ')." }
  $mode = 'Install'; if ($modes.Count -eq 1) { $mode = $modes[0] }
  if ($Script:Opt.OllamaVersion -and $Script:Opt.OllamaVersion -notmatch '^\d+\.\d+\.\d+(-rc\d+)?$') { Stop-LlmStack "-OllamaVersion must look like 0.35.0, not '$($Script:Opt.OllamaVersion)'" }
  if ($Script:Opt.Model -and $Script:Opt.Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]+)?$') { Stop-LlmStack "-Model must be an Ollama tag such as qwen3.5:4b, not '$($Script:Opt.Model)'" }
  if ($Script:Opt.SearxngUrl -and $Script:Opt.NoWebSearch) { Stop-LlmStack 'Choose -SearxngUrl or -NoWebSearch, not both.' }
  # Every mode, so a bad port is never silently ignored.
  foreach ($k in @('WebUIPort', 'SearxngPort')) { if ($null -ne $Script:Opt[$k]) { Test-LlmPort $Script:Opt[$k] "-$k" } }
  # TLS 1.2 for Invoke-RestMethod on Windows PowerShell 5.1.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  switch ($mode) {
    'Help' { Show-LlmHelp }
    'Version' { Write-Output "$($Script:ScriptName) v$($Script:ScriptVersion)" }
    'Status' { Resolve-LlmSettings; Show-LlmStatus }
    'Recommend' { Resolve-LlmSettings; Show-LlmRecommendations }
    'SyncModels' { Resolve-LlmSettings; Invoke-LlmSync }
    'Benchmark' { Resolve-LlmSettings; Invoke-LlmBenchmark }
    'CheckModels' { Test-LlmCatalogTags -Fix }
    'RefreshCatalog' { New-LlmCatalogProposal -DoDiscover:([bool]$Script:Opt.Discover) }
    'RefreshCatalogApply' { Invoke-LlmCatalogApply -DoDiscover:([bool]$Script:Opt.Discover) }
    'Start' { Resolve-LlmSettings; Start-LlmStack }
    'Stop' { Resolve-LlmSettings; Stop-LlmStackServices }
    'Update' { Invoke-LlmUpdate }
    'Uninstall' { Invoke-LlmUninstall }
    default { Invoke-LlmInstall }
  }
}

# Dot-sourcing (the tests) loads the functions without running anything.
if ($MyInvocation.InvocationName -ne '.') {
  Set-StrictMode -Version 2
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  try {
    Invoke-LlmMain
    exit 0
  } catch {
    $msg = "$($_.Exception.Message)"
    Write-Host ''
    if ($msg.StartsWith('LLMSTACK: ')) {
      Write-Host "ERROR: $($msg.Substring(10))" -ForegroundColor Red
    } else {
      Write-Host "ERROR: $msg" -ForegroundColor Red
      Write-Host "       at $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    }
    if ($Script:InstallStarted) {
      Write-Host '==========================================================' -ForegroundColor Red
      Write-Host 'The install stopped partway. Re-running is safe (the script is idempotent).' -ForegroundColor Red
      Write-Host "Service logs: $($Script:LogDir)" -ForegroundColor Red
      Write-Host '==========================================================' -ForegroundColor Red
    }
    exit 1
  }
}
