#Requires -Version 5.1
<#
.SYNOPSIS
    Test src/core.psm1 and config/catalog.json without installing anything.
.DESCRIPTION
    1. Catalogue sanity (config/catalog.json, the bundled copy - offline unless -Online): unique Ids/names, known groups and methods, Direct
       keys exist, DEV/POST off by default, Interactive only where expected.
    2. -DryRun every package through Invoke-KitPackage (no side effects).
    3. -Online: also scan what's installed and resolve the direct downloads
       from the vendor pages (network).
    Runs under Windows PowerShell 5.1 and pwsh. Exit code = failures.
.EXAMPLE
    powershell -NoProfile -File tools\test-core.ps1
    pwsh -NoProfile -File tools\test-core.ps1 -Online
#>
[CmdletBinding()]
param([switch]$Online)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# scratch state folder: the per-PC preference tests below write local-settings.json there
$keepState = $env:MYWINKIT_STATE_DIR
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ('my-win-kit-core-' + [guid]::NewGuid().ToString('N'))
# -Online still tests THIS copy's config/*.json (a PR's catalogue), not GitHub main
$keepCfg = $env:MYWINKIT_CONFIG_URL
$env:MYWINKIT_CONFIG_URL = ([Uri](Join-Path $root 'config')).AbsoluteUri
Import-Module (Join-Path $root 'src\core.psm1') -Force

$script:fail = 0
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok    $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}

Write-Host "test-core: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$cat = @(Initialize-Kit -KitRoot $root -Offline:(-not $Online))
$groups = @(Get-KitGroups)
$data = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $root 'config\catalog.json')))

Check ($cat.Count -ge 50) "catalogue loads ($($cat.Count) packages)"
Check (@($cat.Id | Select-Object -Unique).Count -eq $cat.Count) 'package Ids are unique'
Check (@($cat.Name | Select-Object -Unique).Count -eq $cat.Count) 'package names are unique'
$gk = @($groups.Key)
Check (@($cat | Where-Object { $gk -notcontains $_.Group }).Count -eq 0) 'every package is in a known group'
Check (@($groups.Letter | Select-Object -Unique).Count -eq $groups.Count) 'group letters are unique'
$methods = 'winget', 'msstore', 'script', 'direct', 'npm', 'builtin'
Check (@($cat | Where-Object { $methods -notcontains $_.Method }).Count -eq 0) 'every method is known'
Check (@($cat | Where-Object { $_.Method -eq 'direct' -and -not $data['Direct'].Contains($_.Ref) }).Count -eq 0) 'every direct Ref has a Direct entry'
Check (@($cat | Where-Object { $_.Group -in 'DEV', 'POST' -and $_.Default }).Count -eq 0) 'DEV and POST are off by default'
Check (@($cat | Where-Object { $_.Group -eq 'POST' -and -not $_.Interactive }).Count -eq 0) 'POST items are Interactive (never under a spinner)'
Check (@($cat | Where-Object { $_.Method -eq 'script' -and $_.Ref -notmatch '^https://' }).Count -eq 0) 'script installers use https'
$ai = @($cat | Where-Object AI | ForEach-Object Name)
Check ($ai.Count -ge 4) "AI tools flagged: $($ai -join ', ')"
$order = @(Get-KitRunOrder $cat)
Check ($order[-1].Group -eq 'POST') 'run order puts POST last'

Write-Host 'catalogue changes 2026-11-26 (kit 2.5.0):'
$byId = @{}; foreach ($p in $cat) { $byId[$p.Id] = $p }
$removedIds = @(@($data['Removed']) | ForEach-Object { [int]$_['Id'] })
Check (-not $byId.ContainsKey(8) -and -not $byId.ContainsKey(33) -and $removedIds -contains 8 -and $removedIds -contains 33) 'Perplexity (8) and Samsung Quick Share (33) moved to Removed'
Check ($byId.ContainsKey(32) -and $byId[32].Ref -eq 'Google.QuickShare') 'Google Quick Share (32) kept'
Check (-not $byId[4].Default) 'Obsidian (4) is off by default'
foreach ($id in 53, 54) {
    $p = $byId[$id]
    Check ($p.AI -and -not $p.Default -and -not $p.On) "$($p.Name) ($id): AI-flagged and off by default (the AI flag ticks nothing)"
}
foreach ($id in 47, 56) { Check ($byId[$id].AI) "$($byId[$id].Name) ($id) is AI-flagged" }
Check (@($cat | Where-Object { $_.AI -and $_.Group -eq 'DEV' -and $_.Default }).Count -eq 0) 'no AI-flagged dev tool is in the recommended set'
$set = @(Get-KitAiUpdateSet -Installed @{ 53 = '1.0'; 7 = '140' })
Check ($set.Count -eq 1 -and $set[0].Id -eq 53) "AI update set = installed AI tools only (Cursor installed -> [$(@($set.Name) -join ', ')]; Codex not installed -> not touched)"
Check (@(Get-KitAiUpdateSet -Installed @{}).Count -eq 0) 'AI update set is empty when no AI tool is installed (never installs Codex/Cursor)'
$ctt = $byId[59]; $dev = $byId[60]; $wsl = $byId[61]
Check ($ctt -and $ctt.Method -eq 'script' -and $ctt.Interactive -and $ctt.Elevated -and $ctt.Shell -eq 'pwsh' -and -not $ctt.Default -and $ctt.Ref -eq 'https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1') 'Chris Titus prompt (59): official setup.ps1, pwsh, elevated, interactive, off'
Check ($dev -and $dev.Method -eq 'builtin' -and $dev.Ref -eq 'dev-folder' -and $dev.Default -and -not $dev.Interactive) 'Dev folder (60): builtin, on by default, runs under the progress view'
Check ($wsl -and $wsl.Method -eq 'builtin' -and $wsl.Ref -eq 'wsl-ubuntu' -and $wsl.Interactive -and $wsl.Group -eq 'DEV' -and -not $wsl.Default) 'WSL + Ubuntu (61): builtin, DEV, interactive, off'

Write-Host 'dry run (no installs):'
$installed = @{}
if ($Online) {
    $installed = Get-KitInstalled
    Check ($installed.Count -ge 0) "installed-state scan ($($installed.Count) found)"
}
foreach ($p in $order) {
    if ($p.Method -eq 'direct' -and -not $Online) { continue }
    $r = Invoke-KitPackage -Package $p -Installed $installed[$p.Id] -DryRun
    # blocked: Smart App Control is on here and the tool is unsigned (Hermes) - reported, not run
    $okStatus = $r.Status -in 'dryrun', 'current' -or ($r.Status -eq 'blocked' -and $r.Detail -like '*Smart App Control*')
    Check $okStatus ("{0,-22} {1,-7} {2}" -f $p.Name, $r.Status, $r.Detail)
}
if ($Online) {
    foreach ($k in @($data['Direct'].Keys)) {
        try { $d = Resolve-KitDirect -Key $k; Check ([bool]$d.Version) "direct $k -> v$($d.Version) $($d.FileName)" }
        catch { Check $false "direct $k resolve: $_" }
    }
}

Check (Test-KitVersionCurrent -Installed '2.8.0' -Latest '2.8.0') 'version compare: equal is current'
Check (-not (Test-KitVersionCurrent -Installed '2.5.5' -Latest '2.8.0')) 'version compare: older is not current'
Check (Test-KitVersionCurrent -Installed '6.28899.6.0' -Latest '6.28899.6') 'version compare: trailing .0'

Write-Host 'dev folder (Get-KitDevFolderPath, injected D: check + folder checks, every combination):'
$sys = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
$devCands = @('D:\dev\github', "$sys\dev\github", 'D:\dev\git', "$sys\dev\git")
$devBad = @()
foreach ($dt in 'Fixed', '', 'CDRom', 'Removable', 'Network') {
    $hasD = $dt -eq 'Fixed'
    for ($mask = 0; $mask -lt 16; $mask++) {
        $present = @(for ($b = 0; $b -lt 4; $b++) { if ($mask -band (1 -shl $b)) { $devCands[$b] } })
        $ex = { param($p) $present -contains $p }.GetNewClosure()
        # expected: the first existing candidate in order (D: ones only with a fixed D:), else a new dev\github
        $want = $null
        foreach ($c in $devCands) { if ($present -contains $c -and ($hasD -or $c -notlike 'D:*')) { $want = $c; break } }
        if (-not $want) { $want = if ($hasD) { 'D:\dev\github' } else { "$sys\dev\github" } }
        $got = Get-KitDevFolderPath -DDriveType $dt -Exists $ex
        if ($got -ne $want) { $devBad += "D:'$dt' present=[$($present -join ',')] got $got want $want" }
    }
}
Check (-not $devBad.Count) "80 combinations (D: fixed / none / CD / USB / network x 16 sets of existing folders): existing dev\github before dev\git, D: before C:, else a new dev\github$(if ($devBad.Count) { ': ' + ($devBad | Select-Object -First 3) -join '; ' })"
Check ((Get-KitDevFolderPath -DDriveType 'Fixed' -Exists { param($p) $p -eq "$sys\dev\github" }) -eq "$sys\dev\github") 'PC A: C:\dev\github exists, D: present -> C:\dev\github (nothing new on D:)'
Check ((Get-KitDevFolderPath -DDriveType 'Fixed' -Exists { param($p) $p -in 'D:\dev\github', "$sys\dev\git" }) -eq 'D:\dev\github') 'PC B: D:\dev\github wins over an old dev\git'
Check ((Get-KitDevFolderPath -DDriveType '' -Exists { param($p) $p -eq "$sys\dev\git" }) -eq "$sys\dev\git") 'PC C/D: only C:\dev\git -> reused, never moved or renamed'
$r = Invoke-KitDevFolder -DryRun -DDriveType '' -Exists { param($p) [void]$p; $false }
Check ($r.Status -eq 'dryrun' -and $r.Detail -eq "would create $sys\dev\github") "nothing there, no D: -> would create $sys\dev\github (dry run creates nothing)"
$r = Invoke-KitDevFolder -DryRun -DDriveType '' -Exists { param($p) $p -eq "$sys\dev\git" }
Check ($r.Status -eq 'current' -and $r.To -eq "$sys\dev\git") "an existing dev\git -> current, nothing created ($($r.Detail))"

Write-Host 'WSL (Select-KitUbuntuDistro on sample wsl --list --online output):'
$wslOnline = @('The following is a list of valid distributions that can be installed.', "Install using 'wsl.exe --install <Distro>'.", '',
    'NAME                            FRIENDLY NAME', 'AlmaLinux-9                     AlmaLinux OS 9', 'Debian                          Debian GNU/Linux',
    'Ubuntu                          Ubuntu', 'Ubuntu-25.10                    Ubuntu 25.10', 'Ubuntu-24.04                    Ubuntu 24.04 LTS',
    'Ubuntu-22.04                    Ubuntu 22.04 LTS', 'Ubuntu-20.04                    Ubuntu 20.04 LTS', 'openSUSE-Tumbleweed             openSUSE Tumbleweed')
Check ((Select-KitUbuntuDistro -Lines $wslOnline) -eq 'Ubuntu-24.04') 'picks the highest LTS (24.04), skips interim 25.10'
Check ((Select-KitUbuntuDistro -Lines ($wslOnline + @('Ubuntu-26.04                    Ubuntu 26.04 LTS'))) -eq 'Ubuntu-26.04') 'a newer LTS (26.04) wins when listed'
$utf16 = @($wslOnline | ForEach-Object { ($_.ToCharArray() | ForEach-Object { "$_`0" }) -join '' })
$utf16[0] = [string][char]0xFFFD + [string][char]0xFFFD + $utf16[0]
Check ((Select-KitUbuntuDistro -Lines $utf16) -eq 'Ubuntu-24.04') 'UTF-16 output read as UTF-8 (NULs, mangled BOM) parses the same'
Check ((Select-KitUbuntuDistro -Lines @('NAME    FRIENDLY NAME', 'Debian  Debian')) -eq 'Ubuntu') 'no versioned Ubuntu listed -> Ubuntu'
Check ((Select-KitUbuntuDistro -Lines @()) -eq 'Ubuntu') 'no output (offline) -> Ubuntu'
Check (Test-KitRebootNeeded -ExitCode 3010 -Out @()) 'reboot: exit 3010'
Check (Test-KitRebootNeeded -ExitCode 0 -Out @('The requested operation is successful. Changes will not be effective until the system is rebooted.')) 'reboot: "until the system is rebooted"'
Check (-not (Test-KitRebootNeeded -ExitCode 0 -Out @('Checking for updates.', 'The most recent version of Windows Subsystem for Linux is already installed.'))) 'reboot: not for an up-to-date wsl --update'

