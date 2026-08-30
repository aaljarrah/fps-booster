<#
  LOCALE :: sfc verification (health.ps1 Probe-SystemFiles, -Deep, elevated)

  Three rungs, in order:
    1. the [SR] tail of %SystemRoot%\Logs\CBS\CBS.log, time-filtered to THIS run
       (invariant English on every UI language - so it is the verdict)
    2. sfc.exe's own console text, DOCUMENTED English-only
    3. honest 'unknown'

  The bar:
    - a localized machine WITH a usable CBS log must still reach the right verdict
    - a localized machine WITHOUT one must reach severity 'unknown' and a category status
      of 'unknown' - never 'ok', and never a warning it did not measure
    - [SR] lines left over from a PREVIOUS scan must never grade today's run

  These run entirely on stubs: sfc.exe is never executed and CBS.log is never read.
#>

# Shared mock block: an elevated, -Deep Probe-SystemFiles whose sfc output and CBS log are
# whatever $TestCtx says they are.
$FFSfcMocks = {
  $IsAdmin = $true
  $Deep = $true
  function Repair-WindowsImage { param([switch]$Online, [switch]$CheckHealth, [switch]$ScanHealth, $ErrorAction)
    [pscustomobject]@{ ImageHealthState = 'Healthy' } }
  function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
    $p = "$Path$LiteralPath"
    if ($p -match 'RebootPending') { return $false }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
  function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
    $TestCtx.sfcArgs = @($Arguments)
    New-FFNativeResult -Text $TestCtx.sfcText -ExitCode $TestCtx.sfcExit }
  function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
    $p = "$Path$LiteralPath"
    if ($p -match 'CBS\.log$') {
      if ($TestCtx.cbsThrow) { throw (New-Object System.UnauthorizedAccessException($TestCtx.cbsThrow)) }
      return @($TestCtx.cbsLines)
    }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
}

function Get-FFSfcResult {
  <# Runs Probe-SystemFiles through Invoke-Category (so the category STATUS is exercised, not
     just the findings) and returns the category document. #>
  param([string]$SfcText = '', [int]$SfcExit = 0, $CbsLines = @(), [string]$CbsThrow = $null)
  $ctx = @{ sfcText = $SfcText; sfcExit = $SfcExit; cbsLines = @($CbsLines); cbsThrow = $CbsThrow }
  $r = Invoke-InEngineScope -Engine 'health' -Ctx $ctx -Mocks $FFSfcMocks -Test {
    $TestCtx.doc = Invoke-Category 'system-files'
  }
  $r.doc
}

function Get-FFFinding {
  param($Doc, [string]$IdPattern)
  @(@($Doc.findings) | Where-Object { "$($_.id)" -match $IdPattern }) | Select-Object -First 1
}

# ---------------- rung 1: the CBS [SR] log decides, whatever the console language ----------------

foreach ($row in @(
  @{ Lang = 'en-US'; Console = 'sfc/en-US-clean.txt';      Cbs = 'cbs/sr-clean.log';     Id = 'sfc-verify-clean';      Sev = 'info' }
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-clean.txt';      Cbs = 'cbs/sr-clean.log';     Id = 'sfc-verify-clean';      Sev = 'info' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-clean.txt';      Cbs = 'cbs/sr-clean.log';     Id = 'sfc-verify-clean';      Sev = 'info' }
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-unfixable.txt';  Cbs = 'cbs/sr-unfixable.log'; Id = 'sfc-verify-violations'; Sev = 'warning' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-unfixable.txt';  Cbs = 'cbs/sr-unfixable.log'; Id = 'sfc-verify-violations'; Sev = 'warning' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-repaired.txt';   Cbs = 'cbs/sr-repaired.log';  Id = 'sfc-verify-violations'; Sev = 'warning' }
  @{ Lang = 'fr-FR'; Console = 'sfc/fr-FR-clean.txt';      Cbs = 'cbs/sr-clean.log';     Id = 'sfc-verify-clean';      Sev = 'info' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "sfc: CBS [SR] log decides on $($row.Lang) ($(Split-Path -Leaf $row.Cbs))" -Body {
    $d = $FFTestData
    $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path $d.Console) -CbsLines (Get-FFFixtureLines -Path $d.Cbs)
    $f = Get-FFFinding $doc '^sfc-verify-'
    Assert-Stop ($null -ne $f) "a $($d.Lang) run with a readable CBS log must produce an sfc-verify-* finding"
    Assert-Eq $d.Id  $f.id       "the CBS [SR] markers must decide the verdict on $($d.Lang)"
    Assert-Eq $d.Sev $f.severity 'the severity must match the verdict'
    Assert-Eq 'cbs-log-sr-lines' $f.evidence.verdictSource 'the verdict must declare it came from the locale-independent CBS log'
  }
}

