#Requires -Version 7.4
<#
.SYNOPSIS
    my-win-kit modern menu (PowerShell 7.4+ with PwshSpectreConsole).
.DESCRIPTION
    Started by install.ps1 when PowerShell 7.4+ is present. Renders screens
    and collects choices; all install work happens in src/core.psm1.
    Spectre.Console draws everything; input comes from the kit's own picker
    (Show-Picker, built on [Console]::ReadKey) because Spectre's prompts have
    no Esc/back key. Exit codes: 0 = normal quit, 3 = Spectre unavailable
    (the loader then falls back to the classic menu).
.PARAMETER KitRoot
    Folder that holds install.ps1 (and the bundled config/ copy).
.PARAMETER DryRun
    Simulate: show what would run, install nothing.
.PARAMETER TestKeys
    Smoke test: comma-separated keys (DownArrow, Enter, Escape, Spacebar,
    Backspace, LeftArrow, text:abc) fed to the picker, with a Spectre
    TestConsole (120 x 30) as the screen. Forces -DryRun. Prints
    "SCREEN-HEIGHTS: ..." (rows used per screen) on exit for the tests.
    Env MYWINKIT_TEST_ANSI=1 makes the TestConsole emit truecolor ANSI.
.NOTES
    Keep ASCII-only (glyphs come from [char] codes) and parseable by 5.1
    (CI parses every file under both editions). Every glyph used here exists
    in BOTH Consolas and Cascadia Mono (checked with GlyphTypeface).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KitRoot,
    [switch]$DryRun,
    [string]$TestKeys
)

$ErrorActionPreference = 'Stop'
# UTF-8 BEFORE Spectre loads: a fresh console is code page 437, and Spectre
# decides Unicode support once, when its console is created. Too late = every
# glyph prints as "?" and borders fall back to ASCII.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
Import-Module (Join-Path $KitRoot 'src\core.psm1') -Force
function C([int]$cp) { return [string][char]$cp }
try { $Host.UI.RawUI.WindowTitle = "my-win-kit $(C 0x00B7) modern (PowerShell 7)" } catch {}

# ---------------------------------------------------------------- Spectre module

