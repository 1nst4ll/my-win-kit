#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit classic menu: the fallback for stock Windows PowerShell 5.1.
.DESCRIPTION
    Runs when PowerShell 7 is missing or declined, or the Spectre module
    cannot load, so a fresh PC is never stuck. Deliberately simple: numbered
    toggles, then the same install engine (src/core.psm1) as the modern menu.
.PARAMETER KitRoot
    Folder that holds install.ps1.
.PARAMETER DryRun
    Show what would run, install nothing.
.PARAMETER TestInput
    Smoke test: answers separated by ";" fed to the prompts in order (then Q).
    Forces -DryRun. One string because `powershell -File` cannot pass arrays.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [switch]$DryRun,
    [string]$TestInput
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $KitRoot 'src\core.psm1') -Force

$script:Testing = $PSBoundParameters.ContainsKey('TestInput')
if ($script:Testing) { $DryRun = $true }
$script:Queue = New-Object System.Collections.Queue
if ($script:Testing) { foreach ($t in ($TestInput -split ";")) { $script:Queue.Enqueue($t) } }

$cat    = @(Initialize-Kit -KitRoot $KitRoot)
$groups = @(Get-KitGroups)
$state  = Get-KitState
$Host.UI.RawUI.WindowTitle = 'my-win-kit (classic)'

function Read-Answer([string]$Prompt) {
    Write-Host "  $Prompt " -ForegroundColor Cyan -NoNewline
    if ($script:Testing) {
        $a = if ($script:Queue.Count) { [string]$script:Queue.Dequeue() } else { 'Q' }
        Write-Host $a
        return $a
    }
    return (Read-Host)
}
function Clear-Kit { if (-not $script:Testing) { Clear-Host } }
function Write-Rule { Write-Host ('  ' + ('-' * 100)) -ForegroundColor DarkGray }

if (-not (Test-KitWinget)) {
    Write-Host '  winget (App Installer) is missing - most installs need it.' -ForegroundColor Red
    Write-Host '  Opening its Microsoft Store page; install it, then run install.cmd again.' -ForegroundColor Gray
    if (-not $script:Testing) { try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch {} }
}

Write-Host '  Checking what is installed on this PC...' -ForegroundColor DarkGray
$installed = Get-KitInstalled

function Show-Menu {
    Clear-Kit
    $on = @($cat | Where-Object On).Count
    $dry = if ($DryRun) { '  |  DRY RUN' } else { '' }
    Write-Host ''
    Write-Host "  my-win-kit  |  classic menu (PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor))  |  $on selected$dry" -ForegroundColor DarkYellow
    Write-Rule
    $colW = 33
    $cols = 3
    try { if ($Host.UI.RawUI.WindowSize.Width -lt 104) { $cols = 2 } } catch {}
    foreach ($g in $groups) {
        $items = @($cat | Where-Object Group -eq $g.Key | Sort-Object Id)
        if (-not $items) { continue }
        $hdr = "  [$($g.Letter)] $($g.Label.ToUpper())"
        if ($g.Key -eq 'POST') { $hdr += '  (runs last; never selected by *)' }
        Write-Host $hdr -ForegroundColor Yellow
        for ($i = 0; $i -lt $items.Count; $i += $cols) {
            Write-Host '    ' -NoNewline
            for ($c = 0; $c -lt $cols -and ($i + $c) -lt $items.Count; $c++) {
                $p = $items[$i + $c]
                $box = if ($p.On) { '[x]' } else { '[ ]' }
                $mark = if ($installed.ContainsKey($p.Id)) { '*' } else { ' ' }
                $txt = ('{0} {1,2} {2}{3}' -f $box, $p.Id, $p.Name, $mark)
                if ($txt.Length -gt $colW - 1) { $txt = $txt.Substring(0, $colW - 1) }
                $color = if ($p.On) { 'Green' } else { 'Gray' }
                Write-Host $txt.PadRight($colW) -ForegroundColor $color -NoNewline
            }
            Write-Host ''
        }
    }
    Write-Rule
    Write-Host '  Toggle: numbers  1 5 12  ranges 20-27  group letters  U D   * = all (not post)  0 = none' -ForegroundColor DarkGray
    Write-Host '          Z = recommended set   N = recommended, only what is new here   (* after a name = installed)' -ForegroundColor DarkGray
    Write-Host '  I = install selected   L = latest AI tools   W = Windows tweaks   Q = quit' -ForegroundColor Cyan
}

