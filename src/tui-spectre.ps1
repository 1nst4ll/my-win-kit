#Requires -Version 7.4
<#
.SYNOPSIS
    my-win-kit modern menu (PowerShell 7.4+ with PwshSpectreConsole).
.DESCRIPTION
    Started by install.ps1 when PowerShell 7.4+ is present. Renders screens
    and collects choices; all install work happens in src/core.psm1.
    Exit codes: 0 = normal quit, 3 = Spectre unavailable (the loader then
    falls back to the classic menu).
.PARAMETER KitRoot
    Folder that holds install.ps1 (and the synced winget-id-overrides.json).
.PARAMETER DryRun
    Simulate: show what would run, install nothing.
.PARAMETER TestKeys
    Smoke test: comma-separated keys (DownArrow, Enter, Spacebar, text:abc)
    fed to a Spectre TestConsole. Forces -DryRun. Used by tools/smoke-tui.ps1.
.NOTES
    Keep ASCII-only (glyphs come from [char] codes) and parseable by 5.1
    (CI parses every file under both editions).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [switch]$DryRun,
    [string]$TestKeys
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- Spectre module

function Initialize-SpectreModule {
    $min = [version]'2.3.0'
    $have = Get-Module -ListAvailable PwshSpectreConsole | Where-Object { $_.Version -ge $min } | Select-Object -First 1
    if (-not $have) {
        Write-Host '  First run on this PC: installing the PwshSpectreConsole module (current user)...' -ForegroundColor DarkYellow
        try {
            Install-PSResource -Name PwshSpectreConsole -Scope CurrentUser -TrustRepository -Quiet -ErrorAction Stop
        } catch {
            try { Install-Module PwshSpectreConsole -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }
            catch { Write-Host "  Could not install PwshSpectreConsole: $($_.Exception.Message)" -ForegroundColor Red; return $false }
        }
    }
    try { Import-Module PwshSpectreConsole -MinimumVersion $min -ErrorAction Stop; return $true }
    catch { Write-Host "  Could not load PwshSpectreConsole: $($_.Exception.Message)" -ForegroundColor Red; return $false }
}

if (-not (Initialize-SpectreModule)) { exit 3 }
Import-Module (Join-Path $KitRoot 'src\core.psm1') -Force
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------- look

# Gruvbox dark
$script:Hex = @{
    Orange = '#fe8019'; Yellow = '#fabd2f'; Green = '#b8bb26'; Red = '#fb4934'
    Aqua = '#8ec07c'; Blue = '#83a598'; Purple = '#d3869b'; Gray = '#928374'
    Fg = '#ebdbb2'; Line = '#665c54'
}
$script:Glyph = @{
    Ok = [string][char]0x2713; Up = [string][char]0x2191; Same = [string][char]0x00B7; Fail = [string][char]0x2717
    Heal = [string][char]0x21BB; Dry = [string][char]0x25CB; Dot = [string][char]0x00B7; Warn = '!'
}
Set-SpectreColors -AccentColor $Hex.Orange -DefaultValueColor $Hex.Gray

# ---------------------------------------------------------------- test console (smoke test)

$script:Test = $null
if ($TestKeys) {
    $DryRun = $true
    $tc = [Spectre.Console.Testing.TestConsole]::new()
    $tc.Profile.Width = 120
    $tc.Profile.Height = 40
    $tc.Profile.Capabilities.Interactive = $true
    foreach ($k in ($TestKeys -split ',')) {
        $k = $k.Trim(); if (-not $k) { continue }
        if ($k -like 'text:*') { $tc.Input.PushText($k.Substring(5)) } else { $tc.Input.PushKey([ConsoleKey]$k) }
    }
    [Spectre.Console.AnsiConsole]::Console = $tc
    $script:Test = $tc
}

# ---------------------------------------------------------------- helpers

