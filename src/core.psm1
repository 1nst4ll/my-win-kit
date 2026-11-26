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
    npm, builtin.

    Self-healing winget IDs: a vanished ID is replaced by its successor, and a
    dead installer download falls back to older versions, then to the Store.
    Heals persist on this PC (cache\local-overrides.json); copy them into
    config/winget-id-overrides.json in the repo to share them with every PC.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible.
#>

Set-StrictMode -Version 2.0

$script:KitVersion  = '2.4.1'   # bump with user-visible changes (shown in the menu banner)
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
$script:UA          = 'my-win-kit (PowerShell)'

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
$script:ConfigFiles = @('catalog.json', 'settings.json', 'winget-id-overrides.json')
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
        $sb = [Text.StringBuilder]::new('"')
        foreach ($ch in ([string]$v).ToCharArray()) {
            $n = [int]$ch
            if ($ch -eq '"') { [void]$sb.Append('\"') } elseif ($ch -eq '\') { [void]$sb.Append('\\') }
            elseif ($n -lt 32 -or $n -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $n)) } else { [void]$sb.Append($ch) }
        }
        return $sb.Append('"').ToString()
    }
    if ($v -is [System.Collections.IDictionary]) {
        return '{ ' + ((@($v.Keys) | ForEach-Object { (ConvertTo-KitJsonValue ([string]$_)) + ': ' + (ConvertTo-KitJsonValue $v[$_]) }) -join ', ') + ' }'
    }
    if ($v -is [System.Collections.IEnumerable]) { return '[' + ((@($v) | ForEach-Object { ConvertTo-KitJsonValue $_ }) -join ', ') + ']' }
    return ConvertTo-KitJsonValue ([string]$v)
}

