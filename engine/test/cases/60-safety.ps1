<#
  SAFETY :: the invariants that stop this thing breaking someone's computer

    rule 1  detect before fixing; verify after, with the same read-only probe
    rule 2  never report a confident result you did not measure
    rule 3  undo restores captured prior state
    rule 4  destructive / irreversible actions are consent-gated
    rule 5  the catalog documents exactly what will run

  HOW THESE STAY SAFE. The whole-catalog dry-run sweep runs IN PROCESS with three
  independent layers of protection, because a bug in the -DryRun short-circuit would
  otherwise mutate this machine:
    1. -DryRun is set, so Invoke-RepairRun must return before any step executes
    2. every mutating cmdlet a step could reach (Start-Process, Set-Service, Stop-Service,
       Set-ItemProperty, Remove-Item, Checkpoint-Computer, Repair-WindowsImage, ...) is
       shadowed by a stub that THROWS and records the attempt - so a leak is caught and
       named rather than performed
    3. Join-Path is shadowed so any %SystemRoot%\System32\<tool>.exe a step builds resolves
       to a non-existent path, and the in-box console tools (sc, net, netsh, reg, chkdsk,
       bcdedit, ...) are shadowed by throwing stubs of their own
    4. the ledger writers are shadowed, so nothing is written to data\state either
  If layer 1 ever breaks, the test fails LOUDLY at layer 2 or 3 with the command it tried
  to run, rather than performing it.
#>

# Every cmdlet a repair step could use to change something. Shadowed as throwing recorders.
$FFMutationGuards = {
  $DryRun = $true
  $Force = $false
  $NoRestorePoint = $false
  $script:FFLedgerWrites = 0

  function Save-RepairLedger { param($Entries) $script:FFLedgerWrites++ }
  function Sync-LedgerEntry  { param($Entry)   $script:FFLedgerWrites++ }

  function FFDeny { param([string]$What)
    $TestCtx.mutationAttempts += "$What"
    throw "SUITE SAFETY: a -DryRun repair tried to run '$What'. The dry-run short-circuit is broken." }

  function Start-Process        { param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$Wait, [switch]$NoNewWindow, $WindowStyle, $Verb, $ErrorAction) FFDeny "Start-Process $FilePath" }
  function Set-Service          { param($Name, $StartupType, $Status, $ErrorAction) FFDeny "Set-Service $Name" }
  function Stop-Service         { param($Name, [switch]$Force, $ErrorAction) FFDeny "Stop-Service $Name" }
  function Start-Service        { param($Name, $ErrorAction) FFDeny "Start-Service $Name" }
  function Restart-Service      { param($Name, [switch]$Force, $ErrorAction) FFDeny "Restart-Service $Name" }
  function Set-ItemProperty     { param($Path, $Name, $Value, $Type, $ErrorAction, $LiteralPath) FFDeny "Set-ItemProperty $Path\$Name" }
  function New-ItemProperty     { param($Path, $Name, $Value, $PropertyType, [switch]$Force, $ErrorAction) FFDeny "New-ItemProperty $Path\$Name" }
  function Remove-ItemProperty  { param($Path, $Name, $ErrorAction) FFDeny "Remove-ItemProperty $Path\$Name" }
  function Remove-Item          { param($Path, $LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) FFDeny "Remove-Item $Path$LiteralPath" }
  function Rename-Item          { param($Path, $LiteralPath, $NewName, [switch]$Force, $ErrorAction) FFDeny "Rename-Item $Path$LiteralPath" }
  function Move-Item            { param($Path, $LiteralPath, $Destination, [switch]$Force, $ErrorAction) FFDeny "Move-Item $Path$LiteralPath" }
  function Copy-Item            { param($Path, $LiteralPath, $Destination, [switch]$Recurse, [switch]$Force, $ErrorAction) FFDeny "Copy-Item $Path$LiteralPath" }
  function Checkpoint-Computer  { param($Description, $RestorePointType, $ErrorAction) FFDeny 'Checkpoint-Computer' }
  function Enable-ComputerRestore { param($Drive, $ErrorAction) FFDeny 'Enable-ComputerRestore' }
  function Repair-WindowsImage  { param([switch]$Online, [switch]$RestoreHealth, [switch]$ScanHealth, [switch]$CheckHealth, $Source, [switch]$LimitAccess, $ErrorAction) FFDeny 'Repair-WindowsImage' }
  function Enable-WindowsOptionalFeature { param([switch]$Online, $FeatureName, $Source, [switch]$All, [switch]$NoRestart, $ErrorAction) FFDeny "Enable-WindowsOptionalFeature $FeatureName" }
  function Disable-WindowsOptionalFeature { param([switch]$Online, $FeatureName, $ErrorAction) FFDeny "Disable-WindowsOptionalFeature $FeatureName" }
  function Set-DnsClientServerAddress { param($InterfaceIndex, $ServerAddresses, [switch]$ResetServerAddresses, $ErrorAction) FFDeny 'Set-DnsClientServerAddress' }
  function Clear-DnsClientCache { param($ErrorAction) FFDeny 'Clear-DnsClientCache' }
  function Restart-Computer     { param([switch]$Force, $ErrorAction) FFDeny 'Restart-Computer' }
  function Stop-Process         { param($Id, $Name, [switch]$Force, $ErrorAction) FFDeny "Stop-Process $Id$Name" }
  function Set-Content          { param($Path, $LiteralPath, $Value, $Encoding, $ErrorAction) FFDeny "Set-Content $Path$LiteralPath" }
  function Out-File             { param($FilePath, $Encoding, $ErrorAction) FFDeny "Out-File $FilePath" }
  function New-Item             { param($Path, $ItemType, $Value, [switch]$Force, $ErrorAction)
    # Directory creation under the scratch dir is harmless; anything else is a mutation.
    if ("$Path" -like "$([System.IO.Path]::GetTempPath())*") { return Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force }
    FFDeny "New-Item $Path" }

  # Layer 3: any %SystemRoot%\System32\<tool>.exe a step builds resolves somewhere harmless,
  # and the in-box console tools are stubbed by name too. ($env:SystemRoot is deliberately NOT
  # redirected: the .NET assembly loader reads it, and moving it breaks ConvertFrom-Json.)
  function Join-Path { param($Path, $ChildPath, $Resolve, $ErrorAction)
    $p = Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
    if ($p -match '(?i)\\System32\\[^\\]+\.exe$') {
      return (Microsoft.PowerShell.Management\Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ff-suite-blocked-tool.exe')
    }
    $p }
  function sc.exe   { FFDeny 'sc.exe' }
  function net      { FFDeny 'net' }
  function net.exe  { FFDeny 'net.exe' }
  function netsh    { FFDeny 'netsh' }
  function reg      { FFDeny 'reg' }
  function bcdedit  { FFDeny 'bcdedit' }
  function chkdsk   { FFDeny 'chkdsk' }
  function schtasks { FFDeny 'schtasks' }
  function wevtutil { FFDeny 'wevtutil' }
  function takeown  { FFDeny 'takeown' }
  function icacls   { FFDeny 'icacls' }
  function cmd      { FFDeny 'cmd' }
}

