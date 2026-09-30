# Pester 6 unit tests for llmstack-windows.ps1. No network, no admin, no
# services: every hardware probe, native command, prompt and registry call
# is mocked, and each test gets its own data folder under $TestDrive.
#
#   Invoke-Pester -Path tests -Output Detailed
#
# Runs on Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII.

BeforeAll {
  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'llmstack-windows.ps1')
  $Script:OptDefault = $Script:Opt.Clone()
  $Script:PathDefault = @{ ProgramRoot = $Script:ProgramRoot; BinDir = $Script:BinDir; InstalledScript = $Script:InstalledScript; ProgramFilesDir = $Script:ProgramFilesDir }

  # Fake hardware read by the probe mocks below.
  function Set-Hw {
    param([int]$RamGB = 64, [int]$Mts = 0, [string[]]$Smi = @(), [object[]]$Ctl = @(), [object[]]$Vram = @(),
          [int]$Build = 26100, [int]$Product = 1, [string]$Arch = 'amd64', [int]$DiskGB = 500)
    $Script:Hw = @{ RamGB = $RamGB; Mts = $Mts; Smi = $Smi; Ctl = $Ctl; Vram = $Vram; Build = $Build; Product = $Product; Arch = $Arch; DiskGB = $DiskGB }
  }
  function New-Ctl([string]$Name, [string]$Ven, [int]$ErrorCode = 0) {
    [pscustomobject]@{ Name = $Name; PNPDeviceID = "PCI\VEN_$Ven&DEV_1234&SUBSYS_00000000&REV_00\4&0&0&0008"; ErrorCode = $ErrorCode }
  }
  function New-Vram([string]$Ven, [double]$MiB, [string]$Desc = '') {
    [pscustomobject]@{ MatchingDeviceId = "pci\ven_$($Ven.ToLower())&dev_1234"; DriverDesc = $Desc; Bytes = $MiB * 1MB }
  }
  # A fresh data folder; every path under it follows.
  function New-Data {
    $Script:DataRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Script:DataRoot | Out-Null
    $Script:ConfigFile = Join-Path $Script:DataRoot 'config.json'
    $Script:CatalogPath = Join-Path $Script:DataRoot 'models.catalog'
    $Script:WebUIDataDir = Join-Path $Script:DataRoot 'open-webui'
    $Script:SecretFile = Join-Path $Script:WebUIDataDir '.webui_secret_key'
    $Script:LogDir = Join-Path $Script:DataRoot 'logs'
    $Script:ModelsDir = Join-Path $Script:DataRoot 'ollama\models'
    $Script:SearxngDir = Join-Path $Script:DataRoot 'searxng'
    $Script:SearxngSettings = Join-Path $Script:SearxngDir 'settings.yml'
    $Script:ComposeFile = Join-Path $Script:DataRoot 'compose.yaml'
    $Script:VenvDir = Join-Path $Script:DataRoot 'venv'
    $Script:CatalogInMemory = $false
    $Script:ProposalBuilt = $false
  }
  # Everything the block writes to the console (stream 6), plus a THROWN:
  # line when it stops with an error, as one string.
  function Get-Out([scriptblock]$Sb) {
    & { try { & $Sb } catch { Write-Host "THROWN: $($_.Exception.Message)" } } 6>&1 | Out-String -Width 400
  }
  function Set-Answers([string[]]$A) {
    $Script:Answers = New-Object System.Collections.Generic.Queue[string]
    foreach ($x in $A) { $Script:Answers.Enqueue($x) }
  }
  # ID `ollama list` shows for a build: first 12 hex of SHA-256 of its manifest.
  # The fake registry serves "manifest:<tag>:v1"; stale builds used ":old".
  function Get-FakeId([string]$Tag, [string]$Rev = 'v1') {
    $sha = [Security.Cryptography.SHA256]::Create()
    (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("manifest:${Tag}:$Rev")) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
  }
  function Set-Catalog([string[]]$Lines) { [IO.File]::WriteAllText($Script:CatalogPath, (($Lines -join "`n") + "`n")) }
}