function Initialize-SpectreModule {
    $min = [version]'2.3.0'
    $have = Get-Module -ListAvailable PwshSpectreConsole | Where-Object { $_.Version -ge $min } | Select-Object -First 1
    if (-not $have) {
        Write-Host '  First run on this PC: installing the PwshSpectreConsole module (current user)...' -ForegroundColor DarkYellow
        Write-KitRunLog 'modern: PwshSpectreConsole missing - installing (CurrentUser)'
        try {
            Install-PSResource -Name PwshSpectreConsole -Scope CurrentUser -TrustRepository -Quiet -ErrorAction Stop
        } catch {
            try { Install-Module PwshSpectreConsole -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }
            catch {
                Write-Host "  Could not install PwshSpectreConsole: $($_.Exception.Message)" -ForegroundColor Red
                Write-KitRunLog "modern: FALLBACK - module install failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
    try { Import-Module PwshSpectreConsole -MinimumVersion $min -ErrorAction Stop; return $true }
    catch {
        Write-Host "  Could not load PwshSpectreConsole: $($_.Exception.Message)" -ForegroundColor Red
        Write-KitRunLog "modern: FALLBACK - module import failed: $($_.Exception.Message)"
        return $false
    }
}

if (-not (Initialize-SpectreModule)) { exit 3 }
$script:SpectreVersion = (Get-Module PwshSpectreConsole).Version

# Explicit console: truecolor + ANSI + Unicode. Spectre's own detection turns all
# colour off when NO_COLOR is set, and dev tools / agent shells export NO_COLOR=1
# to every child window, which made the menu look like plain PowerShell. The kit
# only drops colour for its own switch, MYWINKIT_NO_COLOR=1.
if ($env:MYWINKIT_NO_COLOR -ne '1') {
    try {
        $cs = [Spectre.Console.AnsiConsoleSettings]::new()
        $cs.Ansi = [Spectre.Console.AnsiSupport]::Yes
        $cs.ColorSystem = [Spectre.Console.ColorSystemSupport]::TrueColor
        $cs.Interactive = [Spectre.Console.InteractionSupport]::Yes
        $cs.Out = [Spectre.Console.AnsiConsoleOutput]::new([Console]::Out)
        [Spectre.Console.AnsiConsole]::Console = [Spectre.Console.AnsiConsole]::Create($cs)
        [Spectre.Console.AnsiConsole]::Console.Profile.Capabilities.Unicode = $true
    } catch { Write-KitRunLog "modern: could not create the truecolor console: $($_.Exception.Message)" }
}
$cap0 = [Spectre.Console.AnsiConsole]::Console.Profile.Capabilities
Write-KitRunLog ("modern: console ColorSystem={0} Ansi={1} Unicode={2} OutputEncoding={3} NO_COLOR=[{4}] (ignored) MYWINKIT_NO_COLOR=[{5}]" -f `
    $cap0.ColorSystem, $cap0.Ansi, $cap0.Unicode, [Console]::OutputEncoding.WebName, $env:NO_COLOR, $env:MYWINKIT_NO_COLOR)
$script:EngineLabel = "modern $(C 0x00B7) PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) $(C 0x00B7) Spectre $($script:SpectreVersion)"
$wsz = ''; try { $wsz = "$([Console]::WindowWidth)x$([Console]::WindowHeight)" } catch {}
Write-KitRunLog ("frontend: MODERN started (src\tui-spectre.ps1) - PowerShell {0} at {1}, PwshSpectreConsole {2}, host window {3}, Windows Terminal={4}, dryrun={5}, test={6}" -f `
    $PSVersionTable.PSVersion, (Get-Process -Id $PID).Path, $script:SpectreVersion, $wsz, [bool]$env:WT_SESSION, [bool]$DryRun, [bool]$TestKeys)

# ---------------------------------------------------------------- look

# Gruvbox dark, truecolor
$script:Hex = @{
    Orange = '#fe8019'; Yellow = '#fabd2f'; Green = '#b8bb26'; Red = '#fb4934'
    Aqua = '#8ec07c'; Blue = '#83a598'; Purple = '#d3869b'; Gray = '#928374'
    Fg = '#ebdbb2'; Line = '#665c54'; Dim = '#504945'; Bg1 = '#3c3836'
}
# Glyphs present in both Consolas and Cascadia Mono (no Nerd Font, no emoji)
$script:Glyph = @{
    Ok = C 0x221A; Up = C 0x2191; Down = C 0x2193; Not = C 0x00B7; Fail = C 0x00D7; Heal = C 0x2194; Dry = C 0x25CB
    Same = '='; Dot = C 0x00B7; Arrow = C 0x2192; Pointer = C 0x25BA; Tri = C 0x25B8; Bullet = C 0x2022
    Full = C 0x2588; Shade3 = C 0x2593; Shade2 = C 0x2592; Shade1 = C 0x2591; HalfL = C 0x258C; Warn = C 0x25B2
    LineH = C 0x2500; DLineH = C 0x2550; Left = C 0x00AB; Sun = C 0x263C; Menu = C 0x2261
    On = C 0x25CF; Off = C 0x25CB; Ell = C 0x2026
}
# One accent colour + icon per catalogue group (presentation only; groups live in config/catalog.json)
$script:GroupStyle = @{
    UTIL = @{ Icon = C 0x2261; Color = '#fabd2f' }
    OFCE = @{ Icon = C 0x00B6; Color = '#83a598' }
    BROW = @{ Icon = C 0x25BA; Color = '#8ec07c' }
    CLOU = @{ Icon = C 0x221E; Color = '#83a598' }
    PDF  = @{ Icon = C 0x00A7; Color = '#fb4934' }
    COMM = @{ Icon = C 0x263A; Color = '#b8bb26' }
    REMO = @{ Icon = C 0x2194; Color = '#8ec07c' }
    SECU = @{ Icon = C 0x2666; Color = '#d3869b' }
    MEDI = @{ Icon = C 0x266B; Color = '#fe8019' }
    MAIN = @{ Icon = C 0x2302; Color = '#fabd2f' }
    DSGN = @{ Icon = C 0x2660; Color = '#d3869b' }
    OTHR = @{ Icon = C 0x2022; Color = '#a89984' }
    DEV  = @{ Icon = C 0x00BB; Color = '#fe8019' }
    POST = @{ Icon = C 0x25B2; Color = '#fb4934' }
}
Set-SpectreColors -AccentColor $Hex.Orange -DefaultValueColor $Hex.Gray

# ---------------------------------------------------------------- test console (smoke test)

$script:Test = $null
$script:KeyQueue = [System.Collections.Generic.Queue[ConsoleKeyInfo]]::new()
$script:Heights = [System.Collections.Generic.List[string]]::new()
$script:ScreenName = ''
$script:ScreenStart = 0
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
    $named = @{ Enter = "`r"; Escape = [string][char]27; Spacebar = ' '; Backspace = [string][char]8; Tab = "`t" }
    foreach ($k in ($TestKeys -split ',')) {
        $k = $k.Trim(); if (-not $k) { continue }
        if ($k -like 'text:*') {
            foreach ($ch in $k.Substring(5).ToCharArray()) {
                $ck = [ConsoleKey]0
                if ("$ch" -match '^[a-zA-Z]$') { $ck = [ConsoleKey]("$ch".ToUpper()) } elseif ($ch -eq ' ') { $ck = [ConsoleKey]::Spacebar }
                $script:KeyQueue.Enqueue([ConsoleKeyInfo]::new($ch, $ck, $false, $false, $false))
            }
        } else {
            $chr = if ($named.ContainsKey($k)) { [char]$named[$k] } else { [char]0 }
            $script:KeyQueue.Enqueue([ConsoleKeyInfo]::new($chr, [ConsoleKey]$k, $false, $false, $false))
        }
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
function Get-WindowHeight { if ($script:Test) { return 30 }; try { return [Console]::WindowHeight } catch { return 30 } }
function Get-WindowWidth { if ($script:Test) { return 120 }; try { return [Console]::WindowWidth } catch { return 120 } }
function Get-LinesUsed {
    <# Rows already used on the current screen (from the top of the window). #>
    if ($script:Test) { return ([regex]::Matches($script:Test.Output.Substring($script:ScreenStart), "`n")).Count }
    try { return [Console]::CursorTop - [Console]::WindowTop } catch { return 8 }
}
function Clear-Screen([string]$Name = '') {
    $script:ScreenName = $Name
    if ($script:Test) { Say ''; $script:ScreenStart = $script:Test.Output.Length; return }
    try { [Spectre.Console.AnsiConsole]::Clear() } catch { Say '' }   # no console handle (redirected output)
}
function Format-Duration([TimeSpan]$t) {
    if ($t.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds }
    return '{0:0.0}s' -f $t.TotalSeconds
}
function Limit-Markup([string]$s, [int]$max) {
    <# Cut a markup line to $max visible columns (never wrap), keeping tags balanced. #>
    if ([Spectre.Console.Markup]::Remove($s).Length -le $max) { return $s }
    $sb = [Text.StringBuilder]::new(); $vis = 0; $open = 0; $i = 0
    while ($i -lt $s.Length -and $vis -lt ($max - 1)) {
        $ch = $s[$i]
        if (($ch -eq '[' -or $ch -eq ']') -and ($i + 1) -lt $s.Length -and $s[$i + 1] -eq $ch) { [void]$sb.Append("$ch$ch"); $vis++; $i += 2; continue }
        if ($ch -eq '[') {
            $j = $s.IndexOf(']', $i); if ($j -lt 0) { break }
            $tag = $s.Substring($i, $j - $i + 1)
            if ($tag -eq '[/]') { $open-- } else { $open++ }
            [void]$sb.Append($tag); $i = $j + 1; continue
        }
        [void]$sb.Append($ch); $vis++; $i++
    }
    [void]$sb.Append($script:Glyph.Ell)
    for ($k = 0; $k -lt $open; $k++) { [void]$sb.Append('[/]') }
    return $sb.ToString()
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
    <# "MY WIN KIT" in Spectre's built-in Figlet font, rendered once (~11 ms) and cached. #>
    if ($script:BannerLines) { return $script:BannerLines }
    $cap = [Spectre.Console.Testing.TestConsole]::new()
    $cap.Profile.Width = 200
    $cap.Write([Spectre.Console.FigletText]::new('MY WIN KIT'))
    $lines = @($cap.Output -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    $w = ($lines | Measure-Object -Property Length -Maximum).Maximum
    $script:BannerLines = @($lines | ForEach-Object { ConvertTo-Gradient $_ $w })
    return $script:BannerLines
}

function Show-DryRunBand {
    if (-not $script:DryRunOn) { return }
    $r = [Spectre.Console.Rule]::new("[$($Hex.Purple) bold]$($Glyph.Dry) DRY RUN $($Glyph.Dot) simulation only, nothing will be installed or changed $($Glyph.Dry)[/]")
    $r.Style = St $Hex.Purple
    Out-Render $r
}

function Show-Banner {
    <# Main menu: gradient Figlet banner + subtitle naming the engine (+ dry-run band). #>
    Clear-Screen 'main menu'
    foreach ($l in (Get-BannerLines)) { Say " $l" }
    $admin = if (Test-KitAdmin) { "[$($Hex.Green)]yes[/]" } else { "[$($Hex.Gray)]no[/]" }
    $ci = Get-KitConfigInfo
    $cfg = switch ($ci.Kind) { 'github' { 'config GitHub' } 'cache' { "config cached $($ci.Detail)" } 'bundled' { 'config bundled' } default { 'config ?' } }
    $cfgColor = if ($ci.Kind -eq 'github') { $Hex.Green } else { $Hex.Yellow }
    $s = " [$($Hex.Gray)]v$(Get-KitVersion) $($Glyph.Dot)[/] [$($Hex.Aqua) bold]$(E $script:EngineLabel)[/] [$($Hex.Gray)]$($Glyph.Dot)[/] [$cfgColor]$(E $cfg)[/] [$($Hex.Gray)]$($Glyph.Dot) $(E $env:COMPUTERNAME) $($Glyph.Dot) admin[/] $admin"
    if ($script:DryRunOn) { $s += "  [#282828 on $($Hex.Purple) bold] $($Glyph.Dry) DRY RUN [/]" }
    Say $s
    Show-DryRunBand
    foreach ($w in (Get-KitWarnings)) { Say " [$($Hex.Red)]$($Glyph.Warn) $(E $w)[/]" }
    Say ''
}

function Show-Header([string]$Screen = '') {
    <# Sub-screens: one gradient title rule (+ dry-run band). #>
    Clear-Screen $Screen
    $t = "$(ConvertTo-Gradient 'my-win-kit' 10 1) [$($Hex.Line)]$($Glyph.Tri)[/] [$($Hex.Fg) bold]$(E $Screen)[/]  [$($Hex.Gray)]$(E $script:EngineLabel)[/]"
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
    $parts = foreach ($p in $Pairs) { $k, $a = $p -split '\|', 2; "[$($Hex.Orange) bold]$(E $k)[/] [$($Hex.Gray)]$(E $a)[/]" }
    return ($parts -join "  [$($Hex.Dim)]$($Glyph.Dot)[/]  ")
}

# ---------------------------------------------------------------- the picker (ReadKey + Spectre rendering)

function Read-KitKey {
    if ($script:Test) {
        if ($script:KeyQueue.Count -eq 0) { throw 'Smoke test ran out of keys (screen still waiting for input).' }
        return $script:KeyQueue.Dequeue()
    }
    return [Console]::ReadKey($true)
}

function New-PickItem([string]$Key, [string]$Label, [string]$Text = '', [string]$Group = '', [switch]$Header, [switch]$On) {
    if (-not $Text) { $Text = [Spectre.Console.Markup]::Remove($Label) }
    return [pscustomobject]@{ Key = $Key; Label = $Label; Text = $Text; Group = $Group; IsHeader = [bool]$Header; On = [bool]$On }
}

function Show-Picker {
    <#
    .SYNOPSIS
        Single- or multi-select list with a universal back key. Returns
        @{ Action = select|back|quit|ok|pinned; Key; Selected = keys }.
    .DESCRIPTION
        Keys: up/down/pgup/pgdn/home/end move; enter selects (multi: continues);
        esc, backspace, left = back (with a filter active: clear it first);
        "/" starts type-to-filter (multi and -Search lists); multi: space
        toggles (on a group header: the whole group), a / n = whole group on/off.
        -QuitKey makes that letter return Action = quit (main menu: q).
        Pinned rows (e.g. "Back") stay on top and are never filtered or paged.
        The list is sized to what is left of the window, so it always fits.
    #>
    param(
        [string[]]$Title = @(),
        [object[]]$Items,
        [object[]]$Pinned = @(),
        [switch]$Multi,
        [switch]$Search,
        [switch]$StartSearch,
        [string]$QuitKey = '',
        [switch]$NoBack,
        [string[]]$ReturnKeys = @(),   # extra keys (ConsoleKey names or characters) returned as Action = key
        [int]$Cursor = -1,             # start position (screens that loop keep their place)
        [string]$Filter = '',
        [string[]]$Hints = @()         # replaces the default key hints
    )
    $sel = @{}
    foreach ($it in $Items) { if ($it.On) { $sel[$it.Key] = $true } }
    $searching = [bool]$StartSearch
    $filter = $Filter
    $width = (Get-WindowWidth) - 1
    $fixed = $Title.Count + $Pinned.Count + 3        # + "more" line + 2 footer lines
    $room = (Get-WindowHeight) - (Get-LinesUsed) - 1
    $rows = [Math]::Max(3, [Math]::Min($Items.Count, $room - $fixed))
    $reserve = $fixed + $rows
    $start = -1
    $cursor = if ($Cursor -ge 0) { $Cursor } elseif ($Items.Count) { $Pinned.Count } else { 0 }   # first real item
    $offset = 0
    $first = $true

    while ($true) {
        # ---- visible rows
        $vis = if ($filter) { @($Items | Where-Object { -not $_.IsHeader -and $_.Text -like "*$filter*" }) } else { @($Items) }
        $nav = $Pinned.Count + $vis.Count
        if ($nav -eq 0) { $cursor = 0 } else { if ($cursor -ge $nav) { $cursor = $nav - 1 }; if ($cursor -lt 0) { $cursor = 0 } }
        $ci = $cursor - $Pinned.Count
        if ($ci -ge 0) { if ($ci -lt $offset) { $offset = $ci }; if ($ci -ge $offset + $rows) { $offset = $ci - $rows + 1 } }
        if ($offset -gt [Math]::Max(0, $vis.Count - $rows)) { $offset = [Math]::Max(0, $vis.Count - $rows) }

        # ---- build the frame
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $Title) { $lines.Add($t) }
        for ($i = 0; $i -lt $Pinned.Count; $i++) {
            $mark = if ($cursor -eq $i) { "[$($Hex.Orange) bold]$($Glyph.Tri)[/] " } else { '  ' }
            $lines.Add("$mark$($Pinned[$i].Label)")
        }
        for ($r = 0; $r -lt $rows; $r++) {
            $idx = $offset + $r
            if ($idx -ge $vis.Count) { $lines.Add(''); continue }
            $it = $vis[$idx]
            $isCur = ($cursor -eq $Pinned.Count + $idx)
            $mark = if ($isCur) { "[$($Hex.Orange) bold]$($Glyph.Tri)[/] " } else { '  ' }
            $box = ''
            if ($Multi) {
                if ($it.IsHeader) {
                    $g = @($Items | Where-Object { -not $_.IsHeader -and $_.Group -eq $it.Group })
                    $n = @($g | Where-Object { $sel.ContainsKey($_.Key) }).Count
                    $box = if ($n -eq $g.Count -and $n) { "[$($Hex.Green)]$($Glyph.On)[/] " } elseif ($n) { "[$($Hex.Yellow)]$($Glyph.On)[/] " } else { "[$($Hex.Gray)]$($Glyph.Off)[/] " }
                    $lines.Add("$mark$box$($it.Label) [$($Hex.Gray)]$n/$($g.Count)[/]"); continue
                }
                $box = if ($sel.ContainsKey($it.Key)) { "[$($Hex.Green)]$($Glyph.On)[/] " } else { "[$($Hex.Gray)]$($Glyph.Off)[/] " }
                $box = '  ' + $box
            }
            $label = if ($isCur) { "[on $($Hex.Bg1)]$($it.Label)[/]" } else { $it.Label }
            $lines.Add("$mark$box$label")
        }
        $below = $vis.Count - $offset - $rows
        $more = if ($below -gt 0) { "[$($Hex.Gray)]  $($Glyph.Down) $below more[/]" } elseif ($vis.Count -eq 0) { "[$($Hex.Gray)]  (no match)[/]" } else { '' }
        $lines.Add($more)
        if ($searching) {
            $lines.Add("[$($Hex.Orange) bold]  / [/][$($Hex.Fg)]$(E $filter)[/][$($Hex.Orange)]$($Glyph.Full)[/]  $(Get-KeyHint @('type|filter', 'enter|done', 'esc|clear'))")
        } else {
            $hint = @("$($Glyph.Up)$($Glyph.Down)|move")
            if ($Hints.Count) { $hint += $Hints }
            elseif ($Multi) { $hint += @('space|toggle', 'a/n|group all/none', '/|search', 'enter|continue') }
            else { $hint += 'enter|select'; if ($Search) { $hint += '/|search' } }
            if (-not $NoBack) { $hint += 'esc|back' }
            if ($QuitKey) { $hint += "$QuitKey|quit" }
            $lines.Add('  ' + (Get-KeyHint $hint))
        }
        $sc = if ($Multi) { "  [$($Hex.Green)]$($sel.Count) selected[/]" } else { '' }
        $lines.Add("[$($Hex.Line)]$($Glyph.LineH * 3)[/]$sc" + $(if ($filter -and -not $searching) { "  [$($Hex.Gray)]filter:[/] [$($Hex.Fg)]$(E $filter)[/] [$($Hex.Gray)](esc clears)[/]" } else { '' }))

        # ---- draw (real console: redraw in place; test console: append frames)
        if ($script:Test) {
            if ($first) { $script:Heights.Add("$($script:ScreenName)=$((Get-LinesUsed) + $lines.Count)") }
        } else {
            if ($start -lt 0) {
                [Console]::Write("`n" * $reserve)                    # make room (scrolls the window if needed)
                $start = [Math]::Max(0, [Console]::CursorTop - $reserve)
            }
            [Console]::SetCursorPosition(0, $start)
            [Console]::Write("$([char]27)[J")
        }
        foreach ($l in $lines) { Say (Limit-Markup $l $width) }
        $first = $false

        # ---- keys
        $k = Read-KitKey
        $kc = $k.KeyChar
        $curItem = if ($ci -ge 0 -and $ci -lt $vis.Count) { $vis[$ci] } else { $null }
        switch ($k.Key) {
            'UpArrow'   { $cursor = if ($cursor -le 0) { $nav - 1 } else { $cursor - 1 }; continue }
            'DownArrow' { $cursor = if ($cursor -ge $nav - 1) { 0 } else { $cursor + 1 }; continue }
            'PageUp'    { $cursor = [Math]::Max(0, $cursor - $rows); continue }
            'PageDown'  { $cursor = [Math]::Min($nav - 1, $cursor + $rows); continue }
            'Home'      { $cursor = 0; continue }
            'End'       { $cursor = $nav - 1; continue }
        }
        # (continue inside a switch only leaves the switch)
        if ($k.Key -in 'UpArrow', 'DownArrow', 'PageUp', 'PageDown', 'Home', 'End') { continue }
        if ($searching) {
            if ($k.Key -eq 'Escape') { $filter = ''; $searching = $false; $cursor = $Pinned.Count; continue }
            if ($k.Key -eq 'Backspace') { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1) } else { $searching = $false }; continue }
            if ($k.Key -eq 'Enter') {
                $searching = $false
                if (-not $Multi -and $curItem) { return @{ Action = 'select'; Key = $curItem.Key; Selected = @() } }
                continue
            }
            if ([int]$kc -ge 32) { $filter += $kc; $cursor = $Pinned.Count; $offset = 0; continue }
            continue
        }
        if ($k.Key -in 'Escape', 'Backspace', 'LeftArrow') {
            if ($filter) { $filter = ''; $cursor = $Pinned.Count; continue }
            if (-not $NoBack) { return @{ Action = 'back'; Key = $null; Selected = @($sel.Keys) } }
            continue
        }
        if ($QuitKey -and "$kc" -eq $QuitKey) { return @{ Action = 'quit'; Key = $null; Selected = @() } }
        if ($ReturnKeys.Count -and $curItem -and ($ReturnKeys -contains [string]$k.Key -or ($kc -and [int]$kc -ge 32 -and $ReturnKeys -contains "$kc"))) {
            $name = if ($ReturnKeys -contains [string]$k.Key) { [string]$k.Key } else { "$kc" }
            return @{ Action = 'key'; KeyName = $name; Key = $curItem.Key; Selected = @(); Cursor = $cursor; Filter = $filter }
        }
        if ("$kc" -eq '/' -and ($Multi -or $Search)) { $searching = $true; continue }
        if ($k.Key -eq 'Enter' -or ($k.Key -eq 'Spacebar' -and $cursor -lt $Pinned.Count)) {
            if ($cursor -lt $Pinned.Count) { return @{ Action = 'pinned'; Key = $Pinned[$cursor].Key; Selected = @($sel.Keys) } }
            if ($Multi) { return @{ Action = 'ok'; Key = $null; Selected = @($sel.Keys) } }
            if ($curItem) { return @{ Action = 'select'; Key = $curItem.Key; Selected = @(); Cursor = $cursor; Filter = $filter } }
            continue
        }
        if ($Multi -and $curItem) {
            if ($k.Key -eq 'Spacebar') {
                if ($curItem.IsHeader) {
                    $g = @($Items | Where-Object { -not $_.IsHeader -and $_.Group -eq $curItem.Group })
                    $allOn = @($g | Where-Object { $sel.ContainsKey($_.Key) }).Count -eq $g.Count
                    foreach ($x in $g) { if ($allOn) { $sel.Remove($x.Key) } else { $sel[$x.Key] = $true } }
                } elseif ($sel.ContainsKey($curItem.Key)) { $sel.Remove($curItem.Key) } else { $sel[$curItem.Key] = $true }
                continue
            }
            if ("$kc" -in 'a', 'n') {
                foreach ($x in @($Items | Where-Object { -not $_.IsHeader -and $_.Group -eq $curItem.Group })) {
                    if ("$kc" -eq 'a') { $sel[$x.Key] = $true } else { $sel.Remove($x.Key) }
                }
                continue
            }
        }
    }
}

function Select-One {
    <# Single choice; a pinned Back row on every screen except the main menu. Returns Key, or 'back' / 'quit'. #>
    param([string[]]$Title, [object[]]$Items, [string]$BackLabel = 'Back', [string]$QuitKey = '', [switch]$NoBack)
    $pinned = @()
    if (-not $NoBack) { $pinned = @(New-PickItem 'back' "[$($Hex.Gray)]$($Glyph.Left) $(E $BackLabel)[/]") }
    $list = @($Items | ForEach-Object { if ($_ -is [hashtable]) { New-PickItem $_.Key $_.Label } else { $_ } })
    $r = Show-Picker -Title $Title -Items $list -Pinned $pinned -QuitKey $QuitKey -NoBack:$NoBack
    switch ($r.Action) {
        'select' { return $r.Key }
        'pinned' { return $r.Key }
        'quit'   { return 'quit' }
        default  { return 'back' }
    }
}

function Wait-Back([string]$Label = 'Back to main menu') {
    [void](Select-One -Title @() -Items @(@{ Key = 'ok'; Label = "[$($Hex.Orange) bold]$($Glyph.Left) $(E $Label)[/]" }) -BackLabel $Label)
}

# ---------------------------------------------------------------- tables, panels, labels

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

function Get-GroupStyle([string]$Key) {
    <# Groups added from the menu (config/catalog.json) have no style of their own: neutral fallback. #>
    if ($script:GroupStyle.ContainsKey($Key)) { return $script:GroupStyle[$Key] }
    return @{ Icon = $script:Glyph.Bullet; Color = '#a89984' }
}

function Get-GroupLabel($g) {
    $s = Get-GroupStyle $g.Key
    return "[$($s.Color) bold]$($s.Icon) $(E $g.Label.ToUpper())[/]"
}

# ---------------------------------------------------------------- badges (one vocabulary everywhere)

function Get-StateBadge($p) {
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
    return "[$($Hex.Green)]$($Glyph.Ok) installed[/]  [$($Hex.Yellow)]$($Glyph.Up) update[/]  [$($Hex.Gray)]$($Glyph.Not) not installed[/]  [$($Hex.Red)]$($Glyph.Fail) failed[/]  [$($Hex.Aqua)]$($Glyph.Heal) healed[/]"
}

function Invoke-Scan([switch]$Updates) {
    $script:Installed = @{}; $script:Updates = @{}
    [void](Enable-KitConsoleVt)   # before the live spinner: a child (or the host) may have left VT off
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
    [void](Enable-KitConsoleVt)   # in case a child left VT processing off
    $script:ScanDone = $true
}

function Get-TrimmedRows([object[]]$Rows, [int]$Max, [scriptblock]$Priority) {
    <# Keep tables short enough that the action list below them stays on screen. #>
    if ($Rows.Count -le $Max) { return @{ Rows = $Rows; Hidden = 0 } }
    $keep = @($Rows | Sort-Object $Priority | Select-Object -First $Max)
    $ordered = @($Rows | Where-Object { $keep -contains $_ })
    return @{ Rows = $ordered; Hidden = $Rows.Count - $Max }
}

# ---------------------------------------------------------------- state

$script:Catalog   = @(Initialize-Kit -KitRoot $KitRoot)
$script:Groups    = @(Get-KitGroups)
$script:State     = Get-KitState
$script:DryRunOn  = [bool]$DryRun
$script:Installed = @{}
$script:Updates   = @{}
$script:ScanDone  = $false
# Dry run: from -DryRun or the shared setting settings.dryRunByDefault
if ((Get-KitSetting 'dryRunByDefault' $false) -and -not $script:DryRunOn) { $script:DryRunOn = $true; Write-KitRunLog 'modern: dry run because settings.dryRunByDefault is on' }
foreach ($w in (Get-KitWarnings)) { Write-KitRunLog "packages: WARNING $w" }

if (-not (Test-KitWinget) -and -not $script:Test) {
    Show-Header 'winget missing'
    Out-Render (New-KitPanel "[$($Hex.Fg)]winget (App Installer) is missing - most installs need it.`nOpening its Microsoft Store page: install it, then run install.cmd again.[/]" " [$($Hex.Red)]$($Glyph.Warn) heads up[/] " $Hex.Red)
    try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch { Say 'Manual link: https://aka.ms/getwinget' }
    Say ''
    if ((Select-One -Title "[$($Hex.Fg) bold]Continue anyway?[/] [$($Hex.Gray)](script and direct installs still work)[/]" -Items @(@{ Key = 'yes'; Label = 'Continue' }) -BackLabel 'Quit') -ne 'yes') { exit 0 }
}

# ---------------------------------------------------------------- app picker

function Get-AppLabel($it) {
    $label = "$(Get-StateBadge $it) [$($Hex.Fg)]$(E $it.Name)[/]"
    if ($script:Installed.ContainsKey($it.Id)) { $label += "  $(Get-StateText $it)" }
    if ($it.Method -ne 'winget') { $label += "  [$($Hex.Aqua)]$(Get-MethodLabel $it)[/]" }
    return $label
}

function Select-Apps {
    <# Grouped multi-select. Returns @{ Action = ok|back; Packages }. #>
    param([int[]]$Preselect, [switch]$StartSearch, [string]$Heading = 'Choose apps')
    $items = foreach ($g in $script:Groups) {
        $members = @($script:Catalog | Where-Object Group -eq $g.Key | Sort-Object Id)
        if (-not $members) { continue }
        $gl = Get-GroupLabel $g
        if ($g.Key -eq 'POST') { $gl += " [$($Hex.Red)]runs last, opens its own windows[/]" }
        New-PickItem "g:$($g.Key)" $gl -Group $g.Key -Header
        foreach ($it in $members) {
            New-PickItem "$($it.Id)" (Get-AppLabel $it) -Text "$($it.Name) $($it.Desc)" -Group $g.Key -On:($Preselect -contains $it.Id)
        }
    }
    $pinned = @(
        New-PickItem 'done' "[$($Hex.Orange) bold]$($Glyph.Pointer) Continue[/] [$($Hex.Gray)](enter)[/]"
        New-PickItem 'back' "[$($Hex.Gray)]$($Glyph.Left) Back[/]"
    )
    $title = @("[$($Hex.Fg) bold]$(E $Heading)[/]   $(Get-LegendMarkup)")
    $r = Show-Picker -Title $title -Items @($items) -Pinned $pinned -Multi -StartSearch:$StartSearch
    if ($r.Action -eq 'back' -or ($r.Action -eq 'pinned' -and $r.Key -eq 'back')) { return @{ Action = 'back'; Packages = @() } }
    $ids = @($r.Selected | Where-Object { $_ -notlike 'g:*' } | ForEach-Object { [int]$_ })
    return @{ Action = 'ok'; Packages = @($script:Catalog | Where-Object { $ids -contains $_.Id }) }
}

function Show-Review {
    param([object[]]$Selection)
    $order = @(Get-KitRunOrder $Selection)
    # rows that fit: window - header(3) - title/borders/caption(5) - POST note(1) - action list(~9)
    $max = [Math]::Max(4, (Get-WindowHeight) - 20)
    $trim = Get-TrimmedRows $order $max { if ($script:Updates.ContainsKey($_.Id)) { 0 } elseif (-not $script:Installed.ContainsKey($_.Id)) { 1 } else { 2 } }
    $t = New-KitTable @(' ', 'App', 'Group', 'How', 'On this PC', 'Will') $Hex.Orange
    $gmap = @{}; foreach ($g in $script:Groups) { $gmap[$g.Key] = $g }
    foreach ($p in $trim.Rows) {
        $isInst = $script:Installed.ContainsKey($p.Id)
        $will = if ($p.Interactive) { "[$($Hex.Purple)]run (interactive)[/]" }
                elseif ($script:Updates.ContainsKey($p.Id)) { "[$($Hex.Yellow)]update[/]" }
                elseif ($isInst) { "[$($Hex.Aqua)]check for update[/]" }
                else { "[$($Hex.Green)]install[/]" }
        $gs = (Get-GroupStyle $p.Group)
        Add-KitRow $t @((Get-StateBadge $p), "[$($Hex.Fg)]$(E $p.Name)[/]", "[$($gs.Color)]$($gs.Icon) $(E $gmap[$p.Group].Label)[/]", (Get-MethodLabel $p), (Get-StateText $p), $will)
    }
    $n = $Selection.Count
    $have = @($Selection | Where-Object { $script:Installed.ContainsKey($_.Id) }).Count
    $upd = @($Selection | Where-Object { $script:Updates.ContainsKey($_.Id) }).Count
    $cap = "[$($Hex.Fg)]$(Get-Plural $n "app")[/] [$($Hex.Gray)]$($Glyph.Dot)[/] [$($Hex.Green)]$($n - $have) new[/] [$($Hex.Gray)]$($Glyph.Dot)[/] [$($Hex.Yellow)]$upd with updates[/] [$($Hex.Gray)]$($Glyph.Dot) $have already installed[/]"
    if ($trim.Hidden) { $cap += " [$($Hex.Gray)]$($Glyph.Dot) $($trim.Hidden) more not shown (new and updates first)[/]" }
    $t.Caption = [Spectre.Console.TableTitle]::new($cap)
    Out-Render $t
    if (@($Selection | Where-Object Group -eq 'POST').Count -gt 0) {
        Say "[$($Hex.Red)]$($Glyph.Warn)[/] [$($Hex.Fg)]Post-install items run last and open their own prompts or windows.[/]"
    }
}

# ---------------------------------------------------------------- run

function Write-ResultLine($res) {
    $line = "  $(Get-ResultBadge $res) [$($Hex.Fg)]$(E $res.Name)[/]  $(Get-ResultText $res)  $(Get-VersionMarkup $res)  [$($Hex.Gray)]$($res.Seconds)s[/]"
    if ($res.Healed) { $line += "  [$($Hex.Aqua)]$($Glyph.Heal) $(E $res.Healed)[/]" }
    if ($res.Status -eq 'failed' -and $res.Detail) { $line += "  [$($Hex.Gray)]$(E $res.Detail)[/]" }
    Say (Limit-Markup $line ((Get-WindowWidth) - 1))
}

function Invoke-Run {
    <# Install/update with a live progress view, then a results screen that fits the window. #>
    param([object[]]$Selection, [ValidateSet('install', 'update')][string]$Mode = 'install', [string]$Title = 'Installing')
    $order = @(Get-KitRunOrder $Selection)
    $live = @($order | Where-Object { -not $_.Interactive -or $script:DryRunOn })
    $inter = @($order | Where-Object { $_.Interactive -and -not $script:DryRunOn })
    Show-Header $Title
    $log = Start-KitLog
    Write-KitRunLog "run: $Mode $($order.Count) app(s), dryrun=$($script:DryRunOn), log $log"
    $before = @(); if (Get-KitSetting 'removeShortcuts' $true) { $before = @(Get-KitDesktopShortcuts) }
    $total = [Diagnostics.Stopwatch]::StartNew()
    $script:runResults = [System.Collections.Generic.List[object]]::new()

    if ($live.Count) {
        # Children run through Invoke-KitProcess (core) so they cannot switch the
        # console's VT processing off under the live view; this re-enables it anyway.
        [void](Enable-KitConsoleVt)
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
                $gs = (Get-GroupStyle $p.Group)
                $name = "[$($gs.Color)]$($gs.Icon)[/] [$($Hex.Fg)]$(E $p.Name)[/]"
                $task = $ctx.AddTask("$name [$($Hex.Gray)]$(Get-MethodLabel $p)[/]")
                $task.IsIndeterminate = $true
                $inst = $null; if ($script:Installed.ContainsKey($p.Id)) { $inst = $script:Installed[$p.Id] }
                $onStatus = { param($m) [void](Enable-KitConsoleVt); $task.Description = "$name [$($Hex.Gray)]$(E $m)...[/]" }
                $res = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -DryRun:$script:DryRunOn -OnStatus $onStatus
                [void](Enable-KitConsoleVt)
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
        $res = Invoke-KitPackage -Package $p -Installed $inst -Mode $Mode -OnStatus { param($m) Say "  [$($Hex.Gray)]$($Glyph.Tri) $(E $m)[/]" }
        [void](Enable-KitConsoleVt)   # interactive children share the console
        $script:runResults.Add($res)
        Write-ResultLine $res
    }
    $results = @($script:runResults)
    $removed = @()
    if ((Get-KitSetting 'removeShortcuts' $true) -and -not $script:DryRunOn) { $removed = @(Remove-KitNewShortcuts -Before $before) }
    $fl = @($results | Where-Object Status -eq 'failed').Count
    $ok = @($results | Where-Object Status -in 'installed', 'updated', 'current', 'done', 'dryrun').Count
    $hl = @($results | Where-Object Healed).Count
    Write-KitRunLog "run: done - $ok ok, $hl healed, $fl failed in $(Format-Duration $total.Elapsed)"

    # Results screen (fresh, so the summary and the back item are always on screen)
    Show-Header "$Title $($Glyph.Dot) results"
    $max = [Math]::Max(4, (Get-WindowHeight) - 21)
    $trim = Get-TrimmedRows $results $max { switch ($_.Status) { 'failed' { 0 } default { if ($_.Healed) { 1 } elseif ($_.Status -in 'installed', 'updated') { 2 } else { 3 } } } }
    $t = New-KitTable @(' ', 'App', 'Result', 'Version', 'Time', 'Note') $(if ($fl) { $Hex.Red } else { $Hex.Green })
    foreach ($r in $trim.Rows) {
        $note = ''
        if ($r.Healed) { $note = "[$($Hex.Aqua)]$($Glyph.Heal) $(E $r.Healed)[/]" }
        elseif ($r.Status -in 'failed', 'dryrun' -and $r.Detail) { $note = "[$($Hex.Gray)]$(E $r.Detail)[/]" }
        # one line per row, so the screen height stays predictable (details are in the log)
        Add-KitRow $t @((Get-ResultBadge $r), "[$($Hex.Fg)]$(E $r.Name)[/]", (Get-ResultText $r), (Get-VersionMarkup $r), "[$($Hex.Gray)]$($r.Seconds)s[/]", (Limit-Markup $note 46))
    }
    if ($trim.Hidden) { $t.Caption = [Spectre.Console.TableTitle]::new("[$($Hex.Gray)]$($trim.Hidden) more not shown (failures and changes first) - full list in the log[/]") }
    Out-Render $t
    $sum = "[$($Hex.Green) bold]$($Glyph.Ok) $ok ok[/]   [$($Hex.Aqua) bold]$($Glyph.Heal) $hl healed[/]   [$($Hex.Red) bold]$($Glyph.Fail) $fl failed[/]   [$($Hex.Fg)]total $(Format-Duration $total.Elapsed)[/]"
    if ($script:DryRunOn) { $sum += "   [$($Hex.Purple) bold]$($Glyph.Dry) DRY RUN - nothing was installed or changed[/]" }
    if ($removed.Count) { $sum += "`n[$($Hex.Gray)]Removed $($removed.Count) new desktop shortcut(s): $(E ($removed -join ', '))[/]" }
    if ($hl) { $sum += "`n[$($Hex.Aqua)]Healed package IDs saved to winget-id-overrides.json - every PC starts healed.[/]" }
    $sum += "`n[$($Hex.Gray)]Log: $(E $log)[/]"
    $border = if ($script:DryRunOn) { $Hex.Purple } elseif ($fl) { $Hex.Red } else { $Hex.Green }
    Out-Render (New-KitPanel $sum " [$border bold]Summary[/] " $border)

    $script:State.LastSelection = @($Selection | ForEach-Object Id)
    $script:State.LastFailed = @($results | Where-Object Status -eq 'failed' | ForEach-Object Id)
    if (-not $script:DryRunOn) { Save-KitState $script:State }
    return $results
}

# ---------------------------------------------------------------- screens

function Show-Install {
    if (-not $script:ScanDone) { Show-Header 'Install or update apps'; Invoke-Scan -Updates }
    $step = 'start'; $sel = @()
    while ($true) {
        switch ($step) {
            'start' {
                Show-Header 'Install or update apps'
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
                $start = Select-One -Title "[$($Hex.Fg) bold]Start from[/]" -Items $items -BackLabel 'Back to main menu'
                $pre = switch ($start) {
                    'def'  { @($def.Id) }
                    'miss' { @($missing.Id) }
                    'upd'  { @($upd.Id) }
                    'fail' { $script:State.LastFailed }
                    'last' { $script:State.LastSelection }
                    'none' { @() }
                    default { return }
                }
                $sel = @($script:Catalog | Where-Object { $pre -contains $_.Id })
                $step = 'pick'
            }
            'pick' {
                Show-Header 'Choose apps'
                $r = Select-Apps -Preselect @($sel.Id)
                if ($r.Action -eq 'back') { $step = 'start'; continue }
                $sel = @($r.Packages); $step = 'review'
            }
            'search' {
                Show-Header 'Search apps'
                $r = Select-Apps -Preselect @($sel.Id) -StartSearch -Heading 'Search apps'
                if ($r.Action -eq 'ok') { $sel = @($r.Packages) }
                $step = 'review'
            }
            'review' {
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
                $acts += @{ Key = 'menu';   Label = "[$($Hex.Gray)]Main menu[/]" }
                switch (Select-One -Title "[$($Hex.Fg) bold]Next[/]" -Items $acts -BackLabel 'Back to the app list') {
                    'go'     { [void](Invoke-Run -Selection $sel); $script:ScanDone = $false; Wait-Back; return }
                    'search' { $step = 'search' }
                    'edit'   { $step = 'pick' }
                    'menu'   { return }
                    default  { $step = 'pick' }
                }
            }
        }
    }
}

function Show-UpdateAI {
    Show-Header 'Update AI tools'
    $ai = @($script:Catalog | Where-Object AI | Sort-Object GroupOrder, Id)
    $script:latest = @{}
    [void](Enable-KitConsoleVt)   # before the live spinner: a child (or the host) may have left VT off
    $st = [Spectre.Console.AnsiConsole]::Status()
    $st.Spinner = [Spectre.Console.Spinner+Known]::Point
    $st.SpinnerStyle = St $Hex.Orange
    $st.Start("[$($Hex.Fg)]Checking installed and latest versions...[/]", [Action[Spectre.Console.StatusContext]] {
        param($ctx)
        [void]$ctx   # Spectre passes the StatusContext; not every caller needs it
        $script:Installed = Get-KitInstalled
        $script:Updates = @{}
        foreach ($p in $ai) {
            if (-not $script:Installed.ContainsKey($p.Id)) { continue }   # only installed tools are updated here
            $lt = Get-KitLatestVersion -Package $p
            $script:latest[$p.Id] = $lt
            if ($lt -and $script:Installed.ContainsKey($p.Id) -and -not (Test-KitVersionCurrent -Installed $script:Installed[$p.Id] -Latest $lt)) { $script:Updates[$p.Id] = $lt }
        }
    })
    [void](Enable-KitConsoleVt)
    $script:ScanDone = $false   # updates map here is AI-only; the install screen rescans

    while ($true) {
        Show-Header 'Update AI tools'
        $t = New-KitTable @(' ', 'Tool', 'Installed', 'Latest', 'How it updates') $Hex.Aqua
        # rows that fit: window - header(3) - table frame + caption(5) - blank(1) - action list(~8)
        $trim = Get-TrimmedRows $ai ([Math]::Max(4, (Get-WindowHeight) - 17)) { if ($script:Updates.ContainsKey($_.Id)) { 0 } elseif ($script:Installed.ContainsKey($_.Id)) { 1 } else { 2 } }
        foreach ($p in $trim.Rows) {
            $inst = if ($script:Installed.ContainsKey($p.Id)) { $v = $script:Installed[$p.Id]; if ($v) { E $v } else { 'installed' } } else { "[$($Hex.Gray)]not installed[/]" }
            $lt = $script:latest[$p.Id]
            $latest = if ($script:Updates.ContainsKey($p.Id)) { "[$($Hex.Yellow) bold]$(E $lt)[/]" } elseif ($lt) { "[$($Hex.Green)]$(E $lt)[/]" } elseif ($p.Update) { "[$($Hex.Gray)]checked by $(E $p.Update)[/]" } else { "[$($Hex.Gray)]-[/]" }
            $how = switch ($p.Method) {
                'script' { if ($p.Update) { "[$($Hex.Aqua)]$(E $p.Update)[/] [$($Hex.Gray)](official updater)[/]" } else { 'official installer' } }
                'direct' { "[$($Hex.Aqua)]official download page[/] [$($Hex.Gray)](signed)[/]" }
                'npm'    { 'npm install -g (latest)' }
                default  { if ($p.Appx) { 'winget + updates itself' } else { 'winget upgrade' } }
            }
            Add-KitRow $t @((Get-StateBadge $p), "[$($Hex.Fg)]$(E $p.Name)[/]", $inst, $latest, $how)
        }
        $cap = Get-LegendMarkup
        if ($trim.Hidden) { $cap += "  [$($Hex.Gray)]$($Glyph.Dot) $($trim.Hidden) more not installed[/]" }
        $t.Caption = [Spectre.Console.TableTitle]::new($cap)
        Out-Render $t
        Say ''
        # Only installed tools are updated here; the AI flag never installs anything (use Install or update apps for that).
        $have = @(Get-KitAiUpdateSet -Installed $script:Installed -Packages $ai)
        $items = @()
        if ($have.Count) {
            $items += @{ Key = 'all'; Label = "[$($Hex.Orange) bold]$($Glyph.Pointer) Update all installed[/] [$($Hex.Gray)]($(Get-Plural $have.Count "tool"))[/]" }
            $items += @{ Key = 'pick'; Label = "[$($Hex.Fg)]Pick which installed tools to update[/]" }
        }
        $title = if ($have.Count) { "[$($Hex.Fg) bold]Update[/] [$($Hex.Gray)](installed tools only; new ones: Install or update apps)[/]" } else { "[$($Hex.Fg) bold]No AI tools installed on this PC[/] [$($Hex.Gray)](install them from Install or update apps)[/]" }
        $choice = Select-One -Title $title -Items $items -BackLabel 'Back to main menu'
        $sel = $null
        switch ($choice) {
            'all'  { $sel = $have }
            'pick' {
                Show-Header 'Choose AI tools'
                $pitems = foreach ($x in $have) { New-PickItem "$($x.Id)" (Get-AppLabel $x) -Text $x.Name -Group 'AI' -On }
                $pinned = @(
                    New-PickItem 'done' "[$($Hex.Orange) bold]$($Glyph.Pointer) Continue[/] [$($Hex.Gray)](enter)[/]"
                    New-PickItem 'back' "[$($Hex.Gray)]$($Glyph.Left) Back[/]"
                )
                $r = Show-Picker -Title @("[$($Hex.Fg) bold]Choose AI tools[/]") -Items @($pitems) -Pinned $pinned -Multi
                if ($r.Action -eq 'back' -or ($r.Action -eq 'pinned' -and $r.Key -eq 'back')) { continue }
                $ids = @($r.Selected | ForEach-Object { [int]$_ })
                $sel = @($have | Where-Object { $ids -contains $_.Id })
            }
            default { return }
        }
        if (-not $sel -or $sel.Count -eq 0) { continue }
        [void](Invoke-Run -Selection $sel -Mode 'update' -Title 'Updating AI tools')
        Wait-Back
        return
    }
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
    )
    switch (Select-One -Title "[$($Hex.Fg) bold]Tweaks[/]" -Items $items -BackLabel 'Back to main menu') {
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

# ---------------------------------------------------------------- settings (read-only)
# The menu never writes config: config/*.json is edited by hand in the repo, and every
# PC reads the latest from GitHub at its next start.

function Get-ConfigSourceText {
    $i = Get-KitConfigInfo
    switch ($i.Kind) {
        'github'  { "GitHub ($($i.Repo)@$($i.Branch))" }
        'cache'   { "cached copy from $($i.Detail) (GitHub not reachable)" }
        'bundled' { 'the copy bundled with the kit (GitHub not reachable, no cache)' }
        default   { $i.Kind }
    }
}

function Get-SettingsPanel {
    <# Read-only summary: config source, settings values, learned package-ID fixes. #>
    $i = Get-KitConfigInfo
    $srcHex = if ($i.Kind -eq 'github') { $Hex.Green } else { $Hex.Yellow }
    $on = "[$($Hex.Green) bold]on [/]"; $off = "[$($Hex.Gray)]off[/]"
    $lines = @("[$($Hex.Gray)]Config   [/] [$srcHex]$(E (Get-ConfigSourceText))[/]")
    $known = @(
        @{ Name = 'removeShortcuts'; Default = $true;  Desc = 'remove desktop shortcuts that installers create' }
        @{ Name = 'dryRunByDefault'; Default = $false; Desc = 'start every run in dry run' }
        @{ Name = 'autoInstallPwsh'; Default = $true;  Desc = 'loader installs PowerShell 7 + Terminal unasked (each PC can override)' }
    )
    $first = $true
    foreach ($s in $known) {
        $v = if (Get-KitSetting $s.Name $s.Default) { $on } else { $off }
        $label = if ($first) { 'Settings ' } else { '         ' }
        $lines += "[$($Hex.Gray)]$label[/] [$($Hex.Fg)]$($s.Name.PadRight(16))[/] $v [$($Hex.Gray)]$($Glyph.Dot) $(E $s.Desc)[/]"
        $first = $false
    }
    $fx = { param([int]$n) if ($n -eq 1) { '1 package-ID fix' } else { "$n package-ID fixes" } }
    $lines += "[$($Hex.Gray)]Fixes    [/] [$($Hex.Fg)]$(& $fx (Get-KitOverrideCount)) in use[/] [$($Hex.Gray)](learned when winget renames or breaks an ID)[/]"
    if ($i.LocalFixes) {
        $lines += "[$($Hex.Gray)]         [/] [$($Hex.Yellow)]$(& $fx $i.LocalFixes) learned on this PC only, kept in[/]"
        $lines += "[$($Hex.Gray)]         [/] [$($Hex.Aqua)]$(E $i.LocalFixesFile)[/]"
        $lines += "[$($Hex.Gray)]         [/] [$($Hex.Gray)]copy them into config/winget-id-overrides.json to share them with every PC[/]"
    } else {
        $lines += "[$($Hex.Gray)]         [/] [$($Hex.Gray)]none learned on this PC only[/]"
    }
    $lines += ''
    $lines += "[$($Hex.Orange)]To change config, edit config/*.json in the my-win-kit repo on GitHub.[/]"
    return (New-KitPanel ($lines -join "`n") " [$($Hex.Blue) bold]read-only[/] " $Hex.Line)
}

function Show-Settings {
    while ($true) {
        Show-Header 'Settings'
        Out-Render (Get-SettingsPanel)
        Say ''
        $dr = if ($script:DryRunOn) { "[$($Hex.Purple) bold]on[/]" } else { "[$($Hex.Gray)]off[/]" }
        $ap = Get-KitAutoInstallPwsh
        $apv = if ($ap.On) { "[$($Hex.Green) bold]on[/]" } else { "[$($Hex.Gray)]off[/]" }
        $aps = if ($ap.Source -eq 'this PC') { '(this PC)' } else { '(this PC: shared default)' }
        $items = @(
            @{ Key = 'auto'; Label = "[$($Hex.Fg)]Auto-install PowerShell 7 + Terminal on start:[/] $apv [$($Hex.Gray)]$aps[/]" }
            @{ Key = 'dr';   Label = "[$($Hex.Fg)]Dry run now (show what would run, install nothing):[/] $dr [$($Hex.Gray)](this session)[/]" }
            @{ Key = 'log';  Label = "[$($Hex.Fg)]Open the log folder[/]" }
        )
        $runlog = if ($env:MYWINKIT_RUNLOG) { "[$($Hex.Gray)]run log: $(E $env:MYWINKIT_RUNLOG)[/]" } else { '' }
        switch (Select-One -Title @("[$($Hex.Fg) bold]Settings[/]", $runlog) -Items $items -BackLabel 'Back to main menu') {
            # per-PC preference in local-settings.json (never GitHub); tests only write into their scratch state folder
            'auto' { if (-not $script:Test -or $env:MYWINKIT_STATE_DIR) { Set-KitLocalPref -Name 'autoInstallPwsh' -Value (-not $ap.On) } }
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
    Clear-Screen 'goodbye'
    $w = 64
    $bar = ($Glyph.Shade1 + $Glyph.Shade2 + $Glyph.Shade3 + $Glyph.Full) + ($Glyph.DLineH * ($w - 8)) + ($Glyph.Full + $Glyph.Shade3 + $Glyph.Shade2 + $Glyph.Shade1)
    Say " $(ConvertTo-Gradient $bar $w 2)"
    $msg = 'all set - see you next time'
    Say " $(' ' * [int](($w - $msg.Length) / 2))$(ConvertTo-Gradient $msg $msg.Length 1)"
    Say " $(ConvertTo-Gradient $bar $w 2)"
    Say ''
}

# ---------------------------------------------------------------- main loop

try {
    while ($true) {
        Show-Banner
        $menu = @(
            @{ Key = 'install';  Icon = $Glyph.Pointer; Color = $Hex.Orange; Name = 'Install or update apps'; Desc = "pick from $($script:Catalog.Count) apps: install new ones, update the rest" }
            @{ Key = 'ai';       Icon = $Glyph.Up;      Color = $Hex.Aqua;   Name = 'Update AI tools';        Desc = "the AI tools installed here to latest: Claude, Codex, Cursor, Antigravity $($Glyph.Ell)" }
            @{ Key = 'tweaks';   Icon = $Glyph.Sun;     Color = $Hex.Yellow; Name = 'Windows tweaks';         Desc = 'Spotlight icon, lock-screen tips, Start web search, auto-lock' }
            @{ Key = 'settings'; Icon = $Glyph.Menu;    Color = $Hex.Blue;   Name = 'Settings';               Desc = 'config (read-only), auto PowerShell 7 on this PC, dry run, log folder' }
            @{ Key = 'quit';     Icon = $Glyph.Left;    Color = $Hex.Gray;   Name = 'Quit';                   Desc = 'or press q' }
        )
        $items = foreach ($m in $menu) {
            @{ Key = $m.Key; Label = "[$($m.Color) bold]$($m.Icon)[/] [$($Hex.Fg) bold]$(E $m.Name.PadRight(24))[/] [$($Hex.Gray)]$(E $m.Desc)[/]" }
        }
        $k = Select-One -Title "[$($Hex.Orange) bold]$($Glyph.HalfL) MAIN MENU[/]" -Items $items -QuitKey 'q' -NoBack
        Write-KitRunLog "menu: $k"
        switch ($k) {
            'install'  { Show-Install }
            'ai'       { Show-UpdateAI }
            'tweaks'   { Show-Tweaks }
            'settings' { Show-Settings }
            default {
                Show-Goodbye
                Write-KitRunLog 'frontend: modern quit normally'
                if ($script:Test) {
                    [Console]::Out.Write($script:Test.Output)
                    [Console]::Out.WriteLine("SCREEN-HEIGHTS: $($script:Heights -join '; ')")
                }
                exit 0
            }
        }
    }
} catch {
    Write-KitRunLog "modern: ERROR $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    if ($script:Test) { [Console]::Out.Write($script:Test.Output); [Console]::Out.WriteLine("SCREEN-HEIGHTS: $($script:Heights -join '; ')") }
    throw
}
