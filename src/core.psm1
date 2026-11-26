#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit install engine - shared by both front-ends.
.DESCRIPTION
    No UI here: functions return objects and accept an optional -OnStatus
    scriptblock for progress text. Both src/tui-spectre.ps1 (PowerShell 7.4+)
    and src/tui-classic.ps1 (Windows PowerShell 5.1) call it.

    Install methods: winget, msstore, script (vendor one-liner, run in a
    CHILD process so a vendor `exit` cannot close the menu), direct (latest
    installer resolved from the vendor's download page + Authenticode check),
    npm, builtin (enable-rdp, dev-folder, wsl-ubuntu). NoAdmin packages run
    at the signed-in user's normal rights when the kit is elevated
    (Invoke-KitDeElevated: one-shot scheduled task, RunLevel LUA).

    Self-healing winget IDs: a vanished ID is replaced by its successor, and a
    dead installer download falls back to older versions, then to the Store.
    Heals persist on this PC (cache\local-overrides.json); copy them into
    config/winget-id-overrides.json in the repo to share them with every PC.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version 2.0

$script:KitVersion  = '2.7.0'   # bump with user-visible changes (shown in the menu banner)
$script:KitRoot     = $null
$script:BaseData    = $null
$script:Catalog     = @()
$script:Groups      = @()
$script:Direct      = @{}
$script:Overrides   = @{}
$script:LogPath     = $null
$script:VtUnavailable = $false   # set when console-mode calls fail (not a console): Enable-KitConsoleVt stops trying
$script:StateDir    = if ($env:MYWINKIT_STATE_DIR) { $env:MYWINKIT_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'my-win-kit' }   # override: tests
$script:WG_NOT_FOUND = -1978335212   # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
# winget's "nothing to do" exits for `winget install` on an installed app (source: winget-cli
# doc/windows/package-manager/winget/returnCodes.md). Only these mean 'current'; any other
# non-zero exit is a failure, even when the app is installed (e.g. an upgrade whose installer failed).
$script:WG_UPDATE_NOT_APPLICABLE     = -1978335189   # 0x8A15002B UPDATE_NOT_APPLICABLE: no applicable update found
$script:WG_UPGRADE_VERSION_NOT_NEWER = -1978335153   # 0x8A15004F UPGRADE_VERSION_NOT_NEWER: available version not newer than installed
$script:WG_PACKAGE_ALREADY_INSTALLED = -1978335135   # 0x8A150061 PACKAGE_ALREADY_INSTALLED: installed, upgrade not attempted
$script:WG_INSTALL_DOWNGRADE         = -1978334962   # 0x8A15010E INSTALL_DOWNGRADE: a higher version is already installed
$script:WG_NOTHING_TO_DO = @($script:WG_UPDATE_NOT_APPLICABLE, $script:WG_UPGRADE_VERSION_NOT_NEWER, $script:WG_PACKAGE_ALREADY_INSTALLED, $script:WG_INSTALL_DOWNGRADE)
$script:UA          = 'my-win-kit (PowerShell)'
$script:LastUpgradeRaw = $null   # raw `winget upgrade` lines from the last Get-KitUpdates
$script:LastFailLine = ''        # the line that names the problem in the last failed script/updater run

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------- setup

function ConvertTo-KitPackage($h, [hashtable]$Order, [string]$Origin = 'config') {
    # Indexer access: optional keys are simply $null (StrictMode-safe)
    return [pscustomobject]@{
        Id = [int]$h['Id']; Name = [string]$h['Name']; Group = [string]$h['Group']; GroupOrder = $Order[[string]$h['Group']]
        Default = [bool]$h['On']; On = [bool]$h['On']
        Method = [string]$h['Method']; Ref = [string]$h['Ref']; Desc = [string]$h['Desc']
        AI = [bool]$h['AI']; Interactive = [bool]$h['Interactive']
        Update = $h['Update']; Version = $h['Version']; Exe = $h['Exe']; Appx = $h['Appx']
        Uninstall = $h['Uninstall']; Fallback = $h['Fallback']; Requires = $h['Requires']
        Elevated = [bool]$h['Elevated']; Shell = $h['Shell']; Detect = $h['Detect']
        NoAdmin = [bool]$h['NoAdmin']
        Origin = $Origin
    }
}

# ================================================================ configuration (GitHub is the home, read-only)
# config/catalog.json, config/settings.json and config/winget-id-overrides.json live in the
# GitHub repo (public). Every deployed copy reads the latest at start-up and caches it.
# The menu never writes config: changes are made by hand in the repo.
#   read: GitHub raw URL -> cache -> bundled copy (-> built-in defaults for settings/overrides)
# Test/override hooks: MYWINKIT_REPO (owner/name), MYWINKIT_BRANCH, MYWINKIT_CONFIG_URL
# (base URL or file:/// folder for reads).

$script:Repo = if ($env:MYWINKIT_REPO) { $env:MYWINKIT_REPO } else { '1nst4ll/my-win-kit' }
$script:Branch = if ($env:MYWINKIT_BRANCH) { $env:MYWINKIT_BRANCH } else { 'main' }
$script:ConfigFiles = @('catalog.json', 'settings.json', 'winget-id-overrides.json', 'terminal.json')
$script:Config = @{}          # file name -> parsed document (ordered hashtables)
$script:ConfigSource = @{}    # file name -> @{ Kind = github|cache|bundled|default; Detail }
$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Get-KitConfigBaseUrl {
    if ($env:MYWINKIT_CONFIG_URL) { return $env:MYWINKIT_CONFIG_URL.TrimEnd('/') }
    return "https://raw.githubusercontent.com/$($script:Repo)/$($script:Branch)/config"
}
function Get-KitCacheDir { return (Join-Path $script:StateDir 'cache') }

function ConvertTo-KitHashtable($o) {
    <# ConvertFrom-Json output -> ordered hashtables / arrays (5.1 has no -AsHashtable). #>
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-KitHashtable $p.Value }; return $h
    }
    if ($o -is [System.Collections.IList] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-KitHashtable $_ }) }
    return $o
}

function ConvertTo-KitJsonValue($v) {
    <# Compact JSON, ASCII-only (non-ASCII as \uXXXX) and identical in 5.1 and pwsh. #>
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte]) { return [string]$v }
    if ($v -is [double] -or $v -is [decimal] -or $v -is [single]) { return $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($v -is [string] -or $v -is [char]) {
        if ([string]$v -match '^[\x20\x21\x23-\x5B\x5D-\x7E]*$') { return '"' + $v + '"' }   # plain ASCII: nothing to escape
        $sb = [Text.StringBuilder]::new('"')
        foreach ($ch in ([string]$v).ToCharArray()) {
            $n = [int]$ch
            if ($ch -eq '"') { [void]$sb.Append('\"') } elseif ($ch -eq '\') { [void]$sb.Append('\\') }
            elseif ($n -lt 32 -or $n -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $n)) } else { [void]$sb.Append($ch) }
        }
        return $sb.Append('"').ToString()
    }
    if ($v -is [System.Collections.IDictionary]) {
        return '{ ' + ((@($v.PSBase.Keys) | ForEach-Object { (ConvertTo-KitJsonValue ([string]$_)) + ': ' + (ConvertTo-KitJsonValue $v[$_]) }) -join ', ') + ' }'
    }
    if ($v -is [System.Collections.IEnumerable]) { return '[' + ((@($v) | ForEach-Object { ConvertTo-KitJsonValue $_ }) -join ', ') + ']' }
    return ConvertTo-KitJsonValue ([string]$v)
}

function ConvertTo-KitJsonDocument($doc) {
    <# Top-level object, one array item / one map entry per line: small, readable git diffs. #>
    $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('{')
    $keys = @($doc.PSBase.Keys)   # PSBase: a JSON key named "keys" must not hide the property
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]; $v = $doc[$k]; $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }
        $isMapOfMaps = $v -is [System.Collections.IDictionary] -and @($v.PSBase.Values | Where-Object { $_ -is [System.Collections.IDictionary] }).Count -gt 0
        if ($v -is [System.Collections.IList] -and $v -isnot [string] -and @($v).Count -gt 0) {
            $lines.Add("  $(ConvertTo-KitJsonValue ([string]$k)): [")
            $arr = @($v); for ($j = 0; $j -lt $arr.Count; $j++) { $lines.Add("    $(ConvertTo-KitJsonValue $arr[$j])$(if ($j -lt $arr.Count - 1) { ',' })") }
            $lines.Add("  ]$comma")
        } elseif ($isMapOfMaps -and $v.PSBase.Count -gt 0) {
            $lines.Add("  $(ConvertTo-KitJsonValue ([string]$k)): {")
            $mk = @($v.PSBase.Keys); for ($j = 0; $j -lt $mk.Count; $j++) { $lines.Add("    $(ConvertTo-KitJsonValue ([string]$mk[$j])): $(ConvertTo-KitJsonValue $v[$mk[$j]])$(if ($j -lt $mk.Count - 1) { ',' })") }
            $lines.Add("  }$comma")
        } else {
            $lines.Add("  $(ConvertTo-KitJsonValue ([string]$k)): $(ConvertTo-KitJsonValue $v)$comma")
        }
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function ConvertFrom-KitJsonText([string]$Text) {
    $o = $Text | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $o) { throw 'empty document' }
    return ConvertTo-KitHashtable $o
}

function Test-KitConfigDoc([string]$Name, $Doc) {
    <# Minimal shape check so a broken file never reaches the menus. #>
    if ($Doc -isnot [System.Collections.IDictionary]) { throw 'not a JSON object' }
    if ($Name -eq 'catalog.json') {
        if (-not $Doc.Contains('Groups') -or -not $Doc.Contains('Packages')) { throw 'catalog.json needs Groups and Packages' }
        if (@($Doc['Packages']).Count -lt 1) { throw 'catalog.json has no packages' }
    }
    if ($Name -eq 'terminal.json' -and -not $Doc['defaultProfile']) { throw 'terminal.json needs defaultProfile' }
    return $true
}

function Read-KitConfigFile([string]$Name, [string]$KitRoot, [switch]$Offline) {
    <# Latest config: GitHub -> cache -> bundled. Updates $script:Config / $script:ConfigSource. #>
    $cache = Join-Path (Get-KitCacheDir) $Name
    $doc = $null; $src = $null
    if (-not $Offline -and -not $script:NetworkDown) {
        $base = Get-KitConfigBaseUrl
        try {
            if ($base -like 'file:*') { $text = [IO.File]::ReadAllText(([Uri]"$base/$Name").LocalPath) }
            else { $text = (Invoke-WebRequest -Uri "$base/$Name" -UseBasicParsing -TimeoutSec 4 -UserAgent $script:UA -Headers @{ 'Cache-Control' = 'no-cache' }).Content }
            if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
            $doc = ConvertFrom-KitJsonText $text; [void](Test-KitConfigDoc $Name $doc)
            $src = @{ Kind = 'github'; Detail = $base }
        } catch {
            $msg = $_.Exception.Message
            $is404 = $msg -match '404|Not Found'
            if (-not $is404 -and $base -notlike 'file:*') { $script:NetworkDown = $true }   # offline: skip the other files' timeouts
            Write-KitRunLog "config: $Name from $base failed: $msg"
            $doc = $null
        }
        if ($doc) {
            try {
                if (-not (Test-Path -LiteralPath (Get-KitCacheDir))) { New-Item -ItemType Directory -Path (Get-KitCacheDir) -Force | Out-Null }
                [IO.File]::WriteAllText($cache, (ConvertTo-KitJsonDocument $doc), [Text.UTF8Encoding]::new($false))
            } catch {}
        }
    }
    if (-not $doc -and (Test-Path -LiteralPath $cache)) {
        try {
            $doc = ConvertFrom-KitJsonText ([IO.File]::ReadAllText($cache)); [void](Test-KitConfigDoc $Name $doc)
            $src = @{ Kind = 'cache'; Detail = (Get-Item -LiteralPath $cache).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        } catch {
            $script:Warnings.Add("Cached $Name is damaged ($($_.Exception.Message)) - using the copy that came with the kit.")
            $doc = $null
        }
    }
    if (-not $doc) {
        $b = Join-Path $KitRoot "config\$Name"
        try { $doc = ConvertFrom-KitJsonText ([IO.File]::ReadAllText($b)); [void](Test-KitConfigDoc $Name $doc); $src = @{ Kind = 'bundled'; Detail = $b } }
        catch {
            if ($Name -eq 'catalog.json') { throw "No usable catalog.json (GitHub, cache and $b all failed): $($_.Exception.Message)" }
            $doc = [ordered]@{ schema = 1 }; $src = @{ Kind = 'default'; Detail = 'built-in defaults' }
        }
    }
    $script:Config[$Name] = $doc
    $script:ConfigSource[$Name] = $src
}

function Initialize-Kit {
    <#
    Load the configuration (catalog, settings, learned winget-ID heals) from
    GitHub / cache / the bundled copy and build the package list. -Offline
    skips the network (tests, or a PC known to be offline).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KitRoot, [switch]$Offline)
    $script:KitRoot = $KitRoot
    $script:Warnings = [System.Collections.Generic.List[string]]::new()
    $script:NetworkDown = $false
    foreach ($n in $script:ConfigFiles) { Read-KitConfigFile -Name $n -KitRoot $KitRoot -Offline:$Offline }
    $script:BaseData = $script:Config['catalog.json']
    $script:Direct = $script:BaseData['Direct']
    Update-KitOverrides
    Update-KitCatalog
    $src = $script:ConfigSource['catalog.json']
    Write-KitRunLog "config: catalog from $($src.Kind) ($($src.Detail)); settings from $($script:ConfigSource['settings.json'].Kind); overrides from $($script:ConfigSource['winget-id-overrides.json'].Kind)"
    return $script:Catalog
}

function Update-KitOverrides {
    <# Learned heals = config/winget-id-overrides.json + the ones this PC learned itself. #>
    $script:Overrides = @{}
    $o = $script:Config['winget-id-overrides.json']
    if ($o -and $o.Contains('overrides') -and $o['overrides']) { foreach ($k in @($o['overrides'].Keys)) { $script:Overrides[[string]$k] = [string]$o['overrides'][$k] } }
    foreach ($kv in (Get-KitLocalOverrides).GetEnumerator()) { $script:Overrides[$kv.Key] = $kv.Value }
}

function Update-KitCatalog {
    <# Build groups + package list from the catalog document (Removed entries stay hidden). #>
    $cat = $script:BaseData
    $groups = @($cat['Groups'] | ForEach-Object { [pscustomobject]@{ Key = [string]$_['Key']; Label = [string]$_['Label']; Letter = [string]$_['Letter'] } })
    $post = @($groups | Where-Object Key -eq 'POST')
    $script:Groups = @(@($groups | Where-Object Key -ne 'POST') + $post)
    $order = @{}
    for ($i = 0; $i -lt $script:Groups.Count; $i++) { $order[$script:Groups[$i].Key] = $i }
    $mk = {
        param($h)
        if (-not $order.ContainsKey([string]$h['Group'])) { $h['Group'] = 'OTHR' }
        $p = ConvertTo-KitPackage $h $order
        if ($p.Method -in 'winget', 'msstore') {
            $hops = 0
            while ($script:Overrides.ContainsKey($p.Ref) -and $hops -lt 5) {
                $nv = $script:Overrides[$p.Ref]
                if ($nv -like 'msstore:*') { $p.Method = 'msstore'; $p.Ref = $nv.Substring(8) } else { $p.Ref = $nv }
                $hops++
            }
        }
        $p
    }
    $script:Catalog = @(foreach ($h in @($cat['Packages'])) { & $mk $h })
}

function Get-KitVersion { return $script:KitVersion }
function Get-KitGroups { return $script:Groups }
function Get-KitCatalog { return $script:Catalog }
function Get-KitWarnings { return @($script:Warnings) }
function Get-KitLogPath { return $script:LogPath }
function Get-KitOverrideCount { return $script:Overrides.Count }
function Get-KitSetting([string]$Name, $Default = $null) {
    $s = $script:Config['settings.json']
    if ($s -and $s.Contains($Name)) { return $s[$Name] }
    return $Default
}

function Get-KitConfigInfo {
    <# Where the config came from + the heals this PC learned (for the banner and Settings). #>
    $src = $script:ConfigSource['catalog.json']
    return [pscustomobject]@{
        Repo = $script:Repo; Branch = $script:Branch; Kind = $src.Kind; Detail = $src.Detail
        LocalFixes = (Get-KitLocalOverrides).Count; LocalFixesFile = (Get-KitLocalOverridesFile); Warnings = @($script:Warnings)
    }
}

function Get-KitLocalOverridesFile { return (Join-Path (Get-KitCacheDir) 'local-overrides.json') }

