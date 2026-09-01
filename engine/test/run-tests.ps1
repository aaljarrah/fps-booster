<#
  FrameForge :: engine/test/run-tests.ps1

    npm run test:engine
    powershell -NoProfile -ExecutionPolicy Bypass -File engine\test\run-tests.ps1 [-Area LOCALE] [-Name *sfc*] [-Quick] [-Verbose]

  Runs every case in engine\test\cases\*.ps1 and prints a pass/fail summary.

  THE GATE CONTRACT (changed - read this before wiring CI)
  --------------------------------------------------------
  A test registered with -Xfail asserts behaviour the engine does NOT have: it reproduces a
  live defect. Those used to be printed and then forgiven, so the run exited 0 and said
  "RESULT: PASS" while listing reproduced doctrine-2 violations underneath - which made any CI
  gate on 'npm run test:engine' green over known-broken behaviour. A reproduced defect now
  FAILS the run.

    (default, and the ONLY mode CI or a release may use)  -Xfail tests fail the run.
    -AllowKnownDefects                                    they are reported as DEFECT and
                                                          tolerated. Local iteration only; the
                                                          banner and the summary both say so.

  Exit codes:
    0  every test passed
    1  at least one test failed - including a reproduced defect (default mode), and including
       an -Xfail test that unexpectedly PASSED (XPASS: the narrative is stale, delete it)
    2  the suite itself could not run (a case file did not load, or the selection was empty)
    3  the run MUTATED THIS MACHINE. The tests' verdict is void: a suite that changes the
       machine it is measuring is not evidence of anything.

  The suite is read-only with respect to this machine. It never elevates, never executes a
  repair, and writes only to its OWN per-run directory under
  %TEMP%\frameforge-engine-tests\run-<pid>-<stamp>-<guid>, which it deletes on the way out -
  so two runs, concurrent or sequential, cannot corrupt each other. See the header of
  lib\harness.ps1 for how the environment is faked.

  That paragraph WAS FALSE for one round and is now enforced rather than promised. The
  engines keep runtime state at an absolute %LOCALAPPDATA%\FrameForge\state, which a copied
  tree does not relocate, so a suite run created that folder and copied the invoking user's
  real repair ledger into it. The harness now redirects $env:LOCALAPPDATA and repair.ps1's
  $env:FRAMEFORGE_STATE_DIR into the run's own scratch, and this file FINGERPRINTS the paths
  a run must never touch - <repo>\data\state and %LOCALAPPDATA%\FrameForge - before the first
  test and re-checks them after the last one. A single changed byte fails the run with exit 3,
  whatever the tests said.
#>
[CmdletBinding()]
param(
  [string]$Area = '',
  [string]$Name = '',
  [switch]$Quick,
  [switch]$KeepWorkDir,
  [switch]$ListOnly,
  # Tolerate tests that reproduce a live engine defect (-Xfail) instead of failing on them.
  # Local iteration only - never in CI, never for a release.
  [switch]$AllowKnownDefects
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# When a PowerShell 7 parent (GitHub Actions' default shell, a pwsh terminal) starts this
# Windows PowerShell 5.1 process, the child INHERITS pwsh's PSModulePath. 5.1 then resolves
# built-in modules from PS7's directories, whose Core-only implementations it cannot load —
# measured on windows-latest: 'Get-FileHash' was "not recognized" because the inherited path
# shadowed Microsoft.PowerShell.Utility. Reset to 5.1's own defaults; every child process
# this suite spawns inherits the repaired value.
if ($PSVersionTable.PSEdition -ne 'Core') {
  $env:PSModulePath = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    (Join-Path $PSHOME 'Modules')
  ) -join ';'
}

. (Join-Path $PSScriptRoot 'lib\harness.ps1')

$ansi = $Host.UI.SupportsVirtualTerminal -and -not $env:NO_COLOR
function C { param([string]$Text, [string]$Code) if ($ansi) { "$([char]27)[${Code}m$Text$([char]27)[0m" } else { $Text } }
function Green  { param($t) C $t '32' }
function Red    { param($t) C $t '31' }
function Yellow { param($t) C $t '33' }
function Cyan   { param($t) C $t '36' }
function Dim    { param($t) C $t '90' }
function Bold   { param($t) C $t '1'  }

Initialize-FFWorkDir

# ---------------- load cases ----------------

$caseFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($caseFiles.Count -eq 0) {
  Write-Host (Red 'No case files found in engine\test\cases.')
  Remove-FFWorkDir
  exit 2
}
foreach ($f in $caseFiles) {
  $script:FFCurrentCaseFile = $f.Name
  try { . $f.FullName }
  catch {
    Write-Host (Red "FATAL: case file '$($f.Name)' failed to load: $($_.Exception.Message)")
    Write-Host (Dim ($_.ScriptStackTrace))
    Remove-FFWorkDir
    exit 2
  }
}
$script:FFCurrentCaseFile = $null

$tests = @($script:FFSuite)
if ($Area) { $tests = @($tests | Where-Object { $_.Area -like $Area }) }
if ($Name) { $tests = @($tests | Where-Object { $_.Name -like $Name }) }
if ($Quick) { $tests = @($tests | Where-Object { -not $_.Slow }) }

