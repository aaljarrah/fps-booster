<#
  LOCALE :: Fast Startup availability (health.ps1 Probe-Boot)

  powercfg has NO /English switch, and both the section headers and the feature label are
  MUI-localized, so the engine reads the STATE instead of the prose:

    Rung 1  CallNtPowerInformation(SystemPowerCapabilities) - structured, locale-free
    Rung 2  HKLM\SYSTEM\CurrentControlSet\Control\Power\HibernateEnabled, corroborated
            (positively only) by hiberfil.sys
    Rung 3  the documented English-only powercfg /a parse
    Rung 4  'unknown'

  These tests force each rung in turn. The bar is the same as everywhere: a localized
  machine that reaches rung 3 must end at 'unknown' with severity 'unknown', never at a
  confident 'available'/'unavailable' it did not measure.
#>

# Probe-Boot also reads the Diagnostics-Performance channel; it is stubbed below as an empty,
# READABLE log so the only thing under test here is the Fast Startup ladder.
function Get-FFFastStartup {
  param(
    [bool]$ApiAvailable = $false, [object]$SystemS4 = $null, [object]$HiberFile = $null,
    [object]$HibernateEnabled = $null, [object]$HiberbootEnabled = $null,
    [bool]$HiberfilPresent = $false, [string]$PowercfgText = ''
  )
  $ctx = @{
    apiAvailable = $ApiAvailable; systemS4 = $SystemS4; hiberFile = $HiberFile
    hibernateEnabled = $HibernateEnabled; hiberbootEnabled = $HiberbootEnabled
    hiberfilPresent = $HiberfilPresent; powercfgText = $PowercfgText
  }
  $r = Invoke-InEngineScope -Engine 'health' -Ctx $ctx -Mocks {
    $IsAdmin = $false
    function Get-FFEvents { param([hashtable]$Filter, [int]$MaxEvents = 0)
      $script:FFLastEventError = $null; $script:FFLastEventErrorKind = $null
      $script:FFLastEventUnreadable = $false; @() }
    function Get-FFPowerCapabilities {
      [ordered]@{ available = $TestCtx.apiAvailable; systemS4 = $TestCtx.systemS4
                  hiberFilePresent = $TestCtx.hiberFile; hiberboot = $null
                  ntStatus = '0x00000000'; error = $null } }
    function Get-ItemProperty { param($Path, $Name, $ErrorAction, $LiteralPath)
      $p = "$Path$LiteralPath"
      if ($p -match 'Control\\Power$') {
        if ($null -eq $TestCtx.hibernateEnabled) { throw 'value not found' }
        return [pscustomobject]@{ HibernateEnabled = $TestCtx.hibernateEnabled }
      }
      if ($p -match 'Session Manager\\Power$') {
        if ($null -eq $TestCtx.hiberbootEnabled) { throw 'value not found' }
        return [pscustomobject]@{ HiberbootEnabled = $TestCtx.hiberbootEnabled }
      }
      Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
      if ("$Path$LiteralPath" -match 'hiberfil\.sys$') { return $TestCtx.hiberfilPresent }
      Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
      $TestCtx.powercfgCalled = $true
      New-FFNativeResult -Text $TestCtx.powercfgText -ExitCode 0 }
  } -Test { $TestCtx.doc = Invoke-Category 'boot' }
  $f = @(@($r.doc.findings) | Where-Object { $_.id -eq 'fast-startup-state' }) | Select-Object -First 1
  [pscustomobject]@{ Doc = $r.doc; Finding = $f; Evidence = $f.evidence; PowercfgCalled = [bool]$r.powercfgCalled }
}

# ---------------- rung 1: the structured, locale-free answer ----------------

