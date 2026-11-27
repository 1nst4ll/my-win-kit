#Requires -Version 7.4
<#
.SYNOPSIS
    Drive the modern menu end to end with scripted keys (dry run, no installs).
.DESCRIPTION
    Each scenario starts src/tui-spectre.ps1 with -TestKeys: keys go to the
    kit's picker, a Spectre TestConsole (120 x 30) is the screen, -DryRun is
    forced and its toggle locked. A scenario passes when the run exits 0, the
    output contains the expected text, and every screen fitted 30 rows
    (the menu reports "SCREEN-HEIGHTS: name=rows; ..." on exit).
    Covers Esc / Backspace / Left = back from every level, q = quit, "/" search,
    a/n group toggles, the read-only Settings screen (an Absent list fails a
    scenario when removed screens reappear). Needs PwshSpectreConsole.
.EXAMPLE
    pwsh -NoProfile -File tools\smoke-tui.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$tui = Join-Path $root 'src\tui-spectre.ps1'
$fail = 0
# Test THIS copy's config/*.json, not whatever is on GitHub main
$env:MYWINKIT_CONFIG_URL = ([Uri](Join-Path $root 'config')).AbsoluteUri
# Package managers: fixed sample rows (Store, npm, pip, ...), so screens do not depend on this PC and nothing slow runs
$env:MYWINKIT_SIMULATE_MANAGERS = 'sample'
# Empty per-run state folder, so "last selection" items never shift the menus
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("mwk-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
# One heal "learned on this PC" (a made-up Id no package uses), so Settings shows the local-fix lines
New-Item -ItemType Directory -Path (Join-Path $env:MYWINKIT_STATE_DIR 'cache') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $env:MYWINKIT_STATE_DIR 'cache\local-overrides.json'), "{`n  `"Smoke.Old`": `"Smoke.New`"`n}`n")

