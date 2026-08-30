<#
  FrameForge :: engine/test/lib/harness.ps1

  The test harness. Dot-sourced by run-tests.ps1 BEFORE any case file.

  WHAT THIS IS FOR
  ----------------
  The engines have to be right on the whole Windows 11 population - every UI language,
  every SKU, every build, and every broken state - but the only machine available is one
  en-US Windows 11 Pro desktop, unelevated, on which NOTHING may be mutated. So the suite
  fakes the environment instead of visiting it:

    1. IN-PROCESS FUNCTION SHADOWING (Invoke-InEngineScope). The engine's function
       definitions are loaded into a private scope with its `param()` block and its
       trailing dispatch/`exit` removed. Stub functions are then defined in that SAME
       scope AFTER the engine body, so they shadow both the engine's own helpers and
       Windows cmdlets (Get-Content, Get-ItemProperty, Get-WinEvent, Get-Service, ...).
       The engine files themselves are never touched, and no real command runs.

    2. CHILD PROCESSES IN A SANDBOX (New-FFSandbox / Invoke-FFEngineProcess). For the
       stdout/exit-code contract, the engines run for real - but from a COPY of the tree
       in %TEMP%, where health.ps1 can be swapped for a stub that emits a chosen JSON
       document and where the repair ledger writes to the sandbox's own data\state.

    3. A REDIRECTED PROFILE. Copying the tree is not enough on its own: the engines resolve
       their runtime state to an ABSOLUTE %LOCALAPPDATA%\FrameForge\state, which is the same
       directory whether the engine ran from the real tree or from a sandbox. $env:LOCALAPPDATA
       and repair.ps1's $env:FRAMEFORGE_STATE_DIR are therefore both redirected into this run's
       scratch - see the long note above Initialize-FFWorkDir - and the real state is
       fingerprinted before the run and re-checked after it.

  SAFETY
  ------
  Invoke-FFEngineProcess enforces a hard denylist (Assert-FFSafeArgs) that refuses to
  launch any mutating engine invocation - `repair.ps1 -Action run` without -DryRun,
  image.ps1 download / -Confirm / -AcceptEula / -ConsentRunFido, engine.ps1 apply /
  revert / restore-point, nvidia.ps1 apply-*/restore/snapshot, and anything carrying
  -Force. The denylist is itself covered by a test (cases/60-safety.ps1). Everything the
  suite writes lives under %TEMP%\frameforge-engine-tests\run-<pid>-<stamp>-<guid> - one
  private directory PER RUN, deleted at the end - so concurrent or back-to-back runs
  cannot delete each other's composed shims or sandboxes. That claim is ENFORCED, not
  asserted: Get-FFRealStateFingerprint hashes the install tree's data\state and the real
  %LOCALAPPDATA%\FrameForge before the redirect, and run-tests.ps1 fails the run if a single
  byte of either moved.

  PowerShell 5.1 compatible. ASCII only, so PS 5.1 cannot mis-decode this file; every
  non-ASCII byte the suite needs lives in fixtures\ and is read with -Encoding UTF8.
#>

Set-StrictMode -Off

# ---------------- paths ----------------

$script:FFTestRoot   = Split-Path -Parent $PSScriptRoot
$script:FFEngineDir  = Split-Path -Parent $script:FFTestRoot
$script:FFRepoRoot   = Split-Path -Parent $script:FFEngineDir
$script:FFFixtureDir = Join-Path $script:FFTestRoot 'fixtures'
$script:FFPwsh       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ---- per-run isolation -------------------------------------------------------------
# The work dir used to be a FIXED shared path that Initialize-FFWorkDir deleted and
# recreated. Two runs of the suite - sequential or concurrent - therefore shared one
# directory, and each new run deleted the composed engine shims the other was still
# dot-sourcing mid-run. PROVEN before this change: two concurrent invocations produced
# 34 spurious "The term '...harness-_lib-765569440.ps1' is not recognized" failures.
# Every run now gets its own directory and its own shim names, so a green run means
# something and runs cannot see (or destroy) each other's scratch.
$script:FFRunToken = '{0}-{1}-{2}' -f $PID,
                                      (Get-Date).ToString('yyyyMMddHHmmssfff'),
                                      ([guid]::NewGuid().ToString('N').Substring(0, 8))
$script:FFWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'frameforge-engine-tests'
$script:FFWorkDir  = Join-Path $script:FFWorkRoot ('run-' + $script:FFRunToken)

function Remove-FFStaleWorkDirs {
  <#
    Best-effort reaping of work dirs left behind by runs that were killed before their
    own cleanup. A dir is only removed when its owning PID is gone AND it is older than
    -MinAgeMinutes, so a run in progress - including a concurrent one that started
    seconds ago under a recycled PID - is never touched. Failures are ignored: this is
    housekeeping, never a gate.
  #>
  param([int]$MinAgeMinutes = 30)
  if (-not (Test-Path -LiteralPath $script:FFWorkRoot)) { return }
  $cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
  $dirs = @()
  try { $dirs = @(Get-ChildItem -LiteralPath $script:FFWorkRoot -Directory -Filter 'run-*' -ErrorAction Stop) } catch { return }
  foreach ($d in $dirs) {
    if ($d.FullName -eq $script:FFWorkDir) { continue }
    if ($d.LastWriteTime -gt $cutoff) { continue }
    $ownerPid = 0
    if ($d.Name -match '^run-(\d+)-') { $ownerPid = [int]$Matches[1] }
    if ($ownerPid -gt 0) {
      $alive = $null
      try { $alive = Get-Process -Id $ownerPid -ErrorAction Stop } catch { $alive = $null }
      if ($null -ne $alive) { continue }
    }
    try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch {}
  }
}

# ---- the machine's REAL runtime state, and the redirect that keeps the suite off it ----
#
# The engines deliberately keep runtime state OUT of the install tree: repair.ps1, engine.ps1
# and nvidia.ps1 all resolve it to %LOCALAPPDATA%\FrameForge\state. That is right for the
# product and it broke the suite's sandbox, because New-FFSandbox only relocates the TREE:
# an absolute %LOCALAPPDATA% path is the same path from inside the sandbox as from outside.
# Measured before this fix, on the developer's own machine: a suite run created
# %LOCALAPPDATA%\FrameForge\state, copied the real data\state\repairs-ledger.json into it
# (nvidia.ps1 and engine.ps1 create the folder unconditionally at load; repair.ps1 migrates
# the v1 ledger into it), and the ten SAFETY assertions of the form
#   Assert-False (Test-Path "<sandbox>\data\state\repairs-ledger.json")
# were checking a path no engine could ever write - they passed regardless of behaviour.
#
# Two redirects, belt and braces, both of them contracts the engines already document:
#   1. $env:LOCALAPPDATA -> this run's scratch. Every engine derives its state root from it,
#      including the two that have no override, so nothing lands on the real profile.
#   2. $env:FRAMEFORGE_STATE_DIR -> repair.ps1's explicit override (see its header). Set per
#      SANDBOX to "<sandbox>\data\state", which is what puts the ledger back where those ten
#      assertions look for it. Under the override repair.ps1 skips the v1 migration, so the
#      real data\state\repairs-ledger.json is not even read.
# Both are set on the SUITE PROCESS, so in-process engine scopes (Invoke-InEngineScope) get
# them too and child processes inherit them; Invoke-FFEngineProcess then narrows #2 per call.
$script:FFRealLocalAppData = $env:LOCALAPPDATA
$script:FFRealStateBefore = $null
$script:FFFakeLocalAppData = $null

