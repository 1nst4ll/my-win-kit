#Requires -Version 5.1
<#
.SYNOPSIS
    Publish the kit scripts from this repo to the OneDrive folder every PC syncs.
.DESCRIPTION
    One-way copy: repo -> target. The repo is the single source of truth.
    - Copies ONLY the kit files listed in $KitFiles. Never deletes anything in
      the target and never touches other files there (shortcuts, tools, and the
      per-PC/synced state next to install.ps1: winget-id-overrides.json and the
      package-list overlay my-packages.json(.bak/.tmp) - see $Protected).
    - Skips files whose content is already identical (SHA-256 compare).
    - Skips kit files with uncommitted changes (only committed state ships).
    - Drift guard: if a target file differs from the repo copy AND is newer
      than it, someone edited the OneDrive copy on another PC. That file is
      left alone, a warning names it, and the script exits 2. -Force overrides.
    Run automatically by .githooks/post-commit and post-merge on branch main.
.PARAMETER Target
    Destination folder. Default: "$env:OneDrive\[98] Shortcuts".
.PARAMETER Force
    Overwrite target files even when the drift guard trips.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\publish.ps1
.NOTES
    Exit codes: 0 = published or nothing to do, 1 = error, 2 = drift blocked.
    Keep this file ASCII-only and PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string]$Target,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Kit file set (repo-relative, forward slashes). src/ goes first and the
# loader (install.ps1) last, so a PC that syncs mid-publish never gets a
# loader whose src/ files are missing.
$srcFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | Sort-Object Name |
    ForEach-Object { 'src/' + $_.Name })
$KitFiles = @($srcFiles) + @('win11-tweaks.ps1', 'install.cmd', 'install.ps1')

# Files that live in the target but belong to the PCs, not the repo: never written,
# never deleted. my-packages.json holds Daniel's package-list edits (Settings ->
# Manage packages) and syncs between PCs through OneDrive.
$Protected = @('my-packages.json', 'my-packages.json.bak', 'my-packages.json.tmp', 'winget-id-overrides.json')
$clash = @($KitFiles | Where-Object { $Protected -contains (Split-Path -Leaf $_) })
if ($clash.Count) {
    Write-Host "publish: refusing - protected file(s) in the kit file set: $($clash -join ', ')" -ForegroundColor Red
    exit 1
}

if (-not $Target) {
    if (-not $env:OneDrive) {
        Write-Host 'publish: $env:OneDrive is not set - pass -Target <folder>.' -ForegroundColor Red
        exit 1
    }
    $Target = Join-Path $env:OneDrive '[98] Shortcuts'
}
# The default target contains [ ] - wildcard characters in PowerShell paths,
# so every file-system call below uses -LiteralPath.
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Write-Host "publish: target folder not found: $Target" -ForegroundColor Red
    exit 1
}

# Files with uncommitted changes are not published (needs git; skipped if absent)
$dirty = @()
if (Get-Command git -ErrorAction SilentlyContinue) {
    # PS 5.1 turns native stderr into a terminating error under 'Stop'
    $ErrorActionPreference = 'Continue'
    $porcelain = @(& git -C $RepoRoot status --porcelain -- $KitFiles 2>$null)
    if ($LASTEXITCODE -ne 0) { $porcelain = @() }   # not a git checkout: publish as-is
    $ErrorActionPreference = 'Stop'
    foreach ($ln in $porcelain) { if ("$ln".Length -gt 3) { $dirty += "$ln".Substring(3).Trim('"') } }
}

# SHA-256 via .NET: Get-FileHash lives in a script module that 5.1 fails to
# load when a git hook inherits a PowerShell 7 PSModulePath.
function Get-Sha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($fs)) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

$copied = @(); $unchanged = @(); $drifted = @(); $skipped = @()

foreach ($name in $KitFiles) {
    $src = Join-Path $RepoRoot ($name -replace "/", "\")
    $dst = Join-Path $Target ($name -replace "/", "\")
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Host "publish: missing in repo: $name" -ForegroundColor Red
        exit 1
    }
    if ($dirty -contains $name) { $skipped += $name; continue }

    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        $hs = Get-Sha256 $src
        $hd = Get-Sha256 $dst
        if ($hs -eq $hd) { $unchanged += $name; continue }

        $ts = (Get-Item -LiteralPath $src).LastWriteTimeUtc
        $td = (Get-Item -LiteralPath $dst).LastWriteTimeUtc
        if ($td -gt $ts -and -not $Force) { $drifted += $name; continue }
    }

    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $copied += $name
}

foreach ($n in $copied)    { Write-Host "  copied     $n" -ForegroundColor Green }
foreach ($n in $skipped)   { Write-Host "  skipped    $n (uncommitted changes - commit first)" -ForegroundColor Yellow }
foreach ($n in $drifted)   { Write-Host "  DRIFT      $n is newer in the target and differs - edited on another PC? Not overwritten." -ForegroundColor Yellow }

if ($copied.Count -gt 0) {
    Write-Host "publish: $($copied.Count) file(s) -> $Target" -ForegroundColor Green
} elseif ($drifted.Count -eq 0 -and $skipped.Count -eq 0) {
    Write-Host "publish: nothing changed ($($unchanged.Count) file(s) already current in $Target)" -ForegroundColor DarkGray
}

if ($drifted.Count -gt 0) {
    Write-Host 'publish: drift blocked. Bring the target edit into the repo, or re-run with -Force to overwrite it.' -ForegroundColor Yellow
    exit 2
}
exit 0