function Get-KitLocalOverrides {
    <# Heals learned on this PC (old -> new). Never pushed: copy them into config/winget-id-overrides.json by hand. #>
    $f = Get-KitLocalOverridesFile
    $h = @{}
    if (Test-Path -LiteralPath $f) { try { $d = ConvertFrom-KitJsonText ([IO.File]::ReadAllText($f)); foreach ($k in @($d.Keys)) { $h[[string]$k] = [string]$d[$k] } } catch {} }
    return $h
}

function Get-KitRunOrder {
    <# Selected packages in install order: catalogue group order, POST always last. #>
    param([object[]]$Packages)
    return @($Packages | Sort-Object @{ Expression = { if ($_.Group -eq 'POST') { 1 } else { 0 } } }, GroupOrder, Id)
}

function Test-KitAdmin {
    <# This process runs elevated. Testing: MYWINKIT_SIMULATE_ADMIN=1|0. #>
    if ($env:MYWINKIT_SIMULATE_ADMIN -eq '1') { return $true }
    if ($env:MYWINKIT_SIMULATE_ADMIN -eq '0') { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-KitWinget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Get-KitArch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Update-KitPath {
    <# Reload PATH from the registry so tools installed earlier in this run (Git, Node) are found. #>
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

# ---------------------------------------------------------------- log + state

function Start-KitLog {
    $dir = Join-Path $env:TEMP 'my-win-kit'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogPath = Join-Path $dir ('install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    Write-KitLog "my-win-kit run on $env:COMPUTERNAME, PowerShell $($PSVersionTable.PSVersion)"
    return $script:LogPath
}

function Write-KitLog {
    param([string]$Text)
    if (-not $script:LogPath) { return }
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $Text) -Encoding UTF8 } catch {}
}

function Write-KitRunLog {
    <#
    Debug log of WHICH front-end ran and why: one file per run in
    <state dir>\logs\ (default %LOCALAPPDATA%\my-win-kit\logs). The loader
    creates the file and passes it in MYWINKIT_RUNLOG; a menu started
    directly creates its own.
    #>
    param([string]$Text)
    try {
        if (-not $env:MYWINKIT_RUNLOG) {
            $dir = Join-Path $script:StateDir 'logs'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $env:MYWINKIT_RUNLOG = Join-Path $dir ('run-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $PID)
        }
        Add-Content -LiteralPath $env:MYWINKIT_RUNLOG -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Text) -Encoding UTF8
    } catch {}
}

function Get-KitState {
    <# Per-PC preferences: last selection, settings. Never synced. #>
    $f = Join-Path $script:StateDir 'state.json'
    $s = [pscustomobject]@{ LastSelection = @(); LastFailed = @(); RemoveShortcuts = $true }
    if (Test-Path -LiteralPath $f) {
        try {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($null -ne $j.LastSelection)   { $s.LastSelection = @($j.LastSelection | ForEach-Object { [int]$_ }) }
            if ($null -ne $j.LastFailed)      { $s.LastFailed = @($j.LastFailed | ForEach-Object { [int]$_ }) }
            if ($null -ne $j.RemoveShortcuts) { $s.RemoveShortcuts = [bool]$j.RemoveShortcuts }
        } catch {}
    }
    return $s
}

function Save-KitState {
    param([Parameter(Mandatory)]$State)
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        $State | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:StateDir 'state.json') -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------- detection

function Get-KitUninstallEntries {
    $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
        ForEach-Object {
            $v = $null; if ($_.PSObject.Properties['DisplayVersion']) { $v = $_.DisplayVersion }
            [pscustomobject]@{ Name = $_.DisplayName; Version = $v }
        })
}

function Get-KitVersionText {
    <# First dotted version number in a string, or $null. #>
    param([string]$Text)
    $m = [regex]::Match("$Text", '\d+(\.\d+)+')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-KitToolVersion {
    <# Run a package's Version command (e.g. "claude --version") via its known exe. #>
    param([Parameter(Mandatory)]$Package)
    if (-not $Package.Version) { return $null }
    $parts = $Package.Version -split '\s+'
    $exe = $parts[0]
    if ($Package.Exe) {
        $full = [Environment]::ExpandEnvironmentVariables($Package.Exe)
        if (Test-Path -LiteralPath $full -PathType Leaf) { $exe = $full }   # a folder only proves the install
    }
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Update-KitPath }   # installed earlier in this run
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $null }
    try {
        $r = Invoke-KitProcess -FilePath $exe -ArgumentList @($parts | Select-Object -Skip 1)
        if (-not $r.Started) { return $null }
        return (Get-KitVersionText ((@($r.Out) + @($r.Err)) -join "`n"))
    } catch { return $null }
}

function Get-KitInstalled {
    <#
    .SYNOPSIS
        What's installed on this PC. Returns hashtable Id -> version string
        ('' when installed but version unknown). Missing = not installed.
    .DESCRIPTION
        One `winget export` for every winget/msstore ID, then per-package
        checks: Appx name, uninstall DisplayName regex, known exe path.
    #>
    [CmdletBinding()]
    param([object[]]$Packages = $script:Catalog)

    $wg = @{}
    if (Test-KitWinget) {
        $tmp = Join-Path $env:TEMP ('my-win-kit-export-{0}.json' -f [guid]::NewGuid())
        try {
            $null = Invoke-KitProcess -FilePath 'winget' -ArgumentList @('export', '-o', $tmp, '--include-versions', '--accept-source-agreements', '--disable-interactivity')
            if (Test-Path -LiteralPath $tmp) {
                $j = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
                foreach ($src in @($j.Sources)) {
                    foreach ($pk in @($src.Packages)) {
                        # winget reports odd forms ("> 280.4.5053", "ad 9.8.0"): keep the dotted number
                        $v = ''; if ($pk.PSObject.Properties['Version'] -and $pk.Version) { $v = [string]$pk.Version }
                        $vt = Get-KitVersionText $v; if ($vt) { $v = $vt }
                        $wg[[string]$pk.PackageIdentifier] = $v
                    }
                }
            }
        } catch {
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    $npm = $null
    if (@($Packages | Where-Object Method -eq 'npm').Count) { $npm = Get-KitNpmGlobals }

    $uninst = $null
    $res = @{}
    foreach ($p in $Packages) {
        $ver = $null
        if ($p.Detect) { $ver = Get-KitDetect -Name $p.Detect }
        if ($null -eq $ver -and $p.Method -eq 'npm' -and $npm -and $npm.ContainsKey($p.Ref)) { $ver = $npm[$p.Ref] }
        if ($null -eq $ver -and $p.Appx) {
            try {
                $ax = Get-AppxPackage -Name $p.Appx -ErrorAction Stop | Select-Object -First 1
                if ($ax) { $ver = [string]$ax.Version }
            } catch {}
        }
        if ($null -eq $ver -and $p.Uninstall) {
            if ($null -eq $uninst) { $uninst = Get-KitUninstallEntries }
            $hit = $uninst | Where-Object { $_.Name -match $p.Uninstall } | Select-Object -First 1
            if ($hit) { $ver = if ($hit.Version) { [string]$hit.Version } else { '' } }
        }
        if ($null -eq $ver -and $p.Exe) {
            if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($p.Exe))) {
                $ver = Get-KitToolVersion -Package $p
                if ($null -eq $ver) { $ver = '' }
            }
        }
        if ($null -eq $ver) {
            $wid = $null
            if ($p.Method -in 'winget', 'msstore') { $wid = $p.Ref } elseif ($p.Fallback) { $wid = $p.Fallback }
            if ($wid -and $wg.ContainsKey($wid)) { $ver = $wg[$wid] }
        }
        if ($null -ne $ver) { $res[$p.Id] = $ver }
    }
    return $res
}

# ---------------------------------------------------------------- winget helpers

function Invoke-KitWinget {
    <# Run winget, return @{ Ec; Out }. -DeElevate: at the signed-in user's normal rights (Invoke-KitDeElevated). #>
    param([string[]]$WingetArgs, [switch]$DeElevate)
    Write-KitLog ("winget " + ($WingetArgs -join ' ') + $(if ($DeElevate) { '  (de-elevated)' } else { '' }))
    $r = Invoke-KitChild -FilePath 'winget' -ArgumentList $WingetArgs -DeElevate:$DeElevate
    $out = @(@($r.Out) + @($r.Err))
    $ec = $r.Ec
    $clean = @($out | Where-Object { $_.Trim() -and $_ -match '[A-Za-z]' -and $_ -notmatch '^\s*[\\|/\-]+\s*$' })
    foreach ($l in ($clean | Select-Object -Last 15)) { Write-KitLog "  | $l" }
    Write-KitLog "  exit $ec"
    return @{ Ec = [int]$ec; Out = $clean }
}

function Get-KitWingetFailReason {
    <#
    One readable line for a failed winget run: the last output line that names the
    problem ("Installer failed with exit code: 1"), else the last line, plus the code.
    #>
    param([int]$ExitCode, [string[]]$Out = @())
    $code = 'winget 0x{0:X8}' -f $ExitCode
    $pick = Get-KitFailLine -Out $Out
    if (-not $pick) { $l = @($Out | Where-Object { $_ -and $_.Trim() }); if ($l.Count) { $pick = $l[-1].Trim() } }
    if ($pick) { return "$pick ($code)" }
    return $code
}

function Get-KitFailLine {
    <# The last output line that names a problem (failed, blocked, denied ...), or ''. Shared by winget, scripts and updaters. #>
    param([string[]]$Out = @())
    $lines = @($Out | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -notmatch '^(Installer log is available|Downloading\s|https?://)' })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '(?i)fail|error|cancel|denied|blocked|unable|cannot|could not|not (found|applicable|supported|valid|newer|recognized)|no package|in use|restart') {
            $s = $lines[$i]; if ($s.Length -gt 120) { $s = $s.Substring(0, 117) + '...' }
            return $s
        }
    }
    return ''
}

function Get-KitWingetOutcome {
    <#
    Classify a `winget install` exit: @{ Status = ok | current | failed; Reason }.
    current = one of winget's "nothing to do" codes ($script:WG_NOTHING_TO_DO).
    Every other non-zero exit is failed, whether or not the app is installed.
    #>
    param([int]$ExitCode, [string[]]$Out = @())
    if ($ExitCode -eq 0) { return @{ Status = 'ok'; Reason = '' } }
    if ($script:WG_NOTHING_TO_DO -contains $ExitCode) { return @{ Status = 'current'; Reason = '' } }
    return @{ Status = 'failed'; Reason = (Get-KitWingetFailReason -ExitCode $ExitCode -Out $Out) }
}