# ---------------- rung 2: the documented English console parse ----------------

foreach ($row in @(
  @{ Console = 'sfc/en-US-clean.txt';      Id = 'sfc-verify-clean';      Sev = 'info' }
  @{ Console = 'sfc/en-US-violations.txt'; Id = 'sfc-verify-violations'; Sev = 'warning' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "sfc: English console fallback when CBS is unreadable ($(Split-Path -Leaf $row.Console))" -Body {
    $d = $FFTestData
    $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path $d.Console) -CbsThrow 'Access to the path is denied.'
    $f = Get-FFFinding $doc '^sfc-verify-'
    Assert-Stop ($null -ne $f) 'an English run must still reach a verdict without CBS.log'
    Assert-Eq $d.Id $f.id 'the English console text must be read correctly'
    Assert-Eq $d.Sev $f.severity 'the severity must match the verdict'
    Assert-Eq 'sfc-console-english' $f.evidence.verdictSource 'the verdict must declare it came from the English console parse'
    Assert-NotNull $f.evidence.cbsReadError 'the reason CBS.log could not be used must be kept as evidence'
  }
}

# ---------------- rung 3: honest unknown ----------------

foreach ($row in @(
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-clean.txt' }
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-unfixable.txt' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-clean.txt' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-violations.txt' }
  @{ Lang = 'fr-FR'; Console = 'sfc/fr-FR-clean.txt' }
  @{ Lang = 'none';  Console = 'sfc/empty.txt' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "sfc: $($row.Lang) console + unreadable CBS = unknown, NEVER ok ($(Split-Path -Leaf $row.Console))" -Body {
    $d = $FFTestData
    $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path $d.Console) -CbsThrow 'Access to the path is denied.'
    $f = Get-FFFinding $doc '^sfc-verify-'
    Assert-Stop ($null -ne $f) 'the probe must emit a finding rather than fall silent'
    Assert-Eq 'sfc-verify-indeterminate' $f.id "a $($d.Lang) machine with no usable CBS log must report indeterminate"
    Assert-Eq 'unknown' $f.severity "severity must be 'unknown' - a hole in the measurement, not a fault and not an all-clear"
    Assert-Eq 'none' $f.evidence.verdictSource 'no rung may claim to have decided'
    Assert-NotGraded-Ok $doc.status 'the system-files category on a localized machine with no CBS log'
    Assert-Eq 'unknown' $doc.status 'the category status must be exactly unknown'
    Assert-Match 'UNKNOWN, not clean' $f.detail 'the wording must say out loud that integrity is unknown'
    Assert-Match 'NOT a clean bill of health' $doc.summary "the summary must carry the honest 'could not read' clause"
  }
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'sfc: a CBS log with NO [SR] lines for this run is indeterminate, not clean' -Body {
  $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path 'sfc/de-DE-clean.txt') -CbsLines (Get-FFFixtureLines -Path 'cbs/no-sr-lines.log')
  $f = Get-FFFinding $doc '^sfc-verify-'
  Assert-Eq 'sfc-verify-indeterminate' $f.id 'a CBS log with no [SR] entries proves nothing'
  Assert-Eq 'unknown' $f.severity 'the severity must be unknown'
  Assert-NotGraded-Ok $doc.status 'the category with no [SR] evidence at all'
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'sfc: CBS [SR] markers this parse does not understand are indeterminate' -Body {
  $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path 'sfc/ja-JP-clean.txt') -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-unknown-markers.log')
  $f = Get-FFFinding $doc '^sfc-verify-'
  Assert-Eq 'sfc-verify-indeterminate' $f.id 'unrecognized [SR] text must not be graded'
  Assert-Eq 'unknown' $f.severity 'the severity must be unknown'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'sfc: [SR] lines from a PREVIOUS scan never grade this run' -Body {
  # The most dangerous version of this bug: yesterday's "Verify complete" grading today's
  # scan as clean on a machine that is actually corrupt.
  $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path 'sfc/de-DE-clean.txt') -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-clean.log' -AgeMinutes 1440)
  $f = Get-FFFinding $doc '^sfc-verify-'
  Assert-Eq 'sfc-verify-indeterminate' $f.id 'a day-old [SR] block must not be attributed to this run'
  Assert-Eq 0 $f.evidence.srLinesThisRun 'no [SR] lines may be counted for this run'
  Assert-True (@($f.evidence.srTailAny).Count -gt 0) 'the stale lines are still kept as evidence'
  Assert-NotGraded-Ok $doc.status 'a category graded only from stale log lines'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'sfc: undated [SR] lines are reported as unattributable, with the reason' -Body {
  $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path 'sfc/ja-JP-clean.txt') -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-no-timestamp.log')
  $f = Get-FFFinding $doc '^sfc-verify-'
  Assert-Eq 'sfc-verify-indeterminate' $f.id 'lines with no parseable timestamp cannot grade a run'
  Assert-Match 'no parseable timestamp' $f.detail 'the reason must be named rather than left as a generic failure'
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'sfc: a cannot-repair [SR] line outranks a cheerful console string' -Body {
  # English console says "successfully repaired"; the servicing log says it could not repair a
  # member file. The log has to win, or the run reports success on a broken machine.
  $doc = Get-FFSfcResult -SfcText (Get-FFFixture -Path 'sfc/en-US-repaired.txt') -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-unfixable.log')
  $f = Get-FFFinding $doc '^sfc-verify-'
  Assert-Eq 'sfc-verify-violations' $f.id 'the CBS cannot-repair evidence must produce a violations finding'
  Assert-Eq 'warning' $f.severity 'it must be a warning, not info'
  Assert-Eq 'cbs-log-sr-lines' $f.evidence.verdictSource 'the log, not the console text, must be named as the source'
  Assert-Match 'could not repair' $f.detail 'the wording must say the repair did not complete'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'sfc: an sfc.exe that could not run at all is unknown, not clean' -Body {
  $ctx = @{ sfcText = ''; sfcExit = $null; cbsLines = @(); cbsThrow = $null }
  $r = Invoke-InEngineScope -Engine 'health' -Ctx $ctx -Mocks {
    $IsAdmin = $true
    $Deep = $true
    function Repair-WindowsImage { param([switch]$Online, [switch]$CheckHealth, [switch]$ScanHealth, $ErrorAction)
      [pscustomobject]@{ ImageHealthState = 'Healthy' } }
    function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
      if ("$Path$LiteralPath" -match 'RebootPending') { return $false }
      Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
      throw 'The system cannot find the file specified.' }
    function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
      if ("$Path$LiteralPath" -match 'CBS\.log$') { throw 'denied' }
      Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
  } -Test { $TestCtx.doc = Invoke-Category 'system-files' }
  $f = Get-FFFinding $r.doc 'sfc-verify-failed'
  Assert-Stop ($null -ne $f) 'a failure to launch sfc must be reported'
  Assert-Eq 'unknown' $f.severity 'a probe that could not run is unknown'
  Assert-NotGraded-Ok $r.doc.status 'the category when sfc could not be executed'
}

Register-FFTest -Area 'STATE' -Name 'sfc: the deep scan is skipped (not faked) when unelevated' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{ nativeCalls = 0 } -Mocks {
    $IsAdmin = $false
    $Deep = $true
    function Invoke-FFNative { param($FilePath, $Arguments, $Encoding, $TimeoutMs)
      $TestCtx.nativeCalls++; New-FFNativeResult -Text '' }
    function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
      if ("$Path$LiteralPath" -match 'RebootPending') { return $false }
      Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
  } -Test { $TestCtx.doc = Invoke-Category 'system-files' }
  Assert-Eq 0 $r.nativeCalls 'sfc.exe must not be launched without administrator rights'
  Assert-Eq 'needs-admin' $r.doc.status 'the category must say it needs elevation'
  Assert-NotGraded-Ok $r.doc.status 'an unelevated system-files probe'
  Assert-Match 'administrator rights' $r.doc.summary 'the summary must say what is missing'
}
