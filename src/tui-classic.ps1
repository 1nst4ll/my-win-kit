#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit classic menu: the fallback for stock Windows PowerShell 5.1.
.DESCRIPTION
    Runs when PowerShell 7 is missing or declined, or the Spectre module
    cannot load, so a fresh PC is never stuck. Deliberately simple: numbered
    toggles, then the same install engine (src/core.psm1) as the modern menu.
    Colour: 24-bit gruvbox through VT escape codes when the host supports
    them, otherwise the 16 console colours. Fits 120 x 30.
.PARAMETER KitRoot
    Folder that holds install.ps1.
.PARAMETER DryRun
    Show what would run, install nothing.
.PARAMETER TestInput
    Smoke test: answers separated by ";" fed to the prompts in order (then Q).
    Forces -DryRun. One string because `powershell -File` cannot pass arrays.
.PARAMETER Auto
    Unattended run (install.cmd /auto): no menu, no questions. Installs the
    recommended apps that are missing and updates the installed ones
    (Get-KitAutoPlan), skips what needs a person, prints the summary and
    exits 0 (all ok) or 1 (something failed).
.PARAMETER Pause
    With -Auto: wait for Enter at the end.
.NOTES
    Keep ASCII-only (glyphs come from [char] codes, all present in Consolas and
    Cascadia Mono) and Windows PowerShell 5.1 compatible.
    Env MYWINKIT_FORCE_VT=1 forces truecolor output (screen captures).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [switch]$DryRun,
    [string]$TestInput,
    [switch]$Auto,
    [switch]$Pause
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $KitRoot 'src\core.psm1') -Force

$script:Testing = $PSBoundParameters.ContainsKey('TestInput')
if ($script:Testing) { $DryRun = $true }
$script:Queue = New-Object System.Collections.Queue
if ($script:Testing) { foreach ($t in ($TestInput -split ";")) { $script:Queue.Enqueue($t) } }

$cat    = @(Initialize-Kit -KitRoot $KitRoot)
if ((Get-KitSetting 'dryRunByDefault' $false) -and -not $DryRun) { $DryRun = $true; Write-KitRunLog 'classic: dry run because settings.dryRunByDefault is on' }
$groups = @(Get-KitGroups)
$state  = Get-KitState
try { $Host.UI.RawUI.WindowTitle = "my-win-kit $([char]0x00B7) classic (PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor))" } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------- colour

$script:ESC = [char]27
$script:VT = $false
if ($env:MYWINKIT_FORCE_VT -eq '1') { $script:VT = $true }
elseif (-not [Console]::IsOutputRedirected) {
    try { $script:VT = [bool]$Host.UI.SupportsVirtualTerminal -or [bool]$env:WT_SESSION } catch {}
}
# A child process can leave the console with VT processing off; switch it back on (best effort).
function Restore-Vt { if ($script:VT) { [void](Enable-KitConsoleVt) } }
# gruvbox hex + the 16-colour fallback for each role
$Pal = @{
    Orange = @('#fe8019', 'DarkYellow'); Yellow = @('#fabd2f', 'Yellow'); Green = @('#b8bb26', 'Green')
    Red = @('#fb4934', 'Red'); Aqua = @('#8ec07c', 'Cyan'); Blue = @('#83a598', 'DarkCyan')
    Purple = @('#d3869b', 'Magenta'); Gray = @('#928374', 'DarkGray'); Fg = @('#ebdbb2', 'Gray'); Line = @('#665c54', 'DarkGray')
}
function Write-C([string]$Text, $Role, [switch]$NoNewline) {
    if ($script:VT) {
        $h = $Role[0]
        $rgb = '{0};{1};{2}' -f [Convert]::ToInt32($h.Substring(1, 2), 16), [Convert]::ToInt32($h.Substring(3, 2), 16), [Convert]::ToInt32($h.Substring(5, 2), 16)
        Write-Host "$($script:ESC)[38;2;$($rgb)m$Text$($script:ESC)[0m" -NoNewline:$NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Role[1] -NoNewline:$NoNewline
    }
}
function Write-Gradient([string]$Text, [int]$Width) {
    <# Left-to-right orange -> yellow -> green -> aqua; 16-colour hosts get 4 bands. #>
    $stops = @($Pal.Orange, $Pal.Yellow, $Pal.Green, $Pal.Aqua)
    if ($Width -lt 2) { $Width = [Math]::Max(2, $Text.Length) }
    for ($c = 0; $c -lt $Text.Length; $c += 2) {
        $chunk = $Text.Substring($c, [Math]::Min(2, $Text.Length - $c))
        $t = $c / ($Width - 1)
        if ($script:VT) {
            $seg = [Math]::Min([int][Math]::Floor($t * 3), 2); $f = ($t * 3) - $seg
            $a = $stops[$seg][0]; $b = $stops[$seg + 1][0]
            $rgb = foreach ($o in 1, 3, 5) { $x = [Convert]::ToInt32($a.Substring($o, 2), 16); $y = [Convert]::ToInt32($b.Substring($o, 2), 16); [int]($x + ($y - $x) * $f) }
            Write-Host "$($script:ESC)[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$chunk$($script:ESC)[0m" -NoNewline
        } else {
            Write-Host $chunk -ForegroundColor $stops[[Math]::Min([int][Math]::Floor($t * 4), 3)][1] -NoNewline
        }
    }
    Write-Host ''
}

