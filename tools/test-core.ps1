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

if ($script:fail -eq 0) { Write-Host 'test-core: all passed' -ForegroundColor Green }
else { Write-Host "test-core: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
