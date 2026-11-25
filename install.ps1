#Requires -Version 5.1
# ─────────────────────────────────────────────────────────────
#  Daniel's Workstation Installer
#  Fresh-Windows quick start (works on stock PowerShell 5.1):
#    • double-click install.cmd (auto-created next to this script), or
#    • powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# ─────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = "Daniel's Workstation Installer"

# ─── FRESH-SYSTEM BOOTSTRAP ──────────────────────────────────
# TLS 1.2 for web calls — stock Windows PowerShell 5.1 may default lower
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
if ($PSCommandPath) {
    # Remove mark-of-the-web so future direct runs aren't blocked by policy
    try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue } catch {}
    # (Re)create the double-clickable launcher — bypasses ExecutionPolicy
    # for this script only, no system-wide policy change
    $cmdPath = [IO.Path]::ChangeExtension($PSCommandPath, '.cmd')
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        try {
            Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value @(
                '@echo off',
                'rem Launcher for the workstation installer - safe on fresh Windows.',
                'rem Bypasses ExecutionPolicy for this run only (no system change).',
                'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1"'
            )
        } catch {}
    }
}

# ─── FIXED 120x30 / 4-COLUMN LAYOUT ──────────────────────────
# Sized for the Windows Terminal default window (120 cols x 30 rows):
# menu = 19 masonry rows + 10 chrome/prompt rows = 29 <= 30.
$W      = 120
$boxW   = 116
$endCol = 119
$colX   = @(6, 34, 62, 90)   # content x-position of each layout column
$script:col = 0

# ─── GRUVBOX DARK COLOR SCHEME ────────────────────────────────
#
#   bg0    #282828  →  terminal bg (set in your profile)
#   fg     #ebdbb2  →  Gray        main readable text
#   bg3    #665c54  →  DarkGray    borders, dim, structural
#   red    #fb4934  →  Red         errors
#   green  #b8bb26  →  Green       on, success
#   yellow #fabd2f  →  Yellow      warnings, title accent
#   orange #fe8019  →  DarkYellow  numbers, warm highlights
#   blue   #83a598  →  Cyan        hotkeys
#   aqua   #8ec07c  →  DarkCyan    subtle accents
#   purple #d3869b  →  Magenta     custom markers
#   gray   #928374  →  DarkGray    off state, secondary
#
$c = @{
    Border = 'DarkGray'      # gruvbox bg3 — borders recede
    Label  = 'Gray'          # gruvbox fg — body text
    On     = 'Green'         # gruvbox green — selected
    Off    = 'DarkGray'      # gruvbox gray — deselected
    Num    = 'DarkYellow'    # gruvbox orange — numbers pop warmly
    Key    = 'Cyan'          # gruvbox blue — hotkeys stand out
    Ok     = 'Green'         # success
    Fail   = 'Red'           # gruvbox red — errors
    Warn   = 'Yellow'        # gruvbox yellow — caution
    Accent = 'DarkCyan'      # gruvbox aqua — subtle highlight
    Dim    = 'DarkGray'      # structural dim text
    Custom = 'Magenta'       # gruvbox purple — non-winget markers
    Bar    = 'DarkYellow'    # gruvbox orange — header bar bg
    BarTxt = 'Black'         # contrast on orange bar
}

# Group header colors — Gruvbox palette, no adjacent cols match
$gc = @{
    UTIL = 'Yellow'          # row 1 left
    BROW = 'Cyan'            # row 1 mid
    CLOU = 'DarkCyan'        # row 1 right
    OFCE = 'Magenta'         # row 2 left
    PDF  = 'DarkYellow'      # row 2 mid
    COMM = 'Green'           # row 2 right
    REMO = 'Cyan'            # row 3 left
    SECU = 'Red'             # row 3 mid
    MEDI = 'Yellow'          # row 3 right
    MAIN = 'Gray'            # row 4 left
    DSGN = 'Magenta'         # row 4 mid
    OTHR = 'DarkCyan'        # row 4 right
    DEV  = 'DarkYellow'      # separator section
    POST = 'Red'             # separator section
}

