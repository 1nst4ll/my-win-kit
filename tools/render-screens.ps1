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
# this copy's config/*.json (not GitHub main) and loader (no self-update)
$env:MYWINKIT_CONFIG_URL = ([Uri](Join-Path $root 'config')).AbsoluteUri
$env:MYWINKIT_RAW_URL = 'file:///C:/nonexistent-my-win-kit-update-source'

$screens = [ordered]@{
    '1-main-menu+goodbye' = 'text:q'
    '2-install-flow'      = 'Enter,Enter,Enter,Enter,Enter,text:q'
    '3-search'            = 'Enter,UpArrow,UpArrow,Enter,Enter,Enter,text:anti,Enter,Spacebar,Enter,Enter,Enter,text:q'
    '4-update-ai'         = 'DownArrow,Enter,DownArrow,Enter,Escape,Escape,text:q'
    '9-update-everything' = 'DownArrow,Enter,Enter,Escape,Escape,text:q'
    '5-tweaks'            = 'DownArrow,DownArrow,Enter,Enter,Enter,text:q'
    '6-settings'          = 'DownArrow,DownArrow,DownArrow,Enter,Escape,text:q'
    '8-admin-settings'    = 'DownArrow,DownArrow,DownArrow,Enter,Escape,text:q'   # elevated: ADMIN badge
}
$esc = [char]27
foreach ($name in $screens.Keys) {
    $env:MYWINKIT_SIMULATE_ADMIN = if ($name -like '*admin*') { '1' } else { '0' }
    $env:MYWINKIT_TEST_ANSI = '1'
    $ans = & pwsh -NoProfile -File $tui -KitRoot $root -TestKeys $screens[$name] 2>&1 | Out-String
    $env:MYWINKIT_TEST_ANSI = ''
    $txt = & pwsh -NoProfile -File $tui -KitRoot $root -TestKeys $screens[$name] 2>&1 | Out-String
    # Drop spinner/progress animation frames from the plain capture (keep the last state)
    $clean = ($txt -split "`n" | Where-Object { $_.Trim() }) -join "`n"
    Set-Content -LiteralPath (Join-Path $OutDir "$name.ans") -Value $ans -Encoding utf8
    Set-Content -LiteralPath (Join-Path $OutDir "$name.txt") -Value $clean -Encoding utf8
    $hl = ($txt -split "`n" | Where-Object { $_ -like 'SCREEN-HEIGHTS:*' } | Select-Object -Last 1)
    Write-Host ("  {0,-22} {1,6} chars ansi  {2}" -f $name, $ans.Length, $hl)
}

# Classic menu (VT truecolor forced for the capture), elevated so the ADMIN badge shows
$env:MYWINKIT_SIMULATE_ADMIN = '1'
$env:MYWINKIT_FORCE_VT = '1'
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -Classic -DryRun -ClassicTestInput '2;I;y;;Q' 2>&1 | Out-String
$env:MYWINKIT_FORCE_VT = ''
$env:MYWINKIT_SIMULATE_ADMIN = ''
Set-Content -LiteralPath (Join-Path $OutDir '7-classic.ans') -Value $cl -Encoding utf8
Set-Content -LiteralPath (Join-Path $OutDir '7-classic.txt') -Value ($cl -replace "$esc\[[0-9;]*m", '') -Encoding utf8
Write-Host ("  {0,-22} {1,6} chars ansi" -f '7-classic', $cl.Length)

# Rows per screen come from the menu itself (SCREEN-HEIGHTS, budget 30).
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