$scenarios = @(
    @{ Name = 'install: recommended -> picker -> review -> simulate -> results -> back -> q'
       Keys = 'Enter,Enter,Enter,Enter,Enter,text:q'
       Expect = @('MAIN MENU', 'Start from', 'Choose apps', 'esc back', 'Simulate now', 'results', 'Summary', 'DRY RUN - nothing was installed', 'Log:', 'see you next time')
       OnceAfter = @('Summary', 'Back to main menu') }
    @{ Name = 'esc from every install level: start / picker / review'
       Keys = 'Enter,Escape,Enter,Enter,Escape,Escape,Enter,Enter,Enter,Escape,Escape,Escape,text:q'
       Expect = @('Back to main menu', 'Back to the app list', 'see you next time') }
    @{ Name = 'backspace and left arrow are back too'
       Keys = 'Enter,Enter,Backspace,LeftArrow,text:q'
       Expect = @('Choose apps', 'see you next time') }
    @{ Name = 'search: start empty -> / "claude code" -> space -> simulate'
       Keys = 'Enter,UpArrow,UpArrow,Enter,Enter,Enter,text:claude code,Enter,Spacebar,Enter,Enter,Enter,text:q'
       Expect = @('Search apps', 'Claude Code CLI', '1 selected', '1 app', 'would run') }
    @{ Name = 'group toggle: n clears the Utilities group'
       Keys = 'Enter,Enter,text:n,Enter,Escape,Escape,Escape,text:q'
       Expect = @('29 apps') }
    @{ Name = 'update AI tools: table lists every AI tool, updates installed ones only -> esc -> q'
       Keys = 'DownArrow,Enter,DownArrow,Enter,Escape,Escape,text:q'
       Expect = @('How it updates', 'Antigravity IDE', 'Cursor', 'Codex CLI', 'KiloCode CLI', 'claude update', 'see you next time')
       Absent = @('also installs missing ones') }
    @{ Name = 'tweaks: esc back, then open (dry) -> back'
       Keys = 'DownArrow,DownArrow,Enter,Escape,DownArrow,DownArrow,Enter,Enter,Enter,text:q'
       Expect = @('Windows 11 tweaks', 'would run: powershell -File', 'see you next time') }
    @{ Name = 'settings (read-only): config source, values, local fixes, edit-in-repo line; essentials toggle (this PC), esc back'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,Escape,text:q'
       Expect = @('read-only', 'Config', 'removeShortcuts', 'dryRunByDefault', 'autoInstallEssentials', '1 package-ID fix in use (learned when winget', '1 package-ID fix learned on this PC only', 'local-overrides.json', 'To change config, edit config/*.json in the my-win-kit repo on GitHub.', 'Install essentials on start (PS7, Terminal, Claude Code, font, Terminal settings):', '(this PC: shared default)', '(this PC)', 'elevateAtStart', 'Ask for administrator rights once at start:', 'not admin', 'Dry run now', 'Open the log folder', 'Back to main menu', 'run log:', 'see you next time')
       Absent = @('Manage packages', 'GitHub account', 'Would commit', 'gh auth') }
    @{ Name = 'update submenu: two choices, pinned back row, esc back -> q'
       Keys = 'DownArrow,Enter,Escape,text:q'
       Expect = @('MAIN MENU', 'Install apps', 'Update everything', 'Update AI tools', 'Back to main menu', 'see you next time')
       Absent = @('Install or update apps') }
    @{ Name = 'update everything: review lists kit apps + other apps on this PC, esc back twice -> q'
       Keys = 'DownArrow,Enter,Enter,Escape,Escape,text:q'
       Expect = @('Update everything', 'Review', 'see you next time') }
    # End = the last list row: the package groups sit at the bottom of the pick list, below however many kit /
    # other apps this machine has, so jumping there keeps the check the same on every PC and CI runner
    @{ Name = 'update everything: package-manager rows (sample) in the review; pick screen: End shows PACKAGE MANAGERS + PIP PACKAGES; esc back -> q'
       Keys = 'DownArrow,Enter,Enter,DownArrow,Enter,End,Escape,Escape,Escape,text:q'
       Expect = @('12 packages', '1 pip package', 'pip left out', '+ 12 packages)', 'Choose which to update', 'PACKAGE MANAGERS', 'PIP PACKAGES', 'requests (Python 3.13)', 'see you next time') }
    @{ Name = 'settings: admin-at-start toggle (this PC), esc back'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,DownArrow,Enter,Escape,text:q'
       Expect = @('Ask for administrator rights once at start:', '(this PC, from the next start)', 'see you next time') }
    @{ Name = 'results: blocked / restart needed / skipped / failed badges, Retry the failed / blocked -> retry run -> back -> q'
       Env = @{ MYWINKIT_SIMULATE_OUTCOME = '2=blocked,3=restart,1=skipped,6=failed' }
       Keys = 'Enter,Enter,Enter,Enter,Enter,Escape,text:q'
       Expect = @('blocked', 'restart needed', 'skipped', 'failed', 'Restart Windows to finish', 'Retry the failed / blocked', '(retry)', 'see you next time') }
    @{ Name = 'elevated: ADMIN badge on the banner and every sub-screen header'
       Env = @{ MYWINKIT_SIMULATE_ADMIN = '1' }
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Escape,text:q'
       Expect = @(' ADMIN ', 'Settings', 'see you next time')
       Absent = @('not admin') }
)

# Needs something to update on this PC (first item = "Simulate all now"): skipped on CI runners
$probeCmd = 'Import-Module (Join-Path $env:MWK_ROOT "src\core.psm1"); [void](Initialize-Kit -KitRoot $env:MWK_ROOT -Offline); $i = Get-KitInstalled; $u = Get-KitUpdates -Installed $i; (Get-KitUpdateAllPlan -Installed $i -Updates $u).Run.Count'
$env:MWK_ROOT = $root
$probe = if ($env:GITHUB_ACTIONS) { 0 } else { & pwsh -NoProfile -Command $probeCmd 2>$null | Select-Object -Last 1 }
if (-not $env:GITHUB_ACTIONS -and [int]"0$probe" -gt 0) {
    $scenarios += @{ Name = "update everything (dry): review -> simulate $probe -> results -> back -> q"
        Keys = 'DownArrow,Enter,Enter,Enter,Enter,text:q'
        Expect = @('Simulate all now', 'Updating everything', 'would run', 'Summary', 'DRY RUN - nothing was installed', 'see you next time') }
}

