<#
  FAULT: winget-broken
  Unregisters Microsoft.DesktopAppInstaller for the current user, which removes winget.exe from
  the user's PATH (the WindowsApps execution alias disappears with the registration).

  GROUND TRUTH: Get-AppxPackage Microsoft.DesktopAppInstaller returns an object or it does not,
  and Get-Command winget.exe resolves or it does not. Both structural.

  HONEST LIMIT: revert re-registers from the staged AppxManifest.xml that is still on disk, which
  works offline. If the staged package is genuinely gone, there is nothing to re-register without
  a network, and this script SAYS SO rather than reporting a restore that did not happen. The same
  limit applies to the repair under test: winget-repair should report "could not repair without a
  network", which is why the plan expects 'detected-not-verified' for that row rather than a pass.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId = 'winget-broken'
$PkgName = 'Microsoft.DesktopAppInstaller'

function Get-WingetGroundTruth {
  $pkg = $null
  try { $pkg = Get-AppxPackage -Name $PkgName -ErrorAction Stop | Select-Object -First 1 } catch {}
  $cmd = $null
  try { $cmd = (Get-Command winget.exe -ErrorAction SilentlyContinue) } catch {}
  $sigs = @(
    [ordered]@{ signal = 'appx-package'; name = $PkgName; registered = [bool]$pkg; version = $(if ($pkg) { "$($pkg.Version)" } else { $null }) },
    [ordered]@{ signal = 'winget-on-path'; resolved = [bool]$cmd; path = $(if ($cmd) { "$($cmd.Source)" } else { $null }) }
  )
  New-GroundTruth -Faulted ((-not $pkg) -and (-not $cmd)) -Detail "DesktopAppInstaller registered=$([bool]$pkg); winget on PATH=$([bool]$cmd)." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Unregisters App Installer for the current user, removing winget from PATH.'
      $doc.targets = @{ package = $PkgName }
      $doc.fixes = @('winget-repair')
    }

    'probe' {
      $gt = Get-WingetGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      $pkg = $null
      try { $pkg = Get-AppxPackage -Name $PkgName -ErrorAction Stop | Select-Object -First 1 } catch {}
      $actions = @()
      $capture = [ordered]@{ package = $null }
      if ($null -eq $pkg) {
        $actions += "$PkgName was already not registered for $env:USERNAME; nothing was changed."
      } else {
        $capture.package = [ordered]@{ fullName = "$($pkg.PackageFullName)"; installLocation = "$($pkg.InstallLocation)"; version = "$($pkg.Version)" }
        try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop; $actions += "Unregistered $($pkg.PackageFullName)." }
        catch { $actions += "Remove-AppxPackage failed: $($_.Exception.Message)" }
      }
      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-WingetGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      if ($null -eq $state.package) {
        $actions += 'Nothing was unregistered at inject time, so there is nothing to re-register.'
      } else {
        $manifest = Join-Path "$($state.package.installLocation)" 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
          try { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop; $actions += "Re-registered from $manifest." }
          catch { $actions += "Re-registration FAILED: $($_.Exception.Message)" }
        } else {
          $actions += "The staged manifest is gone ($manifest). App Installer cannot be re-registered offline; restore the checkpoint. Reported rather than claimed as restored."
        }
      }
      $gt = Get-WingetGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Revert attempted from capture.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