function E([string]$s) { return [Spectre.Console.Markup]::Escape("$s") }
function Get-Plural([int]$n, [string]$word) { if ($n -eq 1) { return "1 $word" } return "$n $($word)s" }
function Say([string]$markup = '') { [Spectre.Console.AnsiConsole]::MarkupLine($markup) }
function Out-Render($r) { [Spectre.Console.AnsiConsole]::Write($r) }
function Clear-Screen {
    if ($script:Test) { Say ''; return }
    try { [Spectre.Console.AnsiConsole]::Clear() } catch { Say '' }   # no console handle (redirected output)
}
function Get-PageSize {
    $h = 30
    try { if (-not $script:Test) { $h = [Console]::WindowHeight } } catch {}
    return [Math]::Max(5, $h - 9)
}

function Show-Prompt($Prompt) {
    # Module's async wrapper keeps Ctrl+C working; plain Show() as fallback.
    $mod = Get-Module PwshSpectreConsole
    try { return & $mod { param($p) Invoke-SpectrePromptAsync -Prompt $p } $Prompt }
    catch [System.Management.Automation.CommandNotFoundException] { return $Prompt.Show([Spectre.Console.AnsiConsole]::Console) }
}

function Select-One {
    <# One choice from an ordered list of @{ Key; Label } (Label = markup). Returns Key. #>
    param([string]$Title, [object[]]$Items, [switch]$Search)
    $p = [Spectre.Console.SelectionPrompt[string]]::new()
    $p.Title = $Title
    $p.PageSize = [Math]::Max(3, [Math]::Min((Get-PageSize), $Items.Count))
    $p.WrapAround = $true
    $p.HighlightStyle = [Spectre.Console.Style]::Parse("$($Hex.Orange) bold")
    if ($Search) {
        $p.SearchEnabled = $true
        $p.SearchHighlightStyle = [Spectre.Console.Style]::Parse("$($Hex.Yellow) underline")
        $p.SearchPlaceholderText = "[$($Hex.Gray)](type to search)[/]"
        $p.PageSize = Get-PageSize
    }
    $map = @{}
    foreach ($it in $Items) { $map[$it.Label] = $it.Key; [void]$p.AddChoice($it.Label) }
    return $map[(Show-Prompt $p)]
}

function Confirm-Kit([string]$Question, [bool]$Default = $true) {
    $p = [Spectre.Console.ConfirmationPrompt]::new($Question)
    $p.DefaultValue = $Default
    return [bool](Show-Prompt $p)
}

function New-KitTable([string[]]$Columns) {
    $t = [Spectre.Console.Table]::new()
    $t.Border = [Spectre.Console.TableBorder]::Rounded
    $t.BorderStyle = [Spectre.Console.Style]::Parse($Hex.Line)
    foreach ($c in $Columns) { [void][Spectre.Console.TableExtensions]::AddColumn($t, "[$($Hex.Yellow)]$c[/]") }
    return $t
}
function Add-KitRow($Table, [string[]]$Cells) { [void][Spectre.Console.TableExtensions]::AddRow($Table, $Cells) }

function Show-Header([string]$Screen = '') {
    Clear-Screen
    $who = if (Test-KitAdmin) { 'administrator' } else { 'standard user' }
    $t = "[$($Hex.Orange) bold]my-win-kit[/] [$($Hex.Gray)]$($Glyph.Dot) $(E $env:COMPUTERNAME) $($Glyph.Dot) PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) $($Glyph.Dot) $who[/]"
    if ($Screen) { $t += " [$($Hex.Fg)]$($Glyph.Dot) $(E $Screen)[/]" }
    if ($script:DryRunOn) { $t += " [$($Hex.Purple) bold]$($Glyph.Dot) DRY RUN[/]" }
    $r = [Spectre.Console.Rule]::new($t)
    $r.Justification = [Spectre.Console.Justify]::Left
    $r.Style = [Spectre.Console.Style]::Parse($Hex.Line)
    Out-Render $r
    Say ''
}