function Invoke-ClassicRun([object[]]$Selection, [string]$Mode = 'install') {
    $order = @(Get-KitRunOrder $Selection)
    Clear-Kit
    $log = Start-KitLog
    $before = @(); if ($state.RemoveShortcuts) { $before = @(Get-KitDesktopShortcuts) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $results = @()
    Write-Host ''
    for ($i = 0; $i -lt $order.Count; $i++) {
        $p = $order[$i]
        $inst = $null; if ($installed.ContainsKey($p.Id)) { $inst = $installed[$p.Id] }
        Write-Host ('  [{0}/{1}] {2,-24} {3,-8} ' -f ($i + 1), $order.Count, $p.Name, $p.Method) -NoNewline
        if ($p.Interactive -and -not $DryRun) { Write-Host 'interactive - answer its prompts' -ForegroundColor Magenta }
        $r = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -DryRun:$DryRun
        if ($p.Interactive -and -not $DryRun) { Write-Host '                                         ' -NoNewline }
        $color = switch ($r.Status) { 'failed' { 'Red' } 'dryrun' { 'Magenta' } 'current' { 'DarkCyan' } default { 'Green' } }
        $ver = if ($r.From -and $r.To -and $r.From -ne $r.To) { "$($r.From) -> $($r.To)" } elseif ($r.To) { $r.To } else { $r.From }
        Write-Host ("{0,-10} {1} ({2}s)" -f $r.Status.ToUpper(), $ver, $r.Seconds) -ForegroundColor $color
        if ($r.Healed) { Write-Host "         healed: $($r.Healed)" -ForegroundColor DarkCyan }
        if ($r.Detail -and $r.Status -in 'failed', 'dryrun') { Write-Host "         $($r.Detail)" -ForegroundColor DarkGray }
        $results += $r
        if ($r.Status -ne 'failed') { $p.On = $false }
    }
    if ($state.RemoveShortcuts -and -not $DryRun) {
        $rm = @(Remove-KitNewShortcuts -Before $before)
        if ($rm.Count) { Write-Host "  Removed $($rm.Count) new desktop shortcut(s): $($rm -join ', ')" -ForegroundColor DarkGray }
    }
    $fl = @($results | Where-Object Status -eq 'failed').Count
    Write-Rule
    Write-Host ("  Done: {0} ok, {1} failed, {2:0.0}s.  Log: {3}" -f ($results.Count - $fl), $fl, $sw.Elapsed.TotalSeconds, $log) -ForegroundColor $(if ($fl) { 'Yellow' } else { 'Green' })
    if ($fl) { Write-Host '  Failed apps stay selected - press I to retry.' -ForegroundColor Yellow }
    $state.LastSelection = @($Selection | ForEach-Object Id)
    $state.LastFailed = @($results | Where-Object Status -eq 'failed' | ForEach-Object Id)
    if (-not $DryRun) { Save-KitState $state }
    [void](Read-Answer 'Press Enter to continue')
    $script:installed = Get-KitInstalled
}

$letters = @{}; foreach ($g in $groups) { $letters[$g.Letter] = $g.Key }

while ($true) {
    Show-Menu
    $ans = Read-Answer '>'
    if ([string]::IsNullOrWhiteSpace($ans)) { continue }
    $u = $ans.Trim().ToUpper()
    # Commands use letters that are NOT group letters (U A B C P M R S E T G O D X)
    if ($u -eq 'Q') { exit 0 }
    if ($u -eq 'I') {
        $sel = @($cat | Where-Object On)
        if ($sel.Count -gt 0) {
            $ok = Read-Answer "Install/update $($sel.Count) app(s)? [Y/n]"
            if ($ok -notmatch '^[Nn]') { Invoke-ClassicRun $sel }
        }
        continue
    }
    if ($u -eq 'L') {
        $ai = @($cat | Where-Object { $_.AI -and $installed.ContainsKey($_.Id) })
        if ($ai.Count -gt 0) {
            Write-Host "  AI tools installed here: $(($ai | ForEach-Object { "$($_.Name) $($installed[$_.Id])" }) -join ', ')" -ForegroundColor Gray
            $ok = Read-Answer 'Update them to the latest versions? [Y/n]'
            if ($ok -notmatch '^[Nn]') { Invoke-ClassicRun $ai 'update' }
        }
        continue
    }
    if ($u -eq 'W') {
        $tw = Join-Path $KitRoot 'win11-tweaks.ps1'
        if ($DryRun) { Write-Host "  would run: powershell -File $tw" -ForegroundColor Magenta; [void](Read-Answer 'Press Enter') }
        else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tw }
        continue
    }
    if ($u -eq 'Z') { foreach ($p in $cat) { $p.On = $p.Default }; continue }
    if ($u -eq 'N') { foreach ($p in $cat) { $p.On = $p.Default -and -not $installed.ContainsKey($p.Id) }; continue }

    foreach ($tok in ($u -split '[,\s]+' | Where-Object { $_ })) {
        $n = 0
        if ($tok -match '^(\d+)-(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]; if ($lo -gt $hi) { $x = $lo; $lo = $hi; $hi = $x }
            $cat | Where-Object { $_.Id -ge $lo -and $_.Id -le $hi } | ForEach-Object { $_.On = -not $_.On }
        }
        elseif ($tok -eq '*') { $cat | Where-Object { $_.Group -ne 'POST' } | ForEach-Object { $_.On = $true } }
        elseif ($tok -eq '0') { $cat | ForEach-Object { $_.On = $false } }
        elseif ([int]::TryParse($tok, [ref]$n)) { $cat | Where-Object Id -eq $n | ForEach-Object { $_.On = -not $_.On } }
        elseif ($letters.ContainsKey($tok)) {
            $m = @($cat | Where-Object Group -eq $letters[$tok]); $any = @($m | Where-Object On).Count -gt 0
            $m | ForEach-Object { $_.On = -not $any }
        }
    }
}
