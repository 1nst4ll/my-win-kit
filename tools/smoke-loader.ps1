#Requires -Version 5.1
<#
.SYNOPSIS
    Test the install.ps1 loader decisions and the classic menu (dry run, no installs).
.DESCRIPTION
    Runs under Windows PowerShell 5.1 (the engine a fresh PC has):
      - decision with PowerShell 7 present / simulated absent / -Classic
      - autoInstallEssentials on (default): PowerShell 7 and Windows Terminal are installed
        WITHOUT the question (dry run and MYWINKIT_SIMULATE_INSTALL=ok|fail), and a
        failed or unfinished install still ends in the classic menu
      - essentials (MYWINKIT_SIMULATE_ESSENTIALS): order PS7, Terminal, Claude Code, font,
        Terminal settings, default terminal; skipped when present; a failure carries on
        and is not retried the same day; setting off = none run; /auto runs them too
      - autoInstallEssentials off (this PC's local-settings.json; the older
        autoInstallPwsh name is used for back-compat): the old ask-first flow:
        declined -> classic menu, accepted in dry run -> skips the install, classic menu
      - local override beats the shared settings.json; the classic menu's K toggles it
      - administrator rights at start (MYWINKIT_SIMULATE_*; never a real UAC prompt):
        relaunch decision, already admin, UAC declined -> carry on, standard account
        (over-the-shoulder) -> no whole-kit elevation, elevated copy running as
        another account -> handed back, setting off / -NoElevate, arguments kept,
        classic V toggle and ADMIN badge
      - /auto: unattended dry run with stdin closed and a time limit (no prompt can
        hide), exit code, run log; with a simulated elevation; slash arguments
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
function Set-LocalAuto($Value, [string]$Name = 'autoInstallPwsh') {   # older name on purpose: back-compat
    if ($null -eq $Value) { Remove-Item -LiteralPath $localPrefs -Force -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllText($localPrefs, "{`n  `"$Name`": $(if ($Value) { 'true' } else { 'false' })`n}`n") }
}
function Invoke-LoaderNoInput([string[]]$LoaderArgs, [int]$TimeoutSec = 240) {
    <# stdin closed + a time limit: an unattended run that asks anything would hang here. #>
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$loader`"") + @($LoaderArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return @{ Out = "TIMEOUT after $TimeoutSec s (waiting for input?)`n" + $so.Result; Ec = -1 } }
    $p.WaitForExit()
    return @{ Out = ($so.Result + $se.Result); Ec = $p.ExitCode }
}
function Set-Sim([hashtable]$Vars) {
    foreach ($n in 'MYWINKIT_SIMULATE_ADMIN', 'MYWINKIT_SIMULATE_ELEVATION', 'MYWINKIT_SIMULATE_UAC', 'MYWINKIT_SIMULATE_SESSION_USER') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    foreach ($k in $Vars.Keys) { Set-Item "Env:$k" $Vars[$k] }
}
function Test-Order([string]$Name, $Run, [string[]]$Seq) {
    $pos = -1; $bad = @()
    foreach ($t in $Seq) { $i = $Run.Out.IndexOf($t); if ($i -le $pos) { $bad += $t } else { $pos = $i } }
    if (-not $bad.Count) { Write-Host "  ok    $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (missing or out of order: $($bad -join ' | '))" -ForegroundColor Red }
}
function Get-NewestLog {
    $l = Get-ChildItem -LiteralPath (Join-Path $env:MYWINKIT_STATE_DIR 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) { return @{ Out = (Get-Content -LiteralPath $l.FullName -Raw); Ec = 0 } } else { return @{ Out = ''; Ec = 0 } }
}
# Never a real UAC prompt: this PC's real elevation state is replaced by simulation in every check below.
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0' }
$ask = 'Install PowerShell 7 now?'
$hasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)

Write-Host 'autoInstallEssentials on (the shared default):'
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