Write-Host 'per-PC preference: autoInstallEssentials (local override > settings.json > on; older name autoInstallPwsh still read):'
$a = Get-KitAutoInstallEssentials
Check ($a.On -and $a.Source -in 'shared', 'default') "no local choice -> settings.json value, else on ($($a.On), $($a.Source))"
Set-KitLocalPref -Name 'autoInstallEssentials' -Value $false
$a = Get-KitAutoInstallEssentials
Check (-not $a.On -and $a.Source -eq 'this PC') "local choice off wins over the shared on ($($a.On), $($a.Source))"
$lf = Get-KitLocalPrefsFile
Check ($lf -like "$($env:MYWINKIT_STATE_DIR)*" -and ([IO.File]::ReadAllText($lf)) -eq "{`n  `"autoInstallEssentials`": false`n}`n") 'stored in the state folder (local-settings.json, canonical JSON), not in config/'
Remove-Item -LiteralPath $lf -Force
Set-KitLocalPref -Name 'autoInstallPwsh' -Value $false
Check (-not (Get-KitAutoInstallEssentials).On -and -not (Get-KitAutoInstallPwsh).On) 'back-compat: an older local autoInstallPwsh = false still turns the essentials off'
Set-KitLocalPref -Name 'autoInstallEssentials' -Value $true
Check ((Get-KitAutoInstallEssentials).On -and (Get-KitAutoInstallEssentials).Source -eq 'this PC') 'the new name wins over the older one (local choice back on)'
$sj = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $root 'config\settings.json')))
Check ($sj.Contains('autoInstallEssentials') -and $sj['autoInstallEssentials'] -eq $true -and -not $sj.Contains('autoInstallPwsh')) 'config/settings.json: autoInstallEssentials = true (replaces autoInstallPwsh)'

Write-Host 'per-PC preference: elevateAtStart (local override > settings.json > on):'
$e = Get-KitElevateAtStart
Check ($e.On -and $e.Source -in 'shared', 'default') "no local choice -> settings.json value, else on ($($e.On), $($e.Source))"
Set-KitLocalPref -Name 'elevateAtStart' -Value $false
$e = Get-KitElevateAtStart
Check (-not $e.On -and $e.Source -eq 'this PC' -and (Get-KitAutoInstallEssentials).On) "local choice off wins, autoInstallEssentials untouched ($($e.On), $($e.Source))"
Set-KitLocalPref -Name 'elevateAtStart' -Value $true

Write-Host 'NoAdmin: installers that must not run as administrator (de-elevated from an elevated kit):'
$noAdmin = @($cat | Where-Object NoAdmin | ForEach-Object Id | Sort-Object)
Check (($noAdmin -join ',') -eq '10,36,38,46,53,55') "NoAdmin set = OneDrive, VS Code, GitHub Desktop, Claude Code CLI, Cursor, Antigravity IDE ($(@($cat | Where-Object NoAdmin | ForEach-Object Name) -join ', '))"
Check (@($cat | Where-Object { $_.NoAdmin -and ($_.Interactive -or $_.Elevated) }).Count -eq 0) 'NoAdmin is never on an Interactive or Elevated item'
$vs = $byId[36]; $np = $byId[2]
Check (Test-KitDeElevate -Package $vs -IsAdmin $true) 'routing: NoAdmin + elevated kit -> de-elevated'
Check (-not (Test-KitDeElevate -Package $vs -IsAdmin $false)) 'routing: NoAdmin + not elevated -> runs normally (already normal rights)'
Check (-not (Test-KitDeElevate -Package $np -IsAdmin $true)) 'routing: no NoAdmin + elevated -> runs elevated (no prompt)'
$fakeInter = [pscustomobject]@{ NoAdmin = $true; Interactive = $true }
Check (-not (Test-KitDeElevate -Package $fakeInter -IsAdmin $true)) 'routing: Interactive items are never de-elevated (they need the console)'
$keepAdm = $env:MYWINKIT_SIMULATE_ADMIN
$env:MYWINKIT_SIMULATE_ADMIN = '1'
$r = Invoke-KitPackage -Package $vs -Installed $null -DryRun
Check ($r.Status -eq 'dryrun' -and $r.Detail -like '*at normal user rights*') "dry run as admin says it runs at normal rights: $($r.Detail)"
$r = Invoke-KitPackage -Package $np -Installed $null -DryRun
Check ($r.Detail -notlike '*normal user rights*') "dry run as admin, ordinary app: $($r.Detail)"
$env:MYWINKIT_SIMULATE_ADMIN = '0'
$r = Invoke-KitPackage -Package $vs -Installed $null -DryRun
Check ($r.Detail -notlike '*normal user rights*') "dry run not elevated: no de-elevation ($($r.Detail))"
$env:MYWINKIT_SIMULATE_ADMIN = $keepAdm
$keepDe = $env:MYWINKIT_SIMULATE_DEELEVATE
$env:MYWINKIT_SIMULATE_DEELEVATE = 'ok'
$d = Invoke-KitDeElevated -FilePath 'winget' -ArgumentList @('install', '--id', 'X')
Check ($d.Started -and $d.Ec -eq 0 -and "$($d.Out)" -like '*simulated*') 'de-elevation helper (simulated ok): exit 0, no task created'
$env:MYWINKIT_SIMULATE_DEELEVATE = 'fail'
Check ((Invoke-KitDeElevated -FilePath 'winget').Ec -eq 1) 'de-elevation helper (simulated fail): exit 1'
$env:MYWINKIT_SIMULATE_DEELEVATE = $keepDe
# The script a de-elevated task runs: run it directly here (normal child process, no task) and read its files back
$dt = Join-Path ([IO.Path]::GetTempPath()) ('my-win-kit-deel-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dt | Out-Null
try {
    $txt = Get-KitDeElevatedCommand -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', "echo it's `"quoted`" & exit 5") -OutFile (Join-Path $dt 'o.txt') -EcFile (Join-Path $dt 'e.txt')
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($txt))
    $pr = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    $oTxt = if (Test-Path (Join-Path $dt 'o.txt')) { [IO.File]::ReadAllText((Join-Path $dt 'o.txt')).Trim() } else { '' }
    $eTxt = if (Test-Path (Join-Path $dt 'e.txt')) { [IO.File]::ReadAllText((Join-Path $dt 'e.txt')).Trim() } else { '' }
    Check ($pr.Ec -eq 5 -and $eTxt -eq '5' -and $oTxt -like "*it's*quoted*") "de-elevated task script: output + exit code written (ec=$($pr.Ec), file ec=$eTxt, out=$oTxt)"
} finally { Remove-Item -LiteralPath $dt -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'unattended run plan (Get-KitAutoPlan on injected data, no scan):'
$inj = @{ 2 = '8.1'; 36 = '1.100'; 46 = '2.0.1'; 47 = '1.0.0'; 59 = ''; 61 = '24.04' }
$plan = Get-KitAutoPlan -Installed $inj -Updates @{ 2 = '8.9' } -UpgradeLines @() -Pinned @() -Packages $cat
$inIds = @($plan.Install | ForEach-Object Id); $upIds = @($plan.Update | ForEach-Object Id); $skIds = @($plan.Skipped | ForEach-Object Id)
$recMissing = @($cat | Where-Object { $_.Default -and -not $inj.ContainsKey($_.Id) } | ForEach-Object Id)
Check (($inIds | Sort-Object) -join ',' -eq (($recMissing | Sort-Object) -join ',')) "installs every recommended app that is missing ($($inIds.Count))"
Check (($upIds | Sort-Object) -join ',' -eq '2,46,47') "updates: winget app with an update (2), script tool with a native updater (46), npm tool (47) -> [$($upIds -join ',')]"
Check ($upIds -notcontains 36) 'an installed app with no update is left alone (36)'
Check (($skIds | Sort-Object) -join ',' -eq '59,61') "skipped (needs you): installed Interactive items (Chris Titus prompt 59, WSL 61) -> [$($skIds -join ',')]"
Check (@($plan.Run | Where-Object { $_.Interactive -or $_.Group -eq 'POST' }).Count -eq 0) 'never runs an Interactive or POST item'
Check (@($plan.Run).Count -eq $inIds.Count + $upIds.Count) 'run list = install + update'
Check ((Get-KitAutoExitCode -Results @([pscustomobject]@{ Status = 'installed' }, [pscustomobject]@{ Status = 'current' })) -eq 0) 'exit code 0 when nothing failed'
Check ((Get-KitAutoExitCode -Results @([pscustomobject]@{ Status = 'installed' }, [pscustomobject]@{ Status = 'failed' })) -eq 1) 'exit code 1 when anything failed'
Check ((Get-KitAutoExitCode -Results @()) -eq 0) 'exit code 0 when there was nothing to do'

Write-Host 'update everything (Get-KitUpdateAllPlan on sample winget upgrade output, no winget run):'
$wu = @(
    '   - \ ',
    'Name                               Id                          Version        Available      Source',
    '---------------------------------------------------------------------------------------------------',
    'Git                                Git.Git                     2.55.0.5       2.56.1         winget',
    'Microsoft Visual Studio Code       Microsoft.VisualStudioCode  1.140.0        1.148.0        winget',
    'FFmpeg                             Gyan.FFmpeg                 9.0.2          9.1            winget',
    'Node.js                            OpenJS.NodeJS               24.19.0        24.22.3        winget',
    'Pinned Tool                        Some.Pinned                 1.0            2.0            winget',
    'Odd App                            Odd.Unknown                 Unknown        3.0            winget',
    'Range App                          Range.App                   < 5.0          5.1            winget',
    'WhatsApp                           9NKSQGP7F2NH                2.2540.1.0     2.2546.3.0     msstore',
    '8 upgrades available.',
    '',
    'The following packages have an upgrade available, but require explicit targeting for upgrade:',
    'Name        Id               Version  Available Source',
    '------------------------------------------------------',
    'Explicit    Explicit.Only    1.0      2.0       winget'
)
$rows = @(ConvertFrom-KitWingetUpgradeText -Lines $wu)
Check ($rows.Count -eq 8 -and $rows[2].Id -eq 'Gyan.FFmpeg' -and $rows[2].Version -eq '9.0.2' -and $rows[2].Available -eq '9.1' -and $rows[2].Source -eq 'winget') "parses the first table only ($($rows.Count) rows; footer and explicit-targeting table left out)"
$ap = Get-KitUpdateAllPlan -Installed @{ 37 = '2.55.0.5'; 36 = '1.140.0'; 18 = '2.2540.1.0'; 46 = '2.0.1'; 59 = '' } -Updates @{ 37 = '2.56.1'; 36 = '1.148.0'; 18 = '2.2546.3.0' } -UpgradeLines $wu -Pinned @('Some.Pinned') -Packages $cat
$kitIds = @($ap.Kit | ForEach-Object Id | Sort-Object); $oth = @($ap.Other | ForEach-Object Ref)
Check (($kitIds -join ',') -eq '36,37,46') "kit half: catalogue apps with updates + native updater, not the Interactive Chris Titus prompt -> [$($kitIds -join ',')]"
Check ((@($ap.SelfUpdating | ForEach-Object Id) -join ',') -eq '18' -and @($ap.Run | Where-Object Id -eq 18).Count -eq 0) "SelfUpdates: WhatsApp (18, updates itself) listed apart and left out of Run -> [$(@($ap.SelfUpdating | ForEach-Object Name) -join ', ')]"
Check (($oth -join ',') -eq 'Gyan.FFmpeg,OpenJS.NodeJS') "rest of PC: only rows outside the catalogue -> [$($oth -join ', ')]"
$exc = @{}; foreach ($x in $ap.Excluded) { $exc[$x.Id] = $x.Why }
Check ($exc['Git.Git'] -eq 'in the catalogue' -and $exc['9NKSQGP7F2NH'] -eq 'in the catalogue' -and $exc['Some.Pinned'] -eq 'pinned' -and $exc['Odd.Unknown'] -eq 'unknown version' -and $exc['Range.App'] -eq 'unknown version') 'left out: catalogue IDs (winget + Store), pinned, unknown and ranged versions'
Check (@($ap.Other | Where-Object { $_.Id -ge 0 -or $_.Method -ne 'winget-upgrade' }).Count -eq 0 -and @($ap.Run).Count -eq 5 -and $ap.Run[-1].Method -eq 'winget-upgrade') 'other apps: negative Ids, Method winget-upgrade, run after the kit apps'
$ff = $ap.Other[0]
$r = Invoke-KitPackage -Package $ff -DryRun
Check ($r.Status -eq 'dryrun' -and $r.From -eq '9.0.2' -and $r.To -eq '9.1' -and $r.Detail -eq 'winget upgrade Gyan.FFmpeg') "dry run of an other app: $($r.Detail) ($($r.From) -> $($r.To))"
Check (@(Get-KitUpdateAllPlan -Installed @{} -UpgradeLines @() -Pinned @() -Packages $cat).Run.Count -eq 0) 'nothing installed, nothing to upgrade -> empty plan'

Write-Host 'failure reasons (a short line instead of "see log"):'
$fl = & (Get-Module core) { Get-KitFailLine -Out @('Updating Hermes Agent...', "Program 'hermes.exe' failed to run: An Application Control policy has blocked this file.", '') }
Check ($fl -like '*Application Control policy has blocked*') "picks the line that names the problem: $fl"
$fake = [pscustomobject]@{ Id = 990; Name = 'Fake updater'; Group = 'DEV'; GroupOrder = 0; Method = 'script'; Ref = 'https://example.invalid/x.ps1'; Update = 'my-win-kit-no-such-tool update'; Exe = $null; Requires = $null; Interactive = $false; Elevated = $false; Shell = $null; NoAdmin = $false; Version = $null; Detect = $null }
$r = Invoke-KitPackage -Package $fake -Installed '1.0'
Check ($r.Status -eq 'failed' -and $r.Detail -notlike '*see log*' -and $r.Detail -like '*(exit 1)') "a failed updater reports its reason: $($r.Detail)"

Write-Host 'winget exit codes (Get-KitWingetOutcome, no winget run):'
$o = Get-KitWingetOutcome -ExitCode 0 -Out @('Successfully installed')
Check ($o.Status -eq 'ok') "exit 0 is ok ($($o.Status))"
# Seen on this kit: `winget install` on an up-to-date app exits 0x8A15002B
$o = Get-KitWingetOutcome -ExitCode -1978335189 -Out @('No available upgrade found.', 'No newer package versions are available from the configured sources.')
Check ($o.Status -eq 'current') "0x8A15002B UPDATE_NOT_APPLICABLE is current ($($o.Status))"
foreach ($c in @(-1978335153, -1978335135, -1978334962)) {
    $o = Get-KitWingetOutcome -ExitCode $c
    Check ($o.Status -eq 'current') ('0x{0:X8} (nothing to do) is current ({1})' -f $c, $o.Status)
}
# The real failure from 2026-11-25: Git upgrade, installer exit 1, winget 0x8A150006
$gitOut = @('Found an existing package already installed. Trying to upgrade the installed package...', 'Found Git [Git.Git] Version 2.56.1',
    'Downloading https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/Git-2.56.1-64-bit.exe', 'Successfully verified installer hash',
    'Starting package install...', 'The installer will request to run as administrator. Expect a prompt.', 'Installer failed with exit code: 1',
    'Installer log is available at: C:\Temp\Git.Git.2.56.1.log')
$o = Get-KitWingetOutcome -ExitCode -1978335226 -Out $gitOut
Check ($o.Status -eq 'failed' -and $o.Reason -eq 'Installer failed with exit code: 1 (winget 0x8A150006)') "failed upgrade is failed, not current ($($o.Status): $($o.Reason))"
$o = Get-KitWingetOutcome -ExitCode -1978335212 -Out @('No package found matching input criteria.')
Check ($o.Status -eq 'failed' -and $o.Reason -like 'No package found*0x8A150014*') "ID not found is failed ($($o.Reason))"
$o = Get-KitWingetOutcome -ExitCode 1 -Out $null
Check ($o.Status -eq 'failed' -and $o.Reason -eq 'winget 0x00000001') "no output still gives a reason ($($o.Reason))"

Write-Host 'child processes (Invoke-KitProcess):'
$r = Invoke-KitProcess -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'echo hello& echo oops 1>&2& exit 3')
Check ($r.Started -and $r.Ec -eq 3 -and $r.Out[0] -eq 'hello' -and $r.Err[0].Trim() -eq 'oops') "returns stdout, stderr and exit code (ec=$($r.Ec))"
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('my-win-kit-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    $echo = Join-Path $tmpDir 'echo args.ps1'
    Set-Content -LiteralPath $echo -Value 'foreach ($a in $args) { "<$a>" }' -Encoding ASCII
    $r = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echo, 'a b', 'c"d', 'e\', '', 'f')
    Check (($r.Out -join ' ') -eq '<a b> <c"d> <e\> <> <f>') "arguments arrive intact: $($r.Out -join ' ')"
    $cmdFile = Join-Path $tmpDir 'tool.cmd'
    Set-Content -LiteralPath $cmdFile -Value "@echo off`r`necho got %~1`r`nexit /b 4" -Encoding ASCII
    $r = Invoke-KitProcess -FilePath $cmdFile -ArgumentList @('x y')
    Check ($r.Ec -eq 4 -and $r.Out[0] -eq 'got x y') ".cmd files run through cmd.exe (ec=$($r.Ec), '$($r.Out -join '|')')"
    $r = Invoke-KitProcess -FilePath 'my-win-kit-no-such-tool' -ArgumentList @('x')
    Check (-not $r.Started -and $r.Ec -ne 0) 'a missing program reports Started = false'

    # The bug this guards against: under pwsh in conhost, `& exe` switches VT processing
    # off on the shared console. A child that clears VT on CONOUT$ must not reach ours.
    if (Enable-KitConsoleVt) {
        $clear = Join-Path $tmpDir 'clear-vt.ps1'
        Set-Content -LiteralPath $clear -Encoding ASCII -Value @'
Add-Type -Namespace T -Name C -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateFileW(string n, int a, int s, IntPtr p, int c, int f, IntPtr t); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);'
$h = [T.C]::CreateFileW('CONOUT$', 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
$m = [uint32]0; [void][T.C]::GetConsoleMode($h, [ref]$m); [void][T.C]::SetConsoleMode($h, [uint32]($m -band (-bnot 4)))
[void][T.C]::GetConsoleMode($h, [ref]$m); 'child-mode=0x{0:X}' -f $m
'@
        $h = [MyWinKit.ConsoleMode]::GetStdHandle(-11); $m = [uint32]0
        $r = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $clear)
        [void][MyWinKit.ConsoleMode]::GetConsoleMode($h, [ref]$m)
        $childOff = "$($r.Out)" -match 'child-mode=0x[0-9A-F]*[0-389AB]$'
        Check ($childOff -and ($m -band 4) -ne 0) ('a child that clears VT on its console leaves ours on ({0}, ours 0x{1:X})' -f "$($r.Out)", $m)
        [void][MyWinKit.ConsoleMode]::SetConsoleMode($h, [uint32]($m -band (-bnot 4)))
        $ok = Enable-KitConsoleVt
        [void][MyWinKit.ConsoleMode]::GetConsoleMode($h, [ref]$m)
        Check ($ok -and ($m -band 4) -ne 0) ('Enable-KitConsoleVt switches VT back on (mode 0x{0:X})' -f $m)
    } else {
        Write-Host '  skip  console-mode checks (output is not a console; run in a console window to include them)' -ForegroundColor DarkGray
    }
} finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'essentials: Windows Terminal settings merge (scratch files only, never this PC''s Terminal):'
$wt = Join-Path $env:MYWINKIT_STATE_DIR 'wt'
New-Item -ItemType Directory -Path $wt -Force | Out-Null
$claudeGuid = '{b7a91c2d-4e83-4f6a-9d25-1c3f8ae60b74}'
$desired = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $root 'config\terminal.json')))
Check ($desired['defaultProfile'] -eq $claudeGuid -and @($desired['profiles'])[0]['guid'] -eq $claudeGuid) 'config/terminal.json: the Claude Code profile is the default profile'
# a fresh PC: Terminal never started, no settings.json yet
$f1 = Join-Path $wt 'fresh\settings.json'
$r = Merge-KitTerminalSettings -Path $f1 -Desired $desired -StartingDirectory 'C:\dev\git'
$d = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($f1))
$list = @($d['profiles']['list'])
Check ($r.Status -eq 'done' -and $d['defaultProfile'] -eq $claudeGuid -and $list.Count -eq 2 -and $list[1]['name'] -eq 'my-win-kit' -and $list[0]['name'] -eq 'Claude Code' -and $list[0]['commandline'] -eq 'pwsh.exe -NoExit -Command claude') "fresh: settings.json created with the Claude Code profile as default ($($r.Detail))"
Check ($d['profiles']['defaults']['font']['face'] -eq 'CaskaydiaCove Nerd Font Mono' -and $d['profiles']['defaults']['colorScheme'] -eq 'Dark+' -and $d['profiles']['defaults']['opacity'] -eq 90 -and $d['profiles']['defaults']['startingDirectory'] -eq 'C:\dev\git') 'fresh: profile defaults (font, Dark+, opacity 90, starting folder)'
Check (@($d['keybindings']).Count -eq 3 -and $d['copyOnSelect'] -eq $false -and $d['useAcrylicInTabRow'] -eq $true -and @($d['newTabMenu'])[0]['type'] -eq 'remainingProfiles') 'fresh: globals + 3 key bindings'
Check ($list[0]['icon'] -eq ([string][char]0xD83E + [char]0xDD16) -and -not ([IO.File]::ReadAllText($f1) -match '[^\x00-\x7F]')) 'fresh: robot icon kept, file stays ASCII (\u escapes)'
Check (@(Get-ChildItem -LiteralPath (Split-Path $f1) -Filter '*.bak-my-win-kit-*').Count -eq 0) 'fresh: no backup for a new file'
# an existing file with comments, a trailing comma, other profiles, schemes and actions
$f2 = Join-Path $wt 'existing\settings.json'
New-Item -ItemType Directory -Path (Split-Path $f2) -Force | Out-Null
$sample = @'
// Terminal settings with comments
{
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", // Windows PowerShell
    /* a block comment */
    "theme": "dark",
    "actions": [ { "command": { "action": "copy", "singleLine": false }, "id": "User.copy.644BA8F2" } ],
    "keybindings": [ { "id": "User.copy.644BA8F2", "keys": "ctrl+c" }, { "id": "Terminal.FindText", "keys": "ctrl+shift+f" } ],
    "profiles": {
        "defaults": { "font": { "size": 11 }, "opacity": 100 },
        "list": [
            { "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "name": "Windows PowerShell", "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "hidden": false },
            { "guid": "{b7a91c2d-4e83-4f6a-9d25-1c3f8ae60b74}", "name": "Claude Code", "commandline": "old", "tabTitle": "mine" },
        ]
    },
    "schemes": [ { "name": "Mine // not a comment", "background": "#000000" } ]
}
'@
[IO.File]::WriteAllText($f2, $sample)
$r = Merge-KitTerminalSettings -Path $f2 -Desired $desired -StartingDirectory 'D:\dev\git'
$d = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($f2))
$list = @($d['profiles']['list'])
$cl = @($list | Where-Object { $_['guid'] -eq $claudeGuid })
Check ($r.Status -eq 'done' -and $r.Backup -and ([IO.File]::ReadAllText($r.Backup)) -eq $sample -and (Split-Path -Leaf $r.Backup) -like 'settings.json.bak-my-win-kit-2*') "existing: backed up first ($(Split-Path -Leaf $r.Backup))"
Check ($d['theme'] -eq 'dark' -and @($d['schemes'])[0]['name'] -eq 'Mine // not a comment' -and @($d['actions']).Count -eq 1 -and $list.Count -eq 3 -and @($list | Where-Object { $_['name'] -eq 'Windows PowerShell' }).Count -eq 1) 'existing: other profiles, schemes, actions, theme kept (comments and a trailing comma read fine)'
Check ($cl.Count -eq 1 -and $cl[0]['commandline'] -eq 'pwsh.exe -NoExit -Command claude' -and $cl[0]['tabTitle'] -eq 'mine' -and $d['defaultProfile'] -eq $claudeGuid) 'existing: the Claude Code profile updated by guid (own keys kept), made the default'
Check ($d['profiles']['defaults']['font']['size'] -eq 11 -and $d['profiles']['defaults']['font']['face'] -eq 'CaskaydiaCove Nerd Font Mono' -and $d['profiles']['defaults']['opacity'] -eq 90) 'existing: profile defaults merged (font size kept, face set, opacity 90)'
$kb = @($d['keybindings'])
Check ($kb.Count -eq 4 -and @($kb | Where-Object { $_['keys'] -eq 'ctrl+c' }).Count -eq 1 -and @($kb | Where-Object { $_['keys'] -eq 'ctrl+c' })[0]['id'] -eq 'Terminal.CopyToClipboard' -and @($kb | Where-Object { $_['id'] -eq 'Terminal.FindText' }).Count -eq 1) 'existing: key bindings merged by id (ctrl+c re-bound, others kept)'
$t2 = [IO.File]::ReadAllText($f2); $baks = @(Get-ChildItem -LiteralPath (Split-Path $f2) -Filter '*.bak-my-win-kit-*').Count
$r = Merge-KitTerminalSettings -Path $f2 -Desired $desired -StartingDirectory 'D:\dev\git'
Check ($r.Status -eq 'current' -and [IO.File]::ReadAllText($f2) -eq $t2 -and @(Get-ChildItem -LiteralPath (Split-Path $f2) -Filter '*.bak-my-win-kit-*').Count -eq $baks) 'idempotent: second run = no write, no new backup'
$r = Merge-KitTerminalSettings -Path $f2 -Desired $desired -StartingDirectory 'E:\elsewhere' -DryRun
Check ($r.Status -eq 'dryrun' -and [IO.File]::ReadAllText($f2) -eq $t2 -and $r.Detail -like '*startingDirectory*') "dry run: says what would change, writes nothing ($($r.Detail))"
$f3 = Join-Path $wt 'broken\settings.json'
New-Item -ItemType Directory -Path (Split-Path $f3) -Force | Out-Null
[IO.File]::WriteAllText($f3, '{ "profiles": [ broken')
$r = Merge-KitTerminalSettings -Path $f3 -Desired $desired
Check ($r.Status -eq 'failed' -and [IO.File]::ReadAllText($f3) -eq '{ "profiles": [ broken') "a file that does not parse is never overwritten ($($r.Detail))"
$f4 = Join-Path $wt 'nofont\settings.json'
$r = Merge-KitTerminalSettings -Path $f4 -Desired $desired -NoFont -NoDefaultProfile
$d = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($f4))
Check (-not $d['profiles']['defaults'].Contains('font') -and -not $d.Contains('defaultProfile') -and @($d['profiles']['list']).Count -eq 2) '-NoFont (Nerd Font missing) / -NoDefaultProfile (no PowerShell 7): left out'
$legacy = Join-Path $wt 'legacy\settings.json'
New-Item -ItemType Directory -Path (Split-Path $legacy) -Force | Out-Null
[IO.File]::WriteAllText($legacy, '{ "profiles": [ { "guid": "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}", "name": "cmd" } ] }')
$r = Merge-KitTerminalSettings -Path $legacy -Desired $desired
$d = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($legacy))
Check ($r.Status -eq 'done' -and @($d['profiles']['list']).Count -eq 3 -and $d['profiles']['defaults'] -is [System.Collections.IDictionary]) 'old-style profiles list: wrapped into { defaults, list }, entries kept'