function Get-MethodLabel($p) {
    switch ($p.Method) {
        'winget'  { 'winget' }
        'msstore' { 'Store' }
        'script'  { 'official script' }
        'direct'  { 'official download' }
        'npm'     { 'npm' }
        'builtin' { 'built-in' }
        default   { $p.Method }
    }
}

function Get-InstalledLabel($p) {
    if (-not $script:Installed.ContainsKey($p.Id)) { return '' }
    $v = $script:Installed[$p.Id]
    if ($v) { return "[$($Hex.Green)]$($Glyph.Ok) $(E $v)[/]" }
    return "[$($Hex.Green)]$($Glyph.Ok) installed[/]"
}

function Invoke-Scan {
    $script:Installed = @{}
    $st = [Spectre.Console.AnsiConsole]::Status()
    $st.Spinner = [Spectre.Console.Spinner+Known]::Dots
    $st.SpinnerStyle = [Spectre.Console.Style]::Parse($Hex.Orange)
    $st.Start("Checking what's installed on this PC...", [Action[Spectre.Console.StatusContext]] {
        param($ctx)
        [void]$ctx   # Spectre passes the StatusContext; not every caller needs it
        $script:Installed = Get-KitInstalled
    })
}

# ---------------------------------------------------------------- state

$script:Catalog   = @(Initialize-Kit -KitRoot $KitRoot)
$script:Groups    = @(Get-KitGroups)
$script:State     = Get-KitState
$script:DryRunOn  = [bool]$DryRun
$script:Installed = @{}

if (-not (Test-KitWinget) -and -not $script:Test) {
    Show-Header
    Say "[$($Hex.Red)]winget (App Installer) is missing - it is needed for most installs.[/]"
    Say "Opening its Microsoft Store page. Install it, then run install.cmd again."
    try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch { Say 'Manual link: https://aka.ms/getwinget' }
    [void](Confirm-Kit 'Continue anyway (script and direct installs still work)?' $false)
}

# ---------------------------------------------------------------- app picker

function Select-Apps {
    <# Grouped multi-select, preselected with $Preselect Ids. Returns package objects. #>
    param([int[]]$Preselect)
    $p = [Spectre.Console.MultiSelectionPrompt[string]]::new()
    $p.Title = "[$($Hex.Fg)]Choose apps[/]  [$($Hex.Gray)]space = toggle $($Glyph.Dot) a group header toggles the whole group $($Glyph.Dot) enter = continue[/]"
    $p.Mode = [Spectre.Console.SelectionMode]::Leaf
    $p.PageSize = Get-PageSize
    $p.WrapAround = $true
    $p.Required = $false
    $p.HighlightStyle = [Spectre.Console.Style]::Parse("$($Hex.Orange) bold")
    $p.InstructionsText = "[$($Hex.Gray)](up/down to move, space to toggle, enter to continue)[/]"
    $p.MoreChoicesText = "[$($Hex.Gray)](more apps below)[/]"

    $map = @{}
    foreach ($g in $script:Groups) {
        $items = @($script:Catalog | Where-Object Group -eq $g.Key | Sort-Object Id)
        if (-not $items) { continue }
        $gLabel = "[$($Hex.Yellow) bold]$(E $g.Label.ToUpper())[/] [$($Hex.Gray)]($($items.Count))[/]"
        if ($g.Key -eq 'POST') { $gLabel += " [$($Hex.Red)]runs last, opens its own windows[/]" }
        $node = $p.AddChoice($gLabel)
        foreach ($it in $items) {
            $label = E $it.Name
            $tags = @()
            $inst = Get-InstalledLabel $it
            if ($inst) { $tags += $inst }
            if ($it.Method -notin 'winget') { $tags += "[$($Hex.Aqua)]$(Get-MethodLabel $it)[/]" }
            if ($tags) { $label += '  ' + ($tags -join ' ') }
            $child = $node.AddChild($label)
            if ($Preselect -contains $it.Id) { [void]$child.Select() }
            $map[$label] = $it
        }
        # Leaf mode: a fully preselected group shows its header ticked too
        if (@($items | Where-Object { $Preselect -notcontains $_.Id }).Count -eq 0) { [void]$node.Select() }
    }
    $picked = @(Show-Prompt $p)
    return @($picked | ForEach-Object { $map[$_] } | Where-Object { $_ })
}

