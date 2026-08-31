<#
  BUILD :: version gating
           (_lib.ps1 Get-FFOsInfo, image.ps1 Get-FFOsIdentity/Get-FFGeneration,
            repair.ps1 Get-RepairOsInfo/Get-RepairApplicability)

  Two things must never happen:
    - CurrentVersion\ProductName being read as the generation. It literally says
      "Windows 10 Pro" on every Windows 11 machine, including this one.
    - a MISSING build number turning into build 0. [int]$null is 0, not an error, so a
      naive cast produces a confident number that then reads as "the media is newer than
      the installed build (26200 vs 0)" and as "this machine is older than Windows 11".

  Builds used here are the real ones: 19045 = Windows 10 22H2, 22000 = 11 21H2,
  22621 = 22H2, 22631 = 23H2, 26100 = 24H2, 26200 = 25H2.
#>

function Get-FFOsInfoUnderTest {
  param(
    [object]$CurrentBuildNumber = '26200', [object]$Ubr = 9168, [string]$DisplayVersion = '25H2',
    [string]$InstallationType = 'Client', [string]$ProductName = 'Windows 10 Pro',
    [object]$CimBuildNumber = $null, [string]$Caption = 'Microsoft Windows 11 Pro',
    [switch]$RegistryDenied, [switch]$CimDenied
  )
  $ctx = @{
    build = $CurrentBuildNumber; ubr = $Ubr; dv = $DisplayVersion; it = $InstallationType
    pn = $ProductName; cimBuild = $CimBuildNumber; caption = $Caption
    regDenied = [bool]$RegistryDenied; cimDenied = [bool]$CimDenied
  }
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx $ctx -Mocks {
    $script:FFOsInfoCache = $null
    $script:FFEditionCache = $null
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'CurrentVersion') {
        if ($TestCtx.regDenied) { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
        $o = [pscustomobject]@{ EditionID = 'Professional'; DisplayVersion = $TestCtx.dv
                                InstallationType = $TestCtx.it; ProductName = $TestCtx.pn; UBR = $TestCtx.ubr }
        if ($null -ne $TestCtx.build) { $o | Add-Member NoteProperty CurrentBuildNumber $TestCtx.build }
        return $o
      }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
      if ($TestCtx.cimDenied) { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
      if ("$ClassName" -eq 'Win32_OperatingSystem') {
        $o = [pscustomobject]@{ Caption = $TestCtx.caption; OperatingSystemSKU = 48; ProductType = 1 }
        if ($null -ne $TestCtx.cimBuild) { $o | Add-Member NoteProperty BuildNumber $TestCtx.cimBuild }
        return $o
      }
      if ("$ClassName" -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ PartOfDomain = $false; Domain = 'WORKGROUP' } }
      throw 'unexpected class' }
    function Get-ChildItem { param($Path, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'Enrollments') { return @() }
      Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters }
  } -Test { $TestCtx.res = Get-FFOsInfo }
  $r.res
}

foreach ($row in @(
  @{ Build = '19045'; Dv = '22H2'; Gen = 'win10'; Supported = $false; Label = 'Windows 10 22H2' }
  @{ Build = '22000'; Dv = '21H2'; Gen = 'win11'; Supported = $true;  Label = 'Windows 11 21H2' }
  @{ Build = '22621'; Dv = '22H2'; Gen = 'win11'; Supported = $true;  Label = 'Windows 11 22H2' }
  @{ Build = '22631'; Dv = '23H2'; Gen = 'win11'; Supported = $true;  Label = 'Windows 11 23H2' }
  @{ Build = '26100'; Dv = '24H2'; Gen = 'win11'; Supported = $true;  Label = 'Windows 11 24H2' }
  @{ Build = '26200'; Dv = '25H2'; Gen = 'win11'; Supported = $true;  Label = 'Windows 11 25H2' }
  @{ Build = '9600';  Dv = '';     Gen = 'older'; Supported = $false; Label = 'Windows 8.1' }
)) {
  Register-FFTest -Area 'BUILD' -Data $row -Name "os: $($row.Label) (build $($row.Build)) is classified correctly" -Body {
    $d = $FFTestData
    $os = Get-FFOsInfoUnderTest -CurrentBuildNumber $d.Build -DisplayVersion $d.Dv
    Assert-Eq ([int]$d.Build) $os.build 'the build number is read from CurrentBuildNumber'
    Assert-Eq $d.Gen $os.generation 'the generation must come from the build number'
    Assert-Eq $d.Supported $os.supported 'the supported-platform gate must match'
    if (-not $d.Supported) { Assert-NotNull $os.unsupportedReason 'an unsupported platform must say why' }
    else { Assert-Null $os.unsupportedReason 'a supported platform has no reason to give' }
  }
}

Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' -Name 'os: ProductName saying "Windows 10 Pro" never decides the generation' -Body {
  # This is what the registry literally says on the Windows 11 25H2 box this project is
  # developed on. Reading it as the generation would mark every Windows 11 install unsupported.
  $os = Get-FFOsInfoUnderTest -CurrentBuildNumber '26200' -ProductName 'Windows 10 Pro' -Caption 'Microsoft Windows 11 Pro'
  Assert-Eq 'win11' $os.generation 'the build number, not ProductName, decides the generation'
  Assert-Eq $true $os.supported 'and the platform is supported'
  Assert-Eq 'Microsoft Windows 11 Pro' $os.caption 'the human-facing name comes from Win32_OperatingSystem.Caption'
}

Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' -Name 'os: a Server / Server Core installation is unvalidated, not supported' -Body {
  foreach ($it in @('Server', 'Server Core')) {
    $os = Get-FFOsInfoUnderTest -CurrentBuildNumber '26100' -InstallationType $it
    Assert-Eq $false $os.supported "an InstallationType of '$it' is not a validated platform"
    Assert-Match "'$it'" $os.unsupportedReason 'and the installation type must be named in the reason'
  }
}

