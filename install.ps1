#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit loader: keeps the kit up to date and picks the best menu this PC can run.
.DESCRIPTION
    Works on stock Windows PowerShell 5.1 with nothing else installed.
      0. Self-update, at every start, without asking: if GitHub main has a newer
         kit version than this copy, download the repo zip into
         %LOCALAPPDATA%\my-win-kit\app\<version>, verify it, and run from there.
         Any failure (offline, bad zip) falls back to this copy. A newer copy
         already downloaded is used too. -NoUpdate skips the check.
      E. elevateAtStart on (default; this PC's choice in Settings, else
         config/settings.json) and not elevated: relaunch this kit as
         administrator (one UAC prompt, all arguments kept) and wait for it.
         Declined -> carry on here (each installer asks for itself). A
         standard account (Windows would ask for ANOTHER account's password)
         is never elevated as a whole: per-user installs would land in the
         wrong profile.
      1. Essentials, autoInstallEssentials on (default; this PC's choice in
         Settings, else config/settings.json; the older autoInstallPwsh
         still counts): WITHOUT asking, in this order, each skipped when it
         is already done: PowerShell 7 (winget, fallback: signed MSIX from
         GitHub, then the Store), Windows Terminal (winget), Claude Code CLI (official
         installer, at normal user rights), CaskaydiaCove Nerd Font (latest
         Nerd Fonts release, SHA-256 checked), Windows Terminal settings
         (config/terminal.json merged into settings.json, backup first) and
         Windows Terminal as the default terminal app. A failure is shown
         once and never stops the start-up. Then relaunch under pwsh (2).
      2. PowerShell 7.4+ present  -> modern menu (src/tui-spectre.ps1) under pwsh.
      3. autoInstallEssentials off, pwsh missing or too old -> ask "Install
                                     PowerShell 7 now?" first, then 2.
      4. Declined / failed        -> classic menu (src/tui-classic.ps1) in 5.1.
    If the modern menu cannot load its module (exit 3) it also falls back to the
    classic menu, so a fresh PC is never stuck.
    Unattended: install.cmd /auto (or install.ps1 -Auto) runs the same steps
    without a single question, then installs the recommended apps that are
    missing and updates the installed ones (src/tui-classic.ps1 -Auto). Exit
    code 0 = all ok, 1 = something failed. /pause waits for Enter at the end.
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
.PARAMETER Auto
    Unattended run (same as /auto): no questions, recommended set + updates,
    exit code 0 = ok, 1 = failures.
.PARAMETER Pause
    With -Auto: wait for Enter before closing (same as /pause).
.PARAMETER NoElevate
    Do not ask for administrator rights at start (this run only).
.PARAMETER ElevatedChild
    Internal: this copy was relaunched as administrator by the loader.
.PARAMETER KitEnv
    Internal: MYWINKIT_* environment of the parent (base64), because an
    elevated process (and a Windows Terminal tab) does not inherit the environment.
.PARAMETER InTerminal
    Internal: this copy was relaunched inside Windows Terminal by the loader
    (never relaunch again).
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
    Slash forms from install.cmd: /auto /pause /dryrun /classic /noelevate.
    Overrides (tests): MYWINKIT_REPO, MYWINKIT_BRANCH, MYWINKIT_RAW_URL (base of
    raw files, or file:///folder), MYWINKIT_ZIP_URL (zip, or file:///kit.zip),
    MYWINKIT_STATE_DIR, MYWINKIT_BOOTSTRAP_ARGS (args for the iex bootstrap),
    MYWINKIT_SIMULATE_INSTALL=ok|fail (PowerShell 7 / Terminal installs report
    that result without running anything). Essentials after those two:
    MYWINKIT_SIMULATE_ESSENTIALS=absent|present|<present steps: claude,font,
    terminal-settings,default-terminal> simulates them (without it they are
    skipped in test mode), MYWINKIT_SIMULATE_FAIL=<steps> fails those. Elevation: MYWINKIT_SIMULATE_ADMIN=1|0
    (elevated or not), MYWINKIT_SIMULATE_ELEVATION=same|other (what a UAC prompt
    would give: this user, or another account = over-the-shoulder),
    MYWINKIT_SIMULATE_WT_LAUNCH=ok|fail (the Windows Terminal relaunch is
    simulated: ok runs the tab's command in this console, fail = wt could not
    start; without it there is no Terminal relaunch in test mode),
    MYWINKIT_SIMULATE_UAC=accept|decline (the relaunch is simulated: accept runs
    the child copy in this console as if elevated), MYWINKIT_SIMULATE_SESSION_USER
    =same|other (the signed-in user, for the over-the-shoulder check). In test
    mode (any test switch, or MYWINKIT_STATE_DIR set) there is never a real UAC
    prompt: without MYWINKIT_SIMULATE_UAC the elevation step is skipped.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Classic,
    [switch]$DryRun,
    [switch]$NoUpdate,
    [switch]$NoPwsh,
    [switch]$NoTerminal,
    [switch]$WhatIfLoader,
    [string]$Answer,
    [string]$ClassicTestInput,
    [switch]$Auto,
    [switch]$Pause,
    [switch]$NoElevate,
    [switch]$ElevatedChild,
    [string]$KitEnv,
    [switch]$InTerminal,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

# install.cmd passes its arguments through: /auto /pause /dryrun /classic /noelevate
$script:BadArgs = @()
foreach ($r in @($Rest)) {
    if (-not $r) { continue }
    switch -Regex ($r) {
        '^[/-]auto$'      { $Auto = [switch]$true; $PSBoundParameters['Auto'] = [switch]$true; continue }
        '^[/-]pause$'     { $Pause = [switch]$true; $PSBoundParameters['Pause'] = [switch]$true; continue }
        '^[/-]dry-?run$'  { $DryRun = [switch]$true; $PSBoundParameters['DryRun'] = [switch]$true; continue }
        '^[/-]classic$'   { $Classic = [switch]$true; $PSBoundParameters['Classic'] = [switch]$true; continue }
        '^[/-]no-?elevate$' { $NoElevate = [switch]$true; $PSBoundParameters['NoElevate'] = [switch]$true; continue }
        default           { $script:BadArgs += $r }
    }
}
[void]$PSBoundParameters.Remove('Rest')
# The elevated copy gets the parent's MYWINKIT_* variables (run log, test hooks) as an argument.
if ($KitEnv) {
    try {
        foreach ($line in ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($KitEnv)) -split "`n")) {
            $i = $line.IndexOf('='); if ($i -gt 0 -and $line.StartsWith('MYWINKIT_')) { [Environment]::SetEnvironmentVariable($line.Substring(0, $i), $line.Substring($i + 1)) }
        }
    } catch {}
}

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
Write-RunLog ("loader: Windows PowerShell {0} ({1}), kit {2}, args: {3}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $(if ($root) { $root } else { '(none: irm | iex bootstrap)' }), (($PSBoundParameters.GetEnumerator() | Where-Object { $_.Key -ne 'KitEnv' } | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))
if ($script:BadArgs.Count) { Write-Say "Ignoring unknown argument(s): $($script:BadArgs -join ' ') (known: /auto /pause /dryrun /classic /noelevate)" 'Yellow'; Write-RunLog "loader: unknown arguments ignored: $($script:BadArgs -join ' ')" }
if ($Auto) { Write-RunLog 'loader: unattended run (/auto): no questions' }

$script:BoundArgs = $PSBoundParameters   # inside a function $PSBoundParameters is that function's own
function Get-ForwardArgs([string[]]$Skip = @()) {
    <# This run's arguments, for a relaunched copy (self-update, elevation, bootstrap). #>
    $a = @()
    foreach ($kv in $script:BoundArgs.GetEnumerator()) {
        if ($kv.Key -in @('NoUpdate', 'ElevatedChild', 'KitEnv', 'Rest') + $Skip) { continue }
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $a += "-$($kv.Key)" } }
        else { $a += @("-$($kv.Key)", [string]$kv.Value) }
    }
    return , $a
}

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

