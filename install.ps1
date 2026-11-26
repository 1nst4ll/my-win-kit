#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit loader: keeps the kit up to date and picks the best menu this PC can run.
.DESCRIPTION
    Works on stock Windows PowerShell 5.1 with nothing else installed.
      0. Self-update: if GitHub main has a newer kit version than this copy, ask once
         ("Update kit 2.3.0 -> 2.4.0? [Y/n]"), download the repo zip into
         %LOCALAPPDATA%\my-win-kit\app\<version>, verify it, and run from there.
         Any failure falls back to this copy. A newer copy already downloaded is
         used without asking.
      1. autoInstallPwsh on (default; this PC's choice in Settings, else
         config/settings.json): install whatever is missing of PowerShell 7
         (winget, fallback: signed MSI from GitHub) and Windows Terminal
         (winget) WITHOUT asking, then relaunch under pwsh (2).
      2. PowerShell 7.4+ present  -> modern menu (src/tui-spectre.ps1) under pwsh.
      3. autoInstallPwsh off, pwsh missing or too old -> ask "Install PowerShell 7
                                     now?" first, then 2.
      4. Declined / failed        -> classic menu (src/tui-classic.ps1) in 5.1.
    If the modern menu cannot load its module (exit 3) it also falls back to the
    classic menu, so a fresh PC is never stuck.
    Quick start: double-click install.cmd, or on any PC (public repo):
        irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex
    Run that way ($PSScriptRoot empty) it downloads the kit into
    %LOCALAPPDATA%\my-win-kit\app\<version> and starts it from there.
.PARAMETER Classic
    Skip detection and open the classic menu.
.PARAMETER DryRun
    Show what would run, install nothing (passed to either menu).
.PARAMETER NoUpdate
    Skip the self-update check (also used when a downloaded copy re-runs itself).
.PARAMETER UpdateAnswer
    Testing: answer for the "update kit?" question (y or n).
.PARAMETER NoPwsh
    Testing: behave as if PowerShell 7 were not installed. Same as
    environment variable MYWINKIT_SIMULATE_NO_PWSH=1.
.PARAMETER NoTerminal
    Testing: behave as if Windows Terminal were not installed. Same as
    MYWINKIT_SIMULATE_WT=absent (MYWINKIT_SIMULATE_WT=present: as if installed).
.PARAMETER WhatIfLoader
    Testing: print the decision (modern / auto-install / offer-install / classic) and exit.
.PARAMETER Answer
    Testing: answer for the "install PowerShell 7?" question (y or n).
