<#
  FAULT: dirty-bit
  Sets the NTFS volume dirty bit - the exact condition chkdsk exists for, and the condition
  health.ps1's disk probe reads at ~174 with an English 'is Dirty' / 'is NOT Dirty' text match.

  GROUND TRUTH: the EXIT CODE of `fsutil dirty query <drive>:`
      0 = the volume IS dirty
      1 = the volume is NOT dirty
  The exit code is identical on en-US, de-DE and ja-JP. The SENTENCE fsutil prints is not, and
  that difference is the entire reason this cell exists. This script therefore reads the code and
  keeps the text only as evidence.

  NOT REVERTIBLE IN-GUEST. There is no `fsutil dirty clear`. The bit is cleared by chkdsk (which
  is the repair under test) or by discarding the VM state, so -Action revert reports
  revertible:$false and explains itself rather than pretending. The orchestrator restores the
  clean checkpoint after every row anyway, which is the real undo.

  DO NOT REBOOT between inject and the repair: autochk clears the bit during boot, and the repair
  would then be measured against a volume that is no longer dirty - a false pass manufactured by
  the harness itself.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$Drive = 'C',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'dirty-bit'
$fsutil  = Join-Path $env:SystemRoot 'System32\fsutil.exe'

function Get-DirtyGroundTruth {
  param([string]$D)
  if (-not (Test-Path -LiteralPath $fsutil)) {
    return (New-GroundTruth -Faulted $null -Detail "fsutil.exe not found at $fsutil, so the dirty bit could not be read at all." -Signals @())
  }
  $r = Invoke-NativeCapture -FilePath $fsutil -Arguments @('dirty','query',"$($D):")
  $sig = @([ordered]@{ signal = 'fsutil-dirty-query-exitcode'; value = $r.exitCode; meaning = '0 = dirty, 1 = not dirty'; text = $r.output })
  switch ($r.exitCode) {
    0 { return (New-GroundTruth -Faulted $true  -Detail "fsutil dirty query $($D): exited 0 - the volume IS dirty." -Signals $sig) }
    1 { return (New-GroundTruth -Faulted $false -Detail "fsutil dirty query $($D): exited 1 - the volume is NOT dirty." -Signals $sig) }
  }
  New-GroundTruth -Faulted $null -Detail "fsutil dirty query $($D): exited $($r.exitCode), which is neither 0 nor 1. The dirty bit could not be determined." -Signals $sig
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Revertible $false -Message 'Sets the NTFS dirty bit on the target volume. Ground truth is the fsutil exit code. Cleared only by chkdsk or by restoring the checkpoint.'
      $doc.targets = @{ drive = $Drive }
      $doc.fixes = @('chkdsk-scan','chkdsk-spotfix','chkdsk-full-repair')
    }

    'probe' {
      $gt = Get-DirtyGroundTruth -D $Drive
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -Revertible $false -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'fsutil dirty set requires elevation.' }
      $before = Get-DirtyGroundTruth -D $Drive
      $set = Invoke-NativeCapture -FilePath $fsutil -Arguments @('dirty','set',"$($Drive):")
      $after = Get-DirtyGroundTruth -D $Drive
      $capture = [ordered]@{ drive = $Drive; dirtyBefore = $before.faulted; setExitCode = $set.exitCode }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $msg = if ($after.faulted -eq $true) { "Dirty bit SET on $($Drive): and confirmed by exit code. Do not reboot before running the repair - autochk would clear it." }
             elseif ($after.faulted -eq $false) { "fsutil dirty set exited $($set.exitCode) but the volume still reads NOT dirty. The fault was NOT injected." }
             else { 'The dirty bit could not be read after the set attempt, so injection is UNCONFIRMED. Nothing may be concluded from this row.' }
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $after.faulted -Revertible $false -GroundTruth $after -Capture $capture -Message $msg -Evidence @($set)
    }

    'revert' {
      $gt = Get-DirtyGroundTruth -D $Drive
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -Revertible $false -GroundTruth $gt -Message 'NOT REVERTIBLE IN-GUEST: Windows offers no way to clear the NTFS dirty bit except by running chkdsk, which is the repair under test. Restore the clean checkpoint instead - the orchestrator does that after every row.'
      $doc.ok = $true
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Revertible $false -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc
if ($doc.ok) { exit 0 } else { exit 1 }
