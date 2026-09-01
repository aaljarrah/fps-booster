<#
  SABOTAGE :: proving the suite would catch it, instead of assuming it would

  WHY THIS FILE EXISTS. The suite was briefed to catch a stale CBS log grading today's SFC
  scan. It did not. Deleting the time scoping from repair.ps1's Get-SfcCbsOutcome - the
  `-Since` guard, the single line that decides whether a [SR] marker belongs to THIS run -
  left all 257 tests green, and a 30-day-old 'Verify complete' would have graded today's
  sfc-scannow as a completed, successful repair on a machine nobody measured. 257 passing
  tests were not evidence that the guard worked; they were evidence that nothing looked.

  So each case here is a PAIR, and both halves run the SAME assertion function:

    1. against the real engine  -> it must pass
    2. against a sandboxed COPY of the engine with exactly one guard textually removed
                                -> it must FAIL, and the failure text is printed on demand

  Measure-FFAsserts is what makes 2 possible: it runs an assertion function against a private
  assertion list and reports how many failed, without polluting the case's own verdict. The
  two halves cannot drift apart, because there is only one assertion function.

  New-FFSabotagedEngine requires its -Find pattern to match EXACTLY ONCE. A guard that moves
  or is rewritten therefore breaks the sabotage LOUDLY (the case throws and names the drift)
  rather than quietly applying to nothing and passing for the wrong reason - which is the
  failure mode this whole file is a reaction to.

  Nothing here runs against the real machine. The sabotaged engines only ever exist inside
  this run's scratch directory, they are only ever loaded in-process behind the same mutation
  guards cases\60-safety.ps1 uses, and Assert-FFSafeArgs still gates every child process.
#>

$FFSabotageCache = @{}
function Get-FFSabotage {
  <# One sabotaged sandbox per (engine, guard), built on first use and reused after. #>
  param([string]$Key, [string]$Engine, [string]$Find, [string]$Replace)
  if (-not $FFSabotageCache.ContainsKey($Key)) {
    $FFSabotageCache[$Key] = New-FFSabotagedEngine -Engine $Engine -Find $Find -Replace $Replace -Label "sab-$Key"
  }
  $FFSabotageCache[$Key]
}

# =====================================================================================
# 1. CBS TIME SCOPING - the guard the suite was briefed to protect and did not
# =====================================================================================

# The one line that attributes a [SR] marker to this run. Removing it is the regression.
$FFSinceGuardFind = 'if \(\$null -eq \$out\.since -or \$ts -ge \$Since\) \{ \$lines \+= \$line \}'
$FFSinceGuardKill = '$lines += $line'

