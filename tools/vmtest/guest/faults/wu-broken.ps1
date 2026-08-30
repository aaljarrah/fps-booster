<#
  FAULT: wu-broken
  Breaks the Windows Update pipeline the three ways it actually breaks in the field:
    services   wuauserv, bits, cryptsvc, UsoSvc, DoSvc stopped and Start=4
    datastore  SoftwareDistribution\DataStore renamed aside and a junk DataStore.edb written in
               its place, so the update store is present but corrupt rather than merely missing
    policy     a dead WSUS pin: HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
               WUServer/WUStatusServer pointing at a host that does not resolve, plus
               AU\UseWUServer=1

  GROUND TRUTH: service Start DWORDs, the existence of the junk .edb and the renamed folder, and
  the policy values themselves. All structural.

  WHY THE POLICY RUNG MATTERS. wu-reset is documented as scoped: it must NOT delete Policies
  hives and must NOT remove the WSUS client identity, because on a managed machine those are the
  only route to updates - that is the WinUtil behaviour FrameForge advertises it does not copy.
  So on the WSUS cell this rung is part of the BASELINE (conditioning), and the per-repair fault
  there should use -Preset services or datastore. Injecting it as a fault on an unmanaged cell
  is still useful: it makes Get-WuManagementState report managed=true and exercises the same
  cautious branches.

  REVERT restores captured service start types, moves the real DataStore back, and restores each
  policy value to exactly what it was - removing values that did not exist before, restoring the
  ones that did.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [ValidateSet('full','services','datastore','policy')]
  [string]$Preset = 'full',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId   = 'wu-broken'
$WuSvcs    = @('wuauserv','bits','cryptsvc','UsoSvc','DoSvc')
$SdRoot    = Join-Path $env:SystemRoot 'SoftwareDistribution'
$DataStore = Join-Path $SdRoot 'DataStore'
$Aside     = Join-Path $SdRoot 'DataStore.ffvmtest-aside'
$JunkEdb   = Join-Path $DataStore 'DataStore.edb'
$PolKey    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
# TEST-NET-2 (RFC 5737) - guaranteed never to resolve to a real WSUS server anywhere.
$DeadWsus  = 'http://wsus-does-not-exist.invalid:8530'

function Test-Rung { param([string]$Rung) ($Preset -eq 'full' -or $Preset -eq $Rung) }