function Get-KitWingetRows {
    <# Parse an aligned winget table (Name | Id | Version ...) into Name/Id pairs. #>
    param([string[]]$Raw)
    $sep = -1
    for ($j = 0; $j -lt $Raw.Count; $j++) { if ($Raw[$j] -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 1) { return @() }
    $hdr = $Raw[$sep - 1]
    $iId = $hdr.IndexOf('Id'); $iVer = $hdr.IndexOf('Version')
    if ($iId -lt 1 -or $iVer -le $iId) { return @() }
    $rows = @()
    for ($j = $sep + 1; $j -lt $Raw.Count; $j++) {
        $ln = "$($Raw[$j])"
        if ($ln.Length -le $iId -or -not $ln.Trim()) { continue }
        $id = $ln.Substring($iId, [Math]::Min($iVer - $iId, $ln.Length - $iId)).Trim()
        if ($id) { $rows += [pscustomobject]@{ Name = $ln.Substring(0, $iId).Trim(); Id = $id } }
    }
    return $rows
}

function Get-KitWingetRaw {
    param([string[]]$WingetArgs)
    $r = Invoke-KitProcess -FilePath 'winget' -ArgumentList $WingetArgs
    if ($r.Ec -ne 0) { return @() }
    return @($r.Out)
}

function Get-KitPkgVersion {
    <# Installed version of a winget/msstore ID via `winget list`, or $null. #>
    param([string]$WId, [string]$Method)
    if (-not $WId) { return $null }
    $la = @('list', '--id', $WId, '--exact', '--disable-interactivity', '--accept-source-agreements')
    if ($Method -eq 'msstore') { $la += @('--source', 'msstore') }
    $raw = @(Get-KitWingetRaw $la)
    $sep = -1
    for ($j = 0; $j -lt $raw.Count; $j++) { if ($raw[$j] -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 1 -or ($sep + 1) -ge $raw.Count) { return $null }
    $hdr = $raw[$sep - 1]; $dl = $raw[$sep + 1]
    $vi = $hdr.IndexOf('Version'); if ($vi -lt 0) { return $null }
    $ai = $hdr.IndexOf('Available'); $si = $hdr.IndexOf('Source')
    if ($si -lt 0) { $si = $hdr.Length }
    $vEnd = if ($ai -gt 0) { $ai } else { $si }
    if ($dl.Length -le $vi) { return '' }
    return $dl.Substring($vi, [Math]::Min($vEnd - $vi, $dl.Length - $vi)).Trim()
}

function Save-KitOverride {
    <#
    A learned heal (old -> new), kept on this PC only (cache\local-overrides.json)
    and applied at every start. The kit never pushes it: Settings shows the file,
    so it can be copied into config/winget-id-overrides.json in the repo.
    #>
    param([string]$Old, [string]$New)
    $script:Overrides[$Old] = $New
    try {
        $loc = Get-KitLocalOverrides; $loc[$Old] = $New
        if (-not (Test-Path -LiteralPath (Get-KitCacheDir))) { New-Item -ItemType Directory -Path (Get-KitCacheDir) -Force | Out-Null }
        $o = [ordered]@{}; foreach ($k in ($loc.Keys | Sort-Object)) { $o[$k] = $loc[$k] }
        [IO.File]::WriteAllText((Get-KitLocalOverridesFile), (ConvertTo-KitJsonDocument $o), [Text.UTF8Encoding]::new($false))
    } catch {}
    Write-KitRunLog "heal: learned $Old -> $New (kept on this PC: $(Get-KitLocalOverridesFile))"
}
function Find-KitReplacementId {
    <#
    Heal 1: a winget ID vanished (publisher rename, edition/version split).
    Scores search hits on: old-ID prefix, same tail segment, display-name
    match; penalises pre-release channels. Returns the best ID or $null.
    #>
    param($Package)
    $oldId   = $Package.Ref
    $oldBase = $oldId -replace '\.\d+$', ''
    $oldTail = ($oldBase -split '\.')[-1]
    $queries = if ($Package.Method -eq 'msstore') { @($Package.Name) } else { @(@($oldTail, $Package.Name) | Select-Object -Unique) }

    $best = $null; $bestScore = 0
    foreach ($q in $queries) {
        $sa = @('search', $q, '--disable-interactivity', '--accept-source-agreements')
        if ($Package.Method -eq 'msstore') { $sa += @('--source', 'msstore') } else { $sa += @('--source', 'winget') }
        foreach ($row in (Get-KitWingetRows -Raw (Get-KitWingetRaw $sa))) {
            $name = $row.Name; $id = $row.Id
            if ($id -eq $oldId) { continue }
            $s = 0
            if     ($id -like "$oldId.*")                                   { $s += 6 }
            elseif ($oldBase -ne $oldId -and $id -like "$oldBase.*")        { $s += 6 }
            if (($id -split '\.')[-1] -eq $oldTail)                         { $s += 4 }
            if     ($name -eq $Package.Name)                                { $s += 3 }
            elseif ($name -like "$($Package.Name)*" -or $Package.Name -like "$name*") { $s += 1 }
            if ($id -match '(?i)pre-?release|beta|nightly|canary|preview|insider') { $s -= 3 }
            if ($s -gt $bestScore) { $bestScore = $s; $best = $id }
            elseif ($s -eq $bestScore -and $best -and $s -gt 0) {
                $a = [regex]::Match($id, '\.(\d+)$').Groups[1].Value
                $b = [regex]::Match($best, '\.(\d+)$').Groups[1].Value
                if ($a -and $b -and [int]$a -gt [int]$b) { $best = $id }
            }
        }
        if ($bestScore -ge 4) { break }
    }
    if ($bestScore -ge 3) { return $best }
    return $null
}

function Test-KitDownloadFail {
    <# Heal 2 trigger: manifest resolved but its installer download is dead. #>
    param([string[]]$Out)
    $rx = '0x80190194|\(404\)|0x8A150011|hash\s+.*mismatch|installer\s+hash'
    foreach ($o in $Out) { if ($o -match $rx) { return $true } }
    return $false
}

function Get-KitPkgVersions {
    <# Catalogue versions for an ID, newest first. #>
    param([string]$WId, [string]$Method)
    $va = @('show', '--id', $WId, '--exact', '--versions', '--disable-interactivity', '--accept-source-agreements')
    if ($Method -eq 'msstore') { $va += @('--source', 'msstore') }
    $raw = @(Get-KitWingetRaw $va)
    $sep = -1
    for ($j = 0; $j -lt $raw.Count; $j++) { if ($raw[$j] -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 0 -or ($sep + 1) -ge $raw.Count) { return @() }
    return @($raw[($sep + 1)..($raw.Count - 1)] | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'Unknown' })
}

function Find-KitStoreFallback {
    <# Heal 2b: the same app in the Microsoft Store (independent CDN). #>
    param($Package)
    $sa = @('search', $Package.Name, '--source', 'msstore', '--disable-interactivity', '--accept-source-agreements')
    foreach ($row in (Get-KitWingetRows -Raw (Get-KitWingetRaw $sa))) {
        if ($row.Name -eq $Package.Name -or $row.Name -like "*$($Package.Name)*" -or $Package.Name -like "*$($row.Name)*") { return $row.Id }
    }
    return $null
}

function Get-KitWingetInstallArgs {
    param([string]$WId, [string]$Method, [string]$Version = '')
    $a = @('install', '--id', $WId, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Version) { $a += @('--version', $Version) }
    if ($Method -eq 'msstore') { $a += @('--source', 'msstore') }
    return $a
}

# ---------------------------------------------------------------- direct downloads

function Resolve-KitDirect {
    <#
    .SYNOPSIS
        Latest official installer for a Direct key: @{ Url; Version; FileName; Signer; Args }.
        Throws when the vendor page no longer matches the pattern.
    #>
    param([Parameter(Mandatory)][string]$Key)
    $d = $script:Direct[$Key]
    if (-not $d) { throw "unknown direct key '$Key'" }
    $arch = Get-KitArch
    $pat = $d.Pattern.Replace('{arch}', $d.Arch[$arch])
    if ($d.Contains('Arch2')) { $pat = $pat.Replace('{arch2}', $d.Arch2[$arch]) }
    $page = (Invoke-WebRequest -Uri $d.Page -UseBasicParsing -UserAgent $script:UA -TimeoutSec 30).Content
    $m = [regex]::Match($page, $pat)
    if (-not $m.Success) { throw "no $arch installer link found on $($d.Page)" }
    $url = $m.Value
    return [pscustomobject]@{
        Url = $url; Version = $m.Groups[1].Value
        FileName = [Uri]::UnescapeDataString(($url -split '/')[-1])
        Signer = $d.Signer; Args = $d.Args
    }
}

function Test-KitVersionCurrent {
    <# $true when Installed >= Latest (numeric compare on dotted parts). #>
    param([string]$Installed, [string]$Latest)
    $a = Get-KitVersionText $Installed; $b = Get-KitVersionText $Latest
    if (-not $a -or -not $b) { return $false }
    $pa = @($a -split '\.' | ForEach-Object { [int64]$_ }); $pb = @($b -split '\.' | ForEach-Object { [int64]$_ })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $true
}

function Get-KitUpdates {
    <#
    .SYNOPSIS
        Apps with a newer version available: hashtable Id -> latest version.
    .DESCRIPTION
        One `winget upgrade` (about 2 s; redirected output is not truncated) for
        winget/Store apps, plus the vendor page for installed direct apps.
        Script tools (claude, agy) update themselves and are never listed.
    #>
    param([Parameter(Mandatory)][hashtable]$Installed, [object[]]$Packages = $script:Catalog)
    $res = @{}
    $avail = @{}
    $script:LastUpgradeRaw = @()
    if (Test-KitWinget) {
        $raw = @(Get-KitWingetRaw @('upgrade', '--accept-source-agreements', '--disable-interactivity'))
        $script:LastUpgradeRaw = $raw   # Get-KitUpdateAllPlan reuses it (one winget upgrade per scan)
        $sep = -1
        for ($j = 0; $j -lt $raw.Count; $j++) { if ($raw[$j] -match '^-{4,}') { $sep = $j; break } }
        if ($sep -ge 1) {
            $hdr = $raw[$sep - 1]
            $iId = $hdr.IndexOf('Id'); $iVer = $hdr.IndexOf('Version'); $iAv = $hdr.IndexOf('Available'); $iSrc = $hdr.IndexOf('Source')
            if ($iId -gt 0 -and $iAv -gt $iVer) {
                if ($iSrc -lt 0) { $iSrc = 9999 }
                for ($j = $sep + 1; $j -lt $raw.Count; $j++) {
                    $ln = $raw[$j]
                    if ($ln.Length -le $iAv) { continue }
                    $id = $ln.Substring($iId, $iVer - $iId).Trim()
                    $av = $ln.Substring($iAv, [Math]::Min($iSrc, $ln.Length) - $iAv).Trim()
                    if ($id -and $av) { $avail[$id] = $av }
                }
            }
        }
    }
    foreach ($p in $Packages) {
        if (-not $Installed.ContainsKey($p.Id)) { continue }
        if ($p.Method -eq 'direct') {
            try {
                $d = Resolve-KitDirect -Key $p.Ref
                if (-not (Test-KitVersionCurrent -Installed $Installed[$p.Id] -Latest $d.Version)) { $res[$p.Id] = $d.Version }
            } catch {}
            continue
        }
        $wid = if ($p.Method -in 'winget', 'msstore') { $p.Ref } else { $null }
        if ($wid -and $avail.ContainsKey($wid)) { $res[$p.Id] = $avail[$wid] }
    }
    return $res
}

function Get-KitLatestVersion {
    <#
    Newest version the kit's install path would get, or $null when unknown:
    direct = vendor download page, winget/msstore = `winget show`, npm = `npm view`,
    script = $null (the vendor installer/updater always fetches latest).
    #>
    param([Parameter(Mandatory)]$Package)
    try {
        switch ($Package.Method) {
            'direct' { return (Resolve-KitDirect -Key $Package.Ref).Version }
            { $_ -in 'winget', 'msstore' } {
                $sa = @('show', '--id', $Package.Ref, '--exact', '--disable-interactivity', '--accept-source-agreements')
                if ($Package.Method -eq 'msstore') { $sa += @('--source', 'msstore') }
                foreach ($l in (Get-KitWingetRaw $sa)) { if ($l -match '^\s*Version:\s*(\S+)') { return $Matches[1] } }
                return $null
            }
            'npm' {
                $r = Invoke-KitProcess -FilePath 'npm' -ArgumentList @('view', $Package.Ref, 'version')
                if ($r.Started -and $r.Ec -eq 0) { return (Get-KitVersionText (@($r.Out) -join ' ')) }
                return $null
            }
            default { return $null }
        }
    } catch { return $null }
}

# ---------------------------------------------------------------- child processes

function ConvertTo-KitArgLine {
    <# Join arguments into one Windows command line (CommandLineToArgvW quoting rules). #>
    param([string[]]$Arguments)
    $parts = @()
    foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        if ($a -ne '' -and $a -notmatch '[\s"]') { $parts += $a; continue }
        $s = [regex]::Replace($a, '(\\*)"', '$1$1\"')
        $s = [regex]::Replace($s, '(\\+)$', '$1$1')
        $parts += '"' + $s + '"'
    }
    return ($parts -join ' ')
}

function Split-KitOutputLines([string]$Text) {
    <# Lines the way PowerShell reads native output (CRLF, LF or a lone CR ends a line). #>
    if (-not $Text) { return @() }
    $l = @($Text -split "`r`n|`n|`r")
    if ($l.Count -and $l[-1] -eq '') { $l = @($l | Select-Object -First ($l.Count - 1)) }
    return $l
}

function Invoke-KitProcess {
    <#
    .SYNOPSIS
        Run a native program away from the menu's console. Returns
        @{ Ec; Out; Err; Started } (Out/Err = lines of stdout/stderr, UTF-8).
    .DESCRIPTION
        Every non-interactive child goes through here, never `& exe`: under
        PowerShell 7 in a conhost window, `& exe` switches the console's
        VT processing off until the program exits, so Spectre's live progress
        and spinners print raw escape codes. This process gets its own hidden
        console (CreateNoWindow) and redirected stdin/stdout/stderr, so the
        menu's console mode is never touched. .cmd/.bat files run via cmd.exe.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $file = $FilePath
    if (-not [IO.Path]::IsPathRooted($file)) {
        $cmd = Get-Command $file -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $file = $cmd.Path }
    }
    $argLine = ConvertTo-KitArgLine $ArgumentList
    if ($file -match '\.(cmd|bat)$') {
        $argLine = '/d /s /c "' + (ConvertTo-KitArgLine @($file)) + ' ' + $argLine + '"'
        $file = $env:ComSpec; if (-not $file) { $file = 'cmd.exe' }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $enc = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    try { $proc = [Diagnostics.Process]::Start($psi) } catch {
        $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return @{ Ec = 1; Out = @(); Err = @("$msg"); Started = $false }
    }
    try {
        try { $proc.StandardInput.Close() } catch {}
        # Read both streams at once so a full stderr pipe cannot deadlock stdout.
        $so = $proc.StandardOutput.ReadToEndAsync()
        $se = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        # A grandchild that inherited the pipes can keep them open: don't wait forever.
        $outText = ''; if ($so.Wait(15000)) { $outText = $so.Result }
        $errText = ''; if ($se.Wait(5000)) { $errText = $se.Result }
        return @{ Ec = [int]$proc.ExitCode; Out = @(Split-KitOutputLines $outText); Err = @(Split-KitOutputLines $errText); Started = $true }
    } finally { $proc.Dispose() }
}

function Enable-KitConsoleVt {
    <#
    Best-effort: switch VT processing back on for this process's console
    output, in case a child process left it off. $true when it is on;
    $false (and nothing changed) when output is not a console.
    #>
    if ($script:VtUnavailable) { return $false }
    try {
        if (-not ('MyWinKit.ConsoleMode' -as [type])) {
            Add-Type -Namespace MyWinKit -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        }
        $h = [MyWinKit.ConsoleMode]::GetStdHandle(-11)
        $m = [uint32]0
        if (-not [MyWinKit.ConsoleMode]::GetConsoleMode($h, [ref]$m)) { return $false }
        if (($m -band 4) -ne 0) { return $true }
        # 0x1 processed output + 0x4 virtual terminal processing
        return [MyWinKit.ConsoleMode]::SetConsoleMode($h, [uint32]($m -bor 5))
    } catch { $script:VtUnavailable = $true; return $false }
}

function Get-KitRemoteScriptArgs {
    <# Arguments for a child PowerShell that runs a vendor one-liner (irm URL | iex). #>
    param([Parameter(Mandatory)][string]$Url)
    $cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm '$Url' | iex"
    return , @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
}

function Invoke-KitRemoteScript {
    <#
    Run a vendor one-liner (irm URL | iex) in a CHILD Windows PowerShell (or
    pwsh with -Shell pwsh) so a vendor `exit` or `throw` cannot close the menu.
    -Attached = shares the console (interactive menus); otherwise it runs
    through Invoke-KitProcess (own hidden console) and its output is captured
    to the log. -Elevated without admin rights: its own administrator window
    (UAC); returns 1223 when the prompt is declined.
    #>
    param([string]$Url, [switch]$Attached, [string]$Shell = '', [switch]$Elevated, [switch]$DeElevate)
    $exe = 'powershell.exe'
    if ($Shell -eq 'pwsh') {
        $exe = Get-KitPwshPath
        if (-not $exe) { Write-KitLog "script: $Url needs PowerShell 7 (pwsh), not found"; return 1 }
    }
    $argList = Get-KitRemoteScriptArgs -Url $Url
    $cmd = $argList[-1]
    Write-KitLog "script: irm $Url | iex  (child $exe$(if ($Elevated) { ', elevated' }))"
    if ($Elevated -and -not (Test-KitAdmin)) {
        # Own administrator window (one UAC prompt); it waits for Enter so its output can be read.
        $wrapped = "try { $cmd; `$c = 0 } catch { Write-Host `$_ -ForegroundColor Red; `$c = 1 }; Write-Host ''; [void](Read-Host 'Finished - press Enter to close this window'); exit `$c"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
        try { $proc = Start-Process -FilePath $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -Verb RunAs -PassThru -ErrorAction Stop }
        catch { Write-KitLog '  administrator prompt declined'; return 1223 }
        $proc.WaitForExit()
        $ec = $proc.ExitCode
    } elseif ($Attached) {
        & $exe @argList
        $ec = $LASTEXITCODE
    } else {
        $r = Invoke-KitChild -FilePath $exe -ArgumentList $argList -DeElevate:$DeElevate
        $out = @(@($r.Out) + @($r.Err))
        $ec = $r.Ec
        foreach ($l in ($out | Where-Object { $_.Trim() } | Select-Object -Last 20)) { Write-KitLog "  | $l" }
        if ($ec -ne 0) { $script:LastFailLine = Get-KitFailLine -Out $out }
    }
    if ($null -eq $ec) { $ec = 1 }
    Write-KitLog "  exit $ec"
    return [int]$ec
}

function Invoke-KitCommandLine {
    <# Run a native command line like "claude update" (Invoke-KitProcess), captured to the log. #>
    param([string]$CommandLine, [string]$Exe, [switch]$DeElevate)
    $parts = $CommandLine -split '\s+'
    $file = $parts[0]
    if ($Exe) { $full = [Environment]::ExpandEnvironmentVariables($Exe); if (Test-Path -LiteralPath $full -PathType Leaf) { $file = $full } }
    if (-not [IO.Path]::IsPathRooted($file) -and -not (Get-Command $file -ErrorAction SilentlyContinue)) { Update-KitPath }
    Write-KitLog "run: $CommandLine$(if ($DeElevate) { '  (de-elevated)' })"
    $r = Invoke-KitChild -FilePath $file -ArgumentList @($parts | Select-Object -Skip 1) -DeElevate:$DeElevate
    $out = @(@($r.Out) + @($r.Err))
    $ec = $r.Ec
    if ($ec -ne 0) { $script:LastFailLine = Get-KitFailLine -Out $out }
    foreach ($l in ($out | Where-Object { $_.Trim() } | Select-Object -Last 15)) { Write-KitLog "  | $l" }
    Write-KitLog "  exit $ec"
    return [int]$ec
}

function Invoke-KitEnableRdp {
    <# Allow RDP with NLA + open the firewall group. Elevates through UAC when needed. #>
    $body = @'
$ErrorActionPreference = 'Stop'
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    # Lock RDP to the Tailscale range (uncomment to use):
    # Set-NetFirewallRule -DisplayGroup 'Remote Desktop' -RemoteAddress 100.64.0.0/10
    exit 0
} catch { exit 1 }
'@
    $tmp = Join-Path $env:TEMP 'my-win-kit-enable-rdp.ps1'
    Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8
    try {
        if (Test-KitAdmin) {
            $ec = (Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp)).Ec
        } else {
            try {
                $proc = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"" -Verb RunAs -PassThru
                $proc.WaitForExit(); $ec = $proc.ExitCode
            } catch { $ec = 1 }
        }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $detail = 'RDP enabled (NLA on)'
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if ($ec -eq 0 -and (Test-Path -LiteralPath $ts)) {
        $ip = @((Invoke-KitProcess -FilePath $ts -ArgumentList @('ip', '-4')).Out) | Select-Object -First 1
        if ($ip) { $detail += ", Tailscale IP $ip" }
    }
    return @{ Ec = [int]$ec; Detail = $detail }
}

# ---------------------------------------------------------------- built-in checks and actions

function Get-KitNpmGlobals {
    <# Globally installed npm packages: hashtable name -> version, or $null when npm is missing. #>
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return $null }
    try {
        $r = Invoke-KitProcess -FilePath 'npm' -ArgumentList @('ls', '-g', '--depth=0', '--json')
        if (-not $r.Started) { return $null }
        $j = (@($r.Out) -join "`n") | ConvertFrom-Json
        $h = @{}
        if ($j -and $j.PSObject.Properties['dependencies'] -and $j.dependencies) {
            foreach ($d in $j.dependencies.PSObject.Properties) {
                $v = ''; if ($d.Value -and $d.Value.PSObject.Properties['version']) { $v = [string]$d.Value.version }
                $h[[string]$d.Name] = $v
            }
        }
        return $h
    } catch { return $null }
}

function Get-KitPwshPath {
    <# pwsh.exe (PowerShell 7) on this PC, or $null. Known path first: PATH is stale right after an install. #>
    $known = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $known) { return $known }
    $c = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Path }
    return $null
}

function Get-KitPwshProfilePath {
    <# PowerShell 7's current-user, current-host profile (Documents may be redirected, e.g. to OneDrive). #>
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1')
}

function Test-KitCttProfile {
    <# $true when PowerShell 7's profile is Chris Titus Tech's (its first line names it). #>
    $f = Get-KitPwshProfilePath
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
    try { return ((@(Get-Content -LiteralPath $f -TotalCount 5 -ErrorAction Stop) -join "`n") -match "Chris Titus Tech's PowerShell profile") } catch { return $false }
}

