<#
  FrameForge :: measure.ps1
  Real frametime capture via Intel PresentMon (ETW), plus reviewer-grade metric computation
  (Average FPS, 1% low, 0.1% low, frametime stutter). PresentMon realtime capture requires
  administrator rights; this script reports that cleanly when not elevated.

  Actions:
    -Action capture  -Process <exe|pid> -Seconds <n>   ->  capture + analyze, returns metrics JSON
    -Action analyze  -Csv <path>                        ->  analyze an existing PresentMon CSV
    -Action metrics  -Frametimes "16.6,16.7,..."        ->  compute metrics from a CSV/list (testing)
#>
[CmdletBinding()]
param(
  [ValidateSet('capture','analyze','metrics')][string]$Action = 'capture',
  [string]$Process,
  [int]$Seconds = 20,
  [string]$Csv,
  [string]$Frametimes,
  [string]$Label = 'run'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$PresentMon = Join-Path $Root 'resources\PresentMon.exe'
$CaptureDir = Join-Path $Root 'data\captures'
if (-not (Test-Path $CaptureDir)) { New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Percentile {
  param([double[]]$Sorted, [double]$P)  # $Sorted ascending, $P in 0..1
  if ($Sorted.Count -eq 0) { return 0 }
  $rank = [Math]::Ceiling($P * $Sorted.Count) - 1
  if ($rank -lt 0) { $rank = 0 }
  if ($rank -ge $Sorted.Count) { $rank = $Sorted.Count - 1 }
  return $Sorted[$rank]
}

function Compute-FrameMetrics {
  param([double[]]$FrameTimesMs)
  # Filter out non-positive / absurd frametimes (PresentMon can log 0 or huge gaps on capture edges)
  $ft = @($FrameTimesMs | Where-Object { $_ -gt 0.05 -and $_ -lt 1000 })
  $n = $ft.Count
  if ($n -lt 2) { return [ordered]@{ ok = $false; reason = 'Not enough frames captured.'; frames = $n } }

  $sumFt = ($ft | Measure-Object -Sum).Sum
  $avgFps = [math]::Round(1000.0 * $n / $sumFt, 1)

  # Per-frame instantaneous FPS, ascending — "1% low (avg)" = mean of slowest 1% of frames (CapFrameX method)
  $instFps = $ft | ForEach-Object { 1000.0 / $_ }
  $instSorted = @($instFps | Sort-Object)
  $take1   = [Math]::Max(1, [Math]::Ceiling($n * 0.01))
  $take01  = [Math]::Max(1, [Math]::Ceiling($n * 0.001))
  $low1    = [math]::Round((($instSorted[0..($take1 - 1)]) | Measure-Object -Average).Average, 1)
  $low01   = [math]::Round((($instSorted[0..($take01 - 1)]) | Measure-Object -Average).Average, 1)

  $ftSorted = @($ft | Sort-Object)
  $ftAvg = $sumFt / $n
  $variance = ($ft | ForEach-Object { ($_ - $ftAvg) * ($_ - $ftAvg) } | Measure-Object -Sum).Sum / $n
  $stutter = [math]::Round([math]::Sqrt($variance), 2)

  [ordered]@{
    ok            = $true
    frames        = $n
    durationSec   = [math]::Round($sumFt / 1000.0, 1)
    avgFps        = $avgFps
    low1Fps       = $low1
    low01Fps      = $low01
    minFps        = [math]::Round($instSorted[0], 1)
    maxFps        = [math]::Round($instSorted[-1], 1)
    frametimeAvgMs = [math]::Round($ftAvg, 2)
    frametimeP99Ms = [math]::Round((Get-Percentile -Sorted $ftSorted -P 0.99), 2)
    stutterMs      = $stutter
  }
}

function Read-FrametimesFromCsv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw "CSV not found: $Path" }
  $rows = Import-Csv -Path $Path
  if (-not $rows -or $rows.Count -eq 0) { return @() }
  # Find the frametime column across PresentMon v1/v2 header variants.
  $cols = $rows[0].PSObject.Properties.Name
  $col = $cols | Where-Object { $_ -match '^(msBetweenPresents|MsBetweenPresents)$' } | Select-Object -First 1
  if (-not $col) { $col = $cols | Where-Object { $_ -match 'between.?presents|^FrameTime$|^msBetweenDisplayChange$' } | Select-Object -First 1 }
  if (-not $col) { throw "No frametime column found. Columns: $($cols -join ', ')" }
  @($rows | ForEach-Object { [double]($_.$col) })
}

switch ($Action) {

  'metrics' {
    $values = @()
    if ($Frametimes) { $values = $Frametimes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [double]$_ } }
    elseif ($Csv) { $values = Read-FrametimesFromCsv -Path $Csv }
    (Compute-FrameMetrics -FrameTimesMs $values) | ConvertTo-Json -Depth 5 -Compress
  }

  'analyze' {
    $ft = Read-FrametimesFromCsv -Path $Csv
    $m = Compute-FrameMetrics -FrameTimesMs $ft
    $m.csv = $Csv
    $m | ConvertTo-Json -Depth 5 -Compress
  }

  'capture' {
    if (-not (Test-Path $PresentMon)) { (@{ ok = $false; reason = "PresentMon.exe missing at $PresentMon" } | ConvertTo-Json -Compress); break }
    if (-not (Test-Admin)) { (@{ ok = $false; needsElevation = $true; reason = 'Frametime capture requires administrator rights (ETW).' } | ConvertTo-Json -Compress); break }
    if (-not $Process) { (@{ ok = $false; reason = 'No target process specified.' } | ConvertTo-Json -Compress); break }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $CaptureDir "$Label-$stamp.csv"
    # --v1_metrics guarantees the stable 'msBetweenPresents' frametime column across PresentMon builds.
    $args = @('--v1_metrics', '--no_console_stats', '--stop_existing_session', '--terminate_after_timed', '--timed', "$Seconds", '--output_file', $csvPath)
    if ($Process -match '^\d+$') { $args += @('--process_id', $Process) } else { $args += @('--process_name', $Process) }

    # Redirect PresentMon's own console text ("Started recording." etc.) to temp files so it
    # never pollutes our stdout — the caller JSON-parses stdout and the prefix would break it.
    $pmOut = [System.IO.Path]::GetTempFileName(); $pmErr = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $PresentMon -ArgumentList $args -NoNewWindow -PassThru -Wait -RedirectStandardOutput $pmOut -RedirectStandardError $pmErr
    Remove-Item $pmOut, $pmErr -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $csvPath)) {
      (@{ ok = $false; reason = "No frames captured for '$Process'. Is the game running and rendering?"; exit = $p.ExitCode } | ConvertTo-Json -Compress); break
    }
    $ft = Read-FrametimesFromCsv -Path $csvPath
    $m = Compute-FrameMetrics -FrameTimesMs $ft
    $m.csv = $csvPath
    $m.process = $Process
    $m.label = $Label
    $m | ConvertTo-Json -Depth 5 -Compress
  }
}