Write-Host 'essentials: Terminal starting folder:'
$od = Join-Path $wt 'od'
$env:MYWINKIT_TEST_OD = $od
$s1 = Resolve-KitTerminalStartDir -Prefer '%MYWINKIT_TEST_OD%\.playground' -Fallback (Join-Path $wt 'devgit') -DryRun
Check ($s1.Source -eq 'fallback' -and $s1.Path -eq (Join-Path $wt 'devgit') -and -not (Test-Path -LiteralPath (Join-Path $wt 'devgit'))) "%OneDrive%\.playground missing -> the dev folder (dry run: not created)"
$s1 = Resolve-KitTerminalStartDir -Prefer '%MYWINKIT_TEST_OD%\.playground' -Fallback (Join-Path $wt 'devgit')
Check ($s1.Source -eq 'fallback' -and $s1.Created -and (Test-Path -LiteralPath (Join-Path $wt 'devgit'))) 'missing dev folder is created'
New-Item -ItemType Directory -Path (Join-Path $od '.playground') -Force | Out-Null
$s1 = Resolve-KitTerminalStartDir -Prefer '%MYWINKIT_TEST_OD%\.playground' -Fallback (Join-Path $wt 'devgit')
Check ($s1.Source -eq 'prefer' -and $s1.Path -eq (Join-Path $od '.playground')) 'the playground folder wins when it exists'
$s1 = Resolve-KitTerminalStartDir -Prefer '%MYWINKIT_NO_SUCH_VAR%\.playground' -Fallback (Join-Path $wt 'devgit')
Check ($s1.Source -eq 'fallback') 'an unset variable (no OneDrive) -> the dev folder'
Remove-Item Env:MYWINKIT_TEST_OD
Check ((Get-KitDevFolderPath -DDriveType 'Fixed' -Exists { param($p) [void]$p; $false }) -eq 'D:\dev\github') 'default fallback = the dev folder logic (Id 60)'
$s1 = Resolve-KitTerminalStartDir -Prefer 'dev-folder' -DryRun
Check ($s1.Path -eq (Get-KitDevFolderPath)) "prefer 'dev-folder' (the keyword in config/terminal.json) = the dev folder: $($s1.Path)"
$tjd = ConvertFrom-KitJsonText ([IO.File]::ReadAllText((Join-Path $root 'config\terminal.json')))
Check ($tjd['startingDirectory']['prefer'] -eq 'dev-folder') 'config/terminal.json: startingDirectory.prefer = dev-folder'
# a kit-managed profile that carries its own folder (a PC's Claude Code profile) is moved to the dev folder; other profiles keep theirs
$f5 = Join-Path $wt 'ownfolder\settings.json'
New-Item -ItemType Directory -Path (Split-Path $f5) -Force | Out-Null
[IO.File]::WriteAllText($f5, '{ "profiles": { "defaults": {}, "list": [ { "guid": "{b7a91c2d-4e83-4f6a-9d25-1c3f8ae60b74}", "name": "Claude Code", "startingDirectory": "E:\\old\\.playground" }, { "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "name": "Windows PowerShell", "startingDirectory": "E:\\mine" } ] } }')
$r = Merge-KitTerminalSettings -Path $f5 -Desired $desired -StartingDirectory 'D:\dev\git'
$d = ConvertFrom-KitJsoncText ([IO.File]::ReadAllText($f5))
$cl = @(@($d['profiles']['list']) | Where-Object { $_['guid'] -eq $claudeGuid }); $wp = @(@($d['profiles']['list']) | Where-Object { $_['name'] -eq 'Windows PowerShell' })
Check ($r.Status -eq 'done' -and $cl[0]['startingDirectory'] -eq 'D:\dev\git' -and $wp[0]['startingDirectory'] -eq 'E:\mine' -and $d['profiles']['defaults']['startingDirectory'] -eq 'D:\dev\git') 'kit profile with its own folder -> the dev folder; a non-kit profile keeps its own; defaults set'