function Get-KitDriveType {
    <# DriveType of a drive letter ('Fixed', 'CDRom', 'Removable', 'Network', ...) when it is ready, else ''. #>
    param([Parameter(Mandatory)][string]$Letter)
    try {
        $d = New-Object System.IO.DriveInfo ($Letter.TrimEnd(':', '\') + ':')
        if ($d.IsReady) { return [string]$d.DriveType }
    } catch {}
    return ''
}

function Get-KitDevFolderPath {
    <#
    D:\dev\git when D: is a local fixed disk (not a CD/DVD, USB stick or network
    drive), else <system drive>\dev\git. -DDriveType injects the D: check (tests).
    #>
    param([AllowEmptyString()][string]$DDriveType)
    if (-not $PSBoundParameters.ContainsKey('DDriveType')) { $DDriveType = Get-KitDriveType 'D' }
    if ($DDriveType -eq 'Fixed') { return 'D:\dev\git' }
    $sys = $env:SystemDrive; if (-not $sys) { $sys = 'C:' }
    return "$sys\dev\git"
}

function Invoke-KitDevFolder {
    <# Create the dev folder (idempotent). @{ Status = done|current|dryrun|failed; Detail; To = path }. #>
    param([switch]$DryRun, [AllowEmptyString()][string]$DDriveType)
    $path = if ($PSBoundParameters.ContainsKey('DDriveType')) { Get-KitDevFolderPath -DDriveType $DDriveType } else { Get-KitDevFolderPath }
    if (Test-Path -LiteralPath $path -PathType Container) { return @{ Status = 'current'; Detail = "$path already exists"; To = $path } }
    if ($DryRun) { return @{ Status = 'dryrun'; Detail = "would create $path"; To = $path } }
    try {
        New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        return @{ Status = 'done'; Detail = "created $path"; To = $path }
    } catch { return @{ Status = 'failed'; Detail = "could not create $($path): $($_.Exception.Message)"; To = '' } }
}

function ConvertFrom-KitWslText {
    <#
    wsl.exe writes UTF-16LE unless WSL_UTF8=1, so its lines read as UTF-8 carry
    NUL characters (and a mangled BOM). Strip them so either form parses.
    #>
    param([string[]]$Lines)
    return @(@($Lines) | ForEach-Object { ("$_" -replace "`0", '' -replace "[$([char]0xFEFF)$([char]0xFFFD)]", '').TrimEnd() })
}

function Select-KitUbuntuDistro {
    <#
    Newest Ubuntu LTS from `wsl --list --online` output: the highest Ubuntu-NN.04
    with an even NN (LTS releases); 'Ubuntu' when none is listed. No header
    needed, so localized output parses too.
    #>
    param([string[]]$Lines)
    $best = $null; $bestMajor = -1
    foreach ($l in (ConvertFrom-KitWslText $Lines)) {
        $tok = ($l.Trim() -split '\s+')[0]
        if ($tok -match '^Ubuntu-(\d+)\.04$') {
            $major = [int]$Matches[1]
            if (($major % 2) -eq 0 -and $major -gt $bestMajor) { $bestMajor = $major; $best = $tok }
        }
    }
    if ($best) { return $best }
    return 'Ubuntu'
}

function Get-KitWslDistros {
    <# WSL distributions registered for this user (registry, no wsl.exe call: safe when WSL is missing). #>
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $k)) { return @() }
    return @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue | ForEach-Object { $_.GetValue('DistributionName') } | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Test-KitWslInstalled {
    <# The WSL app (Store/MSI package, %ProgramFiles%\WSL) is present. The inbox wsl.exe stub alone does not count. #>
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'WSL\wsl.exe')) { return $true }
    try { if (Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction Stop) { return $true } } catch {}
    return $false
}

function Get-KitWslExe {
    $p = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return (Join-Path $env:SystemRoot 'System32\wsl.exe')
}

function Test-KitRebootNeeded {
    <# A Windows restart is needed: exit 3010/1641, or the output says so. #>
    param([int]$ExitCode, [string[]]$Out)
    if ($ExitCode -in 3010, 1641) { return $true }
    foreach ($l in @($Out)) { if ("$l" -match '(?i)reboot|restart (the|your) (system|computer|pc|machine)') { return $true } }
    return $false
}