function Assert-FFStaleCbsIsNotAVerdict {
  <#
    THE ASSERTION. A CBS log whose [SR] lines were all written weeks before this scan started
    contains no evidence about this scan, so Get-SfcCbsOutcome must return an honest $null and
    say why - for a 'clean' log, a 'repaired' log and an 'unfixable' log alike. Grading any of
    them is reading someone else's measurement and reporting it as yours.
  #>
  param([string]$EngineDir = '')
  foreach ($row in @(
    @{ Log = 'cbs/sr-clean.log';     WouldSay = 'clean' }
    @{ Log = 'cbs/sr-repaired.log';  WouldSay = 'repaired' }
    @{ Log = 'cbs/sr-unfixable.log'; WouldSay = 'unfixable' }
  )) {
    # 30 days old, and the scan started two minutes ago.
    $lines = Get-FFFixtureLines -Path $row.Log -AgeMinutes 43200
    $r = Invoke-InEngineScope -Engine 'repair' -EngineDir $EngineDir -Ctx @{ lines = @($lines) } -Mocks {
      function Get-Content { param($Path, $LiteralPath, $Tail, $Encoding, [switch]$Raw, $ErrorAction, $TotalCount)
        if ("$Path$LiteralPath" -match 'CBS\.log$') { return @($TestCtx.lines) }
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters }
    } -Test { $TestCtx.res = Get-SfcCbsOutcome -Since (Get-Date).AddMinutes(-2) }

    $res = $r.res
    Assert-HonestUnknown $res.outcome "a CBS log whose newest [SR] line is 30 days old (it would otherwise read '$($row.WouldSay)')"
    Assert-True ($res.srLinesTotal -gt 0) "the stale lines must still be COUNTED, not silently dropped ($($row.Log))"
    Assert-Eq 0 ([int]$res.srLinesThisRun) "and none of them may be attributed to this run ($($row.Log))"
    Assert-True ([bool]$res.readable) "the log was readable - this is not a read failure ($($row.Log))"
    Assert-NotNull $res.error "and the engine must say WHY it could not decide ($($row.Log))"
    Assert-Match '(?i)older|before this scan|at or after' "$($res.error)" `
      "the reason must name the TIME problem, not something else ($($row.Log))"
  }
}

function Assert-FFStaleCbsStepIsIndeterminate {
  <#
    The user-visible consequence of the same guard, through the whole sfc step. The console
    text is empty (a truncated or redirected sfc run - the case where CBS is the deciding
    rung on an English machine too), and the log is stale. The step must report indeterminate
    and say the repair did not complete. Without the guard it reports a completed repair.
  #>
  param([string]$EngineDir = '')
  $r = Invoke-FFSfcStep -ConsoleFixture 'sfc/empty.txt' -EngineDir $EngineDir `
                        -CbsLines (Get-FFFixtureLines -Path 'cbs/sr-clean.log' -AgeMinutes 43200)
  Assert-Null $r.threw 'sfc exiting 0 must not raise'
  Assert-Eq 'indeterminate' $r.outcome 'a scan that left no evidence in the log is indeterminate, never clean'
  Assert-Match 'no rung could decide' "$($r.mutation.decidedBy)" 'and the ledger must record that nothing decided'
  Assert-Match 'NOT a completed repair' "$($r.message)" 'and the message must refuse to claim the repair completed'
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 2' -Name 'CBS: a 30-day-old [SR] log does not grade today''s scan' -Body {
  Assert-FFStaleCbsIsNotAVerdict
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 2' -Name 'CBS: a stale log leaves the sfc step indeterminate, not "repaired"' -Body {
  Assert-FFStaleCbsStepIsIndeterminate
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 2' -Name 'SABOTAGE: deleting the CBS -Since guard is CAUGHT' -Body {
  $sab = Get-FFSabotage -Key 'cbs-since' -Engine 'repair' -Find $FFSinceGuardFind -Replace $FFSinceGuardKill
  Assert-Match '\$Since' "$($sab.before)" 'the sabotage must have removed the time comparison itself'

  $real = Measure-FFAsserts { Assert-FFStaleCbsIsNotAVerdict }
  Assert-Eq 0 $real.failed "the real engine must hold the guard (failed: $(@($real.texts) -join ' | '))"
  Assert-True ($real.total -ge 18) 'and the assertion must actually be making assertions'

  $broken = Measure-FFAsserts { Assert-FFStaleCbsIsNotAVerdict -EngineDir $sab.engineDir }
  Assert-Null $broken.threw "the sabotaged engine must still RUN, so the failure is a verdict and not a crash ($($broken.threw))"
  Assert-True ($broken.failed -gt 0) 'REMOVING THE TIME SCOPING MUST FAIL THIS SUITE - it did not, before this file existed'
  Assert-True (@($broken.texts | Where-Object { $_ -match 'DOCTRINE 2' }).Count -gt 0) `
    'and it must fail as a doctrine-2 violation: a confident answer over a measurement that was never made'
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 2' -Name 'SABOTAGE: deleting the CBS -Since guard is caught through the whole sfc step too' -Body {
  $sab = Get-FFSabotage -Key 'cbs-since' -Engine 'repair' -Find $FFSinceGuardFind -Replace $FFSinceGuardKill
  $real = Measure-FFAsserts { Assert-FFStaleCbsStepIsIndeterminate }
  Assert-Eq 0 $real.failed "the real step must report indeterminate (failed: $(@($real.texts) -join ' | '))"
  $broken = Measure-FFAsserts { Assert-FFStaleCbsStepIsIndeterminate -EngineDir $sab.engineDir }
  Assert-True ($broken.failed -gt 0) 'without the guard the step grades the run from a 30-day-old log, and that must fail the suite'
}

# =====================================================================================
# 2. A PROBE THAT REPORTS HEALTHY WHEN ITS QUERY FAILED
# =====================================================================================

# health.ps1 missing / crashed / unparseable arrives at Get-RepairDetection as $null. The
# guard turns that into indeterminate + probe-failure, which refuses. The sabotage makes it
# report healthy instead - the exact shape of doctrine rule 2's worst case.
$FFProbeGuardFind = 'if \(\$null -eq \$probe\) \{'
$FFProbeGuardKill = "if (`$null -eq `$probe) { `$det.state = 'healthy'; `$det.reason = `$null; `$det.detail = 'SABOTAGE: a failed probe reported as healthy.'; return `$det }`r`n  if (`$false) {"

function Assert-FFFailedProbeRefuses {
  <# A probe that did not answer is not permission to fix. Same claim as the SAFETY case of
     the same name, made against a chosen engine so the sabotage can be pointed at it. #>
  param([string]$EngineDir = '')
  $ctx = @{ mutationAttempts = @(); rows = @() }
  $r = Invoke-InEngineScope -Engine 'repair' -EngineDir $EngineDir -Ctx $ctx -Mocks ([scriptblock]::Create(
      $FFMutationGuards.ToString() + @'

function Invoke-HealthProbe { param([string]$Category, [switch]$Deep, [switch]$Fresh) $null }

# Same licence-channel pin as the SAFETY case of the same name: on a KMS/volume-licensed
# host (Windows Server CI runner), activation-retry's environment gate truthfully answers
# not-applicable before the probe is consulted, and this assertion would measure the
# runner's licence instead of the probe-failure guard.
function Get-FFLicenseState {
  [ordered]@{ readable = $true; error = $null; rows = @(); keyedRows = 1; primary = $null
              channel = 'retail'; channelSource = 'product-key-channel'; status = 1
              statusText = 'Licensed'; product = 'Stubbed Windows (Retail)'; kmsHost = $null
              primaryChosenBy = 'stub' } }
'@)) -Test {
    foreach ($rep in @(Load-Catalog)) {
      if ("$($rep.localDetect)" -match '\S') { continue }
      $TestCtx.rows += [pscustomobject]@{ id = "$($rep.id)"; doc = (Invoke-RepairRun $rep) }
    }
  }
  Assert-Stop (@($r.rows).Count -gt 0) 'at least one repair must depend on the health probe'
  Assert-Eq 0 @($r.mutationAttempts).Count 'a failed probe must not reach a single mutating command'
  foreach ($row in @($r.rows)) {
    Assert-Eq 'indeterminate' "$($row.doc.detection.state)" "$($row.id): a failed probe is indeterminate, NEVER healthy"
    Assert-Eq 'probe-failure' "$($row.doc.detection.reason)" "$($row.id): with reason probe-failure"
    Assert-Eq $true $row.doc.wouldRefuse "$($row.id): and the repair must refuse"
  }
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 2' -Name 'SABOTAGE: a probe that reports healthy when its query FAILED is caught' -Body {
  $sab = Get-FFSabotage -Key 'probe-healthy' -Engine 'repair' -Find $FFProbeGuardFind -Replace $FFProbeGuardKill
  $real = Measure-FFAsserts { Assert-FFFailedProbeRefuses }
  Assert-Eq 0 $real.failed "the real engine must refuse on a failed probe (failed: $(@($real.texts) -join ' | '))"
  Assert-True ($real.total -gt 20) 'and the assertion must cover the whole probe-driven part of the ladder'

  $broken = Measure-FFAsserts { Assert-FFFailedProbeRefuses -EngineDir $sab.engineDir }
  Assert-Null $broken.threw "the sabotaged engine must still run ($($broken.threw))"
  Assert-True ($broken.failed -gt 0) 'a green tick over a measurement that failed MUST fail this suite'
  Assert-True (@($broken.texts | Where-Object { $_ -match 'NEVER healthy' }).Count -gt 0) `
    'and the failure must be the one that names it: healthy over a failed probe'
}

# =====================================================================================
# 3. A DRY RUN THAT MUTATES
# =====================================================================================

# The `if ($DryRun) { ... }` short-circuit in Invoke-RepairRun, anchored on the line above it
# so the pattern cannot also match the second (undo) dry-run branch.
$FFDryRunGuardFind = '\$refusalKind = Get-RefusalKind \$preDet\r?\n\r?\n  if \(\$DryRun\) \{'
$FFDryRunGuardKill = "`$refusalKind = Get-RefusalKind `$preDet`r`n`r`n  if (`$false) {"

function Assert-FFDryRunIsInert {
  <#
    The scenario that matters: a probe that DOES find each repair's problem, so nothing is
    stopped by refuse-if-healthy and the dry-run short-circuit is the ONLY thing standing
    between the sweep and a real repair. Every mutating cmdlet is shadowed by a throwing
    recorder (cases\60-safety.ps1's $FFMutationGuards), so a leak is caught and NAMED here
    rather than performed.
  #>
  param([string]$EngineDir = '')
  $r = Invoke-FFDryRunSweep -EngineDir $EngineDir -ProbeStatus 'warning' -ProbeFindings @(
    'wu-service-disabled|warning|A service is disabled.'
    'store-cache-corrupt|warning|The store cache is corrupt.'
    'search-index-corrupt|warning|The index is corrupt.'
    'spooler-stopped|warning|The spooler is stopped.'
    'dns-resolution-failed|warning|DNS does not resolve.'
    'component-store-corrupt|critical|The component store is corrupt.'
  )
  Assert-Stop (@($r.rows).Count -gt 20) "the whole catalog must have been swept (got $(@($r.rows).Count))"
  Assert-Eq 0 @($r.mutationAttempts).Count "NO dry run may reach a mutating command (attempted: $(@($r.mutationAttempts) -join '; '))"
  Assert-Eq 0 $r.ledgerWrites 'and none may write a ledger entry'
  foreach ($row in @($r.rows)) {
    Assert-Eq $true  $row.doc.dryRun  "$($row.id): dryRun must be reported true"
    Assert-Eq $false $row.doc.mutated "$($row.id): mutated MUST be false"
  }
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 4' -Name 'SABOTAGE: a dry run that actually mutates is caught' -Slow -Body {
  $sab = Get-FFSabotage -Key 'dryrun' -Engine 'repair' -Find $FFDryRunGuardFind -Replace $FFDryRunGuardKill
  $real = Measure-FFAsserts { Assert-FFDryRunIsInert }
  Assert-Eq 0 $real.failed "a real dry run must be inert even when every repair has a matching fault (failed: $(@($real.texts) -join ' | '))"

  $broken = Measure-FFAsserts { Assert-FFDryRunIsInert -EngineDir $sab.engineDir }
  Assert-True ($broken.failed -gt 0) 'deleting the dry-run short-circuit MUST fail this suite'
  Assert-True (@($broken.texts | Where-Object { $_ -match 'mutating command|dryRun must be reported' }).Count -gt 0) `
    'and it must fail as a mutation, naming the command the dry run tried to run'
}

# =====================================================================================
# 4. A CATALOG COMMAND THAT DIVERGES FROM WHAT THE ENGINE RUNS
# =====================================================================================
# Doctrine rule 5. repair.ps1 -Action selftest compares every data\repairs.json whatItRuns
# line against the real step commands; the CONTRACT case 'the catalog documents exactly what
# will run' gates on it. The sabotage edits the CATALOG in a sandbox so it promises a command
# the engine does not run, and the selftest must refuse to bless it.

function New-FFDivergentCatalogSandbox {
  <# A sandbox whose data\repairs.json promises sfc.exe /verifyonly for a step that runs
     sfc.exe /scannow. Throws if the text it rewrites is not there, for the same reason
     New-FFSabotagedEngine does. #>
  $sandbox = New-FFSandbox -Label 'sab-catalog'
  $catalog = Join-Path $sandbox 'data\repairs.json'
  $text = Get-Content -LiteralPath $catalog -Raw -Encoding UTF8
  $hits = [regex]::Matches($text, [regex]::Escape('sfc.exe /scannow'))
  if ($hits.Count -lt 1) { throw "SABOTAGE TARGET NOT FOUND: no 'sfc.exe /scannow' line in the sandboxed data\repairs.json - the catalog's wording moved, so this sabotage would prove nothing." }
  $patched = $text.Replace('sfc.exe /scannow', 'sfc.exe /verifyonly')
  [System.IO.File]::WriteAllText($catalog, $patched, (New-Object System.Text.UTF8Encoding($false)))
  $sandbox
}

function Assert-FFCatalogMatchesEngine {
  <# The catalog says exactly what the engine will run. Run against a sandbox so the sabotage
     can be pointed at a copy. #>
  param([Parameter(Mandatory)][string]$Sandbox)
  $res = Invoke-FFEngineProcess -Script (Join-Path $Sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'selftest') -TimeoutMs 90000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 selftest' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the selftest document must parse'
  Assert-Eq $true $doc.ok 'the catalog self-test must pass - a failure means data/repairs.json no longer describes what the engine does'
  Assert-Eq $true $doc.whatItRunsIntegrity.ok 'and every whatItRuns line must match the real step commands'
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 5' -Name 'SABOTAGE: a catalog command that diverges from what the engine runs is caught' -Body {
  $clean = New-FFSandbox -Label 'sab-catalog-clean'
  $real = Measure-FFAsserts { Assert-FFCatalogMatchesEngine -Sandbox $clean }
  Assert-Eq 0 $real.failed "an untouched catalog must self-test clean (failed: $(@($real.texts) -join ' | '))"

  $divergent = New-FFDivergentCatalogSandbox
  $broken = Measure-FFAsserts { Assert-FFCatalogMatchesEngine -Sandbox $divergent }
  Assert-True ($broken.failed -gt 0) 'a catalog promising /verifyonly for a step that runs /scannow MUST fail the self-test'
  Assert-True (@($broken.texts | Where-Object { $_ -match 'whatItRuns|self-test must pass' }).Count -gt 0) `
    'and it must fail on the what-it-runs comparison, not on something incidental'
}

# =====================================================================================
# 5. THE SABOTAGE MACHINERY ITSELF
# =====================================================================================

Register-FFTest -Area 'SABOTAGE' -Name 'a sabotage whose target has moved fails LOUDLY instead of applying to nothing' -Body {
  # The failure mode this file exists to prevent, one level up: a sabotage test that quietly
  # patches nothing would "prove" the suite catches a regression it never introduced.
  Assert-Throws { New-FFSabotagedEngine -Engine 'repair' -Find 'this guard does not exist anywhere' -Replace 'x' -Label 'sab-miss' } `
    'a pattern that matches nothing must throw' -Pattern 'SABOTAGE TARGET NOT FOUND'
  Assert-Throws { New-FFSabotagedEngine -Engine 'repair' -Find '\$det\.reason = .probe-failure.' -Replace 'x' -Label 'sab-many' } `
    'a pattern that matches more than once must throw too - a sabotage must be exactly one change' -Pattern 'SABOTAGE TARGET NOT FOUND'
  # ...and it never touches the real tree.
  $realSrc = Get-FFEngineSource -Engine 'repair'
  Assert-Match ([regex]::Escape('$ts -ge $Since')) $realSrc 'the REAL repair.ps1 still carries the guard after all this'
  Assert-Eq 0 @(Compare-FFRealStateFingerprint).Count 'and sabotaging copies changed nothing on this machine'
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'rule 4' -Name 'a sabotaged engine can never be launched as a child process' -Body {
  # The hazard this closes, found while proving the dry-run sabotage by hand: the suite's
  # denylist permits `repair.ps1 -Action run -DryRun` as a real child process, and it does so on
  # the strength of the very short-circuit a sabotage is allowed to delete. Run the two together
  # and the suite would execute real repairs on this machine. (It did not: repair.ps1's elevation
  # gate returns first and the suite is unelevated - which is luck, not a guarantee.) A sabotaged
  # sandbox is now marked, and the child-process runner refuses it outright.
  $sab = Get-FFSabotage -Key 'cbs-since' -Engine 'repair' -Find $FFSinceGuardFind -Replace $FFSinceGuardKill
  Assert-True (Test-Path -LiteralPath (Join-Path $sab.sandbox '.ff-sabotaged')) 'a sabotaged sandbox is marked as one'
  foreach ($args_ in @(
    @('-Action', 'run', '-Id', 'sfc-scannow', '-DryRun'),
    @('-Action', 'selftest'),
    @('-Action', 'ledger')
  )) {
    Assert-Throws { Invoke-FFEngineProcess -Script (Join-Path $sab.sandbox 'engine\repair.ps1') -EngineArgs $args_ -TimeoutMs 30000 } `
      "the runner must refuse to spawn a sabotaged engine ($(@($args_) -join ' ')) - even for a read-only action, because a sabotage can change what 'read-only' means" `
      -Pattern 'SUITE SAFETY'
  }
  # And an UNsabotaged sandbox is still launchable, or the guard would have broken the suite.
  $clean = New-FFSandbox -Label 'sab-guard-clean'
  $res = Invoke-FFEngineProcess -Script (Join-Path $clean 'engine\repair.ps1') -EngineArgs @('-Action', 'ledger') -TimeoutMs 60000
  Assert-Eq 0 $res.exitCode 'an ordinary sandbox is unaffected'
}

Register-FFTest -Area 'SABOTAGE' -Doctrine 'the suite is read-only' `
  -Name 'SABOTAGE: the read-only gate really detects a changed byte' -Body {
  # run-tests.ps1 exits 3 when the machine moved under the run. That claim is worth exactly as
  # much as the proof that the comparison fires, so the SAME functions are run here over a
  # scratch directory the suite is allowed to change.
  $dir = Join-Path $script:FFWorkDir ('fpr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $keep = Join-Path $dir 'ledger.json'; Set-Content -LiteralPath $keep -Value '[]' -Encoding UTF8
  $gone = Join-Path $dir 'gone.json';   Set-Content -LiteralPath $gone -Value '[]' -Encoding UTF8
  $before = Get-FFRealStateFingerprint -Paths @($dir)

  Assert-Eq 0 @(Compare-FFRealStateFingerprint -Before $before -Paths @($dir)).Count 'an untouched directory reports no differences'

  Set-Content -LiteralPath $keep -Value '[{"id":"a-repair-nobody-asked-for"}]' -Encoding UTF8
  Remove-Item -LiteralPath $gone -Force
  $added = Join-Path $dir 'new.json'; Set-Content -LiteralPath $added -Value '{}' -Encoding UTF8
  $diffs = @(Compare-FFRealStateFingerprint -Before $before -Paths @($dir))

  Assert-Eq 3 $diffs.Count "every change must be reported, one line each (got: $($diffs -join '; '))"
  Assert-True (@($diffs | Where-Object { $_ -like "MODIFIED*ledger.json" }).Count -eq 1) 'a rewritten ledger is reported as MODIFIED'
  Assert-True (@($diffs | Where-Object { $_ -like "DELETED*gone.json" }).Count -eq 1)    'a deleted file is reported as DELETED'
  Assert-True (@($diffs | Where-Object { $_ -like "CREATED*new.json" }).Count -eq 1)     'and a file that appeared is reported as CREATED'

  # And the gate is actually wired to this: run-tests.ps1 must call it and exit 3.
  $runner = Get-Content -LiteralPath (Join-Path $script:FFTestRoot 'run-tests.ps1') -Raw -Encoding UTF8
  Assert-Match 'Compare-FFRealStateFingerprint' $runner 'run-tests.ps1 must run the comparison'
  Assert-Match '(?m)^\s*exit 3\s*$' $runner 'and exit 3 when it is not empty'
  Assert-True ($runner.IndexOf('Compare-FFRealStateFingerprint') -lt $runner.IndexOf('Get-FFSuiteExitCode')) `
    'and it must be checked BEFORE the test verdict, because it outranks it'
}

Register-FFTest -Area 'SABOTAGE' -Name 'Measure-FFAsserts reports failures without polluting the calling test' -Body {
  # Every case above depends on this being true, so it is asserted rather than assumed.
  $r = Measure-FFAsserts { Assert-Eq 1 1 'passes'; Assert-Eq 1 2 'fails'; Assert-Eq 3 4 'fails too' }
  Assert-Eq 3 $r.total 'all three assertions are counted'
  Assert-Eq 2 $r.failed 'and the two failures are reported'
  Assert-Null $r.threw 'no exception was raised'
  Assert-True (@($r.texts | Where-Object { $_ -match 'fails too' }).Count -eq 1) 'the failure texts come back'
  $t = Measure-FFAsserts { throw 'boom' }
  Assert-Match 'boom' "$($t.threw)" 'a body that throws is reported as threw, not silently swallowed'
}