foreach ($row in @(
  @{ Reg = $null;   Cim = $null; Label = 'the registry value is missing and CIM has none either' }
  @{ Reg = 'abc';   Cim = $null; Label = 'the registry value is not a number' }
  @{ Reg = '';      Cim = $null; Label = 'the registry value is empty' }
)) {
  # WAS -Xfail, NOW A REAL EXPECTATION. The defect these reproduce: in _lib.ps1 Get-FFOsInfo,
  # `$build = [int]$cv.CurrentBuildNumber` was an unguarded cast, and [int]$null is 0 rather
  # than an error - so a machine whose CurrentBuildNumber cannot be read (GPO-hardened images,
  # Server Core, a denied key) reported build 0, generation "older", supported:false and the
  # confidently WRONG sentence "Windows build 0 is older than 22000". image.ps1
  # Get-FFOsIdentity already guarded with `if ($raw -match '^\d+$')` - digits or nothing.
  # These are no longer forgiven: a suite that exits 0 while reproducing a doctrine-2
  # violation is not a gate.
  Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' -Data $row `
    -Name "os: an unreadable build stays `$null, never 0 ($($row.Label))" -Body {
    $d = $FFTestData
    $os = Get-FFOsInfoUnderTest -CurrentBuildNumber $d.Reg -CimBuildNumber $d.Cim
    Assert-HonestUnknown $os.build 'a build number that could not be read'
    Assert-Ne 0 $os.build 'it must NEVER become 0 - [int]$null is 0, and 0 reads as "older than Windows 11"'
    Assert-Eq 'unknown' $os.generation 'the generation is unknown'
    Assert-Eq $false $os.supported 'an unknown build cannot be declared supported'
    Assert-Match 'could not be read' $os.unsupportedReason 'and the reason must say the build could not be read'
  }
}

# WAS -Xfail, NOW A REAL EXPECTATION. Same root cause as the rows above: while the unguarded
# [int] cast made $build 0 instead of $null, the guard `if ($null -eq $build -and $null -ne $ci)`
# was never true and the Win32_OperatingSystem.BuildNumber fallback was DEAD CODE in exactly the
# GPO-hardened / Server Core case it was written for.
Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' `
  -Name 'os: a hidden registry build falls back to Win32_OperatingSystem.BuildNumber' -Body {
  # GPO-hardened and Server Core images can hide CurrentBuildNumber.
  $os = Get-FFOsInfoUnderTest -CurrentBuildNumber $null -CimBuildNumber '26100'
  Assert-Eq 26100 $os.build 'CIM must supply the build when the registry cannot'
  Assert-Eq 'win11' $os.generation 'and the generation follows from it'
}

# ---------------- image.ps1 identity ----------------