function Edit-BySearch {
    <# Type-to-search one app at a time; each pick toggles it. Returns the new selection. #>
    param([object[]]$Selection)
    $sel = @{}; foreach ($s in $Selection) { $sel[$s.Id] = $true }
    while ($true) {
        $items = @(@{ Key = 'done'; Label = "[$($Hex.Orange) bold]Done[/] [$($Hex.Gray)]($($sel.Count) selected)[/]" })
        foreach ($it in ($script:Catalog | Sort-Object Name)) {
            # Glyph boxes, not "[[x]]": escaped brackets break Spectre's search highlighting
            $box = if ($sel.ContainsKey($it.Id)) { "[$($Hex.Green)]$([char]0x25CF)[/]" } else { "[$($Hex.Gray)]$([char]0x25CB)[/]" }
            $inst = Get-InstalledLabel $it
            $items += @{ Key = "$($it.Id)"; Label = "$box $(E $it.Name)  [$($Hex.Gray)]$(E $it.Desc)[/] $inst" }
        }
        $k = Select-One -Title 'Search an app to add or remove it' -Items $items -Search
        if ($k -eq 'done' -or -not $k) { break }
        $id = [int]$k
        if ($sel.ContainsKey($id)) { $sel.Remove($id) } else { $sel[$id] = $true }
    }
    return @($script:Catalog | Where-Object { $sel.ContainsKey($_.Id) })
}

function Show-Review {
    param([object[]]$Selection)
    $t = New-KitTable @('App', 'Group', 'How', 'On this PC', 'Will')
    $gl = @{}; foreach ($g in $script:Groups) { $gl[$g.Key] = $g.Label }
    foreach ($p in (Get-KitRunOrder $Selection)) {
        $inst = Get-InstalledLabel $p
        $will = if ($p.Interactive) { "[$($Hex.Purple)]run (interactive)[/]" } elseif ($inst) { "[$($Hex.Blue)]update if newer[/]" } else { "[$($Hex.Green)]install[/]" }
        if (-not $inst) { $inst = "[$($Hex.Gray)]-[/]" }
        Add-KitRow $t @((E $p.Name), (E $gl[$p.Group]), (Get-MethodLabel $p), $inst, $will)
    }
    $n = $Selection.Count
    $have = @($Selection | Where-Object { $script:Installed.ContainsKey($_.Id) }).Count
    $t.Caption = [Spectre.Console.TableTitle]::new("$(Get-Plural $n "app") $($Glyph.Dot) $($n - $have) new $($Glyph.Dot) $have already installed")
    Out-Render $t
    if (@($Selection | Where-Object Group -eq 'POST').Count -gt 0) {
        Say "[$($Hex.Red)]$($Glyph.Warn)[/] [$($Hex.Fg)]Post-install items run last and open their own prompts or windows.[/]"
    }
    Say ''
}

# ---------------------------------------------------------------- run

function Get-ResultMarkup($r) {
    switch ($r.Status) {
        'installed' { "[$($Hex.Green)]$($Glyph.Ok) installed[/]" }
        'updated'   { "[$($Hex.Green)]$($Glyph.Up) updated[/]" }
        'current'   { "[$($Hex.Aqua)]$($Glyph.Same) up to date[/]" }
        'done'      { "[$($Hex.Green)]$($Glyph.Ok) done[/]" }
        'dryrun'    { "[$($Hex.Purple)]$($Glyph.Dry) would run[/]" }
        default     { "[$($Hex.Red)]$($Glyph.Fail) failed[/]" }
    }
}

function Get-VersionMarkup($r) {
    if ($r.From -and $r.To -and $r.From -ne $r.To) { return "$(E $r.From) $([char]0x2192) $(E $r.To)" }
    if ($r.To) { return E $r.To }
    if ($r.From) { return E $r.From }
    return "[$($Hex.Gray)]-[/]"
}