function Get-FFProtectedPaths {
  <# The paths a suite run must leave byte-identical. The install tree's data\state holds a
     real historical repair record; %LOCALAPPDATA%\FrameForge is the live per-user state. #>
  @(
    (Join-Path $script:FFRepoRoot 'data\state'),
    $(if ($script:FFRealLocalAppData) { (($script:FFRealLocalAppData.TrimEnd('\')) + '\FrameForge') } else { $null })
  ) | Where-Object { $_ }
}

function Get-FFRealStateFingerprint {
  <# path -> SHA256 (or a marker for a missing path), for every file under Get-FFProtectedPaths.
     Compared before and after the run: this is what makes the header's read-only claim a
     MEASUREMENT rather than a promise.

     -Paths exists so cases\65-sabotage.ps1 can run this exact code over a scratch directory it
     is allowed to change, and prove the comparison actually fires. A gate nobody has seen go
     red is not a gate. #>
  param([string[]]$Paths)
  if (-not $Paths) { $Paths = @(Get-FFProtectedPaths) }
  $map = [ordered]@{}
  foreach ($root in $Paths) {
    if (-not (Test-Path -LiteralPath $root)) { $map[$root] = '<absent>'; continue }
    $map[$root] = '<present>'
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop) } catch { $map[$root] = "<unreadable: $($_.Exception.Message)>"; continue }
    foreach ($f in ($files | Sort-Object FullName)) {
      $h = '<unreadable>'
      try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
      $map[$f.FullName] = $h
    }
  }
  $map
}

function Compare-FFRealStateFingerprint {
  <# Returns the list of differences between the fingerprint taken at Initialize-FFWorkDir and
     one taken now. Empty means the run touched nothing outside its own scratch.
     -Before / -Paths are for the test that proves this comparison works; the gate itself
     passes neither. #>
  param($Before, [string[]]$Paths)
  $now = Get-FFRealStateFingerprint -Paths $Paths
  $before = $(if ($null -ne $Before) { $Before } else { $script:FFRealStateBefore })
  $diffs = @()
  if ($null -eq $before) { return @('the before-fingerprint was never taken') }
  foreach ($k in @($before.Keys)) {
    if (-not $now.Contains($k)) { $diffs += "DELETED  $k"; continue }
    if ("$($now[$k])" -ne "$($before[$k])") { $diffs += "MODIFIED $k" }
  }
  foreach ($k in @($now.Keys)) { if (-not $before.Contains($k)) { $diffs += "CREATED  $k" } }
  @($diffs)
}

function Initialize-FFWorkDir {
  <# Creates THIS run's private scratch directory. It never deletes anything another run
     could be using: the only path it removes is its own, and its own is unique. #>
  if (Test-Path -LiteralPath $script:FFWorkDir) {
    # Cannot happen (PID + ms timestamp + guid), but if it somehow did, a stale dir here
    # would silently poison the run - so refuse rather than reuse.
    throw "Work dir already exists, refusing to reuse it: $script:FFWorkDir"
  }
  New-Item -ItemType Directory -Force -Path $script:FFWorkDir | Out-Null
  # The fingerprint is taken BEFORE the redirect, against the real paths, so the comparison at
  # the end of the run is against the machine as it actually was.
  $script:FFRealStateBefore = Get-FFRealStateFingerprint
  $script:FFFakeLocalAppData = Join-Path $script:FFWorkDir 'localappdata'
  New-Item -ItemType Directory -Force -Path $script:FFFakeLocalAppData | Out-Null
  $env:LOCALAPPDATA = $script:FFFakeLocalAppData
  $env:FRAMEFORGE_STATE_DIR = (Join-Path $script:FFFakeLocalAppData 'FrameForge\state')
  Remove-FFStaleWorkDirs
}

function Get-FFSandboxStateDir {
  <# Where a SANDBOXED engine's runtime state must land: the sandbox's own data\state, which
     is the path cases\60-safety.ps1 asserts against. #>
  param([Parameter(Mandatory)][string]$Sandbox)
  Join-Path $Sandbox 'data\state'
}
function Remove-FFWorkDir {
  try { Remove-Item -LiteralPath $script:FFWorkDir -Recurse -Force -ErrorAction Stop } catch {}
  # Drop the shared parent too, but only when THIS run left it empty - a concurrent run's
  # directory inside it makes the delete fail, which is exactly the wanted outcome.
  try {
    if (Test-Path -LiteralPath $script:FFWorkRoot) {
      if (@(Get-ChildItem -LiteralPath $script:FFWorkRoot -Force -ErrorAction Stop).Count -eq 0) {
        Remove-Item -LiteralPath $script:FFWorkRoot -Force -ErrorAction Stop
      }
    }
  } catch {}
}

function Get-FFFixture {
  <# Raw text of a fixture file. UTF8 is explicit: the localized fixtures are the
     whole point of the suite and PS 5.1 would otherwise decode them as ANSI. #>
  param([Parameter(Mandatory)][string]$Path)
  $p = Join-Path $script:FFFixtureDir $Path
  if (-not (Test-Path -LiteralPath $p)) { throw "Fixture not found: $p" }
  Get-Content -LiteralPath $p -Raw -Encoding UTF8
}

function Get-FFFixtureLines {
  <# Fixture as an array of lines, with @@TS@@ replaced by a CBS-style local timestamp.
     -AgeMinutes shifts that timestamp into the past so a test can prove the engine
     refuses to attribute a stale log entry to the run it just made. #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [double]$AgeMinutes = 0
  )
  $stamp = (Get-Date).AddMinutes(-$AgeMinutes).ToString('yyyy-MM-dd HH:mm:ss')
  $text = Get-FFFixture -Path $Path
  @(($text -replace '@@TS@@', $stamp) -split "`r?`n" | Where-Object { "$_" -match '\S' })
}

# ---------------- test registry ----------------

$script:FFSuite = New-Object System.Collections.ArrayList

function Register-FFTest {
  <#
    -Area      grouping shown in the summary (LOCALE / SKU / BUILD / STATE / CONTRACT / SAFETY)
    -Doctrine  which rule of docs/GAUNTLET.md this test defends, for the report
    -Xfail     non-empty => this asserts CORRECT behaviour that the engine does NOT yet
               have. It is reported as an ENGINE DEFECT and does not fail the suite; if it
               ever passes it is reported as XPASS and DOES fail, so the marker cannot rot.
    -Slow      only runs without -Quick.
    -Data      per-test payload, readable inside the body as $FFTestData. This is how a
               table-driven `foreach` registers one test per row: a plain closure over the
               loop variable would give every body the LAST row (PowerShell scriptblocks
               capture the variable, not its value), and .GetNewClosure() would rebind the
               body to a module scope where the harness functions are no longer visible.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Area,
    [Parameter(Mandatory)][scriptblock]$Body,
    [string]$Doctrine = '',
    [string]$Xfail = '',
    [switch]$Slow,
    $Data = $null
  )
  $null = $script:FFSuite.Add([pscustomobject]@{
    Name = $Name; Area = $Area; Body = $Body; Doctrine = $Doctrine
    Xfail = $Xfail; Slow = [bool]$Slow; Data = $Data; File = $script:FFCurrentCaseFile
  })
}

# Set by the runner immediately before each body; read inside a body as $FFTestData.
$script:FFTestData = $null

# ---------------- run verdict (THE CI CONTRACT) ----------------
# Lifted out of run-tests.ps1 so the contract is a function the suite can test rather than
# inline arithmetic nobody checks. The change this encodes:
#
#   A test carrying an -Xfail narrative asserts CORRECT behaviour the engine does not have.
#   The suite used to print it, exit 0 and say "RESULT: PASS" - so a CI gate on
#   `npm run test:engine` was green over reproduced, live doctrine-2 violations. It now FAILS
#   the run by default. -AllowKnownDefects restores the old tolerant reporting for local
#   iteration ONLY; CI and release must never pass it, and run-tests.ps1 says so in its banner.
#
# XPASS still fails: a narrative describing a defect that no longer exists is a lie about the
# engine, and the marker has to be deleted when the fix lands.

function Get-FFTestState {
  param(
    [bool]$Threw = $false,
    [int]$AssertCount = 0,
    [int]$FailedCount = 0,
    [string]$KnownDefect = '',
    [switch]$AllowKnownDefects
  )
  if ($AssertCount -eq 0 -and -not $Threw) { return 'EMPTY' }
  $clean = ((-not $Threw) -and $FailedCount -eq 0 -and $AssertCount -gt 0)
  if ("$KnownDefect" -match '\S') {
    if ($clean) { return 'XPASS' }
    if ($AllowKnownDefects) { return 'DEFECT' }
    return 'FAIL'
  }
  if ($clean) { return 'PASS' }
  return 'FAIL'
}

function Test-FFStateIsFailure {
  param([Parameter(Mandatory)][string]$State)
  return (@('FAIL', 'XPASS', 'EMPTY') -contains $State)
}

function Get-FFSuiteExitCode {
  param([string[]]$States)
  foreach ($s in @($States)) { if (Test-FFStateIsFailure $s) { return 1 } }
  return 0
}

# ---------------- assertions ----------------
# Assertions RECORD and continue, so one case reports every way it is wrong rather than
# only the first. Assert-Stop throws when continuing would be meaningless.

$script:FFAsserts = $null

function Add-FFAssert {
  param([bool]$Ok, [string]$Text)
  if ($null -eq $script:FFAsserts) { return }
  $null = $script:FFAsserts.Add([pscustomobject]@{ Ok = $Ok; Text = $Text })
}

function Measure-FFAsserts {
  <#
    Runs -Body against a PRIVATE assertion list and returns @{ total; failed; texts; threw }
    WITHOUT adding anything to the running test's own list.

    This exists for one purpose: the SABOTAGE cases. "The suite would catch it" is a claim,
    and the only way to test a claim about an assertion is to run that assertion against a
    deliberately broken engine and check that it FAILED. Both sides call the same shared
    Assert-* function, so a sabotage test can never drift away from the assertion it is
    supposed to be vouching for.
  #>
  param([Parameter(Mandatory)][scriptblock]$Body)
  $saved = $script:FFAsserts
  $script:FFAsserts = New-Object System.Collections.ArrayList
  $threw = $null
  try { $null = & $Body } catch { $threw = "$($_.Exception.Message)" }
  $mine = @($script:FFAsserts)
  $script:FFAsserts = $saved
  $failed = @($mine | Where-Object { -not $_.Ok })
  [pscustomobject]@{
    total = $mine.Count; failed = $failed.Count; threw = $threw
    texts = @($failed | ForEach-Object { $_.Text })
  }
}

function Format-FFValue {
  param($Value)
  if ($null -eq $Value) { return '<null>' }
  if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
  if ($Value -is [System.Array]) { return '@(' + ((@($Value) | ForEach-Object { Format-FFValue $_ }) -join ', ') + ')' }
  $s = "$Value"
  if ($s.Length -gt 220) { $s = $s.Substring(0, 220) + '...' }
  if ($s -eq '') { return "''" }
  $s
}

function Assert-True {
  param($Condition, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ([bool]$Condition) "$Because (got: $(Format-FFValue $Condition))"
}
function Assert-False {
  param($Condition, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert (-not [bool]$Condition) "$Because (got: $(Format-FFValue $Condition))"
}
function Assert-Eq {
  param($Expected, $Actual, [Parameter(Mandatory)][string]$Because)
  $ok = ($null -eq $Expected -and $null -eq $Actual)
  if (-not $ok) { $ok = ($null -ne $Expected -and $null -ne $Actual -and "$Expected" -ceq "$Actual") }
  Add-FFAssert $ok "$Because (expected: $(Format-FFValue $Expected); got: $(Format-FFValue $Actual))"
}
function Assert-Ne {
  param($NotExpected, $Actual, [Parameter(Mandatory)][string]$Because)
  $same = ($null -eq $NotExpected -and $null -eq $Actual)
  if (-not $same) { $same = ($null -ne $NotExpected -and $null -ne $Actual -and "$NotExpected" -ceq "$Actual") }
  Add-FFAssert (-not $same) "$Because (must NOT be: $(Format-FFValue $NotExpected); got: $(Format-FFValue $Actual))"
}
function Assert-Null {
  param($Value, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ($null -eq $Value) "$Because (got: $(Format-FFValue $Value))"
}
function Assert-NotNull {
  param($Value, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ($null -ne $Value) "$Because (got: <null>)"
}
function Assert-Match {
  param([Parameter(Mandatory)][string]$Pattern, $Text, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ("$Text" -match $Pattern) "$Because (pattern /$Pattern/ against: $(Format-FFValue $Text))"
}
function Assert-NoMatch {
  param([Parameter(Mandatory)][string]$Pattern, $Text, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert (-not ("$Text" -match $Pattern)) "$Because (pattern /$Pattern/ must NOT match: $(Format-FFValue $Text))"
}
function Assert-In {
  param($Value, [Parameter(Mandatory)]$Allowed, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert (@($Allowed) -contains $Value) "$Because (allowed: $(Format-FFValue $Allowed); got: $(Format-FFValue $Value))"
}
function Assert-NotIn {
  param($Value, [Parameter(Mandatory)]$Forbidden, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert (-not (@($Forbidden) -contains $Value)) "$Because (forbidden: $(Format-FFValue $Forbidden); got: $(Format-FFValue $Value))"
}
function Assert-Throws {
  param([Parameter(Mandatory)][scriptblock]$Script, [Parameter(Mandatory)][string]$Because, [string]$Pattern = '')
  $threw = $false; $msg = ''
  try { $null = & $Script } catch { $threw = $true; $msg = "$($_.Exception.Message)" }
  if ($threw -and $Pattern) { Add-FFAssert ($msg -match $Pattern) "$Because - message /$Pattern/ (got: $msg)" }
  else { Add-FFAssert $threw "$Because (no exception was thrown)" }
}
function Assert-Stop {
  <# A precondition: if this is wrong, the rest of the case would only report noise. #>
  param($Condition, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ([bool]$Condition) "$Because (got: $(Format-FFValue $Condition))"
  if (-not $Condition) { throw "PRECONDITION FAILED: $Because" }
}

# The doctrine assertion this whole suite exists for: a signal that could not be read must
# come back as "could not determine", never as a confident value.
function Assert-HonestUnknown {
  param($Value, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ($null -eq $Value) "DOCTRINE 2 - $Because must be an honest unknown (`$null), not a confident answer (got: $(Format-FFValue $Value))"
}

# A health.ps1 category may never resolve to 'ok' when a signal was not read.
function Assert-NotGraded-Ok {
  param($Status, [Parameter(Mandatory)][string]$Because)
  Add-FFAssert ("$Status" -ne 'ok') "DOCTRINE 2 - $Because must not be graded 'ok' (got: $(Format-FFValue $Status))"
}

# ---------------- engine loading (in-process, function-shadowed) ----------------

$script:FFEngineHarnessCache = @{}

function Get-FFEngineHarnessScript {
  <#
    Builds (once per run, then cached) a runnable copy of an engine that contains its
    FUNCTIONS and top-level setup but NOT its param() block and NOT its dispatch tail -
    so nothing is executed and nothing calls `exit`.

    The param block and the cut point are located with the PowerShell PARSER, not with
    regexes over the source, so brace/paren counting cannot go wrong. $PSScriptRoot is
    rewritten to a literal, because the composed file lives in %TEMP% while the engine
    still has to find _lib.ps1, data\*.json and health.ps1 in the real tree (or in a
    sandbox, when -EngineDir is given).

    The real engine files are never modified.
  #>
  param(
    [Parameter(Mandatory)][string]$Engine,
    [string]$EngineDir
  )
  if (-not $EngineDir) { $EngineDir = $script:FFEngineDir }
  $key = "$Engine|$EngineDir"
  if ($script:FFEngineHarnessCache.ContainsKey($key)) { return $script:FFEngineHarnessCache[$key] }

  $src = Join-Path $EngineDir "$Engine.ps1"
  if (-not (Test-Path -LiteralPath $src)) { throw "Engine not found: $src" }
  $text = Get-Content -LiteralPath $src -Raw -Encoding UTF8

  # 1) Cut the dispatch tail. '$out = $null' at the start of a line is the first statement
  #    of the dispatch section in health.ps1, repair.ps1 and image.ps1 alike, and is unique
  #    in each. _lib.ps1 has no tail to cut.
  $m = [regex]::Match($text, '(?m)^\$out = \$null\s*$')
  if ($m.Success) { $text = $text.Substring(0, $m.Index) }

  # 2) Remove the param() block (with its attributes) using the AST.
  $tokens = $null; $perrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$perrors)
  if ($null -ne $ast.ParamBlock) {
    $pb = $ast.ParamBlock.Extent
    $text = $text.Substring(0, $pb.StartOffset) + $text.Substring($pb.EndOffset)
  }
  $text = $text -replace '(?m)^\s*\[CmdletBinding\(\)\]\s*$', ''

  # 3) $PSScriptRoot -> a literal this composed file can rely on.
  $text = $text -replace '\$PSScriptRoot', "`$FFEngineRoot"

  $prelude = @"
param(`$__mocks, `$__test, `$TestCtx)
Set-StrictMode -Off
`$ErrorActionPreference = 'SilentlyContinue'
`$ProgressPreference    = 'SilentlyContinue'
`$FFEngineRoot = '$($EngineDir -replace "'","''")'
# Stand-ins for the removed param() block. A test overrides any of these from its -Mocks
# block, which is dot-sourced into this same scope AFTER the engine body.
`$Action = 'list'; `$Category = `$null; `$Deep = `$false; `$Json = `$false
`$Id = `$null; `$DryRun = `$false; `$Force = `$false; `$NoRestorePoint = `$false
`$SourcePath = `$null; `$DnsProvider = 'cloudflare'
`$IsoPath = `$null; `$Url = `$null; `$Dest = `$null; `$Index = '0'
`$AcceptEula = `$false; `$Confirm = `$false; `$ConsentRunFido = `$false
`$FidoSha256 = `$null; `$SuspendBitLocker = `$false; `$AllowFeatureUpdate = `$false

"@
  $epilogue = @"

# ---- test stubs (defined last so they shadow the engine's own helpers and cmdlets) ----
. `$__mocks
# ---- the case body ----
. `$__test
"@

  # The shim name carries THIS run's token as well as a per-shim guid: the old name was a
  # deterministic hash of the engine directory, so two runs sharing the (then fixed) work
  # dir composed the very same path and each one's cleanup deleted the other's shim.
  $outPath = Join-Path $script:FFWorkDir ("harness-$Engine-" + [Math]::Abs($EngineDir.GetHashCode()) + '-' + $script:FFRunToken + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.ps1')
  # UTF8 WITH BOM: the engines contain non-ASCII copy and PS 5.1 needs the BOM to decode it.
  $enc = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($outPath, ($prelude + $text + $epilogue), $enc)
  $script:FFEngineHarnessCache[$key] = $outPath
  return $outPath
}

function Invoke-InEngineScope {
  <#
    Runs -Test inside a scope that holds the engine's real functions plus whatever -Mocks
    defines (mocks win, being defined last). Results travel back through the $TestCtx
    hashtable, which both scriptblocks see as $TestCtx - stdout is discarded so stray
    engine output cannot masquerade as a result.
  #>
  param(
    [Parameter(Mandatory)][string]$Engine,
    [scriptblock]$Mocks = {},
    [Parameter(Mandatory)][scriptblock]$Test,
    [hashtable]$Ctx,
    [string]$EngineDir
  )
  if ($null -eq $Ctx) { $Ctx = @{} }
  $path = Get-FFEngineHarnessScript -Engine $Engine -EngineDir $EngineDir
  $null = & $path $Mocks $Test $Ctx
  return $Ctx
}

# ---------------- stub factories ----------------

function New-FFNativeResult {
  <# The shape Invoke-FFNative returns, for stubbing a console tool's output. #>
  param([string]$Text = '', [object]$ExitCode = 0, [string]$Error = $null)
  [ordered]@{ exitCode = $ExitCode; stdout = $Text; stderr = ''; text = $Text; error = $Error }
}

function New-FFEventRecord {
  <# Enough of a Get-WinEvent record for the engine's readers (Id / TimeCreated /
     ProviderName / Message / ToXml for Get-FFEventDataMap). #>
  param(
    [int]$Id = 35,
    [datetime]$TimeCreated = (Get-Date),
    [string]$ProviderName = 'Microsoft-Windows-Time-Service',
    [string]$Message = 'The time provider NtpClient is currently receiving valid time data.',
    [hashtable]$Data = $null
  )
  $xmlData = ''
  if ($null -ne $Data) {
    foreach ($k in $Data.Keys) {
      $v = [System.Security.SecurityElement]::Escape("$($Data[$k])")
      $xmlData += "<Data Name='$k'>$v</Data>"
    }
  }
  $xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID>$Id</EventID><Provider Name='$ProviderName'/></System><EventData>$xmlData</EventData></Event>"
  $o = New-Object psobject
  $o | Add-Member NoteProperty Id $Id
  $o | Add-Member NoteProperty TimeCreated $TimeCreated
  $o | Add-Member NoteProperty ProviderName $ProviderName
  $o | Add-Member NoteProperty Message $Message
  $o | Add-Member ScriptMethod ToXml { $this.__Xml }
  $o | Add-Member NoteProperty __Xml $xml
  $o
}

function New-FFErrorRecord {
  <#
    An ErrorRecord that classifies the way a real one does. -Kind picks the identity the
    engines actually key on (FullyQualifiedErrorId / exception type / HRESULT), never the
    message text - which is the entire point of Get-FFEventErrorKind and Test-FFAccessDenied.
  #>
  param(
    [ValidateSet('no-events','log-missing','provider-missing','access-denied','hresult-denied','not-found','service-not-found','other')]
    [string]$Kind = 'other',
    [string]$Message = 'stub failure'
  )
  $ex = $null; $fqid = 'StubError'
  switch ($Kind) {
    # What Get-Service -ErrorAction Stop raises when the service genuinely does not exist -
    # `sc delete wuauserv`, which is what the debloat scripts do. health.ps1 keys on this
    # FullyQualifiedErrorId, NEVER on the message, so a stub that merely `throw`s a string is
    # an UNCLASSIFIABLE query failure and is correctly read as "nothing was measured".
    'service-not-found' { $ex = New-Object System.Exception($Message); $fqid = 'NoServiceFoundForGivenName,Microsoft.PowerShell.Commands.GetServiceCommand' }
    'no-events'        { $ex = New-Object System.Exception($Message); $fqid = 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand' }
    'log-missing'      { $ex = New-Object System.Diagnostics.Eventing.Reader.EventLogNotFoundException($Message); $fqid = 'NoMatchingLogsFound,Microsoft.PowerShell.Commands.GetWinEventCommand' }
    'provider-missing' { $ex = New-Object System.Exception($Message); $fqid = 'NoMatchingProvidersFound,Microsoft.PowerShell.Commands.GetWinEventCommand' }
    'access-denied'    { $ex = New-Object System.UnauthorizedAccessException($Message); $fqid = 'UnauthorizedAccessException,Microsoft.PowerShell.Commands.GetWinEventCommand' }
    'hresult-denied'   {
      $ex = New-Object System.Exception($Message)
      # 0x80070005 = FACILITY_WIN32 + ERROR_ACCESS_DENIED. HResult is settable via reflection.
      try {
        $f = [System.Exception].GetField('_HResult', [System.Reflection.BindingFlags]'NonPublic,Instance')
        if ($null -eq $f) { $f = [System.Exception].GetField('m_HResult', [System.Reflection.BindingFlags]'NonPublic,Instance') }
        if ($null -ne $f) { $f.SetValue($ex, [int]-2147024891) }
      } catch {}
      $fqid = 'HResultDenied'
    }
    'not-found'        { $ex = New-Object System.IO.FileNotFoundException($Message); $fqid = 'PathNotFound' }
    default            { $ex = New-Object System.Exception($Message) }
  }
  $rec = New-Object System.Management.Automation.ErrorRecord($ex, $fqid, [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
  if ($Kind -eq 'access-denied') {
    $rec = New-Object System.Management.Automation.ErrorRecord($ex, $fqid, [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
  }
  if ($Kind -eq 'service-not-found') {
    $rec = New-Object System.Management.Automation.ErrorRecord($ex, $fqid, [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
  }
  $rec
}

# A stand-in for Microsoft.Management.Infrastructure.CimException: the engines classify CIM
# failures by the STRUCTURED NativeErrorCode ('InvalidNamespace', 'InvalidClass', 5 for
# ERROR_ACCESS_DENIED) rather than by message text, and a plain [Exception] has no such
# property - so a mock that throws one cannot exercise those branches at all.
if (-not ('FFTestCimException' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
public class FFTestCimException : Exception {
  public object NativeErrorCode { get; set; }
  public FFTestCimException(string message, object code) : base(message) { NativeErrorCode = code; }
}
'@
}

function New-FFCimException {
  <# -NativeErrorCode 'InvalidNamespace' | 'InvalidClass' | 5 | ... #>
  param([string]$Message = 'CIM failure', [Parameter(Mandatory)]$NativeErrorCode)
  New-Object FFTestCimException($Message, $NativeErrorCode)
}

# ---------------- sandbox (for real child-process runs) ----------------

function New-FFSandbox {
  <# A throwaway COPY of engine\ + data\ under %TEMP%. Engines resolve their catalog,
     ledger and sibling scripts relative to their own location, so a sandboxed engine
     reads sandboxed catalogs and writes sandboxed state - the real tree is untouched. #>
  param([string]$Label = 'sbx')
  $dir = Join-Path $script:FFWorkDir ("$Label-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'engine') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'data')   | Out-Null
  Copy-Item -Path (Join-Path $script:FFEngineDir '*.ps1') -Destination (Join-Path $dir 'engine') -Force
  Copy-Item -Path (Join-Path $script:FFRepoRoot 'data\*.json') -Destination (Join-Path $dir 'data') -Force
  $dir
}

function Add-FFSandboxEnginePatch {
  <#
    Splices a block of PowerShell into a SANDBOXED engine, immediately before its dispatch
    section (the `$out = $null` line every engine starts its dispatch with). The block is
    therefore defined AFTER every function in the file and BEFORE any of them runs, so a
    function defined in it SHADOWS the engine's own definition of the same name for the whole
    dispatch.

    That is what makes two otherwise impossible things testable:
      * running an engine's real -Action end to end against a FAKED machine (a Home SKU, a
        German UI, a missing cmdlet, an unreadable build), as a real child process emitting
        real JSON on stdout;
      * SABOTAGE tests - deliberately breaking a verdict function to prove the suite's own
        assertions would catch it, rather than trusting that they would.

    The real engine files are never touched: -Sandbox must be a directory from New-FFSandbox.
  #>
  param(
    [Parameter(Mandatory)][string]$Sandbox,
    [Parameter(Mandatory)][string]$Engine,
    [Parameter(Mandatory)][string]$Patch
  )
  $target = Join-Path $Sandbox "engine\$Engine.ps1"
  # The work-dir guard comes FIRST: this function rewrites a file, so it must decide it is
  # allowed to touch the path before it so much as looks at it.
  if (-not $target.StartsWith($script:FFWorkDir)) { throw "REFUSING to patch an engine outside the run work dir: $target" }
  if (-not (Test-Path -LiteralPath $target)) { throw "Sandboxed engine not found: $target" }
  $text = Get-Content -LiteralPath $target -Raw -Encoding UTF8
  $m = [regex]::Match($text, '(?m)^\$out = \$null\s*$')
  if (-not $m.Success) { throw "Could not find the dispatch marker (`$out = `$null) in $target - the splice point moved, so this patch would be silently ignored." }
  $block = "`r`n# ---- FrameForge test patch (sandbox only) ----`r`n" + $Patch + "`r`n# ---- end test patch ----`r`n`r`n"
  $patched = $text.Substring(0, $m.Index) + $block + $text.Substring($m.Index)
  $enc = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($target, $patched, $enc)
  $target
}

function New-FFSabotagedEngine {
  <#
    A sandbox whose copy of one engine has had exactly ONE guard textually removed, and the
    path to that sandbox's engine directory (feed it to Invoke-InEngineScope -EngineDir, or
    run it as a child process).

    -Find is matched as a REGEX and must match EXACTLY ONCE. That requirement is the point:
    if the guard is edited, moved or renamed, the sabotage stops applying, and a sabotage that
    silently applies to nothing would let a sabotage test pass while proving nothing at all.
    A miss throws with the count it saw, so the failure is loud and names the drift.

    Returns @{ sandbox; engineDir; enginePath; before; after }.
  #>
  param(
    [Parameter(Mandatory)][string]$Engine,
    [Parameter(Mandatory)][string]$Find,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Replace,
    [string]$Label = 'sabotage'
  )
  $sandbox = New-FFSandbox -Label $Label
  $target = Join-Path $sandbox "engine\$Engine.ps1"
  if (-not $target.StartsWith($script:FFWorkDir, [System.StringComparison]::OrdinalIgnoreCase)) { throw "REFUSING to sabotage an engine outside the run work dir: $target" }
  $text = Get-Content -LiteralPath $target -Raw -Encoding UTF8
  $matches_ = [regex]::Matches($text, $Find)
  if ($matches_.Count -ne 1) {
    throw ("SABOTAGE TARGET NOT FOUND: the pattern /$Find/ matched $($matches_.Count) time(s) in $Engine.ps1, and a sabotage test is only evidence when it matches exactly once. " +
           'The guard it removes has moved or been rewritten - update this pattern deliberately rather than letting the sabotage apply to nothing.')
  }
  $patched = [regex]::Replace($text, $Find, { param($m) $Replace })
  [System.IO.File]::WriteAllText($target, $patched, (New-Object System.Text.UTF8Encoding($true)))
  # A sabotaged engine may only ever be loaded IN PROCESS, behind the mutation guards. The
  # suite's denylist lets `repair.ps1 -Action run -DryRun` through as a CHILD PROCESS because
  # -DryRun is honoured - which is exactly the promise a sabotage is allowed to break. The
  # marker makes that combination impossible rather than merely unlikely; see Invoke-FFEngineProcess.
  [System.IO.File]::WriteAllText((Join-Path $sandbox '.ff-sabotaged'), "$Engine`r`n$Find`r`n", (New-Object System.Text.UTF8Encoding($false)))
  [pscustomobject]@{
    sandbox = $sandbox
    engineDir = (Join-Path $sandbox 'engine')
    enginePath = $target
    before = $matches_[0].Value
    after = $Replace
  }
}

function Set-FFSandboxHealthStub {
  <#
    Replaces the sandbox's health.ps1 with a stub, so repair.ps1's detect/verify step gets
    a chosen answer instantly and deterministically instead of scanning the real machine.

    -Mode:
      json     emit -Json (with @@CATEGORY@@ substituted), exit 0
      garbage  emit text that is not JSON at all, exit 0     -> must read as probe-failure
      empty    emit nothing, exit 0                          -> must read as probe-failure
      crash    emit nothing, exit 1                          -> must read as probe-failure
      missing  delete health.ps1 entirely                    -> must read as probe-failure
  #>
  param(
    [Parameter(Mandatory)][string]$Sandbox,
    [ValidateSet('json','garbage','empty','crash','missing')][string]$Mode = 'json',
    [string]$Json = ''
  )
  $target = Join-Path $Sandbox 'engine\health.ps1'
  if ($Mode -eq 'missing') {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    return
  }
  $body = ''
  switch ($Mode) {
    'json'    { $body = "`$doc = @'`r`n$Json`r`n'@`r`n`$doc = `$doc -replace '@@CATEGORY@@', `"`$Category`"`r`n[Console]::Out.WriteLine(`$doc)`r`nexit 0" }
    'garbage' { $body = "[Console]::Out.WriteLine('health.ps1 : the term is not recognized')`r`nexit 0" }
    'empty'   { $body = "exit 0" }
    'crash'   { $body = "exit 1" }
  }
  $stub = @"
# TEST STUB - not the real health.ps1. Written by engine/test/lib/harness.ps1.
param([string]`$Action = 'scan', [string]`$Category, [switch]`$Deep, [switch]`$Json)
$body
"@
  [System.IO.File]::WriteAllText($target, $stub, (New-Object System.Text.UTF8Encoding($true)))
}

function New-FFHealthDoc {
  <# A health.ps1 `probe` document, as JSON text, for Set-FFSandboxHealthStub -Mode json.
     Findings are given as "id|severity|detail" strings. #>
  param(
    [string]$Status = 'ok',
    [string]$Summary = 'Stubbed probe.',
    [string[]]$Findings = @()
  )
  $f = @()
  foreach ($row in $Findings) {
    $parts = "$row" -split '\|', 3
    $f += [ordered]@{ id = $parts[0]; severity = $parts[1]; detail = $parts[2]; evidence = $null }
  }
  $doc = [ordered]@{
    category = '@@CATEGORY@@'
    status = $Status
    summary = $Summary
    findings = $f
    durationMs = 1
    supportedOs = $true
    unvalidatedPlatform = $false
    languageMode = 'FullLanguage'
  }
  ConvertTo-Json -InputObject $doc -Depth 8
}

function New-FFFakeMedia {
  <# A folder shaped like extracted Windows media: setup.exe + sources\install.wim, both
     zero-byte placeholders. image.ps1 will resolve it as media and then fail to read its
     inventory - which is exactly the "media present, verdict undetermined" case a launch
     without -Confirm must still handle without executing anything. #>
  param([string]$Label = 'media')
  $dir = Join-Path $script:FFWorkDir ("$Label-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'sources') | Out-Null
  Set-Content -LiteralPath (Join-Path $dir 'setup.exe') -Value '' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $dir 'sources\install.wim') -Value '' -Encoding Ascii
  $dir
}

# ---------------- safe child-process runner ----------------

function Assert-FFSafeArgs {
  <#
    THE SUITE'S OWN SAFETY RAIL. Refuses to spawn any engine invocation that could mutate
    the machine. Deliberately conservative and deliberately dumb: it matches on the literal
    argument list, so a new mutating action is refused by default until this list is
    updated on purpose. Covered by cases/60-safety.ps1.
  #>
  param([string]$Script, [string[]]$EngineArgs)
  $leaf = (Split-Path -Leaf $Script).ToLowerInvariant()
  $lower = @(@($EngineArgs) | ForEach-Object { "$_".ToLowerInvariant() })
  $joined = ($lower -join ' ')
  $hasDryRun = ($lower -contains '-dryrun')

  if ($lower -contains '-force') {
    throw "SUITE SAFETY: refusing to run '$leaf' with -Force ($joined)."
  }
  foreach ($sw in @('-confirm', '-accepteula', '-consentrunfido', '-suspendbitlocker')) {
    if ($lower -contains $sw) { throw "SUITE SAFETY: refusing to run '$leaf' with $sw ($joined)." }
  }

  # The value that follows -action, whatever its position.
  $action = ''
  for ($i = 0; $i -lt $lower.Count; $i++) {
    if ($lower[$i] -eq '-action' -and $i + 1 -lt $lower.Count) { $action = $lower[$i + 1]; break }
  }

  switch ($leaf) {
    'repair.ps1' {
      if ($action -eq 'run' -and -not $hasDryRun) { throw "SUITE SAFETY: repair.ps1 -Action run without -DryRun would mutate this machine ($joined)." }
      if ($action -eq 'undo' -and -not $hasDryRun) { throw "SUITE SAFETY: repair.ps1 -Action undo without -DryRun would mutate this machine ($joined)." }
    }
    'image.ps1' {
      $banned = @('download', 'dism-source-repair', 'acquire-url')
      if ($banned -contains $action) { throw "SUITE SAFETY: image.ps1 -Action $action is never run by the suite ($joined)." }
      if ($action -eq 'preflight') { throw "SUITE SAFETY: image.ps1 -Action preflight runs Windows Setup's compat scan; the suite never runs it ($joined)." }
    }
    'engine.ps1' {
      $banned = @('apply', 'revert', 'revert-all', 'restore-point')
      if ($banned -contains $action -and -not $hasDryRun) { throw "SUITE SAFETY: engine.ps1 -Action $action without -DryRun would mutate this machine ($joined)." }
      if ($action -eq 'restore-point') { throw "SUITE SAFETY: engine.ps1 -Action restore-point always mutates ($joined)." }
    }
    'nvidia.ps1' {
      $banned = @('snapshot', 'restore', 'createcsn', 'apply-preset', 'apply-custom', 'revert', 'build-catalog', 'open')
      if ($banned -contains $action) { throw "SUITE SAFETY: nvidia.ps1 -Action $action is never run by the suite ($joined)." }
    }
    'procs.ps1' {
      if ($action -eq 'close') { throw "SUITE SAFETY: procs.ps1 -Action close terminates processes ($joined)." }
    }
    'measure.ps1' {
      if ($action -eq 'capture') { throw "SUITE SAFETY: measure.ps1 -Action capture launches PresentMon ($joined)." }
    }
  }
}

function Invoke-FFEngineProcess {
  <#
    Runs an engine as a real child PowerShell and returns
      @{ exitCode; stdout; stderr; timedOut; durationMs; command }
    Streams are read concurrently (the classic redirect deadlock otherwise) and decoded
    with an explicit UTF-8 decoder, so the assertion "stdout is one JSON document and
    stderr is empty" is measuring the engine and not the console code page.
  #>
  param(
    [Parameter(Mandatory)][string]$Script,
    [string[]]$EngineArgs = @(),
    [int]$TimeoutMs = 120000,
    # Where this call's runtime state must land. Defaults to the sandbox's own data\state when
    # the engine being run is a sandboxed copy, and to the run's scratch profile otherwise.
    # NEVER the real one: see the redirect note above Initialize-FFWorkDir.
    [string]$StateDir = ''
  )
  Assert-FFSafeArgs -Script $Script -EngineArgs $EngineArgs

  $engineDir = Split-Path -Parent $Script
  $sandboxRoot = $null
  if ($engineDir.StartsWith($script:FFWorkDir, [System.StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $engineDir) -eq 'engine') {
    $sandboxRoot = Split-Path -Parent $engineDir
  }
  # A SABOTAGED engine has, by definition, had a guard removed - possibly the one that makes
  # -DryRun mean anything. Assert-FFSafeArgs lets `-Action run -DryRun` through on the strength
  # of that guard, so a sabotaged engine must never be launched as a child process at all. The
  # sabotage cases load it in-process, behind cases\60-safety.ps1's throwing mutation stubs.
  if ($sandboxRoot -and (Test-Path -LiteralPath (Join-Path $sandboxRoot '.ff-sabotaged'))) {
    $marker = (Get-Content -LiteralPath (Join-Path $sandboxRoot '.ff-sabotaged') -Raw -ErrorAction SilentlyContinue) -replace "`r?`n", ' '
    throw "SUITE SAFETY: refusing to launch a SABOTAGED engine as a child process - its guards have been removed on purpose, so no switch it is passed can be trusted ($marker). Load it in-process with Invoke-InEngineScope -EngineDir instead."
  }
  if (-not $StateDir) {
    $StateDir = "$($env:FRAMEFORGE_STATE_DIR)"
    # <workdir>\<label>-<guid>\engine\<x>.ps1 -> <workdir>\<label>-<guid>\data\state
    if ($sandboxRoot) { $StateDir = Get-FFSandboxStateDir -Sandbox $sandboxRoot }
  }
  # A run that could not be redirected is a run that might write the real ledger. Refuse it.
  if (-not $StateDir) { throw 'SUITE SAFETY: no state directory was resolved for this engine call, so it could write the real repair ledger. Initialize-FFWorkDir must run first.' }
  if (-not $StateDir.StartsWith($script:FFWorkDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "SUITE SAFETY: refusing to run an engine with its state root outside this run's scratch directory: $StateDir"
  }

  $res = [ordered]@{ exitCode = $null; stdout = ''; stderr = ''; timedOut = $false; durationMs = 0; command = ''; stateDir = $StateDir }
  $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($EngineArgs)
  $res.command = "powershell " + (@($argList | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } }) -join ' ')
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:FFPwsh
    # PS 5.1 / .NET 4.x has no ProcessStartInfo.ArgumentList - quote and join by hand.
    $psi.Arguments = (@($argList | ForEach-Object { if ("$_" -match '[\s]') { '"' + "$_" + '"' } else { "$_" } }) -join ' ')
    $psi.UseShellExecute = $false
    # Both redirects, explicitly, per call: LOCALAPPDATA covers engine.ps1 and nvidia.ps1, which
    # create their state folder at load and have no override; FRAMEFORGE_STATE_DIR is repair.ps1's
    # documented override and is what puts the ledger inside THIS sandbox.
    $psi.EnvironmentVariables['LOCALAPPDATA'] = "$($env:LOCALAPPDATA)"
    $psi.EnvironmentVariables['FRAMEFORGE_STATE_DIR'] = $StateDir
    $res.stateDir = $StateDir
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.WorkingDirectory = (Split-Path -Parent $Script)
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
      $res.timedOut = $true
      try { $p.Kill() } catch {}
    } else {
      $res.exitCode = $p.ExitCode
    }
    try { $res.stdout = "$($outTask.Result)" } catch {}
    try { $res.stderr = "$($errTask.Result)" } catch {}
  } finally {
    if ($null -ne $p) { try { $p.Dispose() } catch {} }
  }
  $sw.Stop()
  $res.durationMs = [int]$sw.ElapsedMilliseconds
  $res
}

function Invoke-FFHostArgv {
  <#
    Runs an engine through an ARBITRARY argv - the one electron\main.js says it would use -
    rather than through the suite's own `-File` invocation, and returns the same shape as
    Invoke-FFEngineProcess. cases\56-policy.ps1 is the only caller: it is how the host's
    scriptblock fallback is tested against the real engines instead of against a copy of the
    argv builder living in a test file.

    -SafetyScript / -SafetyArgs are the LOGICAL call this argv performs, and they go through
    Assert-FFSafeArgs exactly as a normal engine call does, so this door cannot be used to
    launch something mutating. The state redirects are applied here too.
  #>
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string[]]$Argv,
    [Parameter(Mandatory)][string]$SafetyScript,
    [string[]]$SafetyArgs = @(),
    [int]$TimeoutMs = 120000
  )
  Assert-FFSafeArgs -Script $SafetyScript -EngineArgs $SafetyArgs
  $stateDir = "$($env:FRAMEFORGE_STATE_DIR)"
  if (-not $stateDir -or -not $stateDir.StartsWith($script:FFWorkDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'SUITE SAFETY: the state redirect is not in force, so this call could write the real repair ledger.'
  }
  $res = [ordered]@{ exitCode = $null; stdout = ''; stderr = ''; timedOut = $false; durationMs = 0; command = "$Exe $(@($Argv) -join ' ')"; stateDir = $stateDir }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Argv | ForEach-Object { if ("$_" -match '[\s]') { '"' + ("$_" -replace '"', '\"') + '"' } else { "$_" } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.EnvironmentVariables['LOCALAPPDATA'] = "$($env:LOCALAPPDATA)"
    $psi.EnvironmentVariables['FRAMEFORGE_STATE_DIR'] = $stateDir
    $psi.WorkingDirectory = $script:FFRepoRoot
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) { $res.timedOut = $true; try { $p.Kill() } catch {} }
    else { $res.exitCode = $p.ExitCode }
    try { $res.stdout = "$($outTask.Result)" } catch {}
    try { $res.stderr = "$($errTask.Result)" } catch {}
  } finally {
    if ($null -ne $p) { try { $p.Dispose() } catch {} }
  }
  $sw.Stop()
  $res.durationMs = [int]$sw.ElapsedMilliseconds
  $res
}

function ConvertFrom-FFEngineStdout {
  <#
    Parses an engine's stdout under the ONE-DOCUMENT contract and returns
      @{ ok; doc; error; hadBom; docCount }
    ok=$false with a reason when the text is empty, carries a BOM, or is not exactly one
    JSON document (two concatenated documents fail ConvertFrom-Json, which is the check).
  #>
  param([string]$Stdout)
  $out = [ordered]@{ ok = $false; doc = $null; error = $null; hadBom = $false; docCount = 0 }
  if ($null -eq $Stdout) { $Stdout = '' }
  if ($Stdout.Length -gt 0 -and [int][char]$Stdout[0] -eq 0xFEFF) {
    $out.hadBom = $true
    $Stdout = $Stdout.Substring(1)
  }
  $trimmed = $Stdout.Trim()
  if ($trimmed -eq '') { $out.error = 'stdout was empty - no JSON document was emitted at all'; return $out }
  $out.docCount = 1
  try {
    $out.doc = $trimmed | ConvertFrom-Json -ErrorAction Stop
    $out.ok = $true
  } catch {
    $out.error = "stdout did not parse as exactly one JSON document: $($_.Exception.Message)"
    # Distinguish "two documents" from "not JSON at all", because they are different bugs.
    if ($trimmed -match '(?s)\}\s*\{') { $out.docCount = 2; $out.error = "stdout carried MORE THAN ONE JSON document (the host parses exactly one): $($_.Exception.Message)" }
  }
  $out
}

function Assert-FFOneJsonDoc {
  <# The whole stdout/stderr/exit-code contract in one assertion. #>
  param(
    [Parameter(Mandatory)]$Result,
    [Parameter(Mandatory)][string]$Label,
    [int]$ExpectExit = 0,
    [switch]$AllowStderr
  )
  Assert-False $Result.timedOut "$Label must finish inside the timeout"
  $parsed = ConvertFrom-FFEngineStdout -Stdout $Result.stdout
  Assert-True $parsed.ok "$Label must emit exactly ONE parseable JSON document on stdout$(if ($parsed.error) { " - $($parsed.error)" })"
  Assert-False $parsed.hadBom "$Label stdout must be BOM-free (the Electron host reads it raw)"
  Assert-Eq $ExpectExit $Result.exitCode "$Label must exit $ExpectExit"
  if (-not $AllowStderr) {
    Assert-Eq '' ("$($Result.stderr)".Trim()) "$Label must write NOTHING to stderr"
  }
  return $parsed.doc
}

# ---------------- misc ----------------

function Get-FFEngineSource {
  <# Raw engine source, for the few structural assertions that are better made against the
     text than by executing a consent-gated path. #>
  param([Parameter(Mandatory)][string]$Engine)
  Get-Content -LiteralPath (Join-Path $script:FFEngineDir "$Engine.ps1") -Raw -Encoding UTF8
}