Write-Host 'essentials (simulated with MYWINKIT_SIMULATE_ESSENTIALS; nothing installed or changed):'
Check 'what-if: essentials on, the six steps named' (Invoke-Loader @('-WhatIfLoader')) @('essentials: on (', 'Claude Code, CaskaydiaCove Nerd Font, Terminal settings, default terminal app')
Check 'test mode without the simulation: the steps are skipped' (Invoke-Loader @('-NoPwsh', '-NoTerminal', '-DryRun', '-ClassicTestInput', 'Q')) @('classic menu') @('Claude Code:', 'CaskaydiaCove Nerd Font:')
$env:MYWINKIT_SIMULATE_INSTALL = 'ok'
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'absent'
$r = Invoke-Loader @('-NoPwsh', '-NoTerminal', '-ClassicTestInput', 'Q')
Check 'all missing: installed without a question, then the classic menu' $r @('no question asked', 'Claude Code: simulated', 'Default terminal app: simulated', 'classic menu') @($ask)
Test-Order 'order: PowerShell 7, Terminal, Claude Code, font, Terminal settings, default terminal' $r @('Simulated: PowerShell 7 install (ok)', 'Simulated: Windows Terminal install (ok)', 'Claude Code: simulated', 'CaskaydiaCove Nerd Font: simulated', 'Terminal settings: simulated', 'Default terminal app: simulated')
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'present'
$r = Invoke-Loader @('-NoPwsh', '-ClassicTestInput', 'Q')
Check 'all present: nothing runs (skipped quietly)' $r @('classic menu') @('Claude Code:', 'CaskaydiaCove Nerd Font:', 'Terminal settings:', 'Default terminal app:')
Check 'run log: each step recorded as current' (Get-NewestLog) @('essentials: Claude Code -> current', 'essentials: CaskaydiaCove Nerd Font -> current', 'essentials: Terminal settings -> current', 'essentials: Default terminal app -> current')
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'font,default-terminal'
$r = Invoke-Loader @('-NoPwsh', '-ClassicTestInput', 'Q')
Check 'font + default terminal present: only Claude Code and the settings run' $r @('Claude Code: simulated', 'Terminal settings: simulated') @('CaskaydiaCove Nerd Font:', 'Default terminal app:')
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'absent'
$env:MYWINKIT_SIMULATE_FAIL = 'claude'
$r = Invoke-Loader @('-NoPwsh', '-ClassicTestInput', 'Q')
Check 'Claude Code fails: shown once, the next steps and the menu still run' $r @('Claude Code not set up: simulated failure - carrying on (next try tomorrow)', 'CaskaydiaCove Nerd Font: simulated', 'Default terminal app: simulated', 'classic menu')
$r = Invoke-Loader @('-NoPwsh', '-ClassicTestInput', 'Q')
Check 'failed today: Claude Code not retried at the next start' $r @('CaskaydiaCove Nerd Font: simulated', 'classic menu') @('Claude Code not set up')
Check 'run log: the skip is recorded' (Get-NewestLog) @('essentials: claude failed earlier today - not retrying until tomorrow')
Remove-Item -LiteralPath (Join-Path $env:MYWINKIT_STATE_DIR 'loader.json') -Force -ErrorAction SilentlyContinue
$env:MYWINKIT_SIMULATE_FAIL = ''
$r = Invoke-Loader @('-NoPwsh', '-NoTerminal', '-DryRun', '-ClassicTestInput', 'Q')
Check 'dry run: every step says what it would do' $r @('Dry run: would install PowerShell 7', 'Dry run: Claude Code: would set it up', 'Dry run: Default terminal app: would set it up', 'DRY RUN')
$r = Invoke-LoaderNoInput @('/auto', '/dryrun')
Check '/auto runs the essentials too (no question)' $r @('Dry run: Claude Code: would set it up', 'Exit code 0') @('[Y/n]', 'TIMEOUT')
Set-LocalAuto $false 'autoInstallEssentials'
$r = Invoke-Loader @('-NoPwsh', '-Answer', 'n', '-DryRun', '-ClassicTestInput', 'Q')
Check 'autoInstallEssentials off: none of them run (PowerShell 7 asked first, as before)' $r @($ask, 'classic menu') @('Claude Code:', 'CaskaydiaCove Nerd Font:', 'Terminal settings:', 'Default terminal app:')
Check 'what-if: essentials off (this PC)' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh')) @('essentials: off (this PC)', 'decision: offer-install')
Set-LocalAuto $null
$env:MYWINKIT_SIMULATE_ESSENTIALS = ''; $env:MYWINKIT_SIMULATE_INSTALL = ''

