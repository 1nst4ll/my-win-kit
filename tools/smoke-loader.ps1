#Requires -Version 5.1
<#
.SYNOPSIS
    Test the install.ps1 loader decisions and the classic menu (dry run, no installs).
.DESCRIPTION
    Runs under Windows PowerShell 5.1 (the engine a fresh PC has):
      - decision with PowerShell 7 present / simulated absent / -Classic
      - autoInstallPwsh on (default): PowerShell 7 and Windows Terminal are installed
        WITHOUT the question (dry run and MYWINKIT_SIMULATE_INSTALL=ok|fail), and a
        failed or unfinished install still ends in the classic menu
      - autoInstallPwsh off (this PC's local-settings.json): the old ask-first flow:
        declined -> classic menu, accepted in dry run -> skips the install, classic menu
      - local override beats the shared settings.json; the classic menu's K toggles it
      - classic menu: toggle apps, POST group, simulate an install run
    Windows Terminal is simulated (MYWINKIT_SIMULATE_WT) so results do not depend on this PC.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-loader.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$loader = Join-Path $root 'install.ps1'
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $env:MYWINKIT_STATE_DIR -Force | Out-Null
$localPrefs = Join-Path $env:MYWINKIT_STATE_DIR 'local-settings.json'
# test THIS copy: no self-update to whatever is on GitHub main
$env:MYWINKIT_RAW_URL = 'file:///C:/nonexistent-my-win-kit-update-source'
$env:MYWINKIT_CONFIG_URL = ([Uri](Join-Path $root 'config')).AbsoluteUri   # this copy's config, not GitHub main
$env:MYWINKIT_SIMULATE_WT = 'present'
$env:MYWINKIT_SIMULATE_INSTALL = ''
$script:fail = 0

function Invoke-Loader([string[]]$LoaderArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $loader @LoaderArgs 2>&1 | Out-String
    return @{ Out = $out; Ec = $LASTEXITCODE }
}
function Check([string]$Name, $Run, [string[]]$Expect, [string[]]$Absent = @()) {
    $missing = @($Expect | Where-Object { -not $Run.Out.Contains($_) })   # literal, not -like (brackets are wildcards)
    $missing += @($Absent | Where-Object { $Run.Out.Contains($_) } | ForEach-Object { "(should be absent) $_" })
    if ($Run.Ec -eq 0 -and $missing.Count -eq 0) { Write-Host "  ok    $Name" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  FAIL  $Name (exit $($Run.Ec); missing: $($missing -join ' | '))" -ForegroundColor Red
        ($Run.Out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 12) | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}
function Set-LocalAuto($Value) {
    if ($null -eq $Value) { Remove-Item -LiteralPath $localPrefs -Force -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllText($localPrefs, "{`n  `"autoInstallPwsh`": $(if ($Value) { 'true' } else { 'false' })`n}`n") }
}
$ask = 'Install PowerShell 7 now?'
$hasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)

Write-Host 'autoInstallPwsh on (the shared default):'
Set-LocalAuto $null
if ($hasPwsh) {
    Check 'decision: PowerShell 7 + Terminal present -> modern' (Invoke-Loader @('-WhatIfLoader')) @('decision: modern')
    Check 'decision: Terminal missing -> auto-install Terminal only' (Invoke-Loader @('-WhatIfLoader', '-NoTerminal')) @('decision: auto-install (Windows Terminal)')
}
Check 'decision: PowerShell 7 absent -> auto-install, no question' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh')) @('decision: auto-install (PowerShell 7 (not installed))') @('offer-install')
Check 'decision: both absent -> auto-install both' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh', '-NoTerminal')) @('decision: auto-install (PowerShell 7 (not installed) + Windows Terminal)')
Check 'decision: -Classic forced (no auto-install)' (Invoke-Loader @('-WhatIfLoader', '-Classic', '-NoPwsh')) @('decision: classic')
Check 'dry run: installs both without asking, classic menu' (Invoke-Loader @('-NoPwsh', '-NoTerminal', '-DryRun', '-ClassicTestInput', 'Q')) @('no question asked', 'Dry run: would install PowerShell 7', 'Dry run: would install Windows Terminal', 'classic menu', 'DRY RUN') @($ask)
$env:MYWINKIT_SIMULATE_INSTALL = 'ok'
Check 'simulated install ok, pwsh not found yet -> classic (never stranded)' (Invoke-Loader @('-NoPwsh', '-NoTerminal', '-ClassicTestInput', 'Q')) @('Simulated: PowerShell 7 install (ok)', 'Simulated: Windows Terminal install (ok)', 'PowerShell 7 is not available yet', 'classic menu') @($ask)
$env:MYWINKIT_SIMULATE_INSTALL = 'fail'
Check 'simulated install failure -> classic menu' (Invoke-Loader @('-NoPwsh', '-NoTerminal', '-ClassicTestInput', 'Q')) @('Simulated: PowerShell 7 install (fail)', 'Windows Terminal was not installed', 'classic menu') @($ask)
if ($hasPwsh) {
    Check 'Terminal failed today -> not retried at the next start' (Invoke-Loader @('-WhatIfLoader', '-NoTerminal')) @('decision: modern')
}
Remove-Item -LiteralPath (Join-Path $env:MYWINKIT_STATE_DIR 'loader.json') -Force -ErrorAction SilentlyContinue
$env:MYWINKIT_SIMULATE_INSTALL = ''

Write-Host 'autoInstallPwsh off on this PC (local override beats the shared on):'
Set-LocalAuto $false
Check 'decision: PowerShell 7 absent -> offer install (ask first)' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh', '-NoTerminal')) @('decision: offer-install')
Check 'declined PowerShell 7 -> classic menu'          (Invoke-Loader @('-NoPwsh', '-Answer', 'n', '-DryRun', '-ClassicTestInput', 'Q')) @($ask, 'classic menu', 'DRY RUN')
Check 'accepted in dry run -> no install, classic'     (Invoke-Loader @('-NoPwsh', '-Answer', 'y', '-DryRun', '-ClassicTestInput', 'Q')) @('Dry run: would install PowerShell 7', 'classic menu')
Check 'classic menu shows the local choice'           (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q')) @('auto PowerShell 7 + Terminal: off (this PC)')
Check 'classic K toggles it back on (this PC)'         (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'K;Q')) @('auto PowerShell 7 + Terminal: on (this PC)')
Check 'after K: loader auto-installs again'            (Invoke-Loader @('-WhatIfLoader', '-NoPwsh')) @('decision: auto-install')
Set-LocalAuto $null

Write-Host 'classic menu:'
Check 'classic: toggles + POST + simulated run'        (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', '0;2;46;X;I;y;;Q')) @('0 selected', '[1/5] Notepad++', '[5/5] Enable RDP Host', '5 ok', '0 failed', 'see you next time', 'auto PowerShell 7 + Terminal: on (shared)')

# The run log must prove which front-end started (newest log = the classic run above)
$log = Get-ChildItem -LiteralPath (Join-Path $env:MYWINKIT_STATE_DIR 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$logText = if ($log) { Get-Content -LiteralPath $log.FullName -Raw } else { '' }
Check 'run log records loader decision + front-end' @{ Out = $logText; Ec = 0 } @('loader: decision = classic', 'loader: starting CLASSIC menu', 'frontend: CLASSIC started')

Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
foreach ($n in 'MYWINKIT_SIMULATE_WT', 'MYWINKIT_SIMULATE_INSTALL') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
if ($script:fail -eq 0) { Write-Host 'smoke-loader: all passed' -ForegroundColor Green } else { Write-Host "smoke-loader: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
