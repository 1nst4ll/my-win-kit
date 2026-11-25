#Requires -Version 5.1
<#
.SYNOPSIS
    Fold my-packages.json (Daniel's live edits) into src/catalog.psd1, so they
    become the repo defaults.
.DESCRIPTION
    Text edits that keep the catalogue's comments and layout:
      - default on/off overrides  -> the package line's  On = $true/$false
      - removed packages          -> the line is deleted and its Id is added to
                                     RetiredIds (Ids are never reused)
      - new groups                -> added to Groups, before POST
      - added packages            -> appended above the Post-install section
    The result is validated (parses, unique Ids and names) before the file is
    replaced. Names are made ASCII (the catalogue stays ASCII-only).

    Safe order:  1. run this  2. tools/test-core.ps1  3. commit on main (publishes)
                 4. re-run with -ClearOverlay (or reset in Settings)
    Clearing before the commit is published would hide the changes on other PCs
    until the new catalogue arrives. Duplicates are harmless meanwhile: base wins.
.PARAMETER Overlay
    Path of my-packages.json. Default: the OneDrive copy every PC syncs.
.PARAMETER Catalog
    Catalogue to edit. Default: src/catalog.psd1 in this repo.
.PARAMETER DryRun
    Print what would change; write nothing.
.PARAMETER ClearOverlay
    After a successful import, rename the overlay to my-packages.imported-<date>.json.
.NOTES
    Keep ASCII-only and Windows PowerShell 5.1 compatible. Exit 0 = ok, 1 = error.
#>
[CmdletBinding()]
param(
    [string]$Overlay,
    [string]$Catalog,
    [switch]$DryRun,
    [switch]$ClearOverlay
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Catalog) { $Catalog = Join-Path $repo 'src\catalog.psd1' }
if (-not $Overlay) {
    if (-not $env:OneDrive) { Write-Host 'import-overlay: $env:OneDrive is not set - pass -Overlay <path>.' -ForegroundColor Red; exit 1 }
    $Overlay = Join-Path $env:OneDrive '[98] Shortcuts\my-packages.json'
}
if (-not (Test-Path -LiteralPath $Overlay)) { Write-Host "import-overlay: no overlay at $Overlay - nothing to import." -ForegroundColor Yellow; exit 0 }

$j = Get-Content -LiteralPath $Overlay -Raw | ConvertFrom-Json
if ([int]$j.schema -ne 1) { Write-Host "import-overlay: unsupported schema $($j.schema)." -ForegroundColor Red; exit 1 }

function ConvertTo-Ascii([string]$s) {
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) { if ([int]$ch -lt 128) { [void]$sb.Append($ch) } }
    return $sb.ToString()
}
function Q([string]$s) { return "'" + (ConvertTo-Ascii $s).Replace("'", "''") + "'" }

$text = [IO.File]::ReadAllText($Catalog)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = [System.Collections.Generic.List[string]]($text -split '\r?\n')
$base = Import-PowerShellDataFile -LiteralPath $Catalog
$baseIds = @($base.Packages | ForEach-Object { [int]$_['Id'] })
$removed = @($j.removed | ForEach-Object { [int]$_ })
$log = [System.Collections.Generic.List[string]]::new()