function Invoke-Run {
    <# Install/update a selection with live status, then the results table. Returns the results. #>
    param([object[]]$Selection, [ValidateSet('install', 'update')][string]$Mode = 'install', [string]$Title = 'Installing')
    $order = @(Get-KitRunOrder $Selection)
    Show-Header $Title
    $log = Start-KitLog
    $before = @(); if ($script:State.RemoveShortcuts) { $before = @(Get-KitDesktopShortcuts) }
    $total = [Diagnostics.Stopwatch]::StartNew()
    $results = @()

    for ($i = 0; $i -lt $order.Count; $i++) {
        $p = $order[$i]
        $pct = [int](($i) / $order.Count * 100)
        $head = "[$($Hex.Orange)][[$($i + 1)/$($order.Count)]][/] [$($Hex.Fg)]$(E $p.Name)[/] [$($Hex.Gray)]$(Get-MethodLabel $p) $($Glyph.Dot) $pct%[/]"
        $inst = $null; if ($script:Installed.ContainsKey($p.Id)) { $inst = $script:Installed[$p.Id] }

        if ($p.Interactive -and -not $script:DryRunOn) {
            $r = [Spectre.Console.Rule]::new("[$($Hex.Purple)]$(E $p.Name) $($Glyph.Dot) interactive, answer its prompts[/]")
            $r.Justification = [Spectre.Console.Justify]::Left; Out-Render $r
            $res = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode
        } else {
            $script:runRes = $null
            $st = [Spectre.Console.AnsiConsole]::Status()
            $st.Spinner = [Spectre.Console.Spinner+Known]::Dots
            $st.SpinnerStyle = [Spectre.Console.Style]::Parse($Hex.Orange)
            $st.Start($head, [Action[Spectre.Console.StatusContext]] {
                param($ctx)
                [void]$ctx   # Spectre passes the StatusContext; not every caller needs it
                $onStatus = { param($m) $ctx.Status = "$head [$($Hex.Gray)]$(E $m)...[/]" }
                $script:runRes = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -DryRun:$script:DryRunOn -OnStatus $onStatus
            })
            $res = $script:runRes
        }
        $results += $res
        $line = "  $(Get-ResultMarkup $res) [$($Hex.Fg)]$(E $res.Name)[/] [$($Hex.Gray)]$(Get-VersionMarkup $res) $($Glyph.Dot) $($res.Seconds)s[/]"
        if ($res.Healed) { $line += " [$($Hex.Aqua)]$($Glyph.Heal) $(E $res.Healed)[/]" }
        if ($res.Status -eq 'failed' -and $res.Detail) { $line += "`n      [$($Hex.Gray)]$(E $res.Detail)[/]" }
        Say $line
    }

    $removed = @()
    if ($script:State.RemoveShortcuts -and -not $script:DryRunOn) { $removed = @(Remove-KitNewShortcuts -Before $before) }

    # Results table
    Say ''
    $t = New-KitTable @('App', 'Result', 'Version', 'Time', 'Note')
    foreach ($r in $results) {
        $note = ''
        if ($r.Healed) { $note = "[$($Hex.Aqua)]$($Glyph.Heal) $(E $r.Healed)[/]" }
        elseif ($r.Status -in 'failed', 'dryrun' -and $r.Detail) { $note = "[$($Hex.Gray)]$(E $r.Detail)[/]" }
        Add-KitRow $t @((E $r.Name), (Get-ResultMarkup $r), (Get-VersionMarkup $r), "$($r.Seconds)s", $note)
    }
    $ok = @($results | Where-Object Status -in 'installed', 'updated', 'current', 'done', 'dryrun').Count
    $fl = @($results | Where-Object Status -eq 'failed').Count
    $hl = @($results | Where-Object Healed).Count
    $el = $total.Elapsed
    $time = if ($el.TotalMinutes -ge 1) { '{0}m {1:00}s' -f [int][Math]::Floor($el.TotalMinutes), $el.Seconds } else { '{0:0.0}s' -f $el.TotalSeconds }
    $t.Caption = [Spectre.Console.TableTitle]::new("$ok ok $($Glyph.Dot) $fl failed $($Glyph.Dot) $hl healed $($Glyph.Dot) $time")
    Out-Render $t
    if ($removed.Count) { Say "[$($Hex.Gray)]Removed $($removed.Count) new desktop shortcut(s): $(E ($removed -join ', '))[/]" }
    if ($hl) { Say "[$($Hex.Aqua)]Healed package IDs were saved to winget-id-overrides.json, so every PC starts healed.[/]" }
    Say "[$($Hex.Gray)]Log: $(E $log)[/]"
    Say ''

    $script:State.LastSelection = @($Selection | ForEach-Object Id)
    $script:State.LastFailed = @($results | Where-Object Status -eq 'failed' | ForEach-Object Id)
    if (-not $script:DryRunOn) { Save-KitState $script:State }
    return $results
}

