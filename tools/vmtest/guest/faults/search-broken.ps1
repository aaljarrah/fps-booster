<#
  FAULT: search-broken
  Breaks Windows Search:
    stop-only  stops WSearch, leaving Start alone. Produces the honest "the indexer process is
               gone" condition without destroying the index - this is the fault for shell-restart.
    full       stops WSearch, sets Start=4, and TRUNCATES Windows.edb to zero bytes. This is the
               real-world "the index is corrupt" condition search-index-rebuild exists for.

  GROUND TRUTH: the WSearch Start DWORD, whether SearchIndexer.exe is in the process table, and
  the LENGTH IN BYTES of Windows.edb. A file length is a number; "the index looks small" is not.

  A truncated .edb is deliberately different from a deleted one. Deleting it makes Windows
  rebuild silently at next start, which would repair the fault before the repair ran. A zero-byte
  file that still exists is corrupt, stays corrupt, and is what the probe must notice.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [ValidateSet('full','stop-only')]
  [string]$Preset = 'full',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'search-broken'
$Svc     = 'WSearch'
$EdbPath = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows\Windows.edb'
$Aside   = "$EdbPath.ffvmtest-aside"

function Get-SearchGroundTruth {
  $rows = Get-ServiceStartRows -Names @($Svc)
  $row  = @($rows)[0]
  $proc = $null
  try { $proc = @(Get-Process -Name 'SearchIndexer' -ErrorAction SilentlyContinue).Count } catch {}
  $edbLen = $null; $edbThere = Test-Path -LiteralPath $EdbPath
  if ($edbThere) { try { $edbLen = (Get-Item -LiteralPath $EdbPath -Force).Length } catch { $edbLen = $null } }
  $sigs = @(
    [ordered]@{ signal = 'wsearch-service'; present = $row.present; start = $row.start; status = $row.status },
    [ordered]@{ signal = 'searchindexer-process-count'; value = $proc },
    [ordered]@{ signal = 'windows-edb'; path = $EdbPath; present = $edbThere; bytes = $edbLen; asidePresent = (Test-Path -LiteralPath $Aside) }
  )
  if (-not $row.present) { return (New-GroundTruth -Faulted $null -Detail 'The WSearch service key does not exist on this machine; nothing can be concluded.' -Signals $sigs) }
  if ($null -eq $row.start) { return (New-GroundTruth -Faulted $null -Detail 'The WSearch Start value could not be read; UNDETERMINED.' -Signals $sigs) }

  if ($Preset -eq 'stop-only') {
    $f = ("$($row.status)" -ne 'Running')
    return (New-GroundTruth -Faulted $f -Detail "WSearch status is '$($row.status)'." -Signals $sigs)
  }
  if ($edbThere -and $null -eq $edbLen) { return (New-GroundTruth -Faulted $null -Detail 'Windows.edb exists but its length could not be read; UNDETERMINED.' -Signals $sigs) }
  $f = (($row.start -eq 4) -and $edbThere -and ($edbLen -eq 0))
  New-GroundTruth -Faulted $f -Detail "WSearch Start=$($row.start), Windows.edb present=$edbThere bytes=$edbLen." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Stops WSearch and (preset full) disables it and truncates Windows.edb.'
      $doc.presets = @('full','stop-only')
      $doc.targets = [ordered]@{ service = $Svc; index = $EdbPath }
      $doc.fixes = @('search-index-rebuild','shell-restart')
    }

    'probe' {
      $gt = Get-SearchGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Stopping WSearch and touching the index requires elevation.' }
      $capture = [ordered]@{ preset = $Preset; services = @(Get-ServiceStartRows -Names @($Svc)); edbMoved = $false; edbBytesBefore = $null }
      $actions = @()
      $actions += (Stop-ServiceHard -Name $Svc)

      if ($Preset -eq 'full') {
        try { $null = Set-ServiceStartValue -Name $Svc -Start 4; $actions += "$Svc Start=4." } catch { $actions += "$Svc Start could not be set: $($_.Exception.Message)" }
        if (Test-Path -LiteralPath $EdbPath) {
          try { $capture.edbBytesBefore = (Get-Item -LiteralPath $EdbPath -Force).Length } catch {}
          if (Test-Path -LiteralPath $Aside) { Remove-Item -LiteralPath $Aside -Force -ErrorAction SilentlyContinue }
          try {
            # Move the real index aside (so revert can restore the captured file, not a rebuilt
            # one) and put a zero-byte file in its place.
            Move-Item -LiteralPath $EdbPath -Destination $Aside -Force -ErrorAction Stop
            [System.IO.File]::WriteAllBytes($EdbPath, (New-Object byte[] 0))
            $capture.edbMoved = $true
            $actions += "Windows.edb ($($capture.edbBytesBefore) bytes) moved to $Aside and replaced with a zero-byte file."
          } catch { $actions += "Windows.edb could NOT be truncated: $($_.Exception.Message)" }
        } else {
          $actions += 'Windows.edb does not exist on this machine yet; only the service rung was injected. Reported, not hidden.'
        }
      }

      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-SearchGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      $null = Stop-ServiceHard -Name $Svc
      if ($state.edbMoved -eq $true) {
        try {
          if (Test-Path -LiteralPath $EdbPath) { Remove-Item -LiteralPath $EdbPath -Force -ErrorAction Stop }
          Move-Item -LiteralPath $Aside -Destination $EdbPath -Force -ErrorAction Stop
          $actions += 'The captured Windows.edb was moved back.'
        } catch { $actions += "Windows.edb could NOT be restored: $($_.Exception.Message)" }
      }
      $actions += (Restore-ServiceStartRows -Rows $state.services)
      $gt = Get-SearchGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured state restored.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
