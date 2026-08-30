<#
  FAULT: optional-feature-disable
  Usually injects NOTHING - and that is the point.

  On a clean Windows 11 image NetFx3 is already DisabledWithPayloadRemoved, and NetFx4-AdvSrvs and
  DirectPlay are Disabled. The "fault" the enable-* repairs address is the DEFAULT STATE. What this
  script exists for is to CAPTURE that prior state precisely, so the undo assertion has something
  to compare against, and to disable the feature if some cell happens to ship it enabled.

  Why the capture matters: repair.ps1's undo for these features must restore the CAPTURED state,
  and DisabledWithPayloadRemoved is not the same machine state as Disabled - restoring it needs
  Disable-WindowsOptionalFeature -Remove. An undo that lands on plain Disabled has left the payload
  on disk and quietly changed the machine. That single distinction is doctrine rule 3 in miniature,
  and it is only observable because the prior state was read before anything ran.

  GROUND TRUTH: Get-WindowsOptionalFeature -Online -FeatureName <n> .State - a structured enum
  (Enabled / Disabled / DisabledWithPayloadRemoved / EnablePending / DisablePending). Enum values
  are identical on every UI language; the DISM console text is not.

  faulted = the feature is NOT Enabled (i.e. the repair has something to do).
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [ValidateSet('NetFx3','NetFx4-AdvSrvs','DirectPlay')]
  [string]$FeatureName = 'NetFx3',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'optional-feature-disable'

function Get-FeatureState {
  param([string]$Name)
  try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
    return [ordered]@{ name = $Name; readable = $true; state = "$($f.State)" }
  } catch {
    return [ordered]@{ name = $Name; readable = $false; state = $null; error = "$($_.Exception.Message)" }
  }
}

function Get-FeatureGroundTruth {
  param([string]$Name)
  $s = Get-FeatureState -Name $Name
  $sigs = @([ordered]@{ signal = 'windows-optional-feature-state'; value = $s })
  if (-not $s.readable) { return (New-GroundTruth -Faulted $null -Detail "The state of '$Name' could not be read; UNDETERMINED." -Signals $sigs) }
  $f = ("$($s.state)" -ne 'Enabled' -and "$($s.state)" -ne 'EnablePending')
  New-GroundTruth -Faulted $f -Detail "'$Name' is $($s.state)." -Signals $sigs
}

# The per-feature state file keeps NetFx3's capture from overwriting DirectPlay's.
$StateKey = "$FaultId.$FeatureName"

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Captures (and if necessary produces) the disabled state of an optional feature, so the enable-* repairs have a measured prior state to be undone to.'
      $doc.targets = @('NetFx3','NetFx4-AdvSrvs','DirectPlay')
      $doc.fixes = @('enable-netfx3','enable-netfx4-advsrvs','enable-directplay')
      $doc.note = 'NetFx3 additionally requires -SourcePath <media>\sources\sxs for the CELL ARCHITECTURE, because the payload is not on a clean image and the cells have no network.'
    }

    'probe' {
      $gt = Get-FeatureGroundTruth -Name $FeatureName
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
      $doc.featureName = $FeatureName
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Reading and changing optional feature state requires elevation.' }
      $before = Get-FeatureState -Name $FeatureName
      if (-not $before.readable) { throw "The prior state of '$FeatureName' could not be read, so nothing was changed - injecting without a capture would make the undo assertion meaningless." }
      $actions = @("Captured prior state: $($before.state).")
      if ("$($before.state)" -eq 'Enabled' -or "$($before.state)" -eq 'EnablePending') {
        try {
          $r = Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
          $actions += "Disabled '$FeatureName'$(if ($r.RestartNeeded) { ' (restart pending)' })."
        } catch { $actions += "Could not disable '$FeatureName': $($_.Exception.Message)" }
      } else {
        $actions += "'$FeatureName' was already $($before.state) on this clean image; nothing was changed. The capture is the deliverable here, not a mutation."
      }
      $capture = [ordered]@{ featureName = $FeatureName; before = $before }
      $null = Save-FaultState -Fault $StateKey -State $capture -StateRoot $StateRoot
      $gt = Get-FeatureGroundTruth -Name $FeatureName
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
      $doc.featureName = $FeatureName
    }

    'revert' {
      $state = Read-FaultState -Fault $StateKey -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$StateKey' at $StateRoot." }
      $prior = "$($state.before.state)"
      $now   = Get-FeatureState -Name $FeatureName
      $actions = @("Captured prior state was '$prior'; current state is '$($now.state)'.")
      if ("$($now.state)" -eq $prior) {
        $actions += 'Already matches the captured state; nothing to do.'
      } elseif ($prior -eq 'DisabledWithPayloadRemoved') {
        try { $null = Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -Remove -NoRestart -ErrorAction Stop
              $actions += "Disabled with -Remove, reproducing DisabledWithPayloadRemoved exactly (a plain Disable would have left the payload on disk - a different machine state)." }
        catch { $actions += "Could not restore DisabledWithPayloadRemoved: $($_.Exception.Message)" }
      } elseif ($prior -eq 'Disabled') {
        try { $null = Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop; $actions += 'Disabled, restoring the captured state.' }
        catch { $actions += "Could not disable: $($_.Exception.Message)" }
      } elseif ($prior -eq 'Enabled' -or $prior -eq 'EnablePending') {
        $actions += "The captured prior state was $prior, so this fault's revert leaves the feature enabled."
      } else {
        $actions += "The captured prior state '$prior' is not one this script knows how to reproduce; nothing was changed rather than guessing."
      }
      $gt = Get-FeatureGroundTruth -Name $FeatureName
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Revert attempted against the captured state.' -Evidence $actions
      $doc.featureName = $FeatureName
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
