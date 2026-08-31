<#
  FAULT: services-disabled
  The generic "a gaming/debloat script disabled this" fault. Sets a named set of services to
  Start=4 (disabled) in the registry and stops them.

  GROUND TRUTH: the Start DWORD under HKLM\SYSTEM\CurrentControlSet\Services\<name>. A number,
  identical on every UI language, readable and writable even for the services whose SCM security
  descriptor denies Set-Service (AppXSvc, ClipSVC, StateRepository).

  REVERT restores the EXACT captured Start value per service - including restoring a service to
  'disabled' if that is what it was before injection - and restarts only the services that were
  Running when captured. It never assumes 'auto' is the right answer, because for several of
  these services on several editions it is not.

  This is the cleanest row in the matrix: a number goes in, a number comes out, and no text is
  read anywhere in the loop. If a locale cell fails HERE, the bug is not a locale bug.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$Preset = 'audio',
  [string[]]$Services,
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'services-disabled'

# Presets mirror data/repairs.json's dependency sets. Keys are SERVICE KEY NAMES, never display
# names - display names are translated and would not resolve on de-DE or ja-JP.
$Presets = @{
  'audio'   = @('Audiosrv','AudioEndpointBuilder')
  'store'   = @('AppXSvc','ClipSVC','StateRepository','InstallService')
  'update'  = @('wuauserv','bits','cryptsvc','UsoSvc','DoSvc')
  'search'  = @('WSearch')
  'spooler' = @('Spooler')
  'time'    = @('W32Time')
}

function Resolve-TargetServices {
  if ($Services -and @($Services).Count -gt 0) { return @($Services) }
  if (-not $Presets.ContainsKey($Preset)) { throw "Unknown -Preset '$Preset'. Valid: $(($Presets.Keys | Sort-Object) -join ', '). Or pass -Services explicitly." }
  @($Presets[$Preset])
}

function Get-ServicesGroundTruth {
  param([string[]]$Names)
  $rows = Get-ServiceStartRows -Names $Names
  $missing  = @($rows | Where-Object { -not $_.present })
  $unreadable = @($rows | Where-Object { $_.present -and $null -eq $_.start })
  $disabled = @($rows | Where-Object { $_.present -and $_.start -eq 4 })
  if ($unreadable.Count -gt 0) {
    return (New-GroundTruth -Faulted $null -Detail "The Start value of $($unreadable.Count) service(s) could not be read ($(($unreadable | ForEach-Object { $_.name }) -join ', ')). The fault state is UNDETERMINED." -Signals $rows)
  }
  $present = @($rows | Where-Object { $_.present })
  if ($present.Count -eq 0) {
    return (New-GroundTruth -Faulted $null -Detail "None of the target services exist on this build ($($Names -join ', ')). That is a platform difference, not a fault state - nothing can be concluded." -Signals $rows)
  }
  $faulted = ($disabled.Count -eq $present.Count -and $disabled.Count -gt 0)
  $detail = "$($disabled.Count) of $($present.Count) present service(s) have Start=4 (disabled)."
  if ($missing.Count -gt 0) { $detail += " $($missing.Count) target(s) do not exist on this build: $(($missing | ForEach-Object { $_.name }) -join ', ')." }
  New-GroundTruth -Faulted $faulted -Detail $detail -Signals $rows
}

$doc = $null
try {
  $targets = Resolve-TargetServices

  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Disables a named set of services by writing Start=4 to their registry keys.'
      $doc.presets = $Presets
      $doc.targets = @($targets)
      $doc.fixes = @('store-services-enable','audio-restart','wu-reset','search-index-rebuild','spooler-clear-queue','ntp-resync')
    }

    'probe' {
      $gt = Get-ServicesGroundTruth -Names $targets
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Writing service Start values requires elevation.' }
      $before = Get-ServiceStartRows -Names $targets
      $actions = @()
      foreach ($r in $before) {
        if (-not $r.present) { $actions += "$($r.name): not present on this build, skipped."; continue }
        $actions += (Stop-ServiceHard -Name $r.name)
        try { $null = Set-ServiceStartValue -Name $r.name -Start 4; $actions += "$($r.name): Start set to 4 (disabled)." }
        catch { $actions += "$($r.name): Start could NOT be set - $($_.Exception.Message)" }
      }
      $capture = [ordered]@{ preset = $Preset; targets = @($targets); before = @($before) }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-ServicesGroundTruth -Names $targets
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot - revert would have to invent the prior start types, which is exactly what doctrine rule 3 forbids." }
      $actions = Restore-ServiceStartRows -Rows $state.before
      $gt = Get-ServicesGroundTruth -Names @($state.targets)
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured start types restored.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc
if ($doc.ok) { exit 0 } else { exit 1 }
