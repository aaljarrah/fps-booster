<#
  SKU :: editions this machine will never be
        (_lib.ps1 Get-FFEdition / Test-FFCapability, image.ps1 Get-FFBitLockerStatus + rails)

  Windows 11 Home has no BitLocker PowerShell module. N/KN editions ship without the media
  feature pack. LTSC and IoT ship without the Microsoft Store. System Restore can be off by
  policy. Every one of those is a BY-DESIGN absence, and the bar is that the engines tell an
  absence apart from a fault - and, crucially, apart from "I could not check".

  available = $false  means "measured: this edition does not have it"
  available = $null   means "could not determine" and must NEVER be produced by a probe
                      that was denied, or by one that simply did not run.
#>

function Get-FFCapability {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$EditionId = 'Professional',
    [object]$IsLtsc = $false, [object]$IsServer = $false, [string]$InstallationType = 'Client',
    [string[]]$CommandsPresent = @(),
    [string]$CimBehaviour = 'ok',        # ok | denied | missing
    [object]$DisableSr = $null,
    [string]$SrPolicyBehaviour = 'absent', # absent | denied
    [string]$AppxBehaviour = 'ok'        # ok | denied | absent
  )
  $ctx = @{
    capName = $Name
    editionId = $EditionId; isLtsc = $IsLtsc; isServer = $IsServer; installationType = $InstallationType
    cmds = @($CommandsPresent); cim = $CimBehaviour; disableSr = $DisableSr
    srPolicy = $SrPolicyBehaviour; appx = $AppxBehaviour
  }
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx $ctx -Mocks {
    function Get-FFEdition {
      [ordered]@{ editionId = $TestCtx.editionId; sku = 48; caption = 'Microsoft Windows 11'
                  installationType = $TestCtx.installationType
                  isN = [bool]("$($TestCtx.editionId)" -match '(?i)(N|KN)$'); isLtsc = $TestCtx.isLtsc
                  isServer = $TestCtx.isServer; isDomainJoined = $false; isMdmEnrolled = $false
                  policyManagerPresent = $false; source = 'stub' } }
    function Get-Command { param($Name, $ErrorAction, $CommandType, $Module)
      if (@($TestCtx.cmds) -contains "$Name") { return [pscustomobject]@{ Name = $Name } }
      throw "The term '$Name' is not recognized." }
    function Get-CimInstance { param($Namespace, $ClassName, $Filter, $ErrorAction)
      switch ($TestCtx.cim) {
        'denied'  { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
        'missing' { throw "Invalid namespace: $Namespace" }
        default   { return [pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = 0 } }
      } }
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'SystemRestore') {
        if ($TestCtx.srPolicy -eq 'denied') { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
        if ($null -eq $TestCtx.disableSr) { throw 'Property DisableSR does not exist.' }
        return [pscustomobject]@{ DisableSR = $TestCtx.disableSr }
      }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-AppxProvisionedPackage { param([switch]$Online, $ErrorAction)
      switch ($TestCtx.appx) {
        'denied' { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
        'absent' { return @() }
        default  { return @([pscustomobject]@{ DisplayName = 'Microsoft.WindowsStore' }) }
      } }
    function Get-AppxPackage { param($Name, $ErrorAction) throw 'not available' }
  } -Test { $TestCtx.res = Test-FFCapability -Name $TestCtx.capName }
  $r.res
}

# ---------------- BitLocker: absent on Home, unknown when denied ----------------

Register-FFTest -Area 'SKU' -Name 'BitLocker: present when the module exists (Pro/Enterprise/Education)' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ capName = 'BitLocker' } -Mocks {
    function Get-Command { param($Name, $ErrorAction, $CommandType, $Module)
      if ("$Name" -eq 'Get-BitLockerVolume') { return [pscustomobject]@{ Name = $Name } }
      throw 'not found' }
  } -Test { $TestCtx.res = Test-FFCapability -Name 'BitLocker' }
  Assert-Eq $true $r.res.available 'the BitLocker module means BitLocker management is available'
  Assert-Eq 'cmdlet' $r.res.how 'and the source is the cmdlet'
}