# Pester allows BeforeEach only inside a block, so one Describe wraps them all.
Describe 'llmstack-windows.ps1' {

BeforeEach {
  $Script:Opt = $Script:OptDefault.Clone()
  $Script:Cfg = [ordered]@{ WebUIPort = 8080; SearxngMode = 'local'; SearxngUrl = 'http://127.0.0.1:8888'; SearxngPort = 8888 }
  foreach ($k in $Script:PathDefault.Keys) { Set-Variable -Name $k -Scope Script -Value $Script:PathDefault[$k] }
  $Script:AssumeYes = $false
  New-Data
  Set-Hw
  Set-Answers @()
  $Script:Ollama = @{ Models = @(); Stale = @(); PullFail = @(); Down = $false; Embed = @(); Calls = (New-Object System.Collections.Generic.List[string]) }
  $Script:Live = @()      # tags the fake registry serves; '*' means all
  $Script:RegDown = $false

  Mock Get-LlmOsInfo { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Build = $Script:Hw.Build; ProductType = $Script:Hw.Product } }
  Mock Get-LlmArch { $Script:Hw.Arch }
  Mock Get-LlmCpuInfo { [pscustomobject]@{ Name = 'Test CPU 9000'; Threads = 16 } }
  Mock Get-LlmRamBytes { [double]$Script:Hw.RamGB * 1GB - 250MB }
  Mock Get-LlmDimmSpeed { $Script:Hw.Mts }
  Mock Get-LlmDiskFreeGB { $Script:Hw.DiskGB }
  Mock Get-LlmVideoControllers { $Script:Hw.Ctl }
  Mock Get-LlmRegistryVram { $Script:Hw.Vram }
  Mock Get-LlmNvidiaSmi { $Script:Hw.Smi }
  Mock Test-LlmAdmin { $true }
  Mock Read-LlmAnswer { if ($Script:Answers.Count -gt 0) { $Script:Answers.Dequeue() } else { '' } }

  Mock Get-LlmHttpStatus {
    param([string]$Url)
    if ($Script:RegDown) { return '000' }
    if ($Url -match '/v2/library/([^/]+)/manifests/(.+)$') {
      $tag = "$($Matches[1]):$($Matches[2])"
      if ($Script:Live -contains '*' -or $Script:Live -contains $tag -or $tag -eq 'llama3.3:70b') { return '200' }
      return '404'
    }
    return '000'
  }
  Mock Test-LlmRegistryReachable { -not $Script:RegDown }
  Mock Get-LlmRegistryManifestId { param([string]$Tag) if ($Script:RegDown) { '' } else { Get-FakeId $Tag } }
  Mock Find-LlmNewFamilies { @() }

  Mock Invoke-LlmOllama {
    param([string[]]$Arguments)
    $Script:Ollama.Calls.Add(($Arguments -join ' '))
    switch ($Arguments[0]) {
      'list' {
        if ($Script:Ollama.Down) { return [pscustomobject]@{ Code = 1; Output = @('Error: could not connect to ollama') } }
        $o = @('NAME                      ID              SIZE      MODIFIED')
        foreach ($m in $Script:Ollama.Models) {
          $n = ConvertTo-LlmModelName $m
          $rev = 'v1'; if ($Script:Ollama.Stale -contains $n) { $rev = 'old' }
          $o += "$m    $(Get-FakeId $n $rev)    4.1 GB    2 weeks ago"
        }
        return [pscustomobject]@{ Code = 0; Output = $o }
      }
      'show' {
        if ($Script:Ollama.Embed -contains $Arguments[1]) { return [pscustomobject]@{ Code = 0; Output = @('  Capabilities', '    embedding', '') } }
        return [pscustomobject]@{ Code = 0; Output = @('  Capabilities', '    completion', '') }
      }
      default { return [pscustomobject]@{ Code = 0; Output = @() } }
    }
  }
  # Pulls go through the live runner so their progress shows.
  Mock Invoke-LlmNativeLive {
    param([string[]]$Arguments)
    $Script:Ollama.Calls.Add(($Arguments -join ' '))
    if ($Arguments[0] -eq 'pull' -and $Script:Ollama.PullFail -contains $Arguments[1]) { return 1 }
    return 0
  }
}

# ===========================================================================
Describe 'Script metadata and CLI validation' {
  It 'is ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI)' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) 'llmstack-windows.ps1'))
    @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
  }
  It 'has a header version that matches $ScriptVersion' {
    $text = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'llmstack-windows.ps1'))
    $text | Should -Match ([regex]::Escape("llmstack-windows.ps1  v$($Script:ScriptVersion)"))
  }
  It 'refuses two modes at once' {
    $Script:Opt.Recommend = $true; $Script:Opt.Status = $true
    { Invoke-LlmMain } | Should -Throw -ExpectedMessage '*Choose one mode*'
  }
  It 'validates -OllamaVersion' {
    $Script:Opt.OllamaVersion = 'latest'; $Script:Opt.Version = $true
    { Invoke-LlmMain } | Should -Throw -ExpectedMessage '*must look like 0.35.0*'
  }
  It 'validates -Model' {
    $Script:Opt.Model = 'bad tag!'; $Script:Opt.Version = $true
    { Invoke-LlmMain } | Should -Throw -ExpectedMessage '*must be an Ollama tag*'
  }
  It 'refuses -SearxngUrl with -NoWebSearch' {
    $Script:Opt.SearxngUrl = 'http://x:8888'; $Script:Opt.NoWebSearch = $true; $Script:Opt.Version = $true
    { Invoke-LlmMain } | Should -Throw -ExpectedMessage '*not both*'
  }
  It 'rejects ports out of range' {
    $Script:Opt.WebUIPort = 70000
    { Resolve-LlmSettings } | Should -Throw -ExpectedMessage '*Invalid port*'
  }
  It 'rejects a SearXNG URL without a scheme' {
    $Script:Opt.SearxngUrl = '192.168.1.2:8888'
    { Resolve-LlmSettings } | Should -Throw -ExpectedMessage '*must start with http*'
  }
  It 'resolves settings: config first, then parameters' {
    [IO.File]::WriteAllText($Script:ConfigFile, '{ "WebUIPort": 3000, "SearxngMode": "remote", "SearxngUrl": "http://10.0.0.5:8899", "SearxngPort": 8888 }')
    Resolve-LlmSettings
    $Script:Cfg.WebUIPort | Should -Be 3000
    $Script:Cfg.SearxngMode | Should -Be 'remote'
    $Script:Opt.NoWebSearch = $true
    Resolve-LlmSettings
    $Script:Cfg.SearxngMode | Should -Be 'off'
  }
  It 'prints help naming every mode and option' {
    $out = Get-Out { Show-LlmHelp }
    foreach ($m in @('-Install', '-Update', '-Status', '-Recommend', '-SyncModels', '-Benchmark', '-Uninstall', '-CheckModels',
                     '-RefreshCatalog', '-RefreshCatalogApply', '-SearxngUrl', '-NoWebSearch', '-WebUIPort', '-Model', '-NoModel',
                     '-OllamaVersion', '-Yes', '-Discover')) {
      $out | Should -Match ([regex]::Escape($m))
    }
  }
}