Register-FFTest -Area 'BUILD' -Name 'image: Get-FFGeneration maps builds to generations, $null when unreadable' -Body {
  $r = Invoke-InEngineScope -Engine 'image' -Test {
    $TestCtx.map = [ordered]@{}
    foreach ($b in @(26200, 26100, 22631, 22621, 22000, 21996, 19045, 10240, 9600, 0)) {
      $TestCtx.map["$b"] = (Get-FFGeneration -Build $b)
    }
    $TestCtx.nullBuild = (Get-FFGeneration -Build $null)
    $TestCtx.textBuild = (Get-FFGeneration -Build 'abc')
  }
  Assert-Eq 'win11'  $r.map['26200'] '25H2 is Windows 11'
  Assert-Eq 'win11'  $r.map['22000'] '21H2 (the first Windows 11 build) is Windows 11'
  Assert-Eq 'win10'  $r.map['21996'] 'the pre-release 21996 build is below the 22000 line'
  Assert-Eq 'win10'  $r.map['19045'] '22H2 is Windows 10'
  Assert-Eq 'win10'  $r.map['10240'] 'the first Windows 10 build is Windows 10'
  Assert-Eq 'legacy' $r.map['9600']  'Windows 8.1 is legacy'
  Assert-HonestUnknown $r.map['0']    'build 0'
  Assert-HonestUnknown $r.nullBuild   'a null build'
  Assert-HonestUnknown $r.textBuild   'a non-numeric build'
}

Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' -Name 'image: Get-FFOsIdentity never reports build 0 for a missing registry value' -Body {
  $r = Invoke-InEngineScope -Engine 'image' -Ctx @{} -Mocks {
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'CurrentVersion') {
        return [pscustomobject]@{ EditionID = 'Professional'; DisplayVersion = ''; ProductName = 'Windows 10 Pro' } }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
      throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
  } -Test { $TestCtx.os = Get-FFOsIdentity }
  Assert-HonestUnknown $r.os.currentBuild 'a build that could not be read from either source'
  Assert-Ne 0 $r.os.currentBuild 'build 0 would read as "the media is newer than the installed build"'
  Assert-HonestUnknown $r.os.generation 'and the generation is unknown too'
  Assert-Eq 'unknown' $r.os.currentBuildSource 'the source must say it never got one'
  Assert-Null $r.os.buildString 'and no build string may be synthesised'
}

Register-FFTest -Area 'BUILD' -Name 'image: the product name prefers CIM Caption over the known-stale registry value' -Body {
  $r = Invoke-InEngineScope -Engine 'image' -Ctx @{} -Mocks {
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'CurrentVersion') {
        return [pscustomobject]@{ EditionID = 'Professional'; CurrentBuildNumber = '26200'; UBR = 9168
                                  DisplayVersion = '25H2'; ProductName = 'Windows 10 Pro' } }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
      if ("$ClassName" -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro' } }
      throw 'unexpected' }
  } -Test { $TestCtx.os = Get-FFOsIdentity }
  Assert-Eq 'Microsoft Windows 11 Pro' $r.os.productName 'the Caption wins'
  Assert-Eq 'cim-win32-operatingsystem-caption' $r.os.productNameSource 'and the source is recorded'
  Assert-Eq 'Windows 10 Pro' $r.os.productNameRegistry 'the stale registry value is still reported, so the lie is visible'
  Assert-Eq '26200.9168' $r.os.buildString 'the build string carries the UBR'
}

Register-FFTest -Area 'BUILD' -Name 'image: with no CIM, the product name is synthesised from build + edition' -Body {
  $r = Invoke-InEngineScope -Engine 'image' -Ctx @{} -Mocks {
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'CurrentVersion') {
        return [pscustomobject]@{ EditionID = 'Professional'; CurrentBuildNumber = '26200'; ProductName = 'Windows 10 Pro' } }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction) throw 'no CIM here' }
  } -Test { $TestCtx.os = Get-FFOsIdentity }
  Assert-Eq 'Windows 11 Professional' $r.os.productName 'the name is rebuilt from the build number and edition'
  Assert-Eq 'synthesised-from-build-and-edition' $r.os.productNameSource 'and it declares that it was synthesised'
  Assert-NoMatch 'Windows 10' $r.os.productName 'a Windows 11 machine is never named "Windows 10" at a reinstall consent gate'
}

# ---------------- repair.ps1 build gates ----------------

function Get-FFApplicability {
  param($Repair, [object]$Build = 26200, [string]$DisplayVersion = '25H2', [switch]$Unreadable)
  $ctx = @{ build = $Build; dv = $DisplayVersion; unreadable = [bool]$Unreadable; repair = $Repair }
  $r = Invoke-InEngineScope -Engine 'repair' -Ctx $ctx -Mocks {
    function Get-RepairOsInfo {
      if ($TestCtx.unreadable) {
        return [ordered]@{ currentBuild = $null; displayVersion = ''; generation = $null; readable = $false; error = 'Access is denied.' } }
      $gen = $null
      if ($null -ne $TestCtx.build) { if ($TestCtx.build -ge 22000) { $gen = 'win11' } elseif ($TestCtx.build -ge 10240) { $gen = 'win10' } else { $gen = 'legacy' } }
      [ordered]@{ currentBuild = $TestCtx.build; displayVersion = $TestCtx.dv; generation = $gen; readable = $true; error = $null } }
  } -Test { $TestCtx.res = Get-RepairApplicability $TestCtx.repair }
  $r.res
}

