<#
  FAULT: store-broken
  Breaks the Microsoft Store three ways:
    unregister  Remove-AppxPackage on Microsoft.WindowsStore for the CURRENT USER (the staged
                package stays in WindowsApps, so re-registration is possible offline - which is
                what store-reregister does)
    cache       renames the Store package's LocalCache aside and writes junk in its place
    services    AppXSvc, ClipSVC, StateRepository, InstallService set to Start=4

  GROUND TRUTH: Get-AppxPackage returns an OBJECT (or does not), the LocalCache paths exist or do
  not, and the service Start values are DWORDs. No text is parsed.

  WHY THE REGISTRY FOR THE SERVICES: Set-Service on AppXSvc is access-denied even for an elevated
  administrator - its SCM security descriptor does not grant SERVICE_CHANGE_CONFIG to
  Administrators. Writing the Start value directly is the only way to disable it, and it is also
  exactly what the debloat scripts do, so it is the realistic fault.

  NOTE ON SCOPE: this unregisters for the user the harness logs in as. That is the same scope
  store-reregister repairs. Provisioned-for-all-users state is left alone; store-reregister-all
  is the repair that touches that, and its fault is this one with -Preset full.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [ValidateSet('full','unregister','cache','services')]
  [string]$Preset = 'full',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId  = 'store-broken'
$PkgName  = 'Microsoft.WindowsStore'
$StoreSvc = @('AppXSvc','ClipSVC','StateRepository','InstallService')
$CacheRoot = Join-Path $env:LOCALAPPDATA 'Packages'

function Test-Rung { param([string]$Rung) ($Preset -eq 'full' -or $Preset -eq $Rung) }

function Get-StorePackage {
  try { return (Get-AppxPackage -Name $PkgName -ErrorAction Stop | Select-Object -First 1) } catch { return $null }
}
function Get-StoreCachePath {
  # The package family folder under %LOCALAPPDATA%\Packages, found by prefix match on the family
  # name - a structural lookup, not a hard-coded publisher hash.
  try {
    $d = Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction Stop | Where-Object { $_.Name -like "$PkgName`_*" } | Select-Object -First 1
    if ($null -eq $d) { return $null }
    return (Join-Path $d.FullName 'LocalCache')
  } catch { return $null }
}

