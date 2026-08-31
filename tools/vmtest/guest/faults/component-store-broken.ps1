<#
  FAULT: component-store-broken
  Renames one payload file inside WinSxS so that the component store is GENUINELY corrupt - the
  condition DISM /ScanHealth reports as Repairable and SFC reports as a corrupt member file.

  THIS DOES REAL DAMAGE TO THE WINDOWS IMAGE. It runs only inside a throwaway VM, only against a
  target drawn from the candidate list below, and it REFUSES rather than improvising when no
  candidate resolves. A fault script that picks a random file out of WinSxS is a fault script
  that eventually bricks something and cannot say what it broke.

  TARGET SELECTION (documented ladder, structural at every rung):
    1. -TargetPath, if given explicitly.
    2. The first pattern in $CandidatePatterns that resolves to exactly one existing file under
       WinSxS. The patterns name payload from components that are (a) present on every Windows 11
       SKU in this matrix, (b) not required to boot, and (c) covered by Windows Resource
       Protection, which is what makes SFC notice.
    3. No match -> REFUSE with injected:$null and an explanation. "I could not find a safe target"
       is a first-class outcome; guessing is not.

  GROUND TRUTH: the file exists at its original path (healthy) or at <path>.ffvmtest-broken
  (faulted). Two Test-Path calls. Nothing is read from DISM or SFC output - those are the things
  under test, and using them as the oracle would be circular.

  OWNERSHIP: WinSxS payload is owned by TrustedInstaller and its ACL denies write to
  Administrators. Injection takes ownership and grants itself write, CAPTURING the original owner
  SDDL first; revert renames the file back and restores the captured owner and ACL. If the repair
  under test already restored the file from the component store (which is a PASS - it means the
  repair worked), revert reports that instead of failing.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$TargetPath,
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId  = 'component-store-broken'
$WinSxS   = Join-Path $env:SystemRoot 'WinSxS'
$Suffix   = '.ffvmtest-broken'
$takeown  = Join-Path $env:SystemRoot 'System32\takeown.exe'
$icacls   = Join-Path $env:SystemRoot 'System32\icacls.exe'

# Non-boot-critical, WRP-protected payload present on every Win11 SKU in this matrix. Ordered
# most-preferred first. The architecture prefix is a wildcard so the same list works on ARM64.
$CandidatePatterns = @(
  '*_microsoft-windows-mspaint_*\mspaint.exe',
  '*_microsoft-windows-notepad_*\notepad.exe',
  '*_microsoft-windows-charmap_*\charmap.exe',
  '*_microsoft-windows-calc*_*\win32calc.exe',
  '*_microsoft-windows-magnify_*\magnify.exe'
)

function Resolve-Target {
  param([string]$Explicit)
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit)) { throw "-TargetPath does not exist: $Explicit" }
    return [ordered]@{ path = $Explicit; pattern = '(explicit -TargetPath)' }
  }
  foreach ($pat in $CandidatePatterns) {
    $hits = @()
    try { $hits = @(Get-ChildItem -LiteralPath $WinSxS -Filter (Split-Path -Leaf $pat) -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -like (Join-Path $WinSxS $pat) }) } catch {}
    if ($hits.Count -ge 1) { return [ordered]@{ path = $hits[0].FullName; pattern = $pat; candidateCount = $hits.Count } }
  }
  $null
}