# ===========================================================================
Describe 'Hardware detection and picks' {
  It 'CPU 16 GB DDR5-5600: bandwidth from SMBIOS, dense cap applied' {
    Set-Hw -RamGB 16 -Mts 5600
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'System RAM: +16 GB'
    $out | Should -Match 'RAM bandwidth: +~90 GB/s \(DDR 5600 MT/s, read from SMBIOS'
    $out | Should -Match 'Dense model cap: +~7\.3 GB'
    $out | Should -Match 'CPU and RAM: 70% of 16 GB = ~11\.2 GB'
    $out | Should -Match 'daily: +qwen3\.5:4b'
    $out | Should -Match 'coding: +qwen3\.5:9b'
    $out | Should -Not -Match 'gemma4:12b'
    $out | Should -Match 'GPUs: +none found'
  }
  It 'CPU 64 GB with unreadable DIMM speed assumes DDR4-3200' {
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'DDR 3200 MT/s, assumed'
    $out | Should -Match '~51 GB/s'
    $out | Should -Match 'Dense model cap: +~4\.1 GB'
    $out | Should -Match 'daily: +qwen3\.6:35b-a3b\s'
    $out | Should -Match 'reasoning: +gemma4:26b-a4b-it-qat'
    $out | Should -Match 'coding: +qwen3\.6:35b-a3b-coding'
    $out | Should -Not -Match 'qwen3\.8:27b'
  }
  It '7 GB VM gets only the light pick' {
    Set-Hw -RamGB 7
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'light: +granite4\.2:3b'
    $out | Should -Not -Match 'daily:'
  }
  It 'NVIDIA 24 GB sizes from VRAM with no dense cap, listed once' {
    Set-Hw -RamGB 64 -Smi @('NVIDIA GeForce RTX 4090, 24564') -Ctl @((New-Ctl 'NVIDIA GeForce RTX 4090' '10DE'))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'NVIDIA GeForce RTX 4090 +\[discrete, 24\.0 GB\] +driver working'
    $out | Should -Match 'GPU NVIDIA GeForce RTX 4090: 75% of 24 GB VRAM = ~18\.0 GB'
    $out | Should -Match 'No dense-speed cap'
    $out | Should -Match 'daily: +gemma4:26b-a4b-it-qat'
    $out | Should -Match 'reasoning: +qwen3\.8:27b'
    $out | Should -Match 'coding: +devstral-small-2:24b'
    ([regex]::Matches($out, 'RTX 4090 +\[')).Count | Should -Be 1
  }
  It 'NVIDIA without a driver (Basic Display Adapter) sizes as CPU' {
    Set-Hw -RamGB 32 -Mts 4800 -Ctl @((New-Ctl 'Microsoft Basic Display Adapter' '10DE'))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'NO DRIVER'
    $out | Should -Match 'nvidia\.com/drivers'
    $out | Should -Match 'Sizing: +CPU and RAM'
  }
  It 'AMD 16 GB sizes from the registry VRAM (not the 4 GB AdapterRAM cap)' {
    Set-Hw -RamGB 32 -Ctl @((New-Ctl 'AMD Radeon RX 7800 XT' '1002')) -Vram @((New-Vram '1002' 16368))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'AMD Radeon RX 7800 XT +\[discrete, 16\.0 GB\] +driver working'
    $out | Should -Match 'GPU AMD Radeon RX 7800 XT: 75% of 16 GB VRAM = ~12\.0 GB'
    $out | Should -Match 'daily: +gemma4:12b'
    $out | Should -Match 'coding: +qwen3\.5:9b'
  }
  It 'reads a QWORD VRAM value stored as REG_BINARY' {
    Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = '0000'; PSPath = 'X' }) } -ParameterFilter { $Path -like '*4d36e968*' }
    Mock Get-ItemProperty { [pscustomobject]@{ 'HardwareInformation.qwMemorySize' = [BitConverter]::GetBytes([UInt64](8GB)); MatchingDeviceId = 'pci\ven_1002&dev_73df'; DriverDesc = 'AMD Radeon RX 6700 XT' } }
    $v = @(Get-LlmRegistryVram)
    $v.Count | Should -Be 1
    $v[0].Bytes | Should -Be ([double]8GB)
  }
  It 'AMD APU (512 MB carve-out) is integrated and sizes as CPU' {
    Set-Hw -RamGB 32 -Ctl @((New-Ctl 'AMD Radeon(TM) Graphics' '1002')) -Vram @((New-Vram '1002' 512))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match '\[integrated, 0\.5 GB\]'
    $out | Should -Match 'Sizing: +CPU and RAM'
  }
  It 'Intel GPUs are listed but never size the picks' {
    Set-Hw -RamGB 32 -Ctl @((New-Ctl 'Intel(R) Arc(TM) A770 Graphics' '8086'))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'Arc\(TM\) A770 Graphics +\[unsized, VRAM unknown\]'
    $out | Should -Match 'OLLAMA_IGPU_ENABLE=1'
    $out | Should -Match 'Sizing: +CPU and RAM'
  }
  It 'NVIDIA 12 GB + AMD 24 GB: the larger card sizes' {
    Set-Hw -RamGB 64 -Smi @('NVIDIA GeForce RTX 3060, 12288') -Ctl @((New-Ctl 'NVIDIA GeForce RTX 3060' '10DE'), (New-Ctl 'AMD Radeon RX 7900 XTX' '1002')) -Vram @((New-Vram '1002' 24560))
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'GPU AMD Radeon RX 7900 XTX: 75% of 24 GB'
    $out | Should -Match 'RTX 3060 +\[discrete, 12\.0 GB\]'
  }
  It 'Windows 10 is unsupported' {
    Set-Hw -Build 19045
    (Test-LlmOsSupported (Get-LlmSystem)) | Should -BeFalse
    Get-Out { Show-LlmRecommendations } | Should -Match 'unsupported: this script targets Windows 11'
  }
  It 'Windows Server is unsupported unless LLMSTACK_ALLOW_SERVER=1' {
    Set-Hw -Product 3
    $saved = $env:LLMSTACK_ALLOW_SERVER
    try {
      $env:LLMSTACK_ALLOW_SERVER = ''
      (Test-LlmOsSupported (Get-LlmSystem)) | Should -BeFalse
      $env:LLMSTACK_ALLOW_SERVER = '1'
      (Test-LlmOsSupported (Get-LlmSystem)) | Should -BeTrue
    } finally { $env:LLMSTACK_ALLOW_SERVER = $saved }
  }
  It 'parses decimal sizes the same in a comma-decimal culture' {
    $saved = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
      [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
      ConvertTo-LlmDouble '7.6' | Should -Be 7.6
      Set-Hw -RamGB 16 -Mts 5600
      Get-Out { Show-LlmRecommendations } | Should -Match 'Dense model cap: +~7\.3 GB'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $saved }
  }
  It 'the install refuses an unsupported OS before changing anything' {
    Set-Hw -Build 19045
    Mock Confirm-LlmInstall { $true }
    $out = Get-Out { Invoke-LlmInstall }
    $out | Should -Match 'THROWN: .*supports Windows 11'
    Should -Invoke Confirm-LlmInstall -Times 0
  }
}

