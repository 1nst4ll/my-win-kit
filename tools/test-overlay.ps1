#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for my-packages.json (the package-list overlay) and import-overlay.ps1.
.DESCRIPTION
    Works on a scratch copy of the kit in %TEMP% (never the repo root, never
    OneDrive): base load, add (Id above max, persisted, atomic), default on/off,
    remove + restore, Ids never reused, memory-only (dry run), corrupt and
    newer-schema files, reset, the classic menu with an overlay, publish leaving
    my-packages.json alone, and import-overlay folding the overlay into a copy
    of the catalogue. -Online adds a real (read-only) winget search + Id lookup.
    Runs under Windows PowerShell 5.1 and pwsh. Exit code = failures.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-overlay.ps1 -Online
#>
[CmdletBinding()]
param([switch]$Online)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:fail = 0
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok    $What" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}
function New-ScratchKit {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("my-win-kit-overlay-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $d 'src') -Force | Out-Null
    Copy-Item -Path (Join-Path $repo 'src\*') -Destination (Join-Path $d 'src') -Force
    foreach ($f in 'install.ps1', 'install.cmd', 'win11-tweaks.ps1') { Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $d }
    return $d
}
function Import-Core([string]$Kit) { Import-Module (Join-Path $Kit 'src\core.psm1') -Force; return @(Initialize-Kit -KitRoot $Kit) }

Write-Host "test-overlay: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$kit = New-ScratchKit
$ov = Join-Path $kit 'my-packages.json'
try {
    # --- base only
    $cat = Import-Core $kit
    $baseCount = $cat.Count
    $baseMax = ($cat | Measure-Object -Property Id -Maximum).Maximum
    Check (-not (Test-Path $ov)) 'no overlay file -> base catalogue only'
    Check ((Get-KitOverlayInfo).Changes -eq 0) 'overlay info: 0 changes'

    # --- add
    $r = Add-KitPackage -Name 'Test App' -Ref 'Test.App' -Method winget -Group 'UTIL' -On $true
    Check ($r.Ok -and $r.Package.Id -eq $baseMax + 1) "add: new Id $($r.Package.Id) = max + 1"
    Check ((Test-Path $ov) -and -not (Test-Path "$ov.tmp")) 'add: file written atomically (no .tmp left)'
    $j = Get-Content $ov -Raw | ConvertFrom-Json
    Check ($j.schema -eq 1 -and $j.added.Count -eq 1 -and $j.added[0].Ref -eq 'Test.App' -and $j.lastId -eq $baseMax + 1) 'add: schema 1, entry + lastId persisted'
    Check (@(Get-KitCatalog).Count -eq $baseCount + 1 -and (@(Get-KitCatalog | Where-Object Ref -eq 'Test.App')[0].Origin -eq 'mine')) 'add: visible in the merged catalogue (origin mine)'
    $dup = Add-KitPackage -Name 'Again' -Ref 'Test.App' -Method winget
    Check (-not $dup.Ok) 'add: duplicate winget Id refused'
    $ng = Add-KitPackage -Name 'Grouped' -Ref 'Test.Grouped' -NewGroupLabel 'My tools'
    $grp = @(Get-KitGroups | Where-Object Label -eq 'My tools')
    Check ($ng.Ok -and $grp.Count -eq 1 -and $grp[0].Key -eq 'MY1' -and $grp[0].Letter -eq 'F' -and (Get-KitGroups)[-1].Key -eq 'POST') 'add: new group MY1 (letter F), POST stays last'

    # --- reload from disk = same view (sync to another PC)
    $cat2 = Import-Core $kit
    Check ($cat2.Count -eq $baseCount + 2) 'reload: overlay merged again from disk'

    # --- default on/off
    $np = @($cat2 | Where-Object Id -eq 2)[0]   # Notepad++, base default on
    [void](Set-KitPackageDefault -Id 2 -On $false)
    Check (-not @(Get-KitCatalog | Where-Object Id -eq 2)[0].Default) 'default: base package turned off'
    Check (((Get-Content $ov -Raw | ConvertFrom-Json).defaults.'2') -eq $false) 'default: override saved by Id'
    [void](Set-KitPackageDefault -Id 2 -On $true)
    Check (-not ((Get-Content $ov -Raw | ConvertFrom-Json).defaults.PSObject.Properties['2'])) 'default: back to base value removes the override'
    [void](Set-KitPackageDefault -Id ($baseMax + 1) -On $false)
    Check (-not @(Get-KitCatalog | Where-Object Id -eq ($baseMax + 1))[0].Default) 'default: added package updated in place'
    [void]$np

    # --- remove / restore / Ids never reused
    [void](Remove-KitPackage -Id 25)
    Check (-not @(Get-KitCatalog | Where-Object Id -eq 25).Count -and @(Get-KitRemovedPackages | Where-Object Id -eq 25).Count) 'remove: hidden from the catalogue, listed as removed'
    [void](Restore-KitPackage -Id 25)
    Check (@(Get-KitCatalog | Where-Object Id -eq 25).Count -eq 1) 'restore: back in the catalogue'
    [void](Remove-KitPackage -Id ($baseMax + 2))
    $n3 = Add-KitPackage -Name 'Third' -Ref 'Test.Third'
    Check ($n3.Package.Id -eq $baseMax + 3) "ids: removed added package's Id is not reused (got $($n3.Package.Id))"

    # --- memory only (dry run)
    $hash = (Get-Content $ov -Raw)
    Set-KitOverlayMemoryOnly $true
    $m = Add-KitPackage -Name 'Memory' -Ref 'Test.Memory'
    Check ($m.Saved -eq 'memory' -and @(Get-KitCatalog | Where-Object Ref -eq 'Test.Memory').Count -and (Get-Content $ov -Raw) -eq $hash) 'dry run: change visible in memory, file untouched'
    Set-KitOverlayMemoryOnly $false

    # --- classic menu with an overlay (new group without crash)
    [void](Add-KitPackage -Name 'Grouped Two' -Ref 'Test.G2' -Group 'MY1')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'install.ps1') -Classic -DryRun -ClassicTestInput 'Q' 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0 -and $cl.Contains('MY TOOLS') -and $cl.Contains('Grouped Two') -and $cl.Contains('Test App')) 'classic menu shows overlay packages and the new group'

    # --- import-overlay into a copy of the catalogue
    $catCopy = Join-Path $kit 'src\catalog.import-test.psd1'
    Copy-Item (Join-Path $kit 'src\catalog.psd1') $catCopy
    [void](Set-KitPackageDefault -Id 34 -On $true)
    [void](Remove-KitPackage -Id 26)
    $imp = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\import-overlay.ps1') -Overlay $ov -Catalog $catCopy 2>&1 | Out-String
    $c2 = Import-PowerShellDataFile $catCopy
    $p34 = @($c2.Packages | Where-Object { $_['Id'] -eq 34 })[0]
    Check ($LASTEXITCODE -eq 0) 'import-overlay: exit 0'
    Check ([bool]$p34['On']) 'import-overlay: default override folded in (Id 34 on)'
    Check (-not @($c2.Packages | Where-Object { $_['Id'] -eq 26 }).Count -and @($c2.RetiredIds) -contains 26) 'import-overlay: removed package deleted, Id retired'
    Check (@($c2.Packages | Where-Object { $_['Ref'] -eq 'Test.App' }).Count -eq 1 -and @($c2.Groups | Where-Object { $_['Key'] -eq 'MY1' }).Count -eq 1) 'import-overlay: added package + new group present'
    Check (@($c2.RetiredIds) -contains ($baseMax + 2)) 'import-overlay: removed added package Id retired too'
    $ascii = @([IO.File]::ReadAllBytes($catCopy) | Where-Object { $_ -gt 127 }).Count -eq 0
    Check $ascii 'import-overlay: catalogue still ASCII-only'
    [void]$imp

    # --- reset keeps the Id high-water mark
    $last = (Get-Content $ov -Raw | ConvertFrom-Json).lastId
    [void](Reset-KitOverlay)
    $after = if (Test-Path $ov) { Get-Content $ov -Raw | ConvertFrom-Json } else { $null }
    Check ((Test-Path "$ov.bak") -and @(Get-KitCatalog).Count -eq $baseCount -and $after.lastId -eq $last -and $after.added.Count -eq 0) "reset: base list again, .bak kept, lastId $last kept"
    Check ((Get-KitNextId) -eq $last + 1) 'reset: next Id still above every Id ever used'

    # --- corrupt file
    Set-Content -LiteralPath $ov -Value '{ this is not json'
    Remove-Item "$ov.bak" -Force
    $cat3 = Import-Core $kit
    Check ($cat3.Count -eq $baseCount -and @(Get-KitWarnings).Count -eq 1 -and (Get-Content "$ov.bak" -Raw).Contains('not json')) 'corrupt: warning, base list, original kept as .bak'

    # --- newer schema: ignored and never overwritten
    Set-Content -LiteralPath $ov -Value '{ "schema": 9, "added": [] }'
    $cat4 = Import-Core $kit
    $r9 = Add-KitPackage -Name 'X' -Ref 'Test.X'
    Check ($cat4.Count -eq $baseCount -and (Get-KitOverlayInfo).MemoryOnly -and (Get-Content $ov -Raw).Contains('"schema": 9') -and $r9.Saved -eq 'memory') 'newer schema: ignored, file left untouched'

    # --- publish never touches my-packages.json
    $target = Join-Path $kit 'publish target [98]'
    New-Item -ItemType Directory -Path $target | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'my-packages.json') -Value '{"schema":1,"added":[],"removed":[7]}'
    $h0 = (Get-Content -LiteralPath (Join-Path $target 'my-packages.json') -Raw)
    $pub = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\publish.ps1') -Target $target 2>&1 | Out-String
    Check ((Get-Content -LiteralPath (Join-Path $target 'my-packages.json') -Raw) -eq $h0 -and $pub -notmatch 'my-packages') 'publish: my-packages.json in the target untouched'

    if ($Online -and -not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host '  skip  winget search checks (winget not available on this machine)' -ForegroundColor Yellow }
    elseif ($Online) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $hits = @(Find-KitWingetPackages -Query 'notepad++')
        Check (@($hits | Where-Object { $_.Id -eq 'Notepad++.Notepad++' -and $_.Source -eq 'winget' }).Count -eq 1) "winget search 'notepad++': $($hits.Count) hits in $([int]$sw.Elapsed.TotalSeconds)s incl. Notepad++.Notepad++"
        $t = Test-KitWingetId -Id 'VideoLAN.VLC'
        Check ($t -and $t.Name -eq 'VLC media player' -and $t.Version) "exact Id lookup VideoLAN.VLC -> $($t.Name) $($t.Version)"
        Check ($null -eq (Test-KitWingetId -Id 'No.Such.Package.Zzz')) 'exact Id lookup: unknown Id -> null'
    }
} finally {
    Remove-Item -LiteralPath $kit -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail -eq 0) { Write-Host 'test-overlay: all passed' -ForegroundColor Green } else { Write-Host "test-overlay: $($script:fail) failure(s)" -ForegroundColor Red }
exit $script:fail
