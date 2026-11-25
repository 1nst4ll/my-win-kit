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
    Env MYWINKIT_TEST_ANSI=1 makes the TestConsole emit truecolor ANSI
    (tools/render-screens.ps1 uses it to capture screens).
.NOTES
    Keep ASCII-only (glyphs come from [char] codes) and parseable by 5.1
    (CI parses every file under both editions). Every glyph used here exists
    in BOTH Consolas and Cascadia Mono (checked with GlyphTypeface), so it
    renders in classic conhost and in Windows Terminal without fallback fonts.
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

# Gruvbox dark, truecolor
$script:Hex = @{
    Orange = '#fe8019'; Yellow = '#fabd2f'; Green = '#b8bb26'; Red = '#fb4934'
    Aqua = '#8ec07c'; Blue = '#83a598'; Purple = '#d3869b'; Gray = '#928374'
    Fg = '#ebdbb2'; Line = '#665c54'; Dim = '#504945'; Bg1 = '#3c3836'
}
function C([int]$cp) { return [string][char]$cp }
# Glyphs present in both Consolas and Cascadia Mono (no Nerd Font, no emoji)
$script:Glyph = @{
    Ok = C 0x221A; Up = C 0x2191; Down = C 0x2193; Not = C 0x00B7; Fail = C 0x00D7; Heal = C 0x2194; Dry = C 0x25CB
    Same = '='; Dot = C 0x00B7; Arrow = C 0x2192; Pointer = C 0x25BA; Tri = C 0x25B8; Bullet = C 0x2022
    Full = C 0x2588; Shade3 = C 0x2593; Shade2 = C 0x2592; Shade1 = C 0x2591; HalfL = C 0x258C; Warn = C 0x25B2
    LineH = C 0x2500; DLineH = C 0x2550; Left = C 0x00AB; Sun = C 0x263C; Menu = C 0x2261
}
# One accent colour + icon per catalogue group (presentation only; groups live in catalog.psd1)
$script:GroupStyle = @{
    UTIL = @{ Icon = C 0x2261; Color = '#fabd2f' }   # triple bar
    OFCE = @{ Icon = C 0x00B6; Color = '#83a598' }   # pilcrow
    BROW = @{ Icon = C 0x25BA; Color = '#8ec07c' }   # pointer
    CLOU = @{ Icon = C 0x221E; Color = '#83a598' }   # infinity
    PDF  = @{ Icon = C 0x00A7; Color = '#fb4934' }   # section
    COMM = @{ Icon = C 0x263A; Color = '#b8bb26' }   # smiley
    REMO = @{ Icon = C 0x2194; Color = '#8ec07c' }   # left-right arrow
    SECU = @{ Icon = C 0x2666; Color = '#d3869b' }   # diamond
    MEDI = @{ Icon = C 0x266B; Color = '#fe8019' }   # notes
    MAIN = @{ Icon = C 0x2302; Color = '#fabd2f' }   # house
    DSGN = @{ Icon = C 0x2660; Color = '#d3869b' }   # spade
    OTHR = @{ Icon = C 0x2022; Color = '#a89984' }   # bullet
    DEV  = @{ Icon = C 0x00BB; Color = '#fe8019' }   # guillemet
    POST = @{ Icon = C 0x25B2; Color = '#fb4934' }   # triangle
}
Set-SpectreColors -AccentColor $Hex.Orange -DefaultValueColor $Hex.Gray

# ---------------------------------------------------------------- test console (smoke test)