# ---------------------------------------------------------------- Start menu / Desktop shortcuts + uninstaller

function Get-KitRegPaths {
    <#
    Where the shortcuts and the Apps & Features entry go (per user, no admin).
    Test hooks: MYWINKIT_STARTMENU_DIR, MYWINKIT_DESKTOP_DIR, MYWINKIT_UNINSTALL_KEY.
    With MYWINKIT_STATE_DIR set (tests) all three hooks are required, else $null:
    a test must never touch the real Start menu, Desktop or registry.
    #>
    $sm = $env:MYWINKIT_STARTMENU_DIR; $dt = $env:MYWINKIT_DESKTOP_DIR; $key = $env:MYWINKIT_UNINSTALL_KEY
    if ($env:MYWINKIT_STATE_DIR -and -not ($sm -and $dt -and $key)) { return $null }
    if (-not $sm) { $sm = Join-Path ([Environment]::GetFolderPath('Programs')) 'my-win-kit' }
    if (-not $dt) { $dt = [Environment]::GetFolderPath('Desktop') }
    if (-not $key) { $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\my-win-kit' }
    return [pscustomobject]@{ StartMenuDir = $sm; DesktopLnk = (Join-Path $dt 'my-win-kit.lnk'); UninstallKey = $key }
}
function Register-KitShortcuts([string]$KitDir, [switch]$Installer) {
    <#
    Copies launch.ps1, uninstall.ps1 and the icon from $KitDir into the state
    folder (%LOCALAPPDATA%\my-win-kit), then creates or refreshes: Start menu
    folder "my-win-kit" (my-win-kit + Uninstall my-win-kit), the Desktop
    shortcut and the Apps & Features entry. -Installer (the online install):
    always creates the Desktop shortcut; without it (a later start) an existing
    Desktop shortcut is refreshed but a deleted one is not re-created.
    Records the paths in <state>\install.json for the uninstaller. Never throws.
    #>
    $paths = Get-KitRegPaths
    if (-not $paths) { Write-RunLog 'shortcuts: skipped (test mode without the MYWINKIT_STARTMENU_DIR/DESKTOP_DIR/UNINSTALL_KEY hooks)'; return $false }
    try {
        $need = @{ 'src\launch.ps1' = 'launch.ps1'; 'src\uninstall.ps1' = 'uninstall.ps1'; 'assets\my-win-kit.ico' = 'my-win-kit.ico' }
        foreach ($k in $need.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $KitDir $k))) { throw "this kit copy has no $k" } }
        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        foreach ($k in $need.Keys) { Copy-Item -LiteralPath (Join-Path $KitDir $k) -Destination (Join-Path $stateDir $need[$k]) -Force }
        $ver = Get-LocalKitVersion $KitDir
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $icon = Join-Path $stateDir 'my-win-kit.ico'
        $runArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $stateDir 'launch.ps1')
        $unArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StateDir "{1}"' -f (Join-Path $stateDir 'uninstall.ps1'), $stateDir
        $ws = New-Object -ComObject WScript.Shell
        $mk = {
            param($Path, $Arguments, $Description)
            $l = $ws.CreateShortcut($Path)
            $l.TargetPath = $ps; $l.Arguments = $Arguments; $l.WorkingDirectory = $env:USERPROFILE
            $l.IconLocation = "$icon,0"; $l.Description = $Description
            $l.Save()
        }
        if (-not (Test-Path -LiteralPath $paths.StartMenuDir)) { New-Item -ItemType Directory -Path $paths.StartMenuDir -Force | Out-Null }
        & $mk (Join-Path $paths.StartMenuDir 'my-win-kit.lnk') $runArgs 'Install and update apps, Windows tweaks (my-win-kit)'
        & $mk (Join-Path $paths.StartMenuDir 'Uninstall my-win-kit.lnk') $unArgs 'Remove my-win-kit (its shortcuts and downloaded files; installed apps stay)'
        $desk = 'not touched'
        if ($Installer -or (Test-Path -LiteralPath $paths.DesktopLnk)) {
            $dd = Split-Path -Parent $paths.DesktopLnk
            if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            & $mk $paths.DesktopLnk $runArgs 'Install and update apps, Windows tweaks (my-win-kit)'
            $desk = $paths.DesktopLnk
        }
        $key = $paths.UninstallKey
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        $vals = [ordered]@{
            DisplayName = 'my-win-kit'; DisplayVersion = "$ver"; Publisher = 'my-win-kit (github.com/1nst4ll/my-win-kit)'
            DisplayIcon = $icon; InstallLocation = $stateDir; URLInfoAbout = 'https://github.com/1nst4ll/my-win-kit'
            UninstallString = ('"{0}" {1}' -f $ps, $unArgs); InstallDate = (Get-Date -Format 'yyyyMMdd')
        }
        foreach ($n in $vals.Keys) { New-ItemProperty -LiteralPath $key -Name $n -Value $vals[$n] -PropertyType String -Force | Out-Null }
        foreach ($n in 'NoModify', 'NoRepair') { New-ItemProperty -LiteralPath $key -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
        $rec = '{{ "Version": "{0}", "StartMenuDir": "{1}", "DesktopLnk": "{2}", "UninstallKey": "{3}" }}' -f $ver, ($paths.StartMenuDir -replace '\\', '\\'), ($paths.DesktopLnk -replace '\\', '\\'), ($key -replace '\\', '\\')
        [IO.File]::WriteAllText((Join-Path $stateDir 'install.json'), $rec)
        Write-RunLog "shortcuts: v$ver registered - Start menu $($paths.StartMenuDir), Desktop $desk, uninstall key $key"
        return $true
    } catch {
        Write-RunLog "shortcuts: FAILED - $($_.Exception.Message)"
        Write-Say "Could not add the Start menu / Desktop shortcuts: $($_.Exception.Message)" 'Yellow'
        return $false
    }
}