# ===========================================================================
Describe 'Model catalogue' {
  It 'ships a well-formed catalogue' {
    $lines = @((Get-LlmDefaultCatalogText).Split("`n"))
    ($lines -match '^# Last-Updated: \d{4}-\d{2}-\d{2}$').Count | Should -Be 1
    ($lines -match "^# Catalogue-Generation: $([regex]::Escape($Script:CatalogGeneration))$").Count | Should -Be 1
    $rows = @($lines | Where-Object { $_ -and $_ -notmatch '^#' })
    $rows.Count | Should -BeGreaterThan 10
    foreach ($r in $rows) {
      $f = $r.Split('|')
      $f.Count | Should -Be 7
      $f[1] | Should -Match '^[a-z0-9][a-z0-9._-]*(/[a-z0-9._-]+)?:[a-z0-9._-]+$'
      $f[3] | Should -BeIn @('moe', 'dense')
      $f[4] | Should -BeIn @('daily', 'reasoning', 'coding', 'vision', 'light')
      $f[5] | Should -BeIn @('yes', 'no')
    }
    @($rows | Where-Object { $_.Split('|')[4] -eq 'daily' -and $_.Split('|')[5] -eq 'yes' }).Count | Should -BeGreaterThan 0
  }
  It 'writes the catalogue once and never overwrites it' {
    [void](Get-Out { Show-LlmRecommendations })
    Test-Path $Script:CatalogPath | Should -BeTrue
    Add-Content -Path $Script:CatalogPath -Value '# my edit'
    [void](Get-Out { Show-LlmRecommendations })
    (Get-Content $Script:CatalogPath) -contains '# my edit' | Should -BeTrue
  }
  It 'uses the built-in catalogue in memory when it cannot write' {
    Mock Test-LlmAdmin { $false }
    Remove-Item $Script:DataRoot -Recurse -Force
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'using the built-in one'
    $out | Should -Match 'daily: +qwen3\.6:35b-a3b\s'
    Test-Path $Script:CatalogPath | Should -BeFalse
  }
  It 'handles a catalogue with no Last-Updated line' {
    Set-Catalog @('32|qwen3.6:35b-a3b|24|moe|daily|yes|x')
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'daily: +qwen3\.6:35b-a3b'
    $out | Should -Match "no readable 'Last-Updated"
    $out | Should -Match 'predates the generation'
  }
  It 'reads CRLF catalogues' {
    [IO.File]::WriteAllText($Script:CatalogPath, "# Last-Updated: 2026-09-30`r`n# Catalogue-Generation: 3.4.0`r`n32|qwen3.6:35b-a3b|24|moe|daily|yes|x`r`n")
    $out = Get-Out { Show-LlmRecommendations }
    $out | Should -Match 'daily: +qwen3\.6:35b-a3b'
    $out | Should -Not -Match 'predates'
  }
  It 'never picks an unreviewed REVIEW row' {
    Set-Catalog @('# Last-Updated: 2026-09-30', 'REVIEW|big:99b|REVIEW|moe|daily|yes|x', '8|small:1b|1|dense|daily|yes|y')
    Get-Out { Show-LlmRecommendations } | Should -Match 'daily: +small:1b'
  }
  It 'grades staleness from Last-Updated' {
    Set-Catalog @("# Last-Updated: $((Get-Date).AddDays(-200).ToString('yyyy-MM-dd'))", '8|small:1b|1|dense|daily|yes|y')
    Get-Out { Show-LlmCatalogAge } | Should -Match 'very likely stale'
  }
}