function Find-PackageLine([int]$Id) {
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*@\{\s*Id\s*=\s*$Id\s*;") { return $i } }
    return -1
}

# 1. default on/off overrides
if ($j.defaults) {
    foreach ($pr in $j.defaults.PSObject.Properties) {
        $id = [int]$pr.Name; $on = [bool]$pr.Value
        if ($removed -contains $id) { continue }
        $i = Find-PackageLine $id
        if ($i -lt 0) { $log.Add("  skip default for Id $id (not in the catalogue)"); continue }
        $new = [regex]::Replace($lines[$i], 'On\s*=\s*\$(true|false)', $(if ($on) { 'On = $true ' } else { 'On = $false' }))
        if ($new -ne $lines[$i]) { $lines[$i] = $new; $log.Add("  default  Id $id -> $(if ($on) { 'on' } else { 'off' })") }
    }
}

# 2. removed base packages -> delete the line, retire the Id
$retire = [System.Collections.Generic.List[int]]::new()
foreach ($id in $removed) {
    $retire.Add($id)
    $i = Find-PackageLine $id
    if ($i -ge 0) { $log.Add("  remove   Id $id ($([regex]::Match($lines[$i], "Name\s*=\s*'([^']*)'").Groups[1].Value))"); $lines.RemoveAt($i) }
}

# 3. new groups (before POST)
foreach ($g in @($j.groups)) {
    if (-not $g -or @($base.Groups | Where-Object { $_['Key'] -eq $g.Key }).Count) { continue }
    $pi = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*@\{\s*Key\s*=\s*'POST'") { $pi = $i; break } }
    if ($pi -lt 0) { throw 'POST group line not found in the catalogue' }
    $lines.Insert($pi, "        @{ Key = $(Q $g.Key); Label = $(Q $g.Label); Letter = $(Q $g.Letter) }")
    $log.Add("  group    $($g.Key) '$($g.Label)'")
}

# 4. added packages (above the Post-install section)
$adds = @($j.added | Where-Object { $_ -and $removed -notcontains [int]$_.Id -and $baseIds -notcontains [int]$_.Id })
if ($adds.Count) {
    $ai = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*# -- Post-install') { $ai = $i; break } }
    if ($ai -lt 0) { throw "'# -- Post-install' comment not found in the catalogue" }
    $block = @("        # -- Imported from my-packages.json ($(Get-Date -Format 'yyyy-MM-dd'))")
    foreach ($a in $adds) {
        $on = if ([bool]$a.On) { '$true ' } else { '$false' }
        $desc = if ($a.Desc) { $a.Desc } else { "Added from winget ($($a.Ref))" }
        $block += "        @{ Id = $([int]$a.Id); Name = $(Q $a.Name); Group = $(Q $a.Group); On = $on; Method = $(Q $a.Method); Ref = $(Q $a.Ref); Desc = $(Q $desc) }"
        $log.Add("  add      Id $([int]$a.Id) $($a.Name) [$($a.Method) $($a.Ref)] in $($a.Group)")
    }
    for ($k = $block.Count - 1; $k -ge 0; $k--) { $lines.Insert($ai, $block[$k]) }
}

# 5. RetiredIds (removed Ids + the overlay's high-water mark if no package uses it)
$all = [System.Collections.Generic.List[int]]::new()
foreach ($r in @($base['RetiredIds'])) { if ($r) { $all.Add([int]$r) } }
foreach ($r in $retire) { if (-not $all.Contains($r)) { $all.Add($r) } }
$usedIds = @($baseIds | Where-Object { $removed -notcontains $_ }) + @($adds | ForEach-Object { [int]$_.Id })
if ($j.lastId -and [int]$j.lastId -gt (($usedIds + @(0)) | Measure-Object -Maximum).Maximum -and -not $all.Contains([int]$j.lastId)) { $all.Add([int]$j.lastId) }
if ($all.Count) {
    $retLine = "    RetiredIds = @($((@($all) | Sort-Object -Unique) -join ', '))   # Ids that were removed: never reuse them"
    $ri = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*RetiredIds\s*=') { $ri = $i; break } }
    if ($ri -ge 0) { $lines[$ri] = $retLine }
    else {
        $di = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Direct\s*=\s*@\{') { $di = $i; break } }
        if ($di -lt 0) { throw "'Direct = @{' not found in the catalogue" }
        # step back over the comment block above Direct
        while ($di -gt 0 -and $lines[$di - 1] -match '^\s*#') { $di-- }
        $lines.Insert($di, ''); $lines.Insert($di, $retLine)
    }
    $log.Add("  retired  Ids $((@($all) | Sort-Object -Unique) -join ', ')")
}

if ($log.Count -eq 0) { Write-Host 'import-overlay: the overlay has no changes to import.' -ForegroundColor Yellow; exit 0 }
Write-Host "import-overlay: $Overlay -> $Catalog"
$log | ForEach-Object { Write-Host $_ }
if ($DryRun) { Write-Host 'import-overlay: dry run - nothing written.' -ForegroundColor Magenta; exit 0 }

# Validate, then replace
$tmp = "$Catalog.tmp"
[IO.File]::WriteAllText($tmp, ($lines -join $nl), (New-Object Text.UTF8Encoding($false)))
try {
    $chk = Import-PowerShellDataFile -LiteralPath $tmp
    $ids = @($chk.Packages | ForEach-Object { [int]$_['Id'] })
    $names = @($chk.Packages | ForEach-Object { $_['Name'] })
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'duplicate Ids after import' }
    if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw 'duplicate names after import' }
} catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "import-overlay: result failed validation, catalogue unchanged: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Move-Item -LiteralPath $tmp -Destination $Catalog -Force
Write-Host "import-overlay: catalogue updated ($($ids.Count) packages)." -ForegroundColor Green

if ($ClearOverlay) {
    $dest = Join-Path (Split-Path -Parent $Overlay) ('my-packages.imported-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Move-Item -LiteralPath $Overlay -Destination $dest
    Write-Host "import-overlay: overlay moved to $dest" -ForegroundColor Green
} else {
    Write-Host 'Next: run tools/test-core.ps1, commit on main (publishes), then re-run with -ClearOverlay.' -ForegroundColor Cyan
}
exit 0