function Get-WuGroundTruth {
  $sigs = @()
  $verdicts = @()

  if (Test-Rung 'services') {
    $rows = Get-ServiceStartRows -Names $WuSvcs
    $sigs += [ordered]@{ signal = 'service-start-values'; rows = @($rows) }
    $present = @($rows | Where-Object { $_.present })
    $unreadable = @($present | Where-Object { $null -eq $_.start })
    if ($unreadable.Count -gt 0) { $verdicts += $null }
    else { $verdicts += ((@($present | Where-Object { $_.start -eq 4 })).Count -eq $present.Count -and $present.Count -gt 0) }
  }

  if (Test-Rung 'datastore') {
    $asideThere = Test-Path -LiteralPath $Aside
    $junkThere  = Test-Path -LiteralPath $JunkEdb
    $junkLen = $null
    if ($junkThere) { try { $junkLen = (Get-Item -LiteralPath $JunkEdb).Length } catch {} }
    $sigs += [ordered]@{ signal = 'softwaredistribution'; asidePresent = $asideThere; junkEdbPresent = $junkThere; junkEdbBytes = $junkLen }
    $verdicts += ($asideThere -and $junkThere)
  }

  if (Test-Rung 'policy') {
    $wu = Get-RegValueSnapshot -Path $PolKey -Name 'WUServer'
    $au = Get-RegValueSnapshot -Path $AuKey  -Name 'UseWUServer'
    $sigs += [ordered]@{ signal = 'wsus-policy'; wuServer = $wu; useWuServer = $au }
    if ($null -eq $wu.present -or $null -eq $au.present) { $verdicts += $null }
    else { $verdicts += ($wu.present -and "$($wu.value)" -eq $DeadWsus -and $au.present -and [int]$au.value -eq 1) }
  }

  if (@($verdicts | Where-Object { $null -eq $_ }).Count -gt 0) {
    return (New-GroundTruth -Faulted $null -Detail 'At least one rung of this fault could not be read, so the injection state is UNDETERMINED.' -Signals $sigs)
  }
  $all = (@($verdicts | Where-Object { $_ -eq $true }).Count -eq @($verdicts).Count)
  New-GroundTruth -Faulted $all -Detail "Preset '$Preset': $(@($verdicts | Where-Object { $_ -eq $true }).Count) of $(@($verdicts).Count) rung(s) are in the faulted state." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Disables the update services, corrupts SoftwareDistribution\DataStore, and writes a dead WSUS policy.'
      $doc.presets = @('full','services','datastore','policy')
      $doc.targets = [ordered]@{ services = $WuSvcs; dataStore = $DataStore; policyKey = $PolKey; deadWsusServer = $DeadWsus }
      $doc.fixes = @('wu-reset','wu-reset-aggressive')
    }

    'probe' {
      $gt = Get-WuGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Breaking the update stack requires elevation.' }
      $actions = @()
      $capture = [ordered]@{ preset = $Preset; services = $null; dataStoreMoved = $false; policy = $null; policyKeyExisted = $null; auKeyExisted = $null }

      if (Test-Rung 'services') {
        $capture.services = @(Get-ServiceStartRows -Names $WuSvcs)
        foreach ($r in $capture.services) {
          if (-not $r.present) { $actions += "$($r.name): not present on this build."; continue }
          $actions += (Stop-ServiceHard -Name $r.name)
          try { $null = Set-ServiceStartValue -Name $r.name -Start 4; $actions += "$($r.name): Start=4." } catch { $actions += "$($r.name): $($_.Exception.Message)" }
        }
      }

      if (Test-Rung 'datastore') {
        # Stop wuauserv first or the .edb is locked. If DataStore does not exist yet (a machine
        # that has never scanned) there is nothing to move, and the script says so rather than
        # inventing a corruption that Windows would simply recreate.
        $null = Stop-ServiceHard -Name 'wuauserv'
        if (Test-Path -LiteralPath $DataStore) {
          if (Test-Path -LiteralPath $Aside) { Remove-Item -LiteralPath $Aside -Recurse -Force -ErrorAction SilentlyContinue }
          try {
            Move-Item -LiteralPath $DataStore -Destination $Aside -Force -ErrorAction Stop
            $capture.dataStoreMoved = $true
            $actions += "DataStore moved aside to $Aside."
          } catch { $actions += "DataStore could NOT be moved aside: $($_.Exception.Message)" }
        } else {
          $actions += "No DataStore folder existed (this image has never scanned for updates); only the junk .edb is written."
        }
        try { $null = New-JunkFile -Path $JunkEdb -Bytes 262144; $actions += "Junk DataStore.edb written ($JunkEdb)." }
        catch { $actions += "Junk DataStore.edb could NOT be written: $($_.Exception.Message)" }
      }

      if (Test-Rung 'policy') {
        $capture.policyKeyExisted = (Test-Path -LiteralPath $PolKey)
        $capture.auKeyExisted     = (Test-Path -LiteralPath $AuKey)
        $capture.policy = @(
          (Get-RegValueSnapshot -Path $PolKey -Name 'WUServer'),
          (Get-RegValueSnapshot -Path $PolKey -Name 'WUStatusServer'),
          (Get-RegValueSnapshot -Path $AuKey  -Name 'UseWUServer')
        )
        if (-not (Test-Path -LiteralPath $AuKey)) { New-Item -Path $AuKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $PolKey -Name 'WUServer'       -Value $DeadWsus -Type String
        Set-ItemProperty -LiteralPath $PolKey -Name 'WUStatusServer' -Value $DeadWsus -Type String
        Set-ItemProperty -LiteralPath $AuKey  -Name 'UseWUServer'    -Value 1 -Type DWord
        $actions += "WSUS policy written pointing at $DeadWsus (UseWUServer=1)."
      }

      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-WuGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot - nothing can be restored without inventing prior state." }
      $actions = @()
      if ($state.services) { $actions += (Restore-ServiceStartRows -Rows $state.services) }
      if ($state.dataStoreMoved -eq $true) {
        $null = Stop-ServiceHard -Name 'wuauserv'
        try {
          if (Test-Path -LiteralPath $DataStore) { Remove-Item -LiteralPath $DataStore -Recurse -Force -ErrorAction Stop }
          Move-Item -LiteralPath $Aside -Destination $DataStore -Force -ErrorAction Stop
          $actions += 'The real DataStore was moved back.'
        } catch { $actions += "DataStore could NOT be moved back: $($_.Exception.Message)" }
      } elseif (Test-Path -LiteralPath $JunkEdb) {
        $actions += (Remove-ManifestFiles -Paths @($JunkEdb))
      }
      if ($state.policy) {
        foreach ($s in @($state.policy)) { $actions += (Restore-RegValueSnapshot -Snapshot $s) }
        if ($state.auKeyExisted -eq $false)     { $actions += (Remove-RegKeyIfCreated -Path $AuKey  -WasPresent $false) }
        if ($state.policyKeyExisted -eq $false) { $actions += (Remove-RegKeyIfCreated -Path $PolKey -WasPresent $false) }
      }
      $gt = Get-WuGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured state restored.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