# ===========================================================================
Describe 'Sync models' {
  # Picks on the default 64 GB CPU machine: qwen3.6:35b-a3b (daily, vision),
  # gemma4:26b-a4b-it-qat (reasoning), qwen3.6:35b-a3b-coding (coding),
  # granite4.2:3b (light).
  It 'pulls only chosen picks and removes only models answered yes, pulls first' {
    $Script:Ollama.Models = @('llama3.3:70b', 'qwen2.5:32b-instruct', 'nomic-embed-text', 'gemma4:26b-a4b-it-qat')
    $Script:Ollama.Embed = @('nomic-embed-text:latest')
    Set-Answers @('y', 'n', 'y', 'y', 'n', 'n')
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Not -Match 'THROWN'
    $c = $Script:Ollama.Calls
    $c | Should -Contain 'pull qwen3.6:35b-a3b'
    $c | Should -Contain 'pull granite4.2:3b'
    $c | Should -Not -Contain 'pull qwen3.6:35b-a3b-coding'
    $c | Should -Not -Contain 'pull gemma4:26b-a4b-it-qat'
    $c | Should -Contain 'rm llama3.3:70b'
    $c | Should -Not -Contain 'rm qwen2.5:32b-instruct'
    $c | Should -Not -Contain 'rm nomic-embed-text:latest'
    $out | Should -Match 'Embedding model'
    $out | Should -Match 'gemma4:26b-a4b-it-qat .* current'
    $lastPull = [array]::LastIndexOf([string[]]$c.ToArray(), 'pull granite4.2:3b')
    $firstRm = [array]::IndexOf([string[]]$c.ToArray(), 'rm llama3.3:70b')
    $lastPull | Should -BeLessThan $firstRm
  }
  It 'a failed pull prevents every removal' {
    $Script:Ollama.Models = @('llama3.3:70b')
    $Script:Ollama.PullFail = @('qwen3.6:35b-a3b')
    Set-Answers @('y', 'y', 'y', 'y', 'y', 'y')
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Match 'THROWN'
    $out | Should -Match 'no models were removed'
    $Script:Ollama.Calls | Should -Not -Contain 'rm llama3.3:70b'
  }
  It 'Ollama not running stops and changes nothing' {
    $Script:Ollama.Down = $true
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Match 'THROWN: Cannot reach Ollama.*Nothing was changed'
    @($Script:Ollama.Calls | Where-Object { $_ -match '^(pull|rm) ' }).Count | Should -Be 0
  }
  It 'a catalogue without a generation marker is replaced only on yes' {
    Set-Catalog @('# Last-Updated: 2026-09-30', '32|qwen3.6:35b-a3b|24|moe|daily|yes|old')
    $Script:Ollama.Models = @('qwen3.6:35b-a3b')
    Set-Answers @('n')
    Get-Out { Invoke-LlmSync } | Should -Match 'no Catalogue-Generation line'
    (Get-Content $Script:CatalogPath) -match '^# Catalogue-Generation:' | Should -BeNullOrEmpty
    Set-Answers @('y', 'n', 'n', 'n')
    $out = Get-Out { Invoke-LlmSync }
    (Get-Content $Script:CatalogPath) -match '^# Catalogue-Generation: ' | Should -Not -BeNullOrEmpty
    @(Get-ChildItem $Script:DataRoot -Filter 'models.catalog.backup-*').Count | Should -Be 1
    $out | Should -Match 'gemma4:26b-a4b-it-qat'
  }
  It 'an older generation is offered; the current one is not' {
    $Script:Ollama.Models = @('qwen3.6:35b-a3b')
    Set-Catalog @('# Last-Updated: 2026-09-30', '# Catalogue-Generation: 3.3.0', '32|qwen3.6:35b-a3b|24|moe|daily|yes|x')
    Set-Answers @('n')
    Get-Out { Invoke-LlmSync } | Should -Match 'is generation 3\.3\.0'
    New-Data
    Set-Catalog @('# Last-Updated: 2020-01-01', "# Catalogue-Generation: $($Script:CatalogGeneration)", '32|qwen3.6:35b-a3b|24|moe|daily|yes|x')
    Get-Out { Invoke-LlmSync } | Should -Not -Match 'Catalogue-Generation line|this script ships generation'
  }
  It 'offers an update for an outdated build and not for a current one' {
    $Script:Ollama.Models = @('qwen3.6:35b-a3b', 'gemma4:26b-a4b-it-qat')
    $Script:Ollama.Stale = @('qwen3.6:35b-a3b')
    Set-Answers @('y', 'n', 'n')
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Match 'qwen3\.6:35b-a3b .* outdated'
    $out | Should -Match 'gemma4:26b-a4b-it-qat .* current'
    $out | Should -Match 'Update qwen3\.6:35b-a3b'
    $out | Should -Not -Match 'Update gemma4'
    $Script:Ollama.Calls | Should -Contain 'pull qwen3.6:35b-a3b'
    $out | Should -Match 'Updated:\s+qwen3\.6:35b-a3b'
  }
  It 'a failed update blocks every removal' {
    $Script:Ollama.Models = @('qwen3.6:35b-a3b', 'llama3.3:70b')
    $Script:Ollama.Stale = @('qwen3.6:35b-a3b')
    $Script:Ollama.PullFail = @('qwen3.6:35b-a3b')
    Set-Answers @('y', 'n', 'n', 'n', 'y')
    Get-Out { Invoke-LlmSync } | Should -Match 'THROWN'
    $Script:Ollama.Calls | Should -Not -Contain 'rm llama3.3:70b'
  }
  It 'an unreachable registry marks picks unchecked and carries on' {
    $Script:Ollama.Models = @('qwen3.6:35b-a3b')
    $Script:Ollama.Stale = @('qwen3.6:35b-a3b')
    $Script:RegDown = $true
    Set-Answers @('n', 'n', 'n')
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Not -Match 'THROWN'
    $out | Should -Match 'qwen3\.6:35b-a3b .* unchecked'
    $out | Should -Match 'Registry unreachable'
    $out | Should -Not -Match 'Update qwen3\.6'
  }
  It 'a disk shortfall stops before any pull' {
    Set-Hw -DiskGB 20
    $Script:Ollama.Models = @('llama3.3:70b')
    Set-Answers @('y', 'y', 'y', 'y', 'y')
    $out = Get-Out { Invoke-LlmSync }
    $out | Should -Match 'THROWN: Nothing was changed'
    @($Script:Ollama.Calls | Where-Object { $_ -match '^(pull|rm) ' }).Count | Should -Be 0
  }
}