function Invoke-KitElevatedCapture {
    <#
    Run a console program as administrator with its output captured. Already
    elevated: Invoke-KitProcess. Otherwise one UAC prompt: a hidden cmd.exe runs
    it with output redirected to a temp file (the elevated process does not
    inherit this environment, so -Environment is set inside that cmd).
    Returns @{ Ec; Out; Err; Started }; Ec 1223 = the prompt was declined.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [hashtable]$Environment = @{})
    if (Test-KitAdmin) {
        $saved = @{}
        foreach ($k in @($Environment.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Environment[$k]) }
        try { return (Invoke-KitProcess -FilePath $FilePath -ArgumentList $ArgumentList) }
        finally { foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }
    $out = Join-Path $env:TEMP ('my-win-kit-elevated-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $sets = (@($Environment.Keys) | ForEach-Object { "set $_=$($Environment[$_])&& " }) -join ''
    $line = '/d /s /c "' + $sets + '"' + $FilePath + '" ' + (ConvertTo-KitArgLine $ArgumentList) + ' > "' + $out + '" 2>&1"'
    $cmdExe = $env:ComSpec; if (-not $cmdExe) { $cmdExe = 'cmd.exe' }
    try { $proc = Start-Process -FilePath $cmdExe -ArgumentList $line -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop }
    catch { return @{ Ec = 1223; Out = @(); Err = @('administrator prompt declined'); Started = $false } }
    $proc.WaitForExit()
    $lines = @()
    if (Test-Path -LiteralPath $out) {
        try { $lines = @(Split-KitOutputLines ([IO.File]::ReadAllText($out))) } catch {}
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    return @{ Ec = [int]$proc.ExitCode; Out = $lines; Err = @(); Started = $true }
}

function Invoke-KitWslUbuntu {
    <#
    WSL installed and current (`wsl --install --no-distribution`, else
    `wsl --update`; as administrator), then the newest Ubuntu LTS unless it is
    already registered. The distro's first run (Linux user name + password)
    shares the console, so the catalogue entry is Interactive.
    Returns @{ Status = installed|current|dryrun|failed; Detail; To }.
    #>
    param([switch]$DryRun, [scriptblock]$OnStatus)
    $notify = $OnStatus
    function Send-Note([string]$t) { if ($notify) { try { & $notify $t } catch {} } }
    $hasWsl = Test-KitWslInstalled
    $a = if ($hasWsl) { @('--update') } else { @('--install', '--no-distribution') }
    if ($DryRun) {
        return @{ Status = 'dryrun'; Detail = "wsl $($a -join ' ') (admin), then wsl --install -d <newest Ubuntu LTS> unless it is installed"; To = '' }
    }
    $wsl = Get-KitWslExe
    Send-Note $(if ($hasWsl) { 'updating WSL (Windows asks for admin)' } else { 'installing WSL (Windows asks for admin)' })
    Write-KitLog "wsl $($a -join ' ')  (elevated)"
    $r = Invoke-KitElevatedCapture -FilePath $wsl -ArgumentList $a -Environment @{ WSL_UTF8 = '1' }
    $out = @(ConvertFrom-KitWslText (@($r.Out) + @($r.Err)) | Where-Object { $_.Trim() })
    foreach ($l in ($out | Select-Object -Last 15)) { Write-KitLog "  | $l" }
    Write-KitLog "  exit $($r.Ec)"
    if ($r.Ec -eq 1223) { return @{ Status = 'failed'; Detail = 'administrator prompt declined'; To = '' } }
    if (Test-KitRebootNeeded -ExitCode $r.Ec -Out $out) { return @{ Status = 'failed'; Detail = 'WSL installed - restart Windows, then run this again to add Ubuntu'; To = '' } }
    $last = if ($out.Count) { $out[-1].Trim() } else { '' }
    if ($r.Ec -ne 0 -and -not $hasWsl) { return @{ Status = 'failed'; Detail = "wsl --install exit $($r.Ec): $last".TrimEnd(' ', ':'); To = '' } }
    $wslNote = ''
    if ($r.Ec -ne 0) { $wslNote = "wsl --update exit $($r.Ec); " }
    $wsl = Get-KitWslExe

    Send-Note 'finding the newest Ubuntu LTS'
    $saved = $env:WSL_UTF8; $env:WSL_UTF8 = '1'
    try { $lr = Invoke-KitProcess -FilePath $wsl -ArgumentList @('--list', '--online') } finally { $env:WSL_UTF8 = $saved }
    $name = Select-KitUbuntuDistro -Lines (@($lr.Out) + @($lr.Err))
    Write-KitLog "  newest Ubuntu LTS: $name (wsl --list --online exit $($lr.Ec))"
    $ver = Get-KitVersionText $name; if (-not $ver) { $ver = '' }
    if (@(Get-KitWslDistros) -contains $name) { return @{ Status = 'current'; Detail = "$($wslNote)WSL up to date, $name already installed"; To = $ver } }

    Send-Note "installing $name - it asks for a new Linux user name and password; type exit to come back here"
    Write-KitLog "wsl --install -d $name  (console attached: first-run user set-up)"
    & $wsl --install -d $name
    $ec = $LASTEXITCODE; if ($null -eq $ec) { $ec = 1 }
    Write-KitLog "  exit $ec"
    if (@(Get-KitWslDistros) -contains $name) { return @{ Status = 'installed'; Detail = "$($wslNote)$name installed"; To = $ver } }
    if ($ec -in 3010, 1641) { return @{ Status = 'failed'; Detail = 'restart Windows, then run this again'; To = '' } }
    return @{ Status = 'failed'; Detail = "$($wslNote)wsl --install -d $name exit $ec (see log)"; To = '' }
}

function Get-KitDetect {
    <#
    Built-in install checks, named by a catalogue entry's Detect key. Returns the
    version text ('' = installed, version unknown) or $null (not installed).
    #>
    param([Parameter(Mandatory)][string]$Name)
    try {
        switch ($Name) {
            'dev-folder'  { if (Test-Path -LiteralPath (Get-KitDevFolderPath) -PathType Container) { return '' }; return $null }
            'ctt-profile' { if (Test-KitCttProfile) { return '' }; return $null }
            'wsl-ubuntu'  {
                $best = $null; $bestMajor = -2
                foreach ($d in @(Get-KitWslDistros | Where-Object { $_ -match '^Ubuntu(-\d+\.\d+)?$' })) {
                    $m = -1; if ($d -match '^Ubuntu-(\d+)\.') { $m = [int]$Matches[1] }
                    if ($m -gt $bestMajor) { $bestMajor = $m; $best = $d }
                }
                if (-not $best) { return $null }
                $v = Get-KitVersionText $best; if ($v) { return $v }; return ''
            }
            default { return $null }
        }
    } catch { return $null }
}

# ---------------------------------------------------------------- per-PC preferences (local, never GitHub)

function Get-KitLocalPrefsFile { return (Join-Path $script:StateDir 'local-settings.json') }

function Get-KitLocalPrefs {
    <# This PC's own preferences (%LOCALAPPDATA%\my-win-kit\local-settings.json): ordered hashtable. #>
    $f = Get-KitLocalPrefsFile
    if (Test-Path -LiteralPath $f) { try { $d = ConvertFrom-KitJsonText ([IO.File]::ReadAllText($f)); if ($d -is [System.Collections.IDictionary]) { return $d } } catch {} }
    return [ordered]@{}
}

function Set-KitLocalPref {
    <# Save one per-PC preference locally. Never touches config/*.json or GitHub. #>
    param([Parameter(Mandatory)][string]$Name, $Value)
    $d = Get-KitLocalPrefs
    $d[$Name] = $Value
    if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    [IO.File]::WriteAllText((Get-KitLocalPrefsFile), (ConvertTo-KitJsonDocument $d), [Text.UTF8Encoding]::new($false))
    Write-KitRunLog "prefs: $Name = $(ConvertTo-KitJsonValue $Value) (this PC: $(Get-KitLocalPrefsFile))"
}

function Get-KitLocalSwitch {
    <#
    Effective value of an on/off setting a PC can override: this PC's
    local-settings.json, else settings.json, else -Default. -Legacy = older
    names of the same setting, read after -Name at each level.
    @{ On; Source = 'this PC' | 'shared' | 'default' }. The loader (5.1, no
    module) applies the same order on its own copy of the files.
    #>
    param([Parameter(Mandatory)][string]$Name, [bool]$Default = $true, [string[]]$Legacy = @())
    $names = @($Name) + @($Legacy | Where-Object { $_ })
    $loc = Get-KitLocalPrefs
    foreach ($n in $names) { if ($loc.Contains($n) -and $loc[$n] -is [bool]) { return [pscustomobject]@{ On = [bool]$loc[$n]; Source = 'this PC' } } }
    $s = $script:Config['settings.json']
    foreach ($n in $names) { if ($s -and $s.Contains($n) -and $s[$n] -is [bool]) { return [pscustomobject]@{ On = [bool]$s[$n]; Source = 'shared' } } }
    return [pscustomobject]@{ On = $Default; Source = 'default' }
}

function Get-KitAutoInstallPwsh {
    <# Older name of Get-KitAutoInstallEssentials (autoInstallPwsh became autoInstallEssentials in kit 2.7.0). #>
    return (Get-KitAutoInstallEssentials)
}

function Get-KitElevateAtStart {
    <# "Ask for administrator rights once at start" (elevateAtStart): the loader relaunches the kit elevated. #>
    return (Get-KitLocalSwitch -Name 'elevateAtStart' -Default $true)
}

# ---------------------------------------------------------------- de-elevation (NoAdmin installs from an elevated kit)

$script:WG_PROHIBITS_ELEVATION    = -1978335146   # 0x8A150056 APPINSTALLER_CLI_ERROR_INSTALLER_PROHIBITS_ELEVATION
$script:WG_ADMIN_CONTEXT_PROHIBITED = -1978335107 # 0x8A15007D APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED (user-scope package)

function Get-KitSessionUser {
    <#
    The user signed in to this Windows session: the owner of explorer.exe in
    this process's session. @{ Sid; Name } or $null (no Explorer shell).
    Testing: MYWINKIT_SIMULATE_SESSION_USER = same | other | a SID.
    #>
    $sim = $env:MYWINKIT_SIMULATE_SESSION_USER
    if ($sim) {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($sim -eq 'same') { return @{ Sid = $me.User.Value; Name = $me.Name } }
        if ($sim -eq 'other') { return @{ Sid = 'S-1-5-21-0-0-0-1001'; Name = 'PC\signed-in-user' } }
        return @{ Sid = $sim; Name = $sim }
    }
    try {
        $sess = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $ex = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $sess" -ErrorAction Stop | Select-Object -First 1)
        if (-not $ex.Count) { return $null }
        $o = Invoke-CimMethod -InputObject $ex[0] -MethodName GetOwner -ErrorAction Stop
        $s = Invoke-CimMethod -InputObject $ex[0] -MethodName GetOwnerSid -ErrorAction Stop
        if (-not $s.Sid) { return $null }
        $name = if ($o.Domain) { "$($o.Domain)\$($o.User)" } else { [string]$o.User }
        return @{ Sid = [string]$s.Sid; Name = $name }
    } catch { return $null }
}

function Test-KitDeElevate {
    <#
    Routing decision: run this package's installer at the signed-in user's
    normal rights? Yes when the catalogue marks it NoAdmin, the kit is
    elevated, and it is not Interactive (a de-elevated run cannot share the
    console). -IsAdmin injects the elevation state (tests).
    #>
    param([Parameter(Mandatory)]$Package, $IsAdmin = $null)
    if ($null -eq $IsAdmin) { $IsAdmin = Test-KitAdmin }
    return [bool]($Package.NoAdmin -and $IsAdmin -and -not $Package.Interactive)
}

function ConvertTo-KitPsLiteral([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

function Get-KitDeElevatedCommand {
    <#
    The PowerShell text a de-elevated task runs: the program with its
    arguments, all output to -OutFile, the exit code to -EcFile.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][string]$EcFile)
    $argText = (@($ArgumentList) | ForEach-Object { ConvertTo-KitPsLiteral ([string]$_) }) -join ' '
    return @"
`$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { `$o = @(& $(ConvertTo-KitPsLiteral $FilePath) $argText 2>&1 | ForEach-Object { "`$_" }); `$c = `$LASTEXITCODE; if (`$null -eq `$c) { `$c = 0 } } catch { `$o = @("`$_"); `$c = 1 }
[IO.File]::WriteAllLines($(ConvertTo-KitPsLiteral $OutFile), [string[]]`$o, (New-Object Text.UTF8Encoding `$false))
[IO.File]::WriteAllText($(ConvertTo-KitPsLiteral $EcFile), [string]`$c)
exit `$c
"@
}

function Invoke-KitDeElevated {
    <#
    .SYNOPSIS
        Run a program at the signed-in user's normal (medium) integrity from an
        elevated kit, wait for it, return @{ Ec; Out; Err; Started } like
        Invoke-KitProcess.
    .DESCRIPTION
        A one-shot scheduled task (Task Scheduler COM API, no module): principal
        = the session user (explorer.exe owner), logon type InteractiveToken,
        RunLevel LUA (limited). Task Scheduler starts it with that user's
        filtered token, the same token Explorer has, so the installer runs at
        medium integrity in the user's own profile. The task runs a hidden
        PowerShell that writes the output and exit code to temp files; the kit
        polls for them, then deletes the task. Not `runas /trustlevel`: that
        gives a restricted token, not a normal one.
        Testing: MYWINKIT_SIMULATE_DEELEVATE=ok|fail returns that result without
        creating a task.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 3600)
    $sim = $env:MYWINKIT_SIMULATE_DEELEVATE
    if ($sim -in 'ok', 'fail') {
        Write-KitLog "de-elevated (simulated $sim): $FilePath $($ArgumentList -join ' ')"
        $ec = 0; if ($sim -eq 'fail') { $ec = 1 }
        return @{ Ec = $ec; Out = @("simulated de-elevated run ($sim)"); Err = @(); Started = $true }
    }
    $user = Get-KitSessionUser
    if (-not $user) { return @{ Ec = 1; Out = @(); Err = @('no signed-in user found (Explorer is not running), cannot drop administrator rights'); Started = $false } }
    $file = $FilePath
    if (-not [IO.Path]::IsPathRooted($file)) { $c = Get-Command $file -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $file = $c.Path } }
    $tag = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $env:TEMP 'my-win-kit'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $outF = Join-Path $dir "deelevated-$tag.out"; $ecF = Join-Path $dir "deelevated-$tag.ec"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-KitDeElevatedCommand -FilePath $file -ArgumentList $ArgumentList -OutFile $outF -EcFile $ecF)))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
    # conhost --headless: no console window at all (also when Windows Terminal is the default terminal)
    $exe = $ps; $args2 = $psArgs
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if (Test-Path -LiteralPath $conhost) { $exe = $conhost; $args2 = "--headless `"$ps`" $psArgs" }
    $name = "my-win-kit-deelevated-$tag"
    Write-KitLog "de-elevated (task $name for $($user.Name), RunLevel LUA): $file $($ArgumentList -join ' ')"
    $folder = $null; $registered = $false
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $folder = $svc.GetFolder('\')
        $td = $svc.NewTask(0)
        $td.RegistrationInfo.Description = 'my-win-kit: one install at normal user rights (deleted after the run)'
        $td.Principal.UserId = $user.Name
        $td.Principal.LogonType = 3        # TASK_LOGON_INTERACTIVE_TOKEN: the user's own logon session
        $td.Principal.RunLevel = 0         # TASK_RUNLEVEL_LUA: limited (filtered) token, medium integrity
        $td.Settings.Enabled = $true
        $td.Settings.AllowDemandStart = $true
        $td.Settings.DisallowStartIfOnBatteries = $false
        $td.Settings.StopIfGoingOnBatteries = $false
        $td.Settings.ExecutionTimeLimit = 'PT2H'
        $td.Settings.Hidden = $true
        $act = $td.Actions.Create(0)       # TASK_ACTION_EXEC
        $act.Path = $exe
        $act.Arguments = $args2
        $act.WorkingDirectory = $dir
        $task = $folder.RegisterTaskDefinition($name, $td, 6, $user.Name, $null, 3)   # 6 = create or update; 3 = interactive token
        $registered = $true
        [void]$task.Run($null)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if (Test-Path -LiteralPath $ecF) { break }
            Start-Sleep -Milliseconds 400
            $t = $folder.GetTask($name)
            # 4 = running; 0x41301 = still running, 0x41303 = has not run yet
            if ($sw.Elapsed.TotalSeconds -gt 3 -and $t.State -ne 4 -and $t.LastTaskResult -notin 267009, 267011 -and -not (Test-Path -LiteralPath $ecF)) { Start-Sleep -Milliseconds 500; break }
        }
        $lines = @(); if (Test-Path -LiteralPath $outF) { try { $lines = @(Split-KitOutputLines ([IO.File]::ReadAllText($outF))) } catch {} }
        if (Test-Path -LiteralPath $ecF) {
            $ec = 1; [void][int]::TryParse(([IO.File]::ReadAllText($ecF)).Trim(), [ref]$ec)
            return @{ Ec = $ec; Out = $lines; Err = @(); Started = $true }
        }
        $last = 0; try { $last = [int]$folder.GetTask($name).LastTaskResult } catch {}
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { try { $folder.GetTask($name).Stop(0) } catch {}; return @{ Ec = 1; Out = $lines; Err = @("timed out after $TimeoutSec s"); Started = $true } }
        return @{ Ec = $(if ($last) { $last } else { 1 }); Out = $lines; Err = @('the de-elevated task ended without a result (task result 0x{0:X8})' -f $last); Started = $true }
    } catch {
        return @{ Ec = 1; Out = @(); Err = @("could not run at normal user rights: $($_.Exception.Message)"); Started = $false }
    } finally {
        if ($registered -and $folder) { try { $folder.DeleteTask($name, 0) } catch {} }
        Remove-Item -LiteralPath $outF, $ecF -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-KitChild {
    <# Invoke-KitProcess, or Invoke-KitDeElevated when -DeElevate (NoAdmin package, elevated kit). #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$DeElevate)
    if ($DeElevate) { return (Invoke-KitDeElevated -FilePath $FilePath -ArgumentList $ArgumentList) }
    return (Invoke-KitProcess -FilePath $FilePath -ArgumentList $ArgumentList)
}

# ================================================================ essentials (the loader sets these up at every start)
# Order (install.ps1): PowerShell 7, Windows Terminal (both in the loader), then the steps here:
# Claude Code CLI, CaskaydiaCove Nerd Font, Windows Terminal settings (config/terminal.json),
# Windows Terminal as the default terminal app. Each step checks first and does nothing when it
# is already done. One setting turns all of it off: autoInstallEssentials (legacy: autoInstallPwsh).
# Testing: MYWINKIT_SIMULATE_ESSENTIALS = absent | present | <steps that are present, e.g. claude,font>
# simulates detection and install (nothing on the PC is read or changed); MYWINKIT_SIMULATE_INSTALL=fail
# fails every simulated install, MYWINKIT_SIMULATE_FAIL=<steps> only those.

$script:EssentialSteps = @('claude', 'font', 'terminal-settings', 'default-terminal')
$script:EssentialLabels = @{ 'claude' = 'Claude Code'; 'font' = 'CaskaydiaCove Nerd Font'; 'terminal-settings' = 'Terminal settings'; 'default-terminal' = 'Default terminal app' }
# HKCU\Console\%%Startup values that make Windows Terminal (stable) the default terminal app
# (learn.microsoft.com/windows/terminal/group-policy; Preview and "let Windows decide" use other GUIDs).
$script:WtDelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
$script:WtDelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
$script:ConsoleStartupKey = 'HKCU:\Console\%%Startup'
$script:ClaudeInstallUrl = 'https://claude.ai/install.ps1'
$script:ClaudeExe = '%USERPROFILE%\.local\bin\claude.exe'
$script:NerdFontApi = 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest'
$script:NerdFontAsset = 'CascadiaCode.zip'
$script:NerdFontProbe = 'CaskaydiaCoveNerdFontMono-Regular.ttf'   # the face Terminal uses: "CaskaydiaCove Nerd Font Mono"
$script:FontsRegPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Get-KitAutoInstallEssentials {
    <# "Install essentials on start" (autoInstallEssentials; the older autoInstallPwsh still counts). #>
    return (Get-KitLocalSwitch -Name 'autoInstallEssentials' -Legacy 'autoInstallPwsh' -Default $true)
}

function Get-KitEssentialSim {
    <# '' = real run; 'present' | 'ok' | 'fail' = simulated (tests). #>
    param([Parameter(Mandatory)][string]$Name)
    $s = [string]$env:MYWINKIT_SIMULATE_ESSENTIALS
    if (-not $s) { return '' }
    $present = @()
    if ($s -eq 'present') { $present = $script:EssentialSteps } elseif ($s -ne 'absent') { $present = @($s -split '[,; ]+' | Where-Object { $_ }) }
    if ($present -contains $Name) { return 'present' }
    $fails = @([string]$env:MYWINKIT_SIMULATE_FAIL -split '[,; ]+' | Where-Object { $_ })
    if ($env:MYWINKIT_SIMULATE_INSTALL -eq 'fail' -or $fails -contains $Name) { return 'fail' }
    return 'ok'
}

# ---------------------------------------------------------------- JSON with comments (Windows Terminal's settings.json)

function Remove-KitJsonComments {
    <# Strip // and /* */ comments and trailing commas outside strings, so ConvertFrom-Json (5.1 too) reads JSONC. #>
    param([AllowEmptyString()][string]$Text)
    $sb = New-Object System.Text.StringBuilder ($Text.Length)
    $n = $Text.Length; $i = 0; $inStr = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq [char]'\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
            if ($c -eq [char]'"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq [char]'"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq [char]'/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq [char]'/') { while ($i -lt $n -and $Text[$i] -ne [char]"`n") { $i++ }; continue }
        if ($c -eq [char]'/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq [char]'*') { $e = $Text.IndexOf('*/', $i + 2); if ($e -lt 0) { $i = $n } else { $i = $e + 2 }; continue }
        if ($c -eq [char]',') {
            # trailing comma: only whitespace before the next } or ]
            $j = $i + 1; while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            if ($j -lt $n -and ($Text[$j] -eq [char]'}' -or $Text[$j] -eq [char]']')) { $i++; continue }
        }
        [void]$sb.Append($c); $i++
    }
    return $sb.ToString()
}

function ConvertFrom-KitJsoncText {
    <# JSON with comments -> ordered hashtables / arrays. Throws when it does not parse. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text.Trim()) { throw 'empty file' }
    $t = $Text.TrimStart([char]0xFEFF)
    # fast path: Terminal writes plain JSON itself; the character scan (slow in 5.1) only when needed
    if ($t -notmatch '//|/\*|,\s*[}\]]') { try { return (ConvertFrom-KitJsonText $t) } catch {} }
    return (ConvertFrom-KitJsonText (Remove-KitJsonComments $t))
}

function ConvertTo-KitJsonPretty {
    <# Indented JSON (4 spaces, ASCII with \uXXXX escapes), the layout Windows Terminal writes itself. #>
    param($Value, [int]$Level = 0)
    $ind = '    ' * ($Level + 1); $end = '    ' * $Level
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.PSBase.Count -eq 0) { return '{}' }
        $parts = @(foreach ($k in @($Value.PSBase.Keys)) { $ind + (ConvertTo-KitJsonValue ([string]$k)) + ': ' + (ConvertTo-KitJsonPretty -Value $Value[$k] -Level ($Level + 1)) })
        return "{`n" + ($parts -join ",`n") + "`n$end}"
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        if (@($Value).Count -eq 0) { return '[]' }
        $parts = @(foreach ($x in @($Value)) { $ind + (ConvertTo-KitJsonPretty -Value $x -Level ($Level + 1)) })
        return "[`n" + ($parts -join ",`n") + "`n$end]"
    }
    return (ConvertTo-KitJsonValue $Value)
}

function Copy-KitJsonValue($v) {
    <# Deep copy of parsed JSON (ordered hashtables / arrays), so merging never changes the source. #>
    if ($v -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in @($v.PSBase.Keys)) { $h[$k] = Copy-KitJsonValue $v[$k] }; return $h }
    if ($v -is [System.Collections.IList] -and $v -isnot [string]) { return , @(foreach ($x in @($v)) { Copy-KitJsonValue $x }) }
    return $v
}

function Merge-KitJsonInto {
    <# Set every key of -Source on -Target (objects merge key by key, anything else is replaced). Adds changed paths to -Changes. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Target, [Parameter(Mandatory)][System.Collections.IDictionary]$Source, [string]$Prefix, [System.Collections.Generic.List[string]]$Changes)
    foreach ($k in @($Source.PSBase.Keys)) {
        $sv = $Source[$k]; $path = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
        if ($sv -is [System.Collections.IDictionary] -and $Target.Contains($k) -and $Target[$k] -is [System.Collections.IDictionary]) {
            Merge-KitJsonInto -Target $Target[$k] -Source $sv -Prefix $path -Changes $Changes
            continue
        }
        if (-not $Target.Contains($k) -or (ConvertTo-KitJsonValue $Target[$k]) -ne (ConvertTo-KitJsonValue $sv)) {
            $Target[$k] = Copy-KitJsonValue $sv
            if ($null -ne $Changes) { $Changes.Add($path) }
        }
    }
}

# ---------------------------------------------------------------- Windows Terminal settings

function Get-KitTerminalSettingsPath {
    <#
    Windows Terminal's settings.json for this user: the Store/winget package
    (LocalState), or the unpackaged copy when only that one exists.
    Testing: MYWINKIT_WT_SETTINGS = another file.
    #>
    if ($env:MYWINKIT_WT_SETTINGS) { return $env:MYWINKIT_WT_SETTINGS }
    $pkg = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $unp = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    if (-not (Test-Path -LiteralPath $pkg) -and (Test-Path -LiteralPath $unp)) { return $unp }
    return $pkg
}

function Get-KitTerminalConfig {
    <#
    The desired Terminal settings (config/terminal.json): cache -> bundled copy
    (-Online: GitHub first, like the other config files). $null when none.
    #>
    param([Parameter(Mandatory)][string]$KitRoot, [switch]$Online)
    if ($Online -or -not $script:Config.ContainsKey('terminal.json')) { Read-KitConfigFile -Name 'terminal.json' -KitRoot $KitRoot -Offline:(-not $Online) }
    $d = $script:Config['terminal.json']
    if ($d -is [System.Collections.IDictionary] -and $d.Contains('defaultProfile')) { return $d }
    return $null
}

function Resolve-KitTerminalStartDir {
    <#
    Starting folder for every Terminal profile: -Prefer (environment variables
    expanded; default %OneDrive%\.playground) when that folder exists, else
    -Fallback (default: the kit's dev folder, D:\dev\git or C:\dev\git), created
    when missing unless -DryRun. @{ Path; Source = prefer|fallback|home; Created }.
    #>
    param([string]$Prefer = '%OneDrive%\.playground', [string]$Fallback, [switch]$DryRun)
    if (-not $PSBoundParameters.ContainsKey('Fallback')) { $Fallback = Get-KitDevFolderPath }
    $p = [Environment]::ExpandEnvironmentVariables($Prefer)
    if ($p -and $p -notmatch '%' -and (Test-Path -LiteralPath $p -PathType Container)) { return @{ Path = $p; Source = 'prefer'; Created = $false } }
    if ($Fallback) {
        if (Test-Path -LiteralPath $Fallback -PathType Container) { return @{ Path = $Fallback; Source = 'fallback'; Created = $false } }
        if ($DryRun) { return @{ Path = $Fallback; Source = 'fallback'; Created = $false } }
        try { New-Item -ItemType Directory -Path $Fallback -Force -ErrorAction Stop | Out-Null; return @{ Path = $Fallback; Source = 'fallback'; Created = $true } } catch {}
    }
    return @{ Path = '%USERPROFILE%'; Source = 'home'; Created = $false }
}

function Merge-KitTerminalSettings {
    <#
    .SYNOPSIS
        Merge the desired Terminal settings (config/terminal.json) into a
        settings.json. Returns @{ Status = done|current|dryrun|failed; Detail;
        Path; Backup; Changes }.
    .DESCRIPTION
        No file yet (Terminal never started): a new one with the desired
        settings (Terminal adds its generated profiles at its first start).
        Otherwise: sets the globals and profiles.defaults, adds or updates the
        profiles by guid, sets defaultProfile and the key bindings (by id; an
        entry with the same keys is replaced), and keeps everything else
        (other profiles, schemes, actions). Comments are allowed when reading.
        Writes only when something changes, after a backup to
        settings.json.bak-my-win-kit-<date>. A file that does not parse is
        never overwritten.
        -StartingDirectory goes into profiles.defaults. -NoFont leaves the font
        out (the Nerd Font is not installed yet, so Terminal would warn);
        -NoDefaultProfile keeps the current default profile (no PowerShell 7).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Desired,
        [string]$StartingDirectory = '',
        [switch]$NoFont,
        [switch]$NoDefaultProfile,
        [switch]$DryRun
    )
    $res = @{ Status = 'failed'; Detail = ''; Path = $Path; Backup = ''; Changes = @() }
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $doc = $null
    if ($exists) {
        try { $doc = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($Path)) } catch { $res.Detail = "settings.json does not parse, left alone: $($_.Exception.Message)"; return $res }
        if ($doc -isnot [System.Collections.IDictionary]) { $res.Detail = 'settings.json is not a JSON object, left alone'; return $res }
    } else {
        $doc = [ordered]@{ '$help' = 'https://aka.ms/terminal-documentation'; '$schema' = 'https://aka.ms/terminal-profiles-schema' }
    }
    $before = if ($exists) { ConvertTo-KitJsonPretty $doc } else { '' }
    $changes = New-Object 'System.Collections.Generic.List[string]'

    # globals
    if ($Desired['globals'] -is [System.Collections.IDictionary]) { Merge-KitJsonInto -Target $doc -Source $Desired['globals'] -Changes $changes }
    # profiles: { defaults, list } (an old-style plain list is wrapped)
    $prof = $doc['profiles']
    if ($prof -is [System.Collections.IList]) { $prof = [ordered]@{ defaults = [ordered]@{}; list = @($prof) }; $doc['profiles'] = $prof; $changes.Add('profiles') }
    elseif ($prof -isnot [System.Collections.IDictionary]) { $prof = [ordered]@{ defaults = [ordered]@{}; list = @() }; $doc['profiles'] = $prof; $changes.Add('profiles') }
    if ($prof['defaults'] -isnot [System.Collections.IDictionary]) { $prof['defaults'] = [ordered]@{} }
    if ($prof['list'] -isnot [System.Collections.IList]) { $prof['list'] = @() }
    $defs = [ordered]@{}
    if ($Desired['profileDefaults'] -is [System.Collections.IDictionary]) { $defs = Copy-KitJsonValue $Desired['profileDefaults'] }
    if ($NoFont -and $defs.Contains('font')) { $defs.Remove('font') }
    if ($StartingDirectory) { $defs['startingDirectory'] = $StartingDirectory }
    Merge-KitJsonInto -Target $prof['defaults'] -Source $defs -Prefix 'profiles.defaults' -Changes $changes
    $list = New-Object System.Collections.ArrayList
    foreach ($x in @($prof['list'])) { [void]$list.Add($x) }
    foreach ($want in @($Desired['profiles'])) {
        if ($want -isnot [System.Collections.IDictionary] -or -not $want['guid']) { continue }
        $hit = $null
        foreach ($x in $list) { if ($x -is [System.Collections.IDictionary] -and ([string]$x['guid']) -eq ([string]$want['guid'])) { $hit = $x; break } }
        if ($hit) { Merge-KitJsonInto -Target $hit -Source $want -Prefix "profile '$($want['name'])'" -Changes $changes }
        else { [void]$list.Insert(0, (Copy-KitJsonValue $want)); $changes.Add("profile '$($want['name'])' added") }
    }
    $prof['list'] = @($list.ToArray())
    # default profile
    if ($Desired['defaultProfile'] -and -not $NoDefaultProfile -and [string]$doc['defaultProfile'] -ne [string]$Desired['defaultProfile']) { $doc['defaultProfile'] = [string]$Desired['defaultProfile']; $changes.Add('defaultProfile') }
    # key bindings: by id; an entry with the same keys but another id is replaced
    $kbs = New-Object System.Collections.ArrayList
    if ($doc['keybindings'] -is [System.Collections.IList]) { foreach ($x in @($doc['keybindings'])) { [void]$kbs.Add($x) } }
    foreach ($want in @($Desired['keybindings'])) {
        if ($want -isnot [System.Collections.IDictionary]) { continue }
        $wantText = ConvertTo-KitJsonValue $want
        $exact = $false; $drop = @()
        foreach ($x in $kbs) {
            if ($x -isnot [System.Collections.IDictionary]) { continue }
            if ((ConvertTo-KitJsonValue $x) -eq $wantText) { $exact = $true; continue }
            if (([string]$x['id'] -and [string]$x['id'] -eq [string]$want['id']) -or ([string]$x['keys'] -and [string]$x['keys'] -eq [string]$want['keys'])) { $drop += , $x }
        }
        foreach ($x in $drop) { $kbs.Remove($x) }
        if (-not $exact) { [void]$kbs.Add((Copy-KitJsonValue $want)) }
        if ($drop.Count -or -not $exact) { $changes.Add("keybinding $($want['keys'])") }
    }
    if ($kbs.Count -or $doc.Contains('keybindings')) { $doc['keybindings'] = @($kbs.ToArray()) }

    $after = ConvertTo-KitJsonPretty $doc
    $res.Changes = @($changes)
    if ($exists -and $after -eq $before) { $res.Status = 'current'; $res.Detail = 'already as configured'; return $res }
    $what = if ($exists) { ($changes | Select-Object -Unique) -join ', ' } else { 'new settings.json' }
    if ($DryRun) { $res.Status = 'dryrun'; $res.Detail = "would update $($Path): $what"; return $res }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($exists) {
            $bak = "$Path.bak-my-win-kit-$(Get-Date -Format 'yyyy-MM-dd')"
            if (Test-Path -LiteralPath $bak) { $bak = "$Path.bak-my-win-kit-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')" }
            Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop
            $res.Backup = $bak
        }
        [IO.File]::WriteAllText($Path, $after + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $res.Status = 'done'; $res.Detail = $(if ($exists) { "updated: $what" } else { 'created settings.json' })
    } catch { $res.Status = 'failed'; $res.Detail = "could not write $($Path): $($_.Exception.Message)" }
    return $res
}

# ---------------------------------------------------------------- Windows Terminal as the default terminal app

function Get-KitRegistryAccess {
    <# Reader/writer for one registry key (PowerShell path); tests pass their own pair instead. #>
    param([Parameter(Mandatory)][string]$Key)
    $regKey = $Key   # captured by the closures below
    return @{
        Read = { param($Name) try { return [string](Get-ItemProperty -LiteralPath $regKey -Name $Name -ErrorAction Stop).$Name } catch { return '' } }.GetNewClosure()
        Write = { param($Name, $Value) if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }; New-ItemProperty -LiteralPath $regKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null }.GetNewClosure()
    }
}