Write-Host 'essentials: default terminal app (registry through a stub, never the real one):'
$reg = @{}
$stub = @{ Read = { param($n) [string]$reg[$n] }.GetNewClosure(); Write = { param($n, $v) $reg[$n] = $v }.GetNewClosure() }
$r = Set-KitDefaultTerminal -Registry $stub -DryRun
Check ($r.Status -eq 'dryrun' -and $reg.Count -eq 0) "dry run writes nothing ($($r.Detail))"
$r = Set-KitDefaultTerminal -Registry $stub
Check ($r.Status -eq 'done' -and $reg['DelegationConsole'] -eq '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' -and $reg['DelegationTerminal'] -eq '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}') 'sets DelegationConsole + DelegationTerminal to Windows Terminal (stable)'
$reg['Touched'] = 'no'
$r = Set-KitDefaultTerminal -Registry $stub
Check ($r.Status -eq 'current' -and $reg.Count -eq 3) 'already set -> current, no write'
$reg['DelegationTerminal'] = '{86633F1F-6454-40EC-89CE-DA4EBA977EE2}'
$r = Set-KitDefaultTerminal -Registry $stub
Check ($r.Status -eq 'done' -and $reg['DelegationTerminal'] -eq '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}') 'another terminal (Preview) -> switched to Windows Terminal'

