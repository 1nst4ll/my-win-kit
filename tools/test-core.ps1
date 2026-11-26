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
    $okStatus = $r.Status -in 'dryrun', 'current'
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

Write-Host 'dev folder (Get-KitDevFolderPath, injected D: check):'
$sys = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
Check ((Get-KitDevFolderPath -DDriveType 'Fixed') -eq 'D:\dev\git') 'D: is a fixed disk -> D:\dev\git'
foreach ($t in '', 'CDRom', 'Removable', 'Network') { Check ((Get-KitDevFolderPath -DDriveType $t) -eq "$sys\dev\git") "D: '$t' -> $sys\dev\git" }
$r = Invoke-KitDevFolder -DryRun -DDriveType ''
Check (($r.Status -eq 'dryrun' -and $r.Detail -eq "would create $sys\dev\git") -or ($r.Status -eq 'current' -and $r.Detail -like '*already exists')) "dry run creates nothing: $($r.Status) - $($r.Detail)"

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

Write-Host 'per-PC preference: autoInstallPwsh (local override > settings.json > on):'
$a = Get-KitAutoInstallPwsh
# -Online reads settings.json from GitHub main, which may not have the key yet ('default')
Check ($a.On -and $a.Source -in 'shared', 'default') "no local choice -> settings.json value, else on ($($a.On), $($a.Source))"
Set-KitLocalPref -Name 'autoInstallPwsh' -Value $false
$a = Get-KitAutoInstallPwsh
Check (-not $a.On -and $a.Source -eq 'this PC') "local choice off wins over the shared on ($($a.On), $($a.Source))"
$lf = Get-KitLocalPrefsFile
Check ($lf -like "$($env:MYWINKIT_STATE_DIR)*" -and ([IO.File]::ReadAllText($lf)) -eq "{`n  `"autoInstallPwsh`": false`n}`n") 'stored in the state folder (local-settings.json, canonical JSON), not in config/'
Set-KitLocalPref -Name 'autoInstallPwsh' -Value $true
Check ((Get-KitAutoInstallPwsh).On) 'local choice back on'

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
Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
$env:MYWINKIT_STATE_DIR = $keepState
$env:MYWINKIT_CONFIG_URL = $keepCfg

if ($script:fail -eq 0) { Write-Host 'test-core: all passed' -ForegroundColor Green }
else { Write-Host "test-core: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
