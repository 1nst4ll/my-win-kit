#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the GitHub-backed configuration, the self-update and the irm | iex bootstrap.
.DESCRIPTION
    Default (no network, safe for CI), on scratch folders in %TEMP%:
      - read chain: "GitHub" (a file:/// config URL) -> cache -> bundled; corrupt cache;
        missing settings file -> defaults
      - JSON writer: ASCII-only, stable round trip, one package per line
      - dry-run edits (add / default / remove / restore / setting): in memory only,
        commit previews, Ids never reused
      - learned heals while gh is unavailable -> pending cache
      - publish: config/*.json shipped, protected legacy files untouched
      - self-update from a fake newer kit (file:/// zip): accept, re-use, decline, broken zip
      - irm | iex bootstrap with an empty $PSScriptRoot
    -Write (needs gh signed in with push access): real commits through the contents
      API against a THROWAWAY branch (created from the current branch on GitHub and
      deleted afterwards): add, default, remove, restore, setting, forced conflict
      (stale sha -> re-fetch -> retry), pending heals push.
    Runs under Windows PowerShell 5.1 and pwsh. Exit code = failures.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-config.ps1
    pwsh -NoProfile -File tools\test-config.ps1 -Write
#>
[CmdletBinding()]
param([switch]$Write)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:fail = 0
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok    $What" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}
function New-Scratch([string]$Tag) { $d = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-$Tag-" + [guid]::NewGuid()); New-Item -ItemType Directory -Path $d -Force | Out-Null; return $d }
function Copy-Kit([string]$Dest) {
    foreach ($d in 'src', 'config') { New-Item -ItemType Directory -Path (Join-Path $Dest $d) -Force | Out-Null; Copy-Item -Path (Join-Path $repo "$d\*") -Destination (Join-Path $Dest $d) -Force }
    foreach ($f in 'install.ps1', 'install.cmd', 'win11-tweaks.ps1') { Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $Dest }
}
function Get-LatestLog([string]$State) {
    $l = Get-ChildItem -LiteralPath (Join-Path $State 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) { return [IO.File]::ReadAllText($l.FullName) } else { return '' }
}

Write-Host "test-config: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$keepEnv = @{}; foreach ($n in 'MYWINKIT_STATE_DIR', 'MYWINKIT_CONFIG_URL', 'MYWINKIT_GH', 'MYWINKIT_BRANCH', 'MYWINKIT_RAW_URL', 'MYWINKIT_ZIP_URL', 'MYWINKIT_BOOTSTRAP_ARGS', 'MYWINKIT_RUNLOG', 'MYWINKIT_TEST_STALE_SHA') { $keepEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
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
    $env:MYWINKIT_GH = 'none'
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

    # ---------------------------------------------------------------- JSON writer
    $doc = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $repo 'config\catalog.json')))
    $t1 = ConvertTo-KitJsonDocument $doc; $t2 = ConvertTo-KitJsonDocument (ConvertFrom-KitJsonText $t1)
    Check ($t1 -eq $t2) 'JSON writer: stable round trip'
    Check ($t1 -eq [IO.File]::ReadAllText((Join-Path $repo 'config\catalog.json'))) 'JSON writer: config/catalog.json is in canonical form'
    $u = ConvertTo-KitJsonDocument ([ordered]@{ Name = "Caf$([char]0xE9) `"q`" \ x" })
    Check (-not @([Text.Encoding]::UTF8.GetBytes($u) | Where-Object { $_ -gt 127 }).Count -and (ConvertFrom-KitJsonText $u)['Name'] -eq "Caf$([char]0xE9) `"q`" \ x") 'JSON writer: ASCII-only (\u escapes), round-trips quotes and backslashes'
    Check (@(($t1 -split "`n") | Where-Object { $_ -match '^\s+\{ "Id": ' }).Count -eq @($doc['Packages']).Count) 'JSON writer: one package per line'

    # ---------------------------------------------------------------- dry-run edits
    $env:MYWINKIT_CONFIG_URL = 'http://127.0.0.1:9/config'
    $cat = @(Initialize-Kit -KitRoot $kit -Offline)
    Set-KitConfigMemoryOnly $true
    $bundledBefore = [IO.File]::ReadAllText((Join-Path $kit 'config\catalog.json'))
    $max = (@($cat) + @(Get-KitRemovedPackages) | Measure-Object -Property Id -Maximum).Maximum
    $r = Add-KitPackage -Name 'Test App' -Ref 'Test.App' -Group 'UTIL' -On $true
    Check ($r.Status -eq 'dryrun' -and $r.Package.Id -eq $max + 1 -and $r.Preview -like '*config/catalog.json - config: add Test App (from*') "dry run add: in memory, Id $($max + 1), commit preview"
    $r = Add-KitPackage -Name 'Grouped' -Ref 'Test.Grouped' -NewGroupLabel 'My tools'
    Check ($r.Status -eq 'dryrun' -and @(Get-KitGroups | Where-Object Label -eq 'My tools').Count -eq 1 -and (Get-KitGroups)[-1].Key -eq 'POST') 'dry run add into a new group (before POST)'
    Check (-not (Add-KitPackage -Name 'Again' -Ref 'Test.App').Ok) 'duplicate winget Id refused'
    $r = Set-KitPackageDefault -Id 2 -On $false
    Check ($r.Status -eq 'dryrun' -and -not @(Get-KitCatalog | Where-Object Id -eq 2)[0].Default -and $r.Preview -like '*Notepad++ default off*') 'dry run default off'
    $r = Remove-KitPackage -Id ($max + 1)
    Check ($r.Status -eq 'dryrun' -and -not @(Get-KitCatalog | Where-Object Id -eq ($max + 1)).Count -and @(Get-KitRemovedPackages | Where-Object Id -eq ($max + 1)).Count) 'dry run remove -> removed list'
    $r = Add-KitPackage -Name 'Third' -Ref 'Test.Third'
    Check ($r.Package.Id -eq $max + 3) "Ids never reused (removed Id stays taken: got $($r.Package.Id))"
    $r = Restore-KitPackage -Id ($max + 1)
    Check ($r.Status -eq 'dryrun' -and @(Get-KitCatalog | Where-Object Id -eq ($max + 1)).Count -eq 1) 'dry run restore'
    $r = Set-KitSetting -Name 'removeShortcuts' -Value $false
    Check ($r.Status -eq 'dryrun' -and (Get-KitSetting 'removeShortcuts' $true) -eq $false) 'dry run setting'
    Check ([IO.File]::ReadAllText((Join-Path $kit 'config\catalog.json')) -eq $bundledBefore) 'dry run: no file written'
    Set-KitConfigMemoryOnly $false
    $r = Set-KitPackageDefault -Id 3 -On $false
    Check ($r.Status -eq 'nogh') 'real save without gh -> "nogh", nothing changed'

    # ---------------------------------------------------------------- learned heals while signed out
    $cat = @(Initialize-Kit -KitRoot $kit -Offline)
    & (Get-Module core) { Save-KitOverride -Old 'Old.Id' -New 'New.Id' }
    Check ((Get-KitConfigInfo).Pending -eq 1 -and (Get-KitPendingOverrides)['Old.Id'] -eq 'New.Id') 'heal without gh -> kept in pending-overrides.json'
    $cat = @(Initialize-Kit -KitRoot $kit -Offline)
    Check ((Get-KitOverrideCount) -ge 1) 'pending heals applied at the next start'

    # ---------------------------------------------------------------- publish
    $target = New-Scratch 'cfg-publish [98]'; $scratch += $target
    Set-Content -LiteralPath (Join-Path $target 'winget-id-overrides.json') -Value '{"legacy":true}'
    $pub = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\publish.ps1') -Target $target 2>&1 | Out-String
    $committed = -not (& git -C $repo status --porcelain -- config 2>$null)
    if ($committed) { Check ((Test-Path -LiteralPath (Join-Path $target 'config\catalog.json')) -and (Get-Content -LiteralPath (Join-Path $target 'winget-id-overrides.json') -Raw).Contains('legacy')) 'publish: config/*.json shipped, legacy root file untouched' }
    else { Check ((Get-Content -LiteralPath (Join-Path $target 'winget-id-overrides.json') -Raw).Contains('legacy') -and $pub -match 'uncommitted') 'publish: legacy root file untouched (config uncommitted, skipped)' }

    # ---------------------------------------------------------------- self-update + bootstrap (file:/// "GitHub")
    $up = New-Scratch 'cfg-update'; $scratch += $up
    $newer = Join-Path $up 'src-tree\my-win-kit-main'; New-Item -ItemType Directory -Path $newer -Force | Out-Null; Copy-Kit $newer
    $core = Join-Path $newer 'src\core.psm1'
    [IO.File]::WriteAllText($core, ([regex]::Replace([IO.File]::ReadAllText($core), "KitVersion\s*=\s*'[0-9.]+'", "KitVersion  = '9.9.9'")))
    Compress-Archive -Path (Join-Path $up 'src-tree\my-win-kit-main') -DestinationPath (Join-Path $up 'kit.zip')
    $env:MYWINKIT_RAW_URL = ([Uri]$newer).AbsoluteUri
    $env:MYWINKIT_ZIP_URL = ([Uri](Join-Path $up 'kit.zip')).AbsoluteUri
    $env:MYWINKIT_GH = ''
    $env:MYWINKIT_CONFIG_URL = 'http://127.0.0.1:9/config'
    Remove-Item Env:MYWINKIT_RUNLOG -ErrorAction SilentlyContinue
    $st2 = New-Scratch 'cfg-upstate'; $scratch += $st2; $env:MYWINKIT_STATE_DIR = $st2
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -UpdateAnswer y -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st2
    Check ($o -match 'Update kit [0-9.]+ -> 9\.9\.9' -and (Test-Path (Join-Path $st2 'app\9.9.9\install.ps1')) -and $log -match 'running kit v9\.9\.9' -and $log -match 'frontend: CLASSIC started' -and $o -match 'v9\.9\.9') 'self-update: asked, downloaded, verified, ran v9.9.9'
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $log = Get-LatestLog $st2
    Check ($o -notmatch 'Update kit' -and $log -match 'newer copy already on this PC: v9\.9\.9') 'self-update: next start uses the downloaded copy without asking'
    $st3 = New-Scratch 'cfg-upstate'; $scratch += $st3; $env:MYWINKIT_STATE_DIR = $st3
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -UpdateAnswer n -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    $o2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    Check (-not (Test-Path (Join-Path $st3 'app')) -and $o2 -notmatch 'Update kit' -and (Get-LatestLog $st3) -match 'declined earlier') 'self-update: decline is remembered (asked once per version)'
    # broken newer version -> fall back to this copy
    [IO.File]::WriteAllText($core, [IO.File]::ReadAllText($core) + "`nfunction Broken {")
    Remove-Item (Join-Path $up 'kit.zip'); Compress-Archive -Path (Join-Path $up 'src-tree\my-win-kit-main') -DestinationPath (Join-Path $up 'kit.zip')
    $st4 = New-Scratch 'cfg-upstate'; $scratch += $st4; $env:MYWINKIT_STATE_DIR = $st4
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -UpdateAnswer y -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
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
    $env:MYWINKIT_BOOTSTRAP_ARGS = ''

    # ---------------------------------------------------------------- real commits on a throwaway branch
    if ($Write) {
        $env:MYWINKIT_GH = ''; $env:MYWINKIT_CONFIG_URL = ''; $env:MYWINKIT_STATE_DIR = $state
        Import-Module (Join-Path $kit 'src\core.psm1') -Force
        if (-not (Test-KitGhLogin)) { Check $false 'gh signed in (needed for -Write)' }
        else {
            $gh = Get-KitGh
            $slug = '1nst4ll/my-win-kit'
            $from = (& git -C $repo rev-parse --abbrev-ref HEAD).Trim()
            $sha = (& $gh api "repos/$slug/git/ref/heads/$from" --jq .object.sha).Trim()
            $tb = "config-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            & $gh api -X POST "repos/$slug/git/refs" -f "ref=refs/heads/$tb" -f "sha=$sha" | Out-Null
            Write-Host "  (throwaway branch $tb from $from@$($sha.Substring(0,7)))" -ForegroundColor DarkGray
            try {
                $env:MYWINKIT_BRANCH = $tb
                Import-Module (Join-Path $kit 'src\core.psm1') -Force
                $cat = @(Initialize-Kit -KitRoot $kit)
                $k = (Get-KitConfigInfo).Kind
                Check ($k -in 'github', 'gh') "write: config read from GitHub ($k) on $tb"
                $r = Add-KitPackage -Name '7-Zip Test' -Ref '7zip.7zip' -Group 'UTIL' -On $false
                Check ($r.Status -eq 'saved' -and $r.Commit -like 'https://github.com/*') "write: add committed ($($r.Commit))"
                $newId = $r.Package.Id
                Check ((Set-KitPackageDefault -Id $newId -On $true).Status -eq 'saved') 'write: default on committed'
                Check ((Remove-KitPackage -Id $newId).Status -eq 'saved') 'write: remove committed'
                Check ((Restore-KitPackage -Id $newId).Status -eq 'saved') 'write: restore committed'
                $env:MYWINKIT_TEST_STALE_SHA = '1'
                $r = Set-KitSetting -Name 'dryRunByDefault' -Value $true
                $env:MYWINKIT_TEST_STALE_SHA = ''
                $rl = [IO.File]::ReadAllText($env:MYWINKIT_RUNLOG)
                Check ($r.Status -eq 'saved' -and $rl -match 'attempt 1 failed \(conflict\)' -and $rl -match "config/settings.json .*\(attempt 2\)") 'write: stale sha -> conflict -> re-fetch, re-apply, retry -> committed'
                & (Get-Module core) { Save-KitOverride -Old 'Old.Test' -New 'New.Test' }
                Check ((Get-KitConfigInfo).Pending -eq 0) 'write: heal pushed at once when signed in'
                $msgs = (& $gh api "repos/$slug/commits?sha=$tb&per_page=10" --jq '.[].commit.message') -join "`n"
                Check ($msgs -match 'config: add 7-Zip Test \(from' -and $msgs -match 'config: remove 7-Zip Test' -and $msgs -match 'config: setting dryRunByDefault = True' -and $msgs -match 'learned package-ID' -and $msgs -notmatch 'Co-Authored-By') 'write: commit messages on the branch (no co-author line)'
                $final = ConvertFrom-KitJsonText ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((& $gh api "repos/$slug/contents/config/catalog.json?ref=$tb" --jq .content) -join '') -replace '\s', '')))
                Check (@($final['Packages'] | Where-Object { $_['Ref'] -eq '7zip.7zip' -and $_['On'] -eq $true }).Count -eq 1) 'write: final catalog.json on GitHub has the package, default on'
            } finally {
                & $gh api -X DELETE "repos/$slug/git/refs/heads/$tb" | Out-Null
                $gone = (& $gh api "repos/$slug/git/ref/heads/$tb" 2>&1 | Out-String) -match '404|Not Found'
                Check $gone "throwaway branch $tb deleted"
            }
        }
    }
} finally {
    foreach ($n in $keepEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $keepEnv[$n]) }
    foreach ($d in $scratch) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fail -eq 0) { Write-Host 'test-config: all passed' -ForegroundColor Green } else { Write-Host "test-config: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