# ---------------------------------------------------------------- screens

function Show-Install {
    Show-Header 'Install or update apps'
    if ($script:Installed.Count -eq 0) { Invoke-Scan }
    $def = @($script:Catalog | Where-Object Default)
    $missing = @($def | Where-Object { -not $script:Installed.ContainsKey($_.Id) })
    $items = @(
        @{ Key = 'def';  Label = "Recommended set [$($Hex.Gray)]($($def.Count) apps, installed ones update if newer)[/]" }
        @{ Key = 'miss'; Label = "Recommended, only what's missing here [$($Hex.Gray)]($(Get-Plural $missing.Count "app"))[/]" }
    )
    if ($script:State.LastFailed.Count)    { $items += @{ Key = 'fail'; Label = "Retry last run's failures [$($Hex.Gray)]($(Get-Plural $script:State.LastFailed.Count "app"))[/]" } }
    if ($script:State.LastSelection.Count) { $items += @{ Key = 'last'; Label = "My last selection on this PC [$($Hex.Gray)]($(Get-Plural $script:State.LastSelection.Count "app"))[/]" } }
    $items += @{ Key = 'none'; Label = 'Start empty' }
    $items += @{ Key = 'back'; Label = "[$($Hex.Gray)]Back[/]" }
    $start = Select-One -Title 'Start from' -Items $items
    $pre = switch ($start) {
        'def'  { @($def.Id) }
        'miss' { @($missing.Id) }
        'fail' { $script:State.LastFailed }
        'last' { $script:State.LastSelection }
        'none' { @() }
        default { return }
    }

    $sel = @(Select-Apps -Preselect $pre)
    while ($true) {
        Show-Header 'Review'
        if ($sel.Count -eq 0) { Say "[$($Hex.Gray)]Nothing selected.[/]"; Say '' } else { Show-Review $sel }
        $acts = @()
        if ($sel.Count) {
            $verb = if ($script:DryRunOn) { 'Simulate' } else { 'Install' }
            $acts += @{ Key = 'go'; Label = "[$($Hex.Orange) bold]$verb now[/] [$($Hex.Gray)]($(Get-Plural $sel.Count "app"))[/]" }
        }
        $acts += @{ Key = 'search'; Label = 'Search to add or remove an app' }
        $acts += @{ Key = 'edit';   Label = 'Change the selection (full list)' }
        $acts += @{ Key = 'back';   Label = "[$($Hex.Gray)]Back to main menu[/]" }
        switch (Select-One -Title 'Next' -Items $acts) {
            'go'     { [void](Invoke-Run -Selection $sel); $script:Installed = @{}; Wait-Back; return }
            'search' { $sel = @(Edit-BySearch -Selection $sel) }
            'edit'   { $sel = @(Select-Apps -Preselect @($sel.Id)) }
            default  { return }
        }
    }
}

