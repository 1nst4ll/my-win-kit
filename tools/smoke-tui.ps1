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
# Empty per-run state folder, so "last selection" items never shift the menus
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("mwk-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
# One heal "learned on this PC" (a made-up Id no package uses), so Settings shows the local-fix lines
New-Item -ItemType Directory -Path (Join-Path $env:MYWINKIT_STATE_DIR 'cache') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $env:MYWINKIT_STATE_DIR 'cache\local-overrides.json'), "{`n  `"Smoke.Old`": `"Smoke.New`"`n}`n")

$scenarios = @(
    @{ Name = 'install: recommended -> picker -> review -> simulate -> results -> back -> q'
       Keys = 'Enter,Enter,Enter,Enter,Enter,text:q'
       Expect = @('MAIN MENU', 'Start from', 'Choose apps', 'esc back', 'Simulate now', 'results', 'Summary', 'DRY RUN - nothing was installed', 'Log:', 'see you next time') }
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
       Expect = @('31 apps') }
    @{ Name = 'update AI tools: table -> pick -> esc -> esc -> q'
       Keys = 'DownArrow,Enter,End,Enter,Escape,Escape,text:q'
       Expect = @('How it updates', 'Antigravity IDE', 'Choose AI tools', 'claude update', 'see you next time') }
    @{ Name = 'tweaks: esc back, then open (dry) -> back'
       Keys = 'DownArrow,DownArrow,Enter,Escape,DownArrow,DownArrow,Enter,Enter,Enter,text:q'
       Expect = @('Windows 11 tweaks', 'would run: powershell -File', 'see you next time') }
    @{ Name = 'settings (read-only): config source, values, local fixes, edit-in-repo line; enter, esc back'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,Escape,text:q'
       Expect = @('read-only', 'Config', 'removeShortcuts', 'dryRunByDefault', '1 package-ID fix in use (learned when winget', '1 package-ID fix learned on this PC only', 'local-overrides.json', 'To change config, edit config/*.json in the my-win-kit repo on GitHub.', 'Dry run now', 'Open the log folder', 'Back to main menu', 'run log:', 'see you next time')
       Absent = @('Manage packages', 'GitHub account', 'Would commit', 'gh auth') }
)

# Needs at least one AI tool installed (first item = "Update all installed"): skipped on CI runners
$hasAi = (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
if ($hasAi -and -not $env:GITHUB_ACTIONS) {
    $scenarios += @{ Name = 'update AI tools: update all -> simulate -> results -> back'
        Keys = 'DownArrow,Enter,Enter,Enter,text:q'
        Expect = @('Update all installed', 'Updating AI tools', 'would run', 'Summary') }
}

foreach ($s in $scenarios) {
    $kitRoot = $root
    $out = & pwsh -NoProfile -File $tui -KitRoot $kitRoot -TestKeys $s.Keys 2>&1 | Out-String
    $ec = $LASTEXITCODE
    $missing = @($s.Expect | Where-Object { -not $out.Contains($_) })   # literal, not -like (brackets are wildcards)
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