function Set-KitDefaultTerminal {
    <#
    Make Windows Terminal the default terminal app for this user
    (HKCU\Console\%%Startup DelegationConsole + DelegationTerminal). Call it
    only when Terminal is installed. -Registry = @{ Read; Write } scriptblocks
    (tests). @{ Status = done|current|dryrun|failed; Detail }.
    #>
    param([switch]$DryRun, [hashtable]$Registry)
    if (-not $Registry) { $Registry = Get-KitRegistryAccess -Key $script:ConsoleStartupKey }
    $want = [ordered]@{ DelegationConsole = $script:WtDelegationConsole; DelegationTerminal = $script:WtDelegationTerminal }
    $todo = @(foreach ($k in @($want.Keys)) { if ((& $Registry.Read $k) -ne $want[$k]) { $k } })
    if (-not $todo.Count) { return @{ Status = 'current'; Detail = 'Windows Terminal is already the default terminal app' } }
    if ($DryRun) { return @{ Status = 'dryrun'; Detail = "would set $($todo -join ' + ') under HKCU\Console\%%Startup (Windows Terminal)" } }
    try {
        foreach ($k in $todo) { & $Registry.Write $k $want[$k] }
        return @{ Status = 'done'; Detail = 'Windows Terminal is now the default terminal app' }
    } catch { return @{ Status = 'failed'; Detail = "could not set the default terminal: $($_.Exception.Message)" } }
}

# ---------------------------------------------------------------- CaskaydiaCove Nerd Font (Cascadia Code Nerd Font)