# ===========================================================================
Describe 'Catalogue refresh and validation' {
  It 'keeps order, comments dead rows in place, and suggests only as # REVIEW' {
    Set-Catalog @('# Last-Updated: 2026-01-01', '# Catalogue-Generation: 3.4.0', '# --- Daily ---', '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept', '# --- Coding ---', '16|qwen3.6:14b|9|dense|coding|no|dead one')
    $Script:Live = @('qwen3.6:35b-a3b', 'qwen3.6:27b')
    [void](Get-Out { New-LlmCatalogProposal })
    $p = @(Get-Content "$($Script:CatalogPath).proposed")
    $p[[array]::IndexOf($p, '# --- Daily ---') + 1] | Should -Be '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept'
    $p[[array]::IndexOf($p, '# --- Coding ---') + 1] | Should -Match '^# DEAD \(404.*qwen3\.6:14b'
    ($p -match '^# REVIEW: REVIEW\|qwen3\.6:27b\|').Count | Should -Be 1
    ($p -match '^REVIEW\|').Count | Should -Be 0
    $p | Should -Contain '# Last-Updated: 2026-01-01'
    Move-Item "$($Script:CatalogPath).proposed" $Script:CatalogPath -Force
    [void](Get-Out { New-LlmCatalogProposal })
    $p2 = @(Get-Content "$($Script:CatalogPath).proposed")
    ($p2 -match '^# REVIEW: REVIEW\|qwen3\.6:27b\|').Count | Should -Be 1
    ($p2 -match '^# --- Suggested by -RefreshCatalog').Count | Should -Be 1
  }
  It 'stamps Last-Updated only on a confirmed apply' {
    Set-Catalog @('# Last-Updated: 2026-01-01', '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept')
    $Script:Live = @('qwen3.6:35b-a3b')
    Set-Answers @('n')
    [void](Get-Out { Invoke-LlmCatalogApply })
    Get-Content $Script:CatalogPath | Should -Contain '# Last-Updated: 2026-01-01'
    $Script:ProposalBuilt = $false
    Set-Answers @('y')
    [void](Get-Out { Invoke-LlmCatalogApply })
    Get-Content $Script:CatalogPath | Should -Contain "# Last-Updated: $(Get-Date -Format 'yyyy-MM-dd')"
    Test-Path "$($Script:CatalogPath).proposed" | Should -BeFalse
    @(Get-ChildItem $Script:DataRoot -Filter 'models.catalog.backup-*').Count | Should -BeGreaterThan 0
  }
  It 'never applies a leftover proposal when the registry is unreachable' {
    Set-Catalog @('# Last-Updated: 2026-01-01', '32|qwen3.6:35b-a3b|23|moe|daily|yes|kept')
    [IO.File]::WriteAllText("$($Script:CatalogPath).proposed", "# stale`n8|bogus:1b|1|dense|daily|yes|x`n")
    $before = [IO.File]::ReadAllText($Script:CatalogPath)
    $Script:RegDown = $true
    Set-Answers @('y')
    [void](Get-Out { Invoke-LlmCatalogApply })
    [IO.File]::ReadAllText($Script:CatalogPath) | Should -Be $before
  }
  It 'is offline-safe: no proposal and no change' {
    Set-Catalog @('# Last-Updated: 2026-01-01', '32|qwen3.6:35b-a3b|23|moe|daily|no|x')
    $before = [IO.File]::ReadAllText($Script:CatalogPath)
    $Script:RegDown = $true
    Get-Out { Test-LlmCatalogTags -Fix; New-LlmCatalogProposal } | Should -Not -Match 'THROWN'
    Test-Path "$($Script:CatalogPath).proposed" | Should -BeFalse
    [IO.File]::ReadAllText($Script:CatalogPath) | Should -Be $before
  }
  It '-CheckModels corrects the VERIFIED column' {
    Set-Catalog @('# Last-Updated: 2026-01-01', '32|qwen3.6:35b-a3b|23|moe|daily|no|x', '8|gone:1b|1|dense|daily|yes|y')
    $Script:Live = @('qwen3.6:35b-a3b')
    [void](Get-Out { Test-LlmCatalogTags -Fix })
    $c = Get-Content $Script:CatalogPath
    $c | Should -Contain '32|qwen3.6:35b-a3b|23|moe|daily|yes|x'
    $c | Should -Contain '8|gone:1b|1|dense|daily|no|y'
  }
}