Register-FFTest -Area 'BUILD' -Name 'repair gate: minBuild / maxBuild / generation are all honoured' -Body {
  $min = [pscustomobject]@{ id = 't'; minBuild = 26100 }
  Assert-Eq $true  (Get-FFApplicability -Repair $min -Build 26200).applicable 'build 26200 satisfies minBuild 26100'
  Assert-Eq $true  (Get-FFApplicability -Repair $min -Build 26100).applicable 'the boundary build itself satisfies minBuild'
  $below = Get-FFApplicability -Repair $min -Build 22631 -DisplayVersion '23H2'
  Assert-Eq $false $below.applicable 'build 22631 does not satisfy minBuild 26100'
  Assert-Match '26100 or newer' $below.notApplicableReason 'and the requirement is stated'
  Assert-Match '23H2' $below.notApplicableReason 'along with the machine it was measured on'

  $max = [pscustomobject]@{ id = 't'; maxBuild = 22631 }
  Assert-Eq $true  (Get-FFApplicability -Repair $max -Build 22631).applicable 'the boundary build satisfies maxBuild'
  $above = Get-FFApplicability -Repair $max -Build 26200
  Assert-Eq $false $above.applicable 'a newer build is outside maxBuild'
  Assert-Match 'removed after that' $above.notApplicableReason 'and the reason explains why the rung is gone'

  $gen = [pscustomobject]@{ id = 't'; generation = 'win10' }
  Assert-Eq $false (Get-FFApplicability -Repair $gen -Build 26200).applicable 'a win10-only repair does not apply to Windows 11'
  Assert-Eq $true  (Get-FFApplicability -Repair $gen -Build 19045).applicable 'and it does apply to Windows 10'
}

Register-FFTest -Area 'BUILD' -Doctrine 'rule 2' -Name 'repair gate: an unreadable build is applicable=$null, never $true' -Body {
  # Running a build-gated repair on an unknown build is fixing blind - the same mistake as
  # running on a failed probe.
  $gated = [pscustomobject]@{ id = 't'; minBuild = 26100 }
  $r = Get-FFApplicability -Repair $gated -Unreadable
  Assert-HonestUnknown $r.applicable 'applicability when the build could not be read'
  Assert-Ne $true $r.applicable 'it must never fall through to "yes"'
  Assert-Match 'could not determine' $r.notApplicableReason 'and it must say so in those words'

  $ungated = [pscustomobject]@{ id = 't' }
  Assert-Eq $true (Get-FFApplicability -Repair $ungated -Unreadable).applicable 'a repair with NO build gate is unaffected by an unreadable build'
}

Register-FFTest -Area 'BUILD' -Doctrine 'rule 5' -Name 'repair gate: every build gate declared in data/repairs.json is well-formed' -Body {
  $r = Invoke-InEngineScope -Engine 'repair' -Test {
    $TestCtx.rows = @(@(Load-Catalog) | Where-Object { $_.minBuild -or $_.maxBuild -or $_.generation } |
      ForEach-Object { [ordered]@{ id = "$($_.id)"; minBuild = $_.minBuild; maxBuild = $_.maxBuild; generation = "$($_.generation)" } })
    $TestCtx.valid = @($script:ValidGenerations)
  }
  foreach ($row in @($r.rows)) {
    if ($null -ne $row.minBuild) { Assert-Match '^\d+$' "$($row.minBuild)" "$($row.id): minBuild must be a plain build number" }
    if ($null -ne $row.maxBuild) { Assert-Match '^\d+$' "$($row.maxBuild)" "$($row.id): maxBuild must be a plain build number" }
    if ("$($row.generation)" -match '\S') {
      Assert-In "$($row.generation)".ToLowerInvariant() @($r.valid) "$($row.id): generation must be one of the declared vocabulary"
    }
    if ($null -ne $row.minBuild -and $null -ne $row.maxBuild) {
      Assert-True ([int]$row.minBuild -le [int]$row.maxBuild) "$($row.id): minBuild must not exceed maxBuild"
    }
  }
  Assert-True ($null -ne $r.valid -and @($r.valid).Count -gt 0) 'the engine declares a generation vocabulary'
}