$FFSweepCache = @{}

function Invoke-FFDryRunSweep {
  <# Every repair in the catalog, -DryRun, in one process, with the guards above.
     Cached per (status, findings, engine) so the several tests that share a scenario pay for
     it once. -EngineDir sweeps a SANDBOXED copy instead of the real engine; cases\65-sabotage.ps1
     uses it to point these same assertions at an engine whose dry-run short-circuit has been
     deleted, and check that they fail. #>
  param([string]$ProbeStatus = 'ok', [string[]]$ProbeFindings = @(), [string]$EngineDir = '')
  $key = "$ProbeStatus|" + (@($ProbeFindings) -join '~') + "|$EngineDir"
  if ($FFSweepCache.ContainsKey($key)) { return $FFSweepCache[$key] }
  $ctx = @{ mutationAttempts = @(); probeStatus = $ProbeStatus; probeFindings = @($ProbeFindings); rows = @() }
  $r = Invoke-InEngineScope -Engine 'repair' -EngineDir $EngineDir -Ctx $ctx -Mocks ([scriptblock]::Create(
      $FFMutationGuards.ToString() + @'

function Invoke-HealthProbe { param([string]$Category, [switch]$Deep, [switch]$Fresh)
  $f = @()
  foreach ($row in @($TestCtx.probeFindings)) {
    $p = "$row" -split '\|', 3
    $f += [pscustomobject]@{ id = $p[0]; severity = $p[1]; detail = $p[2] }
  }
  [pscustomobject]@{ category = $Category; status = $TestCtx.probeStatus; summary = 'Stubbed probe.'; findings = $f } }
'@)) -Test {
    foreach ($rep in @(Load-Catalog)) {
      $doc = $null; $err = $null
      try { $doc = Invoke-RepairRun $rep } catch { $err = "$($_.Exception.Message)" }
      $TestCtx.rows += [pscustomobject]@{ id = "$($rep.id)"; tier = "$($rep.tier)"; doc = $doc; err = $err }
    }
    $TestCtx.ledgerWrites = $script:FFLedgerWrites
  }
  $FFSweepCache[$key] = $r
  $r
}

# ---------------- the suite's own safety rail ----------------

Register-FFTest -Area 'SAFETY' -Name 'the suite refuses to launch any mutating engine invocation' -Body {
  foreach ($case in @(
    @{ S = 'repair.ps1'; A = @('-Action', 'run', '-Id', 'wu-reset') }
    @{ S = 'repair.ps1'; A = @('-Action', 'run', '-Id', 'sfc-scannow', '-Force') }
    @{ S = 'repair.ps1'; A = @('-Action', 'undo', '-Id', 'wu-reset') }
    @{ S = 'image.ps1';  A = @('-Action', 'download', '-Url', 'https://example.invalid/x.iso', '-Dest', 'C:\x.iso') }
    @{ S = 'image.ps1';  A = @('-Action', 'acquire-url', '-ConsentRunFido') }
    @{ S = 'image.ps1';  A = @('-Action', 'preflight', '-AcceptEula') }
    @{ S = 'image.ps1';  A = @('-Action', 'launch', '-Confirm') }
    @{ S = 'image.ps1';  A = @('-Action', 'dism-source-repair', '-IsoPath', 'C:\x.iso') }
    @{ S = 'engine.ps1'; A = @('-Action', 'apply', '-Id', 'disable-gamedvr') }
    @{ S = 'engine.ps1'; A = @('-Action', 'restore-point') }
    @{ S = 'nvidia.ps1'; A = @('-Action', 'apply-preset', '-Preset', 'esports') }
    @{ S = 'nvidia.ps1'; A = @('-Action', 'snapshot') }
    @{ S = 'procs.ps1';  A = @('-Action', 'close', '-Ids', '1234') }
    @{ S = 'measure.ps1'; A = @('-Action', 'capture', '-Process', 'game.exe') }
  )) {
    Assert-Throws { Assert-FFSafeArgs -Script $case.S -EngineArgs $case.A } `
      "the runner must refuse '$($case.S) $(@($case.A) -join ' ')'" -Pattern 'SUITE SAFETY'
  }
  # ...while still allowing the read-only surface the suite actually uses.
  foreach ($ok in @(
    @{ S = 'repair.ps1'; A = @('-Action', 'run', '-Id', 'wu-reset', '-DryRun') }
    @{ S = 'repair.ps1'; A = @('-Action', 'preflight', '-Id', 'wu-reset') }
    @{ S = 'repair.ps1'; A = @('-Action', 'selftest') }
    @{ S = 'image.ps1';  A = @('-Action', 'launch', '-SourcePath', 'C:\media') }
    @{ S = 'health.ps1'; A = @('-Action', 'scan') }
  )) {
    $threw = $false
    try { Assert-FFSafeArgs -Script $ok.S -EngineArgs $ok.A } catch { $threw = $true }
    Assert-False $threw "the runner must ALLOW '$($ok.S) $(@($ok.A) -join ' ')'"
  }
}

# ---------------- every repair, dry run ----------------

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Name 'every repair: -DryRun mutates nothing and says so' -Body {
  $r = Invoke-FFDryRunSweep -ProbeStatus 'ok'
  Assert-Stop (@($r.rows).Count -gt 20) "the whole catalog must have been swept (got $(@($r.rows).Count))"
  Assert-Eq 0 @($r.mutationAttempts).Count "no dry run may reach a mutating command (attempted: $(@($r.mutationAttempts) -join '; '))"
  Assert-Eq 0 $r.ledgerWrites 'no dry run may write a ledger entry'
  foreach ($row in @($r.rows)) {
    Assert-Null $row.err "$($row.id): a dry run must not throw"
    Assert-Stop ($null -ne $row.doc) "$($row.id): a dry run must return a document"
    Assert-Eq $true  $row.doc.ok      "$($row.id): the dry-run document is a success document"
    Assert-Eq $true  $row.doc.dryRun  "$($row.id): dryRun must be reported true"
    Assert-Eq $false $row.doc.mutated "$($row.id): mutated MUST be false"
    Assert-Eq 'run'  $row.doc.action  "$($row.id): the action is reported"
    Assert-True (@($row.doc.steps).Count -gt 0) "$($row.id): the exact steps that WOULD run must be listed"
    Assert-Match 'none of the listed commands were executed' "$($row.doc.note)" "$($row.id): the note must say nothing ran"
    Assert-Match 'no ledger entry was written' "$($row.doc.note)" "$($row.id): and that no ledger entry was written"
    Assert-NotNull $row.doc.detection "$($row.id): detection must have happened BEFORE anything else"
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 1' -Name 'refuse-if-healthy: a healthy probe stops every repair' -Body {
  # TWO legitimate answers here, and the test names both rather than skipping either.
  #  * The probe answered 'ok' -> healthy -> the repair must REFUSE, because there is nothing
  #    to fix and saying so is a first-class result.
  #  * The repair's catalog entry carries detectionNeedsAdmin and this suite runs UNELEVATED,
  #    so the deciding signal could not be read at all. The honest answer is
  #    indeterminate/needs-admin. It must NEVER be 'healthy' - an unread signal graded green is
  #    doctrine rule 2's worst case - and it must name elevation as the reason.
  # Anything else is a failure, and the healthy branch is asserted to be non-empty so the test
  # cannot quietly become a no-op if every repair starts claiming needs-admin.
  $r = Invoke-FFDryRunSweep -ProbeStatus 'ok'
  $healthy = 0; $needsAdmin = 0
  foreach ($row in @($r.rows)) {
    if ("$($row.doc.detection.method)" -ne 'health-probe') { continue }   # ntp/winget/feature detect locally
    $state = "$($row.doc.detection.state)"
    $reason = "$($row.doc.detection.reason)"
    if ($reason -eq 'needs-admin') {
      $needsAdmin++
      Assert-Eq 'indeterminate' $state "$($row.id): a signal that needs elevation is indeterminate"
      Assert-NotGraded-Ok $state "$($row.id): a repair whose deciding signal could not be read"
      Assert-Match '(?i)administrator|elevat' "$($row.doc.detection.detail)" "$($row.id): and the detail must name elevation as the reason"
      continue
    }
    $healthy++
    Assert-Eq 'healthy' $state "$($row.id): a probe reporting ok means healthy for this repair"
    Assert-Eq $true $row.doc.wouldRefuse "$($row.id): a healthy subsystem must refuse the repair"
    Assert-Eq 'nothing-broken' "$($row.doc.refusalKind)" "$($row.id): and the refusal reason is 'nothing broken here'"
    Assert-Match 'first-class result' "$($row.doc.refusalNote)" "$($row.id): the note must say that is a result, not an error"
  }
  Assert-True ($healthy -gt 5) "the refuse-if-healthy path must actually have been exercised (only $healthy repair(s) reached it; $needsAdmin were unreadable unelevated)"
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 1' -Name 'a category with issues this repair does NOT address still refuses' -Body {
  # windows-update warning solely for a pending reboot must not trigger wu-reset.
  $r = Invoke-FFDryRunSweep -ProbeStatus 'warning' -ProbeFindings @('some-unrelated-finding|warning|Not this repair.')
  # needs-admin rows are excluded BY REASON, not by outcome: their signal was never read, so
  # they have no opinion about whether the finding was relevant. The case above asserts they
  # are honest about that; here they simply have nothing to say.
  $probed = @(@($r.rows) | Where-Object {
    "$($_.doc.detection.method)" -eq 'health-probe' -and
    "$($_.doc.detection.reason)" -ne 'needs-admin' -and
    @($_.doc.detection.relevantFindings).Count -eq 0 })
  Assert-Stop (@($probed).Count -gt 0) 'at least one repair must have found no relevant findings'
  foreach ($row in @($probed)) {
    Assert-Eq 'healthy' "$($row.doc.detection.state)" "$($row.id): a warning it does not address is healthy FOR THIS REPAIR"
    Assert-Eq $true $row.doc.wouldRefuse "$($row.id): and it must still refuse"
    Assert-Match 'none of its findings are ones this repair addresses' "$($row.doc.detection.detail)" "$($row.id): the reason must be explicit"
  }
}

foreach ($row in @(
  @{ Status = 'unknown';  Reason = 'unparseable'; Kind = 'indeterminate-unparseable'; Label = "a probe that could not measure ('unknown')" }
  @{ Status = 'bananas';  Reason = 'unparseable'; Kind = 'indeterminate-unparseable'; Label = 'a probe with a status nobody recognises' }
)) {
  Register-FFTest -Area 'SAFETY' -Doctrine 'rule 2' -Data $row -Name "a probe that did not decide refuses rather than fixing blind ($($row.Label))" -Body {
    $d = $FFTestData
    $r = Invoke-FFDryRunSweep -ProbeStatus $d.Status
    $probed = @(@($r.rows) | Where-Object { "$($_.doc.detection.method)" -eq 'health-probe' })
    Assert-Stop (@($probed).Count -gt 0) 'at least one repair must go through the health probe'
    foreach ($row2 in @($probed)) {
      Assert-Eq 'indeterminate' "$($row2.doc.detection.state)" "$($row2.id): the detection state must be indeterminate"
      Assert-Eq $d.Reason "$($row2.doc.detection.reason)" "$($row2.id): the reason must be '$($d.Reason)'"
      Assert-Eq $true $row2.doc.wouldRefuse "$($row2.id): an undecided probe must refuse"
      Assert-Eq $d.Kind "$($row2.doc.refusalKind)" "$($row2.id): with the refusal kind '$($d.Kind)'"
      Assert-Match 'fixing blind' "$($row2.doc.refusalNote)" "$($row2.id): the note must say running would be fixing blind"
    }
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 2' -Name 'a FAILED probe refuses - it is not permission to fix blind' -Body {
  $ctx = @{ mutationAttempts = @(); rows = @() }
  $r = Invoke-InEngineScope -Engine 'repair' -Ctx $ctx -Mocks ([scriptblock]::Create(
      $FFMutationGuards.ToString() + @'

# health.ps1 missing, crashed, or emitting something unparseable all arrive here as $null.
function Invoke-HealthProbe { param([string]$Category, [switch]$Deep, [switch]$Fresh) $null }

# activation-retry's environment gate (Get-RepairDetection) reads the REAL licence channel
# BEFORE the probe; on a KMS/volume-licensed machine (e.g. a Windows Server CI runner) it
# truthfully answers not-applicable and the probe path is never reached. Pin the channel to
# the retail case so THIS test measures the probe-failure guard, not the runner's licence.
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
    Assert-Eq 'indeterminate' "$($row.doc.detection.state)" "$($row.id): a failed probe is indeterminate"
    Assert-Eq 'probe-failure' "$($row.doc.detection.reason)" "$($row.id): with reason probe-failure"
    Assert-Eq $true $row.doc.wouldRefuse "$($row.id): and the repair must refuse"
    Assert-Eq 'indeterminate-probe-failure' "$($row.doc.refusalKind)" "$($row.id): with the probe-failure refusal kind"
    Assert-Match 'refuses to run blind' "$($row.doc.detection.detail)" "$($row.id): the detail must say it refuses to run blind"
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 1' -Name 'a probe that DOES find this repair''s problem does not refuse' -Body {
  # The negative control: if refuse-if-healthy fired unconditionally the repairs would be
  # inert, and every test above would pass for the wrong reason.
  $r = Invoke-FFDryRunSweep -ProbeStatus 'warning' -ProbeFindings @(
    'wu-service-disabled|warning|A service is disabled.'
    'store-cache-corrupt|warning|The store cache is corrupt.'
    'search-index-corrupt|warning|The index is corrupt.'
    'spooler-stopped|warning|The spooler is stopped.'
    'dns-resolution-failed|warning|DNS does not resolve.'
    'component-store-corrupt|critical|The component store is corrupt.'
  )
  # Only the health-probe repairs: the optional-feature and ntp/winget repairs detect locally
  # and are covered by their own tests.
  $notRefusing = @(@($r.rows) | Where-Object { $_.doc.wouldRefuse -ne $true -and "$($_.doc.detection.method)" -eq 'health-probe' })
  Assert-True (@($notRefusing).Count -gt 0) 'at least one repair must accept a matching finding and NOT refuse'
  foreach ($row in @($notRefusing)) {
    Assert-Eq 'problem' "$($row.doc.detection.state)" "$($row.id): a matched finding means state=problem"
    Assert-True (@($row.doc.detection.relevantFindings).Count -gt 0) "$($row.id): and the matching findings are named"
    Assert-Null $row.doc.refusalKind "$($row.id): a repair that would run has no refusal kind"
  }
  Assert-Eq 0 @($r.mutationAttempts).Count 'and even a would-run dry run mutates nothing'
}

# ---------------- restore points and reversibility ----------------

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Name 'every aggressive repair enforces a System Restore checkpoint' -Body {
  $r = Invoke-FFDryRunSweep -ProbeStatus 'ok'
  $aggressive = @(@($r.rows) | Where-Object { $_.tier -eq 'aggressive' })
  Assert-Stop (@($aggressive).Count -gt 0) 'the catalog must still contain aggressive repairs'
  foreach ($row in @($aggressive)) {
    Assert-Eq $true $row.doc.wouldCreateRestorePoint "$($row.id): an aggressive repair must enforce a restore point"
    $first = @($row.doc.steps)[0]
    Assert-Match '(?i)restore' "$($first.name)" "$($row.id): and the checkpoint must be the FIRST step, before anything changes"
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 3' -Name 'reversibility is declared per repair and matches the catalog' -Body {
  $r = Invoke-FFDryRunSweep -ProbeStatus 'ok'
  $cat = Invoke-InEngineScope -Engine 'repair' -Test { $TestCtx.repairs = @(Load-Catalog) }
  $byId = @{}
  foreach ($rep in @($cat.repairs)) { $byId["$($rep.id)"] = $rep }
  foreach ($row in @($r.rows)) {
    $rep = $byId[$row.id]
    Assert-Eq ([bool]$rep.reversible) ([bool]$row.doc.reversible) "$($row.id): the dry run must report the catalog's reversibility"
    Assert-Eq ([bool]$rep.requiresAdmin) ([bool]$row.doc.requiresAdmin) "$($row.id): and the catalog's admin requirement"
    Assert-Eq ([bool]$rep.requiresReboot) ([bool]$row.doc.requiresReboot) "$($row.id): and the catalog's reboot requirement"
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 3' -Name 'undo with an empty ledger is a no-op, never an invented rollback' -Body {
  $sandbox = New-FFSandbox -Label 'undo'
  Set-FFSandboxHealthStub -Sandbox $sandbox -Mode 'json' -Json (New-FFHealthDoc -Status 'ok')
  $res = Invoke-FFEngineProcess -Script (Join-Path $sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'undo', '-Id', 'wu-reset', '-DryRun') -TimeoutMs 60000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 undo (empty ledger)' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the undo document must parse'
  Assert-Eq $true $doc.ok 'an empty ledger is not an error'
  Assert-Eq $true $doc.noop 'it is a no-op'
  Assert-Match 'nothing to undo' "$($doc.message)" 'and it says there is nothing on record to undo'
  Assert-False (Test-Path -LiteralPath (Join-Path (Get-FFSandboxStateDir -Sandbox $sandbox) 'repairs-ledger.json')) 'no ledger file may be created by an undo that found nothing'
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 3' -Name 'the sandbox really is the state root - the ledger assertions are not checking a dead path' -Body {
  # THE ANCHOR for every "no ledger file was created" assertion in this file. Those assertions
  # are only worth anything while the sandbox's data\state is where a sandboxed repair.ps1
  # actually writes. It was NOT, for one round: state moved to an absolute
  # %LOCALAPPDATA%\FrameForge\state, so the sandbox path could never be written and ten
  # assertions passed no matter what the engine did - while the run wrote the INVOKING USER'S
  # real ledger. If repair.ps1's $env:FRAMEFORGE_STATE_DIR contract is ever dropped or renamed,
  # this test fails first and names the reason, instead of the others going quietly vacuous.
  $sandbox = New-FFSandbox -Label 'stateroot'
  $expected = Get-FFSandboxStateDir -Sandbox $sandbox
  Set-FFSandboxHealthStub -Sandbox $sandbox -Mode 'json' -Json (New-FFHealthDoc -Status 'ok')
  $res = Invoke-FFEngineProcess -Script (Join-Path $sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'ledger') -TimeoutMs 60000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 ledger (sandboxed)' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the ledger document must parse'
  Assert-Eq $expected "$($doc.stateDir)" 'a sandboxed repair.ps1 must resolve its state root INSIDE the sandbox'
  Assert-Eq 'env-override' "$($doc.stateDirSource)" 'and must say the override is what put it there'
  Assert-True ("$($doc.ledgerPath)".StartsWith($expected, [System.StringComparison]::OrdinalIgnoreCase)) `
    "the ledger path must be inside the sandbox state root (got '$($doc.ledgerPath)')"
  Assert-Eq 0 ([int]$doc.count) 'a fresh sandbox has an empty ledger - the real one must not have been migrated in'
  Assert-False ([bool]$doc.migration.migrated) 'and the v1 install-tree migration must be SKIPPED under the override'

  # The other half of the same guarantee: nothing outside the run's scratch was resolved.
  Assert-True ("$($doc.stateDir)".StartsWith($script:FFWorkDir, [System.StringComparison]::OrdinalIgnoreCase)) `
    'the resolved state root must be inside this run''s scratch directory'
  Assert-Eq 0 @(Compare-FFRealStateFingerprint).Count `
    "running a sandboxed repair.ps1 must not change the real state: $((@(Compare-FFRealStateFingerprint)) -join '; ')"
}

# ---------------- process-level dry run (the same path, through the real CLI) ----------------

foreach ($row in @(
  @{ Id = 'wu-reset';            Tier = 'standard' }
  @{ Id = 'wu-reset-aggressive'; Tier = 'aggressive' }
  @{ Id = 'sfc-scannow';         Tier = 'standard' }
  @{ Id = 'dism-restorehealth';  Tier = 'standard' }
)) {
  Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Data $row -Name "repair.ps1 -Action run -Id $($row.Id) -DryRun writes nothing (real CLI)" -Body {
    $d = $FFTestData
    $sandbox = New-FFSandbox -Label "dry-$($d.Id)"
    Set-FFSandboxHealthStub -Sandbox $sandbox -Mode 'json' -Json (New-FFHealthDoc -Status 'ok')
    $res = Invoke-FFEngineProcess -Script (Join-Path $sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'run', '-Id', $d.Id, '-DryRun') -TimeoutMs 90000
    $doc = Assert-FFOneJsonDoc -Result $res -Label "repair.ps1 run -Id $($d.Id) -DryRun" -ExpectExit 0
    Assert-Stop ($null -ne $doc) 'the dry-run document must parse'
    Assert-Eq $true  $doc.dryRun  'dryRun must be reported'
    Assert-Eq $false $doc.mutated 'mutated MUST be false'
    $state = Get-FFSandboxStateDir -Sandbox $sandbox
    Assert-False (Test-Path -LiteralPath (Join-Path $state 'repairs-ledger.json')) 'a dry run must not create a ledger file'
    Assert-False (Test-Path -LiteralPath (Join-Path $state 'backups')) 'a dry run must not create a backup directory'
    Assert-Eq 0 @(Compare-FFRealStateFingerprint).Count 'and it must not have written the real ledger either'
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 2' -Name 'a health.ps1 that crashes or emits garbage reads as probe-failure through the real CLI' -Body {
  foreach ($mode in @('garbage', 'empty', 'crash', 'missing')) {
    $sandbox = New-FFSandbox -Label "probe-$mode"
    Set-FFSandboxHealthStub -Sandbox $sandbox -Mode $mode
    $res = Invoke-FFEngineProcess -Script (Join-Path $sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'run', '-Id', 'wu-reset', '-DryRun') -TimeoutMs 60000
    $doc = Assert-FFOneJsonDoc -Result $res -Label "repair.ps1 dry run against a '$mode' health.ps1" -ExpectExit 0
    if ($null -eq $doc) { continue }
    Assert-Eq 'probe-failure' "$($doc.detection.reason)" "a '$mode' health.ps1 must read as a FAILED probe"
    Assert-Eq $true $doc.wouldRefuse "and the repair must refuse ('$mode')"
    Assert-Eq 'indeterminate-probe-failure' "$($doc.refusalKind)" "with the probe-failure refusal kind ('$mode')"
    Assert-Eq $false $doc.mutated "and nothing may be reported as mutated ('$mode')"
  }
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 1' -Name 'preflight is read-only: it reports the commands and writes nothing' -Body {
  $sandbox = New-FFSandbox -Label 'preflight'
  Set-FFSandboxHealthStub -Sandbox $sandbox -Mode 'json' -Json (New-FFHealthDoc -Status 'warning' -Findings @('wu-service-disabled|warning|A service is disabled.'))
  $res = Invoke-FFEngineProcess -Script (Join-Path $sandbox 'engine\repair.ps1') -EngineArgs @('-Action', 'preflight', '-Id', 'wu-reset') -TimeoutMs 60000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'repair.ps1 preflight' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the preflight document must parse'
  Assert-NotNull $doc.detection 'preflight must report detection'
  Assert-True (@($doc.steps).Count -gt 0) 'and the exact commands that would run'
  Assert-False (Test-Path -LiteralPath (Join-Path (Get-FFSandboxStateDir -Sandbox $sandbox) 'repairs-ledger.json')) 'preflight must not write a ledger entry'
}

# ---------------- image.ps1: the consent gate ----------------

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Name 'image.ps1 launch WITHOUT -Confirm never executes anything' -Body {
  $media = New-FFFakeMedia
  $res = Invoke-FFEngineProcess -Script (Join-Path $FFEngines 'image.ps1') -EngineArgs @('-Action', 'launch', '-SourcePath', $media) -TimeoutMs 90000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'image.ps1 launch (no -Confirm)' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the launch document must parse'
  Assert-Eq 'consent-contract' "$($doc.mode)" 'without -Confirm the action is contract-only'
  Assert-Eq $false $doc.executed 'nothing may be executed'
  Assert-Null $doc.setupPid 'and no setup process id may be reported'
  Assert-NotNull $doc.command 'the exact command is shown instead'
  Assert-Match '/eula accept' "$($doc.command)" 'including the EULA switch it would pass, stated openly'
  Assert-NotNull $doc.contract 'the consent contract must be returned'
  Assert-Match '-Confirm' "$($doc.howToExecute)" 'and the instructions must name the explicit consent switch'
  Assert-True (@($doc.blockers).Count -gt 0) 'the blockers standing between here and a launch must be listed'
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Name 'image.ps1 consent is read-only and admits it passes /eula accept' -Body {
  $res = Invoke-FFEngineProcess -Script (Join-Path $FFEngines 'image.ps1') -EngineArgs @('-Action', 'consent') -TimeoutMs 90000
  $doc = Assert-FFOneJsonDoc -Result $res -Label 'image.ps1 consent' -ExpectExit 0
  Assert-Stop ($null -ne $doc) 'the consent document must parse'
  Assert-Eq $false $doc.executed 'the consent action executes nothing'
  Assert-Match 'nothing was mounted' "$($doc.note)" 'and says nothing was mounted or started'
  Assert-Match '/eula accept' "$($doc.commandsThatRequireThisConsent.preflightCompatScan)" 'the pre-flight scan admits it passes /eula accept'
  Assert-Match '/eula accept' "$($doc.commandsThatRequireThisConsent.repairInstall)" 'and so does the repair itself'
  Assert-Match 'does not accept them for you' "$($doc.contract.eulaNote)" 'the contract must say FrameForge does not accept the terms on the user''s behalf'
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 4' -Name 'image.ps1: every place that starts setup.exe sits behind its own consent gate' -Body {
  # A structural check rather than an executed one: the suite will never pass -Confirm or
  # -AcceptEula, so the guarantee is read off the source. image.ps1 starts Windows Setup in
  # exactly two places, and BOTH are consent-gated:
  #   preflight  the /compat scanonly dress rehearsal, behind -AcceptEula (it passes /eula accept)
  #   launch     the repair install itself, behind -Confirm
  # Pinning the count to two means a third, ungated call site fails this test on sight.
  $src = Get-FFEngineSource -Engine 'image'
  $starts = [regex]::Matches($src, [regex]::Escape('Start-Process -FilePath $setupExe'))
  Assert-Eq 2 $starts.Count 'setup.exe may be started from exactly two places - preflight and launch'

  $preflightIdx = $src.IndexOf("'preflight' {")
  $launchIdx = $src.IndexOf("'launch' {")
  Assert-Stop ($preflightIdx -gt 0 -and $launchIdx -gt $preflightIdx) 'both actions must be locatable, preflight first'

  # launch: the start must come AFTER `if (-not $Confirm -or $DryRun) { ... break }`.
  $launchGate = $src.IndexOf('if (-not $Confirm -or $DryRun)', $launchIdx)
  $launchStart = $src.IndexOf('Start-Process -FilePath $setupExe -ArgumentList $launchArgs', $launchIdx)
  Assert-Stop ($launchGate -gt $launchIdx) 'the launch action must carry the -Confirm gate'
  Assert-Stop ($launchStart -gt 0) 'the launch action must contain the setup.exe start'
  Assert-True ($launchStart -gt $launchGate) 'setup.exe may only be launched AFTER the -Confirm gate has been passed'

  # preflight: the scan start must come AFTER both the -DryRun and the -AcceptEula branches.
  $eulaGate = $src.IndexOf('elseif (-not $AcceptEula)', $preflightIdx)
  $scanStart = $src.IndexOf('Start-Process -FilePath $setupExe -ArgumentList $scanArgs', $preflightIdx)
  Assert-Stop ($eulaGate -gt $preflightIdx -and $eulaGate -lt $launchIdx) 'pre-flight must carry the -AcceptEula gate'
  Assert-Stop ($scanStart -gt 0 -and $scanStart -lt $launchIdx) 'pre-flight must contain the compat-scan start'
  Assert-True ($scanStart -gt $eulaGate) 'the compat scan may only run AFTER the EULA consent gate'

  # And neither switch may have a default that makes the gate vacuous.
  Assert-Match '(?m)^\s*\[switch\]\$Confirm,' $src '-Confirm must be a switch, off by default'
  Assert-Match '(?m)^\s*\[switch\]\$AcceptEula,' $src '-AcceptEula must be a switch, off by default'
}

Register-FFTest -Area 'SAFETY' -Doctrine 'rule 5' -Name 'the catalog never claims an aggressive repair is reversible for free' -Body {
  $r = Invoke-InEngineScope -Engine 'repair' -Test { $TestCtx.repairs = @(Load-Catalog) }
  foreach ($rep in @($r.repairs)) {
    if (-not $rep.reversible) {
      Assert-Match '\S' "$($rep.summary)" "$($rep.id): an irreversible repair must still explain itself"
    }
    if ("$($rep.tier)" -eq 'aggressive') {
      Assert-Ne 'none' "$($rep.restorePoint)" "$($rep.id): an aggressive repair must not opt out of the restore point in the catalog"
    }
  }
}