$script:Test = $null
if ($TestKeys) {
    $DryRun = $true
    $tc = [Spectre.Console.Testing.TestConsole]::new()
    $tc.Profile.Width = 120
    $tc.Profile.Height = 30
    $tc.Profile.Capabilities.Interactive = $true
    $tc.Profile.Capabilities.Unicode = $true
    if ($env:MYWINKIT_TEST_ANSI -eq '1') {
        $tc.EmitAnsiSequences = $true
        $tc.Profile.Capabilities.Ansi = $true
        $tc.Profile.Capabilities.ColorSystem = [Spectre.Console.ColorSystem]::TrueColor
    }
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
function St([string]$s) { return [Spectre.Console.Style]::Parse($s) }
function Clear-Screen {
    if ($script:Test) { Say ''; return }
    try { [Spectre.Console.AnsiConsole]::Clear() } catch { Say '' }   # no console handle (redirected output)
}
function Get-WindowHeight {
    $h = 30
    try { if (-not $script:Test) { $h = [Console]::WindowHeight } } catch {}
    return $h
}
function Get-PageSize([int]$Reserved = 9) { return [Math]::Max(5, (Get-WindowHeight) - $Reserved) }
function Format-Duration([TimeSpan]$t) {
    if ($t.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds }
    return '{0:0.0}s' -f $t.TotalSeconds
}

# Gruvbox gradient orange -> yellow -> green -> aqua
$script:GradStops = @('#fe8019', '#fabd2f', '#b8bb26', '#8ec07c')
function Get-GradientHex([double]$t) {
    if ($t -lt 0) { $t = 0 }; if ($t -gt 1) { $t = 1 }
    $n = $script:GradStops.Count - 1
    $seg = [Math]::Min([int][Math]::Floor($t * $n), $n - 1)
    $f = ($t * $n) - $seg
    $a = $script:GradStops[$seg]; $b = $script:GradStops[$seg + 1]
    $rgb = foreach ($o in 1, 3, 5) {
        $x = [Convert]::ToInt32($a.Substring($o, 2), 16); $y = [Convert]::ToInt32($b.Substring($o, 2), 16)
        [int][Math]::Round($x + ($y - $x) * $f)
    }
    return '#{0:x2}{1:x2}{2:x2}' -f $rgb[0], $rgb[1], $rgb[2]
}
function ConvertTo-Gradient([string]$Text, [int]$Width = 0, [int]$Band = 3) {
    <# Colour a line left-to-right along the gradient, in bands of $Band columns. #>
    if ($Width -le 1) { $Width = [Math]::Max(2, $Text.Length) }
    $sb = [Text.StringBuilder]::new()
    for ($c = 0; $c -lt $Text.Length; $c += $Band) {
        $chunk = $Text.Substring($c, [Math]::Min($Band, $Text.Length - $c))
        if (-not $chunk.Trim()) { [void]$sb.Append($chunk); continue }
        [void]$sb.Append("[$(Get-GradientHex ($c / ($Width - 1)))]$(E $chunk)[/]")
    }
    return $sb.ToString()
}

$script:BannerLines = $null
function Get-BannerLines {
    <# "MY WIN KIT" in Spectre's built-in Figlet font, rendered once (~40 ms) and cached. #>
    if ($script:BannerLines) { return $script:BannerLines }
    $cap = [Spectre.Console.Testing.TestConsole]::new()
    $cap.Profile.Width = 200
    $cap.Write([Spectre.Console.FigletText]::new('MY WIN KIT'))
    $lines = @($cap.Output -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    $w = ($lines | Measure-Object -Property Length -Maximum).Maximum
    $script:BannerLines = @($lines | ForEach-Object { ConvertTo-Gradient $_ $w })
    return $script:BannerLines
}

function Get-SubtitleMarkup {
    $admin = if (Test-KitAdmin) { "[$($Hex.Green)]yes[/]" } else { "[$($Hex.Gray)]no[/]" }
    $s = "[$($Hex.Gray)]v$(Get-KitVersion) $($Glyph.Dot) $(E $env:COMPUTERNAME) $($Glyph.Dot) PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) $($Glyph.Dot) admin[/] $admin"
    if ($script:DryRunOn) { $s += "  [#282828 on $($Hex.Purple) bold] $($Glyph.Dry) DRY RUN [/]" }
    return $s
}

function Show-DryRunBand {
    if (-not $script:DryRunOn) { return }
    $r = [Spectre.Console.Rule]::new("[$($Hex.Purple) bold]$($Glyph.Dry) DRY RUN $($Glyph.Dot) simulation only, nothing will be installed or changed $($Glyph.Dry)[/]")
    $r.Style = St $Hex.Purple
    Out-Render $r
}

function Show-Banner {
    <# Main menu: gradient Figlet banner + subtitle (+ dry-run band). 7-8 rows. #>
    Clear-Screen
    foreach ($l in (Get-BannerLines)) { Say " $l" }
    Say " $(Get-SubtitleMarkup)"
    Show-DryRunBand
    Say ''
}

function Show-Header([string]$Screen = '') {
    <# Sub-screens: one gradient title rule (+ dry-run band). #>
    Clear-Screen
    $t = "$(ConvertTo-Gradient 'my-win-kit' 10 1) [$($Hex.Line)]$($Glyph.Tri)[/] [$($Hex.Fg) bold]$(E $Screen)[/]"
    if ($script:DryRunOn) { $t += "  [#282828 on $($Hex.Purple) bold] DRY RUN [/]" }
    $r = [Spectre.Console.Rule]::new($t)
    $r.Justification = [Spectre.Console.Justify]::Left
    $r.Style = St $Hex.Line
    Out-Render $r
    Show-DryRunBand
    Say ''
}

function Get-KeyHint([string[]]$Pairs) {
    <# "key|action" pairs -> one dim hint line with orange keys. #>
    $parts = foreach ($p in $Pairs) { $k, $a = $p -split '\|', 2; "[$($Hex.Orange)]$(E $k)[/] [$($Hex.Gray)]$(E $a)[/]" }
    return ($parts -join "  [$($Hex.Dim)]$($Glyph.Dot)[/]  ")
}

function Show-Prompt($Prompt) {
    # Module's async wrapper keeps Ctrl+C working; plain Show() as fallback.
    $mod = Get-Module PwshSpectreConsole
    try { return & $mod { param($p) Invoke-SpectrePromptAsync -Prompt $p } $Prompt }
    catch [System.Management.Automation.CommandNotFoundException] { return $Prompt.Show([Spectre.Console.AnsiConsole]::Console) }
}

function Select-One {
    <#
    One choice from an ordered list of @{ Key; Label } (Label = markup). Returns Key.
    SelectionPrompt has no footer, so the key hints go into its title line.
    #>
    param([string]$Title, [object[]]$Items, [switch]$Search, [string]$Hint)
    $p = [Spectre.Console.SelectionPrompt[string]]::new()
    if (-not $Hint) { $Hint = if ($Search) { Get-KeyHint @('type|search', "$($Glyph.Up)$($Glyph.Down)|move", 'enter|toggle') } else { Get-KeyHint @("$($Glyph.Up)$($Glyph.Down)|move", 'enter|select') } }
    $p.Title = if ($Title) { "$Title`n$Hint" } else { $Hint }
    $p.PageSize = [Math]::Max(3, [Math]::Min((Get-PageSize), $Items.Count))
    $p.WrapAround = $true
    $p.HighlightStyle = St "$($Hex.Orange) bold"
    $p.MoreChoicesText = "[$($Hex.Gray)]($($Glyph.Down) more)[/]"
    if ($Search) {
        $p.SearchEnabled = $true
        $p.SearchHighlightStyle = St "$($Hex.Yellow) underline"
        $p.SearchPlaceholderText = "[$($Hex.Gray)](type to search)[/]"
        $p.PageSize = Get-PageSize 10
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

function New-KitTable([string[]]$Columns, [string]$BorderHex = '') {
    if (-not $BorderHex) { $BorderHex = $Hex.Line }
    $t = [Spectre.Console.Table]::new()
    $t.Border = [Spectre.Console.TableBorder]::Rounded
    $t.BorderStyle = St $BorderHex
    foreach ($c in $Columns) { [void][Spectre.Console.TableExtensions]::AddColumn($t, "[$($Hex.Yellow) bold]$c[/]") }
    return $t
}
function Add-KitRow($Table, [string[]]$Cells) { [void][Spectre.Console.TableExtensions]::AddRow($Table, $Cells) }

function New-KitPanel([string]$Markup, [string]$Header = '', [string]$BorderHex = '') {
    if (-not $BorderHex) { $BorderHex = $Hex.Line }
    $pn = [Spectre.Console.Panel]::new([Spectre.Console.Markup]::new($Markup))
    $pn.Border = [Spectre.Console.BoxBorder]::Rounded
    $pn.BorderStyle = St $BorderHex
    if ($Header) { $pn.Header = [Spectre.Console.PanelHeader]::new($Header) }
    return $pn
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

function Get-GroupLabel($g, [int]$Count = -1) {
    $s = $script:GroupStyle[$g.Key]
    $l = "[$($s.Color) bold]$($s.Icon) $(E $g.Label.ToUpper())[/]"
    if ($Count -ge 0) { $l += " [$($Hex.Gray)]($Count)[/]" }
    return $l
}

# ---------------------------------------------------------------- badges (one vocabulary everywhere)

function Get-StateBadge($p) {
    <# Picker / review / AI table: installed, update available, not installed. #>
    if (-not $script:Installed.ContainsKey($p.Id)) { return "[$($Hex.Gray)]$($Glyph.Not)[/]" }
    if ($script:Updates.ContainsKey($p.Id)) { return "[$($Hex.Yellow) bold]$($Glyph.Up)[/]" }
    return "[$($Hex.Green)]$($Glyph.Ok)[/]"
}
function Get-StateText($p) {
    if (-not $script:Installed.ContainsKey($p.Id)) { return "[$($Hex.Gray)]not installed[/]" }
    $v = $script:Installed[$p.Id]; if (-not $v) { $v = 'installed' }
    if ($script:Updates.ContainsKey($p.Id)) { return "[$($Hex.Yellow)]$(E $v) $($Glyph.Arrow) $(E $script:Updates[$p.Id])[/]" }
    return "[$($Hex.Green)]$(E $v)[/]"
}
function Get-ResultBadge($r) {
    switch ($r.Status) {
        'installed' { "[$($Hex.Green) bold]$($Glyph.Ok)[/]" }
        'updated'   { "[$($Hex.Green) bold]$($Glyph.Up)[/]" }
        'current'   { "[$($Hex.Aqua)]$($Glyph.Same)[/]" }
        'done'      { "[$($Hex.Green) bold]$($Glyph.Ok)[/]" }
        'dryrun'    { "[$($Hex.Purple)]$($Glyph.Dry)[/]" }
        default     { "[$($Hex.Red) bold]$($Glyph.Fail)[/]" }
    }
}
function Get-ResultText($r) {
    switch ($r.Status) {
        'installed' { "[$($Hex.Green)]installed[/]" }
        'updated'   { "[$($Hex.Green)]updated[/]" }
        'current'   { "[$($Hex.Aqua)]up to date[/]" }
        'done'      { "[$($Hex.Green)]done[/]" }
        'dryrun'    { "[$($Hex.Purple)]would run[/]" }
        default     { "[$($Hex.Red)]failed[/]" }
    }
}
function Get-VersionMarkup($r) {
    if ($r.From -and $r.To -and $r.From -ne $r.To) { return "[$($Hex.Gray)]$(E $r.From)[/] $($Glyph.Arrow) [$($Hex.Fg)]$(E $r.To)[/]" }
    if ($r.To) { return E $r.To }
    if ($r.From) { return E $r.From }
    return "[$($Hex.Gray)]-[/]"
}
function Get-LegendMarkup {
    return "[$($Hex.Green)]$($Glyph.Ok) installed[/]  [$($Hex.Yellow)]$($Glyph.Up) update available[/]  [$($Hex.Gray)]$($Glyph.Not) not installed[/]  [$($Hex.Red)]$($Glyph.Fail) failed[/]  [$($Hex.Aqua)]$($Glyph.Heal) healed[/]"
}

function Invoke-Scan([switch]$Updates) {
    <# Installed versions (+ available updates). Spinner while it runs. #>
    $script:Installed = @{}; $script:Updates = @{}
    $st = [Spectre.Console.AnsiConsole]::Status()
    $st.Spinner = [Spectre.Console.Spinner+Known]::Point
    $st.SpinnerStyle = St $Hex.Orange
    $st.Start("[$($Hex.Fg)]Checking what's installed on this PC...[/]", [Action[Spectre.Console.StatusContext]] {
        param($ctx)
        $script:Installed = Get-KitInstalled
        if ($Updates) {
            $ctx.Status = "[$($Hex.Fg)]Looking for updates...[/]"
            $script:Updates = Get-KitUpdates -Installed $script:Installed
        }
    })
    $script:ScanDone = $true
}

# ---------------------------------------------------------------- state

$script:Catalog   = @(Initialize-Kit -KitRoot $KitRoot)
$script:Groups    = @(Get-KitGroups)
$script:State     = Get-KitState
$script:DryRunOn  = [bool]$DryRun
$script:Installed = @{}
$script:Updates   = @{}
$script:ScanDone  = $false

if (-not (Test-KitWinget) -and -not $script:Test) {
    Show-Header 'winget missing'
    Out-Render (New-KitPanel "[$($Hex.Fg)]winget (App Installer) is missing - most installs need it.`nOpening its Microsoft Store page: install it, then run install.cmd again.[/]" " [$($Hex.Red)]$($Glyph.Warn) heads up[/] " $Hex.Red)
    try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch { Say 'Manual link: https://aka.ms/getwinget' }
    [void](Confirm-Kit 'Continue anyway (script and direct installs still work)?' $false)
}

# ---------------------------------------------------------------- app picker

function Get-AppLabel($it) {
    $label = "$(Get-StateBadge $it) [$($Hex.Fg)]$(E $it.Name)[/]"
    if ($script:Installed.ContainsKey($it.Id)) { $label += "  $(Get-StateText $it)" }
    if ($it.Method -ne 'winget') { $label += "  [$($Hex.Aqua)]$(Get-MethodLabel $it)[/]" }
    return $label
}

function Select-Apps {
    <# Grouped multi-select, preselected with $Preselect Ids. Returns package objects. #>
    param([int[]]$Preselect)
    $p = [Spectre.Console.MultiSelectionPrompt[string]]::new()
    $p.Title = "[$($Hex.Fg) bold]Choose apps[/]   $(Get-LegendMarkup)"
    $p.Mode = [Spectre.Console.SelectionMode]::Leaf
    $p.PageSize = Get-PageSize 10
    $p.WrapAround = $true
    $p.Required = $false
    $p.HighlightStyle = St "$($Hex.Orange) bold"
    # MultiSelectionPrompt has a footer: the persistent key-hint bar lives here
    $p.InstructionsText = Get-KeyHint @("$($Glyph.Up)$($Glyph.Down)|move", 'space|toggle (a group header toggles the group)', 'enter|confirm')
    $p.MoreChoicesText = "[$($Hex.Gray)]($($Glyph.Down) more apps)[/]"

    $map = @{}
    foreach ($g in $script:Groups) {
        $items = @($script:Catalog | Where-Object Group -eq $g.Key | Sort-Object Id)
        if (-not $items) { continue }
        $gLabel = Get-GroupLabel $g $items.Count
        if ($g.Key -eq 'POST') { $gLabel += " [$($Hex.Red)]runs last, opens its own windows[/]" }
        $node = $p.AddChoice($gLabel)
        foreach ($it in $items) {
            $label = Get-AppLabel $it
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
        $items = @(@{ Key = 'done'; Label = "[$($Hex.Orange) bold]$($Glyph.Pointer) Done[/] [$($Hex.Gray)]($($sel.Count) selected)[/]" })
        foreach ($it in ($script:Catalog | Sort-Object Name)) {
            # Glyph boxes, not "[[x]]": escaped brackets break Spectre's search highlighting
            $box = if ($sel.ContainsKey($it.Id)) { "[$($Hex.Green)]$(C 0x25CF)[/]" } else { "[$($Hex.Gray)]$(C 0x25CB)[/]" }
            $gs = $script:GroupStyle[$it.Group]
            $items += @{ Key = "$($it.Id)"; Label = "$box $(Get-StateBadge $it) [$($gs.Color)]$($gs.Icon)[/] $(E $it.Name)  [$($Hex.Gray)]$(E $it.Desc)[/]" }
        }
        $k = Select-One -Title "[$($Hex.Fg) bold]Search an app to add or remove it[/]" -Items $items -Search
        if ($k -eq 'done' -or -not $k) { break }
        $id = [int]$k
        if ($sel.ContainsKey($id)) { $sel.Remove($id) } else { $sel[$id] = $true }
    }
    return @($script:Catalog | Where-Object { $sel.ContainsKey($_.Id) })
}

function Show-Review {
    param([object[]]$Selection)
    $t = New-KitTable @(' ', 'App', 'Group', 'How', 'On this PC', 'Will') $Hex.Orange
    $gmap = @{}; foreach ($g in $script:Groups) { $gmap[$g.Key] = $g }
    foreach ($p in (Get-KitRunOrder $Selection)) {
        $isInst = $script:Installed.ContainsKey($p.Id)
        $will = if ($p.Interactive) { "[$($Hex.Purple)]run (interactive)[/]" }
                elseif ($script:Updates.ContainsKey($p.Id)) { "[$($Hex.Yellow)]update[/]" }
                elseif ($isInst) { "[$($Hex.Aqua)]check for update[/]" }
                else { "[$($Hex.Green)]install[/]" }
        $gs = $script:GroupStyle[$p.Group]
        Add-KitRow $t @((Get-StateBadge $p), "[$($Hex.Fg)]$(E $p.Name)[/]", "[$($gs.Color)]$($gs.Icon) $(E $gmap[$p.Group].Label)[/]", (Get-MethodLabel $p), (Get-StateText $p), $will)
    }
    $n = $Selection.Count
    $have = @($Selection | Where-Object { $script:Installed.ContainsKey($_.Id) }).Count
    $upd = @($Selection | Where-Object { $script:Updates.ContainsKey($_.Id) }).Count
    $t.Title = [Spectre.Console.TableTitle]::new("[$($Hex.Orange) bold]Review[/]")
    $t.Caption = [Spectre.Console.TableTitle]::new("[$($Hex.Fg)]$(Get-Plural $n "app")[/] [$($Hex.Gray)]$($Glyph.Dot)[/] [$($Hex.Green)]$($n - $have) new[/] [$($Hex.Gray)]$($Glyph.Dot)[/] [$($Hex.Yellow)]$upd with updates[/] [$($Hex.Gray)]$($Glyph.Dot) $have already installed[/]")
    Out-Render $t
    if (@($Selection | Where-Object Group -eq 'POST').Count -gt 0) {
        Say "[$($Hex.Red)]$($Glyph.Warn)[/] [$($Hex.Fg)]Post-install items run last and open their own prompts or windows.[/]"
    }
}

# ---------------------------------------------------------------- run

function Write-ResultLine($res) {
    $line = "  $(Get-ResultBadge $res) [$($Hex.Fg)]$(E $res.Name)[/]  $(Get-ResultText $res)  $(Get-VersionMarkup $res)  [$($Hex.Gray)]$($res.Seconds)s[/]"
    if ($res.Healed) { $line += "  [$($Hex.Aqua)]$($Glyph.Heal) $(E $res.Healed)[/]" }
    if ($res.Status -eq 'failed' -and $res.Detail) { $line += "`n      [$($Hex.Gray)]$(E $res.Detail)[/]" }
    Say $line
}

function Invoke-Run {
    <# Install/update a selection with a live progress view, then results table + summary panel. #>
    param([object[]]$Selection, [ValidateSet('install', 'update')][string]$Mode = 'install', [string]$Title = 'Installing')
    $order = @(Get-KitRunOrder $Selection)
    $live = @($order | Where-Object { -not $_.Interactive -or $script:DryRunOn })
    $inter = @($order | Where-Object { $_.Interactive -and -not $script:DryRunOn })
    Show-Header $Title
    $log = Start-KitLog
    $before = @(); if ($script:State.RemoveShortcuts) { $before = @(Get-KitDesktopShortcuts) }
    $total = [Diagnostics.Stopwatch]::StartNew()
    $script:runResults = [System.Collections.Generic.List[object]]::new()

    if ($live.Count) {
        $pr = [Spectre.Console.AnsiConsole]::Progress()
        $pr.AutoClear = $true
        $pr.HideCompleted = $true
        $spin = [Spectre.Console.SpinnerColumn]::new([Spectre.Console.Spinner+Known]::Point)
        $spin.Style = St $Hex.Orange
        $bar = [Spectre.Console.ProgressBarColumn]::new()
        $bar.Width = 28
        $bar.CompletedStyle = St $Hex.Orange; $bar.FinishedStyle = St $Hex.Green
        $bar.RemainingStyle = St $Hex.Bg1; $bar.IndeterminateStyle = St $Hex.Yellow
        $pct = [Spectre.Console.PercentageColumn]::new(); $pct.Style = St $Hex.Fg; $pct.CompletedStyle = St $Hex.Green
        $el = [Spectre.Console.ElapsedTimeColumn]::new(); $el.Style = St $Hex.Gray
        $desc = [Spectre.Console.TaskDescriptionColumn]::new(); $desc.Alignment = [Spectre.Console.Justify]::Left
        [void][Spectre.Console.ProgressExtensions]::Columns($pr, [Spectre.Console.ProgressColumn[]]@($spin, $desc, $bar, $pct, $el))

        $pr.Start([Action[Spectre.Console.ProgressContext]] {
            param($ctx)
            $overall = $ctx.AddTask("[$($Hex.Orange) bold]Overall[/] [$($Hex.Gray)]0/$($live.Count)[/]")
            $overall.MaxValue = $live.Count
            for ($i = 0; $i -lt $live.Count; $i++) {
                $p = $live[$i]
                $gs = $script:GroupStyle[$p.Group]
                $name = "[$($gs.Color)]$($gs.Icon)[/] [$($Hex.Fg)]$(E $p.Name)[/]"
                $task = $ctx.AddTask("$name [$($Hex.Gray)]$(Get-MethodLabel $p)[/]")
                $task.IsIndeterminate = $true
                $inst = $null; if ($script:Installed.ContainsKey($p.Id)) { $inst = $script:Installed[$p.Id] }
                $onStatus = { param($m) $task.Description = "$name [$($Hex.Gray)]$(E $m)...[/]" }
                $res = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -DryRun:$script:DryRunOn -OnStatus $onStatus
                $task.IsIndeterminate = $false
                $task.Value = $task.MaxValue
                $task.StopTask()
                $script:runResults.Add($res)
                Write-ResultLine $res   # printed above the live progress (Spectre render hook)
                $overall.Increment(1)
                $overall.Description = "[$($Hex.Orange) bold]Overall[/] [$($Hex.Gray)]$($i + 1)/$($live.Count)[/]"
            }
        })
    }
    foreach ($p in $inter) {
        $r = [Spectre.Console.Rule]::new("[$($Hex.Purple) bold]$($Glyph.Warn) $(E $p.Name)[/] [$($Hex.Gray)]interactive - answer its prompts[/]")
        $r.Justification = [Spectre.Console.Justify]::Left; $r.Style = St $Hex.Purple; Out-Render $r
        $inst = $null; if ($script:Installed.ContainsKey($p.Id)) { $inst = $script:Installed[$p.Id] }
        $res = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode
        $script:runResults.Add($res)
        Write-ResultLine $res
    }
    $results = @($script:runResults)

    $removed = @()
    if ($script:State.RemoveShortcuts -and -not $script:DryRunOn) { $removed = @(Remove-KitNewShortcuts -Before $before) }

    # Results table
    Say ''
    $fl = @($results | Where-Object Status -eq 'failed').Count
    $t = New-KitTable @(' ', 'App', 'Result', 'Version', 'Time', 'Note') $(if ($fl) { $Hex.Red } else { $Hex.Green })
    foreach ($r in $results) {
        $note = ''
        if ($r.Healed) { $note = "[$($Hex.Aqua)]$($Glyph.Heal) $(E $r.Healed)[/]" }
        elseif ($r.Status -in 'failed', 'dryrun' -and $r.Detail) { $note = "[$($Hex.Gray)]$(E $r.Detail)[/]" }
        Add-KitRow $t @((Get-ResultBadge $r), "[$($Hex.Fg)]$(E $r.Name)[/]", (Get-ResultText $r), (Get-VersionMarkup $r), "[$($Hex.Gray)]$($r.Seconds)s[/]", $note)
    }
    $t.Title = [Spectre.Console.TableTitle]::new("[$($Hex.Orange) bold]Results[/]")
    Out-Render $t

    # Summary panel
    $ok = @($results | Where-Object Status -in 'installed', 'updated', 'current', 'done', 'dryrun').Count
    $hl = @($results | Where-Object Healed).Count
    $sum = "[$($Hex.Green) bold]$($Glyph.Ok) $ok ok[/]   [$($Hex.Aqua) bold]$($Glyph.Heal) $hl healed[/]   [$($Hex.Red) bold]$($Glyph.Fail) $fl failed[/]   [$($Hex.Fg)]total $(Format-Duration $total.Elapsed)[/]"
    if ($script:DryRunOn) { $sum += "`n[$($Hex.Purple) bold]$($Glyph.Dry) DRY RUN - nothing was installed or changed[/]" }
    if ($removed.Count) { $sum += "`n[$($Hex.Gray)]Removed $($removed.Count) new desktop shortcut(s): $(E ($removed -join ', '))[/]" }
    if ($hl) { $sum += "`n[$($Hex.Aqua)]Healed package IDs saved to winget-id-overrides.json - every PC starts healed.[/]" }
    $sum += "`n[$($Hex.Gray)]Log: $(E $log)[/]"
    $border = if ($script:DryRunOn) { $Hex.Purple } elseif ($fl) { $Hex.Red } else { $Hex.Green }
    Out-Render (New-KitPanel $sum " [$border bold]Summary[/] " $border)
    Say ''

    $script:State.LastSelection = @($Selection | ForEach-Object Id)
    $script:State.LastFailed = @($results | Where-Object Status -eq 'failed' | ForEach-Object Id)
    if (-not $script:DryRunOn) { Save-KitState $script:State }
    return $results
}

# ---------------------------------------------------------------- screens

function Wait-Back { [void](Select-One -Title '' -Items @(@{ Key = 'ok'; Label = "[$($Hex.Orange) bold]$($Glyph.Left) Back to main menu[/]" })) }

function Show-Install {
    Show-Header 'Install or update apps'
    if (-not $script:ScanDone) { Invoke-Scan -Updates }
    $def = @($script:Catalog | Where-Object Default)
    $missing = @($def | Where-Object { -not $script:Installed.ContainsKey($_.Id) })
    $upd = @($script:Catalog | Where-Object { $script:Updates.ContainsKey($_.Id) })
    Say "  [$($Hex.Green)]$($Glyph.Ok) $($script:Installed.Count) installed[/]   [$($Hex.Yellow)]$($Glyph.Up) $($upd.Count) with updates[/]   [$($Hex.Gray)]$($Glyph.Not) $($script:Catalog.Count - $script:Installed.Count) not installed[/]"
    Say ''
    $items = @(
        @{ Key = 'def';  Label = "[$($Hex.Fg)]Recommended set[/] [$($Hex.Gray)]($(Get-Plural $def.Count "app"), installed ones update if newer)[/]" }
        @{ Key = 'miss'; Label = "[$($Hex.Fg)]Recommended, only what's missing here[/] [$($Hex.Gray)]($(Get-Plural $missing.Count "app"))[/]" }
    )
    if ($upd.Count) { $items += @{ Key = 'upd'; Label = "[$($Hex.Yellow)]$($Glyph.Up) Everything with an update[/] [$($Hex.Gray)]($(Get-Plural $upd.Count "app"))[/]" } }
    if ($script:State.LastFailed.Count)    { $items += @{ Key = 'fail'; Label = "[$($Hex.Red)]$($Glyph.Fail) Retry last run's failures[/] [$($Hex.Gray)]($(Get-Plural $script:State.LastFailed.Count "app"))[/]" } }
    if ($script:State.LastSelection.Count) { $items += @{ Key = 'last'; Label = "[$($Hex.Fg)]My last selection on this PC[/] [$($Hex.Gray)]($(Get-Plural $script:State.LastSelection.Count "app"))[/]" } }
    $items += @{ Key = 'none'; Label = "[$($Hex.Fg)]Start empty[/]" }
    $items += @{ Key = 'back'; Label = "[$($Hex.Gray)]$($Glyph.Left) Back[/]" }
    $start = Select-One -Title "[$($Hex.Fg) bold]Start from[/]" -Items $items
    $pre = switch ($start) {
        'def'  { @($def.Id) }
        'miss' { @($missing.Id) }
        'upd'  { @($upd.Id) }
        'fail' { $script:State.LastFailed }
        'last' { $script:State.LastSelection }
        'none' { @() }
        default { return }
    }

    $sel = @(Select-Apps -Preselect $pre)
    while ($true) {
        Show-Header 'Review'
        if ($sel.Count -eq 0) { Say "[$($Hex.Gray)]  Nothing selected.[/]" } else { Show-Review $sel }
        Say ''
        $acts = @()
        if ($sel.Count) {
            $verb = if ($script:DryRunOn) { 'Simulate' } else { 'Install' }
            $acts += @{ Key = 'go'; Label = "[$($Hex.Orange) bold]$($Glyph.Pointer) $verb now[/] [$($Hex.Gray)]($(Get-Plural $sel.Count "app"))[/]" }
        }
        $acts += @{ Key = 'search'; Label = "[$($Hex.Fg)]Search to add or remove an app[/]" }
        $acts += @{ Key = 'edit';   Label = "[$($Hex.Fg)]Change the selection (full list)[/]" }
        $acts += @{ Key = 'back';   Label = "[$($Hex.Gray)]$($Glyph.Left) Back to main menu[/]" }
        switch (Select-One -Title "[$($Hex.Fg) bold]Next[/]" -Items $acts) {
            'go'     { [void](Invoke-Run -Selection $sel); $script:ScanDone = $false; Wait-Back; return }
            'search' { $sel = @(Edit-BySearch -Selection $sel) }
            'edit'   { $sel = @(Select-Apps -Preselect @($sel.Id)) }
            default  { return }
        }
    }
}

function Show-UpdateAI {
    Show-Header 'Update AI tools'
    $ai = @($script:Catalog | Where-Object AI | Sort-Object GroupOrder, Id)
    $script:latest = @{}
    $st = [Spectre.Console.AnsiConsole]::Status()
    $st.Spinner = [Spectre.Console.Spinner+Known]::Point
    $st.SpinnerStyle = St $Hex.Orange
    $st.Start("[$($Hex.Fg)]Checking installed and latest versions...[/]", [Action[Spectre.Console.StatusContext]] {
        param($ctx)
        [void]$ctx   # Spectre passes the StatusContext; not every caller needs it
        $script:Installed = Get-KitInstalled
        $script:Updates = @{}
        foreach ($p in $ai) {
            $lt = Get-KitLatestVersion -Package $p
            $script:latest[$p.Id] = $lt
            if ($lt -and $script:Installed.ContainsKey($p.Id) -and -not (Test-KitVersionCurrent -Installed $script:Installed[$p.Id] -Latest $lt)) { $script:Updates[$p.Id] = $lt }
        }
    })

    $t = New-KitTable @(' ', 'Tool', 'Installed', 'Latest', 'How it updates') $Hex.Aqua
    foreach ($p in $ai) {
        $inst = if ($script:Installed.ContainsKey($p.Id)) { $v = $script:Installed[$p.Id]; if ($v) { E $v } else { 'installed' } } else { "[$($Hex.Gray)]not installed[/]" }
        $lt = $script:latest[$p.Id]
        $latest = if ($script:Updates.ContainsKey($p.Id)) { "[$($Hex.Yellow) bold]$(E $lt)[/]" } elseif ($lt) { "[$($Hex.Green)]$(E $lt)[/]" } elseif ($p.Update) { "[$($Hex.Gray)]checked by $(E $p.Update)[/]" } else { "[$($Hex.Gray)]-[/]" }
        $how = switch ($p.Method) {
            'script' { if ($p.Update) { "[$($Hex.Aqua)]$(E $p.Update)[/] [$($Hex.Gray)](official updater)[/]" } else { 'official installer' } }
            'direct' { "[$($Hex.Aqua)]official download page[/] [$($Hex.Gray)](signed)[/]" }
            default  { if ($p.Appx) { 'winget + updates itself' } else { 'winget' } }
        }
        Add-KitRow $t @((Get-StateBadge $p), "[$($Hex.Fg)]$(E $p.Name)[/]", $inst, $latest, $how)
    }
    $t.Title = [Spectre.Console.TableTitle]::new("[$($Hex.Aqua) bold]AI tools[/]")
    $t.Caption = [Spectre.Console.TableTitle]::new((Get-LegendMarkup))
    Out-Render $t
    Say ''

    $have = @($ai | Where-Object { $script:Installed.ContainsKey($_.Id) })
    $items = @()
    if ($have.Count) { $items += @{ Key = 'all'; Label = "[$($Hex.Orange) bold]$($Glyph.Pointer) Update all installed[/] [$($Hex.Gray)]($(Get-Plural $have.Count "tool"))[/]" } }
    $items += @{ Key = 'pick'; Label = "[$($Hex.Fg)]Pick tools (also installs missing ones)[/]" }
    $items += @{ Key = 'back'; Label = "[$($Hex.Gray)]$($Glyph.Left) Back[/]" }
    $sel = switch (Select-One -Title "[$($Hex.Fg) bold]Update[/]" -Items $items) {
        'all'  { $have }
        'pick' {
            $p = [Spectre.Console.MultiSelectionPrompt[string]]::new()
            $p.Title = "[$($Hex.Fg) bold]Choose AI tools[/]"; $p.Required = $false; $p.PageSize = [Math]::Max(3, $ai.Count)
            $p.HighlightStyle = St "$($Hex.Orange) bold"
            $p.InstructionsText = Get-KeyHint @("$($Glyph.Up)$($Glyph.Down)|move", 'space|toggle', 'enter|confirm')
            $map = @{}
            foreach ($x in $ai) { $lb = Get-AppLabel $x; $map[$lb] = $x; $c = $p.AddChoice($lb); if ($script:Installed.ContainsKey($x.Id)) { [void]$c.Select() } }
            @(Show-Prompt $p | ForEach-Object { $map[$_] })
        }
        default { return }
    }
    if (-not $sel -or $sel.Count -eq 0) { return }
    [void](Invoke-Run -Selection $sel -Mode 'update' -Title 'Updating AI tools')
    $script:ScanDone = $false
    Wait-Back
}

function Show-Tweaks {
    Show-Header 'Windows tweaks'
    $body = "[$($Hex.Fg)]Opens the Windows 11 tweaks menu ([/][$($Hex.Aqua)]win11-tweaks.ps1[/][$($Hex.Fg)]):[/]`n" +
        "  [$($Hex.Orange)]1[/]  Remove the 'Learn about this picture' desktop icon`n" +
        "  [$($Hex.Orange)]2[/]  Remove fun facts and tips from the Spotlight lock screen`n" +
        "  [$($Hex.Orange)]3[/]  Disable web search in the Start menu`n" +
        "  [$($Hex.Orange)]4[/]  Auto-lock the PC after 15 minutes [$($Hex.Gray)](needs administrator)[/]"
    Out-Render (New-KitPanel $body " [$($Hex.Yellow) bold]$($Glyph.Sun) Windows 11 tweaks[/] " $Hex.Yellow)
    Say ''
    $script_ = Join-Path $KitRoot 'win11-tweaks.ps1'
    $items = @(
        @{ Key = 'here';  Label = "[$($Hex.Fg)]Open here[/]" }
        @{ Key = 'admin'; Label = "[$($Hex.Fg)]Open as administrator[/] [$($Hex.Gray)](new window, all 4 fixes)[/]" }
        @{ Key = 'back';  Label = "[$($Hex.Gray)]$($Glyph.Left) Back[/]" }
    )
    switch (Select-One -Title "[$($Hex.Fg) bold]Tweaks[/]" -Items $items) {
        'here' {
            if ($script:DryRunOn) { Say "[$($Hex.Purple)]$($Glyph.Dry) would run: powershell -File $(E $script_)[/]"; Wait-Back; return }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script_
        }
        'admin' {
            if ($script:DryRunOn) { Say "[$($Hex.Purple)]$($Glyph.Dry) would run elevated: powershell -File $(E $script_)[/]"; Wait-Back; return }
            try { Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script_`"" }
            catch { Say "[$($Hex.Red)]Administrator prompt was declined.[/]"; Wait-Back }
        }
    }
}

function Show-Settings {
    while ($true) {
        Show-Header 'Settings'
        $on = "[$($Hex.Green) bold]on[/]"; $off = "[$($Hex.Gray)]off[/]"
        $sc = if ($script:State.RemoveShortcuts) { $on } else { $off }
        $dr = if ($script:DryRunOn) { "[$($Hex.Purple) bold]on[/]" } else { $off }
        $items = @(
            @{ Key = 'sc';  Label = "[$($Hex.Fg)]Remove desktop shortcuts that installers create:[/] $sc" }
            @{ Key = 'dr';  Label = "[$($Hex.Fg)]Dry run (show what would run, install nothing):[/] $dr" }
            @{ Key = 'log'; Label = "[$($Hex.Fg)]Open the log folder[/]" }
            @{ Key = 'back'; Label = "[$($Hex.Gray)]$($Glyph.Left) Back[/]" }
        )
        switch (Select-One -Title "[$($Hex.Fg) bold]Settings[/] [$($Hex.Gray)]($((Get-KitOverrideCount)) learned package-ID fixes in use)[/]" -Items $items) {
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

function Show-Goodbye {
    Clear-Screen
    $w = 64
    $bar = ($Glyph.Shade1 + $Glyph.Shade2 + $Glyph.Shade3 + $Glyph.Full) + ($Glyph.DLineH * ($w - 8)) + ($Glyph.Full + $Glyph.Shade3 + $Glyph.Shade2 + $Glyph.Shade1)
    Say " $(ConvertTo-Gradient $bar $w 2)"
    $msg = 'all set - see you next time'
    Say " $(' ' * [int](($w - $msg.Length) / 2))$(ConvertTo-Gradient $msg $msg.Length 1)"
    Say " $(ConvertTo-Gradient $bar $w 2)"
    Say ''
}

# ---------------------------------------------------------------- main loop

while ($true) {
    Show-Banner
    $menu = @(
        @{ Key = 'install';  Icon = $Glyph.Pointer; Color = $Hex.Orange; Name = 'Install or update apps'; Desc = "pick from $($script:Catalog.Count) apps: install new ones, update the rest" }
        @{ Key = 'ai';       Icon = $Glyph.Up;      Color = $Hex.Aqua;   Name = 'Update AI tools';        Desc = "Claude Code $($Glyph.Dot) Claude Desktop $($Glyph.Dot) agy $($Glyph.Dot) Antigravity, always latest" }
        @{ Key = 'tweaks';   Icon = $Glyph.Sun;     Color = $Hex.Yellow; Name = 'Windows tweaks';         Desc = 'Spotlight icon, lock-screen tips, Start web search, auto-lock' }
        @{ Key = 'settings'; Icon = $Glyph.Menu;    Color = $Hex.Blue;   Name = 'Settings';               Desc = 'shortcut cleanup, dry run, log folder' }
        @{ Key = 'quit';     Icon = $Glyph.Left;    Color = $Hex.Gray;   Name = 'Quit';                   Desc = '' }
    )
    $items = foreach ($m in $menu) {
        @{ Key = $m.Key; Label = "[$($m.Color) bold]$($m.Icon)[/] [$($Hex.Fg) bold]$(E $m.Name.PadRight(24))[/] [$($Hex.Gray)]$(E $m.Desc)[/]" }
    }
    $k = Select-One -Title "[$($Hex.Orange) bold]$($Glyph.HalfL) MAIN MENU[/]" -Items $items
    switch ($k) {
        'install'  { Show-Install }
        'ai'       { Show-UpdateAI }
        'tweaks'   { Show-Tweaks }
        'settings' { Show-Settings }
        default {
            Show-Goodbye
            if ($script:Test) { [Console]::Out.Write($script:Test.Output) }
            exit 0
        }
    }
}