function C([int]$cp) { return [string][char]$cp }
$Gl = @{ Ok = C 0x221A; Up = C 0x2191; Not = C 0x00B7; Fail = C 0x00D7; Heal = C 0x2194; Dry = C 0x25CB; Dot = C 0x00B7; Arrow = C 0x2192; Ell = C 0x2026; Line = C 0x2500 }
$GroupIcon = @{ UTIL = 0x2261; OFCE = 0x00B6; BROW = 0x25BA; CLOU = 0x221E; PDF = 0x00A7; COMM = 0x263A; REMO = 0x2194; SECU = 0x2666; MEDI = 0x266B; MAIN = 0x2302; DSGN = 0x2660; OTHR = 0x2022; DEV = 0x00BB; POST = 0x25B2 }
$GroupRole = @{ UTIL = 'Yellow'; OFCE = 'Blue'; BROW = 'Aqua'; CLOU = 'Blue'; PDF = 'Red'; COMM = 'Green'; REMO = 'Aqua'; SECU = 'Purple'; MEDI = 'Orange'; MAIN = 'Yellow'; DSGN = 'Purple'; OTHR = 'Fg'; DEV = 'Orange'; POST = 'Red' }

# 2-row block-letter banner: '#' = full block, '^' = upper half, '_' = lower half
$script:Banner = @(
    '#^_^# #_#   # # # # #_ #   #_^ # ^#^',
    '# ^ #  #    ^_^_^ # # ^#   # # #  # '
) | ForEach-Object { $_.Replace('#', (C 0x2588)).Replace('^', (C 0x2580)).Replace('_', (C 0x2584)) }

