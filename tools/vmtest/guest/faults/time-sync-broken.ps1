<#
  FAULT: time-sync-broken
  Breaks Windows time synchronisation:
    * W32Time stopped and Start=4
    * the manual peer list pointed at a host that cannot resolve
    * (optional) the clock skewed forward by -SkewMinutes, so a successful resync is visible as a
      correction rather than only as a log entry

  GROUND TRUTH: the W32Time Start DWORD, and the NtpServer / Type values under
  HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters. Registry values, not w32tm output -
  repair.ps1 ~216 parses w32tm's English 'Last Successful Sync Time' / 'unspecified', which is
  precisely the line that does not exist on de-DE or ja-JP.

  WHAT THE REPAIR MUST DO INSTEAD: the sync verdict is available structurally - the W32Time
  service state plus System event log id 35 (Microsoft-Windows-Time-Service). Event IDs are
  numeric and identical on every UI language. If neither can be read, the honest answer is
  "could not determine", not "synced".

  CLOCK REVERT IS PARTIAL AND SAYS SO. The script records the offset it applied and subtracts it
  back, but time has passed in between, so the clock does not return to the exact instant it left.
  Only a checkpoint restore does that. This is stated rather than hidden, because a fault script
  that quietly claims a perfect restore is the same sin as a repair that quietly claims success.

  NOTE: ntp-resync needs a reachable time server to actually succeed, so the orchestrator attaches
  a network adapter for this row. Without a network the honest result is "could not sync", and the
  plan records that expectation instead of calling it a failure.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [int]$SkewMinutes = 11,
  [string]$BogusPeer = 'time.does-not-exist.invalid',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId  = 'time-sync-broken'
$Svc      = 'W32Time'
$ParamKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'

function Get-TimeGroundTruth {
  $rows = Get-ServiceStartRows -Names @($Svc)
  $row  = @($rows)[0]
  $peer = Get-RegValueSnapshot -Path $ParamKey -Name 'NtpServer'
  $type = Get-RegValueSnapshot -Path $ParamKey -Name 'Type'
  $sigs = @(
    [ordered]@{ signal = 'w32time-service'; present = $row.present; start = $row.start; status = $row.status },
    [ordered]@{ signal = 'ntp-peer'; snapshot = $peer },
    [ordered]@{ signal = 'ntp-type'; snapshot = $type }
  )
  if (-not $row.present) { return (New-GroundTruth -Faulted $null -Detail 'The W32Time service key does not exist; nothing can be concluded.' -Signals $sigs) }
  if ($null -eq $row.start -or $null -eq $peer.present) { return (New-GroundTruth -Faulted $null -Detail 'The W32Time start value or its NtpServer parameter could not be read; UNDETERMINED.' -Signals $sigs) }
  $peerBogus = ($peer.present -eq $true -and "$($peer.value)" -like "*$BogusPeer*")
  $f = (($row.start -eq 4 -or "$($row.status)" -ne 'Running') -and $peerBogus)
  New-GroundTruth -Faulted $f -Detail "W32Time Start=$($row.start) status='$($row.status)'; NtpServer='$($peer.value)'." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Stops and disables W32Time, points the peer list at an unresolvable host, and optionally skews the clock.'
      $doc.targets = [ordered]@{ service = $Svc; parametersKey = $ParamKey; bogusPeer = $BogusPeer; skewMinutes = $SkewMinutes }
      $doc.fixes = @('ntp-resync')
      $doc.partialRevert = 'The clock offset is subtracted back, but the exact prior instant is unrecoverable in-guest.'
    }

    'probe' {
      $gt = Get-TimeGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Stopping W32Time and setting the system clock requires elevation.' }
      $capture = [ordered]@{
        services   = @(Get-ServiceStartRows -Names @($Svc))
        ntpServer  = (Get-RegValueSnapshot -Path $ParamKey -Name 'NtpServer')
        ntpType    = (Get-RegValueSnapshot -Path $ParamKey -Name 'Type')
        skewApplied = 0
        skewNote   = 'Revert subtracts skewApplied from the clock. It does NOT restore the exact prior instant - time passed in between. Restore the checkpoint if the exact clock matters.'
      }
      $actions = @()
      $actions += (Stop-ServiceHard -Name $Svc)
      try { $null = Set-ServiceStartValue -Name $Svc -Start 4; $actions += 'W32Time Start=4.' } catch { $actions += "W32Time Start could not be set: $($_.Exception.Message)" }
      try {
        if (-not (Test-Path -LiteralPath $ParamKey)) { New-Item -Path $ParamKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $ParamKey -Name 'NtpServer' -Value "$BogusPeer,0x9" -Type String -ErrorAction Stop
        Set-ItemProperty -LiteralPath $ParamKey -Name 'Type'      -Value 'NTP'            -Type String -ErrorAction Stop
        $actions += "NtpServer set to $BogusPeer (unresolvable), Type=NTP."
      } catch { $actions += "The NTP parameters could not be written: $($_.Exception.Message)" }
      if ($SkewMinutes -ne 0) {
        try { Set-Date -Adjust ([TimeSpan]::FromMinutes($SkewMinutes)) -ErrorAction Stop | Out-Null
              $capture.skewApplied = $SkewMinutes
              $actions += "Clock skewed forward by $SkewMinutes minute(s)." }
        catch { $actions += "The clock could not be skewed: $($_.Exception.Message)" }
      }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-TimeGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      $actions += (Restore-RegValueSnapshot -Snapshot $state.ntpServer)
      $actions += (Restore-RegValueSnapshot -Snapshot $state.ntpType)
      $actions += (Restore-ServiceStartRows -Rows $state.services)
      $skew = 0; try { $skew = [int]$state.skewApplied } catch {}
      if ($skew -ne 0) {
        try { Set-Date -Adjust ([TimeSpan]::FromMinutes(-1 * $skew)) -ErrorAction Stop | Out-Null
              $actions += "Clock adjusted back by $skew minute(s). This is NOT an exact restore of the prior instant - see skewNote." }
        catch { $actions += "The clock could not be adjusted back: $($_.Exception.Message)" }
      }
      $gt = Get-TimeGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured time configuration restored; the clock offset was reversed approximately.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