.PARAMETER ClassicTestInput
    Testing: passed to the classic menu as -TestInput.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
    Overrides (tests): MYWINKIT_REPO, MYWINKIT_BRANCH, MYWINKIT_RAW_URL (base of
    raw files, or file:///folder), MYWINKIT_ZIP_URL (zip, or file:///kit.zip),
    MYWINKIT_STATE_DIR, MYWINKIT_BOOTSTRAP_ARGS (args for the iex bootstrap),
    MYWINKIT_SIMULATE_INSTALL=ok|fail (PowerShell 7 / Terminal installs report
    that result without running anything).
#>
[CmdletBinding()]
param(
    [switch]$Classic,
    [switch]$DryRun,
    [switch]$NoUpdate,
    [string]$UpdateAnswer,
    [switch]$NoPwsh,
    [switch]$NoTerminal,
    [switch]$WhatIfLoader,
    [string]$Answer,
    [string]$ClassicTestInput
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'my-win-kit' } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$root = $PSScriptRoot
$MinPwsh = [version]'7.4'
$script:HasClassicTI = $PSBoundParameters.ContainsKey('ClassicTestInput')
function Write-Say([string]$Text, [string]$Color = 'Gray') { Write-Host "  $Text" -ForegroundColor $Color }
$Dot = [string][char]0x00B7

# ---------------------------------------------------------------- run log (which front-end ran, and why)
# One file per run in <state dir>\logs. Child menus append to the same file via MYWINKIT_RUNLOG.
$stateDir = if ($env:MYWINKIT_STATE_DIR) { $env:MYWINKIT_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'my-win-kit' }
try {
    $logDir = Join-Path $stateDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    # a re-run of a newer copy (-NoUpdate) keeps writing to the parent's log
    if (-not ($NoUpdate -and $env:MYWINKIT_RUNLOG)) { $env:MYWINKIT_RUNLOG = Join-Path $logDir ('run-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $PID) }
    # keep the newest 30
    Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
function Write-RunLog([string]$Text) {
    try { Add-Content -LiteralPath $env:MYWINKIT_RUNLOG -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Text) -Encoding UTF8 } catch {}
}
Write-RunLog ("loader: Windows PowerShell {0} ({1}), kit {2}, args: {3}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $(if ($root) { $root } else { '(none: irm | iex bootstrap)' }), (($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))

# ---------------------------------------------------------------- self-update / bootstrap from GitHub

$Repo    = if ($env:MYWINKIT_REPO) { $env:MYWINKIT_REPO } else { '1nst4ll/my-win-kit' }
$Branch  = if ($env:MYWINKIT_BRANCH) { $env:MYWINKIT_BRANCH } else { 'main' }
$RawBase = if ($env:MYWINKIT_RAW_URL) { $env:MYWINKIT_RAW_URL.TrimEnd('/') } else { "https://raw.githubusercontent.com/$Repo/$Branch" }
$ZipUrl  = if ($env:MYWINKIT_ZIP_URL) { $env:MYWINKIT_ZIP_URL } else { "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" }
$AppDir  = Join-Path $stateDir 'app'

function Get-KitVersionFromText([string]$Text) {
    $m = [regex]::Match($Text, "KitVersion\s*=\s*'([0-9]+(\.[0-9]+){1,3})'")
    if ($m.Success) { return [version]$m.Groups[1].Value }
    return $null
}
function Get-LocalKitVersion([string]$Dir) {
    try { return Get-KitVersionFromText ([IO.File]::ReadAllText((Join-Path $Dir 'src\core.psm1'))) } catch { return $null }
}
function Get-RemoteKitVersion {
    <# KitVersion of src/core.psm1 on GitHub main (3 s timeout), or $null. #>
    try {
        if ($RawBase -like 'file:*') { $text = [IO.File]::ReadAllText(([Uri]"$RawBase/src/core.psm1").LocalPath) }
        else { $text = (Invoke-WebRequest -Uri "$RawBase/src/core.psm1" -UseBasicParsing -TimeoutSec 3 -UserAgent 'my-win-kit' -Headers @{ 'Cache-Control' = 'no-cache' }).Content }
        return Get-KitVersionFromText $text
    } catch {
        Write-RunLog "update: version check failed ($RawBase): $($_.Exception.Message)"
        return $null
    }
}
function Test-KitCopy([string]$Dir) {
    <# A usable kit folder: required files present, every script parses, catalog.json parses. Returns '' or the problem. #>
    foreach ($req in 'install.ps1', 'src\core.psm1', 'src\tui-spectre.ps1', 'src\tui-classic.ps1', 'config\catalog.json') {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $req))) { return "missing $req" }
    }
    foreach ($fl in (Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($fl.FullName, [ref]$t, [ref]$e)
        if ($e -and $e.Count) { return "parse error in $($fl.Name): $($e[0].Message)" }
    }
    try { $j = [IO.File]::ReadAllText((Join-Path $Dir 'config\catalog.json')) | ConvertFrom-Json; if (@($j.Packages).Count -lt 1) { return 'catalog.json has no packages' } }
    catch { return "catalog.json does not parse: $($_.Exception.Message)" }
    return ''
}
function Get-NewestKitCopy {
    <# Newest downloaded copy under %LOCALAPPDATA%\my-win-kit\app: @{ Path; Version } or $null. #>
    if (-not (Test-Path -LiteralPath $AppDir)) { return $null }
    $best = $null
    foreach ($d in (Get-ChildItem -LiteralPath $AppDir -Directory -ErrorAction SilentlyContinue)) {
        $v = Get-LocalKitVersion $d.FullName
        if ($v -and (-not $best -or $v -gt $best.Version) -and (Test-Path -LiteralPath (Join-Path $d.FullName 'install.ps1'))) { $best = [pscustomobject]@{ Path = $d.FullName; Version = $v } }
    }
    return $best
}
function Install-KitCopy([version]$Version) {
    <# Download the repo zip, verify it, put it at app\<version>. Returns the folder or $null. #>
    $dest = Join-Path $AppDir $Version.ToString()
    if ((Test-Path -LiteralPath $dest) -and -not (Test-KitCopy $dest)) { return $dest }
    $work = Join-Path $env:TEMP ("my-win-kit-update-{0}" -f [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'kit.zip'
        if ($ZipUrl -like 'file:*') { Copy-Item -LiteralPath ([Uri]$ZipUrl).LocalPath -Destination $zip }
        else {
            $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 60 -UserAgent 'my-win-kit' } finally { $ProgressPreference = $pp }
        }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x') -Force
        $top = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1
        if (-not $top) { throw 'no install.ps1 in the downloaded zip' }
        $bad = Test-KitCopy $top.FullName
        if ($bad) { throw "downloaded kit failed verification: $bad" }
        $got = Get-LocalKitVersion $top.FullName
        if ($got -ne $Version) { throw "downloaded kit is version $got, expected $Version" }
        if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $top.FullName -Destination $dest
        Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        # keep the three newest copies
        Get-ChildItem -LiteralPath $AppDir -Directory | Sort-Object { Get-LocalKitVersion $_.FullName } -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-RunLog "update: kit $Version installed at $dest"
        return $dest
    } catch {
        Write-RunLog "update: FAILED to install kit $Version - $($_.Exception.Message)"
        Write-Say "Update failed: $($_.Exception.Message)" 'Yellow'
        return $null
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# irm | iex: no script folder -> download the kit and start it from %LOCALAPPDATA%
if (-not $root) {
    Write-Say "my-win-kit $Dot downloading the kit from github.com/$Repo..." 'Cyan'
    $rv = Get-RemoteKitVersion
    $dir = $null
    if ($rv) { $dir = Install-KitCopy $rv }
    if (-not $dir) { $n = Get-NewestKitCopy; if ($n) { $dir = $n.Path; Write-Say "Using the copy already on this PC (v$($n.Version))." 'Yellow' } }
    if (-not $dir) { Write-Say 'Could not download the kit. Check the internet connection (and that the repo is public), then try again.' 'Red'; return }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'install.ps1'), '-NoUpdate')
    if ($env:MYWINKIT_BOOTSTRAP_ARGS) { $childArgs += @($env:MYWINKIT_BOOTSTRAP_ARGS -split '\s+' | Where-Object { $_ }) }
    Write-RunLog "loader: bootstrap -> $dir"
    & powershell.exe @childArgs
    return   # not exit: under iex, exit would close the user's PowerShell window
}

# Self-update (file run). Re-runs the newer copy's loader with -NoUpdate and the same arguments.
if (-not $NoUpdate) {
    $here = Get-LocalKitVersion $root
    $useDir = $null; $useVer = $here
    $n = Get-NewestKitCopy
    if ($n -and $here -and $n.Version -gt $here -and $n.Path -ne $root) { $useDir = $n.Path; $useVer = $n.Version; Write-RunLog "update: newer copy already on this PC: v$($n.Version) at $($n.Path)" }
    $rv = Get-RemoteKitVersion
    Write-RunLog "update: this copy v$here, best local v$useVer, GitHub v$(if ($rv) { $rv } else { '?' })"
    if ($rv -and $useVer -and $rv -gt $useVer) {
        $upFile = Join-Path $stateDir 'update.json'
        $declined = ''; try { $declined = ([IO.File]::ReadAllText($upFile) | ConvertFrom-Json).declined } catch {}
        if ($declined -eq $rv.ToString() -and -not $PSBoundParameters.ContainsKey('UpdateAnswer')) {
            Write-RunLog "update: v$rv was declined earlier - not asking again"
        } elseif (-not $PSBoundParameters.ContainsKey('UpdateAnswer') -and [Console]::IsInputRedirected) {
            Write-RunLog "update: v$rv available but input is redirected (CI/pipe) - not asking, keeping v$useVer"
        } else {
            if ($PSBoundParameters.ContainsKey('UpdateAnswer')) { $ua = $UpdateAnswer; Write-Say "Update kit $useVer -> $($rv)? [Y/n] $ua" 'Cyan' }
            else { Write-Host "  Update kit $useVer -> $($rv)? [Y/n] " -ForegroundColor Cyan -NoNewline; $ua = Read-Host }
            Write-RunLog "update: answer '$ua' for v$rv"
            if ($ua -match '^[Nn]') {
                try { [IO.File]::WriteAllText($upFile, ('{ "declined": "' + $rv + '" }')) } catch {}
            } else {
                $d = Install-KitCopy $rv
                if ($d) { $useDir = $d; $useVer = $rv; Write-Say "Updated to v$rv." 'Green' }
                else { Write-Say "Keeping v$useVer." 'Yellow' }
            }
        }
    }
    if ($useDir) {
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $useDir 'install.ps1'), '-NoUpdate')
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Key -in 'UpdateAnswer', 'NoUpdate') { continue }
            if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $childArgs += "-$($kv.Key)" } }
            else { $childArgs += @("-$($kv.Key)", [string]$kv.Value) }
        }
        Write-RunLog "loader: running kit v$useVer from $useDir"
        & powershell.exe @childArgs
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------- fresh-system bootstrap
# Remove mark-of-the-web from the kit files so later direct runs are not blocked,
# and (re)create the double-clickable launcher (ExecutionPolicy bypass for this run only).
try { Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.cmd' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}
$cmdPath = Join-Path $root 'install.cmd'
if (-not (Test-Path -LiteralPath $cmdPath)) {
    try {
        Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value @(
            '@echo off',
            'rem Launcher for the workstation installer - safe on fresh Windows.',
            'rem Bypasses ExecutionPolicy for this run only (no system change).',
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1"'
        )
    } catch {}
}

# ---------------------------------------------------------------- PowerShell 7 detection

function Find-Pwsh {
    <# Best pwsh.exe on this PC: @{ Path; Version } or $null. Checks known paths (PATH may be stale). #>
    if ($NoPwsh -or $env:MYWINKIT_SIMULATE_NO_PWSH -eq '1') { return $null }
    $cands = @()
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { $cands += $c.Source }
    $cands += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    $cands += (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe')
    $cands += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    $best = $null
    foreach ($p in ($cands | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $v = [version]((& $p -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1) -replace '-.*$', '')
            if (-not $best -or $v -gt $best.Version) { $best = [pscustomobject]@{ Path = $p; Version = $v } }
        } catch {}
    }
    return $best
}

function Get-SimulatedInstall {
    <# Testing: MYWINKIT_SIMULATE_INSTALL=ok|fail makes the installs below report that result without running anything. #>
    if ($env:MYWINKIT_SIMULATE_INSTALL -in 'ok', 'fail') { return $env:MYWINKIT_SIMULATE_INSTALL }
    return ''
}

function Install-Pwsh {
    <# Install PowerShell 7: winget first, then the signed MSI from the official GitHub release. #>
    $sim = Get-SimulatedInstall
    if ($sim) { Write-Say "Simulated: PowerShell 7 install ($sim)." 'Magenta'; Write-RunLog "loader: simulated PowerShell 7 install ($sim)"; return ($sim -eq 'ok') }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Say 'Installing PowerShell 7 with winget...' 'DarkYellow'
        & winget install --id Microsoft.PowerShell --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Say "winget exit code $LASTEXITCODE - trying the official MSI instead." 'Yellow'
    }
    try {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        Write-Say 'Looking up the latest PowerShell release on GitHub...' 'DarkYellow'
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'my-win-kit' } -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -match "^PowerShell-[0-9.]+-win-$arch\.msi$" } | Select-Object -First 1
        if (-not $asset) { Write-Say "No $arch MSI in release $($rel.tag_name)." 'Red'; return $false }
        $file = Join-Path $env:TEMP $asset.name
        Write-Say "Downloading $($asset.name)..." 'DarkYellow'
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing } finally { $ProgressPreference = $pp }
        $sig = Get-AuthenticodeSignature -LiteralPath $file
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft Corporation*') {
            Write-Say "MSI signature not valid ($($sig.Status)) - not installing." 'Red'
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Say 'Installing (Windows will ask for administrator approval)...' 'DarkYellow'
        $msiArgs = "/i `"$file`" /qb- ADD_PATH=1 ENABLE_MU=1 USE_MU=1 REGISTER_MANIFEST=1"
        $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Verb RunAs -PassThru
        $proc.WaitForExit()
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return ($proc.ExitCode -in 0, 3010)
    } catch {
        Write-Say "PowerShell 7 install failed: $($_.Exception.Message)" 'Red'
        return $false
    }
}

# ---------------------------------------------------------------- Windows Terminal + the auto-install setting

function Test-Terminal {
    <# Windows Terminal is installed for this user. Testing: -NoTerminal, MYWINKIT_SIMULATE_WT=present|absent. #>
    if ($NoTerminal -or $env:MYWINKIT_SIMULATE_WT -eq 'absent') { return $false }
    if ($env:MYWINKIT_SIMULATE_WT -eq 'present') { return $true }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe')) { return $true }
    try { if (Get-AppxPackage -Name 'Microsoft.WindowsTerminal*' -ErrorAction Stop) { return $true } } catch {}
    return $false
}

function Install-Terminal {
    <# Latest Windows Terminal with winget (no other channel: without winget it is skipped). #>
    $sim = Get-SimulatedInstall
    if ($sim) { Write-Say "Simulated: Windows Terminal install ($sim)." 'Magenta'; Write-RunLog "loader: simulated Windows Terminal install ($sim)"; return ($sim -eq 'ok') }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Say 'winget is missing - skipping Windows Terminal.' 'Yellow'; Write-RunLog 'loader: Windows Terminal skipped (no winget)'; return $false }
    Write-Say 'Installing Windows Terminal with winget...' 'DarkYellow'
    & winget install --id Microsoft.WindowsTerminal --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $ec = $LASTEXITCODE
    Write-RunLog "loader: winget install Microsoft.WindowsTerminal exit $ec"
    # 0 = installed; winget's "nothing to do" codes = already current
    return ($ec -in 0, -1978335189, -1978335153, -1978335135, -1978334962)
}

function Get-AutoPwshSetting {
    <#
    "Install PowerShell 7 + Windows Terminal at start without asking": this PC's
    own choice (<state>\local-settings.json, set from the Settings screen), else
    settings.json autoInstallPwsh (cached copy, then the bundled one), else on.
    Same order as Get-KitAutoInstallPwsh in src/core.psm1.
    #>
    $srcs = @(
        @{ File = (Join-Path $stateDir 'local-settings.json'); Name = 'this PC' },
        @{ File = (Join-Path $stateDir 'cache\settings.json'); Name = 'shared, cached' },
        @{ File = (Join-Path $root 'config\settings.json'); Name = 'shared, bundled' }
    )
    foreach ($s in $srcs) {
        if (-not (Test-Path -LiteralPath $s.File)) { continue }
        try {
            $j = [IO.File]::ReadAllText($s.File) | ConvertFrom-Json
            if ($j.PSObject.Properties['autoInstallPwsh'] -and $j.autoInstallPwsh -is [bool]) { return [pscustomobject]@{ On = [bool]$j.autoInstallPwsh; Source = $s.Name } }
        } catch {}
    }
    return [pscustomobject]@{ On = $true; Source = 'default' }
}

# A failed Windows Terminal install is not retried on every start the same day (keeps start-up fast).
$loaderState = Join-Path $stateDir 'loader.json'
function Get-WtFailedToday {
    try { return (([IO.File]::ReadAllText($loaderState) | ConvertFrom-Json).wtFailed -eq (Get-Date -Format 'yyyy-MM-dd')) } catch { return $false }
}
function Set-WtFailedToday {
    try { [IO.File]::WriteAllText($loaderState, ('{ "wtFailed": "' + (Get-Date -Format 'yyyy-MM-dd') + '" }')) } catch {}
}

# ---------------------------------------------------------------- launchers

function Start-Classic([string]$Why = '') {
    Write-RunLog "loader: starting CLASSIC menu (src\tui-classic.ps1) in Windows PowerShell $($PSVersionTable.PSVersion)$(if ($Why) { " - reason: $Why" })"
    Write-Say "Starting classic menu $Dot Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)$(if ($Why) { " $Dot $Why" })" 'DarkYellow'
    $a = @{ KitRoot = $root }
    if ($DryRun) { $a.DryRun = $true }
    if ($script:HasClassicTI) { $a.TestInput = $ClassicTestInput }
    & (Join-Path $root 'src\tui-classic.ps1') @a
    exit $LASTEXITCODE
}

function Start-Modern($Pwsh) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'src\tui-spectre.ps1'), '-KitRoot', $root)
    if ($DryRun) { $a += '-DryRun' }
    Write-RunLog "loader: starting MODERN menu (src\tui-spectre.ps1) with $($Pwsh.Path) (PowerShell $($Pwsh.Version))"
    Write-Say "Starting modern menu $Dot PowerShell $($Pwsh.Version.Major).$($Pwsh.Version.Minor) $Dot Spectre" 'Cyan'
    try { $Host.UI.RawUI.WindowTitle = "my-win-kit $Dot modern (PowerShell 7)" } catch {}
    & $Pwsh.Path @a
    $ec = $LASTEXITCODE
    Write-RunLog "loader: modern menu exited with code $ec"
    if ($ec -eq 3) {
        Write-Say 'The modern menu could not load PwshSpectreConsole (details above) - opening the classic menu.' 'Yellow'
        Write-Say "Run log: $env:MYWINKIT_RUNLOG" 'DarkGray'
        Start-Sleep -Seconds 3
        Start-Classic 'Spectre module unavailable'
    }
    exit $ec
}

# ---------------------------------------------------------------- decide

if ($Classic) {
    Write-RunLog 'loader: decision = classic (forced with -Classic)'
    if ($WhatIfLoader) { 'decision: classic (forced)'; exit 0 }
    Start-Classic '-Classic switch'
}

$pw = Find-Pwsh
Write-RunLog $(if ($pw) { "loader: found pwsh $($pw.Path) version $($pw.Version) (needs $MinPwsh+)" } elseif ($NoPwsh -or $env:MYWINKIT_SIMULATE_NO_PWSH -eq '1') { 'loader: pwsh search skipped (simulated absent)' } else { 'loader: no pwsh found' })
$hasPwsh = [bool]($pw -and $pw.Version -ge $MinPwsh)
$found = if ($pw) { "found $($pw.Version), needs $MinPwsh+" } else { 'not installed' }
$auto = Get-AutoPwshSetting
Write-RunLog "loader: autoInstallPwsh = $($auto.On) ($($auto.Source))"

# Auto mode (default): install what is missing without asking, then relaunch under pwsh.
# Any failure ends in the classic menu, exactly like a declined install.
if ($auto.On) {
    $needWt = -not (Test-Terminal)
    if ($needWt -and (Get-WtFailedToday)) { Write-RunLog 'loader: Windows Terminal missing, but its install failed earlier today - not retrying until tomorrow'; $needWt = $false }
    if (-not $hasPwsh -or $needWt) {
        $what = @(); if (-not $hasPwsh) { $what += "PowerShell 7 ($found)" }; if ($needWt) { $what += 'Windows Terminal' }
        Write-RunLog "loader: decision = auto-install $($what -join ' + ') (autoInstallPwsh on, $($auto.Source))"
        if ($WhatIfLoader) { "decision: auto-install ($($what -join ' + '))"; exit 0 }
        Write-Host ''
        Write-Say "my-win-kit $Dot installing $($what -join ' and ') $Dot no question asked (switch off in Settings)" 'DarkYellow'
        if ($DryRun) {
            if (-not $hasPwsh) { Write-Say 'Dry run: would install PowerShell 7 (winget Microsoft.PowerShell, MSI fallback) without asking.' 'Magenta' }
            if ($needWt) { Write-Say 'Dry run: would install Windows Terminal (winget Microsoft.WindowsTerminal) without asking.' 'Magenta' }
            if ($hasPwsh) { Start-Modern $pw }
            Start-Classic 'dry run: PowerShell 7 not installed'
        }
        $pwshOk = $hasPwsh
        if (-not $hasPwsh) {
            if (Install-Pwsh) { $pw = Find-Pwsh; $pwshOk = [bool]($pw -and $pw.Version -ge $MinPwsh) }
            Write-RunLog "loader: auto-install PowerShell 7 -> $(if ($pwshOk) { "ok ($($pw.Path))" } else { 'not available' })"
        }
        if ($needWt) {
            if (Install-Terminal) { Write-RunLog 'loader: auto-install Windows Terminal -> ok' }
            else { Set-WtFailedToday; Write-RunLog 'loader: auto-install Windows Terminal -> failed'; Write-Say 'Windows Terminal was not installed - carrying on without it.' 'Yellow' }
        }
        if ($pwshOk) { Start-Modern $pw }
        Write-Say 'PowerShell 7 is not available yet - opening the classic menu.' 'Yellow'
        Start-Sleep -Seconds 2
        Start-Classic 'auto-install: PowerShell 7 not available'
    }
}

if ($hasPwsh) {
    Write-RunLog 'loader: decision = modern'
    if ($WhatIfLoader) { "decision: modern ($($pw.Path) $($pw.Version))"; exit 0 }
    Start-Modern $pw
}

Write-RunLog "loader: decision = offer PowerShell 7 install ($found; autoInstallPwsh off, $($auto.Source))"
if ($WhatIfLoader) { "decision: offer-install (PowerShell 7 $found)"; exit 0 }

Write-Host ''
Write-Say 'my-win-kit' 'DarkYellow'
Write-Say "The modern menu runs on PowerShell 7 ($found)."
Write-Say 'Without it you get the simpler classic menu - every install works in both.'
Write-Host ''
if ($PSBoundParameters.ContainsKey('Answer')) { $ans = $Answer; Write-Say "Install PowerShell 7 now? [Y/n] $ans" 'Cyan' }
else { Write-Host '  Install PowerShell 7 now? [Y/n] ' -ForegroundColor Cyan -NoNewline; $ans = Read-Host }

Write-RunLog "loader: install PowerShell 7 answer = '$ans'"
if ($ans -match '^[Nn]') { Start-Classic 'PowerShell 7 install declined' }

if ($DryRun) {
    Write-Say 'Dry run: would install PowerShell 7 (winget Microsoft.PowerShell, MSI fallback).' 'Magenta'
    Start-Classic 'dry run: PowerShell 7 not installed'
}
if (Install-Pwsh) {
    $pw = Find-Pwsh
    if ($pw -and $pw.Version -ge $MinPwsh) { Start-Modern $pw }
    Write-Say 'PowerShell 7 was installed but could not be found yet - opening the classic menu.' 'Yellow'
    $why = 'PowerShell 7 installed but not found yet'
} else {
    Write-Say 'PowerShell 7 was not installed - opening the classic menu.' 'Yellow'
    $why = 'PowerShell 7 install failed'
}
Start-Sleep -Seconds 2
Start-Classic $why