Write-Host 'essentials off on this PC via the older autoInstallPwsh (local override beats the shared on):'
Set-LocalAuto $false
Check 'decision: PowerShell 7 absent -> offer install (ask first)' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh', '-NoTerminal')) @('decision: offer-install')
Check 'declined PowerShell 7 -> classic menu'          (Invoke-Loader @('-NoPwsh', '-Answer', 'n', '-DryRun', '-ClassicTestInput', 'Q')) @($ask, 'classic menu', 'DRY RUN')
Check 'accepted in dry run -> no install, classic'     (Invoke-Loader @('-NoPwsh', '-Answer', 'y', '-DryRun', '-ClassicTestInput', 'Q')) @('Dry run: would install PowerShell 7', 'classic menu')
Check 'classic menu shows the local choice'           (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q')) @('essentials on start: off (this PC)')
Check 'classic K toggles it back on (this PC)'         (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'K;Q')) @('essentials on start: on (this PC)')
Check 'after K: loader auto-installs again'            (Invoke-Loader @('-WhatIfLoader', '-NoPwsh')) @('decision: auto-install')
Set-LocalAuto $null

Write-Host 'administrator rights at start (simulated; never a real UAC prompt):'
Check 'test mode without a simulation: no relaunch'    (Invoke-Loader @('-WhatIfLoader')) @('elevate: no (test mode') @('elevate: relaunch')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'same'; MYWINKIT_SIMULATE_UAC = 'accept' }
Check 'not admin, admin account -> relaunch elevated'  (Invoke-Loader @('-WhatIfLoader')) @('elevate: relaunch as administrator (one UAC prompt)')
Check '-NoElevate / /noelevate -> no relaunch'         (Invoke-Loader @('-WhatIfLoader', '/noelevate')) @('elevate: no (off for this run') @('elevate: relaunch')
Set-LocalAuto $false 'elevateAtStart'
Check 'elevateAtStart off on this PC -> no relaunch'   (Invoke-Loader @('-WhatIfLoader')) @('elevate: no (elevateAtStart is off (this PC))') @('elevate: relaunch')
Check 'classic shows the local choice'                 (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q', '-NoElevate')) @('admin at start: off (this PC)')
Check 'classic V toggles it back on (this PC)'         (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'V;Q', '-NoElevate')) @('admin at start: on (this PC)')
Set-LocalAuto $null
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'other'; MYWINKIT_SIMULATE_UAC = 'accept' }
Check 'standard account (over-the-shoulder) -> no whole-kit elevation' (Invoke-Loader @('-WhatIfLoader')) @('elevate: no (this account is not an administrator') @('elevate: relaunch')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '1' }
Check 'already elevated -> no relaunch'                (Invoke-Loader @('-WhatIfLoader')) @('elevate: already elevated') @('elevate: relaunch')
Check 'already elevated -> ADMIN badge in the classic menu' (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q')) @('ADMIN', 'classic menu')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'same'; MYWINKIT_SIMULATE_UAC = 'accept' }
$r = Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q;x y')
Check 'UAC accepted -> the elevated copy runs the kit (ADMIN), parent ends' $r @('Simulated: administrator prompt accepted', 'ADMIN', 'see you next time') @('No administrator rights')
Check 'run log: elevated copy got every argument + its reason' (Get-NewestLog) @('-ElevatedChild', '-ClassicTestInput Q;x y', '-DryRun True', '-Classic True', 'elevate: elevated = yes (relaunched as administrator', 'elevated=yes')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'same'; MYWINKIT_SIMULATE_UAC = 'decline' }
Check 'UAC declined -> carries on without admin (classic)' (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q')) @('Simulated: administrator prompt declined', 'No administrator rights - carrying on', 'classic menu') @('ADMIN')
Check 'run log: declined is recorded'                  (Get-NewestLog) @('elevate: elevated = no - administrator prompt declined', 'elevated=no')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'same'; MYWINKIT_SIMULATE_UAC = 'accept'; MYWINKIT_SIMULATE_SESSION_USER = 'other' }
Check 'elevated as another account -> handed back, no whole-kit elevation' (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', 'Q')) @('Administrator rights came from another account', 'Carrying on here without administrator rights', 'classic menu')
Check 'run log: over-the-shoulder recorded'            (Get-NewestLog) @('over-the-shoulder, handing back', 'elevate: elevated = no - the elevated copy ran as another account')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0' }

Write-Host 'unattended (/auto, dry run, no input at all):'
Check 'what-if: /auto -> unattended front-end'         (Invoke-Loader @('-WhatIfLoader', '/auto')) @('front-end: unattended')
$cmdOut = & cmd.exe /d /c "`"$(Join-Path $root 'install.cmd')`" -WhatIfLoader /auto" 2>&1 | Out-String
Check 'install.cmd passes its arguments through (/auto)' @{ Out = $cmdOut; Ec = $LASTEXITCODE } @('front-end: unattended')
Check 'unknown argument -> named and ignored'          (Invoke-Loader @('-WhatIfLoader', '/bogus')) @('Ignoring unknown argument(s): /bogus')
$r = Invoke-LoaderNoInput @('/auto', '/dryrun')
Check '/auto /dryrun: finishes with no input, no questions, exit 0' $r @('unattended run', 'to install', 'Exit code 0 (all ok)', 'Run log:') @('[Y/n]', 'Press Enter', 'TIMEOUT', 'see you next time')
Check 'run log: unattended front-end + its plan'       (Get-NewestLog) @('loader: unattended run (/auto)', 'loader: starting UNATTENDED run', 'frontend: UNATTENDED (classic -Auto) started', 'auto: elevated=no; install [', 'auto: finished')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0'; MYWINKIT_SIMULATE_ELEVATION = 'same'; MYWINKIT_SIMULATE_UAC = 'accept' }
$r = Invoke-LoaderNoInput @('-Auto', '-DryRun')
Check '-Auto: elevates once (simulated), runs as administrator, exit 0' $r @('Simulated: administrator prompt accepted', 'as administrator (nothing else will ask)', 'Exit code 0') @('[Y/n]', 'TIMEOUT')
Set-Sim @{ MYWINKIT_SIMULATE_ADMIN = '0' }
Set-LocalAuto $false
Check '/auto with essentials off and no PowerShell 7: no question' (Invoke-LoaderNoInput @('/auto', '/dryrun', '-NoPwsh')) @('Exit code 0') @($ask, 'TIMEOUT')
Set-LocalAuto $null

Write-Host 'classic menu:'
Check 'classic L: update submenu -> everything (kit + rest of PC), declined' (Invoke-Loader @('-Classic', '-DryRun', '-NoElevate', '-ClassicTestInput', 'L;1;n;L;;Q')) @('1 everything (kit apps + rest of PC)', '2 AI tools only', 'Kit apps (', 'Other apps on this PC (', 'see you next time')
Check 'classic: toggles + POST + simulated run'        (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', '0;2;46;X;I;y;;Q')) @('0 selected', '[1/5] Notepad++', '[5/5] Enable RDP Host', '5 ok', '0 failed', 'see you next time', 'essentials on start: on (shared)', 'admin at start: on (shared)')

# The run log must prove which front-end started (newest log = the classic run above)
$log = Get-ChildItem -LiteralPath (Join-Path $env:MYWINKIT_STATE_DIR 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$logText = if ($log) { Get-Content -LiteralPath $log.FullName -Raw } else { '' }
Check 'run log records loader decision + front-end' @{ Out = $logText; Ec = 0 } @('loader: decision = classic', 'loader: starting CLASSIC menu', 'frontend: CLASSIC started')

Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
foreach ($n in 'MYWINKIT_SIMULATE_WT', 'MYWINKIT_SIMULATE_INSTALL', 'MYWINKIT_SIMULATE_ESSENTIALS', 'MYWINKIT_SIMULATE_FAIL', 'MYWINKIT_SIMULATE_ADMIN', 'MYWINKIT_SIMULATE_ELEVATION', 'MYWINKIT_SIMULATE_UAC', 'MYWINKIT_SIMULATE_SESSION_USER') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
if ($script:fail -eq 0) { Write-Host 'smoke-loader: all passed' -ForegroundColor Green } else { Write-Host "smoke-loader: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
