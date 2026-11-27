#Requires -Version 5.1
<#
.SYNOPSIS
    Removes my-win-kit from this PC (for this user).
.DESCRIPTION
    What the "Uninstall my-win-kit" Start menu shortcut and Settings > Apps run.
    Asks once, then removes: the Start menu folder, the Desktop shortcut, the
    Apps & Features entry and the whole state folder (%LOCALAPPDATA%\my-win-kit:
    downloaded kit copies, config cache, logs, this PC's settings). Apps the
    kit installed are NOT removed.
    It copies itself to %TEMP% and runs from there, so it can delete its own
    folder. Paths come from <state>\install.json (written by the installer).
    Windows PowerShell 5.1, ASCII.
.PARAMETER StateDir
    The kit's state folder (default: MYWINKIT_STATE_DIR, else %LOCALAPPDATA%\my-win-kit).
.PARAMETER Yes
    Testing / scripted: no question, no "press Enter" at the end.
.PARAMETER FromTemp
    Internal: this is the %TEMP% copy.
#>
[CmdletBinding()]
param(
    [string]$StateDir,
    [switch]$Yes,
    [switch]$FromTemp
)
$ErrorActionPreference = 'Continue'
if (-not $StateDir) { $StateDir = if ($env:MYWINKIT_STATE_DIR) { $env:MYWINKIT_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'my-win-kit' } }
$StateDir = $StateDir.TrimEnd('\')

if (-not $FromTemp) {
    # run from a copy in %TEMP%, so the state folder (which may hold this file) can go
    $tmp = Join-Path $env:TEMP ('my-win-kit-uninstall-{0}.ps1' -f [guid]::NewGuid())
    Copy-Item -LiteralPath $PSCommandPath -Destination $tmp -Force
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp, '-StateDir', $StateDir, '-FromTemp')
    if ($Yes) { $a += '-Yes' }
    Set-Location -LiteralPath $env:TEMP
    & powershell.exe @a
    exit $LASTEXITCODE
}
Set-Location -LiteralPath $env:TEMP
try { $Host.UI.RawUI.WindowTitle = 'Uninstall my-win-kit' } catch {}

# where the installer put things (install.json), else the defaults
$sm = Join-Path ([Environment]::GetFolderPath('Programs')) 'my-win-kit'
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'my-win-kit.lnk'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\my-win-kit'
$rec = Join-Path $StateDir 'install.json'
if (Test-Path -LiteralPath $rec) {
    try {
        $j = [IO.File]::ReadAllText($rec) | ConvertFrom-Json
        if ($j.StartMenuDir) { $sm = $j.StartMenuDir }
        if ($j.DesktopLnk) { $desk = $j.DesktopLnk }
        if ($j.UninstallKey) { $key = $j.UninstallKey }
    } catch {}
}

Write-Host ''
Write-Host '  Uninstall my-win-kit' -ForegroundColor Cyan
Write-Host ''
Write-Host '  This removes:'
Write-Host "    - the Start menu folder   $sm"
Write-Host "    - the Desktop shortcut    $desk"
Write-Host '    - the Settings > Apps entry'
Write-Host "    - the kit's own files     $StateDir"
Write-Host '      (downloaded kit copies, config cache, logs, this PC''s settings)'
Write-Host ''
Write-Host '  Apps the kit installed stay installed. Remove those in Settings > Apps.' -ForegroundColor Yellow
Write-Host ''
if (-not $Yes) {
    Write-Host '  Uninstall my-win-kit? [Y/n] ' -ForegroundColor Cyan -NoNewline
    $ans = Read-Host
    if ($ans -match '^[Nn]') { Write-Host '  Nothing removed.'; Start-Sleep -Seconds 2; exit 0 }
}

$failed = @()
function Remove-KitItem([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host "  -  $What (not there)" -ForegroundColor DarkGray; return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Write-Host "  ok $What" -ForegroundColor Green }
    catch { $script:failed += $What; Write-Host "  !! $What - $($_.Exception.Message)" -ForegroundColor Red }
}
# the Start menu folder only if it is ours (named my-win-kit), never a parent folder
if ((Split-Path -Leaf $sm) -eq 'my-win-kit') { Remove-KitItem $sm 'Start menu folder' }
if ((Split-Path -Leaf $desk) -eq 'my-win-kit.lnk') { Remove-KitItem $desk 'Desktop shortcut' }
if ((Split-Path -Leaf $key) -match 'my-win-kit') { Remove-KitItem $key 'Settings > Apps entry' }
# the state folder only if it is the kit's: named my-win-kit, or holding the installer's install.json
if ((Split-Path -Leaf $StateDir) -eq 'my-win-kit' -or (Test-Path -LiteralPath $rec)) { Remove-KitItem $StateDir 'kit files' }
else { $failed += 'kit files'; Write-Host "  !! kit files - $StateDir does not look like the kit's folder; left alone" -ForegroundColor Red }

Write-Host ''
if ($failed.Count) {
    Write-Host '  Some parts could not be removed (is a my-win-kit window still open?).' -ForegroundColor Yellow
    Write-Host '  Close it and run Uninstall again.' -ForegroundColor Yellow
} else {
    Write-Host '  my-win-kit is uninstalled.' -ForegroundColor Green
}
if (-not $Yes) { [void](Read-Host '  Press Enter to close') }
exit $(if ($failed.Count) { 1 } else { 0 })
