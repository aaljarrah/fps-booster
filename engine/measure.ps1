<#
  FrameForge :: measure.ps1
  Real frametime capture via Intel PresentMon (ETW), plus reviewer-grade metric computation
  (Average FPS, 1% low, 0.1% low, frametime stutter). PresentMon realtime capture requires
  administrator rights; this script reports that cleanly when not elevated.

  Actions:
    -Action capture  -Process <exe|pid> -Seconds <n>   ->  capture + analyze, returns metrics JSON
    -Action analyze  -Csv <path>                        ->  analyze an existing PresentMon CSV
    -Action metrics  -Frametimes "16.6,16.7,..."        ->  compute metrics from a CSV/list (testing)

  A failed capture must name the REAL reason. "Is the game running and rendering?" used to be
  returned for every possible failure, including ones where PresentMon never started at all.
#>
[CmdletBinding()]
param(
  [string]$Action = 'capture',
  [string]$Process,
  [int]$Seconds = 20,
  [string]$Csv,
  [string]$Frametimes,
  [string]$Label = 'run'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { . (Join-Path $PSScriptRoot '_lib.ps1') } catch {}
if (-not (Get-Command Write-FFJson -ErrorAction SilentlyContinue)) {
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  function Write-FFJson { param($InputObject, [int]$Depth = 12, [switch]$Pretty)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress))
  }
}

$Root = Split-Path -Parent $PSScriptRoot
$PresentMon = Join-Path $Root 'resources\PresentMon.exe'
# Captures go to %LOCALAPPDATA%, not into the install tree: a per-machine install under
# %ProgramFiles% is not writable, and this New-Item used to run at script load outside any
# try/catch, so the script died before emitting JSON and the host reported "No output from engine."
$StateBase = $env:LOCALAPPDATA
if (-not $StateBase) { $StateBase = $env:TEMP }
$CaptureDir = ($StateBase.TrimEnd('\')) + '\FrameForge\captures'
try {
  if (-not (Test-Path -LiteralPath $CaptureDir)) { New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null }
} catch {
  Write-FFJson @{ ok = $false; reason = "FrameForge could not create its capture folder at '$CaptureDir': $($_.Exception.Message)" }
  exit 0
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsArch {
  # PROCESSOR_ARCHITEW6432 is set only inside a 32-bit process on 64-bit Windows.
  $a = $env:PROCESSOR_ARCHITEW6432
  if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
  if (-not $a) { $a = 'unknown' }
  "$a"
}

function Get-PeMachine {
  <# The architecture a bundled .exe was built for, read straight out of its PE header. The
     bundled PresentMon is x64: on ARM64 Windows it runs only under x64 emulation, which is not
     guaranteed present in every configuration — and "it did not start" must not be reported as
     "your game is not rendering". #>
  param([string]$Path)
  try {
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
      $br = New-Object System.IO.BinaryReader($fs)
      $fs.Position = 0x3C
      $peOff = $br.ReadInt32()
      $fs.Position = $peOff
      if ($br.ReadUInt32() -ne 0x00004550) { return $null }   # 'PE\0\0'
      $machine = $br.ReadUInt16()
      switch ($machine) {
        0x8664  { return 'x64' }
        0x014c  { return 'x86' }
        0xAA64  { return 'ARM64' }
        0x01c4  { return 'ARM' }
        default { return ('0x{0:X4}' -f $machine) }
      }
    } finally { $fs.Dispose() }
  } catch { return $null }
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
  if (-not (Test-Path -LiteralPath $Path)) { throw "CSV not found: $Path" }
  $rows = Import-Csv -LiteralPath $Path
  if (-not $rows -or $rows.Count -eq 0) { return @() }
  # Find the frametime column across PresentMon v1/v2 header variants.
  $cols = $rows[0].PSObject.Properties.Name
  $col = $cols | Where-Object { $_ -match '^(msBetweenPresents|MsBetweenPresents)$' } | Select-Object -First 1
  if (-not $col) { $col = $cols | Where-Object { $_ -match 'between.?presents|^FrameTime$|^msBetweenDisplayChange$' } | Select-Object -First 1 }
  if (-not $col) { throw "No frametime column found. Columns: $($cols -join ', ')" }
  @($rows | ForEach-Object { [double]($_.$col) })
}

function Quote-Arg { param([string]$Value) '"' + ($Value -replace '"', '\"') + '"' }

# Action validation in the BODY, not via [ValidateSet] on the parameter: a binding failure
# happens BEFORE the script runs, producing empty stdout plus a raw error on stderr, which
# the Electron host can only report as "the engine returned no output". Matches health.ps1.
$ValidActions = @('capture','analyze','metrics')
if ($ValidActions -notcontains $Action) {
  $err = [ordered]@{
    ok = $false; action = "$Action"; errorCode = 'unknown-action'
    error = "Unknown action '$Action'."; validActions = $ValidActions
  }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $err -Depth 6 -Compress))
  exit 2
}