# Group the run by area while keeping registration order inside each area (a stable sort:
# Sort-Object is not stable in PS 5.1, so the original index is the tie-breaker).
$areaOrder = @{ 'SMOKE' = 0; 'CONTRACT' = 1; 'POLICY' = 2; 'LOCALE' = 3; 'SKU' = 4; 'BUILD' = 5; 'STATE' = 6; 'SAFETY' = 7; 'SABOTAGE' = 8; 'VMTEST' = 9 }
$idx = 0
$tests = @($tests | ForEach-Object {
  $rank = 99; if ($areaOrder.ContainsKey($_.Area)) { $rank = $areaOrder[$_.Area] }
  $_ | Add-Member NoteProperty __Rank $rank -Force -PassThru | Add-Member NoteProperty __Idx ($idx++) -Force -PassThru
} | Sort-Object __Rank, Area, __Idx)

# A filter that matches nothing must not look like a green run.
if ($tests.Count -eq 0) {
  Write-Host (Red "No tests matched (Area='$Area' Name='$Name'). Refusing to report a pass on an empty selection.")
  Remove-FFWorkDir
  exit 2
}

if ($ListOnly) {
  foreach ($t in $tests) { Write-Host ("{0,-9} {1}" -f $t.Area, $t.Name) }
  Write-Host ''
  Write-Host "$($tests.Count) test(s)."
  Remove-FFWorkDir
  exit 0
}

