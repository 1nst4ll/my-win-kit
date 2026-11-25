#Requires -Version 7.4
<#
.SYNOPSIS
    Drive the Spectre menu end to end with scripted keys (dry run, no installs).
.DESCRIPTION
    Each scenario starts src/tui-spectre.ps1 with -TestKeys: keys are fed to a
    Spectre TestConsole, -DryRun is forced, and the dry-run toggle is locked.
    Asserts the run exits 0 and its output contains the expected text.
    Needs PwshSpectreConsole (installed on first run of the menu).
    -Online scenarios also scan installed apps and resolve vendor pages.
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
    @{ Name = 'install: recommended set -> simulate -> results'
       Keys = 'Enter,Enter,Enter,Enter,Enter,UpArrow,Enter'
       Expect = @('MAIN MENU', 'Start from', 'Choose apps', 'UTILITIES', 'Simulate now', 'Results', 'Summary', 'DRY RUN - nothing was installed', 'Log:') }
    @{ Name = 'install: start empty -> search "claude code" -> simulate'
       Keys = 'Enter,UpArrow,UpArrow,Enter,Enter,Enter,text:claude code,Enter,text:Done,Enter,Enter,Enter,UpArrow,Enter'
       Expect = @('Search an app', 'Claude Code CLI', '1 app', 'would run') }   # 'claude update' only when installed
    @{ Name = 'update AI tools: version table -> back'
       Keys = 'DownArrow,Enter,UpArrow,Enter,UpArrow,Enter'
       Expect = @('How it updates', 'Antigravity IDE', 'official download page', 'claude update') }
    @{ Name = 'settings toggles + tweaks (dry)'
       Keys = 'DownArrow,DownArrow,DownArrow,Enter,Enter,DownArrow,Enter,UpArrow,Enter,DownArrow,DownArrow,Enter,Enter,Enter,UpArrow,Enter'
       Expect = @('Remove desktop shortcuts', 'Dry run', 'win11-tweaks.ps1', 'would run: powershell -File') }
)

# Needs at least one AI tool installed (first item = "Update all installed"): skipped on CI runners
$hasAi = (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
if ($hasAi -and -not $env:GITHUB_ACTIONS) {
    $scenarios += @{ Name = 'update AI tools: update all -> simulate'
        Keys = 'DownArrow,Enter,Enter,Enter,UpArrow,Enter'
        Expect = @('Update all installed', 'Updating AI tools', 'would run') }
}

foreach ($s in $scenarios) {
    $out = & pwsh -NoProfile -File $tui -KitRoot $root -TestKeys $s.Keys 2>&1 | Out-String
    $ec = $LASTEXITCODE
    $missing = @($s.Expect | Where-Object { -not $out.Contains($_) })   # literal, not -like (brackets are wildcards)
    if ($ec -eq 0 -and $missing.Count -eq 0) {
        Write-Host "  ok    $($s.Name)" -ForegroundColor Green
    } else {
        $fail++
        Write-Host "  FAIL  $($s.Name) (exit $ec; missing: $($missing -join ' | '))" -ForegroundColor Red
        ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 15) | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'smoke-tui: all passed' -ForegroundColor Green } else { Write-Host "smoke-tui: $fail failure(s)" -ForegroundColor Red }
exit $fail