# ─── PACKAGES ─────────────────────────────────────────────────
$pk = @(
    # ── UTILITIES
    [pscustomobject]@{Id=1;  On=$true;  N='UniGetUI';             W='Devolutions.UniGetUI';            S='';        G='UTIL'}
    [pscustomobject]@{Id=2;  On=$true;  N='Notepad++';            W='Notepad++.Notepad++';             S='';        G='UTIL'}
    [pscustomobject]@{Id=3;  On=$true;  N='PowerToys';            W='Microsoft.PowerToys';             S='';        G='UTIL'}
    [pscustomobject]@{Id=4;  On=$true;  N='Obsidian';             W='Obsidian.Obsidian';               S='';        G='UTIL'}
    # ── OFFICE
    [pscustomobject]@{Id=5;  On=$true;  N='Microsoft Office';     W='Microsoft.Office';                S='';        G='OFCE'}
    [pscustomobject]@{Id=6;  On=$true;  N='LibreOffice';          W='TheDocumentFoundation.LibreOffice';S='';       G='OFCE'}
    # ── BROWSERS & AI
    [pscustomobject]@{Id=7;  On=$true;  N='Google Chrome';        W='Google.Chrome';                   S='';        G='BROW'}
    [pscustomobject]@{Id=8;  On=$true;  N='Perplexity';           W='XP8JNQFBQH6PVF';                 S='msstore'; G='BROW'}
    [pscustomobject]@{Id=9;  On=$true;  N='Claude Desktop';       W='Anthropic.Claude';                S='';        G='BROW'}
    # ── CLOUD STORAGE
    [pscustomobject]@{Id=10; On=$true;  N='OneDrive';             W='Microsoft.OneDrive';              S='';        G='CLOU'}
    [pscustomobject]@{Id=11; On=$true;  N='Dropbox';              W='Dropbox.Dropbox';                 S='';        G='CLOU'}
    [pscustomobject]@{Id=12; On=$true;  N='Google Drive';         W='Google.GoogleDrive';              S='';        G='CLOU'}
    # ── PDF TOOLS
    [pscustomobject]@{Id=13; On=$true;  N='Adobe Acrobat';        W='Adobe.Acrobat.Reader.64-bit';     S='';        G='PDF'}
    [pscustomobject]@{Id=14; On=$true;  N='PDFgear';              W='PDFgear.PDFgear';                 S='';        G='PDF'}
    [pscustomobject]@{Id=15; On=$true;  N='Foxit PDF Reader';     W='Foxit.FoxitReader';               S='';        G='PDF'}
    # ── COMMUNICATION
    [pscustomobject]@{Id=16; On=$true;  N='Microsoft Teams';      W='Microsoft.Teams';                 S='';        G='COMM'}
    [pscustomobject]@{Id=17; On=$true;  N='Zoom';                 W='Zoom.Zoom';                       S='';        G='COMM'}
    [pscustomobject]@{Id=18; On=$true;  N='WhatsApp Desktop';     W='9NKSQGP7F2NH';                    S='msstore'; G='COMM'}
    [pscustomobject]@{Id=19; On=$true;  N='Signal';               W='OpenWhisperSystems.Signal';       S='';        G='COMM'}
    [pscustomobject]@{Id=52; On=$true;  N='Telegram';             W='Telegram.TelegramDesktop';        S='';        G='COMM'}
    # ── REMOTE ACCESS
    [pscustomobject]@{Id=20; On=$true;  N='AnyDesk';              W='AnyDesk.AnyDesk';                 S='';        G='REMO'}
    [pscustomobject]@{Id=21; On=$true;  N='RealVNC Viewer';       W='XP99DVCPGKTXNJ';                  S='msstore'; G='REMO'}
    [pscustomobject]@{Id=50; On=$true;  N='Tailscale';            W='Tailscale.Tailscale';             S='';        G='REMO'}
    # ── SECURITY & VPN
    [pscustomobject]@{Id=22; On=$true;  N='Bitwarden';            W='Bitwarden.Bitwarden';             S='';        G='SECU'}
    [pscustomobject]@{Id=23; On=$true;  N='NordVPN';              W='NordSecurity.NordVPN';            S='';        G='SECU'}
    # ── MEDIA & CREATIVE
    [pscustomobject]@{Id=24; On=$true;  N='CapCut';               W='ByteDance.CapCut';                S='';        G='MEDI'}
    [pscustomobject]@{Id=25; On=$true;  N='VLC';                  W='VideoLAN.VLC';                    S='';        G='MEDI'}
    [pscustomobject]@{Id=26; On=$true;  N='qBittorrent';          W='qBittorrent.qBittorrent';         S='';        G='MEDI'}
    [pscustomobject]@{Id=27; On=$true;  N='OBS Studio';           W='OBSProject.OBSStudio';            S='';        G='MEDI'}
    # ── MAINTENANCE
    [pscustomobject]@{Id=28; On=$true;  N='Revo Uninstaller';     W='RevoUninstaller.RevoUninstaller'; S='';        G='MAIN'}
    [pscustomobject]@{Id=29; On=$true;  N='Adv. IP Scanner';      W='Famatech.AdvancedIPScanner';      S='';        G='MAIN'}
    # ── DESIGN
    [pscustomobject]@{Id=30; On=$true;  N='Affinity Suite';       W='Canva.Affinity';                  S='';        G='DSGN'}
    # ── OTHER
    [pscustomobject]@{Id=31; On=$true;  N='Reolink';              W='Reolink.Reolink';                 S='';        G='OTHR'}
    [pscustomobject]@{Id=32; On=$true;  N='Quick Share';          W='Google.QuickShare';               S='';        G='OTHR'}
    [pscustomobject]@{Id=33; On=$true;  N='Samsung Quick Share';  W='9PCTGDFXVZLJ';                    S='msstore'; G='OTHR'}
    # ── DEV TOOLS (off by default — Terminal & PS7 first)
    [pscustomobject]@{Id=34; On=$false; N='Windows Terminal';     W='Microsoft.WindowsTerminal';       S='';        G='DEV'}
    [pscustomobject]@{Id=35; On=$false; N='PowerShell 7';         W='Microsoft.PowerShell';            S='';        G='DEV'}
    [pscustomobject]@{Id=36; On=$false; N='VS Code';              W='Microsoft.VisualStudioCode';      S='';        G='DEV'}
    [pscustomobject]@{Id=37; On=$false; N='Git';                  W='Git.Git';                         S='';        G='DEV'}
    [pscustomobject]@{Id=38; On=$false; N='GitHub Desktop';       W='GitHub.GitHubDesktop';            S='';        G='DEV'}
    [pscustomobject]@{Id=39; On=$false; N='GitHub CLI';           W='GitHub.cli';                      S='';        G='DEV'}
    [pscustomobject]@{Id=40; On=$false; N='Node.js LTS';          W='OpenJS.NodeJS.LTS';               S='';        G='DEV'}
    [pscustomobject]@{Id=41; On=$false; N='Python 3.13';          W='Python.Python.3.13';              S='';        G='DEV'}
    [pscustomobject]@{Id=42; On=$false; N='uv (Python pkgs)';     W='astral-sh.uv';                    S='';        G='DEV'}
    [pscustomobject]@{Id=43; On=$false; N='Oh My Posh';           W='JanDeDobbeleer.OhMyPosh';         S='';        G='DEV'}
    [pscustomobject]@{Id=44; On=$false; N='PostgreSQL 18';        W='PostgreSQL.PostgreSQL.18';        S='';        G='DEV'}
    [pscustomobject]@{Id=45; On=$false; N='DBeaver';              W='DBeaver.DBeaver.Community';       S='';        G='DEV'}
    [pscustomobject]@{Id=46; On=$false; N='Claude Code CLI';      W='';                                S='custom';  G='DEV'}
    [pscustomobject]@{Id=47; On=$false; N='KiloCode CLI';         W='';                                S='custom';  G='DEV'}
    [pscustomobject]@{Id=53; On=$false; N='Cursor';               W='Anysphere.Cursor';                S='';        G='DEV'}
    [pscustomobject]@{Id=54; On=$false; N='Codex CLI';            W='OpenAI.Codex';                    S='';        G='DEV'}
    [pscustomobject]@{Id=55; On=$false; N='Antigravity IDE';      W='Google.Antigravity';              S='';        G='DEV'}
    [pscustomobject]@{Id=56; On=$false; N='Hermes Agent';         W='';                                S='custom';  G='DEV'}
    [pscustomobject]@{Id=57; On=$false; N='Antigravity CLI';      W='';                                S='custom';  G='DEV'}
    # ── POST-INSTALL (off by default, always runs last)
    [pscustomobject]@{Id=48; On=$false; N='MS Activation (MAS)';  W='';                                S='custom';  G='POST'}
    [pscustomobject]@{Id=49; On=$false; N='Chris Titus WinUtil';  W='';                                S='custom';  G='POST'}
    [pscustomobject]@{Id=51; On=$false; N='Enable RDP Host';      W='';                                S='custom';  G='POST'}
)

$grpOrder = @('UTIL','OFCE','BROW','CLOU','PDF','COMM','REMO','SECU','MEDI','MAIN','DSGN','OTHR','DEV','POST')
$gk = @{U='UTIL';A='OFCE';B='BROW';C='CLOU';P='PDF';M='COMM';R='REMO';S='SECU';E='MEDI';T='MAIN';G='DSGN';O='OTHR';D='DEV';X='POST'}
$gl = @{UTIL='UTILITIES';OFCE='OFFICE';BROW='BROWSERS & AI';CLOU='CLOUD STORAGE';PDF='PDF TOOLS';COMM='COMMUNICATION';REMO='REMOTE ACCESS';SECU='SECURITY & VPN';MEDI='MEDIA & CREATIVE';MAIN='MAINTENANCE';DSGN='DESIGN';OTHR='OTHER';DEV='DEV TOOLS';POST='POST-INSTALL'}

$script:noIcons = $true
$script:needCls = $true      # full clear on first paint / after sub-screens
$script:flash   = $null      # one-shot message shown under the prompt
$script:flashC  = $null      # optional flash color (default = Warn)
$script:lastWS  = $null      # window size last frame — resize detection
$script:failedPkgs = @()     # names of packages that failed this run
$script:healedPkgs = @()     # "Name: old → new" ID replacements this run

# Snapshot of the curated defaults — [Z] restores this selection
$script:defaults = @{}
foreach ($p in $pk) { $script:defaults[$p.Id] = $p.On }

# Group → items lookup, computed once (package list is static; the
# items are live references, so .On changes are always reflected)
$script:grpItems = @{}
foreach ($g in $grpOrder) { $script:grpItems[$g] = @($pk | Where-Object { $_.G -eq $g }) }