# Needs at least one AI tool installed (first item = "Update all installed"): skipped on CI runners
$hasAi = (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
if ($hasAi -and -not $env:GITHUB_ACTIONS) {
    $scenarios += @{ Name = 'update AI tools: update all -> simulate -> results -> back'
        Keys = 'DownArrow,Enter,DownArrow,Enter,Enter,Enter,text:q'
        Expect = @('Update all installed', 'Updating AI tools', 'would run', 'Summary', 'see you next time') }
    $scenarios += @{ Name = 'update AI tools: pick lists installed tools only -> esc -> esc -> q'
        Keys = 'DownArrow,Enter,DownArrow,Enter,DownArrow,Enter,Escape,Escape,Escape,text:q'
        Expect = @('Pick which installed tools to update', 'Choose AI tools', 'see you next time') }
}

foreach ($s in $scenarios) {
    $kitRoot = $root
    $env:MYWINKIT_SIMULATE_ADMIN = '0'   # same screens on an elevated CI runner and a normal PC
    $env:MYWINKIT_SIMULATE_SAC = 'off'   # Smart App Control on this PC must not change the screens
    if ($s.ContainsKey('Env')) { foreach ($k in $s.Env.Keys) { Set-Item "Env:$k" $s.Env[$k] } }
    $out = & pwsh -NoProfile -File $tui -KitRoot $kitRoot -TestKeys $s.Keys 2>&1 | Out-String
    $ec = $LASTEXITCODE
    foreach ($n in 'MYWINKIT_SIMULATE_ADMIN', 'MYWINKIT_SIMULATE_OUTCOME', 'MYWINKIT_SIMULATE_SAC') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $missing = @($s.Expect | Where-Object { -not $out.Contains($_) })   # literal, not -like (brackets are wildcards)
    if ($s.ContainsKey('OnceAfter')) {
        # the results screen shows exactly one Back row (Wait-Back): count after the last marker
        $tail = $out.Substring([Math]::Max(0, $out.LastIndexOf($s.OnceAfter[0])))
        $n = ([regex]::Matches($tail, [regex]::Escape($s.OnceAfter[1]))).Count
        if ($n -ne 1) { $missing += "exactly one '$($s.OnceAfter[1])' after '$($s.OnceAfter[0])' (found $n)" }
    }
    if ($s.ContainsKey('Absent')) { $missing += @($s.Absent | Where-Object { $out.Contains($_) } | ForEach-Object { "(should be absent) $_" }) }
    $hl = ($out -split "`n" | Where-Object { $_ -like 'SCREEN-HEIGHTS:*' } | Select-Object -Last 1)
    $tall = @()
    if ($hl) { $tall = @(($hl -replace '^SCREEN-HEIGHTS:\s*', '') -split ';\s*' | Where-Object { $_ -match '=(\d+)$' -and [int]$Matches[1] -gt 30 }) }
    else { $missing += 'SCREEN-HEIGHTS line' }
    if ($ec -eq 0 -and $missing.Count -eq 0 -and $tall.Count -eq 0) {
        Write-Host "  ok    $($s.Name)" -ForegroundColor Green
    } else {
        $fail++
        Write-Host "  FAIL  $($s.Name) (exit $ec; missing: $($missing -join ' | '); taller than 30: $($tall -join ', '))" -ForegroundColor Red
        ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 15) | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'smoke-tui: all passed' -ForegroundColor Green } else { Write-Host "smoke-tui: $fail failure(s)" -ForegroundColor Red }
exit $fail
