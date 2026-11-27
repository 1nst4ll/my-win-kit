#Requires -Version 5.1
<#
.SYNOPSIS
    Draws the my-win-kit icon from scratch and writes assets/my-win-kit.ico.
.DESCRIPTION
    No external art: every size is drawn with System.Drawing (not scaled down
    from one big picture), so the small sizes stay sharp. Shape: a rounded
    dark gruvbox square holding a 2x2 grid of "window" panes; the fourth pane
    is an orange down arrow (install / update). Colours come from $script:Hex
    in src/tui-spectre.ps1.
    The .ico holds 16, 24, 32, 48, 64 and 256 px images, each stored as PNG
    (Windows Vista and later read PNG icon entries at every size).
    Also writes a preview PNG (every size, plus 16 and 32 enlarged 8x).
.PARAMETER Out
    Where to write the .ico (default: assets/my-win-kit.ico in the repo).
.PARAMETER Preview
    Where to write the preview PNG (default: %TEMP%\my-win-kit-icon-preview.png).
#>
[CmdletBinding()]
param(
    [string]$Out,
    [string]$Preview
)
$ErrorActionPreference = 'Stop'
# (defaults here: $PSScriptRoot is empty inside a 5.1 param block)
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\my-win-kit.ico' }
if (-not $Preview) { $Preview = Join-Path $env:TEMP 'my-win-kit-icon-preview.png' }
Add-Type -AssemblyName System.Drawing

function ConvertTo-Color([string]$Hex) { return [Drawing.ColorTranslator]::FromHtml($Hex) }
$Bg     = ConvertTo-Color '#282828'   # gruvbox bg0
$Edge   = ConvertTo-Color '#504945'   # Dim
$Blue   = ConvertTo-Color '#83a598'
$Aqua   = ConvertTo-Color '#8ec07c'
$Yellow = ConvertTo-Color '#fabd2f'
$Orange = ConvertTo-Color '#fe8019'

