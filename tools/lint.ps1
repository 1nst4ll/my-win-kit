#Requires -Version 5.1
<#
.SYNOPSIS
    Lint every .ps1/.psm1/.psd1 in the repo: parser check + PSScriptAnalyzer.
.DESCRIPTION
    The one lint command, used locally and by .github/workflows/lint.yml.
      -ParseOnly   parser check only (CI runs this under Windows PowerShell 5.1
                   AND pwsh, because 5.1 decodes BOM-less files as ANSI).
      default      parser check + PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1.
    Known issues ($KnownIssues) are reported as warnings instead of failures.
    Remove an entry as soon as its bug is fixed - the list must only shrink.
.NOTES
    Exit code = number of failures (0 = clean). Keep ASCII-only, PS 5.1 compatible.
#>
[CmdletBinding()]
param([switch]$ParseOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
$InCI     = [bool]$env:GITHUB_ACTIONS
$Edition  = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

# Each entry: File (repo-relative, forward slashes) + Check ('Parse51' or a PSSA rule name).
$KnownIssues = @(
    # (empty - win11-tweaks.ps1 BOM fixed 2026-11-25)
)

function Test-Known([string]$File, [string]$Check) {
    foreach ($k in $KnownIssues) { if ($k.File -eq $File -and $k.Check -eq $Check) { return $true } }
    return $false
}

$script:failures = 0
function Report([string]$File, [int]$Line, [string]$Check, [string]$Message) {
    if ($Line -lt 1) { $Line = 1 }   # file-level findings (e.g. encoding) report line 0
    if (Test-Known $File $Check) {
        if ($InCI) { Write-Host "::warning file=$File,line=$Line::[known issue] $Check - $Message" }
        else       { Write-Host "  known  $File`:$Line  $Check - $Message" -ForegroundColor Yellow }
    } else {
        $script:failures++
        if ($InCI) { Write-Host "::error file=$File,line=$Line::$Check - $Message" }
        else       { Write-Host "  FAIL   $File`:$Line  $Check - $Message" -ForegroundColor Red }
    }
}

$files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' })

Write-Host "lint: $($files.Count) script(s) under $Edition"

# 1. Parser check
$parseCheck = if ($PSVersionTable.PSEdition -eq 'Core') { 'Parse' } else { 'Parse51' }
foreach ($f in $files) {
    $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Report $rel $errs[0].Extent.StartLineNumber $parseCheck "$($errs.Count) parse error(s); first: $($errs[0].Message)"
    }
}

# 2. PSScriptAnalyzer
if (-not $ParseOnly) {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Host 'lint: installing PSScriptAnalyzer (CurrentUser)...'
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PSScriptAnalyzer
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
        foreach ($d in @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $Settings)) {
            Report $rel ([int]$d.Line) $d.RuleName $d.Message
        }
    }
}

if ($script:failures -eq 0) { Write-Host 'lint: clean' -ForegroundColor Green }
else { Write-Host "lint: $($script:failures) failure(s)" -ForegroundColor Red }
exit $script:failures