function Get-StoreGroundTruth {
  $sigs = @(); $verdicts = @()

  if (Test-Rung 'unregister') {
    $pkg = Get-StorePackage
    $sigs += [ordered]@{ signal = 'appx-package'; name = $PkgName; registered = [bool]$pkg
                         version = $(if ($pkg) { "$($pkg.Version)" } else { $null })
                         status  = $(if ($pkg) { "$($pkg.Status)" } else { $null }) }
    $verdicts += (-not $pkg)
  }

  if (Test-Rung 'cache') {
    $cache = Get-StoreCachePath
    $aside = $null; $exists = $null; $asideExists = $null
    if ($cache) { $aside = "$cache.ffvmtest-aside"; $exists = Test-Path -LiteralPath $cache; $asideExists = Test-Path -LiteralPath $aside }
    $sigs += [ordered]@{ signal = 'store-localcache'; path = $cache; present = $exists; asidePresent = $asideExists }
    if ($null -eq $cache) { $verdicts += $null } else { $verdicts += [bool]$asideExists }
  }

  if (Test-Rung 'services') {
    $rows = Get-ServiceStartRows -Names $StoreSvc
    $sigs += [ordered]@{ signal = 'service-start-values'; rows = @($rows) }
    $present = @($rows | Where-Object { $_.present })
    if (@($present | Where-Object { $null -eq $_.start }).Count -gt 0) { $verdicts += $null }
    else { $verdicts += ((@($present | Where-Object { $_.start -eq 4 })).Count -eq $present.Count -and $present.Count -gt 0) }
  }

  if (@($verdicts | Where-Object { $null -eq $_ }).Count -gt 0) {
    return (New-GroundTruth -Faulted $null -Detail 'At least one rung could not be read; the injection state is UNDETERMINED.' -Signals $sigs)
  }
  $all = (@($verdicts | Where-Object { $_ -eq $true }).Count -eq @($verdicts).Count)
  New-GroundTruth -Faulted $all -Detail "Preset '$Preset': $(@($verdicts | Where-Object { $_ -eq $true }).Count) of $(@($verdicts).Count) rung(s) faulted." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Unregisters the Store package for the current user, corrupts its LocalCache, and disables its dependency services.'
      $doc.presets = @('full','unregister','cache','services')
      $doc.targets = [ordered]@{ package = $PkgName; services = $StoreSvc; cacheRoot = $CacheRoot }
      $doc.fixes = @('store-cache-reset','store-reregister','store-reregister-all','store-services-enable')
    }

    'probe' {
      $gt = Get-StoreGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      $actions = @()
      $capture = [ordered]@{ preset = $Preset; package = $null; services = $null; cachePath = $null; cacheMoved = $false }

      if (Test-Rung 'cache') {
        $cache = Get-StoreCachePath
        $capture.cachePath = $cache
        if ($cache -and (Test-Path -LiteralPath $cache)) {
          $aside = "$cache.ffvmtest-aside"
          if (Test-Path -LiteralPath $aside) { Remove-Item -LiteralPath $aside -Recurse -Force -ErrorAction SilentlyContinue }
          try {
            Move-Item -LiteralPath $cache -Destination $aside -Force -ErrorAction Stop
            New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $null = New-JunkFile -Path (Join-Path $cache 'Microsoft\Windows\INetCache\ffvmtest-junk.dat') -Bytes 131072
            $capture.cacheMoved = $true
            $actions += "LocalCache moved aside to $aside and replaced with junk."
          } catch { $actions += "LocalCache could NOT be moved aside: $($_.Exception.Message)" }
        } else {
          $actions += 'No Store LocalCache folder was found for this user; the cache rung did nothing (reported, not hidden).'
        }
      }

      if (Test-Rung 'unregister') {
        $pkg = Get-StorePackage
        if ($null -eq $pkg) {
          $actions += 'The Store package was already not registered for this user; nothing to unregister.'
        } else {
          $capture.package = [ordered]@{ fullName = "$($pkg.PackageFullName)"; family = "$($pkg.PackageFamilyName)"; installLocation = "$($pkg.InstallLocation)"; version = "$($pkg.Version)" }
          try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop; $actions += "Unregistered $($pkg.PackageFullName) for $env:USERNAME." }
          catch { $actions += "Remove-AppxPackage failed: $($_.Exception.Message)" }
        }
      }

      if (Test-Rung 'services') {
        if (-not (Test-FaultAdmin)) { throw 'Disabling the Store dependency services requires elevation.' }
        $capture.services = @(Get-ServiceStartRows -Names $StoreSvc)
        foreach ($r in $capture.services) {
          if (-not $r.present) { $actions += "$($r.name): not present on this build."; continue }
          $actions += (Stop-ServiceHard -Name $r.name)
          try { $null = Set-ServiceStartValue -Name $r.name -Start 4; $actions += "$($r.name): Start=4 (written in the registry - Set-Service is denied for these)." }
          catch { $actions += "$($r.name): $($_.Exception.Message)" }
        }
      }

      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-StoreGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      if ($state.services) { $actions += (Restore-ServiceStartRows -Rows $state.services) }
      if ($state.cacheMoved -eq $true -and $state.cachePath) {
        $aside = "$($state.cachePath).ffvmtest-aside"
        try {
          if (Test-Path -LiteralPath $state.cachePath) { Remove-Item -LiteralPath $state.cachePath -Recurse -Force -ErrorAction Stop }
          Move-Item -LiteralPath $aside -Destination $state.cachePath -Force -ErrorAction Stop
          $actions += 'The real LocalCache was moved back.'
        } catch { $actions += "LocalCache could NOT be moved back: $($_.Exception.Message)" }
      }
      if ($state.package) {
        # Re-register from the staged manifest that is still on disk. This needs no network,
        # which is why the cells can run without one.
        $manifest = Join-Path "$($state.package.installLocation)" 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
          try { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop; $actions += "Re-registered $($state.package.fullName) from $manifest." }
          catch { $actions += "Re-registration FAILED: $($_.Exception.Message)" }
        } else {
          $actions += "The staged manifest is gone ($manifest), so the package cannot be re-registered offline. Restore the checkpoint instead - this is reported rather than being silently treated as restored."
        }
      }
      $gt = Get-StoreGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured state restored where restoration was possible.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