function New-RoundedPath([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) { $p.AddRectangle((New-Object Drawing.RectangleF $X, $Y, $W, $H)); return $p }
    $d = 2 * $R
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap([int]$S) {
    <# One icon image, drawn natively at S x S pixels. #>
    $bmp = New-Object Drawing.Bitmap $S, $S, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.Clear([Drawing.Color]::Transparent)

    # background tile (16 px: fills the square, larger: a small margin)
    $m = if ($S -le 16) { 0 } else { [math]::Round($S * 0.04) }
    $r = [math]::Max(2, [math]::Round($S * 0.18))
    $tile = New-RoundedPath $m $m ($S - 2 * $m) ($S - 2 * $m) $r
    $g.FillPath((New-Object Drawing.SolidBrush $Bg), $tile)
    if ($S -ge 32) {
        $pen = New-Object Drawing.Pen $Edge, ([single][math]::Max(1, [math]::Round($S / 64)))
        $g.DrawPath($pen, $tile)
    }

    # 2x2 grid, snapped to whole pixels
    # Small sizes are drawn pixel by pixel: odd cells, so the arrow tip is one centred pixel.
    $small = @{ 16 = @(5, 2); 24 = @(7, 2); 32 = @(9, 4) }
    if ($small.ContainsKey($S)) {
        $cell = $small[$S][0]; $gap = $small[$S][1]
    } else {
        $pad = [math]::Round($S * 0.19)
        $gap = [math]::Max(1, [math]::Round($S * 0.08))
        $cell = [math]::Floor(($S - 2 * $pad - $gap) / 2)
    }
    $x0 = [math]::Floor(($S - (2 * $cell + $gap)) / 2)
    $x1 = $x0 + $cell + $gap
    $ob = New-Object Drawing.SolidBrush $Orange
    if ($small.ContainsKey($S)) {
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::None
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::None
        foreach ($pane in @(@($x0, $x0, $Blue), @($x1, $x0, $Aqua), @($x0, $x1, $Yellow))) {
            $g.FillRectangle((New-Object Drawing.SolidBrush $pane[2]), [int]$pane[0], [int]$pane[1], [int]$cell, [int]$cell)
        }
        # arrow: head rows cell, cell-2, ..., 1 wide; a base line (with a blank row above it) from 32 px
        $headH = ($cell + 1) / 2
        $base = if ($S -ge 32) { 1 } else { 0 }
        $shaftW = if ($cell -le 5) { 1 } else { 3 }
        $shaftH = $cell - $headH - 2 * $base
        $g.FillRectangle($ob, [int]($x1 + ($cell - $shaftW) / 2), [int]$x1, [int]$shaftW, [int]$shaftH)
        for ($row = 0; $row -lt $headH; $row++) {
            $wRow = $cell - 2 * $row
            $g.FillRectangle($ob, [int]($x1 + $row), [int]($x1 + $shaftH + $row), [int]$wRow, 1)
        }
        if ($base) { $g.FillRectangle($ob, [int]$x1, [int]($x1 + $cell - 1), [int]$cell, 1) }
        $g.Dispose()
        return $bmp
    }
    $pr = [math]::Round($cell * 0.12)
    foreach ($pane in @(@($x0, $x0, $Blue), @($x1, $x0, $Aqua), @($x0, $x1, $Yellow))) {
        $g.FillPath((New-Object Drawing.SolidBrush $pane[2]), (New-RoundedPath $pane[0] $pane[1] $cell $cell $pr))
    }

    # fourth pane: orange down arrow (shaft + head + base line), filling the cell
    $cx = $x1 + $cell / 2.0
    $headH = [math]::Round($cell * 0.5)
    $baseH = [math]::Max(1, [math]::Round($cell * 0.14))
    $shaftW = [math]::Max(1, [math]::Round($cell * 0.34))
    if (($cell - $shaftW) % 2) { $shaftW++ }   # keep the shaft centred on whole pixels
    $headTop = $x1 + $cell - $baseH - $headH - [math]::Max(0, [math]::Round($cell * 0.06))
    $g.FillRectangle($ob, [single]($cx - $shaftW / 2.0), [single]$x1, [single]$shaftW, [single]($headTop - $x1 + 0.5))
    $head = @(
        (New-Object Drawing.PointF ([single]$x1), ([single]$headTop)),
        (New-Object Drawing.PointF ([single]($x1 + $cell)), ([single]$headTop)),
        (New-Object Drawing.PointF ([single]$cx), ([single]($headTop + $headH)))
    )
    $g.FillPolygon($ob, [Drawing.PointF[]]$head)
    $g.FillRectangle($ob, [single]$x1, [single]($x1 + $cell - $baseH), [single]$cell, [single]$baseH)

    $g.Dispose()
    return $bmp
}

function Get-PngBytes([Drawing.Bitmap]$Bmp) {
    $ms = New-Object IO.MemoryStream
    $Bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

$sizes = @(16, 24, 32, 48, 64, 256)
$images = @{}
foreach ($s in $sizes) { $images[$s] = New-IconBitmap $s }

# ---- .ico: ICONDIR + one ICONDIRENTRY per size + the PNG data
$pngs = @(foreach ($s in $sizes) { , (Get-PngBytes $images[$s]) })
$ms = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ms
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $w.Write([byte[]]$p) }
$w.Flush()
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllBytes($Out, $ms.ToArray())
Write-Host "icon:    $Out ($($ms.Length) bytes, sizes $($sizes -join ', '))"

# ---- preview: every size at 1x on a light and a dark strip, then 16 and 32 enlarged 8x
$zoom = 8
$pw = 20 + ($sizes | Measure-Object -Sum).Sum + 10 * $sizes.Count + 16 * $zoom + 32 * $zoom + 30
$ph = [math]::Max(2 * 256 + 30, 32 * $zoom + 20)
$pv = New-Object Drawing.Bitmap ([int]$pw), ([int]$ph)
$g = [Drawing.Graphics]::FromImage($pv)
$g.Clear([Drawing.Color]::FromArgb(240, 240, 240))
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(32, 32, 32))), 0, 266, $pw, 266)
$x = 10
foreach ($s in $sizes) { $g.DrawImage($images[$s], $x, 10, $s, $s); $g.DrawImage($images[$s], $x, 276, $s, $s); $x += $s + 10 }
$g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
$g.DrawImage($images[16], $x, 10, 16 * $zoom, 16 * $zoom); $x += 16 * $zoom + 10
$g.DrawImage($images[32], $x, 10, 32 * $zoom, 32 * $zoom)
$g.Dispose()
$pv.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
Write-Host "preview: $Preview"
