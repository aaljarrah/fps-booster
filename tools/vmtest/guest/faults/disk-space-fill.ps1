<#
  FAULT: disk-space-fill
  Two separate things, and the split is the whole design:

    BALLAST  files in C:\ffvmtest\ballast, OUTSIDE every folder temp-clean sweeps. They bring the
             volume down to -PostCleanFreeGB, which is the state the machine should be in AFTER a
             successful repair.
    JUNK     files inside the folders temp-clean actually sweeps (%TEMP% and %SystemRoot%\Temp),
             totalling -JunkGB. They take the volume the rest of the way down, into the range the
             disk-space probe grades as a fault.

  SIZING MATTERS, AND NAIVE SIZING BREAKS THE ROW.
  health.ps1 grades the SYSTEM drive critical at free < 10% OR free < 20 GB, and warns under 15%.
  On a 64 GB test VHDX that second clause dominates: nothing under 20 GB free is ever healthy. So
  if the fault simply filled the disk to 8% and the junk were a few megabytes, temp-clean would
  delete everything it is supposed to and the volume would STILL be graded critical - the row would
  fail with 'verify-not-healthy' while the repair had done its job perfectly. The defaults below
  are chosen so the arithmetic works out:

      free after junk     = PostCleanFreeGB - JunkGB  =  26 - 18  =  ~8 GB   -> critical (a fault)
      free after cleanup  = PostCleanFreeGB           =        26 GB         -> >= 20 GB and ~41%
                                                                                on a 64 GB disk
                                                                                -> healthy

  Both halves are created with `fsutil file createnew`, which allocates clusters WITHOUT writing
  data. Free space drops immediately (NTFS has allocated it), the operation is instant, and a
  dynamic VHDX does not grow by 44 GB on the host to make it happen.

  GROUND TRUTH: free bytes on the volume, plus a manifest of exactly which files this script
  created. Numbers and paths - no text anywhere.

  REVERT deletes only the manifest paths. Junk the repair already deleted comes back as
  'already gone', which is EVIDENCE THE REPAIR WORKED, not an error.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$Drive = 'C',
  # Free space to leave once the junk is cleaned up. Must be comfortably above health.ps1's
  # 20 GB / 15% system-drive thresholds or a successful repair still verifies as unhealthy.
  [int]$PostCleanFreeGB = 26,
  # How much of that is junk inside the swept folders, i.e. how much the repair can actually
  # reclaim. Must be large enough to push the volume into the graded-fault range.
  [int]$JunkGB = 18,
  [int]$JunkFileGB = 2,
  [string]$BallastRoot = 'C:\ffvmtest\ballast',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'disk-space-fill'
$fsutil  = Join-Path $env:SystemRoot 'System32\fsutil.exe'
$TargetFreeAfterInjectGB = $PostCleanFreeGB - $JunkGB

function Get-VolumeRow {
  param([string]$D)
  try {
    $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($D):'" -ErrorAction Stop
    $size = [int64]$v.Size; $free = [int64]$v.FreeSpace
    $pct = $null; if ($size -gt 0) { $pct = [math]::Round(100.0 * $free / $size, 2) }
    return [ordered]@{ drive = $D; sizeBytes = $size; freeBytes = $free
                       sizeGB = [math]::Round($size / 1GB, 2); freeGB = [math]::Round($free / 1GB, 2); freePercent = $pct }
  } catch { return $null }
}

function New-AllocatedFile {
  <# fsutil file createnew: allocates without writing. Returns the path, or throws. #>
  param([string]$Path, [int64]$Bytes)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $r = Invoke-NativeCapture -FilePath $fsutil -Arguments @('file','createnew', $Path, "$Bytes")
  if ($r.exitCode -ne 0 -or -not (Test-Path -LiteralPath $Path)) { throw "fsutil file createnew exited $($r.exitCode) for $Path" }
  $Path
}

function Get-SpaceGroundTruth {
  param($State)
  $v = Get-VolumeRow -D $Drive
  $manifest = @(); if ($State) { $manifest = @($State.created) }
  $still = @($manifest | Where-Object { Test-Path -LiteralPath $_ })
  $sigs = @(
    [ordered]@{ signal = 'volume'; value = $v },
    [ordered]@{ signal = 'created-file-manifest'; total = @($manifest).Count; stillPresent = @($still).Count },
    [ordered]@{ signal = 'targets'; postCleanFreeGB = $PostCleanFreeGB; junkGB = $JunkGB; targetFreeAfterInjectGB = $TargetFreeAfterInjectGB }
  )
  if ($null -eq $v) { return (New-GroundTruth -Faulted $null -Detail "Free space on $($Drive): could not be read; UNDETERMINED." -Signals $sigs) }
  # The oracle asserts ITS OWN manipulation reached its target - it does not re-implement
  # health.ps1's grading thresholds, which are the thing under test.
  $f = ($v.freeGB -le ($TargetFreeAfterInjectGB + 2))
  New-GroundTruth -Faulted $f -Detail "$($Drive): has $($v.freeGB) GB free ($($v.freePercent)%); this fault aims for about $TargetFreeAfterInjectGB GB." -Signals $sigs
}

