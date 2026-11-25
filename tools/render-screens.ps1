#Requires -Version 7.4
<#
.SYNOPSIS
    Capture every menu screen to files for eyeballing layout and colour (dry run).
.DESCRIPTION
    Drives src/tui-spectre.ps1 (Spectre TestConsole, 120x30) and src/tui-classic.ps1
    with scripted keys and saves, per screen:
      <name>.txt  plain text (layout)
      <name>.ans  truecolor ANSI (view with: Get-Content <name>.ans -Raw in Windows Terminal)
    Also reports the main-menu height against the 30-row budget.
.PARAMETER OutDir
    Folder for the captures (created if missing).
.EXAMPLE
    pwsh -File tools\render-screens.ps1 -OutDir $env:TEMP\my-win-kit-screens
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutDir)

$root = Split-Path -Parent $PSScriptRoot
$tui = Join-Path $root 'src\tui-spectre.ps1'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-render-" + [guid]::NewGuid())

$screens = [ordered]@{
    '1-main-menu+goodbye' = 'UpArrow,Enter'
    '2-install-flow'      = 'Enter,Enter,Enter,Enter,Enter,UpArrow,Enter'
    '3-search'            = 'Enter,UpArrow,UpArrow,Enter,Enter,Enter,text:anti,Enter,text:Done,Enter,Enter,Enter,UpArrow,Enter'
    '4-update-ai'         = 'DownArrow,Enter,Enter,Enter,UpArrow,Enter'
    '5-tweaks'            = 'DownArrow,DownArrow,Enter,Enter,Enter,UpArrow,Enter'
    '6-settings'          = 'DownArrow,DownArrow,DownArrow,Enter,UpArrow,Enter,UpArrow,Enter'
}
$esc = [char]27
foreach ($name in $screens.Keys) {
    $env:MYWINKIT_TEST_ANSI = '1'
    $ans = & pwsh -NoProfile -File $tui -KitRoot $root -TestKeys $screens[$name] 2>&1 | Out-String
    $env:MYWINKIT_TEST_ANSI = ''
    $txt = & pwsh -NoProfile -File $tui -KitRoot $root -TestKeys $screens[$name] 2>&1 | Out-String
    # Drop spinner/progress animation frames from the plain capture (keep the last state)
    $clean = ($txt -split "`n" | Where-Object { $_.Trim() }) -join "`n"
    Set-Content -LiteralPath (Join-Path $OutDir "$name.ans") -Value $ans -Encoding utf8
    Set-Content -LiteralPath (Join-Path $OutDir "$name.txt") -Value $clean -Encoding utf8
    Write-Host ("  {0,-22} {1,6} chars ansi, {2,5} lines text" -f $name, $ans.Length, ($clean -split "`n").Count)
}

# Classic menu (VT truecolor forced for the capture)
$env:MYWINKIT_FORCE_VT = '1'
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -Classic -DryRun -ClassicTestInput '2;I;y;;Q' 2>&1 | Out-String
$env:MYWINKIT_FORCE_VT = ''
Set-Content -LiteralPath (Join-Path $OutDir '7-classic.ans') -Value $cl -Encoding utf8
Set-Content -LiteralPath (Join-Path $OutDir '7-classic.txt') -Value ($cl -replace "$esc\[[0-9;]*m", '') -Encoding utf8
Write-Host ("  {0,-22} {1,6} chars ansi" -f '7-classic', $cl.Length)

# Height check: main menu = from the first banner line to the "Quit" item
$lines = Get-Content -LiteralPath (Join-Path $OutDir '1-main-menu+goodbye.txt')
$start = ($lines | Select-String -Pattern '__  __' | Select-Object -First 1).LineNumber
$end = ($lines | Select-String -Pattern 'Quit' | Select-Object -First 1).LineNumber
Write-Host "  main menu height: $($end - $start + 1) rows (budget 30, blank lines dropped in .txt)"
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
