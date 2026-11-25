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
    a/n group toggles. Needs PwshSpectreConsole.
.EXAMPLE
    pwsh -NoProfile -File tools\smoke-tui.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$tui = Join-Path $root 'src\tui-spectre.ps1'
$fail = 0
# Empty per-run state folder, so "last selection" items never shift the menus
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-smoke-" + [guid]::NewGuid())

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
    @{ Name = 'settings: toggle, esc back'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,DownArrow,Enter,Escape,text:q'
       Expect = @('Manage packages', 'Remove desktop shortcuts', 'Dry run', 'run log:', 'see you next time') }
    @{ Name = 'manage packages: default off, remove (confirm), restore, reset - dry run keeps it in memory'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,Enter,DownArrow,Spacebar,text:d,Enter,Escape,DownArrow,DownArrow,DownArrow,Enter,Enter,Escape,End,Enter,Enter,Escape,Escape,text:q'
       Expect = @('Package list', 'space default on/off', 'Remove it?', 'Removed packages', 'Reset?', 'changes stay in memory', 'see you next time') }
    @{ Name = 'manage packages: esc from every level (list, search box, id box, removed)'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,Enter,Escape,DownArrow,Enter,Escape,DownArrow,DownArrow,Enter,Escape,DownArrow,DownArrow,DownArrow,Enter,Escape,Escape,Escape,text:q'
       Expect = @('Search winget and the Microsoft Store for', 'Exact winget ID', 'Nothing removed', 'Back to Settings', 'see you next time') }
)

# Needs at least one AI tool installed (first item = "Update all installed"): skipped on CI runners
$hasAi = (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
if ($hasAi -and -not $env:GITHUB_ACTIONS) {
    $scenarios += @{ Name = 'update AI tools: update all -> simulate -> results -> back'
        Keys = 'DownArrow,Enter,Enter,Enter,text:q'
        Expect = @('Update all installed', 'Updating AI tools', 'would run', 'Summary') }
}

# Real winget search + add by Id, saved for real into a SCRATCH copy of the kit (never the repo or OneDrive)
$scratch = $null
if (Get-Command winget -ErrorAction SilentlyContinue) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-smoke-kit-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $scratch 'src') -Force | Out-Null
    Copy-Item -Path (Join-Path $root 'src\*') -Destination (Join-Path $scratch 'src')
    foreach ($f in 'install.ps1', 'install.cmd', 'win11-tweaks.ps1') { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $scratch }
    $scenarios += @{ Name = 'manage packages: winget search + add, add by exact Id into a new group (real save, scratch kit)'
        Kit = $scratch; AllowSave = $true
        Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,DownArrow,Enter,text:7zip,Enter,Enter,Enter,Enter,Enter,DownArrow,DownArrow,Enter,text:Mozilla.Firefox,Enter,End,Enter,text:My tools,Enter,DownArrow,Enter,Enter,Escape,Escape,text:q'
        Expect = @('Searching winget', 'result(s)', 'Which group?', 'In the recommended set?', 'Added', 'saved to my-packages.json', 'Name of the new group', 'Mozilla Firefox', 'see you next time') }
}

foreach ($s in $scenarios) {
    $kitRoot = if ($s.ContainsKey('Kit')) { $s.Kit } else { $root }
    $env:MYWINKIT_TEST_ALLOW_SAVE = if ($s.ContainsKey('AllowSave')) { '1' } else { '' }
    $out = & pwsh -NoProfile -File $tui -KitRoot $kitRoot -TestKeys $s.Keys 2>&1 | Out-String
    $env:MYWINKIT_TEST_ALLOW_SAVE = ''
    $ec = $LASTEXITCODE
    $missing = @($s.Expect | Where-Object { -not $out.Contains($_) })   # literal, not -like (brackets are wildcards)
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
if ($scratch) {
    # the real save must have landed in the scratch kit, and only there
    $ovf = Join-Path $scratch 'my-packages.json'
    $okSave = $false
    if (Test-Path -LiteralPath $ovf) {
        $j = Get-Content -LiteralPath $ovf -Raw | ConvertFrom-Json
        $ff = @($j.added | Where-Object { $_.Ref -eq 'Mozilla.Firefox' })
        $okSave = ($j.schema -eq 1 -and @($j.added).Count -eq 2 -and $ff.Count -eq 1 -and $ff[0].On -eq $true -and $ff[0].Group -eq 'MY1' -and @($j.groups | Where-Object Label -eq 'My tools').Count -eq 1)
    }
    $repoClean = -not (Test-Path -LiteralPath (Join-Path $root 'my-packages.json'))
    if ($okSave -and $repoClean) { Write-Host '  ok    real save: scratch my-packages.json has 7zip + Firefox (on, new group MY1); repo root untouched' -ForegroundColor Green }
    else { $fail++; Write-Host "  FAIL  real save check (saved ok: $okSave, repo root clean: $repoClean)" -ForegroundColor Red; if (Test-Path $ovf) { Get-Content $ovf | Write-Host } }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'smoke-tui: all passed' -ForegroundColor Green } else { Write-Host "smoke-tui: $fail failure(s)" -ForegroundColor Red }
exit $fail