# ─── SELF-HEALING PACKAGE IDS ────────────────────────────────
# Two ways winget packages rot, two healing strategies:
#  1. ID vanished (publisher renames: NordVPN→NordSecurity; version
#     splits: PostgreSQL.PostgreSQL→.17; edition splits: DBeaver→
#     .Community) → search for the successor ID and retry.
#  2. ID fine but the installer download is dead (404 / hash mismatch
#     — publisher pulled the binary, manifest lags; e.g. RealVNC) →
#     retry previous versions, then the Microsoft Store channel.
# Successful heals persist to winget-id-overrides.json so future runs
# start healed. Values prefixed "msstore:" switch the source channel.
# Delete that file to reset all learned mappings.
$WG_NOT_FOUND = -1978335212   # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND

$ovrDir = if ($PSScriptRoot) { $PSScriptRoot } else { $env:LOCALAPPDATA }
$script:ovrPath = Join-Path $ovrDir 'winget-id-overrides.json'
$script:idOverrides = @{}
if (Test-Path -LiteralPath $script:ovrPath) {
    try {
        $j = Get-Content -LiteralPath $script:ovrPath -Raw | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) { $script:idOverrides[$pr.Name] = [string]$pr.Value }
    } catch {}
}
if ($script:idOverrides.Count -gt 0) {
    $healN = 0
    foreach ($p in $pk) {
        $hops = 0   # follow chains old→new→newer, cycle-guarded
        while ($p.W -and $script:idOverrides.ContainsKey($p.W) -and $hops -lt 5) {
            $nv = $script:idOverrides[$p.W]
            if ($nv -like 'msstore:*') { $p.S = 'msstore'; $p.W = $nv.Substring(8) }
            else                       { $p.W = $nv }
            $hops++
        }
        if ($hops -gt 0) { $healN++ }
    }
    if ($healN -gt 0) { $script:flash = "$healN package ID(s) auto-corrected from $(Split-Path $script:ovrPath -Leaf)"; $script:flashC = $c.Accent }
}

# ─── WRITE HELPERS ────────────────────────────────────────────

# ── Buffered frame rendering ─────────────────────────────────
# A full menu frame is ~600 tiny Write-Host calls — each one a console
# API roundtrip, which paints visibly top-to-bottom on conhost. When the
# host supports VT/ANSI (Win10+ conhost, Windows Terminal, VS Code),
# X/XNL/Pad/Bar append ANSI-colored text to a StringBuilder instead and
# the whole frame is written in ONE console call. Hosts without VT
# (e.g. ISE) automatically keep the per-call path.
$script:vt    = $false
try { $script:vt = [bool]$Host.UI.SupportsVirtualTerminal } catch {}
$script:fb    = New-Object System.Text.StringBuilder 16384
$script:bufOn = $false
$ESC   = [char]27
$ansiF = @{ Black=30; DarkBlue=34; DarkGreen=32; DarkCyan=36; DarkRed=31; DarkMagenta=35; DarkYellow=33; Gray=37
            DarkGray=90; Blue=94; Green=92; Cyan=96; Red=91; Magenta=95; Yellow=93; White=97 }
$ansiB = @{ Black=40; DarkBlue=44; DarkGreen=42; DarkCyan=46; DarkRed=41; DarkMagenta=45; DarkYellow=43; Gray=47
            DarkGray=100; Blue=104; Green=102; Cyan=106; Red=101; Magenta=105; Yellow=103; White=107 }
function BufStart { if ($script:vt) { $script:bufOn = $true; $null = $script:fb.Clear() } }
function BufFlush {
    if ($script:bufOn) {
        $script:bufOn = $false
        $null = $script:fb.Append("$ESC[0m")
        [Console]::Write($script:fb.ToString())
    }
}

function X {
    param([string]$T,[string]$F='Gray')
    if ($script:bufOn) { $null = $script:fb.Append("$ESC[$($ansiF[$F])m").Append($T) }
    else { Write-Host $T -ForegroundColor $F -NoNewline }
    $script:col += $T.Length
}
function XNL {
    param([string]$T='',[string]$F='Gray')
    if ($script:bufOn) { if ($T) { $null = $script:fb.Append("$ESC[$($ansiF[$F])m").Append($T) }; $null = $script:fb.Append("`r`n") }
    else { if($T){Write-Host $T -ForegroundColor $F}else{Write-Host ''} }
    $script:col = 0
}
function Pad {
    param([int]$To)
    $n = $To - $script:col
    if ($n -gt 0) {
        if ($script:bufOn) { $null = $script:fb.Append(' ' * $n) } else { Write-Host (' '*$n) -NoNewline }
        $script:col += $n
    }
}

# Console width (falls back to layout width when unavailable)
function ConW { $bw = 0; try { $bw = [Console]::BufferWidth } catch {}; if ($bw -lt 20) { $bw = $W }; return $bw }
# Overwrite the current row in place (transient status — cursor stays on the row)
function WTemp { param([string]$T,[string]$F='Gray'); $w=(ConW)-1; if($T.Length -gt $w){$T=$T.Substring(0,$w)}; Write-Host ("`r"+$T.PadRight($w)) -NoNewline -ForegroundColor $F }
# Overwrite the current row with a final line (clears residue, moves to next row)
function WLine { param([string]$T,[string]$F='Gray'); $w=(ConW)-1; if($T.Length -gt $w){$T=$T.Substring(0,$w)}; Write-Host ("`r"+$T.PadRight($w)) -ForegroundColor $F }
function FmtDur { param([TimeSpan]$T) if ($T.TotalMinutes -ge 1) { '{0}m {1:00}s' -f [Math]::Floor($T.TotalMinutes), $T.Seconds } else { '{0:0.0}s' -f $T.TotalSeconds } }

function Bar {
    param([string]$T='',[string]$Bg=$c.Bar,[string]$Fg=$c.BarTxt)
    $p=$W-$T.Length; $l=[Math]::Floor($p/2); $r=$p-$l; $s=(' '*$l)+$T+(' '*$r)
    if ($script:bufOn) { $null = $script:fb.Append("$ESC[$($ansiF[$Fg]);$($ansiB[$Bg])m").Append($s).Append("$ESC[0m`r`n") }
    else { Write-Host $s -ForegroundColor $Fg -BackgroundColor $Bg }
    $script:col=0
}
function BTop  { X '  '; X "╔$('═'*$boxW)╗" $c.Border; XNL }
function BBot  { X '  '; X "╚$('═'*$boxW)╝" $c.Border; XNL }
function BMid  { X '  '; X "╠$('═'*$boxW)╣" $c.Border; XNL }
function BBlk  { X '  '; X '║' $c.Border; Pad $endCol; X '║' $c.Border; XNL }
function RS    { X '  '; X '║' $c.Border; X '   ' }
function RE    { Pad $endCol; X '║' $c.Border; XNL }

# ─── CHECKBOX / GROUP TAG ────────────────────────────────────

function CB {
    param([pscustomobject]$P)
    X ($P.Id.ToString().PadLeft(2)) $c.Num; X '. ' $c.Dim
    if ($P.On) { X '[' $c.Dim; X '■' $c.On; X '] ' $c.Dim }
    else       { X '[ ] ' $c.Off }
    $nc = if ($P.On) { $c.Label } else { $c.Off }
    X $P.N $nc
    if ($P.S -eq 'custom') { X ' *' $c.Custom }
}

function GT {
    param([string]$K,[string]$Grp)
    X '(' $c.Dim; X $K $c.Key; X ') ' $c.Dim; X $gl[$Grp] ($gc[$Grp])
    # live selected/total count — partial selections show in Warn
    $gi = $script:grpItems[$Grp]; $gOn = @($gi | Where-Object On).Count
    $cc = if ($gOn -eq 0) { $c.Off } elseif ($gOn -eq $gi.Count) { $c.On } else { $c.Warn }
    X " $gOn/$($gi.Count)" $cc
}

