# Generates build/icon.png (512x512) — the FrameForge mark: the same rounded-square-plus-bolt
# the titlebar SVG draws (src/index.html), rasterised at icon size on the light-theme accent.
# electron-builder converts this PNG into the multi-size .ico embedded in the exe/installer.
# Deterministic: same input constants, same output, so the icon never drifts from the mark.
param([string]$OutFile = (Join-Path $PSScriptRoot 'icon.png'))

Add-Type -AssemblyName System.Drawing

$size = 512
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

# Full-bleed rounded square, Fluent corner radius (~22%), vertical accent gradient for depth.
$radius = [int]($size * 0.22)
$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$d = $radius * 2
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($size - $d, 0, $d, $d, 270, 90)
$path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
$path.AddArc(0, $size - $d, $d, $d, 90, 90)
$path.CloseFigure()

$top = [System.Drawing.Color]::FromArgb(255, 0x18, 0x8F, 0xE0)   # lighter accent
$bottom = [System.Drawing.Color]::FromArgb(255, 0x00, 0x53, 0xA6) # deeper accent (base #0067C0 family)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillPath($brush, $path)

# The bolt, scaled 32x from the 16-unit titlebar path:
# M8.9 3 L5.2 8.4 H7.6 L6.9 13 L10.8 7.3 H8.3 Z
$s = $size / 16.0
$pts = @(
  (New-Object System.Drawing.PointF((8.9 * $s), (3.0 * $s))),
  (New-Object System.Drawing.PointF((5.2 * $s), (8.4 * $s))),
  (New-Object System.Drawing.PointF((7.6 * $s), (8.4 * $s))),
  (New-Object System.Drawing.PointF((6.9 * $s), (13.0 * $s))),
  (New-Object System.Drawing.PointF((10.8 * $s), (7.3 * $s))),
  (New-Object System.Drawing.PointF((8.3 * $s), (7.3 * $s)))
)
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$g.FillPolygon($white, $pts)

$g.Dispose()
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $OutFile ($((Get-Item $OutFile).Length) bytes)"