Write-Host 'essentials: CaskaydiaCove Nerd Font:'
$fd = Join-Path $wt 'fonts'; New-Item -ItemType Directory -Path $fd -Force | Out-Null
Check (-not (Test-KitNerdFont -FontDirs @($fd) -RegistryNames @())) 'not installed: empty fonts folder, no registry entry'
Check ([bool](Test-KitNerdFont -FontDirs @($fd) -RegistryNames @('Consolas (TrueType)', 'CaskaydiaCove Nerd Font Mono Bold (TrueType)'))) 'installed: a Fonts registry entry names CaskaydiaCove Nerd Font Mono'
Check (-not (Test-KitNerdFont -FontDirs @($fd) -RegistryNames @('CaskaydiaCove Nerd Font Propo (TrueType)'))) 'the Propo variant alone does not count'
[IO.File]::WriteAllText((Join-Path $fd 'CaskaydiaCoveNerdFontMono-Regular.ttf'), 'x')
Check ((Test-KitNerdFont -FontDirs @($fd) -RegistryNames @()) -like '*CaskaydiaCoveNerdFontMono-Regular.ttf') 'installed: the Mono file is in a fonts folder'
Check ((ConvertTo-KitFontRegName 'CaskaydiaCoveNerdFontMono-BoldItalic.ttf') -eq 'CaskaydiaCove Nerd Font Mono Bold Italic (TrueType)' -and (ConvertTo-KitFontRegName 'CaskaydiaCoveNerdFont-Regular.ttf') -eq 'CaskaydiaCove Nerd Font (TrueType)') 'registry names from file names'
$relJson = '{ "tag_name": "v3.5.1", "assets": [ { "name": "CascadiaCode.tar.xz", "size": 1, "browser_download_url": "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/CascadiaCode.tar.xz", "digest": "sha256:ae598e9401e2846aa3ee364513715de0490b844a4b54f0768991f45f23aa8369" }, { "name": "CascadiaCode.zip", "size": 56585471, "browser_download_url": "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/CascadiaCode.zip", "digest": "sha256:1298BF92698AFA06185CF1D05E6AE05F2D8A1E8C3CB45DDF4C3035168AB342A1" }, { "name": "SHA-256.txt", "size": 11898, "browser_download_url": "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/SHA-256.txt" } ] }'
$rel = Get-KitNerdFontRelease -Json $relJson
Check ($rel.Tag -eq 'v3.5.1' -and $rel.Url -eq 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/CascadiaCode.zip' -and $rel.Sha256 -eq '1298bf92698afa06185cf1d05e6ae05f2d8a1e8c3cb45ddf4c3035168ab342a1' -and $rel.ChecksumUrl -like '*/SHA-256.txt' -and $rel.Size -eq 56585471) 'latest release: CascadiaCode.zip URL + published SHA-256 from the GitHub API answer'
$rel = Get-KitNerdFontRelease -Json ($relJson -replace ', "digest": "sha256:1298[0-9A-F]+"', '')
Check ($rel.Sha256 -eq '' -and $rel.ChecksumUrl) 'no digest on the asset -> falls back to the release''s SHA-256.txt'
$threw = $false; try { [void](Get-KitNerdFontRelease -Json '{ "tag_name": "v9", "assets": [] }') } catch { $threw = $true }
Check $threw 'a release without CascadiaCode.zip -> error (nothing installed)'
Check ((Get-KitSha256FromList -Text "ae598e9401e2846aa3ee364513715de0490b844a4b54f0768991f45f23aa8369  CascadiaCode.tar.xz`n1298bf92698afa06185cf1d05e6ae05f2d8a1e8c3cb45ddf4c3035168ab342a1  CascadiaCode.zip`n" -Name 'CascadiaCode.zip') -eq '1298bf92698afa06185cf1d05e6ae05f2d8a1e8c3cb45ddf4c3035168ab342a1') 'SHA-256.txt: the line for CascadiaCode.zip'
# install from a local zip into a scratch fonts folder (no network, no real registry)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zsrc = Join-Path $wt 'zipsrc'; New-Item -ItemType Directory -Path (Join-Path $zsrc 'sub') -Force | Out-Null
foreach ($n in 'CaskaydiaCoveNerdFontMono-Regular.ttf', 'CaskaydiaCoveNerdFontMono-Bold.ttf', 'CaskaydiaCoveNerdFont-Regular.ttf', 'CaskaydiaCoveNerdFontPropo-Regular.ttf', 'README.md') { [IO.File]::WriteAllText((Join-Path $zsrc "sub\$n"), $n) }
$zip = Join-Path $wt 'CascadiaCode.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($zsrc, $zip)
$fd2 = Join-Path $wt 'fonts2'
$freg = @{}
$fstub = @{ Read = { param($n) [string]$freg[$n] }.GetNewClosure(); Write = { param($n, $v) $freg[$n] = $v }.GetNewClosure() }
$r = Install-KitNerdFont -ZipPath $zip -FontDir $fd2 -Registry $fstub -IsAdmin $false -DryRun
Check ($r.Status -eq 'dryrun' -and -not (Test-Path -LiteralPath $fd2)) "dry run: nothing copied ($($r.Detail))"
$r = Install-KitNerdFont -ZipPath $zip -FontDir $fd2 -Registry $fstub -IsAdmin $false
$copied = @(Get-ChildItem -LiteralPath $fd2 -File | ForEach-Object Name)
Check ($r.Status -eq 'done' -and $copied.Count -eq 3 -and $copied -contains 'CaskaydiaCoveNerdFont-Regular.ttf' -and $copied -contains 'CaskaydiaCoveNerdFontMono-Bold.ttf' -and $copied -contains 'CaskaydiaCoveNerdFontMono-Regular.ttf' -and $freg.Count -eq 3 -and $freg['CaskaydiaCove Nerd Font Mono (TrueType)'] -eq (Join-Path $fd2 'CaskaydiaCoveNerdFontMono-Regular.ttf')) "install: Mono + regular TTFs copied and registered, Propo/README left out ($($r.Detail))"
$r = Install-KitNerdFont -ZipPath $zip -FontDir $fd2 -Registry $fstub -IsAdmin $false
Check ($r.Status -eq 'current') 'second run: already installed, skipped'

Write-Host 'essentials: steps (simulated, nothing on this PC is read or changed):'
$keepSim = @{}; foreach ($n in 'MYWINKIT_SIMULATE_ESSENTIALS', 'MYWINKIT_SIMULATE_FAIL', 'MYWINKIT_SIMULATE_INSTALL') { $keepSim[$n] = [Environment]::GetEnvironmentVariable($n) }
$env:MYWINKIT_SIMULATE_INSTALL = ''; $env:MYWINKIT_SIMULATE_FAIL = ''
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'present'
Check ((@('claude', 'font', 'terminal-settings', 'default-terminal' | ForEach-Object { (Invoke-KitEssential -Name $_ -KitRoot $root).Status }) -join ',') -eq 'current,current,current,current') 'all present -> every step current (skipped)'
$env:MYWINKIT_SIMULATE_ESSENTIALS = 'claude'
$env:MYWINKIT_SIMULATE_FAIL = 'font'
Check ((@('claude', 'font', 'terminal-settings', 'default-terminal' | ForEach-Object { (Invoke-KitEssential -Name $_ -KitRoot $root).Status }) -join ',') -eq 'current,failed,done,done') 'claude present, font fails, the rest still run'
Check ((Invoke-KitEssential -Name 'terminal-settings' -KitRoot $root -TerminalPresent $false).Status -eq 'skipped' -and (Invoke-KitEssential -Name 'default-terminal' -KitRoot $root -TerminalPresent $false).Status -eq 'skipped') 'no Windows Terminal -> its settings and the default-terminal step are skipped'
Check ((Invoke-KitEssential -Name 'default-terminal' -KitRoot $root -DryRun).Status -eq 'dryrun') 'dry run -> dryrun (nothing simulated as done)'
foreach ($n in $keepSim.Keys) { [Environment]::SetEnvironmentVariable($n, $keepSim[$n]) }
$tc = Get-KitTerminalConfig -KitRoot $root
Check ($tc -and $tc['defaultProfile'] -eq $claudeGuid) 'Get-KitTerminalConfig reads config/terminal.json (cache -> bundled)'
$keepWt = $env:MYWINKIT_WT_SETTINGS; $env:MYWINKIT_WT_SETTINGS = Join-Path $wt 'x.json'
Check ((Get-KitTerminalSettingsPath) -eq (Join-Path $wt 'x.json')) 'MYWINKIT_WT_SETTINGS redirects the Terminal settings file (tests)'
$env:MYWINKIT_WT_SETTINGS = $keepWt
Check ((Get-KitTerminalSettingsPath) -like '*Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json' -or (Get-KitTerminalSettingsPath) -like '*Microsoft\Windows Terminal\settings.json') 'default: the Terminal package''s LocalState\settings.json'

Write-Host 'catalogue changes 2026-11-26 (kit 2.8.0):'
$removedNow = @(@($data['Removed']) | ForEach-Object { [int]$_['Id'] })
Check (-not $byId.ContainsKey(41) -and $removedNow -contains 41 -and $byId[62].Ref -eq 'Python.Python.3.14' -and $byId[62].Group -eq 'DEV' -and -not $byId[62].Default) 'Python 3.13 (41) moved to Removed; Python 3.14 (62, Python.Python.3.14) in DEV, off'
Check ($byId[3].Uninstall -eq '^PowerToys' -and 'PowerToys (Preview)' -match $byId[3].Uninstall) 'PowerToys (3): Uninstall ^PowerToys matches its ARP name "PowerToys (Preview)"'
Check ($byId[40].Uninstall -and 'Node.js' -match $byId[40].Uninstall -and 'Node.js LTS helper' -notmatch '^Nodejs') 'Node.js LTS (40): Uninstall ^Node\.js matches "Node.js"'
Check (-not $byId[56].Requires -and $byId[56].Unsigned -and $byId[56].Desc -like '*fetches its own Git*') 'Hermes (56): no Requires git, Unsigned (Smart App Control), new Desc'
Check ($byId[55].NoAdmin -and $data['Direct']['antigravity-ide']['Args'] -like '*/mergetasks=!runcode*') 'Antigravity IDE (55): NoAdmin + /mergetasks=!runcode'
Check ($byId[13].Name -eq 'Adobe Acrobat Reader' -and $byId[13].Desc -eq 'Free Adobe PDF reader') 'Adobe Acrobat Reader (13): renamed, Id kept'
Check ($byId[2].InstallerType -eq 'nullsoft') 'Notepad++ (2): InstallerType nullsoft'
$selfIds = @($cat | Where-Object SelfUpdates | ForEach-Object Id | Sort-Object)
Check (($selfIds -join ',') -eq '5,7,10,11,13,16,18,20') "SelfUpdates = Office, Chrome, OneDrive, Dropbox, Acrobat Reader, Teams, WhatsApp, AnyDesk ($($selfIds -join ','))"
Check ($byId[5].HashNote -like '*setup.exe*') 'Office (5): a friendly hash-mismatch note'

Write-Host 'winget outcome buckets (Get-KitWingetOutcome on sample exit codes, no winget run):'
$buckets = [ordered]@{ '8A15002B' = 'current'; '8A15004F' = 'current'; '8A150061' = 'current'; '8A15010E' = 'current'; '80073D06' = 'current'
    '8A150109' = 'restart'; '8A15010B' = 'restart'; '8A150101' = 'busy'; '8A150103' = 'busy'; '8A150111' = 'busy'
    '8A150008' = 'transient'; '8A15006D' = 'transient'; '8A150102' = 'transient'; '8A150107' = 'transient'; '8A15007F' = 'transient'
    '8A15008E' = 'reinstall'; '8A150068' = 'pinned'; '8A15001B' = 'policy'; '8A15001C' = 'policy'; '8A15010D' = 'otherver'; '8A150011' = 'hash'
    '8A15010A' = 'failed'; '8A150006' = 'failed' }
$bad = @(foreach ($hx in $buckets.Keys) { $o = Get-KitWingetOutcome -ExitCode ([Convert]::ToInt32($hx, 16)) -Out @('x'); if ($o.Status -ne $buckets[$hx]) { "0x$hx=$($o.Status)" } })
Check (-not $bad.Count) "every code lands in its bucket (23 codes; 0x8A15010A reboot-before-install stays failed)$(if ($bad.Count) { ': ' + ($bad -join ', ') })"
$pk = [pscustomobject]@{ Name = 'Demo'; SelfUpdates = $false; HashNote = $null }
$res = @{}
foreach ($b in 'restart', 'busy', 'reinstall', 'policy', 'otherver', 'pinned', 'hash', 'failed') { $res[$b] = (Get-KitWingetResult -Package $pk -Outcome @{ Status = $b; Reason = "r (winget 0x8A150101)" } -IsInstalled $true).Status }
Check ($res['restart'] -eq 'restart' -and $res['busy'] -eq 'blocked' -and $res['reinstall'] -eq 'blocked' -and $res['policy'] -eq 'blocked' -and $res['otherver'] -eq 'blocked' -and $res['pinned'] -eq 'skipped' -and $res['hash'] -eq 'failed' -and $res['failed'] -eq 'failed') "result status per bucket: restart / blocked / skipped / failed ($(($res.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))"
$busy = Get-KitWingetResult -Package $pk -Outcome (Get-KitWingetOutcome -ExitCode ([Convert]::ToInt32('8A150101', 16))) -IsInstalled $true
Check ($busy.Detail -eq 'Demo is in use - close it, then Retry (winget 0x8A150101)') "busy -> '$($busy.Detail)'"
$re = Get-KitWingetOutcome -ExitCode ([Convert]::ToInt32('8A15008E', 16))
Check ($re.Reason -like 'installer type changed: uninstall + install needed*') "installer type changed -> '$($re.Reason)' (never done silently)"
$selfPk = [pscustomobject]@{ Name = 'Office'; SelfUpdates = $true; HashNote = 'Microsoft changed setup.exe; try tomorrow' }
$hashO = Get-KitWingetOutcome -ExitCode -1978335215
$h1 = Get-KitWingetResult -Package $selfPk -Outcome $hashO -IsInstalled $true; $h2 = Get-KitWingetResult -Package $selfPk -Outcome $hashO -IsInstalled $false
Check ($h1.Status -eq 'skipped' -and $h1.Detail -like 'updates itself; Microsoft changed setup.exe; try tomorrow*' -and $h2.Status -eq 'blocked') "SelfUpdates + hash mismatch is never failed: installed -> $($h1.Status), missing -> $($h2.Status) ($($h2.Detail))"
$h3 = Get-KitWingetResult -Package $pk -Outcome $hashO -IsInstalled $true
Check ($h3.Detail -like "*winget's catalogue is behind the vendor, try later*") "hash mismatch elsewhere: $($h3.Detail)"
Check ((Get-KitAutoExitCode -Results @([pscustomobject]@{ Status = 'restart' }, [pscustomobject]@{ Status = 'skipped' })) -eq 0 -and (Get-KitAutoExitCode -Results @([pscustomobject]@{ Status = 'blocked' }, [pscustomobject]@{ Status = 'installed' })) -eq 2 -and (Get-KitAutoExitCode -Results @([pscustomobject]@{ Status = 'blocked' }, [pscustomobject]@{ Status = 'failed' })) -eq 1) '/auto exit: restart needed + skipped = 0, blocked = 2, failed = 1'

Write-Host 'winget arguments (installer type / scope only on a fresh install; source always named):'
$ia = Get-KitWingetInstallArgs -WId 'Notepad++.Notepad++' -Method 'winget' -InstallerType 'nullsoft' -Scope 'user'
Check (($ia -join ' ') -like '*--source winget --installer-type nullsoft --scope user' -and ($ia -join ' ') -notmatch '--force|--ignore-security-hash|--include-unknown|--all') "fresh: $($ia -join ' ')"
Check (((Get-KitWingetInstallArgs -WId '9NKSQGP7F2NH' -Method 'msstore') -join ' ') -like '*--source msstore' -and ((Get-KitWingetInstallArgs -WId 'A.B' -Method 'winget') -join ' ') -notlike '*--installer-type*') 'Store items: --source msstore; no type when none is set'
$r = Invoke-KitPackage -Package $byId[2] -Installed $null -DryRun
Check ($r.Detail -like '*--installer-type nullsoft*') "Notepad++ not installed (dry run): $($r.Detail)"
$r = Invoke-KitPackage -Package $byId[2] -Installed '8.9' -DryRun
Check ($r.Detail -notlike '*--installer-type*') "Notepad++ installed (dry run): the upgrade keeps its type ($($r.Detail))"

Write-Host 'in use (install folder from Add/Remove Programs + a fake process list, nothing killed):'
$arp = @([pscustomobject]@{ Name = 'Git'; Version = '2.55'; InstallLocation = 'C:\Program Files\Git\'; DisplayIcon = '' },
    [pscustomobject]@{ Name = 'GitHub Desktop'; Version = '3.7'; InstallLocation = ''; DisplayIcon = 'C:\Users\x\AppData\Local\GitHubDesktop\GitHubDesktop.exe,0' },
    [pscustomobject]@{ Name = 'Notepad++ (64-bit x64)'; Version = '8.9'; InstallLocation = ''; DisplayIcon = '"C:\Program Files\Notepad++\notepad++.exe"' },
    [pscustomobject]@{ Name = 'Broad App'; Version = '1'; InstallLocation = 'C:\Program Files\'; DisplayIcon = 'C:\Windows\Installer\{X}\icon.exe' })
$procs = @([pscustomobject]@{ Id = 900001; Name = 'bash'; Path = 'C:\Program Files\Git\usr\bin\bash.exe' }, [pscustomobject]@{ Id = 900002; Name = 'ssh'; Path = 'C:\Program Files\Git\usr\bin\ssh.exe' },
    [pscustomobject]@{ Id = 900003; Name = 'bash'; Path = 'C:\Program Files\Git\usr\bin\bash.exe' }, [pscustomobject]@{ Id = 900004; Name = 'GitHubDesktop'; Path = 'C:\Users\x\AppData\Local\GitHubDesktop\app-3.7\GitHubDesktop.exe' },
    [pscustomobject]@{ Id = $PID; Name = 'self'; Path = 'C:\Program Files\Git\self.exe' })
$gitIn = @(Get-KitInUse -Package $byId[37] -Entries $arp -Processes $procs)
Check (($gitIn -join ',') -eq 'bash.exe,ssh.exe') "Git (InstallLocation) in use by: $($gitIn -join ', ') (the kit's own process never counts)"
Check ((Get-KitInstallFolder -Package $byId[38] -Entries $arp) -eq 'C:\Users\x\AppData\Local\GitHubDesktop') 'GitHub Desktop: folder from DisplayIcon; "Git" does not match "GitHub Desktop"'
Check ((Get-KitInstallFolder -Package $byId[2] -Entries $arp) -eq 'C:\Program Files\Notepad++') 'Notepad++: name prefix + quoted DisplayIcon'
Check ((Get-KitInstallFolder -Package ([pscustomobject]@{ Name = 'Broad App'; Uninstall = $null }) -Entries $arp) -eq '' -and @(Get-KitInUse -Package $byId[2] -Entries $arp -Processes $procs).Count -eq 0) 'Program Files itself or a Windows folder is never an install folder; no process -> not in use'

Write-Host 'hash mismatch + transient retry (Invoke-KitPackage with winget mocked, nothing runs):'
$core = Get-Module core
$saved = & $core { @{ W = ${function:Invoke-KitWinget}; V = ${function:Get-KitPkgVersion}; S = ${function:Invoke-KitProcess}; D = $script:RetryDelaySec } }
& $core {
    $script:RetryDelaySec = 0
    $script:MockCalls = [System.Collections.Generic.List[string]]::new()
    $script:MockExits = [System.Collections.Generic.Queue[int]]::new()
    function script:Invoke-KitWinget { param([string[]]$WingetArgs, [switch]$DeElevate) [void]$DeElevate; $script:MockCalls.Add('winget ' + ($WingetArgs -join ' ')); $ec = $script:MockExits.Dequeue(); return @{ Ec = $ec; Out = @("mock exit $ec") } }
    function script:Get-KitPkgVersion { param([string]$WId, [string]$Method) [void]$WId; [void]$Method; return '2.0' }
    function script:Invoke-KitProcess { param([string]$FilePath, [string[]]$ArgumentList) $script:MockCalls.Add("$FilePath " + ($ArgumentList -join ' ')); return @{ Ec = 0; Out = @(); Err = @(); Started = $true } }
}
$keepAdm2 = $env:MYWINKIT_SIMULATE_ADMIN; $env:MYWINKIT_SIMULATE_ADMIN = '0'
$mockPk = [pscustomobject]@{ Id = 991; Name = 'Mock App'; Group = 'UTIL'; GroupOrder = 0; Method = 'winget'; Ref = 'Mock.App'; Update = $null; Exe = $null; Requires = $null; Interactive = $false; Elevated = $false; Shell = $null; NoAdmin = $false; Version = $null; Detect = $null; Uninstall = $null; SelfUpdates = $false; Unsigned = $false; InstallerType = $null; Scope = $null; HashNote = $null; AI = $false; Appx = $null; Fallback = $null }
[void](Start-KitLog)
& $core { $script:MockExits.Enqueue(-1978335215); $script:MockExits.Enqueue(0); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
$calls = @(& $core { $script:MockCalls })
Check ($r.Status -eq 'updated' -and $calls.Count -eq 3 -and $calls[1] -like 'winget source update*' -and $r.Healed -like '*source update*') "hash mismatch -> winget source update -> retry -> updated ($($calls.Count) calls; $($r.Healed))"
& $core { $script:MockExits.Enqueue(-1978335215); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
$calls = @(& $core { $script:MockCalls })
Check ($r.Status -eq 'failed' -and $calls.Count -eq 1 -and $r.Detail -like "*catalogue is behind the vendor*") "second mismatch in the same run: no second source update, reported ($($r.Detail))"
& $core { $script:MockExits.Enqueue([Convert]::ToInt32('8A150008', 16)); $script:MockExits.Enqueue(0); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
Check ($r.Status -eq 'updated' -and @(& $core { $script:MockCalls }).Count -eq 2) "transient (download failed) -> one automatic retry -> updated"
& $core { $script:MockExits.Enqueue([Convert]::ToInt32('8A150008', 16)); $script:MockExits.Enqueue([Convert]::ToInt32('8A150008', 16)); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
Check ($r.Status -eq 'failed' -and @(& $core { $script:MockCalls }).Count -eq 2) 'transient twice -> failed after one retry (no loop)'
& $core { $script:MockExits.Enqueue([Convert]::ToInt32('8A150109', 16)); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
Check ($r.Status -eq 'restart' -and $r.Detail -like '*restart Windows*') "0x8A150109 -> restart needed ($($r.Detail))"
& $core { $script:MockExits.Enqueue([Convert]::ToInt32('8A150068', 16)); $script:MockCalls.Clear() }
$r = Invoke-KitPackage -Package $mockPk -Installed '1.0'
Check ($r.Status -eq 'skipped') "0x8A150068 pinned -> skipped ($($r.Detail))"
& $core { param($s) Set-Item function:script:Invoke-KitWinget $s.W; Set-Item function:script:Get-KitPkgVersion $s.V; Set-Item function:script:Invoke-KitProcess $s.S; $script:RetryDelaySec = $s.D } $saved
$env:MYWINKIT_SIMULATE_ADMIN = $keepAdm2

Write-Host 'Smart App Control:'
$keepSac = $env:MYWINKIT_SIMULATE_SAC
$env:MYWINKIT_SIMULATE_SAC = 'on'
$r = Invoke-KitPackage -Package $byId[56] -Installed '0.9' -Mode update
Check ($r.Status -eq 'blocked' -and $r.Detail -like 'blocked by Smart App Control*') "Hermes on a Smart App Control PC: skipped without running ($($r.Status): $($r.Detail))"
Check (Test-KitAppControlBlock -Out @("Program 'hermes.exe' failed to run: An Application Control policy has blocked this file.")) 'the Application Control message is recognised'
$env:MYWINKIT_SIMULATE_SAC = 'off'
$r = Invoke-KitPackage -Package $byId[56] -Installed '0.9' -Mode update -DryRun
Check ($r.Status -eq 'dryrun') "Smart App Control off: Hermes runs as usual ($($r.Status))"
$env:MYWINKIT_SIMULATE_SAC = $keepSac

Write-Host 'Enable RDP + PowerShell 7 fallback + test hooks:'
$rdp = Get-KitEnableRdpScript
Check ($rdp.Contains("Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'") -and -not $rdp.Contains('-DisplayGroup')) 'RDP firewall group by its resource string (works on Polish Windows), no localized -DisplayGroup'

Write-Host 'Tailnet setup (63):'
$tn = $byId[63]
Check ($tn -and $tn.Method -eq 'builtin' -and $tn.Ref -eq 'tailnet' -and $tn.Interactive -and $tn.Group -eq 'REMO' -and -not $tn.Default -and $tn.Detect -eq 'tailnet') 'Tailnet setup (63): builtin, REMO, interactive (browser sign-in), off, Detect tailnet'
$tord = @(Get-KitRunOrder @($byId[63], $byId[50]))
Check ($tord[0].Id -eq 50 -and $tord[1].Id -eq 63) 'run order: Tailscale (50) before the Tailnet setup (63)'
$tcfg = Get-KitTailnetConfig
$tAllow = @($tcfg['allowFrom'])
Check ($tAllow.Count -eq 2 -and $tAllow -contains '100.64.0.0/10' -and $tAllow -contains 'fd7a:115c:a1e0::/48') "config/tailnet.json: allowFrom = the tailnet ranges only ($($tAllow -join ', '))"
$tKeys = @($tcfg['authorizedKeys'])
Check ($tKeys.Count -ge 1 -and -not @($tKeys | Where-Object { "$_" -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+$' }).Count) "config/tailnet.json: $($tKeys.Count) public key(s), type + key only (no comments, host or user names)"
$ts0 = $tcfg['tailscale']
Check ($ts0['unattended'] -and $ts0['acceptRoutes'] -and $ts0['exitNodeAllowLan'] -and $ts0['autoUpdate'] -and $tcfg['enableRdp'] -and $tcfg['allowPing']) 'config/tailnet.json: unattended, accept-routes, exit-node LAN access, auto-update, RDP and ping on'
Check (((Get-KitTailscaleSetArgs -Config $tcfg) -join ' ') -eq 'set --unattended --accept-routes --exit-node-allow-lan-access --auto-update') 'tailscale set flags from config'
Check ((ConvertTo-KitCidr '100.64.0.0/255.192.0.0') -eq '100.64.0.0/10' -and (ConvertTo-KitCidr 'FD7A:115C:A1E0::/48') -eq 'fd7a:115c:a1e0::/48') 'firewall address notation: Windows mask form and IPv6 case compare as CIDR'
Check ((Test-KitTailnetAddresses -Actual @('fd7a:115c:a1e0::/48', '100.64.0.0/255.192.0.0') -Allow $tAllow) -and -not (Test-KitTailnetAddresses -Actual @('Any') -Allow $tAllow) -and -not (Test-KitTailnetAddresses -Actual @('100.64.0.0/10') -Allow $tAllow) -and -not (Test-KitTailnetAddresses -Actual @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', 'LocalSubnet') -Allow $tAllow)) 'a rule counts as limited only when its addresses are exactly allowFrom (Any, missing or extra -> not)'
$exist = @('# keys', 'from="10.0.0.1" ssh-ed25519 AAAAKEYONE old@laptop', 'ssh-rsa AAAAOTHER someone', '')
$mk = Merge-KitAuthorizedKeys -Existing $exist -Keys @('ssh-ed25519 AAAAKEYONE', 'ssh-ed25519 AAAAKEYTWO')
Check ($mk.Added -eq 1 -and @($mk.Lines).Count -eq 4 -and $mk.Lines[0] -eq '# keys' -and $mk.Lines[1] -eq $exist[1] -and $mk.Lines[2] -eq $exist[2] -and $mk.Lines[3] -eq 'ssh-ed25519 AAAAKEYTWO') 'keys merge: existing lines kept as they are (options, comments, other keys), only the missing key added'
Check ((Merge-KitAuthorizedKeys -Existing $mk.Lines -Keys @('ssh-ed25519 AAAAKEYONE', 'ssh-ed25519 AAAAKEYTWO')).Added -eq 0) 'keys merge: a second run adds nothing'
$tas = Get-KitTailnetAdminScript -Config $tcfg -ResultFile 'C:\scratch\r.json'
$tTok = $null; $tErr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($tas, [ref]$tTok, [ref]$tErr)
Check (-not @($tErr).Count) 'tailnet admin script parses'
Check ($tas.Contains("`$allow = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')") -and -not [regex]::IsMatch($tas, '(?i)-RemoteAddress\s+(?!\$allow\b)')) 'tailnet admin script: every -RemoteAddress is allowFrom (never Any)'
Check ($tas.Contains("-Group `$rdpGroup") -and $tas.Contains("'@FirewallAPI.dll,-28752'") -and $tas.Contains('Limit-InboundPort 22') -and $tas.Contains('Limit-InboundPort 3389') -and -not $tas.Contains('-DisplayGroup')) 'tailnet admin script: every inbound 22 / 3389 rule and the Remote Desktop group (by resource string) limited'
Check ($tas.Contains('*S-1-5-32-544:F') -and $tas.Contains('*S-1-5-18:F') -and $tas.Contains('/inheritance:r')) 'tailnet admin script: authorized keys ACL = Administrators + SYSTEM (by SID), no inheritance'
$wide = [ordered]@{}; foreach ($k in $tcfg.Keys) { $wide[$k] = $tcfg[$k] }; $wide['allowFrom'] = @('100.64.0.0/10', 'Any')
$threw = $false; try { [void](Get-KitTailnetAdminScript -Config $wide -ResultFile 'C:\scratch\r.json') } catch { $threw = $true }
Check $threw 'allowFrom with Any -> refused (no script)'
$full = @{ TsInstalled = $true; Backend = 'Running'; Prefs = @{ unattended = $true; acceptRoutes = $true; exitNodeAllowLan = $true; autoUpdate = $true }; NetCategory = 'Private'
    SshdPresent = $true; SshdAuto = $true; SshdRunning = $true; DefaultShell = [string]$tcfg['sshDefaultShell']; KeysMissing = 0; SshFw = $true; RdpOn = $true; RdpFw = $true; PingFw = $true }
$rowsOk = @(Test-KitTailnetState -State $full -Config $tcfg)
Check ($rowsOk.Count -eq 10 -and -not @($rowsOk | Where-Object { $_.Ok -ne $true }).Count) 'state check: a finished PC -> all 10 steps hold'
$s2 = $full.Clone(); $s2.KeysMissing = $null
Check (-not @(Test-KitTailnetState -State $s2 -Config $tcfg | Where-Object { $_.Ok -eq $false }).Count) 'state check: keys unreadable without admin -> unknown, not "needs work"'
$s3 = $full.Clone(); $s3.SshFw = $false; $s3.Prefs = @{ unattended = $true; acceptRoutes = $true; exitNodeAllowLan = $true; autoUpdate = $false }
$bad3 = @(Test-KitTailnetState -State $s3 -Config $tcfg | Where-Object { $_.Ok -eq $false } | ForEach-Object Step)
Check (($bad3 -join ',') -eq 'prefs,firewall-ssh') "state check: SSH open to Any + auto-update off -> prefs, firewall-ssh ($($bad3 -join ','))"
$s4 = $full.Clone(); $s4.TsInstalled = $false
$bad4 = @(Test-KitTailnetState -State $s4 -Config $tcfg | Where-Object { $_.Ok -eq $false } | ForEach-Object Step)
Check (($bad4 -join ',') -eq 'tailscale,signin,prefs,network') "state check: no Tailscale -> tailscale, signin, prefs, network ($($bad4 -join ','))"
# The generated admin script, run in a child process against mocked Windows: every cmdlet it uses
# (firewall, services, capabilities, registry, ACL, icacls) is a stub; ProgramData is a scratch folder.
$tailnetMocks = @'
param([string]$Scenario, [string]$CallsFile)
$compliant = ($Scenario -eq 'done')
$global:Calls = [System.Collections.Generic.List[string]]::new()
$global:MockState = @{ Profile = $(if ($compliant) { 'Private' } else { 'Public' }); Sshd = $compliant
    SshdStart = $(if ($compliant) { 'Automatic' } else { 'Manual' }); SshdStatus = $(if ($compliant) { 'Running' } else { 'Stopped' })
    Shell = $(if ($compliant) { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }); Deny = $(if ($compliant) { 0 } else { 1 }) }
$ok = @('100.64.0.0/255.192.0.0', 'fd7a:115c:a1e0::/48'); $ad = $(if ($compliant) { $ok } else { @('Any') })
$g = '@FirewallAPI.dll,-28752'
$global:Rules = @{
    'OpenSSH-Server-In-TCP' = @{ Port = '22'; Proto = 'TCP'; Group = ''; Enabled = 'True'; Addr = $ad }
    'RemoteDesktop-UserMode-In-TCP' = @{ Port = '3389'; Proto = 'TCP'; Group = $g; Enabled = 'True'; Addr = $ad }
    'RemoteDesktop-UserMode-In-UDP' = @{ Port = '3389'; Proto = 'UDP'; Group = $g; Enabled = $(if ($compliant) { 'True' } else { 'False' }); Addr = $ad }
    'RemoteDesktop-Shadow-In-TCP' = @{ Port = 'Any'; Proto = 'TCP'; Group = $g; Enabled = 'True'; Addr = $ad }
    'Custom-3389' = @{ Port = '3389'; Proto = 'TCP'; Group = ''; Enabled = 'True'; Addr = $ad }
}
if ($compliant) {
    $global:Rules['my-win-kit-Tailnet-Ping-v4'] = @{ Port = ''; Proto = 'ICMPv4'; Group = ''; Enabled = 'True'; Addr = $ok }
    $global:Rules['my-win-kit-Tailnet-Ping-v6'] = @{ Port = ''; Proto = 'ICMPv6'; Group = ''; Enabled = 'True'; Addr = $ok }
}
function New-R($n) { [pscustomobject]@{ Name = $n; Direction = 'Inbound'; Action = 'Allow'; Enabled = $global:Rules[$n].Enabled } }
function Get-NetAdapter { [CmdletBinding()] param() [pscustomobject]@{ InterfaceDescription = 'Tailscale Tunnel'; ifIndex = 42 } }
function Get-NetConnectionProfile { [CmdletBinding()] param($InterfaceIndex) [pscustomobject]@{ NetworkCategory = $global:MockState.Profile } }
function Set-NetConnectionProfile { [CmdletBinding()] param($InterfaceIndex, $NetworkCategory) $global:Calls.Add("profile $NetworkCategory"); $global:MockState.Profile = $NetworkCategory }
function Get-Service { [CmdletBinding()] param($Name) if ($global:MockState.Sshd) { [pscustomobject]@{ Name = 'sshd'; StartType = $global:MockState.SshdStart; Status = $global:MockState.SshdStatus } } }
function Get-WindowsCapability { [CmdletBinding()] param([switch]$Online, $Name) [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'NotPresent' } }
function Add-WindowsCapability { [CmdletBinding()] param([switch]$Online, $Name) $global:Calls.Add("capability $Name"); $global:MockState.Sshd = $true }
function Set-Service { [CmdletBinding()] param($Name, $StartupType) $global:Calls.Add("sshd $StartupType"); $global:MockState.SshdStart = $StartupType }
function Start-Service { [CmdletBinding()] param($Name) $global:Calls.Add('sshd start'); $global:MockState.SshdStatus = 'Running' }
function Get-ItemProperty { [CmdletBinding()] param($Path, $Name)
    if ($Name -eq 'DefaultShell') { if ($global:MockState.Shell) { return [pscustomobject]@{ DefaultShell = $global:MockState.Shell } }; throw 'no value' }
    if ($Name -eq 'fDenyTSConnections') { return [pscustomobject]@{ fDenyTSConnections = $global:MockState.Deny } }
    if ($Name -eq 'UserAuthentication') { return [pscustomobject]@{ UserAuthentication = $(if ($global:MockState.Deny -eq 0) { 1 } else { 0 }) } }
    throw "unexpected Get-ItemProperty $Path $Name" }
function Set-ItemProperty { [CmdletBinding()] param($Path, $Name, $Value) $global:Calls.Add("reg $Name=$Value"); if ($Name -eq 'fDenyTSConnections') { $global:MockState.Deny = $Value } }
function New-ItemProperty { [CmdletBinding()] param($Path, $Name, $Value, $PropertyType, [switch]$Force) $global:Calls.Add("reg $Name=$Value"); $global:MockState.Shell = $Value }
function Test-Path { [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath) $p = if ($LiteralPath) { $LiteralPath } else { $Path }; if ("$p" -like 'HKLM:*') { return $true }; Microsoft.PowerShell.Management\Test-Path -LiteralPath $p }
function New-Item { [CmdletBinding()] param($Path, $ItemType, [switch]$Force) if ("$Path" -like 'HKLM:*') { $global:Calls.Add("regkey $Path"); return }; Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force }
function icacls.exe { $global:Calls.Add('icacls ' + ($args -join ' ')) }
function Get-Acl { [CmdletBinding()] param($LiteralPath) [pscustomobject]@{ AreAccessRulesProtected = $compliant; Access = @() } }
function Get-NetFirewallPortFilter { [CmdletBinding()] param($Protocol) foreach ($n in @($global:Rules.Keys)) { $r = $global:Rules[$n]; if ($r.Proto -eq $Protocol) { [pscustomobject]@{ RuleName = $n; LocalPort = $r.Port; Protocol = $r.Proto } } } }
function Get-NetFirewallRule { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, $Name, $Group)
    process { if ($InputObject) { New-R $InputObject.RuleName } }
    end {
        foreach ($n in @($Name)) { if ($n -and $global:Rules.ContainsKey($n)) { New-R $n } }
        if ($Group) { foreach ($n in @($global:Rules.Keys)) { if ($global:Rules[$n].Group -eq $Group) { New-R $n } } }
    } }
function Get-NetFirewallAddressFilter { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject) process { [pscustomobject]@{ RemoteAddress = $global:Rules[$InputObject.Name].Addr } } }
function Set-NetFirewallRule { [CmdletBinding()] param($Name, $Group, $RemoteAddress, $Enabled)
    $t = if ($Name) { @($Name) } else { @($global:Rules.Keys | Where-Object { $global:Rules[$_].Group -eq $Group }) }
    foreach ($x in $t) { if ($RemoteAddress) { $global:Calls.Add("fw $x addr " + (@($RemoteAddress) -join ',')); $global:Rules[$x].Addr = @($RemoteAddress) }; if ($Enabled) { $global:Rules[$x].Enabled = "$Enabled" } } }
function New-NetFirewallRule { [CmdletBinding()] param($Name, $DisplayName, $Direction, $Protocol, $LocalPort, $IcmpType, $Action, $Profile, $RemoteAddress)
    $global:Calls.Add("fw new $Name addr " + (@($RemoteAddress) -join ',')); $global:Rules[$Name] = @{ Port = "$LocalPort"; Proto = $Protocol; Group = ''; Enabled = 'True'; Addr = @($RemoteAddress) } }
function Enable-NetFirewallRule { [CmdletBinding()] param($Group) $global:Calls.Add('fw enable group'); foreach ($n in @($global:Rules.Keys)) { if ($global:Rules[$n].Group -eq $Group) { $global:Rules[$n].Enabled = 'True' } } }
'@
function Invoke-TailnetMock([string]$Scenario) {
    $dir = Join-Path $env:TEMP ('my-win-kit-tailnet-mock-' + [guid]::NewGuid().ToString('N'))
    $pd = Join-Path $dir 'ProgramData'; New-Item -ItemType Directory -Path (Join-Path $pd 'ssh') -Force | Out-Null
    $kf = Join-Path $pd 'ssh\administrators_authorized_keys'
    if ($Scenario -eq 'done') { [IO.File]::WriteAllText($kf, ((@('ssh-rsa AAAAEXISTING kept@laptop') + $tKeys) -join "`r`n") + "`r`n") }
    else { [IO.File]::WriteAllText($kf, "ssh-rsa AAAAEXISTING kept@laptop`r`n") }
    $res = Join-Path $dir 'result.json'; $calls = Join-Path $dir 'calls.txt'
    $body = Get-KitTailnetAdminScript -Config $tcfg -ResultFile $res
    $i = $body.LastIndexOf("`nexit 0")
    $body = $body.Substring(0, $i) + "`n[IO.File]::WriteAllLines(`$CallsFile, [string[]]@(`$global:Calls))`nexit 0`n"
    $f = Join-Path $dir 'harness.ps1'
    [IO.File]::WriteAllText($f, $tailnetMocks + "`n`$env:ProgramData = '$pd'`n" + $body)
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f -Scenario $Scenario -CallsFile $calls 2>&1 | Out-String
    $r = @{ Ec = $LASTEXITCODE; Out = $o; Steps = @{}; Calls = @(); Keys = @() }
    if (Test-Path -LiteralPath $res) { $arr = [IO.File]::ReadAllText($res) | ConvertFrom-Json; foreach ($x in @($arr)) { $r.Steps[[string]$x.Step] = "$($x.Status): $($x.Detail)" } }
    if (Test-Path -LiteralPath $calls) { $r.Calls = @([IO.File]::ReadAllLines($calls)) }
    $r.Keys = @([IO.File]::ReadAllLines($kf) | Where-Object { $_.Trim() })
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $r
}
$mf = Invoke-TailnetMock 'fresh'
$st = $mf.Steps
Check ($mf.Ec -eq 0 -and $st.Count -eq 7) "mocked fresh PC: the admin script ran all 7 steps (exit $($mf.Ec))$(if ($mf.Ec -ne 0 -or $st.Count -ne 7) { ': ' + $mf.Out.Trim() })"
Check (-not @($st.Values | Where-Object { $_ -notlike 'done:*' }).Count) ("mocked fresh PC: every step done -> " + ((@($st.PSBase.Keys | Sort-Object) | ForEach-Object { "$_=$($st[$_])" }) -join ' | '))
Check ($mf.Calls -contains 'profile Private' -and $mf.Calls -contains 'sshd Automatic' -and $mf.Calls -contains 'sshd start' -and @($mf.Calls | Where-Object { $_ -like 'capability OpenSSH.Server*' }).Count -eq 1 -and $mf.Calls -contains 'reg fDenyTSConnections=0' -and $mf.Calls -contains 'reg UserAuthentication=1') 'mocked fresh PC: network Private, OpenSSH installed + automatic + started, RDP on with NLA'
$fwAddr = @($mf.Calls | Where-Object { $_ -match ' addr ' })
Check ($fwAddr.Count -ge 6 -and -not @($fwAddr | Where-Object { $_ -notmatch ' addr 100\.64\.0\.0/10,fd7a:115c:a1e0::/48$' }).Count) "mocked fresh PC: all $($fwAddr.Count) firewall changes use exactly the tailnet ranges (SSH, RDP group, the stray 3389 rule, ping)"
Check (@($fwAddr | Where-Object { $_ -like 'fw OpenSSH-Server-In-TCP *' }).Count -eq 1 -and @($fwAddr | Where-Object { $_ -like 'fw Custom-3389 *' }).Count -eq 1 -and @($fwAddr | Where-Object { $_ -like 'fw new my-win-kit-Tailnet-Ping-v4 *' }).Count -eq 1) 'mocked fresh PC: the existing SSH rule and an unrelated 3389 rule limited too, ping rules created'
Check ($mf.Keys.Count -eq (1 + $tKeys.Count) -and $mf.Keys[0] -eq 'ssh-rsa AAAAEXISTING kept@laptop' -and @($mf.Calls | Where-Object { $_ -like 'icacls *' }).Count -ge 1) "mocked fresh PC: keys file keeps its line and gains the $($tKeys.Count) keys; ACL set with icacls"
$md = Invoke-TailnetMock 'done'
Check ($md.Ec -eq 0 -and $md.Steps.Count -eq 7 -and -not @($md.Steps.Values | Where-Object { $_ -notlike 'already:*' }).Count -and $md.Calls.Count -eq 0 -and $md.Keys.Count -eq (1 + $tKeys.Count)) "mocked finished PC: every step 'already', nothing changed ($($md.Calls.Count) calls)$(if ($md.Calls.Count) { ': ' + ($md.Calls -join ' | ') + ' / ' + ((@($md.Steps.PSBase.Keys | Sort-Object) | ForEach-Object { "$_=$($md.Steps[$_])" }) -join ' | ') })"

$keepTsExe = $env:MYWINKIT_TAILSCALE_EXE; $env:MYWINKIT_TAILSCALE_EXE = Join-Path $env:TEMP 'my-win-kit-no-tailscale\tailscale.exe'
try {
    Check ($null -eq (Get-KitDetect -Name 'tailnet')) 'detect: no Tailscale -> not set up (no child process)'
    $tr = Invoke-KitPackage -Package $tn -DryRun
    Check ($tr.Status -eq 'dryrun' -and $tr.Detail.Contains('would set: Tailscale, sign-in')) "dry run lists the steps, changes nothing: $($tr.Detail)"
} finally { $env:MYWINKIT_TAILSCALE_EXE = $keepTsExe }
$psRel = '{ "tag_name": "v7.7.0", "assets": [ { "name": "PowerShell-7.7.0-win-x64.zip", "size": 1, "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0-win-x64.zip" }, { "name": "PowerShell-7.7.0.msixbundle", "size": 120000000, "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle" }, { "name": "PowerShellPreview-7.8.0-preview.1.msixbundle", "size": 1, "browser_download_url": "https://example.invalid/p.msixbundle" } ] }'
$ms = Get-KitPwshMsixAsset -Json $psRel
Check ($ms.Tag -eq 'v7.7.0' -and $ms.Name -eq 'PowerShell-7.7.0.msixbundle' -and $ms.Url -eq 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0.msixbundle') "PowerShell 7: the .msixbundle from the GitHub API answer ($($ms.Name))"
$threw = $false; try { [void](Get-KitPwshMsixAsset -Json '{ "tag_name": "v7.7.0", "assets": [ { "name": "PowerShell-7.7.0-win-x64.msi", "browser_download_url": "x" } ] }') } catch { $threw = $true }
Check $threw 'no .msixbundle in the release -> error (the loader then tries the Store package)'
$keepOut = $env:MYWINKIT_SIMULATE_OUTCOME; $env:MYWINKIT_SIMULATE_OUTCOME = '2=blocked,3=restart'
$r1 = Invoke-KitPackage -Package $byId[2] -DryRun; $r2 = Invoke-KitPackage -Package $byId[3] -DryRun; $r3 = Invoke-KitPackage -Package $byId[1] -DryRun
Check ($r1.Status -eq 'blocked' -and $r2.Status -eq 'restart' -and $r3.Status -eq 'dryrun') 'MYWINKIT_SIMULATE_OUTCOME (dry run only) gives the menus a blocked / restart result to show'
$env:MYWINKIT_SIMULATE_OUTCOME = $keepOut
Write-Host 'Process time limit + Hermes detect (scan hang fix):'
$sw = [Diagnostics.Stopwatch]::StartNew()
$tr = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 30') -TimeoutSec 2
$tsec = $sw.Elapsed.TotalSeconds
Check ($tr['TimedOut'] -and $tr.Started -and $tr.Ec -ne 0 -and $tsec -lt 12) ("-TimeoutSec 2 on a 30 s child: TimedOut after {0:N1} s" -f $tsec)
Check ((@($tr.Err) -join ' ').Contains('timed out after 2 s')) 'the timeout is named in Err'
$nr = Invoke-KitProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'exit 3') -TimeoutSec 30
Check ($nr.Ec -eq 3 -and -not $nr['TimedOut']) "a child that exits in time keeps its exit code ($($nr.Ec))"
Check ($byId[56].Detect -eq 'hermes') 'Hermes (56) uses Detect hermes, never hermes --version (that runs a git fetch that can hang)'
$keepLad = $env:LOCALAPPDATA
$fakeLad = Join-Path ([IO.Path]::GetTempPath()) ('mwk-lad-' + [guid]::NewGuid())
try {
    $env:LOCALAPPDATA = $fakeLad
    Check ($null -eq (Get-KitDetect -Name 'hermes')) 'Hermes detect: no folder = not installed'
    New-Item -ItemType Directory -Path (Join-Path $fakeLad 'hermes\hermes-agent') -Force | Out-Null
    Check ('' -eq (Get-KitDetect -Name 'hermes')) 'Hermes detect: folder without package metadata = installed, version unknown'
    New-Item -ItemType Directory -Path (Join-Path $fakeLad 'hermes\hermes-agent\venv\Lib\site-packages\hermes_agent-0.16.0.dist-info') -Force | Out-Null
    $hv = Get-KitDetect -Name 'hermes'
    Check ($hv -eq '0.16.0') "Hermes detect: version from hermes_agent-*.dist-info ($hv)"
    $hv2 = Get-KitToolVersion -Package $byId[56]
    Check ($hv2 -eq '0.16.0') "Get-KitToolVersion uses the detect, not hermes --version ($hv2)"
} finally { $env:LOCALAPPDATA = $keepLad; Remove-Item -LiteralPath $fakeLad -Recurse -Force -ErrorAction SilentlyContinue }

Check ((Split-Path -Leaf (Start-KitLog)) -match "^install-\d{8}-\d{6}-$PID\.log$") 'install log name carries the PID (two runs in one second get two files)'

Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
$env:MYWINKIT_STATE_DIR = $keepState
$env:MYWINKIT_CONFIG_URL = $keepCfg

if ($script:fail -eq 0) { Write-Host 'test-core: all passed' -ForegroundColor Green }
else { Write-Host "test-core: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