# ─── MASONRY LAYOUT ──────────────────────────────────────────
# Groups are packed into 3 columns by height (first-fit-decreasing),
# DEV+POST pinned to column 3 as a sidebar. No row alignment between
# groups = no wasted lines. Computed once (package list is static).

$gkRev = @{}; foreach ($e in $gk.GetEnumerator()) { $gkRev[$e.Value] = $e.Key }

function Build-Masonry {
    # 4 columns: DEV (the tallest group) is pinned to column 4 as a
    # sidebar; the app groups pack into columns 1-3 by height
    # (first-fit-decreasing); POST lands at the bottom of the shortest
    # app column — its red header + "(last)" tag keep it distinct.
    $NewBlock = { param($g)
        $items = @($pk | Where-Object { $_.G -eq $g } | Sort-Object Id)
        [pscustomobject]@{ G = $g; H = $items.Count + 1; Items = $items; Ord = $grpOrder.IndexOf($g) }
    }
    $appGroups = @($grpOrder | Where-Object { $_ -notin @('DEV','POST') })
    $blocks    = foreach ($g in $appGroups) { & $NewBlock $g }

    # First-fit-decreasing across columns 1-3 (earliest shortest wins)
    $colH = @(0, 0, 0)
    $colBlocks = @(@(), @(), @())
    foreach ($b in ($blocks | Sort-Object H -Descending)) {
        $ci = 0
        for ($k = 1; $k -lt 3; $k++) { if ($colH[$k] -lt $colH[$ci]) { $ci = $k } }
        $colBlocks[$ci] += $b
        $colH[$ci] += $b.H
    }

    # POST → shortest app column (Ord is max, so it sorts to the bottom)
    $post = & $NewBlock 'POST'
    $ci = 0
    for ($k = 1; $k -lt 3; $k++) { if ($colH[$k] -lt $colH[$ci]) { $ci = $k } }
    $colBlocks[$ci] += $post

    # Column 4 = DEV sidebar
    $dev = & $NewBlock 'DEV'

    # Flatten each column to cells, restoring grpOrder within the column
    $cols = @()
    foreach ($cb in @(($colBlocks[0] | Sort-Object Ord), ($colBlocks[1] | Sort-Object Ord), ($colBlocks[2] | Sort-Object Ord), @($dev))) {
        $cells = @()
        foreach ($b in $cb) {
            $cells += , @{ T = 'hdr'; G = $b.G }
            foreach ($it in $b.Items) { $cells += , @{ T = 'pkg'; P = $it } }
        }
        $cols += , $cells
    }
    return $cols
}

$script:masonry = Build-Masonry

function MasonryRows {
    $cols = $script:masonry
    $rows = ($cols | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $rows; $i++) {
        RS
        for ($ci = 0; $ci -lt $cols.Count; $ci++) {
            if ($ci -gt 0) { Pad $colX[$ci] }
            $cells = $cols[$ci]
            if ($i -lt $cells.Count) {
                $cell = $cells[$i]
                if ($cell.T -eq 'hdr') {
                    GT $gkRev[$cell.G] $cell.G
                    if ($cell.G -eq 'POST') { X ' (last)' $c.Dim }
                } else {
                    CB $cell.P
                }
            }
        }
        RE
    }
}

# ─── MENU ─────────────────────────────────────────────────────

function Show-Menu {
    # Force a full clear if the window was resized since the last frame
    try {
        $wsNow = $Host.UI.RawUI.WindowSize
        if ($script:lastWS -and (($wsNow.Width -ne $script:lastWS.Width) -or ($wsNow.Height -ne $script:lastWS.Height))) { $script:needCls = $true }
        $script:lastWS = $wsNow
    } catch {}
    if ($script:needCls) { Clear-Host; $script:needCls = $false }
    else { try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host } }
    try { [Console]::CursorVisible = $false } catch {}
    BufStart
    $sel = @($pk | Where-Object On).Count; $tot = $pk.Count

    Bar -T 'W O R K S T A T I O N   I N S T A L L E R'

    BTop
    RS
    X '1 5 20-27' $c.Num; X ' = toggle' $c.Label
    X '   ' $c.Dim
    X 'letter' $c.Key; X ' = group' $c.Label
    X '   ' $c.Dim
    X 'mix freely: ' $c.Label; X '3 d 8-11' $c.Num
    X '   ' $c.Dim
    X '* ' $c.Custom; X '= non-winget' $c.Label
    RE
    BMid

    MasonryRows

    BMid

    RS
    X '[' $c.Dim; X '*' $c.Key; X '] All ON' $c.Label; X '  '
    X '[' $c.Dim; X '0' $c.Key; X '] All OFF' $c.Label; X '  '
    X '[' $c.Dim; X 'Z' $c.Key; X '] Reset' $c.Label; X '  '
    X '[' $c.Dim; X 'I' $c.On; X '] INSTALL' $c.On; X '  '
    X '[' $c.Dim; X 'Q' $c.Fail; X '] Quit' $c.Label; X '  '
    X '[' $c.Dim; X 'N' $c.Key; X '] Icons: ' $c.Label
    if ($script:noIcons) { X 'DELETE' $c.Warn } else { X 'KEEP' $c.Ok }
    X '  '
    X "$sel/$tot selected" $(if($sel -gt 0){$c.On}else{$c.Off})
    RE
    BBot

    BufFlush   # frame lands in one console write

    # Wipe the prompt + message rows (stale input/messages from last frame),
    # show any one-shot flash, then park the cursor back at the prompt row.
    $py = [Console]::CursorTop
    Write-Host (' ' * ($W - 1))
    if ($script:flash) {
        $fc = if ($script:flashC) { $script:flashC } else { $c.Warn }
        Write-Host ("  $($script:flash)".PadRight($W - 1)) -ForegroundColor $fc
        $script:flash = $null; $script:flashC = $null
    } else {
        Write-Host (' ' * ($W - 1))
    }
    try { [Console]::SetCursorPosition(0, $py) } catch {}
    try { [Console]::CursorVisible = $true } catch {}
}

# ─── CONFIRM ──────────────────────────────────────────────────

function Show-Confirm {
    Clear-Host
    BufStart
    $sel = @($pk | Where-Object On | Sort-Object { $grpOrder.IndexOf($_.G) }, Id)

    Bar -T "C O N F I R M   |   $($sel.Count) packages"

    BTop; BBlk

    $curG=''; $buf=@()

    foreach ($p in $sel) {
        if ($p.G -ne $curG) {
            if ($buf.Count -gt 0) { FlushBuf $buf; $buf=@() }
            if ($p -ne $sel[0]) { BBlk }
            $curG = $p.G
            RS; X $gl[$curG] ($gc[$curG])
            if ($curG -eq 'POST') { X '  (runs last)' $c.Dim }
            RE
        }
        $buf += $p
        if ($buf.Count -eq 4) { FlushBuf $buf; $buf=@() }
    }
    if ($buf.Count -gt 0) { FlushBuf $buf }

    BBlk
    RS
    X 'Desktop icons: ' $c.Label
    if ($script:noIcons) { X 'DELETE new shortcuts after install (default)' $c.Warn } else { X 'KEEP all shortcuts' $c.Ok }
    RE
    $postSel = @($sel | Where-Object { $_.G -eq 'POST' })
    if ($postSel.Count -gt 0) {
        RS
        X '!  ' $c.Fail; X 'POST-INSTALL modifies Windows: ' $c.Warn
        X (($postSel | ForEach-Object { $_.N }) -join ', ') $c.Label
        RE
    }
    BBlk; BBot; BufFlush; Write-Host ''
}