Write-Host ''
Write-Host (Bold 'FrameForge engine test suite')
Write-Host (Dim  "  engines : $script:FFEngineDir")
Write-Host (Dim  "  cases   : $($caseFiles.Count) file(s), $($tests.Count) test(s)$(if ($Quick) { ' (quick mode: slow tests skipped)' })")
Write-Host (Dim  "  scratch : $script:FFWorkDir")
Write-Host (Dim  "  state   : redirected to the scratch dir; $(@(Get-FFProtectedPaths).Count) real path(s) fingerprinted and re-checked at the end")
if ($AllowKnownDefects) {
  Write-Host (Yellow '  gate    : -AllowKnownDefects is ON. Tests that reproduce a live engine defect will NOT')
  Write-Host (Yellow '            fail this run. Never use this mode for CI or for a release.')
} else {
  Write-Host (Dim  '  gate    : strict - a test that reproduces a live engine defect FAILS the run.')
}
$hostAdmin = $false
try { $hostAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
Write-Host (Dim  "  host    : PS $($PSVersionTable.PSVersion) | admin=$hostAdmin | culture=$([System.Globalization.CultureInfo]::CurrentCulture.Name) | uiculture=$([System.Globalization.CultureInfo]::InstalledUICulture.Name)")
Write-Host ''

# ---------------- run ----------------

$results = New-Object System.Collections.ArrayList
$suiteSw = [System.Diagnostics.Stopwatch]::StartNew()
$lastArea = ''

foreach ($t in $tests) {
  if ($t.Area -ne $lastArea) {
    Write-Host ''
    Write-Host (Cyan "  $($t.Area)")
    $lastArea = $t.Area
  }
  $script:FFAsserts = New-Object System.Collections.ArrayList
  $script:FFTestData = $t.Data
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $threw = $null
  try { $null = & $t.Body }
  catch { $threw = $_ }
  $sw.Stop()

  $asserts = @($script:FFAsserts)
  $failed = @($asserts | Where-Object { -not $_.Ok })
  # One place decides the verdict, and cases/00-harness.ps1 tests that decision directly.
  $state = Get-FFTestState -Threw ($null -ne $threw) -AssertCount $asserts.Count `
                           -FailedCount $failed.Count -KnownDefect "$($t.Xfail)" `
                           -AllowKnownDefects:$AllowKnownDefects

  $null = $results.Add([pscustomobject]@{
    Name = $t.Name; Area = $t.Area; File = $t.File; State = $state; Xfail = $t.Xfail
    Doctrine = $t.Doctrine; Ms = [int]$sw.ElapsedMilliseconds
    Asserts = $asserts; Failed = $failed; Threw = $threw
  })

  $tag = switch ($state) {
    'PASS'   { Green  'PASS  ' }
    'FAIL'   { Red    'FAIL  ' }
    'DEFECT' { Yellow 'DEFECT' }
    'XPASS'  { Red    'XPASS ' }
    'EMPTY'  { Red    'EMPTY ' }
  }
  $ms = if ($sw.ElapsedMilliseconds -ge 400) { Dim (" {0}ms" -f [int]$sw.ElapsedMilliseconds) } else { '' }
  Write-Host "    $tag $($t.Name)$ms"

  if (Test-FFStateIsFailure $state) {
    if ($state -eq 'EMPTY') { Write-Host (Red '           the test made no assertions at all') }
    if ($state -eq 'XPASS') { Write-Host (Red "           marked -Xfail ($($t.Xfail)) but PASSED - the narrative is stale, remove the marker") }
    if ($state -eq 'FAIL' -and $t.Xfail) { Write-Host (Red "           this test reproduces a LIVE ENGINE DEFECT: $($t.Xfail)") }
    foreach ($a in $failed) { Write-Host (Red "           x $($a.Text)") }
    if ($null -ne $threw) {
      Write-Host (Red "           ! $($threw.Exception.Message)")
      if ($VerbosePreference -eq 'Continue') { Write-Host (Dim ("             " + ($threw.ScriptStackTrace -replace "`n", "`n             "))) }
    }
  } elseif ($state -eq 'DEFECT' -and $VerbosePreference -eq 'Continue') {
    foreach ($a in $failed) { Write-Host (Yellow "           x $($a.Text)") }
  }
}
$suiteSw.Stop()

# ---------------- summary ----------------

$pass  = @($results | Where-Object { $_.State -eq 'PASS' })
$fail  = @($results | Where-Object { $_.State -eq 'FAIL' })
$xfail = @($results | Where-Object { $_.State -eq 'DEFECT' })
$xpass = @($results | Where-Object { $_.State -eq 'XPASS' })
$empty = @($results | Where-Object { $_.State -eq 'EMPTY' })
$assertTotal = (@($results | ForEach-Object { @($_.Asserts).Count }) | Measure-Object -Sum).Sum

Write-Host ''
Write-Host (Bold '  ---------------------------------------------------------------')
Write-Host ''
foreach ($a in (@($results | Group-Object Area | Sort-Object Name))) {
  $p = @($a.Group | Where-Object { $_.State -eq 'PASS' }).Count
  $f = @($a.Group | Where-Object { Test-FFStateIsFailure $_.State }).Count
  $x = @($a.Group | Where-Object { $_.State -eq 'DEFECT' }).Count
  $bits = @("$p passed")
  if ($f -gt 0) { $bits += (Red "$f FAILED") }
  if ($x -gt 0) { $bits += (Yellow "$x known defect(s)") }
  Write-Host ("  {0,-9} {1}" -f $a.Name, ($bits -join ', '))
}
Write-Host ''
Write-Host "  $($results.Count) tests, $assertTotal assertions, $([int]($suiteSw.ElapsedMilliseconds/1000))s"

if ($xfail.Count -gt 0) {
  Write-Host ''
  Write-Host (Yellow (Bold '  ENGINE DEFECTS the suite reproduces (asserted correct behaviour, engine does not have it yet):'))
  foreach ($x in $xfail) {
    Write-Host (Yellow "    - [$($x.Area)] $($x.Name)")
    Write-Host (Dim   "        $($x.Xfail)")
    foreach ($a in $x.Failed) { Write-Host (Dim "        x $($a.Text)") }
  }
  Write-Host ''
  Write-Host (Yellow '  These were TOLERATED only because -AllowKnownDefects was passed. Without it they fail')
  Write-Host (Yellow '  the run, which is the mode CI and any release build must use.')
}

# ---------------- the read-only claim, MEASURED ----------------
# Checked before the test verdict is reported, because it outranks it: if the run changed the
# machine, what the tests concluded about that machine is worthless.
$stateDiffs = @(Compare-FFRealStateFingerprint)
if ($stateDiffs.Count -gt 0) {
  Write-Host ''
  Write-Host (Red (Bold '  THIS RUN MUTATED THE MACHINE.'))
  Write-Host (Red    '  The suite is required to be read-only with respect to this PC, and it was not. The')
  Write-Host (Red    '  test results above are VOID - a measurement that changes what it measures is not one.')
  Write-Host ''
  foreach ($d in $stateDiffs) { Write-Host (Red "    $d") }
  Write-Host ''
  Write-Host (Red    '  Fix the leak (usually: an engine resolving state from something other than')
  Write-Host (Red    '  $env:LOCALAPPDATA / $env:FRAMEFORGE_STATE_DIR, which lib\harness.ps1 redirects).')
  if (-not $KeepWorkDir) { Remove-FFWorkDir } else { Write-Host (Dim "  work dir kept: $script:FFWorkDir") }
  exit 3
}

$exit = Get-FFSuiteExitCode -States @($results | ForEach-Object { $_.State })
if ($exit -ne 0) {
  Write-Host ''
  Write-Host (Red (Bold "  FAILED:"))
  foreach ($f in @($fail + $xpass + $empty)) {
    $why = ''
    if ($f.State -eq 'XPASS') { $why = '  [XPASS: stale -Xfail narrative]' }
    elseif ($f.State -eq 'EMPTY') { $why = '  [made no assertions]' }
    elseif ($f.Xfail) { $why = '  [reproduces a live engine defect]' }
    Write-Host (Red "    - [$($f.Area)] $($f.Name)  ($($f.File))$why")
  }
  Write-Host ''
  Write-Host (Red (Bold '  RESULT: FAIL'))
  if (-not $KeepWorkDir) { Remove-FFWorkDir } else { Write-Host (Dim "  work dir kept: $script:FFWorkDir") }
  exit 1
}

Write-Host ''
Write-Host (Green (Bold '  RESULT: PASS'))
if (-not $KeepWorkDir) { Remove-FFWorkDir } else { Write-Host (Dim "  work dir kept: $script:FFWorkDir") }
exit 0
