#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit loader: picks the best menu this PC can run.
.DESCRIPTION
    Works on stock Windows PowerShell 5.1 with nothing else installed.
      1. PowerShell 7.4+ present  -> modern menu (src/tui-spectre.ps1) under pwsh.
      2. Missing or too old       -> offer to install PowerShell 7 (winget,
                                     fallback: signed MSI from GitHub), then 1.
      3. Declined / failed        -> classic menu (src/tui-classic.ps1) in 5.1.
    If the modern menu cannot load its module (exit 3) it also falls back to 2/3's
    classic menu, so a fresh PC is never stuck.
    Quick start: double-click install.cmd (recreated next to this file if missing).
.PARAMETER Classic
    Skip detection and open the classic menu.
.PARAMETER DryRun
    Show what would run, install nothing (passed to either menu).
.PARAMETER NoPwsh
    Testing: behave as if PowerShell 7 were not installed. Same as
    environment variable MYWINKIT_SIMULATE_NO_PWSH=1.
.PARAMETER WhatIfLoader
    Testing: print the decision (modern / offer-install / classic) and exit.
.PARAMETER Answer
    Testing: answer for the "install PowerShell 7?" question (y or n).
.PARAMETER ClassicTestInput
    Testing: passed to the classic menu as -TestInput.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [switch]$Classic,
    [switch]$DryRun,
    [switch]$NoPwsh,
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

function Write-Say([string]$Text, [string]$Color = 'Gray') { Write-Host "  $Text" -ForegroundColor $Color }
$Dot = [string][char]0x00B7

# ---------------------------------------------------------------- run log (which front-end ran, and why)
# One file per run in <state dir>\logs. Child menus append to the same file via MYWINKIT_RUNLOG.
$stateDir = if ($env:MYWINKIT_STATE_DIR) { $env:MYWINKIT_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'my-win-kit' }
try {
    $logDir = Join-Path $stateDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $env:MYWINKIT_RUNLOG = Join-Path $logDir ('run-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $PID)
    # keep the newest 30
    Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}
function Write-RunLog([string]$Text) {
    try { Add-Content -LiteralPath $env:MYWINKIT_RUNLOG -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Text) -Encoding UTF8 } catch {}
}
Write-RunLog ("loader: Windows PowerShell {0} ({1}), kit {2}, args: {3}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $root, (($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))

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

function Install-Pwsh {
    <# Install PowerShell 7: winget first, then the signed MSI from the official GitHub release. #>
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
if ($pw -and $pw.Version -ge $MinPwsh) {
    Write-RunLog 'loader: decision = modern'
    if ($WhatIfLoader) { "decision: modern ($($pw.Path) $($pw.Version))"; exit 0 }
    Start-Modern $pw
}

$found = if ($pw) { "found $($pw.Version), needs $MinPwsh+" } else { 'not installed' }
Write-RunLog "loader: decision = offer PowerShell 7 install ($found)"
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
