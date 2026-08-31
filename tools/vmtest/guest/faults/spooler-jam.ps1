<#
  FAULT: spooler-jam
  Stops the print spooler and drops junk .SHD/.SPL pairs into the spool directory - the classic
  "the print queue is stuck and nothing will clear it" condition.

  GROUND TRUTH: a COUNT OF FILES in %SystemRoot%\System32\spool\PRINTERS that this script created
  (recorded by exact name in the capture), plus the Spooler service Start DWORD. The manifest
  matters: revert deletes only the files named in it, never a wildcard sweep of the spool folder,
  because a wildcard sweep would delete real queued jobs on a machine that had any.

  A VM has no printers, so the printer-error-state half of health.ps1's printing category cannot
  fire here. The spool-files-present and spooler-not-running halves are fully covered, and the
  results matrix records the coverage as partial rather than implying the category was proven.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [int]$JobCount = 4,
  [switch]$DisableService,
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId   = 'spooler-jam'
$Svc       = 'Spooler'
$SpoolDir  = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
$Prefix    = 'FFVMTEST'

function Get-OurSpoolFiles {
  if (-not (Test-Path -LiteralPath $SpoolDir)) { return $null }
  try { return @(Get-ChildItem -LiteralPath $SpoolDir -File -Force -ErrorAction Stop | Where-Object { $_.Name -like "$Prefix*" }) } catch { return $null }
}

function Get-SpoolerGroundTruth {
  $rows = Get-ServiceStartRows -Names @($Svc)
  $row  = @($rows)[0]
  $ours = Get-OurSpoolFiles
  $sigs = @(
    [ordered]@{ signal = 'spooler-service'; present = $row.present; start = $row.start; status = $row.status },
    [ordered]@{ signal = 'spool-junk-file-count'; dir = $SpoolDir; value = $(if ($null -eq $ours) { $null } else { @($ours).Count })
                names = $(if ($null -eq $ours) { @() } else { @($ours | ForEach-Object { $_.Name }) }) }
  )
  if ($null -eq $ours) { return (New-GroundTruth -Faulted $null -Detail "The spool directory could not be listed ($SpoolDir); UNDETERMINED." -Signals $sigs) }
  if (-not $row.present) { return (New-GroundTruth -Faulted $null -Detail 'The Spooler service key does not exist; nothing can be concluded.' -Signals $sigs) }
  $f = (@($ours).Count -gt 0 -and "$($row.status)" -ne 'Running')
  New-GroundTruth -Faulted $f -Detail "$(@($ours).Count) junk spool file(s) present; Spooler status '$($row.status)'." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Stops the spooler and writes junk .SHD/.SPL files into the spool directory.'
      $doc.targets = [ordered]@{ service = $Svc; spoolDir = $SpoolDir; filePrefix = $Prefix }
      $doc.fixes = @('spooler-clear-queue')
    }

    'probe' {
      $gt = Get-SpoolerGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Writing to the spool directory requires elevation.' }
      $capture = [ordered]@{ services = @(Get-ServiceStartRows -Names @($Svc)); created = @() }
      $actions = @()
      $actions += (Stop-ServiceHard -Name $Svc)
      if (-not (Test-Path -LiteralPath $SpoolDir)) { New-Item -ItemType Directory -Force -Path $SpoolDir | Out-Null }
      $created = @()
      for ($i = 1; $i -le $JobCount; $i++) {
        $stem = Join-Path $SpoolDir ("{0}{1:00000}" -f $Prefix, $i)
        try {
          $created += (New-JunkFile -Path "$stem.SHD" -Bytes 4096)
          $created += (New-JunkFile -Path "$stem.SPL" -Bytes 131072)
        } catch { $actions += "could not write $stem : $($_.Exception.Message)" }
      }
      $capture.created = @($created)
      $actions += "$(@($created).Count) junk spool file(s) written."
      if ($DisableService) {
        try { $null = Set-ServiceStartValue -Name $Svc -Start 4; $actions += 'Spooler Start=4.' } catch { $actions += "Spooler Start could not be set: $($_.Exception.Message)" }
      }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-SpoolerGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      # Only the files in the manifest. If the repair already deleted them, that is reported as
      # 'already gone' - which is evidence the repair worked, not an error.
      $actions += (Remove-ManifestFiles -Paths @($state.created))
      $actions += (Restore-ServiceStartRows -Rows $state.services)
      $gt = Get-SpoolerGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured state restored; only the files this fault created were removed.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