function Get-ComponentGroundTruth {
  param([string]$Path)
  if (-not $Path) { return (New-GroundTruth -Faulted $null -Detail 'No target file is known (nothing injected and no capture on disk), so the component store fault state cannot be determined by this oracle.' -Signals @()) }
  $broken = "$Path$Suffix"
  $orig = Test-Path -LiteralPath $Path
  $ren  = Test-Path -LiteralPath $broken
  $sigs = @([ordered]@{ signal = 'winsxs-payload-file'; original = $Path; originalPresent = $orig; renamed = $broken; renamedPresent = $ren })
  if ($ren -and -not $orig) { return (New-GroundTruth -Faulted $true  -Detail "The payload file is missing from its component directory and present as $broken - the component store is corrupt." -Signals $sigs) }
  if ($orig -and -not $ren) { return (New-GroundTruth -Faulted $false -Detail 'The payload file is back in its component directory.' -Signals $sigs) }
  if ($orig -and $ren)      { return (New-GroundTruth -Faulted $false -Detail 'The payload file is present AND a renamed copy exists - a repair restored the original from the store. The component itself is intact.' -Signals $sigs) }
  New-GroundTruth -Faulted $null -Detail 'Neither the original nor the renamed file exists. Something else moved it; nothing can be concluded.' -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Renames a WinSxS payload file to produce genuine component-store corruption.'
      $doc.targets = [ordered]@{ winSxS = $WinSxS; candidatePatterns = $CandidatePatterns; suffix = $Suffix }
      $doc.fixes = @('dism-restorehealth','sfc-scannow')
      $doc.warning = 'Real damage. VM only. Never run on a machine whose Windows installation matters.'
    }

    'probe' {
      $path = $TargetPath
      if (-not $path) { $s = Read-FaultState -Fault $FaultId -StateRoot $StateRoot; if ($s) { $path = "$($s.target)" } }
      $gt = Get-ComponentGroundTruth -Path $path
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Taking ownership inside WinSxS requires elevation.' }
      $t = Resolve-Target -Explicit $TargetPath
      if ($null -eq $t) {
        # REFUSAL, not a guess.
        $gt = New-GroundTruth -Faulted $null -Detail 'No candidate WinSxS payload file resolved on this build. The fault was NOT injected and no file was touched - picking an arbitrary file out of the component store is not an acceptable fallback.' -Signals @([ordered]@{ signal = 'candidate-patterns-tried'; value = $CandidatePatterns })
        $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $null -GroundTruth $gt -Message $gt.detail
        break
      }
      $path = "$($t.path)"
      $actions = @()
      $acl = $null; $owner = $null
      try { $acl = (Get-Acl -LiteralPath $path).Sddl; $owner = (Get-Acl -LiteralPath $path).Owner } catch { $actions += "ACL could not be captured: $($_.Exception.Message)" }
      $to = Invoke-NativeCapture -FilePath $takeown -Arguments @('/F', $path)
      $ic = Invoke-NativeCapture -FilePath $icacls  -Arguments @($path, '/grant', "*S-1-5-32-544:(F)")
      $actions += "takeown exit $($to.exitCode); icacls exit $($ic.exitCode) (grant to the literal SID S-1-5-32-544, because the group NAME is localized)."
      $capture = [ordered]@{ target = $path; pattern = "$($t.pattern)"; sddl = $acl; owner = $owner; renamedTo = "$path$Suffix" }
      try {
        Rename-Item -LiteralPath $path -NewName ((Split-Path -Leaf $path) + $Suffix) -Force -ErrorAction Stop
        $actions += "Renamed to $(Split-Path -Leaf $path)$Suffix."
      } catch { $actions += "Rename FAILED: $($_.Exception.Message)" }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-ComponentGroundTruth -Path $path
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence @($actions, $to, $ic)
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $path = "$($state.target)"; $broken = "$path$Suffix"
      $actions = @()
      if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $broken)) {
        try { Remove-Item -LiteralPath $broken -Force -ErrorAction Stop; $actions += 'A repair had already restored the original from the component store; the renamed copy was removed.' }
        catch { $actions += "The renamed copy could not be removed: $($_.Exception.Message)" }
      } elseif (Test-Path -LiteralPath $broken) {
        try { Rename-Item -LiteralPath $broken -NewName (Split-Path -Leaf $path) -Force -ErrorAction Stop; $actions += 'Payload file renamed back.' }
        catch { $actions += "Rename back FAILED: $($_.Exception.Message)" }
      } else {
        $actions += 'Neither file is present; nothing could be renamed back.'
      }
      if ($state.sddl -and (Test-Path -LiteralPath $path)) {
        try {
          $sd = New-Object System.Security.AccessControl.FileSecurity
          $sd.SetSecurityDescriptorSddlForm("$($state.sddl)")
          Set-Acl -LiteralPath $path -AclObject $sd -ErrorAction Stop
          $actions += 'Captured ACL/owner SDDL restored.'
        } catch { $actions += "The captured SDDL could NOT be restored ($($_.Exception.Message)). The file is back but its ACL is not the original - restore the checkpoint rather than trusting this VM's component store." }
      }
      $gt = Get-ComponentGroundTruth -Path $path
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Revert attempted from capture.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