foreach ($row in @(
  @{ S4 = $true;  Hf = $true;  State = 'available';   Label = 'hibernation supported and the hiberfile exists' }
  @{ S4 = $false; Hf = $false; State = 'unavailable'; Label = 'hibernation not supported' }
  @{ S4 = $true;  Hf = $false; State = 'unavailable'; Label = 'S4 supported but no hiberfile' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "Fast Startup: power API decides ($($row.Label))" -Body {
    $d = $FFTestData
    $r = Get-FFFastStartup -ApiAvailable $true -SystemS4 $d.S4 -HiberFile $d.Hf -PowercfgText (Get-FFFixture -Path 'powercfg/ja-JP-full.txt')
    Assert-Eq $d.State $r.Evidence.state 'the structured API must decide the state'
    Assert-Eq 'callntpowerinformation' $r.Evidence.source 'the source must be the structured API'
    Assert-False $r.PowercfgCalled 'powercfg must NOT be run once the structured rung answered'
    Assert-Eq 'info' $r.Finding.severity 'a measured state is informational, not unknown'
  }
}

# ---------------- rung 2: the registry ----------------

foreach ($row in @(
  @{ Reg = 1; State = 'available' }
  @{ Reg = 0; State = 'unavailable' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "Fast Startup: registry rung decides when the API is unavailable (HibernateEnabled=$($row.Reg))" -Body {
    $d = $FFTestData
    $r = Get-FFFastStartup -ApiAvailable $false -HibernateEnabled $d.Reg -PowercfgText (Get-FFFixture -Path 'powercfg/de-DE-full.txt')
    Assert-Eq $d.State $r.Evidence.state 'HibernateEnabled must decide when the API cannot'
    Assert-Eq 'registry-hibernateenabled' $r.Evidence.source 'the source must name the registry rung'
    Assert-False $r.PowercfgCalled 'powercfg must not be consulted once the registry answered'
  }
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'Fast Startup: a present hiberfil.sys is positive corroboration only' -Body {
  # hiberfil.sys is SYSTEM-ACLed, so Test-Path returning $false proves nothing and must never
  # be read as "hibernation is off".
  $present = Get-FFFastStartup -ApiAvailable $false -HiberfilPresent $true -PowercfgText ''
  Assert-Eq 'available' $present.Evidence.state 'a visible hiberfil.sys corroborates availability'
  Assert-Eq 'hiberfil-present' $present.Evidence.source 'the source must name the corroborating rung'

  $absent = Get-FFFastStartup -ApiAvailable $false -HiberfilPresent $false -PowercfgText ''
  Assert-Eq 'unknown' $absent.Evidence.state 'an unreadable hiberfil.sys must NOT be read as "unavailable"'
  Assert-Eq 'unknown' $absent.Finding.severity 'and the finding must carry unknown severity'
}

# ---------------- rung 3: the documented English-only powercfg parse ----------------

Register-FFTest -Area 'LOCALE' -Name 'Fast Startup: English powercfg /a is read when every structured rung failed' -Body {
  $r = Get-FFFastStartup -ApiAvailable $false -PowercfgText (Get-FFFixture -Path 'powercfg/en-US-full.txt')
  Assert-True $r.PowercfgCalled 'powercfg is the last rung and must be reached'
  Assert-Eq 'available' $r.Evidence.state 'Fast Startup listed under the available header means available'
  Assert-Eq 'powercfg-english' $r.Evidence.source 'the source must declare the English text parse'
}

Register-FFTest -Area 'LOCALE' -Name 'Fast Startup: English powercfg /a with hibernation off reads as unavailable' -Body {
  $r = Get-FFFastStartup -ApiAvailable $false -PowercfgText (Get-FFFixture -Path 'powercfg/en-US-hibernation-off.txt')
  Assert-Eq 'unavailable' $r.Evidence.state 'Fast Startup listed only under the NOT-available header means unavailable'
  Assert-Eq 'powercfg-english' $r.Evidence.source 'the source must declare the English text parse'
}

# WAS -Xfail, NOW A REAL EXPECTATION. The defect it reproduces (health.ps1 Probe-Boot): the
# English powercfg parse anchored on "available on this system:", which ALSO matches the header
# "The following sleep states are NOT available on this system:". On a machine where no sleep
# state is available at all (common on Hyper-V Gen2 and many cloud VMs) that header is the FIRST
# match, so the captured section is the UNAVAILABLE list - and finding "Fast Startup" inside it
# reported fastStartup=available on a machine where it is disabled. That is an inverted verdict
# read off a mis-anchored regex: doctrine 2's worst case, and no longer a forgiven one.
Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' `
  -Name 'Fast Startup: powercfg /a listing NO available states must not read as available' -Body {
  $r = Get-FFFastStartup -ApiAvailable $false -PowercfgText (Get-FFFixture -Path 'powercfg/en-US-none-available.txt')
  Assert-True $r.PowercfgCalled 'the English rung must be reached'
  Assert-Ne 'available' $r.Evidence.state 'Fast Startup appears ONLY under the "not available" header, so it is not available'
  Assert-In $r.Evidence.state @('unavailable', 'unknown') 'the only honest answers are unavailable or unknown'
  Assert-NoMatch 'Fast Startup is available' $r.Finding.detail 'the sentence shown to the user must not claim availability'
}

foreach ($row in @(
  @{ Lang = 'de-DE'; File = 'powercfg/de-DE-full.txt' }
  @{ Lang = 'de-DE'; File = 'powercfg/de-DE-hibernation-off.txt' }
  @{ Lang = 'ja-JP'; File = 'powercfg/ja-JP-full.txt' }
  @{ Lang = 'ja-JP'; File = 'powercfg/ja-JP-hibernation-off.txt' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "Fast Startup: $($row.Lang) powercfg = unknown, never a guess ($(Split-Path -Leaf $row.File))" -Body {
    $d = $FFTestData
    $r = Get-FFFastStartup -ApiAvailable $false -PowercfgText (Get-FFFixture -Path $d.File)
    Assert-True $r.PowercfgCalled 'the last rung must at least be attempted'
    Assert-Eq 'unknown' $r.Evidence.state "a $($d.Lang) powercfg /a must leave the state unknown"
    Assert-Eq 'none' $r.Evidence.source 'no rung may claim to have decided'
    Assert-Eq 'unknown' $r.Finding.severity "the finding severity must be 'unknown'"
    Assert-NotGraded-Ok $r.Doc.status 'the boot category when Fast Startup could not be read'
    Assert-Match 'could not be determined' $r.Finding.detail 'the wording must say it could not be determined'
  }
}

Register-FFTest -Area 'LOCALE' -Name 'Fast Startup: the on/off toggle is reported separately from availability' -Body {
  $on  = Get-FFFastStartup -ApiAvailable $true -SystemS4 $true -HiberFile $true -HiberbootEnabled 1
  $off = Get-FFFastStartup -ApiAvailable $true -SystemS4 $true -HiberFile $true -HiberbootEnabled 0
  $unk = Get-FFFastStartup -ApiAvailable $true -SystemS4 $true -HiberFile $true -HiberbootEnabled $null
  Assert-Match 'available and enabled'   $on.Finding.detail  'available + HiberbootEnabled=1 reads as enabled'
  Assert-Match 'available but turned off' $off.Finding.detail 'available + HiberbootEnabled=0 reads as turned off'
  Assert-Match 'on/off setting could not be read' $unk.Finding.detail 'an unreadable toggle is stated, not assumed'
  Assert-Eq 'available' $unk.Evidence.state 'an unreadable toggle does not change the availability verdict'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'boot: an unreadable Diagnostics-Performance channel is never graded healthy' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $false
    function Get-FFEvents { param([hashtable]$Filter, [int]$MaxEvents = 0)
      $script:FFLastEventError = 'Attempted to perform an unauthorized operation.'
      $script:FFLastEventErrorKind = 'access-denied'
      $script:FFLastEventUnreadable = $true
      @() }
  } -Test { $TestCtx.doc = Invoke-Category 'boot' }
  $f = @(@($r.doc.findings) | Where-Object { $_.id -eq 'boot-log-unreadable' }) | Select-Object -First 1
  Assert-Stop ($null -ne $f) 'an unreadable boot log must be reported as its own finding'
  Assert-Eq 'unknown' $f.severity 'a channel that could not be read is unknown'
  Assert-NotGraded-Ok $r.doc.status 'the boot category when its only source was denied'
  Assert-NoMatch 'Boot times look normal' $r.doc.summary 'the summary must not claim normal boot times it never measured'
  Assert-Match 'could not be measured' $r.doc.summary 'the summary must say the measurement did not happen'
}

Register-FFTest -Area 'STATE' -Name 'boot: an empty but READABLE channel says "nothing recorded", not "unreadable"' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $true
    function Get-FFEvents { param([hashtable]$Filter, [int]$MaxEvents = 0)
      $script:FFLastEventError = $null; $script:FFLastEventErrorKind = $null
      $script:FFLastEventUnreadable = $false; @() }
    function Get-FFPowerCapabilities { [ordered]@{ available = $true; systemS4 = $true; hiberFilePresent = $true; hiberboot = $true; ntStatus = '0x00000000'; error = $null } }
  } -Test { $TestCtx.doc = Invoke-Category 'boot' }
  $f = @(@($r.doc.findings) | Where-Object { $_.id -eq 'boot-no-events' }) | Select-Object -First 1
  Assert-Stop ($null -ne $f) 'an empty readable channel is its own, different finding'
  Assert-Eq 'info' $f.severity 'nothing recorded is informational'
  Assert-Match 'could not be assessed' $r.doc.summary 'the summary still must not claim boot times are fine'
}
