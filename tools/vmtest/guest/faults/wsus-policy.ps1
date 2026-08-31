<#
  FAULT (used as CELL CONDITIONING, not as a per-repair fault): wsus-policy
  Writes the WSUS / Group Policy pinning that makes a machine "managed":

    HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
        WUServer, WUStatusServer      -> a WSUS server that does not exist
    HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
        UseWUServer = 1               -> the client must use it
        NoAutoUpdate = 1              -> and must not fetch on its own

  New-TestVm.ps1 applies this BEFORE the 'clean' checkpoint on the pro-24h2-wsus-x64 cell, so the
  policy is part of that cell's baseline rather than something injected per row. That is the whole
  design: the cell's clean state IS a managed machine.

  WHAT IT IS FOR. Several repair.ps1 branches only execute on a managed machine, and none of them
  have ever run:
    * wu-reset must NOT clear the WinHTTP proxy here (on a managed network it is the machine's only
      route to updates) and must NOT delete the WSUS client identity (an administrator's setting,
      and the client would re-register with WSUS, not with Microsoft). Deleting policy is precisely
      the WinUtil behaviour FrameForge advertises that it does not copy.
    * Get-WuManagementState must report managed=true / wsusManaged=true / the server URL, and the
      preflight managementNote must change wording accordingly. A preflight that still says "no
      WSUS pinning" on this cell is a measurement failure, not a cosmetic one.

  WHAT IT IS NOT. This is policy pinning WITHOUT domain membership. Win32_ComputerSystem.PartOfDomain
  stays false, there is no DC, and the Local GPO store is untouched - only the registry policy
  values a DC would have written. Branches that require real domain membership (ntp-resync's domain
  refusal) stay untested and are recorded as skip/'needs-domain-controller'.

  GROUND TRUTH: the policy values themselves.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$WsusServer = 'http://wsus.corp.invalid:8530',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'wsus-policy'
$PolKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

function Get-PolicyGroundTruth {
  $wu = Get-RegValueSnapshot -Path $PolKey -Name 'WUServer'
  $st = Get-RegValueSnapshot -Path $PolKey -Name 'WUStatusServer'
  $us = Get-RegValueSnapshot -Path $AuKey  -Name 'UseWUServer'
  $na = Get-RegValueSnapshot -Path $AuKey  -Name 'NoAutoUpdate'
  $sigs = @(
    [ordered]@{ signal = 'WUServer'; snapshot = $wu },
    [ordered]@{ signal = 'WUStatusServer'; snapshot = $st },
    [ordered]@{ signal = 'UseWUServer'; snapshot = $us },
    [ordered]@{ signal = 'NoAutoUpdate'; snapshot = $na },
    [ordered]@{ signal = 'partOfDomain'; value = $(try { [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { $null })
                note = 'Expected false: this is policy pinning, not domain membership.' }
  )
  if ($null -eq $wu.present -or $null -eq $us.present) {
    return (New-GroundTruth -Faulted $null -Detail 'The Windows Update policy key could not be read; UNDETERMINED.' -Signals $sigs)
  }
  $f = ($wu.present -eq $true -and "$($wu.value)" -eq $WsusServer -and $us.present -eq $true -and [int]$us.value -eq 1)
  New-GroundTruth -Faulted $f -Detail "WUServer='$($wu.value)', UseWUServer=$($us.value)." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Applies WSUS/GPO pinning. Used as cell conditioning, applied before the clean checkpoint.'
      $doc.targets = [ordered]@{ policyKey = $PolKey; auKey = $AuKey; wsusServer = $WsusServer }
      $doc.exercises = @('wu-reset managed branches','wu-reset-aggressive managed branches','Get-WuManagementState','preflight managementNote')
      $doc.doesNotProvide = @('domain membership','a real Local GPO store','a reachable WSUS server')
    }

    'probe' {
      $gt = Get-PolicyGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Writing HKLM policy values requires elevation.' }
      $capture = [ordered]@{
        polKeyExisted = (Test-Path -LiteralPath $PolKey)
        auKeyExisted  = (Test-Path -LiteralPath $AuKey)
        values = @(
          (Get-RegValueSnapshot -Path $PolKey -Name 'WUServer'),
          (Get-RegValueSnapshot -Path $PolKey -Name 'WUStatusServer'),
          (Get-RegValueSnapshot -Path $AuKey  -Name 'UseWUServer'),
          (Get-RegValueSnapshot -Path $AuKey  -Name 'NoAutoUpdate')
        )
        wsusServer = $WsusServer
      }
      if (-not (Test-Path -LiteralPath $AuKey)) { New-Item -Path $AuKey -Force | Out-Null }
      Set-ItemProperty -LiteralPath $PolKey -Name 'WUServer'       -Value $WsusServer -Type String
      Set-ItemProperty -LiteralPath $PolKey -Name 'WUStatusServer' -Value $WsusServer -Type String
      Set-ItemProperty -LiteralPath $AuKey  -Name 'UseWUServer'    -Value 1 -Type DWord
      Set-ItemProperty -LiteralPath $AuKey  -Name 'NoAutoUpdate'   -Value 1 -Type DWord
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-PolicyGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence @("WSUS pinning written for $WsusServer.")
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      foreach ($s in @($state.values)) { $actions += (Restore-RegValueSnapshot -Snapshot $s) }
      if ($state.auKeyExisted  -eq $false) { $actions += (Remove-RegKeyIfCreated -Path $AuKey  -WasPresent $false) }
      if ($state.polKeyExisted -eq $false) { $actions += (Remove-RegKeyIfCreated -Path $PolKey -WasPresent $false) }
      $gt = Get-PolicyGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured policy state restored.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