function Test-KitNerdFont {
    <#
    The CaskaydiaCove Nerd Font Mono face is installed (machine or this user):
    its file in a fonts folder, or a Fonts registry entry naming it. Returns
    where ('' = not installed). -FontDirs / -RegistryNames inject both (tests).
    #>
    param([string[]]$FontDirs, [string[]]$RegistryNames)
    if (-not $PSBoundParameters.ContainsKey('FontDirs')) { $FontDirs = @((Join-Path $env:windir 'Fonts'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts')) }
    foreach ($d in @($FontDirs)) { if ($d -and (Test-Path -LiteralPath (Join-Path $d $script:NerdFontProbe) -PathType Leaf)) { return (Join-Path $d $script:NerdFontProbe) } }
    if (-not $PSBoundParameters.ContainsKey('RegistryNames')) {
        $RegistryNames = @()
        foreach ($hive in 'HKLM:', 'HKCU:') { try { $RegistryNames += @((Get-Item -LiteralPath "$hive\$($script:FontsRegPath)" -ErrorAction Stop).GetValueNames()) } catch {} }
    }
    foreach ($n in @($RegistryNames)) { if ("$n" -match '^CaskaydiaCove Nerd Font Mono\b') { return "registry: $n" } }
    return ''
}

function Get-KitNerdFontRelease {
    <#
    From the GitHub API answer for ryanoasis/nerd-fonts releases/latest (JSON
    text): @{ Tag; Url; Size; Sha256 (the asset's published digest, '' if
    none); ChecksumUrl (the release's SHA-256.txt, '' if none) }. Throws when
    the release has no CascadiaCode.zip.
    #>
    param([Parameter(Mandatory)][string]$Json)
    $rel = $Json | ConvertFrom-Json
    $asset = @($rel.assets | Where-Object { $_.name -eq $script:NerdFontAsset } | Select-Object -First 1)
    if (-not $asset.Count) { throw "no $($script:NerdFontAsset) in release $($rel.tag_name)" }
    $a = $asset[0]
    $sha = ''
    if ($a.PSObject.Properties['digest'] -and "$($a.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1].ToLowerInvariant() }
    $sum = @($rel.assets | Where-Object { $_.name -eq 'SHA-256.txt' } | Select-Object -First 1)
    return @{ Tag = [string]$rel.tag_name; Url = [string]$a.browser_download_url; Size = [long]$a.size; Sha256 = $sha; ChecksumUrl = $(if ($sum.Count) { [string]$sum[0].browser_download_url } else { '' }) }
}

function Get-KitSha256FromList {
    <# The hash for -Name in a sha256sum-style list ("<hash>  <file>" per line), or ''. #>
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Name)
    foreach ($l in (Split-KitOutputLines $Text)) { if ($l -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Name) { return $Matches[1].ToLowerInvariant() } }
    return ''
}

function Get-KitFileSha256 {
    <# SHA-256 of a file through .NET (Get-FileHash can fail to load in 5.1 under an inherited PowerShell 7 module path). #>
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead($Path)
    try { return (-join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') })) } finally { $fs.Dispose(); $sha.Dispose() }
}

function ConvertTo-KitFontRegName {
    <# 'CaskaydiaCoveNerdFontMono-BoldItalic.ttf' -> 'CaskaydiaCove Nerd Font Mono Bold Italic (TrueType)'. #>
    param([Parameter(Mandatory)][string]$FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $fam, $style = $base -split '-', 2
    $fam = ($fam -replace 'NerdFont', ' Nerd Font ').Trim() -replace '\s+', ' '
    $style = ([regex]::Replace([string]$style, '(?<=[a-z])(?=[A-Z])', ' ')).Trim()
    if ($style -eq 'Regular') { $style = '' }
    return ("$fam $style".Trim() + ' (TrueType)')
}

function Install-KitNerdFont {
    <#
    .SYNOPSIS
        Install CaskaydiaCove Nerd Font (Cascadia Code patched by Nerd Fonts)
        unless it is already there. @{ Status = done|current|dryrun|failed; Detail }.
    .DESCRIPTION
        Source: CascadiaCode.zip from the latest ryanoasis/nerd-fonts GitHub
        release (resolved through the GitHub API, never a fixed version). The
        download must match the SHA-256 GitHub publishes for the asset
        (`digest`), else the release's SHA-256.txt; without either it is not
        installed. Installs the CaskaydiaCoveNerdFont and ...Mono TTFs: for all
        users when elevated (C:\Windows\Fonts + HKLM Fonts), else for this user
        (%LOCALAPPDATA%\Microsoft\Windows\Fonts + HKCU Fonts).
        Tests: -ReleaseJson / -ZipPath skip the network, -FontDir and
        -Registry (@{ Read; Write }) redirect the install.
    #>
    param([switch]$DryRun, [string]$ReleaseJson, [string]$ZipPath, [string]$FontDir, [hashtable]$Registry, $IsAdmin = $null, [scriptblock]$OnStatus)
    $notify = $OnStatus
    function Send-Note([string]$t) { if ($notify) { try { & $notify $t } catch {} } }
    if ($null -eq $IsAdmin) { $IsAdmin = Test-KitAdmin }
    $scope = if ($IsAdmin) { 'all users' } else { 'this user' }
    $found = if ($FontDir) { Test-KitNerdFont -FontDirs @($FontDir) -RegistryNames @() } else { Test-KitNerdFont }
    if ($found) { return @{ Status = 'current'; Detail = "already installed ($found)" } }
    if ($DryRun) { return @{ Status = 'dryrun'; Detail = "would download $($script:NerdFontAsset) from the latest ryanoasis/nerd-fonts release, check its SHA-256 and install it for $scope" } }
    $work = Join-Path $env:TEMP ('my-win-kit-font-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        if (-not $ZipPath) {
            Send-Note 'looking up the latest Nerd Fonts release'
            if (-not $ReleaseJson) { $ReleaseJson = [string](Invoke-WebRequest -Uri $script:NerdFontApi -UseBasicParsing -TimeoutSec 20 -UserAgent $script:UA -Headers @{ Accept = 'application/vnd.github+json' }).Content }
            $rel = Get-KitNerdFontRelease -Json $ReleaseJson
            $want = $rel.Sha256
            if (-not $want -and $rel.ChecksumUrl) { $want = Get-KitSha256FromList -Text ([string](Invoke-WebRequest -Uri $rel.ChecksumUrl -UseBasicParsing -TimeoutSec 20 -UserAgent $script:UA).Content) -Name $script:NerdFontAsset }
            if (-not $want) { return @{ Status = 'failed'; Detail = "no SHA-256 published for $($script:NerdFontAsset) in $($rel.Tag) - not installed" } }
            $ZipPath = Join-Path $work $script:NerdFontAsset
            Send-Note "downloading $($script:NerdFontAsset) $($rel.Tag) ($([math]::Round($rel.Size / 1MB)) MB)"
            Write-KitLog "font: $($rel.Url) (sha256 $want)"
            $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $rel.Url -OutFile $ZipPath -UseBasicParsing -TimeoutSec 600 -UserAgent $script:UA } finally { $ProgressPreference = $pp }
            $got = Get-KitFileSha256 -Path $ZipPath
            if ($got -ne $want) { return @{ Status = 'failed'; Detail = "download does not match the published SHA-256 (got $got) - not installed" } }
        }
        Send-Note "installing CaskaydiaCove Nerd Font for $scope"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $files = @()
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.Name -notmatch '^CaskaydiaCoveNerdFont(Mono)?-[A-Za-z]+\.ttf$') { continue }
                $dest = Join-Path $work $e.Name   # leaf name only: no paths from the archive
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                $files += $dest
            }
        } finally { $zip.Dispose() }
        if (-not $files.Count) { return @{ Status = 'failed'; Detail = "no CaskaydiaCove Nerd Font files in $($script:NerdFontAsset)" } }
        $machine = [bool]$IsAdmin
        $target = $FontDir
        if (-not $target) { $target = if ($machine) { Join-Path $env:windir 'Fonts' } else { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts' } }
        if (-not $Registry -and $FontDir) { $Registry = @{ Read = { '' }; Write = { } } }   # a test folder never registers in the real registry
        if (-not $Registry) { $Registry = Get-KitRegistryAccess -Key $(if ($machine) { "HKLM:\$($script:FontsRegPath)" } else { "HKCU:\$($script:FontsRegPath)" }) }
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        $n = 0
        foreach ($f in $files) {
            $leaf = Split-Path -Leaf $f
            $dest = Join-Path $target $leaf
            if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $f -Destination $dest -ErrorAction Stop }
            # machine fonts are registered by file name, per-user fonts by full path
            & $Registry.Write (ConvertTo-KitFontRegName $leaf) $(if ($machine -and -not $FontDir) { $leaf } else { $dest })
            $n++
        }
        if (-not $FontDir) {
            # usable without signing out: load into this session and tell running apps
            try {
                if (-not ('MyWinKit.Fonts' -as [type])) {
                    Add-Type -Namespace MyWinKit -Name Fonts -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr result);
'@
                }
                foreach ($f in $files) { [void][MyWinKit.Fonts]::AddFontResource((Join-Path $target (Split-Path -Leaf $f))) }
                $r = [UIntPtr]::Zero
                [void][MyWinKit.Fonts]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)
            } catch {}
        }
        $ok = if ($FontDir) { Test-KitNerdFont -FontDirs @($FontDir) -RegistryNames @() } else { Test-KitNerdFont }
        if (-not $ok) { return @{ Status = 'failed'; Detail = "copied $n font files, but $($script:NerdFontProbe) is still not found" } }
        return @{ Status = 'done'; Detail = "installed $n font files for $scope" }
    } catch {
        return @{ Status = 'failed'; Detail = "font install failed: $($_.Exception.Message)" }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- Claude Code CLI

function Test-KitClaudeCode {
    <# claude.exe (Claude Code's native installer: %USERPROFILE%\.local\bin) or claude on PATH. Path or ''. #>
    $p = [Environment]::ExpandEnvironmentVariables($script:ClaudeExe)
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    $c = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Path }
    return ''
}

function Install-KitClaudeCode {
    <#
    Claude Code CLI with Anthropic's official installer (irm
    https://claude.ai/install.ps1 | iex in a child PowerShell) unless claude is
    already there. It installs into this user's profile (%USERPROFILE%\.local\bin)
    and needs no administrator rights, so an elevated kit runs it at the
    signed-in user's normal rights (Invoke-KitDeElevated); if that cannot start,
    it runs in the kit's own (elevated, same user) context.
    @{ Status = done|current|dryrun|failed; Detail }.
    #>
    param([switch]$DryRun, [scriptblock]$OnStatus)
    $have = Test-KitClaudeCode
    if ($have) { return @{ Status = 'current'; Detail = "already installed ($have)" } }
    $de = Test-KitAdmin
    if ($DryRun) { return @{ Status = 'dryrun'; Detail = "would run irm $($script:ClaudeInstallUrl) | iex in a child PowerShell$(if ($de) { ' at normal user rights' })" } }
    if ($OnStatus) { try { & $OnStatus 'installing Claude Code (official installer, about a minute)' } catch {} }
    $argList = Get-KitRemoteScriptArgs -Url $script:ClaudeInstallUrl
    Write-KitLog "essentials: Claude Code: irm $($script:ClaudeInstallUrl) | iex$(if ($de) { '  (de-elevated)' })"
    $r = Invoke-KitChild -FilePath 'powershell.exe' -ArgumentList $argList -DeElevate:$de
    if ($de -and -not $r.Started) {
        Write-KitLog "  could not drop administrator rights ($(@($r.Err) -join ' ')) - running the installer in this (same user) context"
        $r = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList $argList
    }
    $out = @(@($r.Out) + @($r.Err))
    foreach ($l in ($out | Where-Object { "$_".Trim() } | Select-Object -Last 15)) { Write-KitLog "  | $l" }
    Write-KitLog "  exit $($r.Ec)"
    Update-KitPath
    $have = Test-KitClaudeCode
    if ($have) {
        $v = ''
        try { $vr = Invoke-KitProcess -FilePath $have -ArgumentList @('--version'); if ($vr.Started) { $v = Get-KitVersionText ((@($vr.Out) + @($vr.Err)) -join ' ') } } catch {}
        return @{ Status = 'done'; Detail = $(if ($v) { "installed $v" } else { 'installed' }) }
    }
    $why = Get-KitFailLine -Out $out
    if (-not $why) { $why = "installer exit $($r.Ec)" }
    return @{ Status = 'failed'; Detail = $why }
}

# ---------------------------------------------------------------- one essentials step (the loader calls these in order)

function Invoke-KitEssential {
    <#
    .SYNOPSIS
        Run one essentials step: claude | font | terminal-settings | default-terminal.
        Returns @{ Name; Label; Status = done|current|dryrun|failed|skipped; Detail }.
        Never throws.
    .PARAMETER TerminalPresent
        Windows Terminal is installed (terminal-settings and default-terminal skip otherwise).
    .PARAMETER PwshPresent
        PowerShell 7 is installed (else the Claude Code profile is added but not made the default).
    #>
    param([Parameter(Mandatory)][ValidateSet('claude', 'font', 'terminal-settings', 'default-terminal')][string]$Name,
        [string]$KitRoot, [switch]$DryRun, [bool]$TerminalPresent = $true, [bool]$PwshPresent = $true, [scriptblock]$OnStatus)
    $label = $script:EssentialLabels[$Name]
    $out = @{ Name = $Name; Label = $label; Status = 'failed'; Detail = '' }
    $sim = Get-KitEssentialSim -Name $Name
    try {
        if ($Name -in 'terminal-settings', 'default-terminal' -and -not $TerminalPresent) { $out.Status = 'skipped'; $out.Detail = 'Windows Terminal is not installed'; return $out }
        if ($sim) {
            switch ($sim) {
                'present' { $out.Status = 'current'; $out.Detail = 'already there (simulated)' }
                'fail'    { $out.Status = 'failed'; $out.Detail = 'simulated failure' }
                default   { if ($DryRun) { $out.Status = 'dryrun'; $out.Detail = 'would set it up (simulated)' } else { $out.Status = 'done'; $out.Detail = 'simulated' } }
            }
            return $out
        }
        $r = $null
        switch ($Name) {
            'claude' { $r = Install-KitClaudeCode -DryRun:$DryRun -OnStatus $OnStatus }
            'font' { $r = Install-KitNerdFont -DryRun:$DryRun -OnStatus $OnStatus }
            'default-terminal' { $r = Set-KitDefaultTerminal -DryRun:$DryRun }
            'terminal-settings' {
                $cfg = $null; if ($KitRoot) { $cfg = Get-KitTerminalConfig -KitRoot $KitRoot }
                if (-not $cfg) { $r = @{ Status = 'skipped'; Detail = 'no config/terminal.json' }; break }
                $sd = $cfg['startingDirectory']; $prefer = '%OneDrive%\.playground'
                if ($sd -is [System.Collections.IDictionary] -and $sd['prefer']) { $prefer = [string]$sd['prefer'] }
                $start = Resolve-KitTerminalStartDir -Prefer $prefer -DryRun:$DryRun
                $m = Merge-KitTerminalSettings -Path (Get-KitTerminalSettingsPath) -Desired $cfg -StartingDirectory $start.Path -NoFont:(-not (Test-KitNerdFont)) -NoDefaultProfile:(-not $PwshPresent) -DryRun:$DryRun
                $r = @{ Status = $m.Status; Detail = $m.Detail }
                if ($m.Backup) { $r.Detail += " (backup: $($m.Backup))" }
                Write-KitRunLog "essentials: Terminal starting folder $($start.Path) ($($start.Source)$(if ($start.Created) { ', created' }))"
            }
        }
        $out.Status = [string]$r.Status; $out.Detail = [string]$r.Detail
    } catch { $out.Status = 'failed'; $out.Detail = "$($_.Exception.Message)" }
    return $out
}

# ---------------------------------------------------------------- update everything (kit apps + the rest of the PC)

function ConvertFrom-KitWingetUpgradeText {
    <#
    Rows of `winget upgrade` output: @{ Name; Id; Version; Available; Source }.
    Reads the first table only: the "require explicit targeting" table after
    it and the "N upgrades available" footer are left out.
    #>
    param([string[]]$Lines = @())
    $Lines = @($Lines)
    $sep = -1
    for ($j = 0; $j -lt $Lines.Count; $j++) { if ("$($Lines[$j])" -match '^-{4,}') { $sep = $j; break } }
    if ($sep -lt 1) { return @() }
    $hdr = "$($Lines[$sep - 1])"
    $iId = $hdr.IndexOf('Id'); $iVer = $hdr.IndexOf('Version'); $iAv = $hdr.IndexOf('Available'); $iSrc = $hdr.IndexOf('Source')
    if ($iId -lt 1 -or $iVer -le $iId -or $iAv -le $iVer) { return @() }
    $rows = @()
    for ($j = $sep + 1; $j -lt $Lines.Count; $j++) {
        $ln = "$($Lines[$j])"
        if (-not $ln.Trim()) { break }                                    # end of the first table
        if ($ln -match '^\s*\d+\s+(upgrades?|packages?)\b') { break }      # footer
        if ($ln.Length -le $iAv) { continue }
        $end = if ($iSrc -gt $iAv -and $ln.Length -gt $iSrc) { $iSrc } else { $ln.Length }
        $rows += [pscustomobject]@{
            Name = $ln.Substring(0, $iId).Trim(); Id = $ln.Substring($iId, $iVer - $iId).Trim()
            Version = $ln.Substring($iVer, $iAv - $iVer).Trim(); Available = $ln.Substring($iAv, $end - $iAv).Trim()
            Source = $(if ($iSrc -gt $iAv -and $ln.Length -gt $iSrc) { $ln.Substring($iSrc).Trim() } else { '' })
        }
    }
    return $rows
}

function Get-KitWingetPins {
    <# Ids pinned with `winget pin` (Update everything never touches them). #>
    if (-not (Test-KitWinget)) { return @() }
    return @(Get-KitWingetRows @(Get-KitWingetRaw @('pin', 'list', '--accept-source-agreements', '--disable-interactivity')) | ForEach-Object Id)
}

function Get-KitCatalogUpdateSet {
    <#
    Installed catalogue apps to update: a newer version is known
    (Get-KitUpdates), or the tool updates itself (script with a native
    updater such as `claude update`, npm tools: winget does not list those).
    Interactive and POST items are left out (they need a person).
    #>
    param([Parameter(Mandatory)][hashtable]$Installed, [hashtable]$Updates = @{}, [object[]]$Packages = $script:Catalog)
    return @($Packages | Where-Object {
        $Installed.ContainsKey($_.Id) -and -not $_.Interactive -and $_.Group -ne 'POST' -and
        ($Updates.ContainsKey($_.Id) -or ($_.Method -eq 'script' -and $_.Update) -or $_.Method -eq 'npm')
    })
}

function New-KitPcUpgrade {
    <# A `winget upgrade` row outside the catalogue as a runnable item (Method winget-upgrade, negative Id, group PC). #>
    param([Parameter(Mandatory)]$Row, [int]$Id, [int]$GroupOrder = 999)
    $p = ConvertTo-KitPackage @{ Id = $Id; Name = $Row.Name; Group = 'PC'; On = $true; Method = 'winget-upgrade'; Ref = $Row.Id; Desc = 'other app on this PC (winget upgrade)' } @{ PC = $GroupOrder } 'pc'
    $p | Add-Member -NotePropertyName Current -NotePropertyValue ([string]$Row.Version)
    $p | Add-Member -NotePropertyName Latest -NotePropertyValue ([string]$Row.Available)
    $p | Add-Member -NotePropertyName Source -NotePropertyValue ([string]$Row.Source)
    return $p
}

function Get-KitUpdateAllPlan {
    <#
    .SYNOPSIS
        "Update everything": @{ Kit; Other; Run; Excluded }.
    .DESCRIPTION
        Kit   = Get-KitCatalogUpdateSet (catalogue apps, AI tools included, each
                through its own method).
        Other = every other row of `winget upgrade` (apps on the PC that are not
                in the catalogue), as winget-upgrade items. Left out: rows whose Id
                is a catalogue winget/Store/fallback ID, pinned packages (`winget
                pin`), unknown or ranged versions, truncated Ids.
        -UpgradeLines / -Pinned inject winget output (tests); by default the
        lines of the last Get-KitUpdates are reused, else `winget upgrade` runs.
    #>
    param([Parameter(Mandatory)][hashtable]$Installed, [hashtable]$Updates = @{}, [string[]]$UpgradeLines = $null, [string[]]$Pinned = $null, [object[]]$Packages = $script:Catalog)
    $kit = @(Get-KitCatalogUpdateSet -Installed $Installed -Updates $Updates -Packages $Packages)
    if ($null -eq $UpgradeLines) {
        if ($null -ne $script:LastUpgradeRaw) { $UpgradeLines = @($script:LastUpgradeRaw) }
        elseif (Test-KitWinget) { $UpgradeLines = @(Get-KitWingetRaw @('upgrade', '--accept-source-agreements', '--disable-interactivity')) }
        else { $UpgradeLines = @() }
    }
    if ($null -eq $Pinned) { $Pinned = @(Get-KitWingetPins) }
    $kitRefs = @{}
    foreach ($p in $Packages) {
        if ($p.Method -in 'winget', 'msstore' -and $p.Ref) { $kitRefs[$p.Ref.ToLowerInvariant()] = $true }
        if ($p.Fallback) { $kitRefs[([string]$p.Fallback).ToLowerInvariant()] = $true }
    }
    $pinSet = @{}; foreach ($x in @($Pinned)) { if ($x) { $pinSet[$x.ToLowerInvariant()] = $true } }
    $others = @(); $excluded = @(); $n = 0
    $gOrder = @($script:Groups).Count + 1
    foreach ($row in @(ConvertFrom-KitWingetUpgradeText -Lines $UpgradeLines | Sort-Object Name)) {
        $key = $row.Id.ToLowerInvariant()
        $why = ''
        if ($kitRefs.ContainsKey($key)) { $why = 'in the catalogue' }
        elseif ($pinSet.ContainsKey($key)) { $why = 'pinned' }
        elseif (-not $row.Version -or $row.Version -match '^(?i)(unknown|<|>)') { $why = 'unknown version' }
        elseif ($row.Id -match '\.\.\.$' -or $row.Id.Contains([string][char]0x2026)) { $why = 'Id cut off by winget' }
        if ($why) { $excluded += [pscustomobject]@{ Id = $row.Id; Name = $row.Name; Why = $why }; continue }
        $n++
        $others += New-KitPcUpgrade -Row $row -Id (-$n) -GroupOrder $gOrder
    }
    return [pscustomobject]@{ Kit = @($kit); Other = @($others); Run = @(@(Get-KitRunOrder $kit) + @($others)); Excluded = @($excluded) }
}

# ---------------------------------------------------------------- unattended run (/auto)

function Get-KitAutoPlan {
    <#
    What `install.cmd /auto` does, with no questions:
      Install = recommended (On) apps that are missing
      Update  = the "update everything" kit half (Get-KitCatalogUpdateSet)
      Other   = the "update everything" rest-of-PC half (winget upgrade rows
                outside the catalogue; Get-KitUpdateAllPlan)
      Skipped = Interactive and POST items it would otherwise touch
                (recommended or installed): they need a person
    Returns @{ Install; Update; Other; Skipped; Run } (Run = Install + Update, in run order, then Other).
    -UpgradeLines / -Pinned pass through to Get-KitUpdateAllPlan (tests).
    #>
    param([Parameter(Mandatory)][hashtable]$Installed, [hashtable]$Updates = @{}, [string[]]$UpgradeLines = $null, [string[]]$Pinned = $null, [object[]]$Packages = $script:Catalog)
    $all = Get-KitUpdateAllPlan -Installed $Installed -Updates $Updates -UpgradeLines $UpgradeLines -Pinned $Pinned -Packages $Packages
    $install = @(); $skipped = @()
    foreach ($p in $Packages) {
        $isInst = $Installed.ContainsKey($p.Id)
        if ($p.Interactive -or $p.Group -eq 'POST') { if ($p.Default -or $isInst) { $skipped += $p }; continue }
        if (-not $isInst -and $p.Default) { $install += $p }
    }
    return [pscustomobject]@{
        Install = @($install); Update = @($all.Kit); Other = @($all.Other); Skipped = @(Get-KitRunOrder $skipped)
        Run = @(@(Get-KitRunOrder (@($install) + @($all.Kit))) + @($all.Other))
    }
}

function Get-KitAutoExitCode {
    <# Exit code of an unattended run: 0 = nothing failed, 1 = at least one failure. #>
    param([object[]]$Results = @())
    if (@($Results | Where-Object { $_.Status -eq 'failed' }).Count) { return 1 }
    return 0
}

function Get-KitAiUpdateSet {
    <#
    What "Update AI tools" updates: AI-flagged apps that are installed on this PC.
    The AI flag never installs anything and never ticks an app elsewhere.
    #>
    param([Parameter(Mandatory)][hashtable]$Installed, [object[]]$Packages = $script:Catalog)
    return @($Packages | Where-Object { $_.AI -and $Installed.ContainsKey($_.Id) } | Sort-Object GroupOrder, Id)
}

# ---------------------------------------------------------------- the one entry point

function New-KitResult {
    param($Package, [string]$Status, [string]$From = '', [string]$To = '', [string]$Detail = '', [string]$Healed = '', [double]$Seconds = 0)
    return [pscustomobject]@{
        Id = $Package.Id; Name = $Package.Name; Method = $Package.Method
        Status = $Status; From = $From; To = $To; Detail = $Detail; Healed = $Healed; Seconds = [Math]::Round($Seconds, 1)
    }
}

function Invoke-KitPackage {
    <#
    .SYNOPSIS
        Install or update one package. Returns a result object:
        Status = installed | updated | current | failed | dryrun.
    .PARAMETER Installed
        Version from Get-KitInstalled ($null = not installed).
    .PARAMETER Mode
        install (default) or update (prefer the tool's native updater).
    .PARAMETER OnStatus
        Optional scriptblock called with short progress text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        $Installed = $null,
        [ValidateSet('install', 'update')][string]$Mode = 'install',
        [switch]$DryRun,
        [scriptblock]$OnStatus
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = $Package
    $isInst = $null -ne $Installed
    $from = if ($isInst) { [string]$Installed } else { '' }
    function Step([string]$t) { if ($OnStatus) { try { & $OnStatus $t } catch {} } }
    # NoAdmin + elevated kit: the installer runs at the signed-in user's normal rights
    $de = Test-KitDeElevate -Package $p
    $deNote = ''; if ($de) { $deNote = ' (at normal user rights, not as admin)' }
    Write-KitLog "== $($p.Name) [$($p.Method) $($p.Ref)] installed='$from' mode=$Mode dry=$([bool]$DryRun)$(if ($de) { ' de-elevated' })"

    try {
        if ($p.Requires) {
            Update-KitPath
            if (-not (Get-Command $p.Requires -ErrorAction SilentlyContinue)) {
                return New-KitResult $p 'failed' $from '' "needs $($p.Requires) first (install it, then retry)" '' $sw.Elapsed.TotalSeconds
            }
        }

        switch ($p.Method) {
            { $_ -in 'winget', 'msstore' } {
                $a = Get-KitWingetInstallArgs -WId $p.Ref -Method $p.Method
                if ($DryRun) {
                    $what = "winget install $($p.Ref)"; if ($p.Method -eq 'msstore') { $what += ' (Store)' }
                    return New-KitResult $p 'dryrun' $from '' "$what$deNote" '' $sw.Elapsed.TotalSeconds
                }
                Step $(if ($de) { 'installing with winget at normal user rights' } else { 'installing with winget' })
                $r = Invoke-KitWinget $a -DeElevate:$de
                $healed = ''
                # The installer refuses an administrator context (manifest: elevationProhibited, or a
                # user-scope package): retry once at the signed-in user's normal rights.
                if (-not $de -and $r.Ec -in $script:WG_PROHIBITS_ELEVATION, $script:WG_ADMIN_CONTEXT_PROHIBITED -and (Test-KitAdmin)) {
                    $de = $true
                    Step 'the installer refuses admin rights - retrying at normal user rights'
                    $r = Invoke-KitWinget $a -DeElevate
                    if ($r.Ec -eq 0) { $healed = 'ran at normal user rights (installer refuses admin)' }
                }

                if ($r.Ec -eq $script:WG_NOT_FOUND) {
                    Step 'ID not in source - searching for its successor'
                    $newId = Find-KitReplacementId -Package $p
                    if ($newId) {
                        Save-KitOverride -Old $p.Ref -New $newId
                        $healed = "$($p.Ref) -> $newId"
                        $p.Ref = $newId
                        Step "healed to $newId - installing"
                        $r = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $p.Ref -Method $p.Method) -DeElevate:$de
                    }
                }
                if ($r.Ec -ne 0 -and -not $isInst -and (Test-KitDownloadFail $r.Out)) {
                    foreach ($v in @(Get-KitPkgVersions -WId $p.Ref -Method $p.Method | Select-Object -Skip 1 -First 2)) {
                        Step "latest download broken - trying v$v"
                        $r2 = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $p.Ref -Method $p.Method -Version $v) -DeElevate:$de
                        if ($r2.Ec -eq 0) { $r = $r2; $healed = "pinned v$v (latest installer download broken)"; break }
                    }
                    if ($r.Ec -ne 0 -and $p.Method -ne 'msstore') {
                        $sid = Find-KitStoreFallback -Package $p
                        if ($sid) {
                            Step "trying the Microsoft Store channel ($sid)"
                            $r2 = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $sid -Method 'msstore') -DeElevate:$de
                            if ($r2.Ec -eq 0) {
                                $r = $r2
                                Save-KitOverride -Old $p.Ref -New "msstore:$sid"
                                $healed = "$($p.Ref) -> msstore:$sid (winget installer broken)"
                                $p.Ref = $sid; $p.Method = 'msstore'
                            }
                        }
                    }
                }

                $o = Get-KitWingetOutcome -ExitCode $r.Ec -Out $r.Out
                if ($o.Status -eq 'ok') {
                    Step 'verifying'
                    $post = Get-KitPkgVersion -WId $p.Ref -Method $p.Method
                    $st = if ($isInst) { 'updated' } else { 'installed' }
                    $det = ''
                    if ($isInst -and $post -and (Get-KitVersionText $post) -eq (Get-KitVersionText $from)) {
                        # winget ran an installer and exited 0, but the version did not move
                        $st = 'current'; $det = "winget exit 0, but the installed version is still $from"
                        Write-KitLog "  note: $det"
                    }
                    return New-KitResult $p $st $from "$post" $det $healed $sw.Elapsed.TotalSeconds
                }
                if ($o.Status -eq 'current') {
                    $det = ''; if (-not $isInst) { $det = 'winget: already installed, nothing newer' }
                    return New-KitResult $p 'current' $from $from $det $healed $sw.Elapsed.TotalSeconds
                }
                Write-KitLog "  failed: $($o.Reason)"
                return New-KitResult $p 'failed' $from '' $o.Reason $healed $sw.Elapsed.TotalSeconds
            }

            'winget-upgrade' {
                # An app outside the catalogue that `winget upgrade` listed (Update everything, /auto)
                $from = [string]$p.Current; $to = [string]$p.Latest
                $a = @('upgrade', '--id', $p.Ref, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                if ($p.Source) { $a += @('--source', [string]$p.Source) }
                if ($DryRun) { return New-KitResult $p 'dryrun' $from $to "winget upgrade $($p.Ref)" '' $sw.Elapsed.TotalSeconds }
                Step 'upgrading with winget'
                $r = Invoke-KitWinget $a
                $healed = ''
                if ($r.Ec -in $script:WG_PROHIBITS_ELEVATION, $script:WG_ADMIN_CONTEXT_PROHIBITED -and (Test-KitAdmin)) {
                    Step 'the installer refuses admin rights - retrying at normal user rights'
                    $r = Invoke-KitWinget $a -DeElevate
                    if ($r.Ec -eq 0) { $healed = 'ran at normal user rights (installer refuses admin)' }
                }
                $o = Get-KitWingetOutcome -ExitCode $r.Ec -Out $r.Out
                if ($o.Status -eq 'ok') { return New-KitResult $p 'updated' $from $to '' $healed $sw.Elapsed.TotalSeconds }
                if ($o.Status -eq 'current') { return New-KitResult $p 'current' $from $from 'winget: nothing to upgrade' $healed $sw.Elapsed.TotalSeconds }
                Write-KitLog "  failed: $($o.Reason)"
                return New-KitResult $p 'failed' $from '' $o.Reason $healed $sw.Elapsed.TotalSeconds
            }

            'script' {
                # Already installed + has a native updater -> use it (claude update, agy update)
                $useUpdate = $isInst -and [bool]$p.Update
                if ($DryRun) {
                    $child = if ($p.Shell -eq 'pwsh') { 'child pwsh' } else { 'child process' }
                    if ($p.Elevated) { $child += ', as administrator' }
                    $what = if ($useUpdate) { $p.Update } else { "irm $($p.Ref) | iex ($child)" }
                    return New-KitResult $p 'dryrun' $from '' "$what$deNote" '' $sw.Elapsed.TotalSeconds
                }
                $script:LastFailLine = ''
                if ($useUpdate) {
                    Step "running $($p.Update)"
                    $ec = Invoke-KitCommandLine -CommandLine $p.Update -Exe $p.Exe -DeElevate:$de
                } else {
                    Step 'running the official installer'
                    if ($p.Elevated -and -not (Test-KitAdmin)) { Step 'it opens its own administrator window (Windows asks first)' }
                    $ec = Invoke-KitRemoteScript -Url $p.Ref -Attached:$p.Interactive -Shell ([string]$p.Shell) -Elevated:$p.Elevated -DeElevate:$de
                }
                if ($ec -eq 1223) { return New-KitResult $p 'failed' $from '' 'administrator prompt declined' '' $sw.Elapsed.TotalSeconds }
                if ($ec -ne 0) {
                    # a short reason from the child's own output when it names one (e.g. "blocked by an Application Control policy")
                    $why = if ($script:LastFailLine) { "$($script:LastFailLine) (exit $ec)" } else { "exit code $ec (see log)" }
                    return New-KitResult $p 'failed' $from '' $why '' $sw.Elapsed.TotalSeconds
                }
                $to = Get-KitToolVersion -Package $p
                $st = 'installed'
                if ($isInst) { $st = 'updated'; if ($to -and (Get-KitVersionText $to) -eq (Get-KitVersionText $from)) { $st = 'current' } }
                if ($p.Interactive) { $st = 'done' }
                return New-KitResult $p $st $from "$to" '' '' $sw.Elapsed.TotalSeconds
            }

            'direct' {
                Step 'finding the latest official installer'
                $d = $null
                try { $d = Resolve-KitDirect -Key $p.Ref } catch {
                    Write-KitLog "  direct resolve failed: $_"
                    if (-not $p.Fallback) { throw }
                }
                if (-not $d) {
                    # Vendor page changed: fall back to winget for this run
                    $fb = $p.PSObject.Copy(); $fb.Method = 'winget'; $fb.Ref = $p.Fallback
                    $r = Invoke-KitPackage -Package $fb -Installed $Installed -Mode $Mode -DryRun:$DryRun -OnStatus $OnStatus
                    $r.Detail = "download page changed - used winget $($p.Fallback). $($r.Detail)".Trim()
                    $r.Method = 'direct'; $r.Id = $p.Id
                    return $r
                }
                if ($isInst -and (Test-KitVersionCurrent -Installed $from -Latest $d.Version)) {
                    return New-KitResult $p 'current' $from $from "latest is $($d.Version)" '' $sw.Elapsed.TotalSeconds
                }
                if ($DryRun) {
                    Write-KitLog "  would download $($d.Url)"
                    return New-KitResult $p 'dryrun' $from $d.Version "download $($d.FileName) v$($d.Version) ($($d.Signer) signed), run $($d.Args)$deNote" '' $sw.Elapsed.TotalSeconds
                }

                $dir = Join-Path $env:TEMP 'my-win-kit'
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $file = Join-Path $dir $d.FileName
                Step "downloading v$($d.Version)"
                Write-KitLog "  download $($d.Url)"
                $oldPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                try { Invoke-WebRequest -Uri $d.Url -OutFile $file -UseBasicParsing -UserAgent $script:UA } finally { $ProgressPreference = $oldPP }

                Step 'checking the signature'
                $sig = Get-AuthenticodeSignature -LiteralPath $file
                if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notlike "*$($d.Signer)*") {
                    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                    return New-KitResult $p 'failed' $from '' "installer signature not valid for $($d.Signer) ($($sig.Status))" '' $sw.Elapsed.TotalSeconds
                }
                Step "installing v$($d.Version)"
                Write-KitLog "  run $file $($d.Args)"
                if ($de) {
                    $ec = (Invoke-KitDeElevated -FilePath $file -ArgumentList @($d.Args -split '\s+' | Where-Object { $_ })).Ec
                } else {
                    # WaitForExit on this process only: Start-Process -Wait in PS 7
                    # also waits for the app the installer launches at the end.
                    $proc = Start-Process -FilePath $file -ArgumentList $d.Args -PassThru
                    $proc.WaitForExit()
                    $ec = $proc.ExitCode
                }
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                Write-KitLog "  exit $ec"
                if ($ec -ne 0) { return New-KitResult $p 'failed' $from '' "installer exit code $ec" '' $sw.Elapsed.TotalSeconds }
                $st = if ($isInst) { 'updated' } else { 'installed' }
                return New-KitResult $p $st $from $d.Version '' '' $sw.Elapsed.TotalSeconds
            }

            'npm' {
                $a = @('install', '-g', $p.Ref)
                if ($DryRun) { return New-KitResult $p 'dryrun' $from '' ("npm " + ($a -join ' ') + $deNote) '' $sw.Elapsed.TotalSeconds }
                Step 'installing with npm'
                Write-KitLog ("npm " + ($a -join ' ') + $(if ($de) { '  (de-elevated)' } else { '' }))
                $nr = Invoke-KitChild -FilePath 'npm' -ArgumentList $a -DeElevate:$de
                $out = @(@($nr.Out) + @($nr.Err)); $ec = $nr.Ec
                foreach ($l in ($out | Select-Object -Last 10)) { Write-KitLog "  | $l" }
                if ($ec -ne 0) { return New-KitResult $p 'failed' $from '' "npm exit code $ec" '' $sw.Elapsed.TotalSeconds }
                $st = if ($isInst) { 'updated' } else { 'installed' }
                return New-KitResult $p $st $from '' '' '' $sw.Elapsed.TotalSeconds
            }

            'builtin' {
                switch ($p.Ref) {
                    'enable-rdp' {
                        if ($DryRun) { return New-KitResult $p 'dryrun' '' '' 'enable RDP + NLA + firewall group (UAC)' '' $sw.Elapsed.TotalSeconds }
                        $r = Invoke-KitEnableRdp
                        $st = if ($r.Ec -eq 0) { 'done' } else { 'failed' }
                        return New-KitResult $p $st '' '' $r.Detail '' $sw.Elapsed.TotalSeconds
                    }
                    'dev-folder' {
                        $r = Invoke-KitDevFolder -DryRun:$DryRun
                        Write-KitLog "  dev folder: $($r.Status) - $($r.Detail)"
                        return New-KitResult $p $r.Status $from $r.To $r.Detail '' $sw.Elapsed.TotalSeconds
                    }
                    'wsl-ubuntu' {
                        $r = Invoke-KitWslUbuntu -DryRun:$DryRun -OnStatus $OnStatus
                        Write-KitLog "  wsl: $($r.Status) - $($r.Detail)"
                        return New-KitResult $p $r.Status $from $r.To $r.Detail '' $sw.Elapsed.TotalSeconds
                    }
                    default { throw "unknown builtin '$($p.Ref)'" }
                }
            }

            default { throw "unknown method '$($p.Method)'" }
        }
    } catch {
        Write-KitLog "  ERROR $($_.Exception.Message)"
        return New-KitResult $p 'failed' $from '' $_.Exception.Message '' $sw.Elapsed.TotalSeconds
    }
}

# ---------------------------------------------------------------- desktop shortcuts

function Get-KitDesktopShortcuts {
    $paths = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:PUBLIC 'Desktop'))
    return @(foreach ($dp in $paths) {
        if ($dp -and (Test-Path -LiteralPath $dp)) {
            Get-ChildItem -LiteralPath $dp -Filter '*.lnk' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        }
    })
}

