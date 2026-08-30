<#
  LOCALE :: DISM component-store analysis (health.ps1 Probe-DiskSpace, -Deep, elevated)

  The engine passes DISM's GLOBAL /English switch precisely so the
  'Component Store Cleanup Recommended : Yes|No' label is emitted in English whatever the
  system language is. Two things must hold:

    1. /English is actually passed (without it this whole block is dead code on roughly
       70% of Windows installs, and the component-cleanup repairs never become available)
    2. if the label is missing or carries a value the parse does not recognise - which is
       what happens if /English is ever ignored, or DISM fails outright - the outcome is
       'unknown', never "no cleanup needed"

  Volume enumeration is stubbed to one healthy fixed volume, so the only thing that can move
  the category status is the component-store finding.
#>

$FFDismMocks = {
  $IsAdmin = $true
  $Deep = $true
  function Get-Volume { param($ErrorAction)
    [pscustomobject]@{ DriveType = 'Fixed'; Size = 1000GB; SizeRemaining = 500GB; DriveLetter = 'C'
                       Path = '\\?\Volume{11111111-1111-1111-1111-111111111111}\'; FileSystemType = 'NTFS' } }
  function Get-Partition { param($ErrorAction, $DriveLetter)
    [pscustomobject]@{ AccessPaths = @('C:\') } }
  function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
    $TestCtx.dismFile = "$FilePath"
    $TestCtx.dismArgs = @($Arguments)
    if ($TestCtx.dismThrow) { throw $TestCtx.dismThrow }
    New-FFNativeResult -Text $TestCtx.dismText -ExitCode $TestCtx.dismExit }
}

function Get-FFDiskSpaceResult {
  param([string]$DismText = '', [int]$DismExit = 0, [string]$DismThrow = $null, [bool]$Admin = $true)
  $ctx = @{ dismText = $DismText; dismExit = $DismExit; dismThrow = $DismThrow; admin = $Admin }
  $r = Invoke-InEngineScope -Engine 'health' -Ctx $ctx -Mocks $FFDismMocks -Test {
    $IsAdmin = $TestCtx.admin
    $TestCtx.doc = Invoke-Category 'disk-space'
  }
  $r
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'DISM: the global /English switch is actually passed' -Body {
  # Without it the label is localized and the parse below can never match, which silently
  # removes component-cleanup from the repair ladder on every non-English machine.
  $r = Get-FFDiskSpaceResult -DismText (Get-FFFixture -Path 'dism/analyze-en-US-yes.txt')
  Assert-Match 'Dism\.exe$' $r.dismFile 'the probe must call Dism.exe'
  Assert-True (@($r.dismArgs) -contains '/English') 'DISM must be invoked with the global /English switch'
  Assert-True (@($r.dismArgs) -contains '/AnalyzeComponentStore') 'the read-only analyze verb must be used'
  Assert-False (@($r.dismArgs) -contains '/StartComponentCleanup') 'the read-only probe must never pass a cleanup verb'
  Assert-False (@($r.dismArgs) -contains '/ResetBase') 'the read-only probe must never pass /ResetBase'
}

foreach ($row in @(
  @{ File = 'dism/analyze-en-US-yes.txt'; Id = 'component-store-cleanup-recommended'; Sev = 'warning'; Rec = 'Yes' }
  @{ File = 'dism/analyze-en-US-no.txt';  Id = 'component-store-cleanup-not-needed';  Sev = 'info';    Rec = 'No' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "DISM: English label read correctly ($(Split-Path -Leaf $row.File))" -Body {
    $d = $FFTestData
    $r = Get-FFDiskSpaceResult -DismText (Get-FFFixture -Path $d.File)
    $f = @(@($r.doc.findings) | Where-Object { $_.id -like 'component-store-*' }) | Select-Object -First 1
    Assert-Stop ($null -ne $f) 'a component-store finding must be produced'
    Assert-Eq $d.Id  $f.id 'the recommendation must be read from the English label'
    Assert-Eq $d.Sev $f.severity 'the severity must match the recommendation'
    Assert-Eq $d.Rec $f.evidence.cleanupRecommended 'the raw value must be kept as evidence'
    Assert-True $f.evidence.english 'the evidence must record that /English was in force'
  }
}

foreach ($row in @(
  @{ Lang = 'de-DE'; File = 'dism/analyze-de-DE-yes.txt' }
  @{ Lang = 'ja-JP'; File = 'dism/analyze-ja-JP-yes.txt' }
  @{ Lang = 'error'; File = 'dism/analyze-error-1726.txt' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "DISM: $($row.Lang) output with no English label = unknown, never 'no cleanup needed'" -Body {
    $d = $FFTestData
    $r = Get-FFDiskSpaceResult -DismText (Get-FFFixture -Path $d.File) -DismExit 1726
    $f = @(@($r.doc.findings) | Where-Object { $_.id -like 'component-store-*' }) | Select-Object -First 1
    Assert-Stop ($null -ne $f) 'the probe must emit a finding rather than fall silent'
    Assert-Eq 'component-store-analyze-indeterminate' $f.id 'an unmatched label must report indeterminate'
    Assert-Eq 'unknown' $f.severity "the severity must be 'unknown', which ranks above 'ok'"
    Assert-NotIn $f.id @('component-store-cleanup-not-needed') 'it must NEVER claim no cleanup is needed'
    Assert-NotGraded-Ok $r.doc.status 'the disk-space category when DISM could not be read'
    Assert-Match 'UNKNOWN rather than absent' $f.detail 'the wording must distinguish unknown from absent'
    Assert-NotNull $f.evidence.outputTail 'the unparsed output tail must be kept as evidence'
  }
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'DISM: an unrecognised recommendation value is unknown, not a default' -Body {
  # The parse uses an exact -eq against Yes/No on purpose: anything else must fall through to
  # unknown instead of being silently rendered as "no cleanup needed".
  $r = Get-FFDiskSpaceResult -DismText (Get-FFFixture -Path 'dism/analyze-en-US-unrecognised.txt')
  $f = @(@($r.doc.findings) | Where-Object { $_.id -like 'component-store-*' }) | Select-Object -First 1
  Assert-Eq 'component-store-analyze-indeterminate' $f.id 'an unknown value must not be graded'
  Assert-Eq 'unknown' $f.severity 'the severity must be unknown'
  Assert-Eq 'Unbekannt' $f.evidence.cleanupRecommended 'the value that could not be understood is reported verbatim'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'DISM: a launch failure is unknown, not "no bloat"' -Body {
  $r = Get-FFDiskSpaceResult -DismThrow 'The system cannot find the file specified.'
  $f = @(@($r.doc.findings) | Where-Object { $_.id -like 'component-store-*' }) | Select-Object -First 1
  Assert-Eq 'component-store-analyze-failed' $f.id 'a failure to run DISM is its own finding'
  Assert-Eq 'unknown' $f.severity 'the severity must be unknown'
  Assert-NotGraded-Ok $r.doc.status 'the disk-space category when DISM could not be launched'
}

Register-FFTest -Area 'STATE' -Name 'DISM: the deep analysis is skipped (not faked) when unelevated' -Body {
  $r = Get-FFDiskSpaceResult -DismText (Get-FFFixture -Path 'dism/analyze-en-US-yes.txt') -Admin $false
  Assert-Null $r.dismArgs 'DISM must not be launched without administrator rights'
  Assert-Eq 'needs-admin' $r.doc.status 'the category must say it needs elevation rather than reporting ok'
  Assert-Eq 0 @(@($r.doc.findings) | Where-Object { $_.id -like 'component-store-*' }).Count 'no component-store claim may be made'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'disk space: a failed volume enumeration is unknown, not "all volumes healthy"' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $false
    $Deep = $false
    function Get-Volume { param($ErrorAction) throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
  } -Test { $TestCtx.doc = Invoke-Category 'disk-space' }
  $f = @(@($r.doc.findings) | Where-Object { $_.id -eq 'volume-query-failed' }) | Select-Object -First 1
  Assert-Stop ($null -ne $f) 'a failed volume query must be reported'
  Assert-Eq 'unknown' $f.severity 'the severity must be unknown'
  Assert-Eq 'unknown' $r.doc.status 'the category status must be unknown'
  Assert-NoMatch 'healthy free space' $r.doc.summary 'the summary must not claim healthy free space it never measured'
}

Register-FFTest -Area 'STATE' -Name 'disk space: a volume with no mount point is inventoried but not graded' -Body {
  # The hidden WinRE/recovery partition is MEANT to be nearly full; grading it would
  # manufacture a critical finding out of a correct configuration.
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $false
    $Deep = $false
    function Get-Volume { param($ErrorAction)
      @(
        [pscustomobject]@{ DriveType='Fixed'; Size=1000GB; SizeRemaining=500GB; DriveLetter='C'; Path='\\?\Volume{aaaa}\'; FileSystemType='NTFS' }
        [pscustomobject]@{ DriveType='Fixed'; Size=900MB;  SizeRemaining=30MB;  DriveLetter=$null; Path='\\?\Volume{bbbb}\'; FileSystemType='NTFS' }
      ) }
    function Get-Partition { param($ErrorAction, $DriveLetter) throw 'no partition' }
  } -Test { $TestCtx.doc = Invoke-Category 'disk-space' }
  $inv = @(@($r.doc.findings) | Where-Object { $_.id -eq 'volume-inventory' }) | Select-Object -First 1
  Assert-Stop ($null -ne $inv) 'the per-volume inventory must always be attached'
  Assert-Eq 2 @($inv.evidence.volumes).Count 'both volumes must be inventoried'
  $hidden = @(@($inv.evidence.volumes) | Where-Object { -not $_.graded }) | Select-Object -First 1
  Assert-Stop ($null -ne $hidden) 'the mount-point-less volume must be marked ungraded'
  Assert-NotNull $hidden.notGradedReason 'and it must say WHY it was not graded'
  Assert-Eq 0 @(@($r.doc.findings) | Where-Object { $_.id -like 'space-critical-*' }).Count 'the recovery partition must not raise a critical space finding'
  Assert-Match 'not graded' $r.doc.summary 'the summary must bound its claim to the volumes it actually graded'
}