# ===========================================================================
Describe 'Status' {
  It 'reports every component down, with the local SearXNG caveat' {
    Mock Test-LlmUrl { $false }
    Mock Get-LlmServiceStatus { 'not installed' }
    Resolve-LlmSettings
    $out = Get-Out { Show-LlmStatus }
    $out | Should -Match 'Ollama +\(:11434\) +DOWN +service: not installed'
    $out | Should -Match 'Open WebUI +\(:8080\) +DOWN'
    $out | Should -Match 'SearXNG +\(local\) +DOWN +Docker Desktop container \(runs after sign-in\)'
  }
  It 'reads the config for ports and remote SearXNG' {
    Mock Test-LlmUrl { $true }
    Mock Get-LlmServiceStatus { 'Running' }
    [IO.File]::WriteAllText($Script:ConfigFile, '{ "WebUIPort": 3000, "SearxngMode": "remote", "SearxngUrl": "http://10.0.0.5:8899" }')
    Resolve-LlmSettings
    $out = Get-Out { Show-LlmStatus }
    $out | Should -Match 'Open WebUI +\(:3000\) +UP +service: Running'
    $out | Should -Match 'SearXNG +\(remote\) +UP +http://10\.0\.0\.5:8899'
  }
}

# ===========================================================================
Describe 'Services and secrets' {
  It 'creates a shawl service under its own virtual account, auto-start, restart on failure' {
    $Script:Native = New-Object System.Collections.Generic.List[string]
    Mock Remove-LlmService { }
    Mock Invoke-LlmNative { param([string]$Exe, [string[]]$Arguments) $Script:Native.Add("$([IO.Path]::GetFileName($Exe)) $($Arguments -join ' ')"); [pscustomobject]@{ Code = 0; Output = @() } }
    Install-LlmService -Name 'llmstack-ollama' -Display 'D' -Description 'X' -Exe 'C:\p\ollama.exe' -ExeArgs @('serve') -Environment @('OLLAMA_HOST=127.0.0.1:11434') -Cwd 'C:\p'
    $shawl = @($Script:Native | Where-Object { $_ -like 'shawl.exe add *' })
    $shawl.Count | Should -Be 1
    $shawl[0] | Should -Match '--name llmstack-ollama --restart'
    $shawl[0] | Should -Match '--kill-process-tree'
    $shawl[0] | Should -Match '--env OLLAMA_HOST=127\.0\.0\.1:11434'
    $shawl[0] | Should -Match '-- C:\\p\\ollama\.exe serve$'
    ($Script:Native -join "`n") | Should -Match 'sc\.exe config llmstack-ollama start= auto obj= NT SERVICE\\llmstack-ollama'
    ($Script:Native -join "`n") | Should -Match 'sc\.exe failure llmstack-ollama .*restart/5000'
  }
  It 'keeps the Open WebUI secret out of the service settings, and reuses it' {
    $Script:Envs = @()
    Mock Install-LlmUv { }
    Mock Invoke-LlmUv { 0 }
    Mock Install-LlmWebUIPackages { $true }
    Mock Invoke-LlmIcacls { }
    Mock Set-LlmFirewallRule { }
    Mock Start-LlmService { }
    New-Item -ItemType File -Path (Join-Path $Script:VenvDir 'Scripts\python.exe') -Force | Out-Null
    Mock Install-LlmService { $Script:Envs = $Environment }
    $Script:Sys = Get-LlmSystem
    Resolve-LlmSettings
    [void](Get-Out { Install-LlmWebUI })
    ($Script:Envs -join ' ') | Should -Not -Match 'SECRET'
    $Script:Envs | Should -Contain 'SEARXNG_QUERY_URL=http://127.0.0.1:8888/search?q=<query>'
    $Script:Envs | Should -Contain 'ENABLE_WEB_SEARCH=true'
    $key = [IO.File]::ReadAllText($Script:SecretFile)
    $key | Should -Match '^[0-9a-f]{64}$'
    [void](Get-Out { Install-LlmWebUI })
    [IO.File]::ReadAllText($Script:SecretFile) | Should -Be $key
  }
  It 'turns web search off with -NoWebSearch' {
    $Script:Envs = @()
    Mock Install-LlmUv { }
    Mock Install-LlmWebUIPackages { $true }
    Mock Invoke-LlmIcacls { }
    Mock Set-LlmFirewallRule { }
    Mock Start-LlmService { }
    New-Item -ItemType File -Path (Join-Path $Script:VenvDir 'Scripts\python.exe') -Force | Out-Null
    Mock Install-LlmService { $Script:Envs = $Environment }
    $Script:Sys = Get-LlmSystem
    $Script:Opt.NoWebSearch = $true
    Resolve-LlmSettings
    [void](Get-Out { Install-LlmWebUI })
    $Script:Envs | Should -Contain 'ENABLE_WEB_SEARCH=false'
    ($Script:Envs -join ' ') | Should -Not -Match 'SEARXNG_QUERY_URL'
  }
  It 'generates 64 hex characters of randomness, differently each time' {
    $a = New-LlmSecretKey; $b = New-LlmSecretKey
    $a | Should -Match '^[0-9a-f]{64}$'
    $a | Should -Not -Be $b
  }
  It 'writes ASCII .cmd commands that call the installed script' {
    $Script:ProgramRoot = Join-Path $TestDrive 'prog'
    $Script:BinDir = Join-Path $Script:ProgramRoot 'bin'
    $Script:InstalledScript = Join-Path $Script:ProgramRoot $Script:ScriptName
    New-Item -ItemType Directory -Path $Script:BinDir -Force | Out-Null
    Mock Add-LlmMachinePath { }
    Mock Copy-Item { }
    Install-LlmCommands
    foreach ($n in @('llmstatus', 'llmstart', 'llmstop', 'llmupgrade')) {
      $f = Join-Path $Script:BinDir "$n.cmd"
      Test-Path $f | Should -BeTrue
      [IO.File]::ReadAllText($f) | Should -Match ([regex]::Escape("..\$($Script:ScriptName)"))
    }
    [IO.File]::ReadAllText((Join-Path $Script:BinDir 'llmstatus.cmd')) | Should -Match ' -Status'
  }
  It 'writes a compose file with SearXNG on loopback only' {
    Resolve-LlmSettings
    Write-LlmCompose
    $c = [IO.File]::ReadAllText($Script:ComposeFile)
    $c | Should -Match '"127\.0\.0\.1:8888:8080"'
    $c | Should -Match 'restart: unless-stopped'
    $c | Should -Not -Match '\\'
  }
  It 'installs no Docker Desktop without an explicit yes, even with -Yes' {
    $Script:AssumeYes = $true
    $Script:ProgramFilesDir = Join-Path $TestDrive 'nopf'
    Mock Save-LlmDownload { }
    Resolve-LlmSettings
    Set-Answers @('')
    $out = Get-Out { [void](Install-LlmSearxng) }
    $out | Should -Match 'needs Docker Desktop'
    $out | Should -Match 'Skipping local SearXNG'
    Should -Invoke Save-LlmDownload -Times 0
  }
}

} # Describe 'llmstack-windows.ps1'