function Wait-Back { [void](Select-One -Title '' -Items @(@{ Key = 'ok'; Label = "[$($Hex.Orange)]Back to main menu[/]" })) }

function Show-UpdateAI {
    Show-Header 'Update AI tools'
    $ai = @($script:Catalog | Where-Object AI | Sort-Object GroupOrder, Id)
    $script:latest = @{}
    $st = [Spectre.Console.AnsiConsole]::Status()
    $st.Spinner = [Spectre.Console.Spinner+Known]::Dots
    $st.SpinnerStyle = [Spectre.Console.Style]::Parse($Hex.Orange)
    $st.Start('Checking installed and latest versions...', [Action[Spectre.Console.StatusContext]] {
        param($ctx)
        [void]$ctx   # Spectre passes the StatusContext; not every caller needs it
        $script:Installed = Get-KitInstalled
        foreach ($p in $ai) { $script:latest[$p.Id] = Get-KitLatestVersion -Package $p }
    })

    $t = New-KitTable @('Tool', 'Installed', 'Latest', 'How it updates')
    foreach ($p in $ai) {
        $inst = Get-InstalledLabel $p
        if (-not $inst) { $inst = "[$($Hex.Gray)]not installed[/]" }
        $lt = $script:latest[$p.Id]
        $latest = if ($lt) { E $lt } else { "[$($Hex.Gray)]-[/]" }
        $how = switch ($p.Method) {
            'script' { if ($p.Update) { "``$(E $p.Update)`` (official updater)" } else { 'official installer' } }
            'direct' { 'official download page' }
            default  { if ($p.Appx) { 'winget + updates itself' } else { 'winget' } }
        }
        if ($lt -and $script:Installed.ContainsKey($p.Id) -and -not (Test-KitVersionCurrent -Installed $script:Installed[$p.Id] -Latest $lt)) {
            $latest = "[$($Hex.Yellow) bold]$latest[/]"
        }
        Add-KitRow $t @((E $p.Name), $inst, $latest, $how)
    }
    Out-Render $t
    Say ''

    $have = @($ai | Where-Object { $script:Installed.ContainsKey($_.Id) })
    $items = @()
    if ($have.Count) { $items += @{ Key = 'all'; Label = "[$($Hex.Orange) bold]Update all installed[/] [$($Hex.Gray)]($($have.Count) tools)[/]" } }
    $items += @{ Key = 'pick'; Label = 'Pick tools (also installs missing ones)' }
    $items += @{ Key = 'back'; Label = "[$($Hex.Gray)]Back[/]" }
    $sel = switch (Select-One -Title 'Update' -Items $items) {
        'all'  { $have }
        'pick' {
            $p = [Spectre.Console.MultiSelectionPrompt[string]]::new()
            $p.Title = 'Choose AI tools'; $p.Required = $false; $p.PageSize = [Math]::Max(3, $ai.Count)
            $p.HighlightStyle = [Spectre.Console.Style]::Parse("$($Hex.Orange) bold")
            $map = @{}
            foreach ($x in $ai) { $lb = "$(E $x.Name) $(Get-InstalledLabel $x)"; $map[$lb] = $x; $c = $p.AddChoice($lb); if ($script:Installed.ContainsKey($x.Id)) { [void]$c.Select() } }
            @(Show-Prompt $p | ForEach-Object { $map[$_] })
        }
        default { return }
    }
    if (-not $sel -or $sel.Count -eq 0) { return }
    [void](Invoke-Run -Selection $sel -Mode 'update' -Title 'Updating AI tools')
    $script:Installed = @{}
    Wait-Back
}