$doc = $null
try {
  $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot

  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Consumes free space with ballast outside the swept folders and junk inside them, sized so that cleaning the junk restores a HEALTHY volume.'
      $doc.targets = [ordered]@{ drive = $Drive; postCleanFreeGB = $PostCleanFreeGB; junkGB = $JunkGB
                                 freeAfterInjectGB = $TargetFreeAfterInjectGB; ballastRoot = $BallastRoot
                                 junkFolders = @("$env:TEMP", (Join-Path $env:SystemRoot 'Temp')) }
      $doc.fixes = @('temp-clean')
      $doc.sizingNote = 'health.ps1 grades the system drive critical under 20 GB free regardless of percentage, so the post-clean figure must clear 20 GB or a perfect repair still verifies as unhealthy.'
    }

    'probe' {
      $gt = Get-SpaceGroundTruth -State $state
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      $before = Get-VolumeRow -D $Drive
      if ($null -eq $before) { throw "Free space on $($Drive): could not be read, so the fill cannot be sized and nothing was written." }
      if ($before.freeGB -lt ($PostCleanFreeGB + 1)) {
        # REFUSE rather than fill a disk that is already too small for the arithmetic to work.
        $gt = New-GroundTruth -Faulted $null -Detail "The volume has only $($before.freeGB) GB free, which is below this fault's post-clean target of $PostCleanFreeGB GB. Filling it further could not produce a state a successful repair would clear, so NOTHING was written." -Signals @([ordered]@{ signal = 'volume'; value = $before })
        $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $null -GroundTruth $gt -Message $gt.detail
        break
      }

      $created = @(); $actions = @()

      # 1) Ballast, outside the swept folders: down to the post-clean target.
      if (-not (Test-Path -LiteralPath $BallastRoot)) { New-Item -ItemType Directory -Force -Path $BallastRoot | Out-Null }
      $ballastBytes = [int64](($before.freeGB - $PostCleanFreeGB) * 1GB)
      $n = 0
      $remaining = $ballastBytes
      while ($remaining -gt 0) {
        $chunk = [int64]([math]::Min([int64]4GB, $remaining))
        $p = Join-Path $BallastRoot ("ballast-{0:0000}.bin" -f (++$n))
        try { $created += (New-AllocatedFile -Path $p -Bytes $chunk) } catch { $actions += "$($_.Exception.Message); stopping the ballast here."; break }
        $remaining -= $chunk
      }
      $actions += "$n ballast file(s) totalling about $([math]::Round($ballastBytes/1GB,1)) GB created in $BallastRoot - OUTSIDE every folder temp-clean sweeps, so the repair cannot be credited with deleting them."

      # 2) Junk, inside the swept folders: the part the repair is supposed to reclaim.
      $junkDirs = @("$env:TEMP", (Join-Path $env:SystemRoot 'Temp'))
      $junkRemaining = [int64]($JunkGB * 1GB)
      $j = 0
      while ($junkRemaining -gt 0) {
        $dir = $junkDirs[$j % $junkDirs.Count]
        $chunk = [int64]([math]::Min([int64]($JunkFileGB * 1GB), $junkRemaining))
        $p = Join-Path $dir ("ffvmtest-junk-{0:000}.tmp" -f (++$j))
        try { $created += (New-AllocatedFile -Path $p -Bytes $chunk) } catch { $actions += "$($_.Exception.Message); stopping the junk here."; break }
        $junkRemaining -= $chunk
      }
      $actions += "$j junk file(s) totalling about $JunkGB GB written into $($junkDirs -join ' and ')."

      $after = Get-VolumeRow -D $Drive
      $capture = [ordered]@{ drive = $Drive; before = $before; after = $after; created = @($created)
                             ballastRoot = $BallastRoot; postCleanFreeGB = $PostCleanFreeGB; junkGB = $JunkGB }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-SpaceGroundTruth -State $capture
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot - without the manifest, revert would have to sweep the temp folders with a wildcard and would delete files it never created." }
      $actions = @(Remove-ManifestFiles -Paths @($state.created))
      try {
        if (Test-Path -LiteralPath $state.ballastRoot) { Remove-Item -LiteralPath $state.ballastRoot -Recurse -Force -ErrorAction Stop; $actions += "removed $($state.ballastRoot)" }
      } catch { $actions += "could not remove $($state.ballastRoot): $($_.Exception.Message)" }
      $gt = Get-SpaceGroundTruth -State $null
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Ballast and any remaining junk removed by manifest.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
