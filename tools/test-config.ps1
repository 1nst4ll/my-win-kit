#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the read-only GitHub configuration, the self-update and the irm | iex bootstrap.
.DESCRIPTION
    No network, safe for CI, on scratch folders in %TEMP%:
      - read chain: "GitHub" (a file:/// config URL) -> cache -> bundled; corrupt cache;
        missing settings file -> defaults
      - JSON writer: ASCII-only, stable round trip, one package per line; every
        config/*.json is in canonical form (they are edited by hand in the repo);
        tailnet.json holds public keys only and a wide-open copy is refused
      - catalogue Ids unique across Packages and Removed, no RetiredId reused
      - learned heals stay on this PC (local-overrides.json), applied at the next start
      - the stable launcher (<state>\launch.ps1) is kept current at every start
      - self-update from a fake newer kit (file:/// zip): accept, re-use, decline, broken zip
      - irm | iex bootstrap with an empty $PSScriptRoot
    The menu never writes config, so nothing here talks to GitHub.
    Runs under Windows PowerShell 5.1 and pwsh. Exit code = failures.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-config.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:fail = 0
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok    $What" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}
function New-Scratch([string]$Tag) { $d = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-$Tag-" + [guid]::NewGuid()); New-Item -ItemType Directory -Path $d -Force | Out-Null; return $d }
function Copy-Kit([string]$Dest) {
    foreach ($d in 'src', 'config', 'assets') { New-Item -ItemType Directory -Path (Join-Path $Dest $d) -Force | Out-Null; Copy-Item -Path (Join-Path $repo "$d\*") -Destination (Join-Path $Dest $d) -Force }
    foreach ($f in 'install.ps1', 'install.cmd', 'win11-tweaks.ps1') { Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $Dest }
}
function Get-LatestLog([string]$State) {
    $l = Get-ChildItem -LiteralPath (Join-Path $State 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) { return [IO.File]::ReadAllText($l.FullName) } else { return '' }
}

Write-Host "test-config: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$keepEnv = @{}; foreach ($n in 'MYWINKIT_STATE_DIR', 'MYWINKIT_CONFIG_URL', 'MYWINKIT_RAW_URL', 'MYWINKIT_ZIP_URL', 'MYWINKIT_BOOTSTRAP_ARGS', 'MYWINKIT_RUNLOG', 'MYWINKIT_STARTMENU_DIR', 'MYWINKIT_DESKTOP_DIR', 'MYWINKIT_UNINSTALL_KEY') { $keepEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
$scratch = @()
try {
    # ---------------------------------------------------------------- read chain
    $state = New-Scratch 'cfg-state'; $scratch += $state
    $env:MYWINKIT_STATE_DIR = $state
    $kit = New-Scratch 'cfg-kit'; $scratch += $kit; Copy-Kit $kit
    $remote = New-Scratch 'cfg-remote'; $scratch += $remote
    Copy-Item -Path (Join-Path $repo 'config\*') -Destination $remote
    # the "GitHub" copy has one extra package, so the source is visible
    $rc = [IO.File]::ReadAllText((Join-Path $remote 'catalog.json')).Replace('"Packages": [', '"Packages": [' + "`n" + '    { "Id": 900, "Name": "Remote Only", "Group": "UTIL", "On": false, "Method": "winget", "Ref": "Remote.Only", "Desc": "x" },')
    [IO.File]::WriteAllText((Join-Path $remote 'catalog.json'), $rc)
    $env:MYWINKIT_CONFIG_URL = ([Uri]$remote).AbsoluteUri
    Import-Module (Join-Path $kit 'src\core.psm1') -Force
    $cat = @(Initialize-Kit -KitRoot $kit)
    $i = Get-KitConfigInfo
    Check ($i.Kind -eq 'github' -and @($cat | Where-Object Ref -eq 'Remote.Only').Count -eq 1) 'read: remote ("GitHub") copy wins over the bundled one'
    Check (Test-Path (Join-Path $state 'cache\catalog.json')) 'read: remote copy cached'

    $env:MYWINKIT_CONFIG_URL = 'http://127.0.0.1:9/config'   # nothing listens: instant "offline"
    $cat = @(Initialize-Kit -KitRoot $kit)
    Check ((Get-KitConfigInfo).Kind -eq 'cache' -and @($cat | Where-Object Ref -eq 'Remote.Only').Count -eq 1) 'offline: cached copy used'

    [IO.File]::WriteAllText((Join-Path $state 'cache\catalog.json'), '{ broken')
    $cat = @(Initialize-Kit -KitRoot $kit)
    Check ((Get-KitConfigInfo).Kind -eq 'bundled' -and -not @($cat | Where-Object Ref -eq 'Remote.Only').Count -and @(Get-KitWarnings | Where-Object { $_ -like '*damaged*' }).Count -eq 1) 'corrupt cache: warning + bundled copy'

    Remove-Item (Join-Path $kit 'config\settings.json'); Remove-Item (Join-Path $state 'cache\settings.json') -ErrorAction SilentlyContinue
    $cat = @(Initialize-Kit -KitRoot $kit)
    Check ((Get-KitSetting 'removeShortcuts' $true) -eq $true) 'missing settings.json: built-in defaults'
    Copy-Item (Join-Path $repo 'config\settings.json') (Join-Path $kit 'config')

    # ---------------------------------------------------------------- JSON writer + canonical form of the hand-edited files
    $doc = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $repo 'config\catalog.json')))
    $t1 = ConvertTo-KitJsonDocument $doc; $t2 = ConvertTo-KitJsonDocument (ConvertFrom-KitJsonText $t1)
    Check ($t1 -eq $t2) 'JSON writer: stable round trip'
    foreach ($cf in 'catalog.json', 'settings.json', 'winget-id-overrides.json', 'terminal.json', 'tailnet.json') {
        $txt = [IO.File]::ReadAllText((Join-Path $repo "config\$cf"))
        Check ($txt -eq (ConvertTo-KitJsonDocument (ConvertFrom-KitJsonText $txt))) "config/$cf is in canonical form (ConvertTo-KitJsonDocument)"
    }
    $u = ConvertTo-KitJsonDocument ([ordered]@{ Name = "Caf$([char]0xE9) `"q`" \ x" })
    Check (-not @([Text.Encoding]::UTF8.GetBytes($u) | Where-Object { $_ -gt 127 }).Count -and (ConvertFrom-KitJsonText $u)['Name'] -eq "Caf$([char]0xE9) `"q`" \ x") 'JSON writer: ASCII-only (\u escapes), round-trips quotes and backslashes'
    Check (@(($t1 -split "`n") | Where-Object { $_ -match '^\s+\{ "Id": ' }).Count -eq (@($doc['Packages']).Count + @(@($doc['Removed']) | Where-Object { $_ }).Count)) 'JSON writer: one package per line (Packages and Removed)'

    # ---------------------------------------------------------------- config/terminal.json (public repo: no personal data)
    $tj = [IO.File]::ReadAllText((Join-Path $repo 'config\terminal.json'))
    Check (-not @([Text.Encoding]::UTF8.GetBytes($tj) | Where-Object { $_ -gt 127 }).Count) 'terminal.json: ASCII-only (the robot icon is a \u escape)'
    $personal = @(@('C:\\Users\\', 'D:\\OneDrive', $env:USERNAME, $env:COMPUTERNAME, '@', 'startOnUserLogin') | Where-Object { $_ -and $tj.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $ip = [regex]::Match($tj, '\b\d{1,3}(\.\d{1,3}){3}\b')
    Check (-not $personal.Count -and -not $ip.Success) "terminal.json: no user names, host names, personal paths or IPs$(if ($personal.Count) { ': ' + ($personal -join ', ') })"
    $td = ConvertFrom-KitJsonText $tj
    $tp = @(@($td['profiles']) | Where-Object { $_['guid'] -eq $td['defaultProfile'] })
    Check ($tp.Count -eq 1 -and $tp[0]['name'] -eq 'Claude Code' -and @($td['keybindings']).Count -eq 3 -and $td['startingDirectory']['prefer'] -eq 'dev-folder' -and $td['profileDefaults']['font']['face'] -eq 'CaskaydiaCove Nerd Font Mono') 'terminal.json: Claude Code profile is the default, 3 key bindings, start folder = the dev folder (keyword dev-folder), Nerd Font face'
    $kp = @(@($td['profiles']) | Where-Object { $_['name'] -eq 'my-win-kit' })
    Check ($kp.Count -eq 1 -and $kp[0]['commandline'] -like '*%LOCALAPPDATA%\my-win-kit\launch.ps1*' -and $kp[0]['commandline'] -notmatch 'OneDrive') 'terminal.json: the my-win-kit profile runs the stable launcher through %LOCALAPPDATA% (no personal path, no OneDrive)'
    $cj = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $repo 'config\catalog.json')))
    $allIds = @(@($cj['Packages']) + @($cj['Removed']) | Where-Object { $_ } | ForEach-Object { [int]$_['Id'] })
    Check ($allIds -contains 62 -and @($cj['Removed'] | Where-Object { $_['Id'] -eq 41 }).Count -eq 1) 'catalog: Python 3.14 took Id 62 (Python 3.13, Id 41, in Removed)'
    Check ($allIds -contains 63 -and @($cj['Packages'] | Where-Object { $_['Id'] -eq 63 -and $_['Ref'] -eq 'tailnet' }).Count -eq 1 -and ($allIds | Measure-Object -Maximum).Maximum -eq 63) 'catalog: the Tailnet setup took Id 63; the next free Id is 64'
    Check (Test-Path (Join-Path $state 'cache\terminal.json')) 'read: terminal.json fetched and cached like the other config files'

    # ---------------------------------------------------------------- config/tailnet.json (public repo: public keys only; never wide open)
    $nj = [IO.File]::ReadAllText((Join-Path $repo 'config\tailnet.json'))
    Check (-not @([Text.Encoding]::UTF8.GetBytes($nj) | Where-Object { $_ -gt 127 }).Count) 'tailnet.json: ASCII-only'
    $npers = @(@('C:\\Users\\', $env:USERNAME, $env:COMPUTERNAME, '@', 'BEGIN ', 'PRIVATE') | Where-Object { $_ -and $nj.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    Check (-not $npers.Count) "tailnet.json: public keys only, no comments, user or host names$(if ($npers.Count) { ': ' + ($npers -join ', ') })"
    Check (Test-Path (Join-Path $state 'cache\tailnet.json')) 'read: tailnet.json fetched and cached like the other config files'
    $keepUrl = $env:MYWINKIT_CONFIG_URL
    $env:MYWINKIT_CONFIG_URL = ([Uri]$remote).AbsoluteUri
    $goodTn = [IO.File]::ReadAllText((Join-Path $remote 'tailnet.json'))
    [IO.File]::WriteAllText((Join-Path $remote 'tailnet.json'), $goodTn.Replace('"100.64.0.0/10",', '"Any",'))
    $cat = @(Initialize-Kit -KitRoot $kit)
    $tnc = Get-KitTailnetConfig
    Check ($tnc -and @($tnc['allowFrom']) -notcontains 'Any' -and @($tnc['allowFrom']) -contains '100.64.0.0/10') 'tailnet.json on "GitHub" with allowFrom Any -> refused, the cached copy is used'
    [IO.File]::WriteAllText((Join-Path $remote 'tailnet.json'), $goodTn.Replace('",' + "`n" + '    "ssh-ed25519', ' user@host",' + "`n" + '    "ssh-ed25519'))
    $cat = @(Initialize-Kit -KitRoot $kit)
    Check (-not @(@((Get-KitTailnetConfig)['authorizedKeys']) | Where-Object { "$_" -like '*@*' }).Count) 'tailnet.json on "GitHub" with a key comment -> refused, the cached copy is used'
    [IO.File]::WriteAllText((Join-Path $remote 'tailnet.json'), $goodTn)
    $env:MYWINKIT_CONFIG_URL = $keepUrl

    # ---------------------------------------------------------------- hand-edited catalogue: Ids are permanent
    $all = @(@($doc['Packages']) + @($doc['Removed']) | Where-Object { $_ } | ForEach-Object { [int]$_['Id'] })
    $retired = @(@($doc['RetiredIds']) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    Check (@($all | Select-Object -Unique).Count -eq $all.Count) 'catalog: Ids unique across Packages and Removed'
    Check (-not @($all | Where-Object { $retired -contains $_ }).Count) 'catalog: no package uses a RetiredId'

    # ---------------------------------------------------------------- learned heals stay on this PC
    $env:MYWINKIT_CONFIG_URL = 'http://127.0.0.1:9/config'
    $cat = @(Initialize-Kit -KitRoot $kit -Offline)
    $before = Get-KitOverrideCount
    $bundledOv = [IO.File]::ReadAllText((Join-Path $kit 'config\winget-id-overrides.json'))
    & (Get-Module core) { Save-KitOverride -Old 'Old.Id' -New 'New.Id' }
    $i = Get-KitConfigInfo
    Check ($i.LocalFixes -eq 1 -and (Get-KitLocalOverrides)['Old.Id'] -eq 'New.Id' -and (Test-Path -LiteralPath $i.LocalFixesFile) -and $i.LocalFixesFile -like '*local-overrides.json') 'heal -> kept in local-overrides.json on this PC'
    Check ([IO.File]::ReadAllText((Join-Path $kit 'config\winget-id-overrides.json')) -eq $bundledOv) 'heal: bundled winget-id-overrides.json untouched (never pushed)'
    $cat = @(Initialize-Kit -KitRoot $kit -Offline)
    Check ((Get-KitOverrideCount) -eq $before + 1) 'local heals applied at the next start'
    $writers = @(Get-Command -Module core -ErrorAction SilentlyContinue | Where-Object { ($_.Verb -in 'Save', 'Add', 'Set', 'Push', 'Remove', 'Restore' -and $_.Noun -match '^Kit(Config|Package|Setting|Pending)') -or $_.Noun -match '^KitGh' })
    Check ($writers.Count -eq 0) 'engine exports no config-write or gh functions'

    # ---------------------------------------------------------------- self-update + bootstrap (file:/// "GitHub")
    $up = New-Scratch 'cfg-update'; $scratch += $up
    $newer = Join-Path $up 'src-tree\my-win-kit-main'; New-Item -ItemType Directory -Path $newer -Force | Out-Null; Copy-Kit $newer
    $core = Join-Path $newer 'src\core.psm1'
    [IO.File]::WriteAllText($core, ([regex]::Replace([IO.File]::ReadAllText($core), "KitVersion\s*=\s*'[0-9.]+'", "KitVersion  = '9.9.9'")))
    Compress-Archive -Path (Join-Path $up 'src-tree\my-win-kit-main') -DestinationPath (Join-Path $up 'kit.zip')
    $env:MYWINKIT_RAW_URL = ([Uri]$newer).AbsoluteUri
    $env:MYWINKIT_ZIP_URL = ([Uri](Join-Path $up 'kit.zip')).AbsoluteUri
    $env:MYWINKIT_CONFIG_URL = 'http://127.0.0.1:9/config'
    Remove-Item Env:MYWINKIT_RUNLOG -ErrorAction SilentlyContinue
    $st2 = New-Scratch 'cfg-upstate'; $scratch += $st2; $env:MYWINKIT_STATE_DIR = $st2
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st2
    Check ($o -match 'Updating the kit [0-9.]+ -> 9\.9\.9' -and $o -notmatch '\[Y/n\]' -and $log -match 'installing v9\.9\.9 \(automatic\)' -and (Test-Path (Join-Path $st2 'app\9.9.9\install.ps1')) -and $log -match 'running kit v9\.9\.9' -and $log -match 'frontend: CLASSIC started' -and $o -match 'v9\.9\.9') 'self-update: no question, downloaded, verified, ran v9.9.9'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st2
    Check ($o -notmatch 'Updating the kit' -and $log -match 'newer copy already on this PC: v9\.9\.9') 'self-update: next start uses the downloaded copy, no second download'
    $st3 = New-Scratch 'cfg-upstate'; $scratch += $st3; $env:MYWINKIT_STATE_DIR = $st3
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -NoUpdate -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st3
    Check (-not (Test-Path (Join-Path $st3 'app')) -and $o -notmatch 'Updating the kit' -and $log -notmatch 'update: ' -and $log -match 'frontend: CLASSIC started') 'self-update: -NoUpdate skips the check'
    Check ((Test-Path (Join-Path $st3 'launch.ps1')) -and [IO.File]::ReadAllText((Join-Path $st3 'launch.ps1')) -eq [IO.File]::ReadAllText((Join-Path $kit 'src\launch.ps1')) -and $log -match 'launcher: .* updated') 'launcher: <state>\launch.ps1 copied from the running kit (shortcuts + Terminal profile run it)'
    # broken newer version -> fall back to this copy
    [IO.File]::WriteAllText($core, [IO.File]::ReadAllText($core) + "`nfunction Broken {")
    Remove-Item (Join-Path $up 'kit.zip'); Compress-Archive -Path (Join-Path $up 'src-tree\my-win-kit-main') -DestinationPath (Join-Path $up 'kit.zip')
    $st4 = New-Scratch 'cfg-upstate'; $scratch += $st4; $env:MYWINKIT_STATE_DIR = $st4
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st4
    Check ($log -match 'failed verification: parse error' -and $log -match 'frontend: CLASSIC started' -and -not (Test-Path (Join-Path $st4 'app\9.9.9'))) 'self-update: broken download rejected, kept the local copy'
    # irm | iex: empty $PSScriptRoot
    [IO.File]::WriteAllText($core, ([regex]::Replace([IO.File]::ReadAllText($core), "`nfunction Broken \{$", '')))
    Remove-Item (Join-Path $up 'kit.zip'); Compress-Archive -Path (Join-Path $up 'src-tree\my-win-kit-main') -DestinationPath (Join-Path $up 'kit.zip')
    $st5 = New-Scratch 'cfg-upstate'; $scratch += $st5; $env:MYWINKIT_STATE_DIR = $st5
    $env:MYWINKIT_BOOTSTRAP_ARGS = '-Classic -DryRun -ClassicTestInput Q'
    $loader = Join-Path $kit 'install.ps1'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '$loader' -Raw | Invoke-Expression; 'STILL-OPEN'" 2>&1 | Out-String
    $log = Get-LatestLog $st5
    Check ($o -match 'downloading the kit' -and (Test-Path (Join-Path $st5 'app\9.9.9\install.ps1')) -and $log -match 'bootstrap ->' -and $log -match 'frontend: CLASSIC started' -and $o -match 'STILL-OPEN') 'irm | iex: empty $PSScriptRoot -> downloaded to app\9.9.9, started, caller shell not closed'
    # irm keeps a UTF-8 BOM as a character in front of param(): the text would not parse (Get-Content above hides that)
    $raw = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($loader)); $okParse = $true
    try { [void][scriptblock]::Create($raw) } catch { $okParse = $false }
    Check ($okParse -and [int][char]$raw[0] -ne 0xFEFF) 'irm | iex: install.ps1 has no BOM and parses as downloaded text'
    Check ($log -match 'shortcuts: skipped \(test mode' -and -not (Test-Path (Join-Path $st5 'install.json'))) 'shortcuts: test mode without the hooks never touches the real Start menu / Desktop / registry'

    # ---------------------------------------------------------------- online install: shortcuts, refresh, uninstall
    $st6 = New-Scratch 'cfg-instate'; $scratch += $st6; $env:MYWINKIT_STATE_DIR = $st6
    $smRoot = New-Scratch 'cfg-startmenu'; $scratch += $smRoot; $sm = Join-Path $smRoot 'my-win-kit'
    $dk = New-Scratch 'cfg-desktop'; $scratch += $dk; $deskLnk = Join-Path $dk 'my-win-kit.lnk'
    $regParent = 'HKCU:\Software\my-win-kit-test\' + [guid]::NewGuid(); $regKey = "$regParent\my-win-kit"
    $env:MYWINKIT_STARTMENU_DIR = $sm; $env:MYWINKIT_DESKTOP_DIR = $dk; $env:MYWINKIT_UNINSTALL_KEY = $regKey
    try {
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '$loader' -Raw | Invoke-Expression" 2>&1 | Out-String
        $ws = New-Object -ComObject WScript.Shell
        $lnks = @(Get-ChildItem -LiteralPath $sm -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
        $ico = Join-Path $st6 'my-win-kit.ico'
        $okLnk = $true
        foreach ($p in @((Join-Path $sm 'my-win-kit.lnk'), (Join-Path $sm 'Uninstall my-win-kit.lnk'), $deskLnk)) {
            if (-not (Test-Path -LiteralPath $p)) { $okLnk = $false; continue }
            $l = $ws.CreateShortcut($p)
            if ($l.IconLocation -ne "$ico,0" -or $l.TargetPath -notmatch 'WindowsPowerShell\\v1\.0\\powershell\.exe$') { $okLnk = $false }
        }
        Check (($lnks -join '|') -eq 'my-win-kit.lnk|Uninstall my-win-kit.lnk' -and $okLnk -and (Test-Path -LiteralPath $ico) -and $o -match 'Added my-win-kit to the Start menu') 'install: Start menu (kit + Uninstall) and Desktop shortcuts, all with the kit icon'
        Check ($ws.CreateShortcut((Join-Path $sm 'my-win-kit.lnk')).Arguments -match [regex]::Escape((Join-Path $st6 'launch.ps1')) -and $ws.CreateShortcut((Join-Path $sm 'Uninstall my-win-kit.lnk')).Arguments -match 'uninstall\.ps1') 'install: shortcuts run launch.ps1 / uninstall.ps1 from the state folder'
        $rk = Get-ItemProperty -LiteralPath $regKey -ErrorAction SilentlyContinue
        Check ($rk -and $rk.DisplayName -eq 'my-win-kit' -and $rk.DisplayVersion -eq '9.9.9' -and $rk.DisplayIcon -eq $ico -and $rk.UninstallString -match 'uninstall\.ps1' -and $rk.NoModify -eq 1 -and $rk.NoRepair -eq 1) 'install: Settings > Apps entry (name, version, icon, uninstall command)'
        # the launcher picks the newest downloaded copy
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $st6 'launch.ps1') -NoUpdate -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
        Check ((Get-LatestLog $st6) -match 'frontend: CLASSIC started' -and $o -match 'v9\.9\.9') 'launcher: starts the newest kit copy (v9.9.9)'
        # running the installer again: same shortcuts, nothing added
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '$loader' -Raw | Invoke-Expression" 2>&1 | Out-String
        $n2 = @(Get-ChildItem -LiteralPath $sm -ErrorAction SilentlyContinue).Count
        Check ($n2 -eq 2 -and (Test-Path -LiteralPath $deskLnk) -and @(Get-ChildItem -LiteralPath $dk).Count -eq 1 -and (Test-Path -LiteralPath $regKey)) 'install: running it again is idempotent'
        # a later start of another version refreshes, but a deleted Desktop shortcut stays deleted
        Remove-Item -LiteralPath $deskLnk
        $inst = Join-Path $st6 'install.json'; [IO.File]::WriteAllText($inst, ([IO.File]::ReadAllText($inst) -replace '"Version": "[0-9.]+"', '"Version": "0.0.1"'))
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $st6 'app\9.9.9\install.ps1') -NoUpdate -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
        Check ([IO.File]::ReadAllText($inst) -match '"Version": "9\.9\.9"' -and -not (Test-Path -LiteralPath $deskLnk) -and (Get-LatestLog $st6) -match 'shortcuts: v9\.9\.9 registered') 'refresh: a new version updates the entry; a deleted Desktop shortcut is not re-created'
        # uninstall removes everything
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $st6 'uninstall.ps1') -StateDir $st6 -Yes 2>&1 | Out-String
        Check (-not (Test-Path -LiteralPath $sm) -and -not (Test-Path -LiteralPath $regKey) -and -not (Test-Path -LiteralPath $st6) -and $o -match 'uninstalled' -and $o -match 'Apps the kit installed stay installed') 'uninstall: Start menu folder, Settings > Apps entry and the kit folder removed; apps kept'
    } finally {
        Remove-Item -LiteralPath $regParent -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem -LiteralPath 'HKCU:\Software\my-win-kit-test' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath 'HKCU:\Software\my-win-kit-test' -Force -ErrorAction SilentlyContinue }
    }
    $env:MYWINKIT_BOOTSTRAP_ARGS = ''
} finally {
    foreach ($n in $keepEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $keepEnv[$n]) }
    foreach ($d in $scratch) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fail -eq 0) { Write-Host 'test-config: all passed' -ForegroundColor Green } else { Write-Host "test-config: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