function ConvertTo-KitJsonDocument($doc) {
    <# Top-level object, one array item / one map entry per line: small, readable git diffs. #>
    $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('{')
    $keys = @($doc.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]; $v = $doc[$k]; $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }
        $isMapOfMaps = $v -is [System.Collections.IDictionary] -and @($v.Values | Where-Object { $_ -is [System.Collections.IDictionary] }).Count -gt 0
        if ($v -is [System.Collections.IList] -and $v -isnot [string] -and @($v).Count -gt 0) {
            $lines.Add("  $(ConvertTo-KitJsonValue ([string]$k)): [")
            $arr = @($v); for ($j = 0; $j -lt $arr.Count; $j++) { $lines.Add("    $(ConvertTo-KitJsonValue $arr[$j])$(if ($j -lt $arr.Count - 1) { ',' })") }
            $lines.Add("  ]$comma")
        } elseif ($isMapOfMaps -and $v.Count -gt 0) {
            $lines.Add("  $(ConvertTo-KitJsonValue ([string]$k)): {")
            $mk = @($v.Keys); for ($j = 0; $j -lt $mk.Count; $j++) { $lines.Add("    $(ConvertTo-KitJsonValue ([string]$mk[$j])): $(ConvertTo-KitJsonValue $v[$mk[$j]])$(if ($j -lt $mk.Count - 1) { ',' })") }
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
        if (Test-Path -LiteralPath $full) { $exe = $full }
    }
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

    $uninst = $null
    $res = @{}
    foreach ($p in $Packages) {
        $ver = $null
        if ($p.Appx) {
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
    <# Run winget, return @{ Ec; Out }. #>
    param([string[]]$WingetArgs)
    Write-KitLog ("winget " + ($WingetArgs -join ' '))
    $r = Invoke-KitProcess -FilePath 'winget' -ArgumentList $WingetArgs
    $out = @(@($r.Out) + @($r.Err))
    $ec = $r.Ec
    $clean = @($out | Where-Object { $_.Trim() -and $_ -match '[A-Za-z]' -and $_ -notmatch '^\s*[\\|/\-]+\s*$' })
    foreach ($l in ($clean | Select-Object -Last 15)) { Write-KitLog "  | $l" }
    Write-KitLog "  exit $ec"
    return @{ Ec = [int]$ec; Out = $clean }
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
    if (Test-KitWinget) {
        $raw = @(Get-KitWingetRaw @('upgrade', '--accept-source-agreements', '--disable-interactivity'))
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
    direct = vendor download page, winget/msstore = `winget show`,
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

function Invoke-KitRemoteScript {
    <#
    Run a vendor one-liner (irm URL | iex) in a CHILD Windows PowerShell so
    a vendor `exit` or `throw` cannot close the menu. -Attached = shares the
    console (interactive menus); otherwise it runs through Invoke-KitProcess
    (own hidden console) and its output is captured to the log.
    #>
    param([string]$Url, [switch]$Attached)
    $cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm '$Url' | iex"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    Write-KitLog "script: irm $Url | iex  (child process)"
    if ($Attached) {
        & powershell.exe @argList
        $ec = $LASTEXITCODE
    } else {
        $r = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList $argList
        $out = @(@($r.Out) + @($r.Err))
        $ec = $r.Ec
        foreach ($l in ($out | Where-Object { $_.Trim() } | Select-Object -Last 20)) { Write-KitLog "  | $l" }
    }
    if ($null -eq $ec) { $ec = 1 }
    Write-KitLog "  exit $ec"
    return [int]$ec
}

function Invoke-KitCommandLine {
    <# Run a native command line like "claude update" (Invoke-KitProcess), captured to the log. #>
    param([string]$CommandLine, [string]$Exe)
    $parts = $CommandLine -split '\s+'
    $file = $parts[0]
    if ($Exe) { $full = [Environment]::ExpandEnvironmentVariables($Exe); if (Test-Path -LiteralPath $full) { $file = $full } }
    Write-KitLog "run: $CommandLine"
    $r = Invoke-KitProcess -FilePath $file -ArgumentList @($parts | Select-Object -Skip 1)
    $out = @(@($r.Out) + @($r.Err))
    $ec = $r.Ec
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
    Write-KitLog "== $($p.Name) [$($p.Method) $($p.Ref)] installed='$from' mode=$Mode dry=$([bool]$DryRun)"

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
                    return New-KitResult $p 'dryrun' $from '' $what '' $sw.Elapsed.TotalSeconds
                }
                Step 'installing with winget'
                $r = Invoke-KitWinget $a
                $healed = ''

                if ($r.Ec -eq $script:WG_NOT_FOUND) {
                    Step 'ID not in source - searching for its successor'
                    $newId = Find-KitReplacementId -Package $p
                    if ($newId) {
                        Save-KitOverride -Old $p.Ref -New $newId
                        $healed = "$($p.Ref) -> $newId"
                        $p.Ref = $newId
                        Step "healed to $newId - installing"
                        $r = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $p.Ref -Method $p.Method)
                    }
                }
                if ($r.Ec -ne 0 -and -not $isInst -and (Test-KitDownloadFail $r.Out)) {
                    foreach ($v in @(Get-KitPkgVersions -WId $p.Ref -Method $p.Method | Select-Object -Skip 1 -First 2)) {
                        Step "latest download broken - trying v$v"
                        $r2 = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $p.Ref -Method $p.Method -Version $v)
                        if ($r2.Ec -eq 0) { $r = $r2; $healed = "pinned v$v (latest installer download broken)"; break }
                    }
                    if ($r.Ec -ne 0 -and $p.Method -ne 'msstore') {
                        $sid = Find-KitStoreFallback -Package $p
                        if ($sid) {
                            Step "trying the Microsoft Store channel ($sid)"
                            $r2 = Invoke-KitWinget (Get-KitWingetInstallArgs -WId $sid -Method 'msstore')
                            if ($r2.Ec -eq 0) {
                                $r = $r2
                                Save-KitOverride -Old $p.Ref -New "msstore:$sid"
                                $healed = "$($p.Ref) -> msstore:$sid (winget installer broken)"
                                $p.Ref = $sid; $p.Method = 'msstore'
                            }
                        }
                    }
                }

                if ($r.Ec -eq 0) {
                    Step 'verifying'
                    $post = Get-KitPkgVersion -WId $p.Ref -Method $p.Method
                    $st = if ($isInst) { 'updated' } else { 'installed' }
                    if ($isInst -and $post -and (Get-KitVersionText $post) -eq (Get-KitVersionText $from)) { $st = 'current' }
                    return New-KitResult $p $st $from "$post" '' $healed $sw.Elapsed.TotalSeconds
                }
                if ($isInst) {
                    # winget exits non-zero when nothing newer exists
                    return New-KitResult $p 'current' $from $from '' $healed $sw.Elapsed.TotalSeconds
                }
                $reason = $r.Out | Select-Object -Last 1
                return New-KitResult $p 'failed' $from '' "$reason" $healed $sw.Elapsed.TotalSeconds
            }

            'script' {
                # Already installed + has a native updater -> use it (claude update, agy update)
                $useUpdate = $isInst -and [bool]$p.Update
                if ($DryRun) {
                    $what = if ($useUpdate) { $p.Update } else { "irm $($p.Ref) | iex (child process)" }
                    return New-KitResult $p 'dryrun' $from '' $what '' $sw.Elapsed.TotalSeconds
                }
                if ($useUpdate) {
                    Step "running $($p.Update)"
                    $ec = Invoke-KitCommandLine -CommandLine $p.Update -Exe $p.Exe
                } else {
                    Step 'running the official installer'
                    $ec = Invoke-KitRemoteScript -Url $p.Ref -Attached:$p.Interactive
                }
                if ($ec -ne 0) { return New-KitResult $p 'failed' $from '' "exit code $ec (see log)" '' $sw.Elapsed.TotalSeconds }
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
                    return New-KitResult $p 'dryrun' $from $d.Version "download $($d.FileName) v$($d.Version) ($($d.Signer) signed), run $($d.Args)" '' $sw.Elapsed.TotalSeconds
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
                # WaitForExit on this process only: Start-Process -Wait in PS 7
                # also waits for the app the installer launches at the end.
                $proc = Start-Process -FilePath $file -ArgumentList $d.Args -PassThru
                $proc.WaitForExit()
                $ec = $proc.ExitCode
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                Write-KitLog "  exit $ec"
                if ($ec -ne 0) { return New-KitResult $p 'failed' $from '' "installer exit code $ec" '' $sw.Elapsed.TotalSeconds }
                $st = if ($isInst) { 'updated' } else { 'installed' }
                return New-KitResult $p $st $from $d.Version '' '' $sw.Elapsed.TotalSeconds
            }

            'npm' {
                $a = @('install', '-g', $p.Ref)
                if ($DryRun) { return New-KitResult $p 'dryrun' $from '' ("npm " + ($a -join ' ')) '' $sw.Elapsed.TotalSeconds }
                Step 'installing with npm'
                Write-KitLog ("npm " + ($a -join ' '))
                $nr = Invoke-KitProcess -FilePath 'npm' -ArgumentList $a
                $out = @(@($nr.Out) + @($nr.Err)); $ec = $nr.Ec
                foreach ($l in ($out | Select-Object -Last 10)) { Write-KitLog "  | $l" }
                if ($ec -ne 0) { return New-KitResult $p 'failed' $from '' "npm exit code $ec" '' $sw.Elapsed.TotalSeconds }
                $st = if ($isInst) { 'updated' } else { 'installed' }
                return New-KitResult $p $st $from '' '' '' $sw.Elapsed.TotalSeconds
            }

            'builtin' {
                if ($p.Ref -ne 'enable-rdp') { throw "unknown builtin '$($p.Ref)'" }
                if ($DryRun) { return New-KitResult $p 'dryrun' '' '' 'enable RDP + NLA + firewall group (UAC)' '' $sw.Elapsed.TotalSeconds }
                $r = Invoke-KitEnableRdp
                $st = if ($r.Ec -eq 0) { 'done' } else { 'failed' }
                return New-KitResult $p $st '' '' $r.Detail '' $sw.Elapsed.TotalSeconds
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
    Test-KitVersionCurrent, Get-KitLatestVersion, Invoke-KitPackage, Invoke-KitProcess, Enable-KitConsoleVt, Get-KitDesktopShortcuts, Remove-KitNewShortcuts
