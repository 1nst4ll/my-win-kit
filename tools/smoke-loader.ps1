#Requires -Version 5.1
<#
.SYNOPSIS
    Test the install.ps1 loader decisions and the classic menu (dry run, no installs).
.DESCRIPTION
    Runs under Windows PowerShell 5.1 (the engine a fresh PC has):
      - decision with PowerShell 7 present / simulated absent / -Classic
      - "install PowerShell 7?" declined  -> classic menu opens
      - "install PowerShell 7?" accepted in dry run -> skips the install, classic menu
      - classic menu: toggle apps, POST group, simulate an install run
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-loader.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$loader = Join-Path $root 'install.ps1'
$env:MYWINKIT_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-smoke-" + [guid]::NewGuid())
$script:fail = 0

function Invoke-Loader([string[]]$LoaderArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $loader @LoaderArgs 2>&1 | Out-String
    return @{ Out = $out; Ec = $LASTEXITCODE }
}
function Check([string]$Name, $Run, [string[]]$Expect) {
    $missing = @($Expect | Where-Object { -not $Run.Out.Contains($_) })   # literal, not -like (brackets are wildcards)
    if ($Run.Ec -eq 0 -and $missing.Count -eq 0) { Write-Host "  ok    $Name" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  FAIL  $Name (exit $($Run.Ec); missing: $($missing -join ' | '))" -ForegroundColor Red
        ($Run.Out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 12) | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}

$hasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue)
if ($hasPwsh) { Check 'decision: PowerShell 7 present -> modern' (Invoke-Loader @('-WhatIfLoader')) @('decision: modern') }
Check 'decision: PowerShell 7 absent -> offer install' (Invoke-Loader @('-WhatIfLoader', '-NoPwsh')) @('decision: offer-install')
Check 'decision: -Classic forced'                      (Invoke-Loader @('-WhatIfLoader', '-Classic')) @('decision: classic')
Check 'declined PowerShell 7 -> classic menu'          (Invoke-Loader @('-NoPwsh', '-Answer', 'n', '-DryRun', '-ClassicTestInput', 'Q')) @('Install PowerShell 7 now?', 'classic menu', 'DRY RUN')
Check 'accepted in dry run -> no install, classic'     (Invoke-Loader @('-NoPwsh', '-Answer', 'y', '-DryRun', '-ClassicTestInput', 'Q')) @('Dry run: would install PowerShell 7', 'classic menu')
Check 'classic: toggles + POST + simulated run'        (Invoke-Loader @('-Classic', '-DryRun', '-ClassicTestInput', '0;2;46;X;I;y;;Q')) @('0 selected', '[1/5] Notepad++', '[5/5] Enable RDP Host', 'Done: 5 ok, 0 failed')

Remove-Item -LiteralPath $env:MYWINKIT_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -eq 0) { Write-Host 'smoke-loader: all passed' -ForegroundColor Green } else { Write-Host "smoke-loader: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