foreach ($row in @(
  @{ Edition = 'Core';                Label = 'Windows 11 Home' }
  @{ Edition = 'CoreN';               Label = 'Windows 11 Home N' }
  @{ Edition = 'CoreSingleLanguage';  Label = 'Windows 11 Home Single Language' }
)) {
  Register-FFTest -Area 'SKU' -Data $row -Name "BitLocker: $($row.Label) is a measured absence, not a fault" -Body {
    $d = $FFTestData
    $r = Get-FFCapability -Name 'BitLocker' -EditionId $d.Edition -CommandsPresent @() -CimBehaviour 'missing'
    Assert-Eq $false $r.available "$($d.Label) does not include BitLocker management"
    Assert-Eq 'registry' $r.how 'the edition is what decided it'
    Assert-Match "'$($d.Edition)'" $r.detail 'the edition must be named in the explanation'
  }
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'BitLocker: a DENIED WMI provider is unknown, never absent' -Body {
  # The provider exists; we were simply not allowed to ask. "Denied" is not "absent", and
  # reporting $false here would tell a Pro user their machine cannot be encrypted.
  $r = Get-FFCapability -Name 'BitLocker' -EditionId 'Professional' -CommandsPresent @() -CimBehaviour 'denied'
  Assert-HonestUnknown $r.available 'a denied BitLocker WMI query'
  Assert-Match 'without administrator rights' $r.detail 'the reason must be stated'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'BitLocker: an inconclusive edition is unknown, never absent' -Body {
  $r = Get-FFCapability -Name 'BitLocker' -EditionId 'SomeFutureEdition' -CommandsPresent @() -CimBehaviour 'missing'
  Assert-HonestUnknown $r.available 'an edition string this table does not know'
  Assert-Match 'not conclusive' $r.detail 'the reason must say the edition was inconclusive'
}

Register-FFTest -Area 'SKU' -Name 'BitLocker: Home reached through the WMI provider still answers true' -Body {
  # Home has no module but DOES have Win32_EncryptableVolume (Device Encryption uses it).
  $r = Get-FFCapability -Name 'BitLocker' -EditionId 'Core' -CommandsPresent @() -CimBehaviour 'ok'
  Assert-Eq $true $r.available 'the WMI provider answering means encryption management is present'
  Assert-Eq 'wmi' $r.how 'and the source is the WMI rung, not the edition table'
}

# ---------------- Store: absent by design on LTSC/IoT and Server ----------------

Register-FFTest -Area 'SKU' -Name 'Store: LTSC and Server are measured absences' -Body {
  $ltsc = Get-FFCapability -Name 'Store' -EditionId 'EnterpriseS' -IsLtsc $true
  Assert-Eq $false $ltsc.available 'LTSC ships without the Store by design'
  Assert-Match 'by design' $ltsc.detail 'and the wording must say it is by design, not broken'

  $srv = Get-FFCapability -Name 'Store' -EditionId 'ServerStandard' -IsServer $true -InstallationType 'Server'
  Assert-Eq $false $srv.available 'Server ships without the Store by design'
  Assert-Match 'by design' $srv.detail 'and says so'
}

Register-FFTest -Area 'SKU' -Name 'Store: an N edition is NOT treated as a Store-less edition' -Body {
  # N editions drop media features, not the Store. Confusing the two would hide a real fault.
  $r = Get-FFCapability -Name 'Store' -EditionId 'ProfessionalN' -AppxBehaviour 'ok'
  Assert-Eq $true $r.available 'ProfessionalN has the Store'
  Assert-Eq 'cmdlet' $r.how 'and it was measured, not inferred from the edition name'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'Store: a denied provisioned-package query is unknown, never absent' -Body {
  $r = Get-FFCapability -Name 'Store' -EditionId 'Professional' -AppxBehaviour 'denied'
  Assert-HonestUnknown $r.available 'a denied Appx query'
  Assert-Match 'undetermined' $r.detail 'the wording must say undetermined'
}

Register-FFTest -Area 'SKU' -Name 'Store: a genuinely unprovisioned image reports absent' -Body {
  $r = Get-FFCapability -Name 'Store' -EditionId 'Professional' -AppxBehaviour 'absent'
  Assert-Eq $false $r.available 'an image with no Store package reports absent'
  Assert-Match 'not provisioned' $r.detail 'and names what it measured'
}

# ---------------- System Restore: disabled by policy vs. not measured ----------------

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'System Restore: DisableSR=1 is a measured, explained absence' -Body {
  $r = Get-FFCapability -Name 'SystemRestore' -DisableSr 1 -SrPolicyBehaviour 'present'
  Assert-Eq $false $r.available 'a policy-disabled System Restore is genuinely unavailable'
  Assert-Eq 'registry' $r.how 'the policy value is what decided it'
  Assert-Match 'DisableSR' $r.detail 'the exact policy value must be named so the user can check it'
}

Register-FFTest -Area 'SKU' -Name 'System Restore: available when Checkpoint-Computer exists and no policy blocks it' -Body {
  $r = Get-FFCapability -Name 'SystemRestore' -CommandsPresent @('Checkpoint-Computer')
  Assert-Eq $true $r.available 'Checkpoint-Computer present and no DisableSR means restore points can be requested'
  Assert-Match 'per-volume protection may still be off' $r.detail 'and the claim is bounded honestly'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'System Restore: no cmdlet and no readable policy is unknown, never absent' -Body {
  foreach ($policy in @('absent', 'denied')) {
    $r = Get-FFCapability -Name 'SystemRestore' -CommandsPresent @() -SrPolicyBehaviour $policy
    Assert-HonestUnknown $r.available "System Restore with no cmdlet and a '$policy' policy read"
    Assert-Match 'undetermined' $r.detail 'the wording must say undetermined'
  }
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'Optional features: a missing DISM module is unknown, never absent' -Body {
  $absent = Get-FFCapability -Name 'OptionalFeatures' -CommandsPresent @()
  Assert-HonestUnknown $absent.available 'optional-feature management with no Get-WindowsOptionalFeature'
  $present = Get-FFCapability -Name 'OptionalFeatures' -CommandsPresent @('Get-WindowsOptionalFeature')
  Assert-Eq $true $present.available 'the DISM module present means features can be enumerated'
  Assert-Match 'elevation still required' $present.detail 'and the remaining limitation is stated'
}

# ---------------- Get-FFEdition itself ----------------

function Get-FFEditionUnderTest {
  param([object]$EditionId = 'Professional', [string]$RegBehaviour = 'ok', [string]$CimBehaviour = 'ok', [string]$InstallationType = 'Client')
  $ctx = @{ editionId = $EditionId; reg = $RegBehaviour; cim = $CimBehaviour; installType = $InstallationType }
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx $ctx -Mocks {
    $script:FFEditionCache = $null
    $script:FFOsInfoCache = $null
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'CurrentVersion') {
        if ($TestCtx.reg -eq 'denied') { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
        return [pscustomobject]@{ EditionID = $TestCtx.editionId; CurrentBuildNumber = '26200'; UBR = 9168
                                  DisplayVersion = '25H2'; InstallationType = $TestCtx.installType; ProductName = 'Windows 10 Pro' }
      }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
      if ($TestCtx.cim -eq 'denied') { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
      if ("$ClassName" -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26200'; OperatingSystemSKU = 48; ProductType = 1 } }
      if ("$ClassName" -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ PartOfDomain = $false; Domain = 'WORKGROUP' } }
      throw 'unexpected class' }
    function Get-ChildItem { param($Path, $ErrorAction, $LiteralPath)
      if ("$Path" -match 'Enrollments') { return @() }
      Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters }
  } -Test { $TestCtx.res = Get-FFEdition }
  $r.res
}

foreach ($row in @(
  @{ Edition = 'Professional';  N = $false; Ltsc = $false }
  @{ Edition = 'ProfessionalN'; N = $true;  Ltsc = $false }
  @{ Edition = 'CoreN';         N = $true;  Ltsc = $false }
  @{ Edition = 'EnterpriseS';   N = $false; Ltsc = $true }
  @{ Edition = 'EnterpriseSN';  N = $true;  Ltsc = $true }
  @{ Edition = 'IoTEnterprise'; N = $false; Ltsc = $true }
)) {
  Register-FFTest -Area 'SKU' -Data $row -Name "edition: $($row.Edition) is classified correctly (isN/isLtsc)" -Body {
    $d = $FFTestData
    $e = Get-FFEditionUnderTest -EditionId $d.Edition
    Assert-Eq $d.Edition $e.editionId 'the edition id is read from the registry'
    Assert-Eq $d.N    $e.isN    'the N/KN classification must be right'
    Assert-Eq $d.Ltsc $e.isLtsc 'the LTSC/IoT classification must be right'
  }
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'edition: an unreadable registry leaves every derived flag $null, not $false' -Body {
  $e = Get-FFEditionUnderTest -RegBehaviour 'denied'
  Assert-HonestUnknown $e.editionId 'an unreadable EditionID'
  Assert-HonestUnknown $e.isN       'the N flag derived from an unread edition'
  Assert-HonestUnknown $e.isLtsc    'the LTSC flag derived from an unread edition'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'edition: an unreadable CIM leaves domain membership $null, not "workgroup"' -Body {
  # Assuming "not domain joined" is the dangerous default: it is what lets the time repair
  # repoint a domain member at pool.ntp.org.
  $e = Get-FFEditionUnderTest -CimBehaviour 'denied'
  Assert-HonestUnknown $e.isDomainJoined 'domain membership when CIM could not be queried'
  Assert-HonestUnknown $e.sku 'the SKU when CIM could not be queried'
}

Register-FFTest -Area 'SKU' -Name 'edition: a Server installation is flagged isServer' -Body {
  $e = Get-FFEditionUnderTest -EditionId 'ServerStandard' -InstallationType 'Server'
  Assert-Eq $true $e.isServer 'InstallationType != Client means Server'
  $c = Get-FFEditionUnderTest -EditionId 'Professional' -InstallationType 'Client'
  Assert-Eq $false $c.isServer 'a Client installation is not Server'
}

# ---------------- image.ps1: BitLocker rails on an edition with no module ----------------

function Get-FFImageBitLocker {
  param([bool]$HaveCmdlet = $false, [string]$CimBehaviour = 'ok', [int]$ProtectionStatus = 0, [bool]$RecoveryProtector = $true)
  $ctx = @{ haveCmdlet = $HaveCmdlet; cim = $CimBehaviour; ps = $ProtectionStatus; rp = $RecoveryProtector }
  $r = Invoke-InEngineScope -Engine 'image' -Ctx $ctx -Mocks {
    function Get-Command { param($Name, $ErrorAction, $CommandType, $Module)
      if ("$Name" -eq 'Get-BitLockerVolume' -and $TestCtx.haveCmdlet) { return [pscustomobject]@{ Name = $Name } }
      $null }
    function Get-BitLockerVolume { param($MountPoint, $ErrorAction)
      [pscustomobject]@{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off'; KeyProtector = @() } }
    function Get-CimInstance { param($Namespace, $ClassName, $Filter, $ErrorAction)
      switch ($TestCtx.cim) {
        'denied'  { throw (New-FFCimException -Message 'Access is denied.' -NativeErrorCode 5) }
        'missing' { throw (New-FFCimException -Message 'Invalid namespace' -NativeErrorCode 'InvalidNamespace') }
        default   { return @([pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = $TestCtx.ps; ConversionStatus = 0 }) }
      } }
  } -Test { $TestCtx.res = Get-FFBitLockerStatus }
  $r.res
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'image rails: no BitLocker module + no provider = "unsupported", not "error"' -Body {
  # The old shape reported status 'error' with a raw CommandNotFoundException, or
  # 'needs-admin' - which sent Home users off to elevate for a problem elevation cannot fix,
  # and left the entire in-place repair path unreachable on Windows 11 Home.
  $r = Get-FFImageBitLocker -HaveCmdlet $false -CimBehaviour 'missing'
  Assert-In $r.status @('unsupported') 'an edition with no encryption provider at all reports unsupported'
  Assert-True (@($r.layers).Count -gt 0) 'every rung that failed is kept as evidence'
  Assert-Match 'Pro/Enterprise/Education' (@($r.layers) -join ' ') 'the reason the module is missing must be explained'
  Assert-NoMatch 'CommandNotFoundException' "$($r.note)" 'a raw exception must never become the rail note'
}

Register-FFTest -Area 'SKU' -Name 'image rails: Home reads encryption through Win32_EncryptableVolume' -Body {
  $r = Get-FFImageBitLocker -HaveCmdlet $false -CimBehaviour 'ok' -ProtectionStatus 0
  Assert-Eq 'checked' $r.status 'the WMI provider answering means the rail was measured'
  Assert-Eq 'cim-win32-encryptablevolume' $r.source 'and the source must name the rung that answered'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'image rails: a DENIED encryption query is not green' -Body {
  $r = Get-FFImageBitLocker -HaveCmdlet $false -CimBehaviour 'denied'
  Assert-Ne 'checked' $r.status 'a denied query has not measured anything'
  Assert-Ne 'unsupported' $r.status 'and it is not the same as "this edition has no provider"'
}