# irm | iex: no script folder -> download the kit and start it from %LOCALAPPDATA%
if (-not $root) {
    Write-Say "my-win-kit $Dot downloading the kit from github.com/$Repo..." 'Cyan'
    $rv = Get-RemoteKitVersion
    $dir = $null
    if ($rv) { $dir = Install-KitCopy $rv }
    if (-not $dir) { $n = Get-NewestKitCopy; if ($n) { $dir = $n.Path; Write-Say "Using the copy already on this PC (v$($n.Version))." 'Yellow' } }
    if (-not $dir) { Write-Say 'Could not download the kit. Check the internet connection (and that the repo is public), then try again.' 'Red'; return }
    # Start menu + Desktop shortcuts and the Apps & Features entry, as the signed-in user (before any elevation)
    if (Register-KitShortcuts -KitDir $dir -Installer) { Write-Say "Added my-win-kit to the Start menu and the Desktop (uninstall: Start menu or Settings > Apps)." 'Green' }
    # & ([scriptblock]::Create((irm <url>))) -Auto passes arguments; plain irm | iex has none
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'install.ps1'), '-NoUpdate') + (Get-ForwardArgs)
    if ($env:MYWINKIT_BOOTSTRAP_ARGS) { $childArgs += @($env:MYWINKIT_BOOTSTRAP_ARGS -split '\s+' | Where-Object { $_ }) }
    Write-RunLog "loader: bootstrap -> $dir"
    # The child copy asks for administrator rights itself (it relaunches elevated and waits).
    & powershell.exe @childArgs
    $global:LASTEXITCODE = $LASTEXITCODE
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
        # Always take the newer version, without asking; any failure keeps this copy.
        Write-Say "Updating the kit $useVer -> $rv..." 'Cyan'
        Write-RunLog "update: installing v$rv (automatic)"
        $d = Install-KitCopy $rv
        if ($d) { $useDir = $d; $useVer = $rv; Write-Say "Updated to v$rv." 'Green' }
        else { Write-Say "Keeping v$useVer." 'Yellow' }
    }
    if ($useDir) {
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $useDir 'install.ps1'), '-NoUpdate') + (Get-ForwardArgs)
        Write-RunLog "loader: running kit v$useVer from $useDir"
        & powershell.exe @childArgs
        exit $LASTEXITCODE
    }
}

# Installed with the online installer (install.json present)? Keep the shortcuts and the
# Apps & Features entry on this version. Only when the version changed; never in the elevated copy.
if (-not $ElevatedChild) {
    try {
        $instFile = Join-Path $stateDir 'install.json'
        if (Test-Path -LiteralPath $instFile) {
            $instVer = ([IO.File]::ReadAllText($instFile) | ConvertFrom-Json).Version
            $myVer = Get-LocalKitVersion $root
            # (the OneDrive copy has no assets\ folder: refreshed only from a downloaded copy)
            if ($myVer -and "$instVer" -ne "$myVer" -and (Test-Path -LiteralPath (Join-Path $root 'assets\my-win-kit.ico'))) { [void](Register-KitShortcuts -KitDir $root) }
        }
    } catch { Write-RunLog "shortcuts: refresh skipped - $($_.Exception.Message)" }
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
            'rem Unattended: install.cmd /auto   (also /pause /dryrun /classic /noelevate)',
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1" %*'
        )
    } catch {}
}

# ---------------------------------------------------------------- settings a PC can override

function Get-LoaderSwitch([string]$Name, [bool]$Default = $true, [string[]]$Legacy = @()) {
    <#
    An on/off setting: this PC's own choice (<state>\local-settings.json, set
    from the Settings screen), else settings.json (cached copy, then the
    bundled one; the loader does not fetch config itself), else -Default.
    -Legacy = older names of the same setting (read after -Name in each file).
    Same order as Get-KitLocalSwitch in src/core.psm1.
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
            foreach ($n in @($Name) + @($Legacy)) {
                if ($n -and $j.PSObject.Properties[$n] -and $j.$n -is [bool]) { return [pscustomobject]@{ On = [bool]$j.$n; Source = $s.Name } }
            }
        } catch {}
    }
    return [pscustomobject]@{ On = $Default; Source = 'default' }
}

# ---------------------------------------------------------------- administrator rights: ask once at start