$script:Admin = Test-KitAdmin
Write-KitRunLog ("frontend: {5} started (src\tui-classic.ps1) - PowerShell {0} ({1}), truecolor VT={2}, dryrun={3}, test={4}, elevated={6}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $script:VT, [bool]$DryRun, $script:Testing, $(if ($Auto) { 'UNATTENDED (classic -Auto)' } else { 'CLASSIC' }), $(if ($script:Admin) { 'yes' } else { 'no' }))

# ---------------------------------------------------------------- helpers

function Read-Answer([string]$Prompt) {
    Write-C "  $Prompt " $Pal.Orange -NoNewline
    if ($script:Testing) {
        $a = if ($script:Queue.Count) { [string]$script:Queue.Dequeue() } else { 'Q' }
        Write-Host $a
        return $a
    }
    return (Read-Host)
}
function Clear-Kit { if (-not $script:Testing) { Clear-Host } }
function Write-Rule { Write-C ('  ' + ($Gl.Line * 112)) $Pal.Line }
function Format-Cut([string]$s, [int]$n) { if ($s.Length -le $n) { return $s.PadRight($n) } return $s.Substring(0, $n - 1) + $Gl.Ell }

function Write-Badge($p) {
    if (-not $installed.ContainsKey($p.Id)) { Write-C $Gl.Not $Pal.Gray -NoNewline }
    elseif ($updates.ContainsKey($p.Id)) { Write-C $Gl.Up $Pal.Yellow -NoNewline }
    else { Write-C $Gl.Ok $Pal.Green -NoNewline }
}

if (-not (Test-KitWinget)) {
    Write-C '  winget (App Installer) is missing - most installs need it.' $Pal.Red
    Write-C '  Opening its Microsoft Store page; install it, then run install.cmd again.' $Pal.Fg
    if (-not $script:Testing -and -not $Auto) { try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch {} }
}

Write-C '  Checking what is installed on this PC and looking for updates...' $Pal.Gray
$installed = Get-KitInstalled
$updates = Get-KitUpdates -Installed $installed
Restore-Vt

function Show-Menu {
    Clear-Kit
    $on = @($cat | Where-Object On).Count
    foreach ($b in $script:Banner) { Write-Host '  ' -NoNewline; Write-Gradient $b $b.Length }
    Write-C "  v$(Get-KitVersion) $($Gl.Dot) classic menu $($Gl.Dot) PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) $($Gl.Dot) " $Pal.Gray -NoNewline
    Write-C "$on selected" $Pal.Orange -NoNewline
    $ci = Get-KitConfigInfo; $cfg = switch ($ci.Kind) { 'github' { 'config GitHub' } 'cache' { "config cached $($ci.Detail)" } default { "config $($ci.Kind)" } }
    Write-C " $($Gl.Dot) $cfg" $(if ($ci.Kind -eq 'github') { $Pal.Green } else { $Pal.Yellow }) -NoNewline
    if ($script:Admin) { Write-C " $($Gl.Dot) " $Pal.Gray -NoNewline; Write-C 'ADMIN' $Pal.Orange -NoNewline }
    if ($DryRun) { Write-C "   $($Gl.Dry) DRY RUN - nothing installs" $Pal.Purple } else { Write-Host '' }
    Write-Rule
    # One row block per group: header column (22) + 4 cells of 22
    foreach ($g in $groups) {
        $items = @($cat | Where-Object Group -eq $g.Key | Sort-Object Id)
        if (-not $items) { continue }
        # groups added to config/catalog.json by hand have no icon/colour here: neutral fallback
        $role = if ($GroupRole.ContainsKey($g.Key)) { $Pal[$GroupRole[$g.Key]] } else { $Pal.Fg }
        $icon = if ($GroupIcon.ContainsKey($g.Key)) { $GroupIcon[$g.Key] } else { 0x2022 }
        $letter = if ($g.Letter) { $g.Letter } else { '-' }
        for ($i = 0; $i -lt $items.Count; $i += 4) {
            if ($i -eq 0) { Write-C ('  ' + (Format-Cut "$letter $(C $icon) $($g.Label.ToUpper())" 20)) $role -NoNewline }
            else { Write-Host (' ' * 22) -NoNewline }
            for ($c = 0; $c -lt 4 -and ($i + $c) -lt $items.Count; $c++) {
                $p = $items[$i + $c]
                if ($p.On) { Write-C '[x]' $Pal.Green -NoNewline } else { Write-C '[ ]' $Pal.Line -NoNewline }
                Write-C ('{0,2} ' -f $p.Id) $Pal.Gray -NoNewline
                Write-C (Format-Cut $p.Name 14) $(if ($p.On) { $Pal.Fg } else { $Pal.Gray }) -NoNewline
                Write-Badge $p
                Write-Host ' ' -NoNewline
            }
            Write-Host ''
        }
    }
    Write-Rule
    Write-C "  $($Gl.Ok) installed  " $Pal.Green -NoNewline; Write-C "$($Gl.Up) update  " $Pal.Yellow -NoNewline; Write-C "$($Gl.Not) not installed    " $Pal.Gray -NoNewline
    Write-C 'toggle  1 5 12  20-27  letter  * all but X  0 none  Z recommended  N only new' $Pal.Gray
    Write-C '  I' $Pal.Orange -NoNewline; Write-C ' install  ' $Pal.Fg -NoNewline; Write-C 'L' $Pal.Orange -NoNewline; Write-C ' update  ' $Pal.Fg -NoNewline
    Write-C 'W' $Pal.Orange -NoNewline; Write-C ' tweaks  ' $Pal.Fg -NoNewline
    # per-PC switches: value + where it comes from
    foreach ($tg in @(@{ Key = 'K'; Label = ' essentials on start: '; Val = (Get-KitAutoInstallEssentials) }, @{ Key = 'V'; Label = ' admin at start: '; Val = (Get-KitElevateAtStart) })) {
        Write-C $tg.Key $Pal.Orange -NoNewline; Write-C $tg.Label $Pal.Fg -NoNewline
        Write-C $(if ($tg.Val.On) { 'on' } else { 'off' }) $(if ($tg.Val.On) { $Pal.Green } else { $Pal.Gray }) -NoNewline
        Write-C $(if ($tg.Val.Source -eq 'this PC') { ' (this PC)  ' } else { ' (shared)  ' }) $Pal.Gray -NoNewline
    }
    Write-C 'Q' $Pal.Orange -NoNewline; Write-C ' quit' $Pal.Fg
}

function Invoke-ClassicRun([object[]]$Selection, [string]$Mode = 'install', [switch]$Unattended) {
    $order = @(Get-KitRunOrder $Selection)
    if (-not $Unattended) { Clear-Kit }
    $log = Start-KitLog
    $before = @(); if (Get-KitSetting 'removeShortcuts' $true) { $before = @(Get-KitDesktopShortcuts) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $results = @()
    Write-Host ''
    if ($DryRun) { Write-C "  $($Gl.Dry) DRY RUN - simulation only, nothing will be installed or changed" $Pal.Purple }
    for ($i = 0; $i -lt $order.Count; $i++) {
        $p = $order[$i]
        $inst = $null; if ($installed.ContainsKey($p.Id)) { $inst = $installed[$p.Id] }
        Write-C ('  [{0}/{1}] ' -f ($i + 1), $order.Count) $Pal.Orange -NoNewline
        Write-C ('{0,-24} ' -f $p.Name) $Pal.Fg -NoNewline
        Write-C ('{0,-8} ' -f $(if ($p.Method -eq 'winget-upgrade') { 'upgrade' } else { $p.Method })) $Pal.Gray -NoNewline
        if ($p.Interactive -and -not $DryRun) { Write-C 'interactive - answer its prompts' $Pal.Purple }
        $onStatus = $null
        if ($p.Interactive -and -not $DryRun) { $onStatus = { param($m) Write-C "         $m" $Pal.Gray } }
        $r = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -DryRun:$DryRun -OnStatus $onStatus
        Restore-Vt
        if ($p.Interactive -and -not $DryRun) { Write-Host (' ' * 43) -NoNewline }
        $badge, $role = switch ($r.Status) {
            'failed'  { $Gl.Fail, $Pal.Red }
            'dryrun'  { $Gl.Dry, $Pal.Purple }
            'current' { '=', $Pal.Aqua }
            'updated' { $Gl.Up, $Pal.Green }
            default   { $Gl.Ok, $Pal.Green }
        }
        $ver = if ($r.From -and $r.To -and $r.From -ne $r.To) { "$($r.From) $($Gl.Arrow) $($r.To)" } elseif ($r.To) { $r.To } else { $r.From }
        Write-C ("{0} {1,-9} {2} ({3}s)" -f $badge, $r.Status.ToUpper(), $ver, $r.Seconds) $role
        if ($r.Healed) { Write-C "         $($Gl.Heal) healed: $($r.Healed)" $Pal.Aqua }
        if ($r.Detail -and $r.Status -in 'failed', 'dryrun') { Write-C "         $($r.Detail)" $Pal.Gray }
        $results += $r
        if ($r.Status -ne 'failed') { $p.On = $false }
    }
    if ((Get-KitSetting 'removeShortcuts' $true) -and -not $DryRun) {
        $rm = @(Remove-KitNewShortcuts -Before $before)
        if ($rm.Count) { Write-C "  Removed $($rm.Count) new desktop shortcut(s): $($rm -join ', ')" $Pal.Gray }
    }
    $fl = @($results | Where-Object Status -eq 'failed').Count
    $hl = @($results | Where-Object Healed).Count
    Write-Rule
    Write-C ('  Done: ') $Pal.Fg -NoNewline
    Write-C "$($Gl.Ok) $($results.Count - $fl) ok   " $Pal.Green -NoNewline
    Write-C "$($Gl.Heal) $hl healed   " $Pal.Aqua -NoNewline
    Write-C "$($Gl.Fail) $fl failed   " $Pal.Red -NoNewline
    Write-C ('{0:0.0}s' -f $sw.Elapsed.TotalSeconds) $Pal.Fg
    Write-C "  Log: $log" $Pal.Gray
    $script:LastResults = @($results)
    if ($fl -and -not $Unattended) { Write-C '  Failed apps stay selected - press I to retry.' $Pal.Yellow }
    $state.LastSelection = @($Selection | Where-Object { $_.Id -gt 0 } | ForEach-Object Id)   # rest-of-PC upgrades have negative Ids
    $state.LastFailed = @($results | Where-Object { $_.Status -eq 'failed' -and $_.Id -gt 0 } | ForEach-Object Id)
    if (-not $DryRun) { Save-KitState $state }
    if ($Unattended) { return }
    [void](Read-Answer 'Press Enter to continue')
    $script:installed = Get-KitInstalled
    $script:updates = Get-KitUpdates -Installed $script:installed
    Restore-Vt
}

if ($Auto) {
    # ------------------------------------------------------------ unattended run (install.cmd /auto): no menu, no questions
    $plan = Get-KitAutoPlan -Installed $installed -Updates $updates -Packages $cat
    Write-Host ''
    Write-Gradient '  my-win-kit - unattended run' 30
    $adm = if ($script:Admin) { 'as administrator (nothing else will ask)' } else { 'without administrator rights (installers may ask)' }
    Write-C "  v$(Get-KitVersion) $($Gl.Dot) $adm $($Gl.Dot) $($plan.Install.Count) to install, $($plan.Update.Count) kit apps + $($plan.Other.Count) other apps to update" $Pal.Gray
    Write-KitRunLog "auto: elevated=$(if ($script:Admin) { 'yes' } else { 'no' }); install [$(@($plan.Install | ForEach-Object Name) -join ', ')]; update [$(@($plan.Update | ForEach-Object Name) -join ', ')]; other PC apps [$(@($plan.Other | ForEach-Object Ref) -join ', ')]; skipped [$(@($plan.Skipped | ForEach-Object Name) -join ', ')]"
    $results = @()
    if ($plan.Run.Count) {
        Invoke-ClassicRun $plan.Run 'install' -Unattended
        $results = @($script:LastResults)
    } else {
        Write-C "  Nothing to do: every recommended app is installed and nothing on this PC has an update." $Pal.Green
        Write-C "  Log: $(Start-KitLog)" $Pal.Gray
    }
    if ($plan.Skipped.Count) {
        Write-C "  Skipped (needs you): $(@($plan.Skipped | ForEach-Object Name) -join ', ')" $Pal.Yellow
        Write-C '  Run install.cmd without /auto to do these.' $Pal.Gray
    }
    $code = Get-KitAutoExitCode -Results $results
    if ($env:MYWINKIT_RUNLOG) { Write-C "  Run log: $env:MYWINKIT_RUNLOG" $Pal.Gray }
    Write-C "  Exit code $code ($(if ($code) { 'something failed' } else { 'all ok' }))" $(if ($code) { $Pal.Red } else { $Pal.Green })
    Write-KitRunLog "auto: finished, $(@($results | Where-Object Status -eq 'failed').Count) failed of $($results.Count), exit $code"
    if ($Pause -and -not $script:Testing) { [void](Read-Host '  Press Enter to close') }
    exit $code
}

$letters = @{}; foreach ($g in $groups) { $letters[$g.Letter] = $g.Key }

while ($true) {
    Show-Menu
    $ans = Read-Answer '>'
    if ([string]::IsNullOrWhiteSpace($ans)) { continue }
    $u = $ans.Trim().ToUpper()
    # Commands use letters that are NOT group letters (U A B C P M R S E T G O D X): Q I L W K V Z N
    if ($u -eq 'Q') {
        Write-Host ''
        $bye = ((C 0x2591) + (C 0x2592) + (C 0x2593)) + ((C 0x2550) * 20) + ' see you next time ' + ((C 0x2550) * 20) + ((C 0x2593) + (C 0x2592) + (C 0x2591))
        Write-Host '  ' -NoNewline; Write-Gradient $bye $bye.Length
        exit 0
    }
    if ($u -eq 'I') {
        $sel = @($cat | Where-Object On)
        if ($sel.Count -gt 0) {
            $ok = Read-Answer "Install/update $($sel.Count) app(s)? [Y/n]"
            if ($ok -notmatch '^[Nn]') { Invoke-ClassicRun $sel }
        }
        continue
    }
    if ($u -eq 'L') {
        # Update submenu: 1 everything (kit apps + the rest of the PC), 2 AI tools only; Enter = back
        Write-C '  Update: ' $Pal.Fg -NoNewline; Write-C '1' $Pal.Orange -NoNewline; Write-C ' everything (kit apps + rest of PC)   ' $Pal.Fg -NoNewline
        Write-C '2' $Pal.Orange -NoNewline; Write-C ' AI tools only   ' $Pal.Fg -NoNewline; Write-C 'Enter back' $Pal.Gray
        $sub = Read-Answer '>'
        if ($sub -eq '1') {
            Write-C '  Looking for updates (catalogue + winget upgrade)...' $Pal.Gray
            $script:updates = Get-KitUpdates -Installed $installed
            $plan = Get-KitUpdateAllPlan -Installed $installed -Updates $script:updates -Packages $cat
            Restore-Vt
            $cut = { param($list) $n = @($list | ForEach-Object Name); if ($n.Count -gt 8) { (($n | Select-Object -First 8) -join ', ') + " $($Gl.Ell) +$($n.Count - 8)" } else { $n -join ', ' } }
            Write-C "  Kit apps ($($plan.Kit.Count)): $(& $cut $plan.Kit)" $Pal.Fg
            Write-C "  Other apps on this PC ($($plan.Other.Count)): $(& $cut $plan.Other)" $Pal.Fg
            if ($plan.Run.Count) {
                $ok = Read-Answer "Update all $($plan.Run.Count)? [Y/n]"
                if ($ok -notmatch '^[Nn]') { Invoke-ClassicRun $plan.Run 'update' }
            } else { [void](Read-Answer 'Everything is up to date. Press Enter') }
        } elseif ($sub -eq '2') {
            $ai = @(Get-KitAiUpdateSet -Installed $installed -Packages $cat)   # installed AI tools only, never new ones
            if ($ai.Count -gt 0) {
                Write-C "  AI tools installed here: $(($ai | ForEach-Object { "$($_.Name) $($installed[$_.Id])" }) -join ', ')" $Pal.Fg
                $ok = Read-Answer 'Update them to the latest versions? [Y/n]'
                if ($ok -notmatch '^[Nn]') { Invoke-ClassicRun $ai 'update' }
            } else { [void](Read-Answer 'No AI tools installed here. Press Enter') }
        }
        continue
    }
    if ($u -eq 'W') {
        $tw = Join-Path $KitRoot 'win11-tweaks.ps1'
        if ($DryRun) { Write-C "  $($Gl.Dry) would run: powershell -File $tw" $Pal.Purple; [void](Read-Answer 'Press Enter') }
        else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tw }
        continue
    }
    if ($u -eq 'K') {
        # per-PC preference (local-settings.json, never GitHub); tests only write into their scratch state folder
        if (-not $script:Testing -or $env:MYWINKIT_STATE_DIR) { Set-KitLocalPref -Name 'autoInstallEssentials' -Value (-not (Get-KitAutoInstallEssentials).On) }
        continue
    }
    if ($u -eq 'V') {
        # per-PC: ask for administrator rights once at start (takes effect at the next start)
        if (-not $script:Testing -or $env:MYWINKIT_STATE_DIR) { Set-KitLocalPref -Name 'elevateAtStart' -Value (-not (Get-KitElevateAtStart).On) }
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