function Remove-KitNewShortcuts {
    <# Delete desktop shortcuts that appeared since $Before. Returns the removed names. #>
    param([string[]]$Before)
    $removed = @()
    foreach ($f in (Get-KitDesktopShortcuts)) {
        if ($Before -notcontains $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            $removed += (Split-Path $f -Leaf)
        }
    }
    return $removed
}

Export-ModuleMember -Function Initialize-Kit, Get-KitVersion, Get-KitUpdates, Get-KitGroups, Get-KitWarnings,
    Get-KitSetting, Get-KitConfigInfo, Get-KitLocalOverrides, ConvertTo-KitJsonDocument, ConvertFrom-KitJsonText,
    Get-KitCatalog, Get-KitLogPath, Get-KitOverrideCount,
    Get-KitRunOrder, Test-KitAdmin, Test-KitWinget, Get-KitArch, Update-KitPath, Start-KitLog, Write-KitLog, Write-KitRunLog,
    Get-KitState, Save-KitState, Get-KitInstalled, Get-KitToolVersion, Get-KitVersionText, Resolve-KitDirect,
    Test-KitVersionCurrent, Get-KitLatestVersion, Get-KitWingetOutcome, Invoke-KitPackage, Invoke-KitProcess, Enable-KitConsoleVt, Get-KitDesktopShortcuts, Remove-KitNewShortcuts,
    Get-KitDevFolderPath, Invoke-KitDevFolder, Get-KitDriveType, Select-KitUbuntuDistro, ConvertFrom-KitWslText, Get-KitWslDistros, Test-KitRebootNeeded,
    Get-KitDetect, Test-KitCttProfile, Get-KitPwshProfilePath, Get-KitPwshPath, Get-KitLocalPrefs, Get-KitLocalPrefsFile, Set-KitLocalPref, Get-KitAutoInstallPwsh, Get-KitAiUpdateSet,
    Get-KitLocalSwitch, Get-KitElevateAtStart, Get-KitSessionUser, Test-KitDeElevate, Get-KitDeElevatedCommand, Invoke-KitDeElevated, Get-KitAutoPlan, Get-KitAutoExitCode,
    ConvertFrom-KitWingetUpgradeText, Get-KitWingetPins, Get-KitCatalogUpdateSet, Get-KitUpdateAllPlan,
    Get-KitAutoInstallEssentials, Invoke-KitEssential, Remove-KitJsonComments, ConvertFrom-KitJsoncText, ConvertTo-KitJsonPretty,
    Get-KitTerminalSettingsPath, Get-KitTerminalConfig, Resolve-KitTerminalStartDir, Merge-KitTerminalSettings, Set-KitDefaultTerminal,
    Test-KitNerdFont, Get-KitNerdFontRelease, Get-KitSha256FromList, Get-KitFileSha256, ConvertTo-KitFontRegName, Install-KitNerdFont,
    Test-KitClaudeCode, Install-KitClaudeCode