function Test-LoaderAdmin {
    <# This process is elevated. Testing: MYWINKIT_SIMULATE_ADMIN=1|0. #>
    if ($env:MYWINKIT_SIMULATE_ADMIN -eq '1') { return $true }
    if ($env:MYWINKIT_SIMULATE_ADMIN -eq '0') { return $false }
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Get-ElevationKind {
    <#
    Who a UAC prompt would make us: 'same' = this account is an administrator
    (its filtered token carries BUILTIN\Administrators as a deny-only group;
    Windows shows a Yes/No consent prompt), 'other' = a standard account
    (Windows asks for ANOTHER account's credentials: over-the-shoulder).
    Testing: MYWINKIT_SIMULATE_ELEVATION=same|other.
    #>
    if ($env:MYWINKIT_SIMULATE_ELEVATION -in 'same', 'other') { return $env:MYWINKIT_SIMULATE_ELEVATION }
    try { foreach ($c in [Security.Principal.WindowsIdentity]::GetCurrent().Claims) { if ($c.Value -eq 'S-1-5-32-544') { return 'same' } } } catch {}
    return 'other'
}

function Get-SessionUserSid {
    <#
    SID of the user signed in to this Windows session (owner of explorer.exe
    here), or $null when unknown (no Explorer shell: then nothing is compared).
    Testing: MYWINKIT_SIMULATE_SESSION_USER=same|other. Same check as
    Get-KitSessionUser in src/core.psm1.
    #>
    $sim = $env:MYWINKIT_SIMULATE_SESSION_USER
    if ($sim -eq 'same') { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    if ($sim -eq 'other') { return 'S-1-5-21-0-0-0-1001' }
    try {
        $sess = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $ex = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $sess" -ErrorAction Stop | Select-Object -First 1)
        if ($ex.Count) { return [string](Invoke-CimMethod -InputObject $ex[0] -MethodName GetOwnerSid -ErrorAction Stop).Sid }
    } catch {}
    return $null
}

function Join-ArgLine([string[]]$Arguments) {
    <# One Windows command line (CommandLineToArgvW rules), for Start-Process -Verb RunAs. #>
    $parts = foreach ($a in $Arguments) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a; continue }
        $s = [regex]::Replace($a, '(\\*)"', '$1$1\"'); $s = [regex]::Replace($s, '(\\+)$', '$1$1')
        '"' + $s + '"'
    }
    return ($parts -join ' ')
}

$script:TestMode = $WhatIfLoader -or $script:HasClassicTI -or $PSBoundParameters.ContainsKey('Answer') -or [bool]$env:MYWINKIT_STATE_DIR
$script:IsAdmin = Test-LoaderAdmin
$script:OtherUserExit = 75   # the elevated copy found it runs as another account: hand back to the parent

# The stable launcher (<state>\launch.ps1): what the Start menu / Desktop shortcuts and the Windows
# Terminal "my-win-kit" profile run. Kept current from this copy at every start, as the signed-in user.
if (-not $ElevatedChild -and (-not $script:TestMode -or $env:MYWINKIT_STATE_DIR)) {
    try {
        $lsrc = Join-Path $root 'src\launch.ps1'; $ldst = Join-Path $stateDir 'launch.ps1'
        if ((Test-Path -LiteralPath $lsrc) -and (-not (Test-Path -LiteralPath $ldst) -or [IO.File]::ReadAllText($lsrc) -ne [IO.File]::ReadAllText($ldst))) {
            if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
            Copy-Item -LiteralPath $lsrc -Destination $ldst -Force
            Write-RunLog "launcher: $ldst updated from $root"
        }
    } catch { Write-RunLog "launcher: not updated - $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- run inside Windows Terminal (not the blue console)
# The kit relaunches itself into a Windows Terminal tab when Terminal is installed: elevated (the
# admin-once step), or as it is (already elevated, or no admin). wt.exe returns at once, so the
# window that started it waits on a hand-off file instead of a process: the tab's PowerShell writes
# "pid=<n>" when it starts and "ec=<exit code>" when the kit ends (75 = the over-the-shoulder
# hand-back). -InTerminal marks the relaunched copy, which never relaunches again.

function Get-WtExe {
    <# wt.exe (Windows Terminal's app alias), or $null. Testing: -NoTerminal, MYWINKIT_SIMULATE_WT=present|absent. #>
    if ($NoTerminal -or $env:MYWINKIT_SIMULATE_WT -eq 'absent') { return $null }
    if ($env:MYWINKIT_SIMULATE_WT -eq 'present') { return 'wt.exe' }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $c = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Test-InsideTerminal {
    <#
    This console is already a terminal tab: the -InTerminal marker, WT_SESSION, or a
    pseudo-console window (Windows Terminal as the default terminal app hands a
    started console to Terminal without setting WT_SESSION). The classic conhost
    window has the class ConsoleWindowClass.
    #>
    if ($InTerminal -or $env:WT_SESSION) { return $true }
    if ($env:MYWINKIT_SIMULATE_WT_LAUNCH) { return $false }   # tests: decide from the marker only
    try {
        if (-not ('MyWinKitLoader.Con' -as [type])) {
            Add-Type -Namespace MyWinKitLoader -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@
        }
        $h = [MyWinKitLoader.Con]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return $false }
        $sb = New-Object System.Text.StringBuilder 256
        [void][MyWinKitLoader.Con]::GetClassName($h, $sb, 256)
        return ($sb.ToString() -eq 'PseudoConsoleWindow')
    } catch { return $false }
}

function Get-KitEnvB64 {
    <# MYWINKIT_* variables as one base64 argument (an elevated process or a Terminal tab does not inherit them). #>
    $kitEnvText = (@(Get-ChildItem Env: | Where-Object { $_.Name -like 'MYWINKIT_*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`n")
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($kitEnvText))
}

function ConvertTo-LoaderPsLiteral([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

function Get-HandoffScript([string]$Handoff, [string[]]$KitArgs) {
    <#
    What the Terminal tab runs (powershell -EncodedCommand, so no quoting or ";" reaches
    wt.exe's own command-line parser): note the PID, run install.ps1 with the arguments,
    write its exit code to the hand-off file.
    #>
    $argText = (@($KitArgs) | ForEach-Object { if ("$_" -match '^-[A-Za-z]+$') { $_ } else { ConvertTo-LoaderPsLiteral "$_" } }) -join ' '
    $f = ConvertTo-LoaderPsLiteral $Handoff
    $script = ConvertTo-LoaderPsLiteral (Join-Path $root 'install.ps1')
    return @"
try { [IO.File]::WriteAllText($f, "pid=`$PID") } catch {}
& $script $argText
`$c = `$LASTEXITCODE; if (`$null -eq `$c) { `$c = 0 }
try { [IO.File]::WriteAllText($f, "pid=`$PID``nec=`$c") } catch {}
exit `$c
"@
}

function Wait-Handoff([string]$Handoff, [int]$StartTimeoutSec = 90) {
    <# Exit code from the hand-off file; $null when the tab never started (timeout). Ends early when that PowerShell is gone. #>
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tabPid = 0
    while ($true) {
        $txt = ''; if (Test-Path -LiteralPath $Handoff) { try { $txt = [IO.File]::ReadAllText($Handoff) } catch {} }
        if ($txt -match 'ec=(-?\d+)') { Remove-Item -LiteralPath $Handoff -Force -ErrorAction SilentlyContinue; return [int]$Matches[1] }
        if ($txt -match 'pid=(\d+)') { $tabPid = [int]$Matches[1] }
        if (-not $tabPid -and $sw.Elapsed.TotalSeconds -gt $StartTimeoutSec) { return $null }
        if ($tabPid -and -not (Get-Process -Id $tabPid -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 800
            $txt = ''; try { $txt = [IO.File]::ReadAllText($Handoff) } catch {}
            Remove-Item -LiteralPath $Handoff -Force -ErrorAction SilentlyContinue
            if ($txt -match 'ec=(-?\d+)') { return [int]$Matches[1] }
            Write-RunLog "terminal: the kit's tab (pid $tabPid) ended without an exit code"
            return 1
        }
        Start-Sleep -Milliseconds 500
    }
}

function Start-InTerminal([switch]$Elevated) {
    <#
    Relaunch this copy in a new Windows Terminal window (elevated with -Elevated: one UAC
    prompt) and wait for it. @{ Started; Declined; Ec ($null = never started); Why }.
    #>
    $wt = Get-WtExe
    if (-not $wt) { return @{ Started = $false; Declined = $false; Ec = $null; Why = 'wt.exe not found' } }
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $handoff = Join-Path $stateDir "handoff-$PID.txt"
    Remove-Item -LiteralPath $handoff -Force -ErrorAction SilentlyContinue
    $kitArgs = (Get-ForwardArgs -Skip @('InTerminal')) + @('-NoUpdate', '-InTerminal')   # (Get-ForwardArgs returns one array: + flattens it, @() would nest it)
    if ($Elevated) { $kitArgs += '-ElevatedChild' }
    $keepAdm = $env:MYWINKIT_SIMULATE_ADMIN
    if ($env:MYWINKIT_SIMULATE_WT_LAUNCH -eq 'ok' -and $Elevated) { $env:MYWINKIT_SIMULATE_ADMIN = '1' }   # simulated: the tab runs elevated
    $kitArgs += @('-KitEnv', (Get-KitEnvB64))
    $env:MYWINKIT_SIMULATE_ADMIN = $keepAdm
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-HandoffScript -Handoff $handoff -KitArgs $kitArgs)))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # new window, the Windows PowerShell profile (by its fixed guid: not the Claude Code default), a fixed title
    $wtArgs = @('-w', 'new', 'new-tab', '-p', '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}', '--title', 'my-win-kit', '--suppressApplicationTitle', $ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    $shown = "$wt $(Join-ArgLine ($wtArgs | Select-Object -First 13)) <command>"
    Write-RunLog "terminal: kit arguments for the tab: $(($kitArgs | Select-Object -SkipLast 2) -join ' ')"
    $sim = $env:MYWINKIT_SIMULATE_WT_LAUNCH
    if ($sim -eq 'fail') { Write-RunLog 'terminal: simulated: wt.exe could not start'; return @{ Started = $false; Declined = $false; Ec = $null; Why = 'simulated launch failure' } }
    if ($sim) {
        Write-Say "Simulated: the kit continues in Windows Terminal$(if ($Elevated) { ' (administrator)' }) (same console)." 'Magenta'
        Write-RunLog "terminal: simulated $(if ($Elevated) { 'elevated ' })launch: $shown"
        $keepAdm = $env:MYWINKIT_SIMULATE_ADMIN
        if ($Elevated) { $env:MYWINKIT_SIMULATE_ADMIN = '1' }
        try { & $ps -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc | Out-Host } finally { $env:MYWINKIT_SIMULATE_ADMIN = $keepAdm }
    } else {
        try {
            if ($Elevated) { Start-Process -FilePath $wt -ArgumentList (Join-ArgLine $wtArgs) -Verb RunAs -ErrorAction Stop | Out-Null }
            else { Start-Process -FilePath $wt -ArgumentList (Join-ArgLine $wtArgs) -ErrorAction Stop | Out-Null }
        } catch {
            $e = $_.Exception; $code = 0
            while ($e) { if ($e -is [ComponentModel.Win32Exception]) { $code = $e.NativeErrorCode; break }; $e = $e.InnerException }
            $declined = ($code -eq 1223) -or ("$($_.Exception.Message)" -match '(?i)cancel')
            Write-RunLog "terminal: wt.exe launch $(if ($declined) { 'declined at the UAC prompt' } else { 'failed' }): $($_.Exception.Message)"
            return @{ Started = $false; Declined = $declined; Ec = $null; Why = "$($_.Exception.Message)" }
        }
        Write-RunLog "terminal: started $(if ($Elevated) { 'elevated ' })$shown; waiting on $handoff"
    }
    $ec = Wait-Handoff -Handoff $handoff
    if ($null -eq $ec) { Write-RunLog 'terminal: the Terminal tab did not start the kit within 90 s' }
    return @{ Started = $true; Declined = $false; Ec = $ec; Why = '' }
}

$script:WtTried = $false
function Invoke-TerminalHandoff([string]$Why) {
    <#
    Before a menu starts in a classic console: relaunch into Windows Terminal (same
    rights) and exit with its code. Once per run; never for /auto (stays in its
    window: scheduled runs and pipes keep their output), never inside a terminal,
    never in tests unless MYWINKIT_SIMULATE_WT_LAUNCH is set.
    #>
    if ($script:WtTried) { return }
    $script:WtTried = $true
    if ($Auto -or $WhatIfLoader) { return }
    if ($script:TestMode -and -not $env:MYWINKIT_SIMULATE_WT_LAUNCH) { return }
    if (-not (Get-WtExe)) { return }
    if (Test-InsideTerminal) { Write-RunLog 'terminal: already inside a terminal tab - no relaunch'; return }
    Write-Say "my-win-kit $Dot continuing in Windows Terminal$(if ($Why) { " ($Why)" })" 'DarkYellow'
    $w = Start-InTerminal
    if ($w.Started -and $null -ne $w.Ec) {
        Write-RunLog "terminal: the kit in Windows Terminal exited with code $($w.Ec)"
        exit $w.Ec
    }
    Write-RunLog "terminal: staying in this window ($(if ($w.Started) { 'the tab did not start' } else { $w.Why }))"
}

if ($ElevatedChild) {
    # The relaunched copy: make sure the elevated account is the signed-in user.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sess = Get-SessionUserSid
    if ($sess -and $sess -ne $me.User.Value) {
        Write-RunLog "elevate: the elevated copy runs as $($me.Name) ($($me.User.Value)), but the signed-in user is $sess - over-the-shoulder, handing back (exit $($script:OtherUserExit))"
        Write-Say "Administrator rights came from another account ($($me.Name)) - going back to the normal window." 'Yellow'
        exit $script:OtherUserExit
    }
    Write-RunLog "elevate: elevated = yes (relaunched as administrator after one UAC prompt; account $($me.Name) = the signed-in user)"
    if ($WhatIfLoader) { 'elevate: running elevated (relaunched copy)' }
} elseif ($script:IsAdmin) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sess = Get-SessionUserSid
    if ($sess -and $sess -ne $me.User.Value) {
        Write-RunLog "elevate: elevated = yes (started as administrator) but as $($me.Name), not the signed-in user ($sess): per-user apps go to that account's profile"
        Write-Say "Running as $($me.Name), not the signed-in user: per-user apps will go to that account's profile." 'Yellow'
    } else { Write-RunLog 'elevate: elevated = yes (started as administrator)' }
    if ($WhatIfLoader) { 'elevate: already elevated' }
} else {
    $elev = Get-LoaderSwitch 'elevateAtStart' $true
    $kind = ''
    $why = ''
    if ($NoElevate) { $why = 'off for this run (-NoElevate / /noelevate)' }
    elseif (-not $elev.On) { $why = "elevateAtStart is off ($($elev.Source))" }
    else {
        $kind = Get-ElevationKind
        if ($kind -eq 'other') { $why = 'this account is not an administrator: Windows would ask for another account, and per-user apps would land in its profile (over-the-shoulder)' }
        elseif ($script:TestMode -and -not $env:MYWINKIT_SIMULATE_UAC) { $why = 'test mode (no real UAC prompt in tests)' }
    }
    if ($why) {
        Write-RunLog "elevate: elevated = no - $why; installers ask for administrator rights one by one"
        if ($WhatIfLoader) { "elevate: no ($why)" }
        elseif ($kind -eq 'other') { Write-Say 'Not asking for administrator rights up front (this is a standard account) - each installer asks for itself.' 'DarkGray' }
    } elseif ($WhatIfLoader) {
        'elevate: relaunch as administrator (one UAC prompt)'
        Write-RunLog 'elevate: decision = relaunch as administrator (what-if, not started)'
    } else {
        # Relaunch this copy elevated with the same arguments and wait for it (exit code + over-the-shoulder hand-back).
        function New-ElevArgs {
            # MYWINKIT_* travel as an argument: the elevated process does not inherit this environment
            return , (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'install.ps1')) + (Get-ForwardArgs) + @('-NoUpdate', '-ElevatedChild', '-KitEnv', (Get-KitEnvB64)))
        }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $ec = $null; $handled = $false
        # Windows Terminal installed: the elevated copy runs in a Terminal window, not the blue console
        # (/auto stays in a console window, so its exit code comes straight from the process)
        if (-not $Auto -and (Get-WtExe) -and ((-not $script:TestMode) -or $env:MYWINKIT_SIMULATE_WT_LAUNCH) -and $env:MYWINKIT_SIMULATE_UAC -ne 'decline') {
            Write-Say "my-win-kit $Dot asking Windows for administrator rights once, so nothing else asks (switch off in Settings)" 'DarkYellow'
            $w = Start-InTerminal -Elevated
            if ($w.Started) {
                $handled = $true; $ec = $w.Ec; $script:WtTried = $true
                if ($null -eq $ec) { Write-Say 'Windows Terminal did not start the kit - carrying on here.' 'Yellow' }
            } elseif ($w.Declined) { $handled = $true }
            else { Write-RunLog "elevate: elevated Windows Terminal launch failed ($($w.Why)) - falling back to an administrator console window" }
        }
        if ($handled) {
        } elseif ($env:MYWINKIT_SIMULATE_UAC -eq 'decline') {
            Write-Say 'Simulated: administrator prompt declined.' 'Magenta'
        } elseif ($env:MYWINKIT_SIMULATE_UAC -eq 'accept') {
            Write-Say 'Simulated: administrator prompt accepted - the kit runs elevated (same console).' 'Magenta'
            $keepSim = $env:MYWINKIT_SIMULATE_ADMIN; $env:MYWINKIT_SIMULATE_ADMIN = '1'
            try {
                $elevArgs = New-ElevArgs
                Write-RunLog "elevate: simulated relaunch: $(Join-ArgLine ($elevArgs | Select-Object -SkipLast 1))"
                & $ps @elevArgs; $ec = $LASTEXITCODE
            } finally { $env:MYWINKIT_SIMULATE_ADMIN = $keepSim }
        } else {
            Write-Say "my-win-kit $Dot asking Windows for administrator rights once, so nothing else asks (switch off in Settings)" 'DarkYellow'
            try {
                $proc = Start-Process -FilePath $ps -ArgumentList (Join-ArgLine (New-ElevArgs)) -Verb RunAs -PassThru -ErrorAction Stop
                $null = $proc.Handle   # keeps the exit code readable in Windows PowerShell 5.1
                Write-RunLog "elevate: relaunched as administrator (pid $($proc.Id)); waiting for it"
                Write-Say 'The kit continues in its administrator window. This window closes when it finishes.' 'DarkGray'
                $proc.WaitForExit()
                $ec = $proc.ExitCode
            } catch {
                Write-RunLog "elevate: relaunch not started: $($_.Exception.Message)"
            }
        }
        if ($null -eq $ec) {
            Write-RunLog 'elevate: elevated = no - administrator prompt declined (or not shown); carrying on, installers ask one by one'
            Write-Say 'No administrator rights - carrying on; each installer asks for itself.' 'Yellow'
        } elseif ($ec -eq $script:OtherUserExit) {
            Write-RunLog 'elevate: elevated = no - the elevated copy ran as another account (over-the-shoulder); carrying on here, installers ask one by one'
            Write-Say 'Carrying on here without administrator rights; each installer asks for itself.' 'Yellow'
        } else {
            Write-RunLog "elevate: the elevated copy exited with code $ec"
            # the administrator window is gone now: say how it ended (its output is in the run log)
            Write-Say "The administrator window finished (exit code $ec). Run log: $env:MYWINKIT_RUNLOG" $(if ($ec) { 'Yellow' } else { 'DarkGray' })
            exit $ec
        }
    }
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

$script:CoreLoaded = $false
function Import-LoaderCore {
    <# The engine (src/core.psm1, 5.1-compatible, no other modules): child processes + the essentials steps. #>
    if ($script:CoreLoaded) { return $true }
    try { Import-Module (Join-Path $root 'src\core.psm1') -Force -DisableNameChecking -ErrorAction Stop; $script:CoreLoaded = $true }
    catch { Write-RunLog "loader: src\core.psm1 did not load: $($_.Exception.Message)" }
    return $script:CoreLoaded
}

function Invoke-LoaderWinget([string[]]$WingetArgs) {
    <# winget in its own hidden console (Invoke-KitProcess, never & exe); returns the exit code. #>
    if (Import-LoaderCore) {
        $r = Invoke-KitProcess -FilePath 'winget' -ArgumentList $WingetArgs
        foreach ($l in @(@($r.Out) + @($r.Err) | Where-Object { "$_".Trim() } | Select-Object -Last 5)) { Write-RunLog "loader:   | $l" }
        return $r.Ec
    }
    & winget @WingetArgs | Out-Host
    return $LASTEXITCODE
}

function Get-SimulatedInstall {
    <# Testing: MYWINKIT_SIMULATE_INSTALL=ok|fail makes the installs below report that result without running anything. #>
    if ($env:MYWINKIT_SIMULATE_INSTALL -in 'ok', 'fail') { return $env:MYWINKIT_SIMULATE_INSTALL }
    return ''
}

function Install-Pwsh {
    <# Install PowerShell 7: winget first, then the signed .msixbundle from the official GitHub release, then the Store package. #>
    $sim = Get-SimulatedInstall
    if ($sim) { Write-Say "Simulated: PowerShell 7 install ($sim)." 'Magenta'; Write-RunLog "loader: simulated PowerShell 7 install ($sim)"; return ($sim -eq 'ok') }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Say 'Installing PowerShell 7 with winget...' 'DarkYellow'
        $ec = Invoke-LoaderWinget @('install', '--id', 'Microsoft.PowerShell', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        Write-RunLog "loader: winget install Microsoft.PowerShell exit $ec"
        if ($ec -eq 0 -or $ec -eq -2147009274) { return $true }   # 0x80073D06: a higher version is already installed
        Write-Say "winget exit code $ec - trying the official MSIX package from GitHub instead." 'Yellow'
    }
    # Since PowerShell 7.7 the releases ship no MSI: the signed .msixbundle (all architectures), per user
    $file = $null
    try {
        if (-not (Import-LoaderCore)) { throw 'src\core.psm1 did not load' }
        Write-Say 'Looking up the latest PowerShell release on GitHub...' 'DarkYellow'
        $json = [string](Invoke-WebRequest -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'my-win-kit'; Accept = 'application/vnd.github+json' } -UseBasicParsing -TimeoutSec 20).Content
        $asset = Get-KitPwshMsixAsset -Json $json
        $file = Join-Path $env:TEMP $asset.Name
        Write-Say "Downloading $($asset.Name)..." 'DarkYellow'
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $asset.Url -OutFile $file -UseBasicParsing } finally { $ProgressPreference = $pp }
        $sig = Get-AuthenticodeSignature -LiteralPath $file
        if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notlike '*O=Microsoft Corporation*') {
            throw "package signature not valid for Microsoft Corporation ($($sig.Status))"
        }
        Write-Say "Installing $($asset.Name)..." 'DarkYellow'
        Add-AppxPackage -Path $file -ErrorAction Stop
        Write-RunLog "loader: PowerShell 7 installed from $($asset.Name) (Add-AppxPackage)"
        return $true
    } catch {
        Write-Say "PowerShell 7 MSIX install did not work: $($_.Exception.Message)" 'Yellow'
        Write-RunLog "loader: PowerShell 7 msixbundle failed: $($_.Exception.Message)"
    } finally { if ($file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } }
    # last resort: the Microsoft Store package (same MSIX, Microsoft's own channel)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Say 'Trying the Microsoft Store package (9MZ1SNWT0N5D)...' 'DarkYellow'
        $ec = Invoke-LoaderWinget @('install', '--id', '9MZ1SNWT0N5D', '--source', 'msstore', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        Write-RunLog "loader: winget install 9MZ1SNWT0N5D (msstore) exit $ec"
        if ($ec -eq 0 -or $ec -eq -2147009274) { return $true }
    }
    Write-Say 'PowerShell 7 install failed.' 'Red'
    return $false
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
    $ec = Invoke-LoaderWinget @('install', '--id', 'Microsoft.WindowsTerminal', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    Write-RunLog "loader: winget install Microsoft.WindowsTerminal exit $ec"
    # 0 = installed; winget's "nothing to do" codes = already current; 0x80073D06 = the Store copy is newer
    return ($ec -in 0, -1978335189, -1978335153, -1978335135, -1978334962, -2147009274)
}

function Get-EssentialsSetting {
    <# "Install essentials on start" (autoInstallEssentials, default on; the older autoInstallPwsh still counts). #>
    return (Get-LoaderSwitch 'autoInstallEssentials' $true @('autoInstallPwsh'))
}

# A failed download-type step (Windows Terminal, Claude Code, the font) is not retried on every
# start the same day (keeps start-up fast on a PC without winget or network): <state>\loader.json.
$loaderState = Join-Path $stateDir 'loader.json'
function Test-FailedToday([string]$Key) {
    try { $j = [IO.File]::ReadAllText($loaderState) | ConvertFrom-Json; return [bool]($j.PSObject.Properties[$Key] -and $j.$Key -eq (Get-Date -Format 'yyyy-MM-dd')) } catch { return $false }
}
function Set-FailedToday([string]$Key, [bool]$Failed = $true) {
    $h = [ordered]@{}
    try { $j = [IO.File]::ReadAllText($loaderState) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = [string]$p.Value } } catch {}
    if ($Failed) { $h[$Key] = (Get-Date -Format 'yyyy-MM-dd') } elseif ($h.Contains($Key)) { $h.Remove($Key) } else { return }
    try { [IO.File]::WriteAllText($loaderState, (([pscustomobject]$h) | ConvertTo-Json -Compress)) } catch {}
}
function Get-WtFailedToday { return (Test-FailedToday 'wtFailed') }
function Set-WtFailedToday { Set-FailedToday 'wtFailed' }

function Invoke-LoaderEssentials([bool]$WtPresent, [bool]$PwshPresent) {
    <#
    The essentials after PowerShell 7 + Windows Terminal, in order (src/core.psm1
    Invoke-KitEssential): Claude Code, CaskaydiaCove Nerd Font, Terminal
    settings, Terminal as the default terminal app. Each one checks first and
    skips when done; a failure is shown once (and Claude Code / the font are
    not retried the same day) and never stops the start-up.
    #>
    if ($script:TestMode -and -not $env:MYWINKIT_SIMULATE_ESSENTIALS) {
        Write-RunLog 'loader: essentials after PowerShell 7 + Terminal skipped (test mode; MYWINKIT_SIMULATE_ESSENTIALS simulates them)'
        return
    }
    if (-not (Import-LoaderCore)) { Write-Say 'Essentials skipped: src\core.psm1 did not load (see the run log).' 'Yellow'; return }
    $ok = [string][char]0x221A; $x = [string][char]0x00D7
    $note = { param($t) Write-Say "  $t" 'DarkGray' }
    foreach ($step in 'claude', 'font', 'terminal-settings', 'default-terminal') {
        $retryKey = "$step-failed"
        $daily = $step -in 'claude', 'font'
        if ($daily -and (Test-FailedToday $retryKey)) { Write-RunLog "loader: essentials: $step failed earlier today - not retrying until tomorrow"; continue }
        $r = Invoke-KitEssential -Name $step -KitRoot $root -DryRun:$DryRun -TerminalPresent $WtPresent -PwshPresent $PwshPresent -OnStatus $note
        Write-RunLog "loader: essentials: $($r.Label) -> $($r.Status) - $($r.Detail)"
        switch ($r.Status) {
            'done'   { Write-Say "$ok $($r.Label): $($r.Detail)" 'Green' }
            'dryrun' { Write-Say "Dry run: $($r.Label): $($r.Detail)" 'Magenta' }
            'failed' { Write-Say "$x $($r.Label) not set up: $($r.Detail) - carrying on$(if ($daily) { ' (next try tomorrow)' })" 'Yellow' }
            default  { }   # current / skipped: run log only
        }
        if ($daily -and -not $DryRun) { Set-FailedToday $retryKey ($r.Status -eq 'failed') }
    }
}

# ---------------------------------------------------------------- launchers

function Start-Auto([string]$Why = '') {
    <# Unattended run: the classic front-end's -Auto mode in this Windows PowerShell 5.1 process (no picker, no questions). #>
    Write-RunLog "loader: starting UNATTENDED run (src\tui-classic.ps1 -Auto) in Windows PowerShell $($PSVersionTable.PSVersion)$(if ($Why) { " - $Why" })"
    $a = @{ KitRoot = $root; Auto = $true }
    if ($DryRun) { $a.DryRun = $true }
    if ($Pause) { $a.Pause = $true }
    & (Join-Path $root 'src\tui-classic.ps1') @a
    $ec = $LASTEXITCODE
    Write-RunLog "loader: unattended run exited with code $ec"
    exit $ec
}

function Start-Classic([string]$Why = '') {
    if ($Auto) { Start-Auto $Why }
    Invoke-TerminalHandoff
    Write-RunLog "loader: starting CLASSIC menu (src\tui-classic.ps1) in Windows PowerShell $($PSVersionTable.PSVersion)$(if ($Why) { " - reason: $Why" })"
    Write-Say "Starting classic menu $Dot Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)$(if ($Why) { " $Dot $Why" })" 'DarkYellow'
    $a = @{ KitRoot = $root }
    if ($DryRun) { $a.DryRun = $true }
    if ($script:HasClassicTI) { $a.TestInput = $ClassicTestInput }
    & (Join-Path $root 'src\tui-classic.ps1') @a
    exit $LASTEXITCODE
}

function Start-Modern($Pwsh) {
    if ($Auto) { Start-Auto "PowerShell 7 $($Pwsh.Version) present; unattended runs use the classic engine" }
    Invoke-TerminalHandoff
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

if ($Auto -and $WhatIfLoader) { 'front-end: unattended (/auto, no questions)' }
if ($Classic) {
    Write-RunLog 'loader: decision = classic (forced with -Classic)'
    if ($WhatIfLoader) { 'decision: classic (forced)'; exit 0 }
    Start-Classic '-Classic switch'
}

$pw = Find-Pwsh
Write-RunLog $(if ($pw) { "loader: found pwsh $($pw.Path) version $($pw.Version) (needs $MinPwsh+)" } elseif ($NoPwsh -or $env:MYWINKIT_SIMULATE_NO_PWSH -eq '1') { 'loader: pwsh search skipped (simulated absent)' } else { 'loader: no pwsh found' })
$hasPwsh = [bool]($pw -and $pw.Version -ge $MinPwsh)
$found = if ($pw) { "found $($pw.Version), needs $MinPwsh+" } else { 'not installed' }
$ess = Get-EssentialsSetting
Write-RunLog "loader: autoInstallEssentials = $($ess.On) ($($ess.Source))"
if ($WhatIfLoader) {
    if ($ess.On) { "essentials: on ($($ess.Source)) - PowerShell 7, Windows Terminal, Claude Code, CaskaydiaCove Nerd Font, Terminal settings, default terminal app" }
    else { "essentials: off ($($ess.Source))" }
}

# Essentials on (default): install what is missing without asking, then relaunch under pwsh.
# A failed PowerShell 7 install ends in the classic menu, exactly like a declined one.
if ($ess.On) {
    $wtOk = Test-Terminal
    $needWt = -not $wtOk
    if ($needWt -and (Get-WtFailedToday)) { Write-RunLog 'loader: Windows Terminal missing, but its install failed earlier today - not retrying until tomorrow'; $needWt = $false }
    $what = @(); if (-not $hasPwsh) { $what += "PowerShell 7 ($found)" }; if ($needWt) { $what += 'Windows Terminal' }
    $pwshOk = $hasPwsh
    if ($what.Count) {
        Write-RunLog "loader: decision = auto-install $($what -join ' + ') (autoInstallEssentials on, $($ess.Source))"
        if ($WhatIfLoader) { "decision: auto-install ($($what -join ' + '))"; exit 0 }
        Write-Host ''
        Write-Say "my-win-kit $Dot installing $($what -join ' and ') $Dot no question asked (switch off in Settings)" 'DarkYellow'
        if ($DryRun) {
            if (-not $hasPwsh) { Write-Say 'Dry run: would install PowerShell 7 (winget Microsoft.PowerShell, MSIX fallback) without asking.' 'Magenta' }
            if ($needWt) { Write-Say 'Dry run: would install Windows Terminal (winget Microsoft.WindowsTerminal) without asking.' 'Magenta'; $wtOk = $true }
        } else {
            if (-not $hasPwsh) {
                if (Install-Pwsh) { $pw = Find-Pwsh; $pwshOk = [bool]($pw -and $pw.Version -ge $MinPwsh) }
                Write-RunLog "loader: auto-install PowerShell 7 -> $(if ($pwshOk) { "ok ($($pw.Path))" } else { 'not available' })"
            }
            if ($needWt) {
                if (Install-Terminal) { $wtOk = $true; Write-RunLog 'loader: auto-install Windows Terminal -> ok' }
                else { Set-WtFailedToday; Write-RunLog 'loader: auto-install Windows Terminal -> failed'; Write-Say 'Windows Terminal was not installed - carrying on without it.' 'Yellow' }
            }
        }
    }
    if (-not $WhatIfLoader) {
        Invoke-LoaderEssentials -WtPresent $wtOk -PwshPresent ($pwshOk -or ($DryRun -and -not $hasPwsh))
        if ($what.Count) {
            if ($DryRun) {
                if ($hasPwsh) { Start-Modern $pw }
                Start-Classic 'dry run: PowerShell 7 not installed'
            }
            if ($pwshOk) { Start-Modern $pw }
            Write-Say 'PowerShell 7 is not available yet - opening the classic menu.' 'Yellow'
            Start-Sleep -Seconds 2
            Start-Classic 'auto-install: PowerShell 7 not available'
        }
    }
}

if ($hasPwsh) {
    Write-RunLog 'loader: decision = modern'
    if ($WhatIfLoader) { "decision: modern ($($pw.Path) $($pw.Version))"; exit 0 }
    Start-Modern $pw
}

Write-RunLog "loader: decision = offer PowerShell 7 install ($found; autoInstallEssentials off, $($ess.Source))"
if ($WhatIfLoader) { "decision: offer-install (PowerShell 7 $found)"; exit 0 }
if ($Auto) { Start-Classic 'PowerShell 7 not installed, autoInstallEssentials off: not asking (unattended)' }

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
    Write-Say 'Dry run: would install PowerShell 7 (winget Microsoft.PowerShell, MSIX fallback).' 'Magenta'
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
