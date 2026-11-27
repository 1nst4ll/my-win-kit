#Requires -Version 5.1
<#
.SYNOPSIS
    my-win-kit launcher: what the Start menu and Desktop shortcuts run.
.DESCRIPTION
    Lives in %LOCALAPPDATA%\my-win-kit (copied there by the online installer,
    see install.ps1 Register-KitShortcuts). Starts the newest downloaded kit
    copy (app\<version>\install.ps1) with the given arguments; that loader then
    updates itself from GitHub as usual. No copy on this PC -> downloads the kit
    from GitHub (the same as the online installer). Windows PowerShell 5.1, ASCII.
#>
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$best = $null; $bestVer = $null
$appDir = Join-Path $here 'app'
if (Test-Path -LiteralPath $appDir) {
    foreach ($d in (Get-ChildItem -LiteralPath $appDir -Directory -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $d.FullName 'install.ps1'
        if (-not (Test-Path -LiteralPath $loader)) { continue }
        try {
            $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $d.FullName 'src\core.psm1')), "KitVersion\s*=\s*'([0-9]+(\.[0-9]+){1,3})'")
            if (-not $m.Success) { continue }
            $v = [version]$m.Groups[1].Value
            if (-not $bestVer -or $v -gt $bestVer) { $bestVer = $v; $best = $loader }
        } catch { continue }
    }
}
if ($best) {
    & $best @args
    exit $LASTEXITCODE
}
# No kit copy on this PC (deleted by hand?): download it, like the online installer.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = if ($env:MYWINKIT_RAW_URL) { $env:MYWINKIT_RAW_URL.TrimEnd('/') + '/install.ps1' } else { 'https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1' }
    if ($url -like 'file:*') { $text = [IO.File]::ReadAllText(([Uri]$url).LocalPath) }
    else { $text = Invoke-RestMethod -Uri $url -UseBasicParsing }
    & ([scriptblock]::Create($text.TrimStart([char]0xFEFF))) @args
    exit $LASTEXITCODE
} catch {
    Write-Host "  Could not start my-win-kit: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Check the internet connection and try again.' -ForegroundColor Red
    [void](Read-Host '  Press Enter to close')
    exit 1
}
