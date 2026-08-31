<#
  LOCALE :: the sfc /scannow REPAIR step (repair.ps1 Get-SfcCbsOutcome + Get-SfcStep)

  sfc.exe exits 0 whether it repaired everything, repaired nothing, or found files it could
  NOT repair - so the exit code alone can never be the verdict, and the console text is
  MUI-localized. The step's ladder is:

    0. exit code       (non-zero = a hard failure, whatever any text says)
    1. sfc's console text, DOCUMENTED English-only
    2. the CBS.log [SR] markers, which the component store writes in English on every UI
    3. honest 'indeterminate' - and Invoke-RepairRun treats indeterminate exactly like
       'unfixable', because a result nobody read is not a completed repair

  sfc.exe IS NEVER EXECUTED HERE. Join-Path is shadowed inside the engine scope so the
  step's `& (Join-Path $env:SystemRoot 'System32\sfc.exe') /scannow` resolves to a
  throwaway .ps1 in %TEMP% that prints a fixture and exits with a chosen code.
#>

function New-FFFakeSfc {
  <# A stand-in for sfc.exe: emits the given text line by line (the way a redirected native
     command's output reaches PowerShell) and exits with the given code. #>
  param([string]$Text, [int]$ExitCode = 0)
  $p = Join-Path $script:FFWorkDir ('fake-sfc-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
  $body = @"
param([Parameter(ValueFromRemainingArguments = `$true)]`$Rest)
`$t = @'
$Text
'@
foreach (`$line in (`$t -split "``r?``n")) { Write-Output `$line }
exit $ExitCode
"@
  [System.IO.File]::WriteAllText($p, $body, (New-Object System.Text.UTF8Encoding($true)))
  $p
}

function Invoke-FFSfcStep {
  # -EngineDir runs the step out of a SANDBOXED copy of repair.ps1 instead of the real one.
  # cases\65-sabotage.ps1 uses it to point the very same assertions at an engine with a guard
  # deliberately removed, and check that they fail.
  param([string]$ConsoleFixture, [int]$ExitCode = 0, $CbsLines = @(), [string]$CbsThrow = $null, [string]$EngineDir = '')
  $fake = New-FFFakeSfc -Text (Get-FFFixture -Path $ConsoleFixture) -ExitCode $ExitCode
  $ctx = @{ fakeSfc = $fake; cbsLines = @($CbsLines); cbsThrow = $CbsThrow }
  $r = Invoke-InEngineScope -Engine 'repair' -EngineDir $EngineDir -Ctx $ctx -Mocks {
    function Join-Path { param($Path, $ChildPath, $Resolve, $ErrorAction)
      if ("$ChildPath" -match 'sfc\.exe$') { return $TestCtx.fakeSfc }
      Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath }
    function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
      if ("$Path$LiteralPath" -match 'CBS\.log$') {
        if ($TestCtx.cbsThrow) { throw (New-Object System.UnauthorizedAccessException($TestCtx.cbsThrow)) }
        return @($TestCtx.cbsLines)
      }
      Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
  } -Test {
    $repair = Get-RepairById 'sfc-scannow'
    $c = New-RepairContext $repair
    $step = Get-SfcStep
    $TestCtx.threw = $null
    try { $TestCtx.message = & $step.exec $c } catch { $TestCtx.threw = "$($_.Exception.Message)" }
    $TestCtx.outcome = $c.sfcOutcome
    $TestCtx.mutation = @($c.mutations)[0]
    $TestCtx.commands = @($step.commands)
  }
  $r
}

# ---------------- Get-SfcCbsOutcome, the locale-independent decision ----------------

foreach ($row in @(
  @{ Log = 'cbs/sr-clean.log';     Outcome = 'clean' }
  @{ Log = 'cbs/sr-repaired.log';  Outcome = 'repaired' }
  @{ Log = 'cbs/sr-unfixable.log'; Outcome = 'unfixable' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "sfc repair: CBS [SR] markers decide ($(Split-Path -Leaf $row.Log))" -Body {
    $d = $FFTestData
    $r = Invoke-InEngineScope -Engine 'repair' -Ctx @{ lines = (Get-FFFixtureLines -Path $d.Log) } -Mocks {
      function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
        if ("$Path$LiteralPath" -match 'CBS\.log$') { return @($TestCtx.lines) }
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
    } -Test { $TestCtx.res = Get-SfcCbsOutcome }
    Assert-Eq $d.Outcome $r.res.outcome 'the [SR] markers must decide the outcome'
    Assert-True $r.res.readable 'the log must be reported readable'
    Assert-True (@($r.res.evidence).Count -gt 0) 'the deciding lines must be kept as evidence'
  }
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'sfc repair: an unreadable or markerless CBS log returns $null, never "clean"' -Body {
  foreach ($case in @(
    @{ Lines = @(); Throw = 'Access to the path is denied.'; Why = 'unreadable' }
    @{ Lines = (Get-FFFixtureLines -Path 'cbs/no-sr-lines.log'); Throw = $null; Why = 'no [SR] lines at all' }
    @{ Lines = (Get-FFFixtureLines -Path 'cbs/sr-unknown-markers.log'); Throw = $null; Why = 'markers this parse does not understand' }
  )) {
    $r = Invoke-InEngineScope -Engine 'repair' -Ctx @{ lines = @($case.Lines); throwWith = $case.Throw } -Mocks {
      function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
        if ("$Path$LiteralPath" -match 'CBS\.log$') {
          if ($TestCtx.throwWith) { throw (New-Object System.UnauthorizedAccessException($TestCtx.throwWith)) }
          return @($TestCtx.lines)
        }
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
    } -Test { $TestCtx.res = Get-SfcCbsOutcome }
    Assert-HonestUnknown $r.res.outcome "a CBS log that is $($case.Why)"
    Assert-NotNull $r.res.error "and it must say WHY it could not decide ($($case.Why))"
  }
}

# ---------------- the full step: rung order and the unfixable override ----------------

foreach ($row in @(
  @{ Lang = 'en-US'; Console = 'sfc/en-US-clean.txt';     Outcome = 'clean';     By = 'sfc-console-text-english' }
  @{ Lang = 'en-US'; Console = 'sfc/en-US-repaired.txt';  Outcome = 'repaired';  By = 'sfc-console-text-english' }
  @{ Lang = 'en-US'; Console = 'sfc/en-US-unfixable.txt'; Outcome = 'unfixable'; By = 'sfc-console-text-english' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "sfc repair: English console decides ($(Split-Path -Leaf $row.Console))" -Body {
    $d = $FFTestData
    $r = Invoke-FFSfcStep -ConsoleFixture $d.Console -CbsThrow 'denied'
    Assert-Null $r.threw 'exit code 0 must not raise'
    Assert-Eq $d.Outcome $r.outcome 'the English console text must decide'
    Assert-Eq $d.By $r.mutation.decidedBy 'the ledger mutation must record WHICH rung decided'
    Assert-Eq 0 $r.mutation.exitCode 'the exit code is recorded'
  }
}

foreach ($row in @(
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-clean.txt';     Log = 'cbs/sr-clean.log';     Outcome = 'clean' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-repaired.txt';  Log = 'cbs/sr-repaired.log';  Outcome = 'repaired' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-unfixable.txt'; Log = 'cbs/sr-unfixable.log'; Outcome = 'unfixable' }
  @{ Lang = 'fr-FR'; Console = 'sfc/fr-FR-clean.txt';     Log = 'cbs/sr-clean.log';     Outcome = 'clean' }
)) {
  Register-FFTest -Area 'LOCALE' -Data $row -Name "sfc repair: $($row.Lang) console falls through to the CBS log ($(Split-Path -Leaf $row.Log))" -Body {
    $d = $FFTestData
    $r = Invoke-FFSfcStep -ConsoleFixture $d.Console -CbsLines (Get-FFFixtureLines -Path $d.Log)
    Assert-Eq $d.Outcome $r.outcome "the CBS log must decide on $($d.Lang)"
    Assert-Match 'cbs-log-sr-markers' $r.mutation.decidedBy 'the ledger must record that the CBS log decided'
    Assert-True $r.mutation.cbsLogReadable 'and that the log was readable'
  }
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'sfc repair: a cannot-repair [SR] line OVERRIDES a cheerful English console string' -Body {
  # sfc printed "successfully repaired them"; the servicing log says it could not repair a
  # member file. If the console wins, the run reports a completed repair on a broken machine.
  $r = Invoke-FFSfcStep -ConsoleFixture 'sfc/en-US-repaired.txt' -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-unfixable.log')
  Assert-Eq 'unfixable' $r.outcome 'the log must outrank the console text'
  Assert-Match 'overrode the console text' $r.mutation.decidedBy 'the override must be recorded explicitly in the ledger'
  Assert-Match 'could NOT be fixed' $r.message 'and the user-facing message must say the repair did not complete'
  Assert-Match 'SourcePath' $r.message 'and must name the follow-up action'
}

foreach ($row in @(
  @{ Lang = 'de-DE'; Console = 'sfc/de-DE-clean.txt' }
  @{ Lang = 'ja-JP'; Console = 'sfc/ja-JP-clean.txt' }
  @{ Lang = 'fr-FR'; Console = 'sfc/fr-FR-clean.txt' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "sfc repair: $($row.Lang) console + unreadable CBS = indeterminate, never success" -Body {
    $d = $FFTestData
    $r = Invoke-FFSfcStep -ConsoleFixture $d.Console -CbsThrow 'Access to the path is denied.'
    Assert-Null $r.threw 'sfc exiting 0 must not raise'
    Assert-Eq 'indeterminate' $r.outcome "a $($d.Lang) machine with no readable CBS log cannot know what SFC found"
    Assert-Match 'no rung could decide' $r.mutation.decidedBy 'the ledger must record that nothing decided'
    Assert-Match 'COULD NOT DETERMINE' $r.message 'the message must say so in plain words'
    Assert-Match 'NOT a completed repair' $r.message 'and must refuse to claim the repair completed'
    Assert-NotNull $r.mutation.cbsLogError 'the reason the log could not be read is kept'
    Assert-False $r.mutation.cbsLogReadable 'and the log is flagged unreadable'
  }
}

Register-FFTest -Area 'STATE' -Name 'sfc repair: a non-zero exit code is a hard failure whatever the text says' -Body {
  $r = Invoke-FFSfcStep -ConsoleFixture 'sfc/en-US-clean.txt' -ExitCode 1 -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-clean.log')
  Assert-NotNull $r.threw 'a non-zero exit must throw so the step is recorded as failed'
  Assert-Match 'exit code 1' $r.threw 'and the exit code must be named'
  Assert-Eq 1 $r.mutation.exitCode 'the exit code is recorded in the ledger BEFORE the throw'
  Assert-NotNull $r.outcome 'the outcome reached before the throw is still recorded'
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 5' -Name 'sfc repair: the declared command matches what the step actually runs' -Body {
  $r = Invoke-FFSfcStep -ConsoleFixture 'sfc/en-US-clean.txt' -CbsThrow 'denied'
  $cmd = (@($r.commands) -join ' ')
  Assert-Match 'sfc\.exe /scannow' $cmd 'the catalog-facing command text must name the real command'
  Assert-Match 'indeterminate' $cmd 'and must state that an undecidable outcome is reported as indeterminate'
}