function Show-Tweaks {
    Show-Header 'Windows tweaks'
    $pn = [Spectre.Console.Panel]::new([Spectre.Console.Markup]::new(
        "[$($Hex.Fg)]Opens the Windows 11 tweaks menu (win11-tweaks.ps1):[/]`n" +
        "  1  Remove the 'Learn about this picture' desktop icon`n" +
        "  2  Remove fun facts and tips from the Spotlight lock screen`n" +
        "  3  Disable web search in the Start menu`n" +
        "  4  Auto-lock the PC after 15 minutes [$($Hex.Gray)](needs administrator)[/]"))
    $pn.Border = [Spectre.Console.BoxBorder]::Rounded
    $pn.BorderStyle = [Spectre.Console.Style]::Parse($Hex.Line)
    Out-Render $pn
    Say ''
    $script_ = Join-Path $KitRoot 'win11-tweaks.ps1'
    $items = @(
        @{ Key = 'here'; Label = 'Open here' }
        @{ Key = 'admin'; Label = 'Open as administrator [grey](new window, all 4 fixes)[/]' }
        @{ Key = 'back'; Label = "[$($Hex.Gray)]Back[/]" }
    )
    switch (Select-One -Title 'Tweaks' -Items $items) {
        'here' {
            if ($script:DryRunOn) { Say "[$($Hex.Purple)]would run: powershell -File $(E $script_)[/]"; Wait-Back; return }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script_
        }
        'admin' {
            if ($script:DryRunOn) { Say "[$($Hex.Purple)]would run elevated: powershell -File $(E $script_)[/]"; Wait-Back; return }
            try { Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script_`"" }
            catch { Say "[$($Hex.Red)]Administrator prompt was declined.[/]"; Wait-Back }
        }
    }
}

function Show-Settings {
    while ($true) {
        Show-Header 'Settings'
        $sc = if ($script:State.RemoveShortcuts) { "[$($Hex.Green)]on[/]" } else { "[$($Hex.Gray)]off[/]" }
        $dr = if ($script:DryRunOn) { "[$($Hex.Purple)]on[/]" } else { "[$($Hex.Gray)]off[/]" }
        $items = @(
            @{ Key = 'sc';  Label = "Remove desktop shortcuts that installers create: $sc" }
            @{ Key = 'dr';  Label = "Dry run (show what would run, install nothing): $dr" }
            @{ Key = 'log'; Label = 'Open the log folder' }
            @{ Key = 'back'; Label = "[$($Hex.Gray)]Back[/]" }
        )
        switch (Select-One -Title "Settings [$($Hex.Gray)]($((Get-KitOverrideCount)) learned package-ID fixes in use)[/]" -Items $items) {
            'sc'  { $script:State.RemoveShortcuts = -not $script:State.RemoveShortcuts; if (-not $script:Test) { Save-KitState $script:State } }
            'dr'  { if (-not $script:Test) { $script:DryRunOn = -not $script:DryRunOn } }   # smoke tests stay dry
            'log' {
                $d = Join-Path $env:TEMP 'my-win-kit'
                if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
                if (-not $script:Test) { Start-Process explorer.exe $d }
            }
            default { return }
        }
    }
}

# ---------------------------------------------------------------- main loop

while ($true) {
    Show-Header
    $items = @(
        @{ Key = 'install';  Label = "[$($Hex.Fg)]Install or update apps[/]  [$($Hex.Gray)]$($script:Catalog.Count) in the catalogue[/]" }
        @{ Key = 'ai';       Label = "[$($Hex.Fg)]Update AI tools[/]  [$($Hex.Gray)]Claude Code $($Glyph.Dot) Claude Desktop $($Glyph.Dot) agy $($Glyph.Dot) Antigravity[/]" }
        @{ Key = 'tweaks';   Label = "[$($Hex.Fg)]Windows tweaks[/]" }
        @{ Key = 'settings'; Label = "[$($Hex.Fg)]Settings[/]" }
        @{ Key = 'quit';     Label = "[$($Hex.Gray)]Quit[/]" }
    )
    $k = Select-One -Title 'What do you want to do?' -Items $items
    switch ($k) {
        'install'  { Show-Install }
        'ai'       { Show-UpdateAI }
        'tweaks'   { Show-Tweaks }
        'settings' { Show-Settings }
        default {
            if ($script:Test) { [Console]::Out.Write($script:Test.Output) }
            exit 0
        }
    }
}