function FlushBuf {
    param([array]$Items)
    RS
    for ($k = 0; $k -lt [Math]::Min($Items.Count, 4); $k++) {
        if ($k -eq 0) { X '  > ' $c.On } else { Pad $colX[$k]; X '> ' $c.On }
        X $Items[$k].N $c.Label
        if ($Items[$k].S -eq 'custom') { X ' *' $c.Custom }
    }
    RE
}

# ─── INSTALL ──────────────────────────────────────────────────

function RunCustom {
    param([string]$Label, [string]$Url)
    Write-Host "         $Label" -ForegroundColor $c.Dim
    try {
        $sc = Invoke-RestMethod -Uri $Url -ErrorAction Stop
        Invoke-Expression $sc
        return $(if($?){0}else{1})
    } catch { return 1 }
}

function Get-PkgInfo {
    param([string]$WId, [string]$Src)
    if (-not $WId) { return $null }
    $la = @('list','--id',$WId,'--exact','--disable-interactivity','--accept-source-agreements')
    if ($Src -eq 'msstore') { $la += @('--source','msstore') }
    try {
        $raw = @(& winget @la 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch { return $null }
    # Find separator line of dashes
    $sep = -1
    for ($j=0; $j -lt $raw.Count; $j++) {
        if ($raw[$j] -match '^-{4,}') { $sep = $j; break }
    }
    if ($sep -lt 1 -or ($sep+1) -ge $raw.Count) { return $null }
    $hdr = $raw[$sep-1]; $dl = $raw[$sep+1]
    $vi = $hdr.IndexOf('Version');   if ($vi -lt 0) { return $null }
    $ai = $hdr.IndexOf('Available'); $si = $hdr.IndexOf('Source')
    if ($si -lt 0) { $si = $hdr.Length }
    # Installed version
    $vEnd = if ($ai -gt 0) { $ai } else { $si }
    $ver = if ($dl.Length -gt $vi) { $dl.Substring($vi, [Math]::Min($vEnd-$vi, $dl.Length-$vi)).Trim() } else { $null }
    # Available version (upgrade column)
    $avl = $null
    if ($ai -gt 0 -and $dl.Length -gt $ai) {
        $avl = $dl.Substring($ai, [Math]::Min($si-$ai, $dl.Length-$ai)).Trim()
        if (-not $avl) { $avl = $null }
    }
    return @{ Ver = $ver; Avl = $avl }
}

# ─── SELF-HEAL HELPERS ───────────────────────────────────────

function Save-IdOverride {
    param([string]$Old, [string]$New)
    $script:idOverrides[$Old] = $New
    try {
        $o = [ordered]@{}
        foreach ($k in ($script:idOverrides.Keys | Sort-Object)) { $o[$k] = $script:idOverrides[$k] }
        $o | ConvertTo-Json | Set-Content -LiteralPath $script:ovrPath -Encoding UTF8
    } catch {}
}

function Get-WingetRows {
    # Parse an aligned winget table (Name | Id | Version ...) → Name/Id pairs
    param([string[]]$Raw)
    $sep = -1
    for ($j = 0; $j -lt $Raw.Count; $j++) { if ($Raw[$j] -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 1) { return @() }
    $hdr = $Raw[$sep-1]
    $iId = $hdr.IndexOf('Id'); $iVer = $hdr.IndexOf('Version')
    if ($iId -lt 1 -or $iVer -le $iId) { return @() }
    $rows = @()
    for ($j = $sep+1; $j -lt $Raw.Count; $j++) {
        $ln = "$($Raw[$j])"
        if ($ln.Length -le $iId -or -not $ln.Trim()) { continue }
        $id = $ln.Substring($iId, [Math]::Min($iVer-$iId, $ln.Length-$iId)).Trim()
        if ($id) { $rows += [pscustomobject]@{ Name = $ln.Substring(0, $iId).Trim(); Id = $id } }
    }
    return $rows
}

function Find-ReplacementId {
    # Heal 1: a package ID vanished from the source — search for its
    # successor. Scores candidates on: old-ID prefix (edition/version
    # split), same tail segment (publisher rename), display-name match.
    # Penalizes pre-release channels. Returns the best-scoring ID, or $null.
    param([pscustomobject]$P)
    $oldId   = $P.W
    $oldBase = $oldId -replace '\.\d+$',''      # PostgreSQL.PostgreSQL.17 → PostgreSQL.PostgreSQL
    $oldTail = ($oldBase -split '\.')[-1]       # NordVPN.NordVPN → NordVPN

    # Store product codes have no dot structure — search by name only
    $queries = if ($P.S -eq 'msstore') { @($P.N) } else { @(@($oldTail, $P.N) | Select-Object -Unique) }

    $best = $null; $bestScore = 0
    foreach ($q in $queries) {
        $sa = @('search', $q, '--disable-interactivity', '--accept-source-agreements')
        if ($P.S -eq 'msstore') { $sa += @('--source','msstore') } else { $sa += @('--source','winget') }
        try { $raw = @(& winget @sa 2>$null) } catch { continue }
        if ($LASTEXITCODE -ne 0) { continue }

        foreach ($row in (Get-WingetRows -Raw $raw)) {
            $name = $row.Name; $id = $row.Id
            if ($id -eq $oldId) { continue }

            $s = 0
            if     ($id -like "$oldId.*")                            { $s += 6 }  # edition/version suffix added
            elseif ($oldBase -ne $oldId -and $id -like "$oldBase.*") { $s += 6 }  # version suffix changed
            if (($id -split '\.')[-1] -eq $oldTail)                  { $s += 4 }  # publisher renamed
            if     ($name -eq $P.N)                                  { $s += 3 }  # exact display name
            elseif ($name -like "$($P.N)*" -or $P.N -like "$name*")  { $s += 1 }
            if ($id -match '(?i)pre-?release|beta|nightly|canary|preview|insider') { $s -= 3 }

            if ($s -gt $bestScore) { $bestScore = $s; $best = $id }
            elseif ($s -eq $bestScore -and $best -and $s -gt 0) {
                # tie-break: prefer the higher trailing version number (.17 vs .18)
                $a = [regex]::Match($id,   '\.(\d+)$').Groups[1].Value
                $b = [regex]::Match($best, '\.(\d+)$').Groups[1].Value
                if ($a -and $b -and [int]$a -gt [int]$b) { $best = $id }
            }
        }
        if ($bestScore -ge 4) { break }   # confident hit — skip remaining queries
    }
    if ($bestScore -ge 3) { return $best }
    return $null
}

function Test-DlFail {
    # Heal 2 trigger: manifest resolved but the installer download is
    # dead — publisher pulled/replaced the binary and the manifest lags.
    param($Out)
    $rx = '0x80190194|\(404\)|0x8A150011|hash\s+.*mismatch|installer\s+hash'
    foreach ($o in $Out) { if ("$o" -match $rx) { return $true } }
    return $false
}

function Get-PkgVersions {
    # Available catalog versions, newest first (winget's listing order)
    param([string]$WId, [string]$Src)
    $va = @('show','--id',$WId,'--exact','--versions','--disable-interactivity','--accept-source-agreements')
    if ($Src -eq 'msstore') { $va += @('--source','msstore') }
    try { $raw = @(& winget @va 2>$null) } catch { return @() }
    if ($LASTEXITCODE -ne 0) { return @() }
    $sep = -1
    for ($j = 0; $j -lt $raw.Count; $j++) { if ($raw[$j] -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 0 -or ($sep+1) -ge $raw.Count) { return @() }
    return @($raw[($sep+1)..($raw.Count-1)] | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -ne 'Unknown' })
}

function Find-StoreFallback {
    # Heal 2b: the same app published in the Microsoft Store — its CDN
    # is independent of the publisher's. Match by display name.
    param([pscustomobject]$P)
    $sa = @('search', $P.N, '--source','msstore','--disable-interactivity','--accept-source-agreements')
    try { $raw = @(& winget @sa 2>$null) } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($row in (Get-WingetRows -Raw $raw)) {
        if ($row.Name -eq $P.N -or $row.Name -like "*$($P.N)*" -or $P.N -like "*$($row.Name)*") { return $row.Id }
    }
    return $null
}

# ─── JOB / SPINNER HELPERS ───────────────────────────────────

function Invoke-JobSpinner {
    # Run $Work in a background job with an in-place spinner on $Line.
    # $Work must end by emitting $LASTEXITCODE. Returns @{ Ec; Out }.
    # Leaves the cursor ON the spinner row — print the result with WLine
    # so it overwrites the spinner (one line per package, no residue).
    param([scriptblock]$Work, $Arg = $null, [string]$Line, [string]$Msg = 'installing...')
    $spin = @('|','/','-','\')
    $job = Start-Job -ScriptBlock $Work -ArgumentList (,$Arg)
    $si = 0
    while ($job.State -in 'NotStarted','Running') {
        WTemp "$Line  $($spin[$si % $spin.Count]) $Msg" $c.Warn
        $si++; Start-Sleep -Milliseconds 150
    }
    $null = Wait-Job $job -ErrorAction SilentlyContinue
    $out = @(Receive-Job $job -ErrorAction SilentlyContinue); Remove-Job $job -Force
    # Last int in the stream is the exit code; none at all = job never ran
    $ec = $out | Where-Object { $_ -is [int] } | Select-Object -Last 1
    if ($null -eq $ec) { $ec = 1 }
    return @{ Ec = [int]$ec; Out = $out }
}

function Invoke-WingetInstall {
    param([pscustomobject]$P, [string]$Line, [string]$Version = '')
    $wA = @('install','--id',$P.W,'--exact','--silent','--accept-package-agreements','--accept-source-agreements')
    if ($Version)           { $wA += @('--version',$Version) }
    if ($P.S -eq 'msstore') { $wA += @('--source','msstore') }
    Invoke-JobSpinner -Work { param($a) & winget @a 2>&1; $LASTEXITCODE } -Arg $wA -Line $Line
}

function Inst {
    param([pscustomobject]$P,[int]$Idx,[int]$Tot,[ref]$Ok,[ref]$Fl)

    $mtd = 'winget'
    if ($P.S -eq 'msstore') { $mtd = 'msstore' }
    if ($P.S -eq 'custom')  { $mtd = 'custom' }

    $psw  = [System.Diagnostics.Stopwatch]::StartNew()
    $pct  = [Math]::Round($Idx / $Tot * 100)
    $tag  = ('[{0}/{1} {2}%]' -f $Idx, $Tot, $pct).PadRight(13)
    $nd   = $P.N.PadRight(24)
    $line = "  $tag $nd [$mtd]"

    try {
        if ($P.S -eq 'custom') {
            switch ($P.Id) {
                46 { # Claude Code CLI
                    Write-Host "$line  downloading..." -ForegroundColor $c.Warn
                    $ec = RunCustom 'irm https://claude.ai/install.ps1 | iex' 'https://claude.ai/install.ps1'
                }
                47 { # KiloCode CLI (npm)
                    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
                        Write-Host "$line  npm not found — install Node.js LTS first, then re-run from a new terminal" -ForegroundColor $c.Fail
                        $ec = 1
                    } else {
                        $r = Invoke-JobSpinner -Work { npm install -g '@kilocode/cli' 2>&1; $LASTEXITCODE } -Line $line
                        $ec = $r.Ec
                    }
                }
                56 { # Hermes Agent (Nous Research — official installer; needs Git)
                    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                        Write-Host "$line  git not found — install Git first (the Hermes installer requires it)" -ForegroundColor $c.Fail
                        $ec = 1
                    } else {
                        Write-Host "$line  downloading..." -ForegroundColor $c.Warn
                        $ec = RunCustom 'irm https://hermes-agent.nousresearch.com/install.ps1 | iex' 'https://hermes-agent.nousresearch.com/install.ps1'
                    }
                }
                57 { # Antigravity CLI (Google — official installer)
                    Write-Host "$line  downloading..." -ForegroundColor $c.Warn
                    $ec = RunCustom 'irm https://antigravity.google/cli/install.ps1 | iex' 'https://antigravity.google/cli/install.ps1'
                }
                48 { # MS Activation (MAS)
                    Write-Host "$line  launching..." -ForegroundColor $c.Warn
                    $ec = RunCustom 'irm https://get.activated.win | iex' 'https://get.activated.win'
                }
                49 { # Chris Titus WinUtil
                    Write-Host "$line  launching..." -ForegroundColor $c.Warn
                    $ec = RunCustom 'irm https://christitus.com/win | iex' 'https://christitus.com/win'
                }
                51 { # Enable RDP Host (registry + NLA + firewall — needs admin)
                    Write-Host "$line  enabling RDP host..." -ForegroundColor $c.Warn
                    $rdpCmd = @'
$ErrorActionPreference = 'Stop'
try {
    # Allow incoming RDP connections
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    # Require Network Level Authentication
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1
    # Open the built-in Remote Desktop firewall rules
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    # If Tailscale is installed, also restrict RDP to the tailnet (CGNAT range)
    # — uncomment the next line to lock RDP to Tailscale-only access:
    # Set-NetFirewallRule -DisplayGroup 'Remote Desktop' -RemoteAddress 100.64.0.0/10
    exit 0
} catch { exit 1 }
'@
                    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                    if ($isAdmin) {
                        $tmp = Join-Path $env:TEMP 'enable-rdp.ps1'
                        Set-Content -Path $tmp -Value $rdpCmd -Encoding UTF8
                        & powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
                        $ec = $LASTEXITCODE
                        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                    } else {
                        Write-Host "         not elevated — requesting admin (UAC prompt)..." -ForegroundColor $c.Dim
                        $tmp = Join-Path $env:TEMP 'enable-rdp.ps1'
                        Set-Content -Path $tmp -Value $rdpCmd -Encoding UTF8
                        try {
                            $proc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$tmp -Verb RunAs -Wait -PassThru
                            $ec = $proc.ExitCode
                        } catch { $ec = 1 }   # UAC declined or failed
                        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                    }
                    if ($ec -eq 0) {
                        $tsIp = $null
                        $tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
                        if (Test-Path $tsExe) { $tsIp = (& $tsExe ip -4 2>$null | Select-Object -First 1) }
                        if ($tsIp) { Write-Host "         RDP enabled (NLA on). Tailscale IP: $tsIp" -ForegroundColor $c.Accent }
                        else       { Write-Host "         RDP enabled (NLA on)." -ForegroundColor $c.Accent }
                    }
                }
            }
            if ($ec -eq 0) {
                WLine "$line  OK  ($(FmtDur $psw.Elapsed))" $c.Ok
                $P.On = $false   # done — deselect so [I] won't re-run it
                $Ok.Value++
            } else {
                WLine "$line  FAILED  ($(FmtDur $psw.Elapsed))" $c.Fail
                $script:failedPkgs += $P.N
                $Fl.Value++
            }
        }
        else {
            # Pre-check: current installed version (transient status line)
            WTemp "$line  checking..." $c.Dim
            $pre = Get-PkgInfo -WId $P.W -Src $P.S
            $r   = Invoke-WingetInstall -P $P -Line $line
            $ec  = $r.Ec; $out = $r.Out

            # ── Self-heal: ID vanished from the source (rename / re-publish) ──
            if ($ec -eq $WG_NOT_FOUND) {
                WLine "$line  ID not in source — searching for its successor..." $c.Dim
                $newId = Find-ReplacementId -P $P
                if ($newId) {
                    WLine "         ↻ healed: $($P.W) → $newId" $c.Accent
                    Save-IdOverride -Old $P.W -New $newId
                    $script:healedPkgs += "$($P.N): $($P.W) → $newId"
                    $P.W = $newId
                    WTemp "$line  checking..." $c.Dim
                    $pre = Get-PkgInfo -WId $P.W -Src $P.S
                    $r   = Invoke-WingetInstall -P $P -Line $line
                    $ec  = $r.Ec; $out = $r.Out
                } else {
                    WTemp "$line  no successor found" $c.Dim
                }
            }

            # ── Self-heal 2: entry OK but the installer download is dead ──
            # (404 / hash mismatch — publisher pulled the binary). Try up to
            # two previous versions, then the Microsoft Store channel.
            if ($ec -ne 0 -and -not $pre -and (Test-DlFail $out)) {
                foreach ($v in @(Get-PkgVersions -WId $P.W -Src $P.S | Select-Object -Skip 1 -First 2)) {
                    WLine "$line  latest download broken — trying v$v..." $c.Dim
                    $r = Invoke-WingetInstall -P $P -Line $line -Version $v
                    if ($r.Ec -eq 0) {
                        $ec = 0; $out = $r.Out
                        $script:healedPkgs += "$($P.N): pinned v$v (latest installer download broken)"
                        break
                    }
                }
                if ($ec -ne 0 -and $P.S -ne 'msstore') {
                    $sid = Find-StoreFallback -P $P
                    if ($sid) {
                        WLine "$line  trying Microsoft Store channel ($sid)..." $c.Dim
                        $sp = [pscustomobject]@{ Id=$P.Id; On=$P.On; N=$P.N; W=$sid; S='msstore'; G=$P.G }
                        $r = Invoke-WingetInstall -P $sp -Line $line
                        if ($r.Ec -eq 0) {
                            $ec = 0; $out = $r.Out
                            Save-IdOverride -Old $P.W -New "msstore:$sid"
                            $script:healedPkgs += "$($P.N): $($P.W) → msstore:$sid (winget installer broken)"
                            $P.W = $sid; $P.S = 'msstore'
                        }
                    }
                }
            }

            if ($ec -eq 0 -and -not $pre) {
                # Fresh install
                WTemp "$line  verifying..." $c.Dim
                $post = Get-PkgInfo -WId $P.W -Src $P.S
                $vt = if ($post -and $post.Ver) { "v$($post.Ver)" } else { '' }
                WLine "$line  INSTALLED $vt  ($(FmtDur $psw.Elapsed))" $c.Ok
                $P.On = $false   # done — deselect so [I] won't re-run it
                $Ok.Value++
            }
            elseif ($ec -eq 0 -and $pre) {
                # Updated
                WTemp "$line  verifying..." $c.Dim
                $post = Get-PkgInfo -WId $P.W -Src $P.S
                $nv = if ($post -and $post.Ver) { $post.Ver } elseif ($pre.Avl) { $pre.Avl } else { '?' }
                WLine "$line  UPDATED v$($pre.Ver) → v$nv  ($(FmtDur $psw.Elapsed))" $c.Ok
                $P.On = $false
                $Ok.Value++
            }
            elseif ($ec -ne 0 -and $pre) {
                # Already installed, no update available
                WLine "$line  v$($pre.Ver) — up to date  ($(FmtDur $psw.Elapsed))" $c.Accent
                $P.On = $false
                $Ok.Value++
            }
            else {
                # Genuine failure — surface the last meaningful winget line
                WLine "$line  FAILED  ($(FmtDur $psw.Elapsed))" $c.Fail
                $reason = $out |
                    Where-Object { $_ -is [string] -and $_.Trim() -and $_ -match '[A-Za-z]' -and $_ -notmatch '^\s*[\\|/\-█▒░]+\s*$' } |
                    Select-Object -Last 1
                if ($reason) {
                    $rt = $reason.ToString().Trim()
                    if ($rt.Length -gt 106) { $rt = $rt.Substring(0,103) + '...' }
                    Write-Host "         → $rt" -ForegroundColor $c.Dim
                }
                $script:failedPkgs += $P.N
                $Fl.Value++
            }
        }
    }
    catch {
        WLine "$line  ERROR: $($_.Exception.Message)" $c.Fail
        $script:failedPkgs += $P.N
        $Fl.Value++
    }
}

function Run-Install {
    $sel = @($pk | Where-Object On | Sort-Object { $grpOrder.IndexOf($_.G) }, Id)
    if ($sel.Count -eq 0) { return }

    Clear-Host
    Bar -T "I N S T A L L I N G   |   $($sel.Count) packages" -Bg 'DarkGreen' -Fg 'Black'

    # Full-session log for post-mortem on failures
    $script:failedPkgs = @()
    $script:healedPkgs = @()
    $logPath = Join-Path $env:TEMP ("workstation-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    try { Start-Transcript -Path $logPath -ErrorAction Stop | Out-Null; $logOk = $true } catch { $logOk = $false }

    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ''
    $null = Invoke-JobSpinner -Work { $null = winget source update 2>&1; 0 } -Line '  Updating winget sources' -Msg 'updating...'
    WLine '  Winget sources updated.' $c.Ok
    Write-Host "  $('─'*($W-4))" -ForegroundColor $c.Dim

    [int]$okC=0; [int]$flC=0
    $postStarted = $false

    # Snapshot desktop shortcuts before installing
    $deskSnap = @()
    if ($script:noIcons) {
        $deskPaths = @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop")
        foreach ($dp in $deskPaths) {
            if (Test-Path $dp) {
                $deskSnap += @(Get-ChildItem -Path $dp -Filter '*.lnk' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
            }
        }
    }

    for ($i=0; $i -lt $sel.Count; $i++) {
        if ($sel[$i].G -eq 'POST' -and -not $postStarted) {
            $postStarted = $true
            Write-Host ''
            Write-Host "  $('═'*($W-4))" -ForegroundColor $c.Border
            Write-Host '  POST-INSTALL SCRIPTS  (all other packages done)' -ForegroundColor $c.Warn
            Write-Host "  $('─'*($W-4))" -ForegroundColor $c.Border
        }
        Inst -P $sel[$i] -Idx ($i+1) -Tot $sel.Count -Ok ([ref]$okC) -Fl ([ref]$flC)
    }

    $bLen=70; $pOk=if($sel.Count -gt 0){[Math]::Round($okC/$sel.Count*100)}else{0}
    $filled=[Math]::Floor($bLen*$okC/[Math]::Max($sel.Count,1)); $empty=$bLen-$filled

    # Sweep new desktop shortcuts
    if ($script:noIcons) {
        $deskPaths = @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop")
        $newIcons = @()
        foreach ($dp in $deskPaths) {
            if (Test-Path $dp) {
                $newIcons += @(Get-ChildItem -Path $dp -Filter '*.lnk' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notin $deskSnap } |
                    Select-Object -ExpandProperty FullName)
            }
        }
        if ($newIcons.Count -gt 0) {
            Write-Host ''
            Write-Host "  $('─'*($W-4))" -ForegroundColor $c.Dim
            Write-Host "  Cleaning $($newIcons.Count) new desktop shortcut(s)..." -ForegroundColor $c.Warn
            foreach ($ic in $newIcons) {
                Remove-Item -Path $ic -Force -ErrorAction SilentlyContinue
                Write-Host "    Removed: $(Split-Path $ic -Leaf)" -ForegroundColor $c.Dim
            }
        }
    }

    Write-Host ''; Write-Host "  $('═'*($W-4))" -ForegroundColor $c.Border; Write-Host ''
    Bar -T 'C O M P L E T E'
    Write-Host ''
    $script:col=0
    X '  '; X ('█'*$filled) $c.Ok; X ('░'*$empty) $c.Dim; X "  $pOk% success" $c.Ok; XNL
    Write-Host ''
    $script:col=0
    X '  Installed: ' $c.Label; X "$okC" $c.Ok; X '   |   Failed: ' $c.Label; X "$flC" $c.Fail; X '   |   Time: ' $c.Label; X (FmtDur $swTotal.Elapsed) $c.Accent; XNL
    if ($script:failedPkgs.Count -gt 0) {
        Write-Host ''
        Write-Host '  Failed packages:' -ForegroundColor $c.Fail
        foreach ($fp in $script:failedPkgs) { Write-Host "    ✗ $fp" -ForegroundColor $c.Fail }
    }
    if ($script:healedPkgs.Count -gt 0) {
        Write-Host ''
        Write-Host '  Self-healed package IDs (saved for future runs):' -ForegroundColor $c.Accent
        foreach ($hp in $script:healedPkgs) { Write-Host "    ↻ $hp" -ForegroundColor $c.Accent }
    }
    if ($logOk) {
        try { Stop-Transcript | Out-Null } catch {}
        Write-Host ''
        Write-Host "  Full log: $logPath" -ForegroundColor $c.Dim
    }
    # Menu flash for the return: failures stay selected for one-key retry
    if ($flC -gt 0) { $script:flash = "$flC package(s) failed — still selected, press I to retry"; $script:flashC = $c.Fail }
    else            { $script:flash = 'All done — installed packages were deselected.';           $script:flashC = $c.Ok }

    Write-Host ''
    Write-Host '  Press any key...' -ForegroundColor $c.Dim
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ─── WINGET CHECK ─────────────────────────────────────────────

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  Winget (App Installer) not found — it is required for installs.' -ForegroundColor $c.Fail
    Write-Host '  Opening its Microsoft Store page — install it, then run this script again.' -ForegroundColor $c.Label
    try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' }
    catch { Write-Host '  Get it manually: https://aka.ms/getwinget' -ForegroundColor $c.Label }
    Write-Host ''
    Write-Host '  Press any key to exit...' -ForegroundColor $c.Dim
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# ─── WINDOW SIZE GUARD ────────────────────────────────────────
# Menu height = chrome (8) + tallest masonry column + prompt/flash (2).
# Width matters even more: below $W columns every row wraps and the
# box layout shatters — grow buffer first, then the window.
$menuRows = ($script:masonry | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum + 10
try {
    $rawUI = $Host.UI.RawUI
    $bs = $rawUI.BufferSize
    if ($bs.Width -lt $W) { $bs.Width = $W; $rawUI.BufferSize = $bs }
    $ws = $rawUI.WindowSize
    $ws.Width  = [Math]::Max($ws.Width,  $W)
    $ws.Height = [Math]::Max($ws.Height, $menuRows)
    $rawUI.WindowSize = $ws
} catch {}
# Re-check: some hosts (Windows Terminal) ignore resize requests
$curWS = $Host.UI.RawUI.WindowSize
if ($curWS.Width -lt $W) {
    Write-Host "  Tip: widen the window to $W+ columns — the layout wraps below that." -ForegroundColor $c.Warn
    Start-Sleep 2
} elseif ($curWS.Height -lt $menuRows) {
    Write-Host "  Tip: window is shorter than $menuRows rows - the menu may scroll." -ForegroundColor $c.Warn
    Start-Sleep 2
}

# ─── MAIN LOOP ────────────────────────────────────────────────

while ($true) {
    Show-Menu

    $script:col=0; X '  > ' $c.Key; $script:col=0
    $key = Read-Host
    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    $kU = $key.Trim().ToUpper()

    # ── Standalone commands (whole input only) ──
    if ($kU -eq 'I') {
        if (@($pk | Where-Object On).Count -eq 0) {
            $script:flash = 'Nothing selected.'; continue
        }
        $script:needCls = $true
        Show-Confirm
        $script:col=0; X '  Proceed? [' $c.Label; X 'y' $c.Ok; X '/' $c.Label; X 'N' $c.Fail; X '] (Enter = cancel) > ' $c.Key; $script:col=0
        $cfm = Read-Host
        if ($cfm -match '^[Yy]') { Run-Install }
        continue
    }
    if ($kU -eq 'Q') {
        Clear-Host; Bar -T 'See you next time!'; Write-Host ''; exit 0
    }
    if ($kU -eq 'N') { $script:noIcons = -not $script:noIcons; continue }
    if ($kU -eq 'Z') {
        foreach ($p in $pk) { $p.On = $script:defaults[$p.Id] }
        $script:flash = 'Selection reset to defaults.'; $script:flashC = $c.Accent
        continue
    }

    # ── Multi-token toggles: numbers, ranges, group letters, * / 0 ──
    # Examples:  "5"   "1 5 12"   "20-27"   "3,d,8-11"   "* d x"
    $bad = @()
    foreach ($tok in ($kU -split '[,\s]+' | Where-Object { $_ })) {
        $num = 0
        if ($tok -match '^(\d+)-(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -gt $hi) { $t = $lo; $lo = $hi; $hi = $t }
            $m = @($pk | Where-Object { $_.Id -ge $lo -and $_.Id -le $hi })
            if ($m.Count -gt 0) { $m | ForEach-Object { $_.On = -not $_.On } }
            else { $bad += $tok }
        }
        elseif ($tok -eq '*') {
            # All ON — except POST (activation / system tweaks / firewall):
            # those stay deliberate opt-ins, never armed by a bulk gesture
            $pk | Where-Object { $_.G -ne 'POST' } | ForEach-Object { $_.On = $true }
            $script:flash = 'All ON — POST-INSTALL excluded (press X to include)'; $script:flashC = $c.Warn
        }
        elseif ($tok -eq '0') { $pk | ForEach-Object { $_.On = $false } }
        elseif ([int]::TryParse($tok, [ref]$num)) {
            $p = $pk | Where-Object { $_.Id -eq $num }
            if ($p) { $p.On = -not $p.On } else { $bad += $tok }
        }
        elseif ($gk.ContainsKey($tok)) {
            $g = $gk[$tok]; $m = @($pk | Where-Object { $_.G -eq $g })
            $anyOn = @($m | Where-Object On).Count -gt 0
            $m | ForEach-Object { $_.On = -not $anyOn }
        }
        else { $bad += $tok }
    }
    if ($bad.Count -gt 0) { $script:flash = "Ignored: $($bad -join ', ')" }
}