switch ($Action) {

  'metrics' {
    $values = @()
    if ($Frametimes) { $values = $Frametimes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [double]$_ } }
    elseif ($Csv) { $values = Read-FrametimesFromCsv -Path $Csv }
    Write-FFJson -InputObject (Compute-FrameMetrics -FrameTimesMs $values) -Depth 5
  }

  'analyze' {
    $ft = Read-FrametimesFromCsv -Path $Csv
    $m = Compute-FrameMetrics -FrameTimesMs $ft
    $m.csv = $Csv
    Write-FFJson -InputObject $m -Depth 5
  }

  'capture' {
    if (-not (Test-Path -LiteralPath $PresentMon)) { Write-FFJson @{ ok = $false; reason = "PresentMon.exe missing at $PresentMon" }; break }
    if (-not (Test-Admin)) { Write-FFJson @{ ok = $false; needsElevation = $true; reason = 'Frametime capture requires administrator rights (ETW).' }; break }
    if (-not $Process) { Write-FFJson @{ ok = $false; reason = 'No target process specified.' }; break }

    $osArch = Get-OsArch
    $binArch = Get-PeMachine $PresentMon
    $archNote = $null
    if ($binArch -and $osArch -match '(?i)ARM64' -and $binArch -ne 'ARM64') {
      $archNote = "The bundled PresentMon is a $binArch build and this is ARM64 Windows, so it runs only under x64 emulation."
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $CaptureDir "$Label-$stamp.csv"
    # --v1_metrics guarantees the stable 'msBetweenPresents' frametime column across PresentMon builds.
    # NOTE: $args is an automatic variable — never reuse that name.
    # Every path is QUOTED: PS 5.1 joins -ArgumentList elements with spaces and quotes nothing,
    # so an install under "C:\Program Files\FrameForge" made PresentMon receive
    # `--output_file C:\Program` plus a stray argument, no CSV was written, and the user was told
    # their game was not rendering. (.NET Framework has no ProcessStartInfo.ArgumentList, so
    # explicit quoting is the fix available on PS 5.1.)
    $pmArgs = @('--v1_metrics', '--no_console_stats', '--stop_existing_session', '--terminate_after_timed',
                '--timed', "$Seconds", '--output_file', (Quote-Arg $csvPath))
    if ($Process -match '^\d+$') { $pmArgs += @('--process_id', "$Process") } else { $pmArgs += @('--process_name', (Quote-Arg $Process)) }
    $pmArgLine = $pmArgs -join ' '

    # Redirect PresentMon's own console text ("Started recording." etc.) to temp files so it
    # never pollutes our stdout — the caller JSON-parses stdout and the prefix would break it.
    # They are READ before being deleted: PresentMon's stderr is the best evidence we have.
    $pmOut = [System.IO.Path]::GetTempFileName(); $pmErr = [System.IO.Path]::GetTempFileName()
    $p = $null; $startError = $null
    try {
      $p = Start-Process -FilePath $PresentMon -ArgumentList $pmArgLine -NoNewWindow -PassThru -Wait -RedirectStandardOutput $pmOut -RedirectStandardError $pmErr
    } catch {
      $startError = "$($_.Exception.Message)"
    }
    $pmStdout = ''; $pmStderr = ''
    try { $pmStdout = ((Get-Content -Raw -LiteralPath $pmOut -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim() } catch {}
    try { $pmStderr = ((Get-Content -Raw -LiteralPath $pmErr -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim() } catch {}
    Remove-Item -LiteralPath $pmOut, $pmErr -Force -ErrorAction SilentlyContinue

    if ($startError) {
      # Bad image format (arch mismatch), Smart App Control / WDAC block, missing dependency —
      # none of which have anything to do with the game.
      $reason = "PresentMon could not be started: $startError"
      if ($archNote) { $reason = "$reason $archNote" }
      Write-FFJson @{ ok = $false; reason = $reason; binaryArch = $binArch; osArch = $osArch; process = $Process }
      break
    }

    $exit = $p.ExitCode
    if (-not (Test-Path -LiteralPath $csvPath)) {
      $reason = if ($exit -ne 0) {
        "PresentMon exited with code $exit and wrote no capture file."
      } else {
        "PresentMon exited cleanly but wrote no capture file for '$Process'. Most often the process was not presenting frames while the capture ran; an ETW session that was refused or already owned by another tool does the same thing."
      }
      if ($pmStderr) { $reason = "$reason PresentMon said: $pmStderr" }
      elseif ($pmStdout) { $reason = "$reason PresentMon said: $pmStdout" }
      if ($archNote) { $reason = "$reason $archNote" }
      Write-FFJson @{ ok = $false; reason = $reason; exit = $exit; stderr = $pmStderr; stdout = $pmStdout
                      binaryArch = $binArch; osArch = $osArch; csvWritten = $false; process = $Process }
      break
    }
    $ft = Read-FrametimesFromCsv -Path $csvPath
    if (@($ft).Count -eq 0) {
      $reason = "PresentMon wrote a capture file with no frames in it for '$Process' (exit $exit). The process was most likely not presenting frames during the capture window."
      if ($pmStderr) { $reason = "$reason PresentMon said: $pmStderr" }
      Write-FFJson @{ ok = $false; reason = $reason; exit = $exit; stderr = $pmStderr; csv = $csvPath
                      csvWritten = $true; frames = 0; binaryArch = $binArch; osArch = $osArch; process = $Process }
      break
    }
    $m = Compute-FrameMetrics -FrameTimesMs $ft
    $m.csv = $csvPath
    $m.process = $Process
    $m.label = $Label
    $m.exit = $exit
    $m.binaryArch = $binArch
    $m.osArch = $osArch
    Write-FFJson -InputObject $m -Depth 5
  }
}
