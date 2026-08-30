<#
  FrameForge :: compat.ps1
  COMPATIBILITY SELF-CHECK — "what can FrameForge actually do on THIS machine?"

  Everything else in this engine answers "is this Windows broken?". This script answers the
  question that has to come first: which of FrameForge's own checks and repairs can honestly
  run here at all. The output is a capability profile: for each health category in
  data/health-checks.json and each repair in data/repairs.json, one verdict —
  supported / needs-admin / unknown / degraded / unavailable — with the plain-English reason
  and the evidence it was reached from.

  Two audiences:
    1. The app, so it degrades KNOWINGLY (grey out a Store repair on an LTSC image that has no
       Store, instead of running it and reporting a confusing failure).
    2. A bug report, so "it didn't work" arrives with the machine's capability profile attached.

  Usage:
    compat.ps1 -Action check [-Json] [-Pretty]   # the full profile (default)
    compat.ps1 -Action list                      # probe + capability ids, no probing
    compat.ps1 -Action selftest                  # catalog integrity, read-only (see below)

  Output is always a single JSON document on stdout, including for invalid input, which exits
  non-zero WITH a JSON error document. -Json is accepted for interface symmetry with the other
  engine scripts and changes nothing; -Pretty indents the document for reading by eye.

  READ-ONLY BY CONSTRUCTION. This script starts no external process, writes no file, and
  changes no registry value. Every signal comes from a registry READ, a CIM query, a
  Get-Command lookup, a file-existence test, or a documented Win32 query API. There is
  deliberately no rung anywhere in this file that shells out to sfc / dism / powercfg / fsutil
  to ask a question: those tools answer in the user's language, and this is the one script
  whose entire job is to be right on a machine whose language we do not know.

  DOCTRINE (docs/GAUNTLET.md rule 2) IS THE POINT OF THIS FILE.
  Every signal is TRI-STATE: $true / $false / $null, where $null means COULD NOT DETERMINE.
  A probe that failed never becomes a $false, and 'unknown' is a first-class verdict ranking
  ABOVE 'supported' and 'needs-admin' precisely so an unmeasured capability can never be
  rendered as a green tick. When this file says "supported" it is because a signal was read,
  not because a signal was missing.

  WHY THIS SCRIPT REFUSES TO DIE WHERE THE OTHERS DO.
  health.ps1 exits 3 with errorCode 'constrained-language' under WDAC/AppLocker. That is right
  for a health scan and useless for a compatibility check: "your machine is in
  ConstrainedLanguage" is exactly the answer a user needs, so producing it is this script's job,
  not a reason to give up. compat.ps1 runs as far as it can in ConstrainedLanguage, marks
  everything that genuinely needs FullLanguage as unavailable WITH that reason, and still exits
  0. For the same reason the _lib.ps1 dot-source is wrapped: if the shared library cannot be
  loaded, this script reads the same values itself and reports which rung answered
  (libraryLoaded / osIdentitySource).

  EXIT CODES: 0 = a report was produced (however bad the news in it), 2 = invalid input,
  1 = this script itself failed. Deliberately never 3 — health.ps1 uses exit 3 for
  'constrained-language' and repair.ps1 uses it for 'not-applicable-on-this-build', so a third
  meaning here would make the number useless to a caller. An incompatible machine is a
  successful report, not an error.

  PowerShell 5.1 compatible (no ternary, no ??, no null-conditional).
#>
[CmdletBinding()]
param(
  # Deliberately NOT [ValidateSet] — a parameter binding failure would exit with no JSON at
  # all, and the Electron host parses exactly one document per run. Validated in the body.
  [string]$Action = 'check',
  [switch]$Json,
  [switch]$Pretty
)

$ValidActions = @('check','list','selftest')
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$Root           = Split-Path -Parent $PSScriptRoot
$CompatCatalog  = Join-Path $Root 'data\compat.json'
$RepairsCatalog = Join-Path $Root 'data\repairs.json'
$HealthCatalog  = Join-Path $Root 'data\health-checks.json'

# ---------------------------------------------------------------------------
# language mode — read FIRST, before anything that might depend on it
# ---------------------------------------------------------------------------
$script:LanguageMode = 'Unknown'
try { $script:LanguageMode = "$($ExecutionContext.SessionState.LanguageMode)" } catch {}
$script:FullLanguage = ($script:LanguageMode -eq 'FullLanguage')

# ---------------------------------------------------------------------------
# shared library — optional, never fatal
# ---------------------------------------------------------------------------
$script:LibLoaded = $false
$script:LibError  = $null
try {
  . (Join-Path $PSScriptRoot '_lib.ps1')
  $script:LibLoaded = $true
} catch {
  $script:LibError = "$($_.Exception.Message)"
}

# ===========================================================================
# small helpers (local, so this file keeps working with or without _lib.ps1)
# ===========================================================================

function Invoke-Safely {
  <# Run a scriptblock; return @{ value; error }. Never throws. #>
  param([Parameter(Mandatory)][scriptblock]$Script)
  $v = $null; $e = $null
  try { $v = & $Script } catch { $e = "$($_.Exception.Message)" }
  [ordered]@{ value = $v; error = $e }
}

function Test-CompatAccessDenied {
  <#
    Access denial decided from the exception TYPE / PowerShell CATEGORY / Win32 code inside the
    HRESULT — never from message text, which is localized. Delegates to _lib's
    Test-FFAccessDenied when the library loaded; the local rungs are the same test, so this
    file keeps working without it.
  #>
  param($ErrorRecord)
  if ($null -eq $ErrorRecord) { return $false }
  if ($script:LibLoaded) {
    $r = Invoke-Safely { Test-FFAccessDenied -ErrorRecord $ErrorRecord }
    if ($null -eq $r.error) { return [bool]$r.value }
  }
  $ex = $ErrorRecord.Exception
  if ($ex -is [System.UnauthorizedAccessException]) { return $true }
  if ($ex -is [System.Security.SecurityException]) { return $true }
  try { if ("$($ErrorRecord.CategoryInfo.Category)" -eq 'PermissionDenied') { return $true } } catch {}
  try {
    $h = [int]$ex.HResult
    if ((($h -band [int]0xFFFF0000) -eq [int]0x80070000) -and (($h -band 0xFFFF) -in 5, 32)) { return $true }
  } catch {}
  return $false
}

function Test-KeyPresent {
  <#
    Does an ordered dictionary hold this key?

    WHY THIS EXISTS RATHER THAN .Contains(): [ordered]@{} is a
    System.Collections.Specialized.OrderedDictionary, which is NOT one of ConstrainedLanguage's
    allowed types — so `$d.Contains('x')` throws "Method invocation is supported only on core
    types in this language mode" on exactly the WDAC/AppLocker machines this script exists to
    describe. Measured: the whole report died at the first such call. Reading .Keys is property
    access and -contains is a language operator, so both survive. Hashtable would also have been
    safe, but the output has to stay ordered to be readable.
  #>
  param($Dictionary, [string]$Name)
  if ($null -eq $Dictionary) { return $false }
  return [bool](@($Dictionary.Keys) -contains $Name)
}

function Test-CompatProperty {
  <#
    Does an object deserialized from a catalog actually DECLARE this property?

    [bool]$repair.requiresAdmin on an object that has no requiresAdmin member yields $false
    with no error at all, so a MISSING catalog field reads as a measured "no". Callers use
    this to tell "declared false" from "never declared", and report the second as unknown.
  #>
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $false }
  $names = @()
  try { $names = @($Object.PSObject.Properties | ForEach-Object { "$($_.Name)" }) } catch { return $false }
  return [bool]($names -contains $Name)
}

function ConvertTo-CompatInvariantUpper {
  <#
    Upper-case for MATCHING, never for display.

    THE TURKISH-I TRAP, MEASURED RATHER THAN ASSUMED. PowerShell -match, -like and -replace
    fold case using the CURRENT CULTURE, and PowerShell 5.1 takes the thread's culture from
    the user regional settings. Verified in a tr-TR session on this machine:
        'INNOTEK GMBH' -match 'innotek'  ->  False      ('I'.ToLower('tr') is the dotless i)
        'NUTANIX AHV'  -match 'Nutanix'  ->  False
    ...both True in en-US. So a case-insensitive regex is NOT a culture-free test, and a
    VirtualBox guest on Turkish Windows would have been reported as physical hardware, which
    is a confident wrong answer. Every match in this file that has to survive a case
    DIFFERENCE upper-cases both sides through here and then uses -cmatch, which no culture
    can bend. (-eq and -contains are ordinal in PowerShell and were never affected; only the
    regex and wildcard operators are, which is why the -like tests on fixed-casing error ids
    are left alone.)
  #>
  param($Value)
  $s = "$Value"
  try { return $s.ToUpperInvariant() } catch { return $s }
}

function Get-CompatRegValue {
  <#
    One registry value, tri-state:
      present = $true   the value was read (data in .value)
      present = $false  the key or the value genuinely is not there
      present = $null   the read FAILED (denied / provider error) — NOT the same as absent
  #>
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
  $out = [ordered]@{ path = $Path; name = $Name; present = $null; value = $null; error = $null; accessDenied = $null }
  $exists = $null
  try { $exists = [bool](Test-Path -LiteralPath $Path -ErrorAction Stop) }
  catch {
    # A Test-Path that THREW proves nothing about whether the key is there, so present now
    # stays $null. It used to be set to $false for every non-denial error, which is a
    # measured negative produced by a read that never happened.
    $out.error = "$($_.Exception.Message)"
    $out.accessDenied = [bool](Test-CompatAccessDenied $_)
    return $out
  }
  if (-not $exists) { $out.present = $false; return $out }
  try {
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    $out.present = $true
    $out.value = $p.$Name
  } catch {
    if (Test-CompatAccessDenied $_) { $out.error = "$($_.Exception.Message)"; $out.accessDenied = $true; return $out }
    # "the key is there but this VALUE is not set" is the expected miss and a real $false.
    # Measured on Windows 11 25H2 (26200.9168): a missing value raises
    # System.Management.Automation.PSArgumentException (category InvalidArgument) and a
    # missing key raises ItemNotFoundException (PathNotFound). Any OTHER provider failure is
    # not evidence of absence, so it leaves present at $null - could not determine.
    $fq = ''
    try { $fq = "$($_.FullyQualifiedErrorId)" } catch {}
    $expectedMiss = ($fq -like 'PathNotFound*' -or $fq -like 'ItemNotFound*' -or $fq -like 'PropertyNotFound*')
    try { if ($_.Exception -is [System.Management.Automation.ItemNotFoundException]) { $expectedMiss = $true } } catch {}
    try { if ($_.Exception -is [System.Management.Automation.PSArgumentException]) { $expectedMiss = $true } } catch {}
    if ($expectedMiss) { $out.present = $false }
    else { $out.error = "$($_.Exception.Message)"; $out.accessDenied = $false }
  }
  return $out
}

function Get-CompatRegKey {
  <#
    Every value under one key.
      present = $true   the key exists AND its values were read (they are in .values)
      present = $false  the key genuinely does not exist
      present = $null   COULD NOT DETERMINE — the key could not be opened, or it opened but its
                        values were denied

    That last case is the one worth spelling out, because getting it wrong is a whole class of
    silent bug: on an administrator-ACLed key such as HKLM\...\CurrentVersion\SPP\Clients,
    Test-Path SUCCEEDS unelevated while Get-ItemProperty raises SecurityException. Setting
    present = $true from the Test-Path alone left an EMPTY .values behind, and every caller
    that then asked "is WUServer in here?" got a confident "no" out of a read that never
    happened. present is therefore only ever $true once the values are actually in hand.
    keyExists keeps the raw Test-Path answer as evidence.
  #>
  param([Parameter(Mandatory)][string]$Path)
  $out = [ordered]@{ path = $Path; present = $null; keyExists = $null; values = [ordered]@{}; error = $null; accessDenied = $null }
  try {
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { $out.keyExists = $false; $out.present = $false; return $out }
    $out.keyExists = $true
  } catch {
    $out.error = "$($_.Exception.Message)"
    $out.accessDenied = [bool](Test-CompatAccessDenied $_)
    return $out
  }
  try {
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    foreach ($n in @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
      $out.values[$n.Name] = $n.Value
    }
    $out.present = $true
  } catch {
    $out.error = "$($_.Exception.Message)"   # present stays $null: the key is there, its contents are not readable
    $out.accessDenied = [bool](Test-CompatAccessDenied $_)
  }
  return $out
}

# System32 vs SysWOW64. A 32-bit PowerShell host on 64-bit Windows has %SystemRoot%\System32
# silently redirected to SysWOW64, where several of these tools do not exist — and a Test-Path
# miss there would be reported as "sfc.exe is missing from this Windows image", a confident
# wrong answer of exactly the kind doctrine rule 2 forbids. Sysnative is the documented
# un-redirected view and exists ONLY for a 32-bit process on 64-bit Windows.
$script:SystemDir = $null
$script:SystemDirNote = $null
try {
  if ((-not [Environment]::Is64BitProcess) -and [Environment]::Is64BitOperatingSystem) {
    $script:SystemDir = (Join-Path $env:SystemRoot 'Sysnative')
    $script:SystemDirNote = 'This is a 32-bit PowerShell host on 64-bit Windows, so in-box tools are resolved through %SystemRoot%\Sysnative (the un-redirected view of System32) instead of the WOW64-redirected %SystemRoot%\System32.'
  } else {
    $script:SystemDir = (Join-Path $env:SystemRoot 'System32')
  }
} catch {
  $script:SystemDir = (Join-Path $env:SystemRoot 'System32')
  $script:SystemDirNote = 'Process/OS bitness could not be read, so in-box tools were resolved through %SystemRoot%\System32 without a WOW64 redirection check.'
}

function Test-CompatSystemFile {
  <# Is an in-box tool present? Tri-state; $null when the test itself failed. #>
  param([Parameter(Mandatory)][string]$Name)
  $path = (Join-Path $script:SystemDir $Name)
  $out = [ordered]@{ name = $Name; path = $path; present = $null; version = $null; error = $null }
  try { $out.present = [bool](Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) }
  catch { $out.error = "$($_.Exception.Message)"; return $out }
  if ($out.present -eq $true) {
    try { $out.version = "$((Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.FileVersion)" } catch {}
  }
  return $out
}

function Test-CompatCommand {
  <# Does a cmdlet / function / exe resolve? Tri-state; $null when the lookup itself threw. #>
  param([Parameter(Mandatory)][string]$Name)
  $out = [ordered]@{ name = $Name; present = $null; kind = $null; error = $null }
  try {
    $c = @(Get-Command -Name $Name -ErrorAction Stop) | Select-Object -First 1
    if ($null -ne $c) { $out.present = $true; $out.kind = "$($c.CommandType)" }
    else { $out.present = $false }
  } catch {
    # CommandNotFoundException is normally a real "no" — EXCEPT under application control, where
    # module auto-loading is restricted and a command that genuinely exists on disk still fails
    # to resolve (measured: Get-Volume is not found in a ConstrainedLanguage session on this
    # machine, where it resolves fine in FullLanguage). Reporting that as "this cmdlet does not
    # exist on this machine" would be a confident wrong statement in a bug report, so in
    # ConstrainedLanguage a miss stays $null — could not determine.
    $fq = ''
    try { $fq = "$($_.FullyQualifiedErrorId)" } catch {}
    if ($fq -like 'CommandNotFoundException*') {
      if ($script:FullLanguage) { $out.present = $false }
      else { $out.error = "Command discovery is restricted in $($script:LanguageMode); '$Name' did not resolve, which is not proof that it is absent from this machine." }
    }
    else { $out.error = "$($_.Exception.Message)" }
  }
  return $out
}

# Service START type, straight from the service's own registry key. This is the locale-free,
# elevation-free way to ask both "does this service still EXIST at all" (a debloat script's
# `sc delete` leaves no key behind) and "is it disabled" — Get-Service's Status strings are
# localized and its StartType property is not present on every host.
$script:ServiceStartNames = @{ 0 = 'boot'; 1 = 'system'; 2 = 'automatic'; 3 = 'manual'; 4 = 'disabled' }

function Get-CompatService {
  param([Parameter(Mandatory)][string]$Name)
  $out = [ordered]@{ name = $Name; present = $null; start = $null; startName = $null; error = $null }
  $k = Get-CompatRegKey ("HKLM:\SYSTEM\CurrentControlSet\Services\$Name")
  $out.present = $k.present
  $out.error   = $k.error
  if ($k.present -eq $true) {
    try {
      if (Test-KeyPresent $k.values 'Start') {
        $out.start = [int]$k.values['Start']
        if ($script:ServiceStartNames.ContainsKey($out.start)) { $out.startName = $script:ServiceStartNames[$out.start] }
      }
    } catch {}
  }
  return $out
}

function Get-CompatCim {
  <# One CIM query, never throwing. Returns @{ value = @(instances); error }. #>
  param([Parameter(Mandatory)][string]$ClassName, [string]$Namespace = 'root\cimv2', [string]$Filter)
  if ($Filter) { return (Invoke-Safely { @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop) }) }
  return (Invoke-Safely { @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop) })
}

function Write-CompatJson {
  <#
    Exactly ONE JSON document on stdout, BOM-free. [Console] is not on ConstrainedLanguage's
    allowed-type list, so the _lib writer (and its [Console]::Out) can throw on precisely the
    machines this script exists to describe. Falls back to the pipeline writer in that case.
  #>
  param([Parameter(Mandatory)]$InputObject, [int]$Depth = 14, [switch]$AsPretty)
  $json = $null
  try {
    if ($AsPretty) { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth }
    else           { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress }
  } catch {
    $json = '{"ok":false,"errorCode":"serialize-failed","error":"The compatibility report could not be serialized to JSON."}'
  }
  try { [Console]::Out.WriteLine($json); return } catch {}
  Write-Output $json
}

# ===========================================================================
# FACT TABLE
# ---------------------------------------------------------------------------
# Every capability verdict below is derived from this table and nothing else, so a verdict can
# always be traced back to the one signal that produced it. Values are strictly tri-state:
#   $true  measured present / yes
#   $false measured absent / no
#   $null  COULD NOT DETERMINE
# Get-Fact returns $null for an id that was never set, which is the safe direction (unknown,
# never "no") — and -Action selftest fails if any capability rule references a fact id that the
# probes do not produce, so a typo becomes a caught error rather than a silent "unknown".
# ===========================================================================
$script:Facts = [ordered]@{}

function Set-Fact {
  param([Parameter(Mandatory)][string]$Id, $Value, [string]$How = 'none', [string]$Detail = $null)
  $v = $null
  if ($null -ne $Value) { $v = [bool]$Value }
  $script:Facts[$Id] = [ordered]@{ id = $Id; value = $v; how = $How; detail = $Detail }
}
function Get-Fact { param([Parameter(Mandatory)][string]$Id) if (Test-KeyPresent $script:Facts $Id) { return $script:Facts[$Id].value } ; return $null }
function Get-FactDetail {
  <#
    THE PARENTHESES ARE LOAD-BEARING. Written without them -
        if (Test-KeyPresent $script:Facts $Id -and "..." -match ...)
    - PowerShell parses -and and everything after it as EXTRA ARGUMENTS to Test-KeyPresent,
    which is a simple function and silently collects them in $args. The second half of the
    test never ran. Measured before the fix: a declared fact whose detail was $null returned
    an EMPTY string, so a capability row could carry a blank reason instead of saying plainly
    that nothing had been read.
  #>
  param([Parameter(Mandatory)][string]$Id)
  if ((Test-KeyPresent $script:Facts $Id) -and (("$($script:Facts[$Id].detail)") -match '\S')) { return "$($script:Facts[$Id].detail)" }
  return "FrameForge has no reading for '$Id' on this machine, so nothing about it can be reported as measured."
}

function Select-CompatDetail {
  <#
    Pick the sentence that matches a TRI-STATE value.

    It exists because the obvious `if ($v -eq $true) { yes } else { no }` writes the measured-
    NEGATIVE sentence for $null as well. Several facts here were doing exactly that: the
    stored value was an honest $null while the prose beside it said "This machine is not
    joined to an Active Directory domain" - and the prose is what a user reads, and what a
    capability row quotes as its reason. Doctrine rule 2 governs the words, not only the
    boolean underneath them.
  #>
  param($Value, [string]$WhenTrue, [string]$WhenFalse, [string]$WhenNull)
  if ($Value -eq $true) { return $WhenTrue }
  if ($Value -eq $false) { return $WhenFalse }
  return $WhenNull
}
function Test-FactDeclared { param([Parameter(Mandatory)][string]$Id) return Test-KeyPresent $script:Facts $Id }

# ===========================================================================
# VERDICT VOCABULARY
# ---------------------------------------------------------------------------
# The rank mirrors health.ps1's status rank exactly (critical > warning > unknown > needs-admin
# > ok) so the two engines never disagree about which of two answers is worse:
#   unavailable  (critical) it cannot run here at all
#   degraded     (warning)  it runs, but with a named limitation
#   unknown      (unknown)  FrameForge could not determine whether it runs here
#   needs-admin  (needs-admin) it runs, elevated
#   supported    (ok)       measured available
# 'unknown' outranking 'needs-admin' and 'supported' is the whole doctrine in one line.
# ===========================================================================
$script:VerdictRank = [ordered]@{ 'supported' = 0; 'needs-admin' = 1; 'unknown' = 2; 'degraded' = 3; 'unavailable' = 4 }

# Every constraint code this file can emit, declared ONCE.
#
# Doctrine rule 5 says the catalog documents exactly what runs, and a reason code that
# reaches a user with no entry in data\compat.json is a gap in that promise. -Action selftest
# asserts this list and the catalog's constraintCodes table are the same set, and every
# constraint object carries a 'documented' flag so an undeclared code is visible in the output
# itself rather than only in a test.
$script:ConstraintCodes = @('powershell-too-old', 'powershell-version-undetermined',
  'constrained-language', 'language-mode-undetermined', 'unvalidated-platform', 'platform-undetermined',
  'missing-requirement', 'requirement-undetermined', 'missing-optional-dependency',
  'optional-dependency-undetermined', 'english-only-fallback-lost', 'ui-language-undetermined',
  'needs-elevation', 'elevation-undetermined', 'rule-evaluation-failed', 'no-capability-rule',
  'catalog-field-missing', 'not-applicable-on-this-build', 'build-undetermined',
  'restore-point-unavailable', 'restore-point-undetermined', 'child-script-blocked-by-policy',
  'execution-policy-undetermined', 'virtual-storage', 'no-store-on-this-edition', 'store-undetermined',
  'client-only-flow', 'ltsc-recovery-flow', 'remote-session', 'domain-time-hierarchy',
  'partial-without-admin', 'network-not-probed', 'server-app-installer', 'no-store-delivery',
  'managed-update-client', 'payload-source-blocked', 'wsus-payload-source')

function New-Constraint {
  param(
    [Parameter(Mandatory)][ValidateSet('supported','needs-admin','unknown','degraded','unavailable')][string]$Verdict,
    [Parameter(Mandatory)][string]$Code,
    [Parameter(Mandatory)][string]$Reason
  )
  [ordered]@{ verdict = $Verdict; code = $Code; reason = $Reason; documented = [bool]($script:ConstraintCodes -contains $Code) }
}

function Resolve-Verdict {
  <#
    The worst constraint wins; 'supported' only when a constraint list was actually handed in
    and every entry in it was understood.

    THIS IS THE ONE FUNCTION A FAILED PROBE MUST NOT BE ABLE TO WALK PAST, so it fails
    towards 'unknown' rather than towards a green tick. The previous version looked up
    $script:VerdictRank[$x.verdict] and compared with -gt; for a $null element, or a
    constraint carrying a verdict outside the vocabulary, that lookup returns $null,
    ($null -gt 0) is $false, and the loop left the answer at 'supported'. Measured before the
    fix, ALL FOUR of these returned 'supported':
        Resolve-Verdict $null
        Resolve-Verdict @($null)
        Resolve-Verdict @([ordered]@{ verdict = 'catastrophe' })
        Resolve-Verdict @([ordered]@{ code = 'x' })          # no verdict member at all
    Now: no list at all is 'unknown', and anything the vocabulary does not recognise is
    treated as 'unknown', which outranks 'supported' by construction. An EMPTY list still
    means 'supported' - that is the legitimate case, and it is the caller's job (see
    New-CapabilityRow) to state truthfully what was checked to produce it.
  #>
  param($Constraints)
  if ($null -eq $Constraints) { return 'unknown' }
  $c = @($Constraints)
  if ($c.Count -eq 0) { return 'supported' }
  $worst = 'supported'
  foreach ($x in $c) {
    $v = $null
    if ($null -ne $x) { try { $v = "$($x.verdict)" } catch {} }
    if (-not (Test-KeyPresent $script:VerdictRank $v)) { $v = 'unknown' }
    if ($script:VerdictRank[$v] -gt $script:VerdictRank[$worst]) { $worst = $v }
  }
  return $worst
}


# ===========================================================================
# PROBE 1 — OS identity
# ===========================================================================

# Win32_OperatingSystem.OperatingSystemSKU. Only SKUs that are actually documented are named;
# anything else keeps its raw number and a $null name. Guessing a SKU name would be a confident
# unmeasured answer, and the EditionID string beside it is the better identifier anyway.
$script:SkuNames = @{
  1 = 'Ultimate'; 2 = 'Home Basic'; 3 = 'Home Premium'; 4 = 'Enterprise'; 6 = 'Business'
  7 = 'Server Standard'; 8 = 'Server Datacenter'; 10 = 'Server Enterprise'; 11 = 'Starter'
  27 = 'Enterprise N'; 48 = 'Professional'; 49 = 'Professional N'; 98 = 'Home N'
  99 = 'Home China'; 100 = 'Home Single Language'; 101 = 'Home'; 121 = 'Education'
  122 = 'Education N'; 125 = 'Enterprise LTSC'; 126 = 'Enterprise N LTSC'
  161 = 'Pro for Workstations'; 162 = 'Pro for Workstations N'; 164 = 'Pro Education'
  165 = 'Pro Education N'; 175 = 'Enterprise for Virtual Desktops'; 191 = 'IoT Enterprise'
}

function Get-CompatOsIdentity {
  <#
    Build identity, edition identity and the supported-platform verdict.

    Ladder, and why it is a ladder:
      1. _lib.ps1's Get-FFOsInfo / Get-FFEdition. These are the SINGLE SOURCE OF TRUTH for the
         `supported` rule that repair.ps1 and image.ps1 are written against, so when the library
         is loaded its answer wins outright.
      2. A local read of the same two sources (HKLM\...\CurrentVersion + Win32_OperatingSystem),
         applying the same rule. This exists only so the compatibility check still produces an
         answer on a machine where _lib.ps1 could not be dot-sourced — which is precisely the
         kind of machine this report is for. `-Action selftest` asserts the two rungs AGREE
         whenever both are available, so the duplication is a checked invariant, not drift.

    NEVER read CurrentVersion\ProductName for the generation: on Windows 11 25H2 it literally
    reads "Windows 10 Pro". CurrentBuildNumber is the authority (>= 22000 is Windows 11).
  #>
  $out = [ordered]@{
    source = 'local'; libError = $null
    build = $null; ubr = $null; buildString = $null; displayVersion = $null; caption = $null
    installationType = $null; productType = $null; generation = $null
    editionId = $null; sku = $null; skuName = $null
    isN = $null; isNSource = 'none'; libIsN = $null; libIsNAgrees = $null
    isLtsc = $null; isServer = $null
    supported = $null; unsupportedReason = $null
    localAgreesWithLibrary = $null
  }

  # --- rung 2 first, so its answer is always available for the selftest cross-check ---
  $cv = Get-CompatRegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $osCim = Get-CompatCim -ClassName 'Win32_OperatingSystem'
  $localBuild = $null; $localUbr = $null; $localDisplay = $null; $localInstall = $null
  $localCaption = $null; $localProductType = $null; $localEdition = $null; $localSku = $null
  if ($cv.present -eq $true) {
    try { if (Test-KeyPresent $cv.values 'CurrentBuildNumber') { $localBuild = [int]$cv.values['CurrentBuildNumber'] } } catch {}
    try { if (Test-KeyPresent $cv.values 'UBR') { $localUbr = [int]$cv.values['UBR'] } } catch {}
    try { if (Test-KeyPresent $cv.values 'DisplayVersion') { $localDisplay = "$($cv.values['DisplayVersion'])" } } catch {}
    try { if (Test-KeyPresent $cv.values 'InstallationType') { $localInstall = "$($cv.values['InstallationType'])" } } catch {}
    try { if (Test-KeyPresent $cv.values 'EditionID') { $localEdition = "$($cv.values['EditionID'])" } } catch {}
  }
  if ($null -eq $osCim.error -and @($osCim.value).Count -gt 0) {
    $o = @($osCim.value)[0]
    try { $localCaption = "$($o.Caption)" } catch {}
    try { $localSku = [int]$o.OperatingSystemSKU } catch {}
    try { $localProductType = [int]$o.ProductType } catch {}
    if ($null -eq $localBuild) { try { $localBuild = [int]$o.BuildNumber } catch {} }
  }
  $localGeneration = $null
  if ($null -ne $localBuild) {
    if ($localBuild -ge 22000) { $localGeneration = 'win11' }
    elseif ($localBuild -ge 10240) { $localGeneration = 'win10' }
    else { $localGeneration = 'older' }
  }
  # Same rule as Get-FFOsInfo: a CLIENT installation on build >= 22000.
  $localSupported = $null
  if ($null -ne $localBuild -and "$localInstall" -match '\S') {
    $localSupported = ($localBuild -ge 22000 -and $localInstall -eq 'Client')
  }

  # --- rung 1 ---
  $libOs = $null; $libEd = $null
  if ($script:LibLoaded) {
    $a = Invoke-Safely { Get-FFOsInfo }
    $b = Invoke-Safely { Get-FFEdition }
    if ($null -eq $a.error) { $libOs = $a.value } else { $out.libError = $a.error }
    if ($null -eq $b.error) { $libEd = $b.value } elseif ($null -eq $out.libError) { $out.libError = $b.error }
  }

  if ($null -ne $libOs) {
    $out.source           = 'lib'
    $out.build            = $libOs.build
    $out.ubr              = $libOs.ubr
    $out.buildString      = $libOs.buildString
    $out.displayVersion   = $libOs.displayVersion
    $out.caption          = $libOs.caption
    $out.installationType = $libOs.installationType
    $out.productType      = $libOs.productType
    $out.generation       = $libOs.generation
    $out.supported        = $libOs.supported
    $out.unsupportedReason = $libOs.unsupportedReason
    if ($null -ne $localSupported -and $null -ne $libOs.supported) {
      $out.localAgreesWithLibrary = ([bool]$localSupported -eq [bool]$libOs.supported -and $localBuild -eq $libOs.build)
    }
  } else {
    $out.build            = $localBuild
    $out.ubr              = $localUbr
    $out.displayVersion   = $localDisplay
    $out.caption          = $localCaption
    $out.installationType = $localInstall
    $out.productType      = $localProductType
    $out.generation       = $localGeneration
    $out.supported        = $localSupported
    if ($null -ne $localBuild) {
      if ($null -ne $localUbr) { $out.buildString = "$localBuild.$localUbr" } else { $out.buildString = "$localBuild" }
    }
    if ($localSupported -eq $false) {
      if ("$localInstall" -ne 'Client') { $out.unsupportedReason = "This is a '$localInstall' installation (build $localBuild). FrameForge is validated on Windows 11 client builds only." }
      else { $out.unsupportedReason = "Windows build $localBuild is older than 22000 (Windows 11). FrameForge is validated on Windows 11 client builds only." }
    } elseif ($null -eq $localSupported) {
      $out.unsupportedReason = 'The Windows build number or installation type could not be read, so this platform cannot be confirmed as supported. That is "could not determine", not "yes".'
    }
  }

  if ($null -ne $libEd) {
    $out.editionId = $libEd.editionId
    $out.sku       = $libEd.sku
    $out.isLtsc    = $libEd.isLtsc
    $out.isServer  = $libEd.isServer
    $out.libIsN    = $libEd.isN
  } else {
    $out.editionId = $localEdition
    $out.sku       = $localSku
    if ("$localEdition" -match '\S') { $out.isLtsc = [bool](@('EnterpriseS', 'EnterpriseSN', 'IoTEnterprise', 'IoTEnterpriseS', 'IoTEnterpriseSK', 'ServerRdsh') -contains "$localEdition") }
    if ("$($out.installationType)" -match '\S') { $out.isServer = ($out.installationType -ne 'Client') }
  }

  # isN is computed HERE, from the final EditionID, and is deliberately NOT taken from the
  # library even when the library answered everything else.
  #
  # WHY: an N edition is one whose EditionID ends in a CAPITAL N - ProfessionalN,
  # EnterpriseSN. The shared rule (_lib.ps1 Get-FFEdition, and the copy that used to live
  # here) tested that case-INSENSITIVELY, so every EditionID merely ending in a lowercase
  # 'n' came back as an N edition. Measured: 'Education' -> isN True and 'CloudEdition' ->
  # isN True, both simply false. EditionID is a fixed PascalCase identifier baked into the
  # image, so a case-SENSITIVE suffix test separates them correctly; the handful of known
  # non-N ids that end in a lowercase n are listed as well, so the answer does not rest on
  # casing alone. _lib.ps1 keeps its own (still case-insensitive) answer, so it is recorded
  # beside this one as libIsN with an agreement flag - the same pattern this file already
  # uses for Test-Admin, so a disagreement shows up in a bug report instead of being hidden.
  if ("$($out.editionId)" -match '\S') {
    $ed = "$($out.editionId)"
    $notN = @('Education', 'ProfessionalEducation', 'CloudEdition', 'Cloud', 'CoreSingleLanguage', 'HomeChina', 'ServerSolution')
    if (@($notN) -contains $ed) { $out.isN = $false; $out.isNSource = 'editionid-known-non-n' }
    else { $out.isN = [bool]($ed -cmatch 'N$'); $out.isNSource = 'editionid-case-sensitive-suffix' }
  }
  if ($null -ne $out.libIsN -and $null -ne $out.isN) { $out.libIsNAgrees = ([bool]$out.libIsN -eq [bool]$out.isN) }
  if ($null -ne $out.sku -and $script:SkuNames.ContainsKey([int]$out.sku)) { $out.skuName = $script:SkuNames[[int]$out.sku] }

  return $out
}

function Get-CompatLanguage {
  <#
    Which language does this Windows speak — and specifically, IS IT ENGLISH?

    That last question is the one FrameForge cares about, because several probes in health.ps1
    and repair.ps1 keep a documented ENGLISH-ONLY text parse as their last-resort rung (sfc's
    console text, fsutil's 'is NOT Dirty', powercfg's 'Fast Startup', w32tm's status labels,
    chkdsk's schedule prompt). On a non-English UI those rungs simply never match, so the
    probe falls back to reporting "could not determine" — correct behaviour, but a real loss
    of fidelity that this report names instead of hiding.

    Every rung here is structural. There is deliberately no `dism /Get-Intl` rung (it needs
    elevation and is itself a text parse) — image.ps1 has one, this file does not need it.
      systemUi:  HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language InstallLanguage (hex LCID)
                 -> ...\Nls\Language Default -> [CultureInfo]::InstalledUICulture
      userUi:    HKCU\Control Panel\Desktop PreferredUILanguages (REG_MULTI_SZ, first entry)
                 -> [CultureInfo]::CurrentUICulture
    An INTERACTIVE console tool renders in the USER's UI language while a service or an
    elevated context can fall back to the installed one, so `english` is true only when BOTH
    are English, and $null when either could not be read.
  #>
  $out = [ordered]@{
    systemUiTag = $null; systemUiSource = 'unknown'; systemUiLcid = $null
    userUiTag   = $null; userUiSource   = 'unknown'
    installedUiCulture = $null; currentUiCulture = $null; systemLocale = $null
    english = $null; englishDetail = $null
    muiInstalledLanguages = @()
  }

  $inst = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name 'InstallLanguage'
  if ($inst.present -eq $true) {
    $r = Invoke-Safely {
      $ci = [System.Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32("$($inst.value)", 16))
      [ordered]@{ tag = $ci.Name; lcid = $ci.LCID }
    }
    if ($null -eq $r.error -and $null -ne $r.value) {
      $out.systemUiTag = "$($r.value.tag)"; $out.systemUiLcid = $r.value.lcid; $out.systemUiSource = 'registry-installlanguage'
    }
  }
  if ($null -eq $out.systemUiTag) {
    $def = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name 'Default'
    if ($def.present -eq $true) {
      $r = Invoke-Safely {
        $ci = [System.Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32("$($def.value)", 16))
        [ordered]@{ tag = $ci.Name; lcid = $ci.LCID }
      }
      if ($null -eq $r.error -and $null -ne $r.value) {
        $out.systemUiTag = "$($r.value.tag)"; $out.systemUiLcid = $r.value.lcid; $out.systemUiSource = 'registry-nls-default'
      }
    }
  }
  $iuc = Invoke-Safely { "$([System.Globalization.CultureInfo]::InstalledUICulture.Name)" }
  if ($null -eq $iuc.error) { $out.installedUiCulture = $iuc.value }
  if ($null -eq $out.systemUiTag -and "$($out.installedUiCulture)" -match '\S') {
    $out.systemUiTag = $out.installedUiCulture; $out.systemUiSource = 'installed-ui-culture'
  }

  $pref = Get-CompatRegValue -Path 'HKCU:\Control Panel\Desktop' -Name 'PreferredUILanguages'
  if ($pref.present -eq $true) {
    $first = $null
    try { $first = "$(@($pref.value) | Where-Object { "$_" -match '\S' } | Select-Object -First 1)" } catch {}
    if ("$first" -match '\S') { $out.userUiTag = "$first".Trim(); $out.userUiSource = 'registry-preferreduilanguages' }
  }
  $cuc = Invoke-Safely { "$([System.Globalization.CultureInfo]::CurrentUICulture.Name)" }
  if ($null -eq $cuc.error) { $out.currentUiCulture = $cuc.value }
  if ($null -eq $out.userUiTag -and "$($out.currentUiCulture)" -match '\S') {
    $out.userUiTag = $out.currentUiCulture; $out.userUiSource = 'current-ui-culture'
  }

  $sl = Invoke-Safely { "$([System.Globalization.CultureInfo]::CurrentCulture.Name)" }
  if ($null -eq $sl.error) { $out.systemLocale = $sl.value }

  $mui = Invoke-Safely { @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages' -ErrorAction Stop | ForEach-Object { $_.PSChildName }) }
  if ($null -eq $mui.error -and $null -ne $mui.value) { $out.muiInstalledLanguages = @($mui.value) }

  # Upper-cased through the invariant helper and matched case-SENSITIVELY: an inline (?i) is
  # folded with the current culture, which is not a culture-free test (see
  # ConvertTo-CompatInvariantUpper). No English tag is affected by the Turkish rule today,
  # but the whole point of this probe is to be right on a machine whose language we do not
  # know, so it does not get to rely on that.
  $sysEn = $null; $userEn = $null
  if ("$($out.systemUiTag)" -match '\S') { $sysEn = [bool]((ConvertTo-CompatInvariantUpper $out.systemUiTag) -cmatch '^EN(-|$)') }
  if ("$($out.userUiTag)"   -match '\S') { $userEn = [bool]((ConvertTo-CompatInvariantUpper $out.userUiTag) -cmatch '^EN(-|$)') }
  if ($null -eq $sysEn -or $null -eq $userEn) {
    $out.english = $null
    $out.englishDetail = "Whether this Windows speaks English could not be determined (installed UI language: $(if ($null -eq $out.systemUiTag) { 'unreadable' } else { $out.systemUiTag }), current user UI language: $(if ($null -eq $out.userUiTag) { 'unreadable' } else { $out.userUiTag })). FrameForge therefore cannot say whether the English-text fallback rungs in its probes will match here."
  } elseif ($sysEn -and $userEn) {
    $out.english = $true
    $out.englishDetail = "This Windows speaks English (installed UI language $($out.systemUiTag), current user UI language $($out.userUiTag)), so the documented English-only fallback rungs in FrameForge's probes can still match."
  } else {
    $out.english = $false
    $out.englishDetail = "This Windows does not present an English UI (installed UI language $($out.systemUiTag), current user UI language $($out.userUiTag)). Windows tools answer in that language, so the documented English-only LAST-RESORT rungs in some FrameForge probes will never match here. Those probes fall back to their structural rung, and where there is none they report 'could not determine' — never a guess."
  }
  return $out
}

function Get-CompatSystemDrive {
  <#
    Which volume is Windows on? Three independent sources, reported together, because every
    drive-scoped repair (chkdsk, temp-clean, the restore-point volume) is aimed at this letter
    and an environment variable alone is trivially overridable.
  #>
  $out = [ordered]@{ letter = $null; source = 'unknown'; envSystemDrive = $null; cimSystemDrive = $null; registrySystemRoot = $null; agree = $null }
  try { $out.envSystemDrive = "$env:SystemDrive" } catch {}
  $osCim = Get-CompatCim -ClassName 'Win32_OperatingSystem'
  if ($null -eq $osCim.error -and @($osCim.value).Count -gt 0) {
    try { $out.cimSystemDrive = "$(@($osCim.value)[0].SystemDrive)" } catch {}
    try { $out.registrySystemRoot = "$(@($osCim.value)[0].SystemDirectory)" } catch {}
  }
  $sr = Get-CompatRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'SystemRoot'
  $regDrive = $null
  if ($sr.present -eq $true -and "$($sr.value)" -match '^([A-Za-z]:)') { $regDrive = $Matches[1] }
  if ("$($out.cimSystemDrive)" -match '^[A-Za-z]:$') { $out.letter = $out.cimSystemDrive.ToUpperInvariant(); $out.source = 'cim-win32-operatingsystem' }
  elseif ($null -ne $regDrive) { $out.letter = $regDrive.ToUpperInvariant(); $out.source = 'registry-systemroot' }
  elseif ("$($out.envSystemDrive)" -match '^[A-Za-z]:$') { $out.letter = $out.envSystemDrive.ToUpperInvariant(); $out.source = 'environment-systemdrive' }
  $seen = @(@($out.envSystemDrive, $out.cimSystemDrive, $regDrive) | Where-Object { "$_" -match '^[A-Za-z]:$' } | ForEach-Object { "$_".ToUpperInvariant() } | Select-Object -Unique)
  if ($seen.Count -gt 0) { $out.agree = ($seen.Count -eq 1) }
  return $out
}

function Get-CompatArchitecture {
  <#
    The OS architecture, NOT the process architecture. $env:PROCESSOR_ARCHITECTURE describes the
    PROCESS: a 32-bit PowerShell host on 64-bit Windows reports 'x86'. Same ladder image.ps1
    uses, for the same reason.
      1. PROCESSOR_ARCHITEW6432 — set only under WOW64, and it holds the real OS architecture
      2. [RuntimeInformation]::OSArchitecture — .NET's own OS-level answer
      3. Win32_Processor.Architecture (0=x86, 5=ARM, 9=x64, 12=ARM64)
      4. PROCESSOR_ARCHITECTURE — the process answer, last, and labelled as such
  #>
  $out = [ordered]@{ value = $null; source = 'unknown'; wow64 = $null; processArchitecture = $null; is64BitProcess = $null; is64BitOs = $null }
  # Upper-cased invariantly and matched case-sensitively: the x86 alternation contains i386
  # and i686, and a case-insensitive regex folds 'I' with the CURRENT culture, which in
  # tr-TR does not fold to i. See ConvertTo-CompatInvariantUpper.
  $norm = {
    param($v)
    switch -CaseSensitive -Regex (ConvertTo-CompatInvariantUpper $v) {
      '^(AMD64|X64)$'     { return 'x64' }
      '^ARM64$'           { return 'arm64' }
      '^(X86|I386|I686)$' { return 'x86' }
      '^ARM$'             { return 'arm' }
    }
    return $null
  }
  try { $out.processArchitecture = (& $norm $env:PROCESSOR_ARCHITECTURE) } catch {}
  try { $out.is64BitProcess = [Environment]::Is64BitProcess } catch {}
  try { $out.is64BitOs = [Environment]::Is64BitOperatingSystem } catch {}
  $w6432 = $null
  try { $w6432 = (& $norm $env:PROCESSOR_ARCHITEW6432) } catch {}
  if ($null -ne $w6432) { $out.value = $w6432; $out.source = 'processor-architew6432'; $out.wow64 = $true; return $out }
  $out.wow64 = $false
  $rt = Invoke-Safely { "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
  if ($null -eq $rt.error) {
    $v = (& $norm $rt.value)
    if ($null -ne $v) { $out.value = $v; $out.source = 'runtimeinformation-osarchitecture'; return $out }
  }
  $cpu = Get-CompatCim -ClassName 'Win32_Processor'
  if ($null -eq $cpu.error -and @($cpu.value).Count -gt 0) {
    $a = $null
    try { $a = [int]@($cpu.value)[0].Architecture } catch {}
    switch ($a) {
      0  { $out.value = 'x86';   $out.source = 'cim-win32-processor'; return $out }
      5  { $out.value = 'arm';   $out.source = 'cim-win32-processor'; return $out }
      9  { $out.value = 'x64';   $out.source = 'cim-win32-processor'; return $out }
      12 { $out.value = 'arm64'; $out.source = 'cim-win32-processor'; return $out }
    }
  }
  if ($null -ne $out.processArchitecture) { $out.value = $out.processArchitecture; $out.source = 'process-architecture-only' }
  return $out
}

# ===========================================================================
# PROBE 2 — form factor
# ===========================================================================

# Win32_SystemEnclosure.ChassisTypes. Only the codes that are unambiguous are used; anything
# else leaves the verdict $null rather than forcing it into 'desktop'.
$script:PortableChassis = @(8, 9, 10, 11, 12, 14, 30, 31, 32)
$script:StationaryChassis = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 28, 34, 35, 36)

# Two query-only Win32 APIs that answer questions nothing else on the machine answers honestly.
# Both need Add-Type, so both are FullLanguage-only and every caller has a fallback rung beneath.
#
#   SYSTEM_POWER_CAPABILITIES via CallNtPowerInformation — the structured, locale-free answer to
#   "does this machine use Modern Standby". powercfg /a would also say so, in the user's language,
#   with a localized feature label; that is exactly why it is not used. _lib.ps1 already declares
#   its own copy of this struct, so this one carries a DIFFERENT type name — Add-Type would throw
#   on a duplicate, and losing the probe to a name collision would be a self-inflicted "unknown".
#   The struct must be the full 76 bytes: CallNtPowerInformation returns STATUS_BUFFER_TOO_SMALL
#   (0xC0000023) for a short one rather than filling in what fits.
#
#   TokenElevationType — the answer to "could this user elevate if they wanted to".
#   THIS EXISTS BECAUSE THE OBVIOUS APPROACH IS WRONG, measured on this machine: a UAC-filtered
#   administrator token carries S-1-5-32-544 as DENY-ONLY, `whoami /groups` lists it, and
#   .NET's WindowsIdentity.Groups DOES NOT — it filters deny-only SIDs out. So walking .Groups
#   for the Administrators SID reports a perfectly ordinary unelevated admin as "not an
#   administrator", which is a confident wrong answer that would then tell the user to go find
#   an administrator when they are one. TokenElevationType says it outright: 3 = Limited, i.e. a
#   split token exists, i.e. this user is an administrator who has simply not elevated.
$script:SysApiReady = $null
function Initialize-CompatSysApi {
  if ($null -ne $script:SysApiReady) { return $script:SysApiReady }
  $script:SysApiReady = $false
  if (-not $script:FullLanguage) { return $false }
  try {
    if (-not ('FFCompatToken' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct FF_COMPAT_POWER_CAPS {
  [MarshalAs(UnmanagedType.I1)] public bool PowerButtonPresent;
  [MarshalAs(UnmanagedType.I1)] public bool SleepButtonPresent;
  [MarshalAs(UnmanagedType.I1)] public bool LidPresent;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS1;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS2;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS3;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS4;
  [MarshalAs(UnmanagedType.I1)] public bool SystemS5;
  [MarshalAs(UnmanagedType.I1)] public bool HiberFilePresent;
  [MarshalAs(UnmanagedType.I1)] public bool FullWake;
  [MarshalAs(UnmanagedType.I1)] public bool VideoDimPresent;
  [MarshalAs(UnmanagedType.I1)] public bool ApmPresent;
  [MarshalAs(UnmanagedType.I1)] public bool UpsPresent;
  [MarshalAs(UnmanagedType.I1)] public bool ThermalControl;
  [MarshalAs(UnmanagedType.I1)] public bool ProcessorThrottle;
  public byte ProcessorMinThrottle;
  public byte ProcessorMaxThrottle;
  [MarshalAs(UnmanagedType.I1)] public bool FastSystemS4;
  [MarshalAs(UnmanagedType.I1)] public bool Hiberboot;
  [MarshalAs(UnmanagedType.I1)] public bool WakeAlarmPresent;
  [MarshalAs(UnmanagedType.I1)] public bool AoAc;
  [MarshalAs(UnmanagedType.I1)] public bool DiskSpinDown;
  public byte HiberFileType;
  [MarshalAs(UnmanagedType.I1)] public bool AoAcConnectivitySupported;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] spare3;
  [MarshalAs(UnmanagedType.I1)] public bool SystemBatteriesPresent;
  [MarshalAs(UnmanagedType.I1)] public bool BatteriesAreShortTerm;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public uint[] BatteryScale;
  public uint AcOnLineWake;
  public uint SoftLidWake;
  public uint RtcWake;
  public uint MinDeviceWakeState;
  public uint DefaultLowLatencyWake;
}
public static class FFCompatPower {
  [DllImport("powrprof.dll", SetLastError = true)]
  private static extern uint CallNtPowerInformation(int InformationLevel, IntPtr lpInputBuffer,
      uint nInputBufferSize, ref FF_COMPAT_POWER_CAPS lpOutputBuffer, uint nOutputBufferSize);
  // SystemPowerCapabilities = 4. Read-only: this level takes no input buffer and changes nothing.
  public static uint Capabilities(ref FF_COMPAT_POWER_CAPS caps) {
    uint size = (uint)Marshal.SizeOf(typeof(FF_COMPAT_POWER_CAPS));
    return CallNtPowerInformation(4, IntPtr.Zero, 0, ref caps, size);
  }
}
public static class FFCompatToken {
  [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
  [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int infoClass, ref int info, int len, out int returned);
  [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
  private const uint TOKEN_QUERY = 0x0008;          // query only; no TOKEN_ADJUST_* is ever asked for
  private const int TokenElevationType = 18;
  // 1 = Default (no split token), 2 = Full (elevated), 3 = Limited (UAC-filtered administrator).
  // -1 / -2 mean the token could not be read, which callers must treat as "could not determine".
  public static int ElevationType() {
    IntPtr tok = IntPtr.Zero;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out tok)) { return -1; }
    try {
      int value = 0; int returned = 0;
      if (!GetTokenInformation(tok, TokenElevationType, ref value, sizeof(int), out returned)) { return -2; }
      return value;
    } finally { if (tok != IntPtr.Zero) { CloseHandle(tok); } }
  }
}
'@
    }
    $script:SysApiReady = $true
  } catch {}
  return $script:SysApiReady
}

function Get-CompatPowerCaps {
  <# @{ available; aoac; systemS3; systemS4; hiberFilePresent; batteriesPresent; ntStatus; error } #>
  $out = [ordered]@{ available = $false; aoac = $null; systemS3 = $null; systemS4 = $null; hiberFilePresent = $null; batteriesPresent = $null; ntStatus = $null; error = $null }
  if (-not (Initialize-CompatSysApi)) {
    $out.error = "The power capabilities API could not be compiled (language mode: $script:LanguageMode)."
    return $out
  }
  $r = Invoke-Safely {
    $caps = New-Object FF_COMPAT_POWER_CAPS
    $rc = [FFCompatPower]::Capabilities([ref]$caps)
    [ordered]@{ rc = $rc; caps = $caps }
  }
  if ($null -ne $r.error) { $out.error = $r.error; return $out }
  $out.ntStatus = ('0x{0:X8}' -f $r.value.rc)
  if ($r.value.rc -ne 0) {
    $out.error = "CallNtPowerInformation(SystemPowerCapabilities) returned NTSTATUS $($out.ntStatus)."
    return $out
  }
  $c = $r.value.caps
  $out.available = $true
  $out.aoac = [bool]$c.AoAc
  $out.systemS3 = [bool]$c.SystemS3
  $out.systemS4 = [bool]$c.SystemS4
  $out.hiberFilePresent = [bool]$c.HiberFilePresent
  $out.batteriesPresent = [bool]$c.SystemBatteriesPresent
  return $out
}

function Get-CompatFormFactor {
  $out = [ordered]@{
    isPortable = $null; portableSource = 'unknown'; portableDetail = $null
    batteryCount = $null; chassisTypes = @(); chassisNote = $null
    modernStandby = $null; modernStandbySource = 'unknown'; modernStandbyDetail = $null
    csEnabled = $null; platformAoAcOverride = $null; s3Available = $null; batteriesPresentApi = $null
    hibernationAvailable = $null; fastStartupCapable = $null; powerCapsSource = 'unknown'
  }

  $caps = Get-CompatPowerCaps
  if ($caps.available) {
    $out.s3Available = $caps.systemS3
    $out.batteriesPresentApi = $caps.batteriesPresent
    $out.hibernationAvailable = $caps.systemS4
    $out.fastStartupCapable = ($caps.systemS4 -and $caps.hiberFilePresent)
    $out.powerCapsSource = 'callntpowerinformation'
  }

  $bat = Get-CompatCim -ClassName 'Win32_Battery'
  if ($null -eq $bat.error) { $out.batteryCount = @($bat.value).Count }
  $enc = Get-CompatCim -ClassName 'Win32_SystemEnclosure'
  if ($null -eq $enc.error) {
    foreach ($e in @($enc.value)) { foreach ($t in @($e.ChassisTypes)) { try { $out.chassisTypes += [int]$t } catch {} } }
  }
  $chassisPortable = $null
  if (@($out.chassisTypes).Count -gt 0) {
    if (@($out.chassisTypes | Where-Object { $script:PortableChassis -contains $_ }).Count -gt 0) { $chassisPortable = $true }
    elseif (@($out.chassisTypes | Where-Object { $script:StationaryChassis -contains $_ }).Count -gt 0) { $chassisPortable = $false }
    else { $out.chassisNote = "The SMBIOS chassis type(s) $($out.chassisTypes -join ', ') are not in FrameForge's portable or stationary list, so the chassis says nothing either way here." }
  }
  if ($out.batteryCount -gt 0) {
    $out.isPortable = $true; $out.portableSource = 'win32-battery'
    $out.portableDetail = "$($out.batteryCount) system battery(ies) reported by Win32_Battery — this is a portable machine, so power policy and thermal behaviour differ from a desktop."
  } elseif ($out.batteriesPresentApi -eq $true) {
    $out.isPortable = $true; $out.portableSource = 'system-power-capabilities'
    $out.portableDetail = 'Win32_Battery returned no instance, but SYSTEM_POWER_CAPABILITIES reports SystemBatteriesPresent — a portable machine whose battery class is not enumerating right now.'
  } elseif ($chassisPortable -eq $true) {
    $out.isPortable = $true; $out.portableSource = 'smbios-chassis'
    $out.portableDetail = "No battery instance was returned, but the SMBIOS chassis type ($($out.chassisTypes -join ', ')) is a portable one."
  } elseif ($out.batteryCount -eq 0 -and $chassisPortable -eq $false) {
    $out.isPortable = $false; $out.portableSource = 'win32-battery+smbios-chassis'
    $out.portableDetail = "No system battery and a stationary SMBIOS chassis type ($($out.chassisTypes -join ', ')) — a desktop."
  } else {
    $out.portableDetail = 'Whether this is a portable machine could not be determined: neither Win32_Battery nor the SMBIOS chassis type gave a usable answer.'
  }

  # Modern Standby (Connected Standby / AoAc), most structural rung first:
  #   1. SYSTEM_POWER_CAPABILITIES.AoAc — the platform's own answer, locale-free, unelevated,
  #      and corroborated by SystemS3 (a Modern Standby machine has NO S3 sleep state).
  #   2. HKLM\SYSTEM\CurrentControlSet\Control\Power\CsEnabled — the documented registry state,
  #      readable even in ConstrainedLanguage where rung 1 cannot be compiled.
  #   3. PlatformAoAcOverride.
  #   4. Honest unknown. powercfg /a would also answer — in the user's language, with a
  #      localized feature label — which is exactly why it is not a rung here.
  $cs = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'CsEnabled'
  if ($cs.present -eq $true) { try { $out.csEnabled = [int]$cs.value } catch {} }
  $ov = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'PlatformAoAcOverride'
  if ($ov.present -eq $true) { try { $out.platformAoAcOverride = [int]$ov.value } catch {} }
  if ($null -ne $caps.aoac) {
    $out.modernStandby = $caps.aoac
    $out.modernStandbySource = 'system-power-capabilities-aoac'
    if ($caps.aoac) {
      $out.modernStandbyDetail = 'This machine uses Modern Standby (Connected Standby): SYSTEM_POWER_CAPABILITIES reports AoAc. It has no S3 sleep state, so anything reasoning about classic sleep does not apply here.'
    } else {
      $out.modernStandbyDetail = "This machine does not use Modern Standby: SYSTEM_POWER_CAPABILITIES reports AoAc off$(if ($caps.systemS3 -eq $true) { ' and the classic S3 sleep state present' }). Sleep here is the classic S3 path."
    }
  } elseif ($null -ne $out.csEnabled) {
    $out.modernStandby = ($out.csEnabled -eq 1)
    $out.modernStandbySource = 'registry-csenabled'
    if ($out.modernStandby) { $out.modernStandbyDetail = 'This machine uses Modern Standby (Connected Standby): HKLM\SYSTEM\CurrentControlSet\Control\Power\CsEnabled = 1. It has no S3 sleep state, so anything reasoning about classic sleep does not apply here.' }
    else { $out.modernStandbyDetail = 'This machine does not use Modern Standby (CsEnabled = 0); it uses the classic S3 sleep path.' }
  } elseif ($null -ne $out.platformAoAcOverride) {
    $out.modernStandby = ($out.platformAoAcOverride -ne 0)
    $out.modernStandbySource = 'registry-platformaoacoverride'
    $out.modernStandbyDetail = "CsEnabled was not present; PlatformAoAcOverride = $($out.platformAoAcOverride) was used instead."
  } else {
    $out.modernStandbyDetail = "Modern Standby support could not be determined: the power capabilities API did not answer ($($caps.error)) and neither CsEnabled nor PlatformAoAcOverride was readable under HKLM\SYSTEM\CurrentControlSet\Control\Power."
  }

  if ($null -eq $out.hibernationAvailable) {
    $he = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    if ($he.present -eq $true) {
      try { $out.hibernationAvailable = ([int]$he.value -eq 1) } catch {}
      if ($null -ne $out.hibernationAvailable) { $out.powerCapsSource = 'registry-hibernateenabled' }
    }
  }
  return $out
}

function Get-CompatVirtualization {
  <#
    Virtual machine or physical hardware?

    Decided from VENDOR IDENTITY strings (Win32_ComputerSystem Manufacturer/Model,
    Win32_BIOS Manufacturer). Those are brand names burned into firmware — they are not
    localized prose, which is what makes this a legitimate string match where a message-text
    match would not be.

    HypervisorPresent is reported but DELIBERATELY NOT USED as the verdict. On ordinary
    physical Windows 11 it is $true whenever Virtualisation-Based Security, HVCI, WSL2, the
    Hyper-V role or Windows Sandbox is on — which is most gaming desktops, including the one
    this engine was written on. Calling that "a virtual machine" would be a confident wrong
    answer, and confident wrong answers are the one thing this codebase will not ship.
  #>
  $out = [ordered]@{
    isVirtual = $null; source = 'unknown'; detail = $null
    manufacturer = $null; model = $null; biosManufacturer = $null; systemFamily = $null
    hypervisorPresent = $null; hypervisorNote = $null; matchedVendor = $null
  }
  $cs = Get-CompatCim -ClassName 'Win32_ComputerSystem'
  if ($null -eq $cs.error -and @($cs.value).Count -gt 0) {
    $c = @($cs.value)[0]
    try { $out.manufacturer = "$($c.Manufacturer)" } catch {}
    try { $out.model = "$($c.Model)" } catch {}
    try { $out.systemFamily = "$($c.SystemFamily)" } catch {}
    try { if ($null -ne $c.HypervisorPresent) { $out.hypervisorPresent = [bool]$c.HypervisorPresent } } catch {}
  }
  $bios = Get-CompatCim -ClassName 'Win32_BIOS'
  if ($null -eq $bios.error -and @($bios.value).Count -gt 0) {
    try { $out.biosManufacturer = "$(@($bios.value)[0].Manufacturer)" } catch {}
  }
  $out.hypervisorNote = 'HypervisorPresent is reported for completeness only. It is true on ordinary physical Windows 11 machines running VBS/HVCI, WSL2, Windows Sandbox or the Hyper-V role, so it is never used here to decide that a machine is virtual.'

  $blob = (@($out.manufacturer, $out.model, $out.biosManufacturer, $out.systemFamily) -join ' | ')
  $blobUpper = (ConvertTo-CompatInvariantUpper $blob)
  $vendors = [ordered]@{
    'VMware'          = 'VMware'
    'VirtualBox'      = 'Oracle VirtualBox'
    'innotek'         = 'Oracle VirtualBox'
    'QEMU'            = 'QEMU/KVM'
    'Xen'             = 'Xen'
    'Parallels'       = 'Parallels'
    'Bochs'           = 'Bochs'
    'Virtual Machine' = 'Microsoft Hyper-V'
    'Amazon EC2'      = 'Amazon EC2'
    'Google Compute Engine' = 'Google Compute Engine'
    'Nutanix'         = 'Nutanix AHV'
    'oVirt'           = 'oVirt'
    'Apple Virtualization' = 'Apple Virtualization'
  }
  # Two things this loop gets right that the obvious version does not.
  #   1. Both sides are upper-cased invariantly and matched with -cmatch. A plain -match is
  #      folded with the CURRENT culture, and measured in tr-TR on this machine
  #      \"INNOTEK GMBH\" -match 'innotek' is False - a VirtualBox guest on Turkish Windows
  #      reported as physical hardware.
  #   2. The needle is anchored so it cannot match INSIDE a longer word. Without the
  #      lookarounds a machine whose model contains 'XENON' matches the 'Xen' vendor key and
  #      is declared a virtual machine. The lookarounds exclude only letters, not digits, so
  #      real firmware strings like VMWARE7,1 still match.
  foreach ($k in @($vendors.Keys)) {
    $needle = [regex]::Escape((ConvertTo-CompatInvariantUpper $k))
    if ($blobUpper -cmatch ('(?<![A-Z])' + $needle + '(?![A-Z])')) {
      $out.isVirtual = $true; $out.source = 'firmware-vendor-identity'; $out.matchedVendor = $vendors[$k]
      $out.detail = "This looks like a virtual machine: the firmware/system identity contains '$k' ($($vendors[$k])). Hardware-facing findings — SSD wear, disk media errors, thermal behaviour — describe the host's virtual devices, not real hardware."
      return $out
    }
  }
  if ("$($out.manufacturer)" -match '\S' -and "$($out.model)" -match '\S') {
    $out.isVirtual = $false; $out.source = 'firmware-vendor-identity'
    $out.detail = "Physical hardware: the firmware identity ($($out.manufacturer) / $($out.model)) matches no known hypervisor vendor."
  } else {
    $out.detail = 'Whether this is a virtual machine could not be determined: Win32_ComputerSystem did not return a manufacturer and model to match against.'
  }
  return $out
}

# Display geometry. EnumDisplaySettingsW returns the CURRENT MODE in real, physical pixels and
# is unaffected by the DPI virtualization that makes GetSystemMetrics lie to a DPI-unaware host
# such as powershell.exe — which is why the metrics call is not used for the size. GetDpiForSystem
# is the system DPI (96 = 100%). Both need Add-Type, so both are FullLanguage-only; the CIM rung
# below covers ConstrainedLanguage.
$script:DisplayApiReady = $null
function Initialize-CompatDisplayApi {
  if ($null -ne $script:DisplayApiReady) { return $script:DisplayApiReady }
  $script:DisplayApiReady = $false
  if (-not $script:FullLanguage) { return $false }
  try {
    if (-not ('FFCompatDisplay' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct FF_COMPAT_DEVMODE {
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
  public ushort dmSpecVersion;
  public ushort dmDriverVersion;
  public ushort dmSize;
  public ushort dmDriverExtra;
  public uint   dmFields;
  public int    dmPositionX;
  public int    dmPositionY;
  public uint   dmDisplayOrientation;
  public uint   dmDisplayFixedOutput;
  public short  dmColor;
  public short  dmDuplex;
  public short  dmYResolution;
  public short  dmTTOption;
  public short  dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
  public ushort dmLogPixels;
  public uint   dmBitsPerPel;
  public uint   dmPelsWidth;
  public uint   dmPelsHeight;
  public uint   dmDisplayFlags;
  public uint   dmDisplayFrequency;
  public uint   dmICMMethod;
  public uint   dmICMIntent;
  public uint   dmMediaType;
  public uint   dmDitherType;
  public uint   dmReserved1;
  public uint   dmReserved2;
  public uint   dmPanningWidth;
  public uint   dmPanningHeight;
}
public static class FFCompatDisplay {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref FF_COMPAT_DEVMODE lpDevMode);
  [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
  private const int ENUM_CURRENT_SETTINGS = -1;
  // Query only: EnumDisplaySettings READS a mode. ChangeDisplaySettings, the mutating call, is
  // not imported here and never will be.
  public static bool CurrentMode(ref FF_COMPAT_DEVMODE dm) {
    dm.dmSize = (ushort)Marshal.SizeOf(typeof(FF_COMPAT_DEVMODE));
    return EnumDisplaySettingsW(null, ENUM_CURRENT_SETTINGS, ref dm);
  }
  // -1 when the export is missing (GetDpiForSystem is Windows 10 1607+).
  public static int SystemDpi() { try { return (int)GetDpiForSystem(); } catch { return -1; } }
  // SM_REMOTESESSION = 0x1000
  public static int RemoteSession() { return GetSystemMetrics(0x1000); }
}
'@
    }
    $script:DisplayApiReady = $true
  } catch {}
  return $script:DisplayApiReady
}

function Get-CompatDisplay {
  $out = [ordered]@{
    primaryWidth = $null; primaryHeight = $null; refreshHz = $null; bitsPerPixel = $null
    resolutionSource = 'unknown'; dpi = $null; scalePercent = $null; dpiSource = 'unknown'
    remoteSession = $null; detail = $null; note = $null
  }
  if (Initialize-CompatDisplayApi) {
    $r = Invoke-Safely {
      $dm = New-Object FF_COMPAT_DEVMODE
      $ok = [FFCompatDisplay]::CurrentMode([ref]$dm)
      [ordered]@{ ok = $ok; w = $dm.dmPelsWidth; h = $dm.dmPelsHeight; hz = $dm.dmDisplayFrequency; bpp = $dm.dmBitsPerPel }
    }
    if ($null -eq $r.error -and $null -ne $r.value -and $r.value.ok) {
      $out.primaryWidth = [int]$r.value.w; $out.primaryHeight = [int]$r.value.h
      $out.refreshHz = [int]$r.value.hz; $out.bitsPerPixel = [int]$r.value.bpp
      $out.resolutionSource = 'enumdisplaysettings-current-mode'
    }
    $d = Invoke-Safely { [FFCompatDisplay]::SystemDpi() }
    if ($null -eq $d.error -and [int]$d.value -gt 0) {
      $out.dpi = [int]$d.value
      $out.scalePercent = [int](($out.dpi / 96.0) * 100)
      $out.dpiSource = 'getdpiforsystem'
    }
    $rs = Invoke-Safely { [FFCompatDisplay]::RemoteSession() }
    if ($null -eq $rs.error) { $out.remoteSession = ([int]$rs.value -ne 0) }
  } else {
    $out.note = "The display query API could not be used (language mode: $script:LanguageMode), so the values below come from the cached CIM/registry rungs."
  }

  if ($null -eq $out.primaryWidth) {
    # LAST RESORT, and labelled as one. Win32_VideoController reports one row per ADAPTER, not
    # per monitor, and its CurrentHorizontalResolution is the mode the driver last configured —
    # so on a multi-monitor machine it can describe a monitor that is not the primary one.
    # Measured on this box: the adapter row says 2560x1440@59 while the actual PRIMARY display
    # (\\.\DISPLAY2) is running 1920x1080@241. The value is still worth reporting, but it is
    # marked as not-necessarily-primary rather than passed off as the answer.
    $vc = Get-CompatCim -ClassName 'Win32_VideoController'
    foreach ($g in @($vc.value)) {
      $w = $null; $h = $null
      try { $w = [int]$g.CurrentHorizontalResolution; $h = [int]$g.CurrentVerticalResolution } catch {}
      if ($w -gt 0 -and $h -gt 0) {
        $out.primaryWidth = $w; $out.primaryHeight = $h
        try { $out.refreshHz = [int]$g.CurrentRefreshRate } catch {}
        $out.resolutionSource = 'cim-win32-videocontroller-adapter-cached'
        $out.note = "$($out.note) This geometry came from the graphics ADAPTER's cached mode, not from the display API. On a multi-monitor machine it may describe a monitor other than the primary one, and it may be stale.".Trim()
        break
      }
    }
  }
  if ($null -eq $out.dpi) {
    $lp = Get-CompatRegValue -Path 'HKCU:\Control Panel\Desktop' -Name 'LogPixels'
    if ($lp.present -eq $true) {
      try { $out.dpi = [int]$lp.value; $out.scalePercent = [int](($out.dpi / 96.0) * 100); $out.dpiSource = 'registry-logpixels' } catch {}
    }
  }
  if ($null -eq $out.remoteSession) {
    # Upper-cased invariantly, then matched case-sensitively - see ConvertTo-CompatInvariantUpper.
    try { if ("$env:SESSIONNAME" -match '\S') { $out.remoteSession = [bool]((ConvertTo-CompatInvariantUpper $env:SESSIONNAME) -cmatch '^RDP-') } } catch {}
  }
  if ($null -ne $out.primaryWidth -and $null -ne $out.dpi) {
    $out.detail = "Primary display $($out.primaryWidth)x$($out.primaryHeight) at $($out.scalePercent)% scaling ($($out.dpi) DPI)."
  } elseif ($null -ne $out.primaryWidth) {
    $out.detail = "Primary display $($out.primaryWidth)x$($out.primaryHeight); the display scaling could not be read."
  } else {
    $out.detail = 'The primary display geometry could not be determined.'
  }
  return $out
}


# ===========================================================================
# PROBE 3 — runtime (PowerShell, execution policy, language mode, elevation)
# ===========================================================================

function Get-CompatPowerShell {
  $out = [ordered]@{
    version = $null; major = $null; edition = $null; clrVersion = $null
    hostName = $null; is64BitProcess = $null; psHome = $null
    supported = $null; detail = $null
  }
  try { $out.version = "$($PSVersionTable.PSVersion)" } catch {}
  try { $out.major = [int]$PSVersionTable.PSVersion.Major } catch {}
  try { $out.edition = "$($PSVersionTable.PSEdition)" } catch {}
  try { $out.clrVersion = "$($PSVersionTable.CLRVersion)" } catch {}
  try { $out.hostName = "$($Host.Name)" } catch {}
  try { $out.is64BitProcess = [Environment]::Is64BitProcess } catch {}
  try { $out.psHome = "$PSHOME" } catch {}
  if ($null -eq $out.major) {
    $out.detail = 'The PowerShell version could not be read, so FrameForge cannot confirm its engines will parse here.'
  } elseif ($out.major -lt 5) {
    $out.supported = $false
    $out.detail = "PowerShell $($out.version). FrameForge's engines are written for Windows PowerShell 5.1 and use syntax this version does not parse."
    } elseif ($out.major -eq 5) {
    $out.supported = $true
    $out.detail = "Windows PowerShell $($out.version) — the version FrameForge's engines are written and validated against."
  } else {
    $out.supported = $true
    $out.detail = "PowerShell $($out.version) ($($out.edition)). The engines are 5.1-compatible so they parse here, but FrameForge is validated on Windows PowerShell 5.1; treat anything odd on this host as unvalidated."
  }
  return $out
}

# Engine scripts whose runnability the execution policy decides. compat.ps1 includes itself:
# if you are reading this report, that one at least ran.
$script:EngineScripts = @('_lib.ps1','engine.ps1','sysinfo.ps1','nvidia.ps1','measure.ps1','procs.ps1','health.ps1','repair.ps1','image.ps1','compat.ps1')

function Get-CompatExecutionPolicy {
  <#
    THE total-failure mode, and the reason this probe exists.

    -ExecutionPolicy Bypass sets only the PROCESS scope. The documented precedence is
    MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine, so a Group Policy value
    OVERRIDES FrameForge's own command line: under "Turn on Script Execution = AllSigned" (or
    Restricted) every unsigned FrameForge .ps1 is refused, stdout is empty, and every engine
    call fails with no stated reason at all. That is the single worst failure mode in this
    product, because it looks like the app is broken rather than blocked.

    RemoteSigned is a conditional block: it refuses only files that still carry Mark-of-the-Web,
    the NTFS Zone.Identifier stream a ZIP-extracted copy keeps. So MOTW is measured here too —
    detection only; FrameForge does not strip the stream by itself.

    The Electron host (electron/main.js) works around a blocked policy by building a scriptblock
    from each engine file's TEXT, which execution policy does not gate. Two honest limits, both
    of which this report states rather than assuming away:
      * the scriptblock path still fails under WDAC / ConstrainedLanguage;
      * repair.ps1 re-invokes health.ps1 as a CHILD process with -File, and that inner call is
        outside the host's control — so a blocked policy breaks detection for every repair whose
        detection routes through health.ps1, even when the outer call succeeded.
  #>
  $out = [ordered]@{
    scopes = [ordered]@{}; effective = $null
    bypassBlocked = $null; blockingScope = $null; blockingValue = $null
    motw = $null; motwFiles = @(); readable = $null; detail = $null; error = $null
  }
  $lst = Invoke-Safely { @(Get-ExecutionPolicy -List -ErrorAction Stop) }
  if ($null -ne $lst.error -or @($lst.value).Count -eq 0) {
    $out.readable = $false
    $out.error = $lst.error
    $out.detail = 'The PowerShell execution policy could not be read, so FrameForge cannot tell you in advance whether Group Policy will block its engine files. That is "could not determine" — not "the policy is fine".'
    return $out
  }
  $out.readable = $true
  foreach ($r in @($lst.value)) { try { $out.scopes["$($r.Scope)"] = "$($r.ExecutionPolicy)" } catch {} }
  $eff = Invoke-Safely { "$(Get-ExecutionPolicy -ErrorAction Stop)" }
  if ($null -eq $eff.error) { $out.effective = $eff.value }

  # Mark-of-the-Web on the engine files. An alternate-data-stream read that throws for any
  # reason other than "no such stream" leaves motw $null rather than $false.
  $motwSeen = $false; $motwUnknown = $false
  foreach ($s in $script:EngineScripts) {
    $p = (Join-Path $PSScriptRoot $s)
    try { if (-not (Test-Path -LiteralPath $p -PathType Leaf -ErrorAction Stop)) { continue } } catch { continue }
    try {
      $null = Get-Item -LiteralPath $p -Stream 'Zone.Identifier' -ErrorAction Stop
      $motwSeen = $true; $out.motwFiles += $s
    } catch {
      $fq = ''
      try { $fq = "$($_.FullyQualifiedErrorId)" } catch {}
      # "the stream is not there" is the expected miss and must NOT read as "could not
      # determine" — on a clean checkout that is every file, and treating it as unknown would
      # turn the RemoteSigned branch below into a permanent shrug. Measured on Windows 11 25H2:
      # a missing alternate data stream raises System.IO.FileNotFoundException with
      # FullyQualifiedErrorId 'AlternateDataStreamNotFound,...GetItemCommand'. The exception
      # TYPE is checked too, so a future change to that error id does not silently break this.
      $expectedMiss = ($fq -like 'AlternateDataStreamNotFound*' -or $fq -like 'ItemNotFound*' -or $fq -like 'PathNotFound*')
      try { if ($_.Exception -is [System.IO.FileNotFoundException]) { $expectedMiss = $true } } catch {}
      if (-not $expectedMiss) { $motwUnknown = $true }
    }
  }
  if ($motwSeen) { $out.motw = $true } elseif (-not $motwUnknown) { $out.motw = $false }

  foreach ($scope in @('MachinePolicy','UserPolicy')) {
    $v = $null
    if (Test-KeyPresent $out.scopes $scope) { $v = "$($out.scopes[$scope])" }
    if ($v -eq 'Restricted' -or $v -eq 'AllSigned') {
      $out.bypassBlocked = $true; $out.blockingScope = $scope; $out.blockingValue = $v; break
    }
    if ($v -eq 'RemoteSigned' -and $out.motw -eq $true) {
      $out.bypassBlocked = $true; $out.blockingScope = $scope; $out.blockingValue = $v; break
    }
    if ($v -eq 'RemoteSigned' -and $null -eq $out.motw) {
      # Policy would block ONLY if the files carry Mark-of-the-Web, and that could not be read.
      $out.blockingScope = $scope; $out.blockingValue = $v
      $out.detail = "Group Policy sets script execution to RemoteSigned in the $scope scope. Whether that blocks FrameForge's engine files depends on Mark-of-the-Web, which could not be read here, so this is undetermined rather than safe."
      return $out
    }
  }
  # Both policy scopes have to have been REPORTED before "no policy blocks this" can be a
  # measurement rather than an assumption. Get-ExecutionPolicy -List normally returns all
  # five scopes; if a host returns fewer, the missing one is exactly the one that could be
  # set to AllSigned, so the answer stays undetermined.
  $missingScopes = @(@('MachinePolicy','UserPolicy') | Where-Object { -not (Test-KeyPresent $out.scopes $_) })
  if ($null -eq $out.bypassBlocked -and $missingScopes.Count -gt 0) {
    $out.detail = "Get-ExecutionPolicy -List did not report the $($missingScopes -join ' and ') scope(s) on this host, so whether Group Policy refuses FrameForge's unsigned engine files could not be determined here. That is 'could not determine', not 'the policy is fine'."
    return $out
  }
  if ($null -eq $out.bypassBlocked) { $out.bypassBlocked = $false }

  if ($out.bypassBlocked) {
    $out.detail = "Windows Group Policy (Turn on Script Execution = $($out.blockingValue), $($out.blockingScope) scope) refuses FrameForge's unsigned engine files. '-ExecutionPolicy Bypass' cannot override a policy scope. The Electron host works around this by running the engines from memory as scriptblocks, but repair.ps1 re-invokes health.ps1 as a child process with -File, and that inner call is still refused — so repair DETECTION is broken here even when the app itself starts. The only complete fix is to Authenticode-sign the engine scripts."
  } else {
    $out.detail = "No Group Policy scope refuses unsigned scripts (MachinePolicy = $(if (Test-KeyPresent $out.scopes 'MachinePolicy') { $out.scopes['MachinePolicy'] } else { 'Undefined' }), UserPolicy = $(if (Test-KeyPresent $out.scopes 'UserPolicy') { $out.scopes['UserPolicy'] } else { 'Undefined' })), so '-ExecutionPolicy Bypass' works and every engine file can run."
  }
  return $out
}

function Get-CompatLockdown {
  <#
    Application control. ConstrainedLanguage is the observable consequence; WDAC / AppLocker are
    the causes, so both are reported — a user told only "ConstrainedLanguage" has nowhere to go.
  #>
  $out = [ordered]@{
    languageMode = $script:LanguageMode; fullLanguage = $script:FullLanguage
    lockdownPolicyEnv = $null
    codeIntegrityPolicyEnforcement = $null; usermodeCodeIntegrityPolicyEnforcement = $null
    securityServicesRunning = @(); deviceGuardReadable = $null
    appLockerPolicyPresent = $null; appIdSvcStart = $null
    detail = $null
  }
  try { if ("$env:__PSLockdownPolicy" -match '\S') { $out.lockdownPolicyEnv = "$env:__PSLockdownPolicy" } } catch {}
  $dg = Get-CompatCim -ClassName 'Win32_DeviceGuard' -Namespace 'root\Microsoft\Windows\DeviceGuard'
  if ($null -eq $dg.error -and @($dg.value).Count -gt 0) {
    $out.deviceGuardReadable = $true
    $d = @($dg.value)[0]
    try { $out.codeIntegrityPolicyEnforcement = [int]$d.CodeIntegrityPolicyEnforcementStatus } catch {}
    try { $out.usermodeCodeIntegrityPolicyEnforcement = [int]$d.UsermodeCodeIntegrityPolicyEnforcementStatus } catch {}
    try { $out.securityServicesRunning = @($d.SecurityServicesRunning | ForEach-Object { [int]$_ }) } catch {}
  } else { $out.deviceGuardReadable = $false }
  $srp = Get-CompatRegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2'
  $out.appLockerPolicyPresent = $srp.present
  $appid = Get-CompatService 'AppIDSvc'
  $out.appIdSvcStart = $appid.startName

  if ($script:FullLanguage) {
    $out.detail = 'PowerShell is running in FullLanguage: no application-control policy is constraining FrameForge on this machine.'
  } else {
    $out.detail = "PowerShell is running in $($script:LanguageMode) — an application-control policy (WDAC or AppLocker) is in force. FrameForge's other engines refuse to run in this mode; this compatibility report is the exception, and it is degraded too (any check reached through Add-Type is unavailable). The fix is for an administrator to allow FrameForge's script directory in the policy."
  }
  return $out
}

function Get-CompatElevation {
  <#
    Three separate questions, kept separate on purpose:
      isAdmin     is this process elevated right now
      canElevate  is this USER an administrator at all — if not, "run as administrator" is not
                  a fix available to them, and telling them to try it wastes their time
      uacEnabled  EnableLUA; with UAC off there is no elevation prompt to give

    THE OBVIOUS WAY TO ANSWER canElevate IS WRONG, and it was measured wrong here before this
    ladder existed. Walking [WindowsIdentity]::GetCurrent().Groups for S-1-5-32-544 reports a
    perfectly ordinary unelevated administrator as NOT an administrator: a UAC-filtered token
    carries that SID as DENY-ONLY, `whoami /groups` lists it, and .NET's WindowsIdentity.Groups
    filters deny-only SIDs out entirely (verified on Windows 11 25H2, build 26200.9168: whoami
    shows BUILTIN\Administrators "Group used for deny only" while .Groups contains no
    S-1-5-32-544 at all). A tool that then says "an administrator has to run this" to the
    administrator sitting in front of it is exactly the confident wrong answer this codebase
    exists to avoid. So:
      1. Already elevated -> yes, trivially.
      2. GetTokenInformation(TokenElevationType): 3 = Limited means a split token exists, which
         means this user IS an administrator who has not elevated. 2 = Full means elevated.
         1 = Default means there is no split token — and since an administrator with UAC off
         would have been caught by rung 1, Default here means a standard user.
      3. Get-LocalGroupMember -SID S-1-5-32-544, matched against the current user's SID. The
         group is addressed by SID, never by name, because the NAME is localized.
      4. Honest unknown. Never $false from a probe that did not run.
  #>
  $out = [ordered]@{ isAdmin = $null; adminSource = 'unknown'; canElevate = $null; canElevateSource = 'unknown'; elevationType = $null; uacEnabled = $null; consentPromptBehaviorAdmin = $null; userName = $null; userSid = $null; libTestAdmin = $null; libTestAdminAgrees = $null; adminAclKeyExists = $null; adminAclReadSucceeded = $null; adminAclAccessDenied = $null; adminAclNote = $null; detail = $null }
  try { $out.userName = "$([Environment]::UserDomainName)\$([Environment]::UserName)" } catch {}
  try { $out.userSid = "$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)" } catch {}

  # isAdmin ladder. _lib.ps1's Test-Admin is deliberately NOT the first rung, and that is not an
  # oversight: its second rung matches the literal SID S-1-5-32-544 in `whoami /groups` output,
  # and a UAC-filtered token lists that SID as DENY-ONLY — so on any machine where its first
  # rung throws (ConstrainedLanguage, where the identity casts are blocked) it returns $true for
  # an ordinary UNELEVATED administrator. Measured here: under ConstrainedLanguage on this
  # unelevated session, Test-Admin returns True. Its answer is still recorded below, because it
  # is what health.ps1 and repair.ps1 actually believe, and a disagreement is worth seeing in a
  # bug report — but it is never what compat.ps1 reports.
  #   1. WindowsPrincipal.IsInRole — exact; needs FullLanguage.
  #   2. GetTokenInformation(TokenElevationType) == 2 (Full) — exact; needs FullLanguage.
  #   3. An administrator-ACLed registry READ. Success means elevated; an access denial means
  #      not elevated. This is the rung that still works under application control, and it
  #      changes nothing — it only opens a key for reading.
  #   4. Honest unknown.
  $a = Invoke-Safely {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  if ($null -eq $a.error) { $out.isAdmin = [bool]$a.value; $out.adminSource = 'windowsprincipal-isinrole' }

  if ($null -eq $out.isAdmin -and (Initialize-CompatSysApi)) {
    $t = Invoke-Safely { [FFCompatToken]::ElevationType() }
    if ($null -eq $t.error) {
      $v = [int]$t.value
      if ($v -ge 1) { $out.elevationType = $v }
      if ($v -eq 2) { $out.isAdmin = $true; $out.adminSource = 'token-elevation-type' }
      elseif ($v -eq 3) { $out.isAdmin = $false; $out.adminSource = 'token-elevation-type' }
    }
  }

  if ($null -eq $out.isAdmin) {
    # HKLM\...\CurrentVersion\SPP\Clients is administrator-ACLed: an unelevated read raises
    # SecurityException. Re-measured on this machine while writing this: Test-Path succeeds,
    # Get-ItemProperty raises System.Security.SecurityException with PowerShell category
    # PermissionDenied. Read-only; nothing is written.
    #
    # TWO THINGS THIS RUNG USED TO GET WRONG, both of the same shape - a read that did not
    # happen being turned into a confident answer.
    #
    #   1. It concluded "not elevated" from present -eq $null, and present is $null for ANY
    #      failed read, not only for a denial. A transient provider error therefore reported
    #      a possibly-elevated session as definitely unelevated. It now requires a PROVEN
    #      denial (accessDenied, decided from the exception type / category / Win32 code,
    #      never from message text).
    #
    #   2. It concluded "elevated" from a SUCCESSFUL read. That inverts the burden of proof:
    #      a successful read means either this token is elevated OR this key is readable by
    #      ordinary users on this build. FrameForge cannot tell those apart from here (the
    #      key ACL cannot be read either - Get-Acl on it throws for the same reason), and
    #      "the ACL is what I assume it is" is not a measurement. Since this rung is only
    #      reached when both exact rungs above have failed, guessing here would put a green
    #      "elevated" into a report whose whole job is to be trustworthy. So a successful
    #      read now leaves isAdmin at $null, and records what happened as evidence instead.
    #      The DENIAL branch is still a real measurement and still answers $false: an
    #      elevated administrator is not denied this key.
    $probe = Get-CompatRegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients'
    $out.adminAclKeyExists     = $probe.keyExists
    $out.adminAclReadSucceeded = $probe.present
    $out.adminAclAccessDenied  = $probe.accessDenied
    if ($probe.keyExists -eq $true -and $probe.accessDenied -eq $true) {
      $out.isAdmin = $false; $out.adminSource = 'admin-acl-registry-denied'
      $out.adminAclNote = 'This session was DENIED a read of the administrator-only key HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients, which an elevated session is not, so this process is not elevated.'
    } elseif ($probe.keyExists -eq $true -and $probe.present -eq $true) {
      $out.adminSource = 'admin-acl-registry-read-inconclusive'
      $out.adminAclNote = 'The exact elevation checks could not run in this language mode, and the fallback - a read of the administrator-ACLed key HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients - SUCCEEDED. That is consistent with an elevated token but does not prove one, because it is also what a build that leaves the key readable to ordinary users would do. FrameForge reports elevation as undetermined here rather than claiming a green tick it did not measure.'
    } elseif ($probe.keyExists -eq $true) {
      $out.adminAclNote = "The fallback read of HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients failed for a reason that was not an access denial ($($probe.error)), so it says nothing about elevation either way."
    } else {
      $out.adminAclNote = 'The administrator-ACLed key this fallback depends on (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients) is not present on this Windows, so the fallback had nothing to test.'
    }
  }

  if ($script:LibLoaded) {
    $lib = Invoke-Safely { Test-Admin }
    if ($null -eq $lib.error) {
      $out.libTestAdmin = [bool]$lib.value
      if ($null -ne $out.isAdmin) { $out.libTestAdminAgrees = ([bool]$out.libTestAdmin -eq [bool]$out.isAdmin) }
    }
  }

  # Rung 1.
  if ($out.isAdmin -eq $true) { $out.canElevate = $true; $out.canElevateSource = 'already-elevated' }

  # Rung 2 — TokenElevationType.
  if ($null -eq $out.canElevate -and (Initialize-CompatSysApi)) {
    $t = Invoke-Safely { [FFCompatToken]::ElevationType() }
    if ($null -eq $t.error) {
      $v = [int]$t.value
      if ($v -ge 1) { $out.elevationType = $v }
      if ($v -eq 3 -or $v -eq 2) { $out.canElevate = $true; $out.canElevateSource = 'token-elevation-type' }
      elseif ($v -eq 1) { $out.canElevate = $false; $out.canElevateSource = 'token-elevation-type' }
    }
  }

  # Rung 3 — the Administrators group, addressed by SID.
  if ($null -eq $out.canElevate -and "$($out.userSid)" -match '\S') {
    $m = Invoke-Safely { @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID.Value)" }) }
    if ($null -eq $m.error) {
      $out.canElevate = [bool](@($m.value) -contains "$($out.userSid)")
      $out.canElevateSource = 'local-administrators-group-sid'
    }
  }

  $lua = Get-CompatRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
  if ($lua.present -eq $true) { try { $out.uacEnabled = ([int]$lua.value -eq 1) } catch {} }
  $cp = Get-CompatRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin'
  if ($cp.present -eq $true) { try { $out.consentPromptBehaviorAdmin = [int]$cp.value } catch {} }

  if ($out.isAdmin -eq $true) {
    $out.detail = 'This process is elevated, so every administrator-gated check and repair can run.'
  } elseif ($out.canElevate -eq $true) {
    $out.detail = 'This process is NOT elevated, but the signed-in user is a member of the local Administrators group — re-launching FrameForge as administrator unlocks the checks and repairs marked needs-admin.'
  } elseif ($out.canElevate -eq $false) {
    $out.detail = 'This process is not elevated and the signed-in user is not a member of the local Administrators group, so nothing marked needs-admin can be unlocked by this user. An administrator has to run FrameForge.'
  } elseif ($out.isAdmin -eq $false) {
    $out.detail = 'This process is NOT elevated. Whether the signed-in user could elevate could not be determined here, so FrameForge cannot say whether "run as administrator" is advice they can act on.'
  } else {
    $out.detail = 'Elevation state could not be determined at all, so FrameForge cannot say which administrator-gated checks and repairs would be allowed to run.'
  }
  if ("$($out.adminAclNote)" -match '\S' -and $out.adminSource -like 'admin-acl-*') { $out.detail = "$($out.detail) $($out.adminAclNote)" }
  if ($out.libTestAdminAgrees -eq $false) {
    $out.detail = "$($out.detail) NOTE FOR A BUG REPORT: engine\_lib.ps1's Test-Admin reports isAdmin=$($out.libTestAdmin) here, which disagrees with the measurement above. health.ps1 and repair.ps1 both use Test-Admin, so on this machine they will act on the wrong answer."
  }
  return $out
}

# ===========================================================================
# PROBE 4 — capabilities
# ===========================================================================

# In-box tools each repair or probe shells out to. Existence only; none of them is RUN here.
$script:NativeTools = @('Dism.exe','sfc.exe','chkdsk.exe','fsutil.exe','netsh.exe','ipconfig.exe','powercfg.exe','w32tm.exe','cscript.exe','WSReset.exe','UsoClient.exe','slmgr.vbs','sc.exe','whoami.exe')

# Cmdlets the probes and repairs bind to.
$script:NeededCommands = @(
  'Repair-WindowsImage','Get-WindowsOptionalFeature','Enable-WindowsOptionalFeature',
  'Repair-Volume','Get-Volume','Get-PhysicalDisk','Get-StorageReliabilityCounter',
  'Get-AppxPackage','Add-AppxPackage','Get-AppxProvisionedPackage',
  'Get-BitsTransfer','Remove-BitsTransfer',
  'Set-DnsClientServerAddress','Resolve-DnsName',
  'Checkpoint-Computer','Enable-ComputerRestore','Get-ComputerRestorePoint',
  'Get-BitLockerVolume','Set-Service','Restart-Service','Start-Service','Stop-Service',
  'Get-HotFix','Get-WinEvent','Get-CimInstance','Get-Service','Repair-WinGetPackageManager'
)

# Services FrameForge starts, stops, re-enables or reads. Presence is measured from the service
# key, so a service DELETED by a debloat script reads as absent rather than as "not applicable".
$script:NeededServices = @(
  'wuauserv','bits','cryptsvc','msiserver','appidsvc','DoSvc','UsoSvc',
  'AppXSvc','ClipSVC','InstallService','WSearch','Spooler',
  'Audiosrv','AudioEndpointBuilder','w32time','VSS','swprv','TrustedInstaller'
)

function Get-CompatCapabilities {
  $out = [ordered]@{
    nativeTools = [ordered]@{}; commands = [ordered]@{}; services = [ordered]@{}
    bitLocker = $null; store = $null; optionalFeatures = $null
    systemRestore = $null; winget = $null; storage = $null
    systemDirectory = $script:SystemDir; systemDirectoryNote = $script:SystemDirNote
  }
  foreach ($t in $script:NativeTools) { $out.nativeTools[$t] = (Test-CompatSystemFile $t) }
  foreach ($c in $script:NeededCommands) { $out.commands[$c] = (Test-CompatCommand $c) }
  foreach ($s in $script:NeededServices) { $out.services[$s] = (Get-CompatService $s) }

  # BitLocker / Store / OptionalFeatures come from _lib's Test-FFCapability, which already
  # layers cmdlet -> WMI provider -> edition and returns $null for "denied, therefore unknown".
  foreach ($pair in @(@('BitLocker','bitLocker'), @('Store','store'), @('OptionalFeatures','optionalFeatures'))) {
    $name = $pair[0]; $slot = $pair[1]
    if ($script:LibLoaded) {
      $r = Invoke-Safely { Test-FFCapability -Name $name }
      # A $null RESULT with no error is not an answer either. Falling through to the
      # placeholder below keeps available at $null with a reason, instead of leaving a bare
      # $null in the slot that later reads as a fact with no detail at all.
      if ($null -eq $r.error -and $null -ne $r.value) { $out[$slot] = $r.value; continue }
      if ($null -eq $r.error) {
        $out[$slot] = [ordered]@{ name = $name; available = $null; how = 'none'; detail = "engine\_lib.ps1 Test-FFCapability returned nothing for the $name capability on this machine, so whether it is available here was not determined." }
        continue
      }
      $out[$slot] = [ordered]@{ name = $name; available = $null; how = 'none'; detail = "The $name capability could not be probed here: $($r.error)" }
      continue
    }
    $out[$slot] = [ordered]@{ name = $name; available = $null; how = 'none'; detail = "The $name capability could not be probed because engine\_lib.ps1 was not available here." }
  }

  $out.systemRestore = (Get-CompatSystemRestore)
  $out.winget = (Get-CompatWinget)
  $out.storage = (Get-CompatStorage)
  return $out
}

function Get-CompatSystemRestore {
  <#
    Six of FrameForge's repairs carry restorePoint:"enforced" — they create a System Restore
    checkpoint as their FIRST step and ABORT if it cannot be created. So "can a restore point be
    made here" is a hard gate on the whole aggressive tier, and it has four independent ways to
    be false:
      * Group Policy DisableSR / DisableConfig
      * the System Restore engine off for the system volume (RPSessionInterval = 0)
      * Checkpoint-Computer / Enable-ComputerRestore missing (Server SKUs, stripped images)
      * the Volume Shadow Copy services deleted or disabled
    Each is read separately so the reason can be named rather than guessed at.
  #>
  $out = [ordered]@{
    capable = $null; source = 'none'; detail = $null
    policyDisableSR = $null; policyDisableConfig = $null; rpSessionInterval = $null
    checkpointCmdlet = $null; enableCmdlet = $null
    vssStart = $null; swprvStart = $null
    systemVolumeProtected = $null; protectionSource = 'not-measured'
    libCapability = $null
  }
  if ($script:LibLoaded) {
    $r = Invoke-Safely { Test-FFCapability -Name 'SystemRestore' }
    if ($null -eq $r.error) { $out.libCapability = $r.value }
  }
  $pol = Get-CompatRegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
  if ($pol.present -eq $true) {
    try { if (Test-KeyPresent $pol.values 'DisableSR') { $out.policyDisableSR = [int]$pol.values['DisableSR'] } } catch {}
    try { if (Test-KeyPresent $pol.values 'DisableConfig') { $out.policyDisableConfig = [int]$pol.values['DisableConfig'] } } catch {}
  }
  $rp = Get-CompatRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval'
  if ($rp.present -eq $true) { try { $out.rpSessionInterval = [int]$rp.value } catch {} }
  $cc = Test-CompatCommand 'Checkpoint-Computer'; $out.checkpointCmdlet = $cc.present
  $ec = Test-CompatCommand 'Enable-ComputerRestore'; $out.enableCmdlet = $ec.present
  $vss = Get-CompatService 'VSS'; $out.vssStart = $vss.startName
  $sw  = Get-CompatService 'swprv'; $out.swprvStart = $sw.startName

  # Whether protection is actually turned on FOR THE SYSTEM VOLUME lives in
  # HKLM\...\CurrentVersion\SPP\Clients, which is administrator-ACLed (verified on this box:
  # an unelevated read raises SecurityException). Get-ComputerRestorePoint needs elevation for
  # the same reason. So unelevated this is genuinely NOT MEASURED, and it is reported as such
  # rather than folded into the 'capable' answer — the six repairs that enforce a checkpoint
  # call Enable-ComputerRestore on the system drive first, so an unprotected volume is
  # recoverable, but FrameForge does not get to promise the checkpoint will succeed.
  $spp = Get-CompatRegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients'
  if ($spp.present -eq $true) {
    $out.protectionSource = 'registry-spp-clients'
    $out.systemVolumeProtected = (@($spp.values.Keys).Count -gt 0)
  } elseif ($spp.present -eq $false) {
    $out.protectionSource = 'registry-spp-clients'
    $out.systemVolumeProtected = $false
  }

  # Which of the inputs this verdict depends on could NOT be read. Each of these is $null
  # only when the read FAILED - a key that genuinely is not there comes back $false - so a
  # non-empty list here means the answer below would have been guessed. It used to be:
  # with the policy key unreadable, policyDisableSR stayed $null, the "-eq 1" test fell
  # through, and the report said "System Restore is available: ... no policy disables it"
  # on the strength of a policy read that never returned.
  $unreadable = @()
  if ($null -eq $pol.present) { $unreadable += 'the System Restore Group Policy key (HKLM\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore)' }
  if ($null -eq $rp.present)  { $unreadable += 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\RPSessionInterval' }
  elseif ($rp.present -eq $true -and $null -eq $out.rpSessionInterval) { $unreadable += 'the RPSessionInterval value (it is present but its data could not be read as a number)' }
  if ($null -eq $out.checkpointCmdlet) { $unreadable += 'whether the Checkpoint-Computer cmdlet exists' }
  if ($null -eq $out.enableCmdlet)     { $unreadable += 'whether the Enable-ComputerRestore cmdlet exists' }
  if ($null -eq $vss.present) { $unreadable += 'the Volume Shadow Copy (VSS) service registry key' }
  elseif ($vss.present -eq $true -and $null -eq $vss.start) { $unreadable += 'the Start value of the Volume Shadow Copy (VSS) service, so whether it is Disabled is not known' }

  if ($out.policyDisableSR -eq 1) {
    $out.capable = $false; $out.source = 'policy'
    $out.detail = 'System Restore is turned off by Group Policy (Policies\Microsoft\Windows NT\SystemRestore\DisableSR = 1). The six repairs that create a checkpoint first will abort rather than run unprotected, unless -NoRestorePoint is passed deliberately.'
    return $out
  }
  if ($out.checkpointCmdlet -eq $false -or $out.enableCmdlet -eq $false) {
    $out.capable = $false; $out.source = 'cmdlet'
    $out.detail = 'Checkpoint-Computer / Enable-ComputerRestore are not present on this Windows (Server SKUs ship without System Restore), so no restore point can be created. The repairs that enforce one will abort unless -NoRestorePoint is passed.'
    return $out
  }
  if ($vss.present -eq $false) {
    $out.capable = $false; $out.source = 'service'
    $out.detail = 'The Volume Shadow Copy service (VSS) does not exist on this machine — its service key is gone, which is what a debloat script''s "sc delete" leaves behind. System Restore cannot create a checkpoint without it.'
    return $out
  }
  if ($vss.startName -eq 'disabled') {
    $out.capable = $false; $out.source = 'service'
    $out.detail = 'The Volume Shadow Copy service (VSS) is Disabled, so no restore point can be created until it is re-enabled.'
    return $out
  }
  if ($unreadable.Count -gt 0) {
    $out.capable = $null; $out.source = 'undetermined'
    $out.detail = "Whether a System Restore checkpoint can be created here could NOT be determined: $($unreadable -join '; ') could not be read. The six repairs that create a checkpoint as their first step may therefore abort at that step - FrameForge is not going to tell you they will succeed on the strength of a read that failed."
    return $out
  }
  if ($out.checkpointCmdlet -eq $true -and ($vss.present -eq $true)) {
    if ($out.rpSessionInterval -eq 0) {
      $out.capable = $false; $out.source = 'registry-rpsessioninterval'
      $out.detail = 'System Restore is switched off for this machine (RPSessionInterval = 0). The repairs that enforce a checkpoint call Enable-ComputerRestore first, so this is recoverable — but as things stand right now no restore point exists to fall back on.'
      return $out
    }
    $out.capable = $true; $out.source = 'cmdlet+service'
    $protNote = ''
    if ($out.systemVolumeProtected -eq $true) { $protNote = ' Restore-point protection is switched on for at least one volume.' }
    elseif ($out.systemVolumeProtected -eq $false) { $protNote = ' No volume currently has restore-point protection switched on, so the repairs that enforce a checkpoint will turn it on for the system drive first.' }
    else { $protNote = ' Whether protection is actually on for the system drive was NOT measured — that key needs administrator rights — so this says the machinery exists, not that the next checkpoint will succeed.' }
    $out.detail = "System Restore is available: the checkpoint cmdlets are present, no policy disables it, and the Volume Shadow Copy service exists. Creating a checkpoint still needs administrator rights.$protNote"
    return $out
  }
  $out.detail = 'Whether a System Restore checkpoint can be created here could not be determined; the repairs that enforce one may abort at their first step.'
  return $out
}

function Get-CompatWinget {
  <#
    winget is per-user, absent from LTSC/IoT and Server images by default, and the
    winget-repair repair additionally needs the PowerShell Gallery (Install-Module) and
    FullLanguage. Presence only — nothing is installed or launched here.
  #>
  $out = [ordered]@{ present = $null; source = 'none'; path = $null; appInstallerPackage = $null; clientModule = $null; repairCmdlet = $null; detail = $null }
  $c = Test-CompatCommand 'winget.exe'
  if ($c.present -eq $true) { $out.present = $true; $out.source = 'get-command' }
  elseif ($c.present -eq $false) {
    # Get-Command only sees what is on PATH for THIS process; the package can still be
    # registered. Fall back to the package itself before saying no.
    $p = Invoke-Safely { @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop) }
    if ($null -eq $p.error) {
      $out.appInstallerPackage = (@($p.value).Count -gt 0)
      if ($out.appInstallerPackage) { $out.present = $true; $out.source = 'appx-desktopappinstaller' }
      else { $out.present = $false; $out.source = 'appx-desktopappinstaller' }
    }
  }
  $m = Test-CompatCommand 'Repair-WinGetPackageManager'
  $out.repairCmdlet = $m.present
  $mod = Invoke-Safely { @(Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -ErrorAction Stop) }
  if ($null -eq $mod.error) { $out.clientModule = (@($mod.value).Count -gt 0) }

  if ($out.present -eq $true) { $out.detail = 'The Windows Package Manager (winget) is present on this machine.' }
  elseif ($out.present -eq $false) { $out.detail = 'The Windows Package Manager (winget) is not present. LTSC, IoT and Server images ship without the App Installer package that provides it.' }
  else { $out.detail = 'Whether winget is present could not be determined here.' }
  return $out
}

function Get-CompatStorage {
  <# The Storage module is what the disk probes and the chkdsk repairs bind to. #>
  $out = [ordered]@{ repairVolume = $null; getVolume = $null; getPhysicalDisk = $null; reliabilityCounters = $null; namespaceReadable = $null; detail = $null }
  $out.repairVolume = (Test-CompatCommand 'Repair-Volume').present
  $out.getVolume = (Test-CompatCommand 'Get-Volume').present
  $out.getPhysicalDisk = (Test-CompatCommand 'Get-PhysicalDisk').present
  $out.reliabilityCounters = (Test-CompatCommand 'Get-StorageReliabilityCounter').present
  $ns = Invoke-Safely { $null = Get-CimClass -Namespace 'root\Microsoft\Windows\Storage' -ClassName 'MSFT_Volume' -ErrorAction Stop; $true }
  if ($null -eq $ns.error) { $out.namespaceReadable = $true } else { $out.namespaceReadable = $false }
  if ($out.repairVolume -eq $true -and $out.getPhysicalDisk -eq $true) {
    $out.detail = 'The Windows Storage module is present, so the disk probes and the chkdsk repairs can bind to Repair-Volume and the physical-disk counters.'
  } elseif ($out.repairVolume -eq $false) {
    $out.detail = 'Repair-Volume is not available on this Windows, so the chkdsk scan and spot-fix repairs have nothing to call.'
  } else {
    $out.detail = 'The Windows Storage module could not be fully probed here.'
  }
  return $out
}

# ===========================================================================
# PROBE 5 — management
# ===========================================================================

function Get-CompatManagement {
  <#
    Is this machine somebody else's to manage? It changes what FrameForge should DO, not just
    what it can do: on a WSUS-pinned or MDM-enrolled machine, held-back updates are a
    CONFIGURATION and "fixing" them means fighting the administrator.

    Azure AD join is read from HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo —
    the structural signal. dsregcmd would also say so, in prose, and prose is not used here.
  #>
  $out = [ordered]@{
    domainJoined = $null; domainName = $null; domainRole = $null
    azureAdJoined = $null; azureAdSource = 'unknown'; workplaceJoined = $null
    mdmEnrolled = $null; mdmProviders = @(); mdmEnrollmentKeysUnreadable = $null; policyManagerPresent = $null
    wsusManaged = $null; wsusServer = $null; useWUServer = $null; targetReleaseVersion = $null
    w32timeType = $null; w32timeDomainHierarchy = $null
    optionalFeaturePayload = [ordered]@{}
    policies = [ordered]@{}
    detail = $null
  }
  $cs = Get-CompatCim -ClassName 'Win32_ComputerSystem'
  if ($null -eq $cs.error -and @($cs.value).Count -gt 0) {
    $c = @($cs.value)[0]
    try { $out.domainJoined = [bool]$c.PartOfDomain } catch {}
    try { $out.domainName = "$($c.Domain)" } catch {}
    try { $out.domainRole = [int]$c.DomainRole } catch {}
  }

  $cdj = Invoke-Safely { @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction Stop) }
  if ($null -eq $cdj.error) {
    $out.azureAdJoined = (@($cdj.value).Count -gt 0)
    $out.azureAdSource = 'registry-clouddomainjoin'
  } else {
    # The key simply not existing is a real "no"; a denied read is not.
    $exists = Invoke-Safely { [bool](Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction Stop) }
    if ($null -eq $exists.error -and $exists.value -eq $false) { $out.azureAdJoined = $false; $out.azureAdSource = 'registry-clouddomainjoin' }
  }
  $wpj = Invoke-Safely { @(Get-ChildItem 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo' -ErrorAction Stop) }
  if ($null -eq $wpj.error) { $out.workplaceJoined = (@($wpj.value).Count -gt 0) }

  if ($script:LibLoaded) {
    $ed = Invoke-Safely { Get-FFEdition }
    if ($null -eq $ed.error -and $null -ne $ed.value) {
      $out.mdmEnrolled = $ed.value.isMdmEnrolled
      $out.policyManagerPresent = $ed.value.policyManagerPresent
      if ($null -eq $out.domainJoined) { $out.domainJoined = $ed.value.isDomainJoined }
    }
  }
  # The per-subkey read used -ErrorAction SilentlyContinue and silently skipped whatever it
  # could not read. On a machine where one enrolment key is ACLed away that quietly shrinks
  # the result set, and "no MDM enrolment" then comes out of an enumeration that was
  # incomplete — a measured negative from a read that failed. Failures are counted now, and a
  # $false is only produced when every subkey was actually read. A $true still stands on its
  # own: one readable enrolment proves enrolment, whatever else was unreadable.
  $enr = Invoke-Safely {
    $rows = @()
    $failed = 0
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
      $p = $null
      try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { $failed = $failed + 1; continue }
      if ($null -ne $p -and "$($p.DiscoveryServiceFullURL)" -match '\S') {
        $st = $null
        try { if ($null -ne $p.EnrollmentState) { $st = [int]$p.EnrollmentState } } catch {}
        $rows += [ordered]@{ providerId = "$($p.ProviderID)"; enrollmentState = $st; discoveryUrl = "$($p.DiscoveryServiceFullURL)" }
      }
    }
    [ordered]@{ rows = @($rows); unreadable = $failed }
  }
  if ($null -eq $enr.error -and $null -ne $enr.value) {
    $out.mdmProviders = @($enr.value.rows)
    $out.mdmEnrollmentKeysUnreadable = $enr.value.unreadable
    if ($null -eq $out.mdmEnrolled) {
      $enrolled = @($out.mdmProviders | Where-Object { $_.enrollmentState -eq 1 })
      if ($enrolled.Count -gt 0) { $out.mdmEnrolled = $true }
      elseif ($enr.value.unreadable -eq 0) { $out.mdmEnrolled = $false }
    }
  }

  $wu = Get-CompatRegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $au = Get-CompatRegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  if ($wu.present -eq $true) {
    try { if (Test-KeyPresent $wu.values 'WUServer') { $out.wsusServer = "$($wu.values['WUServer'])" } } catch {}
    try { if (Test-KeyPresent $wu.values 'TargetReleaseVersionInfo') { $out.targetReleaseVersion = "$($wu.values['TargetReleaseVersionInfo'])" } } catch {}
  }
  if ($au.present -eq $true) {
    try { if (Test-KeyPresent $au.values 'UseWUServer') { $out.useWUServer = [int]$au.values['UseWUServer'] } } catch {}
  }
  if ($wu.present -eq $null -or $au.present -eq $null) { $out.wsusManaged = $null }
  else { $out.wsusManaged = ([bool]("$($out.wsusServer)" -match '\S') -and $out.useWUServer -ne 0) }

  $t = Get-CompatRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name 'Type'
  if ($t.present -eq $true) {
    $out.w32timeType = "$($t.value)"
    $out.w32timeDomainHierarchy = ($out.w32timeType -eq 'NT5DS')
  }

  # "Specify settings for optional component installation and component repair" decides where
  # Enable-WindowsOptionalFeature may fetch feature payload from. The whole key is reported so
  # a value FrameForge does not know about is still visible in a bug report.
  $srv = Get-CompatRegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
  $out.optionalFeaturePayload = [ordered]@{
    keyPresent = $srv.present
    values = $srv.values
    useWindowsUpdateBlocked = $null
    localSourcePath = $null
    repairContentServerSource = $null
  }
  if ($srv.present -eq $true) {
    try { if (Test-KeyPresent $srv.values 'UseWindowsUpdate') { $out.optionalFeaturePayload.useWindowsUpdateBlocked = ([int]$srv.values['UseWindowsUpdate'] -eq 1) } } catch {}
    try { if (Test-KeyPresent $srv.values 'LocalSourcePath') { $out.optionalFeaturePayload.localSourcePath = "$($srv.values['LocalSourcePath'])" } } catch {}
    try { if (Test-KeyPresent $srv.values 'RepairContentServerSource') { $out.optionalFeaturePayload.repairContentServerSource = [int]$srv.values['RepairContentServerSource'] } } catch {}
    if ($null -eq $out.optionalFeaturePayload.useWindowsUpdateBlocked) { $out.optionalFeaturePayload.useWindowsUpdateBlocked = $false }
  } elseif ($srv.present -eq $false) {
    $out.optionalFeaturePayload.useWindowsUpdateBlocked = $false
  }

  if ($script:LibLoaded) {
    $ps = Invoke-Safely { Get-FFPolicySnapshot }
    if ($null -eq $ps.error -and $null -ne $ps.value) { $out.policies = $ps.value }
  }
  # Policy keys beyond _lib's set that decide what FrameForge may do here.
  foreach ($pair in @(
      @('powerShell','HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'),
      @('appx','HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'),
      @('appLocker','HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2'),
      @('servicing','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'),
      @('systemRestorePolicy','HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'))) {
    $k = Get-CompatRegKey $pair[1]
    $out.policies[$pair[0]] = [ordered]@{ path = $pair[1]; present = $k.present; values = $k.values; error = $k.error }
  }

  $who = @()
  if ($out.domainJoined -eq $true) { $who += "joined to the Active Directory domain $($out.domainName)" }
  if ($out.azureAdJoined -eq $true) { $who += 'joined to Microsoft Entra ID (Azure AD)' }
  if ($out.mdmEnrolled -eq $true) { $who += 'enrolled in MDM' }
  if ($out.wsusManaged -eq $true) { $who += "pinned to the WSUS server $($out.wsusServer) by Group Policy" }
  if ($who.Count -gt 0) {
    $out.detail = "This machine is managed: it is $($who -join ', '). FrameForge treats a policy-held update or a policy-disabled feature as a CONFIGURATION here, not as a fault to be repaired."
  } elseif ($out.domainJoined -eq $false -and $out.wsusManaged -eq $false) {
    $out.detail = 'This machine is not domain-joined, not WSUS-pinned, and carries no MDM enrolment — an unmanaged personal machine, so nothing FrameForge changes will fight an administrator policy.'
  } else {
    $out.detail = 'Whether this machine is centrally managed could not be fully determined.'
  }
  return $out
}


# ===========================================================================
# PROBE RUN — populate the fact table from the probes above
# ===========================================================================

# The probe ids, declared ONCE. -Action list used to carry its own hard-coded copy of this
# array, so the two could drift and the list action would then advertise a probe the check
# action does not emit (or hide one it does). -Action selftest asserts the emitted probe keys
# match this list exactly, which makes the drift a caught failure rather than a quiet lie.
$script:ProbeIds = @('os-identity','os-language','os-system-drive','os-architecture','ff-form-factor','ff-virtualization','ff-display','rt-powershell','rt-execution-policy','rt-lockdown','rt-elevation','cap-inventory','mgmt-management')

$script:Probes = [ordered]@{}

function Invoke-CompatProbe {
  <#
    Run ONE probe so that its failure costs only that probe.

    Every probe used to be called bare inside the one try/catch that wraps the whole
    dispatch, so a single unhandled failure anywhere threw the ENTIRE report away and
    returned an error document with no capability profile in it at all. That is honest but
    useless, and the machines most likely to break one probe are exactly the machines this
    report exists for. A failed probe now leaves a placeholder whose every field reads as
    $null, which flows into the fact table as "could not determine" and into the verdicts as
    unknown — never as a measured yes or no. The failure is kept in .probeError so it shows.
  #>
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
  $v = $null; $e = $null
  try { $v = & $Body } catch { $e = "$($_.Exception.Message)" }
  if ($null -ne $e) { return [ordered]@{ probeFailed = $true; probeError = "The $Name probe failed on this machine: $e" } }
  if ($null -eq $v) { return [ordered]@{ probeFailed = $true; probeError = "The $Name probe returned nothing on this machine." } }
  return $v
}

function Invoke-CompatProbes {
  $sw = $null
  try { $sw = [System.Diagnostics.Stopwatch]::StartNew() } catch {}

  $os    = Invoke-CompatProbe 'os-identity'         { Get-CompatOsIdentity }
  $lang  = Invoke-CompatProbe 'os-language'         { Get-CompatLanguage }
  $drive = Invoke-CompatProbe 'os-system-drive'     { Get-CompatSystemDrive }
  $arch  = Invoke-CompatProbe 'os-architecture'     { Get-CompatArchitecture }
  $form  = Invoke-CompatProbe 'ff-form-factor'      { Get-CompatFormFactor }
  $virt  = Invoke-CompatProbe 'ff-virtualization'   { Get-CompatVirtualization }
  $disp  = Invoke-CompatProbe 'ff-display'          { Get-CompatDisplay }
  $ps    = Invoke-CompatProbe 'rt-powershell'       { Get-CompatPowerShell }
  $xp    = Invoke-CompatProbe 'rt-execution-policy' { Get-CompatExecutionPolicy }
  $lock  = Invoke-CompatProbe 'rt-lockdown'         { Get-CompatLockdown }
  $elev  = Invoke-CompatProbe 'rt-elevation'        { Get-CompatElevation }
  $caps  = Invoke-CompatProbe 'cap-inventory'       { Get-CompatCapabilities }
  $mgmt  = Invoke-CompatProbe 'mgmt-management'     { Get-CompatManagement }

  # WSUS: a WUServer value alone is not management — AU\UseWUServer = 1 is what makes the client
  # actually use it. Computed here rather than in the probe so the rule is in one place.
  if ($null -ne $mgmt.wsusManaged) {
    $mgmt.wsusManaged = ([bool]("$($mgmt.wsusServer)" -match '\S') -and $mgmt.useWUServer -eq 1)
  }

  # Two CIM classes that a probe binds to directly. Get-CimClass asks whether the class EXISTS;
  # it does not enumerate instances, so this stays cheap and read-only.
  $slp = Invoke-Safely { $null = Get-CimClass -ClassName 'SoftwareLicensingProduct' -ErrorAction Stop; $true }
  $slpPresent = $null
  if ($null -eq $slp.error) { $slpPresent = $true } elseif ("$($slp.error)" -match '\S') { $slpPresent = $false }

  $script:Probes = [ordered]@{
    'os-identity'      = $os
    'os-language'      = $lang
    'os-system-drive'  = $drive
    'os-architecture'  = $arch
    'ff-form-factor'   = $form
    'ff-virtualization'= $virt
    'ff-display'       = $disp
    'rt-powershell'    = $ps
    'rt-execution-policy' = $xp
    'rt-lockdown'      = $lock
    'rt-elevation'     = $elev
    'cap-inventory'    = $caps
    'mgmt-management'  = $mgmt
  }

  # ---- facts: environment ----
  Set-Fact 'env:full-language' $script:FullLanguage 'session-state' $(if ($script:FullLanguage) { 'PowerShell is running in FullLanguage.' } else { "PowerShell is running in $($script:LanguageMode) because an application-control policy (WDAC/AppLocker) is in force. FrameForge's health and repair engines require FullLanguage and refuse to run in this mode." })
  Set-Fact 'env:admin' $elev.isAdmin 'token' $elev.detail
  Set-Fact 'env:can-elevate' $elev.canElevate 'token-group-sid' $elev.detail
  Set-Fact 'env:os-supported' $os.supported 'build+installationtype' (Select-CompatDetail $os.supported `
    -WhenTrue "Windows 11 client, build $($os.buildString) ($($os.displayVersion)) — the platform FrameForge is validated on." `
    -WhenFalse "$($os.unsupportedReason)" `
    -WhenNull "$($os.unsupportedReason) The platform could not be confirmed, so it is reported as undetermined rather than as unsupported OR supported.")
  Set-Fact 'env:build-readable' $(if ($null -eq $os.build) { $false } else { $true }) 'registry+cim' $(if ($null -eq $os.build) { 'The Windows build number could not be read, so no build-gated repair can be judged applicable or not.' } else { "Windows build $($os.buildString)." })
  Set-Fact 'env:english-ui' $lang.english 'registry-nls' $lang.englishDetail
  Set-Fact 'env:powershell-supported' $ps.supported 'psversiontable' $ps.detail
  $epOk = $null
  if ($null -ne $xp.bypassBlocked) { $epOk = (-not $xp.bypassBlocked) }
  Set-Fact 'env:execution-policy-allows-file' $epOk 'get-executionpolicy-list' $xp.detail
  Set-Fact 'env:virtual-machine' $virt.isVirtual 'firmware-vendor-identity' $virt.detail
  Set-Fact 'env:portable' $form.isPortable 'battery+chassis' $form.portableDetail

  # ---- facts: in-box tools ----
  foreach ($t in $script:NativeTools) {
    $r = $null
    if ($null -ne $caps.nativeTools) { $r = $caps.nativeTools[$t] }
    $present = $null; $d = $null
    if ($null -eq $r) { $d = "Whether $t exists was not probed here: the capability inventory did not run ($($caps.probeError))." }
    elseif ($r.present -eq $true) { $present = $true; $d = "$t was found at $($r.path)." }
    elseif ($r.present -eq $false) { $present = $false; $d = "$t is not present at $($r.path). It is an in-box Windows tool, so its absence means this image has been stripped or modified." }
    else { $d = "Whether $t exists could not be determined: $($r.error)" }
    Set-Fact "exe:$t" $present 'file-exists' $d
  }

  # ---- facts: cmdlets ----
  foreach ($c in $script:NeededCommands) {
    $r = $null
    if ($null -ne $caps.commands) { $r = $caps.commands[$c] }
    $present = $null; $d = $null
    if ($null -eq $r) { $d = "Whether $c exists was not probed here: the capability inventory did not run ($($caps.probeError))." }
    elseif ($r.present -eq $true) { $present = $true; $d = "The $c command is available on this machine." }
    elseif ($r.present -eq $false) { $present = $false; $d = "The $c command does not exist on this machine, so anything that binds to it has nothing to call." }
    else { $d = "Whether $c exists could not be determined: $($r.error)" }
    Set-Fact "cmdlet:$c" $present 'get-command' $d
  }

  # ---- facts: services ----
  foreach ($s in $script:NeededServices) {
    $r = $null
    if ($null -ne $caps.services) { $r = $caps.services[$s] }
    $present = $null; $d = $null
    if ($null -eq $r) { $d = "Whether the $s service exists was not probed here: the capability inventory did not run ($($caps.probeError))." }
    elseif ($r.present -eq $true) { $present = $true; $d = "The $s service exists (start type: $($r.startName))." }
    elseif ($r.present -eq $false) { $present = $false; $d = "The $s service does not exist on this machine — its registry key is gone. That is what a debloat script's 'sc delete' leaves behind, and Set-Service cannot recreate a deleted service." }
    else { $d = "Whether the $s service exists could not be determined: $($r.error)" }
    Set-Fact "svc:$s" $present 'service-registry-key' $d
    $enabled = $null
    if ($present -eq $true -and $null -ne $r.start) { $enabled = ($r.start -ne 4) }
    # The Start value is the only thing that answers this. When it could not be read the
    # detail must NOT fall back to the "the service exists" sentence, which reads as an
    # all-clear beside a $null value.
    $enabledDetail = Select-CompatDetail $enabled `
      -WhenTrue $d `
      -WhenFalse "The $s service is Disabled. FrameForge's repairs re-enable a disabled service to its documented default and record the prior value, so this is a limitation to be aware of rather than a blocker." `
      -WhenNull "Whether the $s service is enabled could not be determined: its Start value was not readable, so FrameForge does not report it as enabled."
    Set-Fact "svcenabled:$s" $enabled 'service-registry-start' $enabledDetail
  }

  # ---- facts: capabilities ----
  # $caps is a placeholder with no members at all when the inventory probe failed, and
  # property access on it yields $null - which Set-Fact stores as "could not determine" and
  # Get-FactDetail renders as the honest no-reading sentence. That is the intended path.
  Set-Fact 'cap:bitlocker' $caps.bitLocker.available 'lib-test-ffcapability' $caps.bitLocker.detail
  Set-Fact 'cap:store' $caps.store.available 'lib-test-ffcapability' $caps.store.detail
  Set-Fact 'cap:optional-features' $caps.optionalFeatures.available 'lib-test-ffcapability' $caps.optionalFeatures.detail
  Set-Fact 'cap:system-restore' $caps.systemRestore.capable 'policy+cmdlet+service' $caps.systemRestore.detail
  Set-Fact 'cap:winget' $caps.winget.present 'get-command+appx' $caps.winget.detail
  Set-Fact 'cap:storage-module' $caps.storage.repairVolume 'get-command' $caps.storage.detail
  Set-Fact 'cimclass:SoftwareLicensingProduct' $slpPresent 'get-cimclass' (Select-CompatDetail $slpPresent `
    -WhenTrue 'The SoftwareLicensingProduct WMI class is present, so activation state can be read.' `
    -WhenFalse 'The SoftwareLicensingProduct WMI class is not registered on this Windows, so activation state cannot be read here.' `
    -WhenNull 'Whether the SoftwareLicensingProduct WMI class exists could not be determined here, so FrameForge cannot say whether activation state is readable.')

  # ---- facts: management ----
  Set-Fact 'mgmt:domain-joined' $mgmt.domainJoined 'cim-computersystem' (Select-CompatDetail $mgmt.domainJoined `
    -WhenTrue "This machine is joined to the Active Directory domain $($mgmt.domainName)." `
    -WhenFalse 'This machine is not joined to an Active Directory domain.' `
    -WhenNull 'Whether this machine is joined to an Active Directory domain could not be determined: Win32_ComputerSystem did not answer here.')
  Set-Fact 'mgmt:azure-ad-joined' $mgmt.azureAdJoined 'registry-clouddomainjoin' (Select-CompatDetail $mgmt.azureAdJoined `
    -WhenTrue 'This machine is joined to Microsoft Entra ID (Azure AD).' `
    -WhenFalse 'This machine is not joined to Microsoft Entra ID.' `
    -WhenNull 'Whether this machine is joined to Microsoft Entra ID could not be determined: the CloudDomainJoin registry key could neither be enumerated nor shown to be absent.')
  Set-Fact 'mgmt:mdm-enrolled' $mgmt.mdmEnrolled 'registry-enrollments' (Select-CompatDetail $mgmt.mdmEnrolled `
    -WhenTrue 'This machine is enrolled in mobile device management, so an administrator sets policy here.' `
    -WhenFalse 'This machine carries no MDM enrolment.' `
    -WhenNull "Whether this machine is enrolled in MDM could not be determined: $($mgmt.mdmEnrollmentKeysUnreadable) enrolment key(s) under HKLM\SOFTWARE\Microsoft\Enrollments could not be read, so an empty result is not proof of no enrolment.")
  Set-Fact 'mgmt:wsus-managed' $mgmt.wsusManaged 'policy-windowsupdate' (Select-CompatDetail $mgmt.wsusManaged `
    -WhenTrue "Windows Update on this machine is pinned to the WSUS server $($mgmt.wsusServer) by Group Policy." `
    -WhenFalse 'Windows Update on this machine talks to Microsoft directly; no WSUS server is pinned by policy.' `
    -WhenNull 'Whether Windows Update is pinned to a WSUS server could not be determined: the WindowsUpdate policy keys could not be read here.')
  Set-Fact 'mgmt:w32time-domain-hierarchy' $mgmt.w32timeDomainHierarchy 'registry-w32time-type' (Select-CompatDetail $mgmt.w32timeDomainHierarchy `
    -WhenTrue 'The time service is configured as NT5DS: this machine takes its clock from the domain hierarchy, and pointing it at a public NTP pool would break that.' `
    -WhenFalse "The time service Type is '$($mgmt.w32timeType)' — not domain-hierarchy time." `
    -WhenNull 'The W32Time Type value could not be read, so whether this machine takes its clock from a domain hierarchy is undetermined. The ntp-resync repair skips the public-pool step when it cannot rule that out.')
  Set-Fact 'mgmt:optional-feature-payload-blocked' $mgmt.optionalFeaturePayload.useWindowsUpdateBlocked 'policy-servicing' (Select-CompatDetail $mgmt.optionalFeaturePayload.useWindowsUpdateBlocked `
    -WhenTrue 'Group Policy forbids downloading optional-feature payload from Windows Update (Policies\Servicing\UseWindowsUpdate = 1), so enabling a feature whose payload was removed needs -SourcePath pointing at installation media.' `
    -WhenFalse 'No policy forbids fetching optional-feature payload from Windows Update.' `
    -WhenNull 'The Policies\Servicing key could not be read, so whether Group Policy blocks optional-feature payload from Windows Update is undetermined.')

  if ($null -ne $sw) { $sw.Stop(); return [int]$sw.ElapsedMilliseconds }
  return $null
}

# ===========================================================================
# CAPABILITY RULES
# ---------------------------------------------------------------------------
# One entry per health category (data/health-checks.json) and one per repair (data/repairs.json).
#   requires  a fact that must be TRUE. $false -> unavailable, $null -> unknown.
#   softens   a fact whose absence limits but does not stop it. $false -> degraded, $null -> unknown.
#   admin     $true when the check/repair loses real signal without elevation.
#   english   set when the check keeps a documented ENGLISH-ONLY last-resort rung; that rung is
#             lost on a non-English UI, which costs fidelity, never correctness.
#   rule      a scriptblock returning any further constraints, for things a fact list cannot say.
# `requires` and `softens` are not decoration — they DRIVE the verdict, and -Action selftest
# fails if any id in them is not produced by the probes, so a typo cannot become a silent
# "unknown".
# ===========================================================================

function New-Rule {
  param([string[]]$Requires = @(), [string[]]$Softens = @(), [bool]$Admin = $false, [string]$English = $null, [scriptblock]$Rule = $null)
  [ordered]@{ requires = @($Requires); softens = @($Softens); admin = $Admin; english = $English; rule = $Rule }
}

$script:HealthRules = [ordered]@{
  'system-files' = (New-Rule -Requires @('exe:Dism.exe','exe:sfc.exe','cmdlet:Repair-WindowsImage') -Admin $true `
    -English 'The SFC verdict is read from the CBS.log [SR] entries this run writes, which are English on every UI language; sfc''s own console text is only a fallback. Losing that fallback costs nothing here.')
  'disk' = (New-Rule -Requires @('cmdlet:Get-PhysicalDisk') -Softens @('cmdlet:Get-StorageReliabilityCounter','exe:fsutil.exe') -Admin $true `
    -English 'The NTFS dirty bit is read structurally through FSCTL_IS_VOLUME_DIRTY; fsutil''s English output is only a fallback, so on a non-English UI an unreadable dirty bit is reported as "unknown" rather than as clean.' `
    -Rule {
      $c = @()
      if ((Get-Fact 'env:virtual-machine') -eq $true) {
        $c += New-Constraint 'degraded' 'virtual-storage' 'This is a virtual machine, so the physical-disk health and SSD wear counters describe the hypervisor''s virtual disks, not real hardware. Treat a wear or media-error finding here as a question for the host, not for this guest.'
      }
      $c
    })
  'windows-update' = (New-Rule -Requires @('cmdlet:Get-HotFix','cmdlet:Get-WinEvent'))
  'network'        = (New-Rule -Requires @('cmdlet:Resolve-DnsName'))
  'store'          = (New-Rule -Requires @('cmdlet:Get-AppxPackage') -Rule {
      $c = @()
      $s = Get-Fact 'cap:store'
      if ($s -eq $false) { $c += New-Constraint 'unavailable' 'no-store-on-this-edition' (Get-FactDetail 'cap:store') }
      elseif ($null -eq $s) { $c += New-Constraint 'unknown' 'store-undetermined' (Get-FactDetail 'cap:store') }
      $c
    })
  'search'     = (New-Rule -Softens @('svc:WSearch') -Admin $true)
  'printing'   = (New-Rule -Softens @('svc:Spooler') -Admin $true)
  'stability'  = (New-Rule -Requires @('cmdlet:Get-WinEvent') -Admin $true)
  'disk-space' = (New-Rule -Softens @('cmdlet:Get-Volume') -Admin $true)
  'boot'       = (New-Rule -Requires @('cmdlet:Get-WinEvent') -Admin $true `
    -English 'Fast Startup availability is read from CallNtPowerInformation and the hibernation registry state; the powercfg /a text parse is a last resort only, so losing it on a non-English UI costs nothing here.')
  'audio'      = (New-Rule -Softens @('svc:Audiosrv','svc:AudioEndpointBuilder'))
  'activation' = (New-Rule -Requires @('cimclass:SoftwareLicensingProduct'))
}

$script:RepairRules = [ordered]@{
  'wu-reset' = (New-Rule -Requires @('svc:wuauserv','svc:bits','svc:cryptsvc','cmdlet:Set-Service','exe:netsh.exe') -Softens @('cmdlet:Get-BitsTransfer','exe:UsoClient.exe') -Rule { Get-ManagedUpdateConstraints })
  'wu-reset-aggressive' = (New-Rule -Requires @('svc:wuauserv','svc:bits','svc:cryptsvc','cmdlet:Set-Service','exe:netsh.exe','exe:sc.exe') -Softens @('cmdlet:Get-BitsTransfer','exe:UsoClient.exe') -Rule { Get-ManagedUpdateConstraints })
  'dism-restorehealth' = (New-Rule -Requires @('exe:Dism.exe','exe:sfc.exe') `
    -English 'sfc''s outcome is decided by exit code first, then its English console text, then the [SR] markers in CBS.log — which are English on every UI language. An outcome none of those can establish is reported as indeterminate, never as success.')
  'sfc-scannow' = (New-Rule -Requires @('exe:sfc.exe') `
    -English 'Same ladder as dism-restorehealth: the CBS.log [SR] rung is UI-language-independent, so a non-English machine loses only the fast path.')
  'wu-repair-reinstall' = (New-Rule -Rule {
      $c = @()
      $os = $script:Probes['os-identity']
      if ($os.isServer -eq $true) { $c += New-Constraint 'unavailable' 'client-only-flow' 'This repair opens Settings > System > Recovery and hands you the "Fix problems using Windows Update" button. That flow is a Windows client feature; a Server installation does not have it.' }
      elseif ($os.isLtsc -eq $true) { $c += New-Constraint 'degraded' 'ltsc-recovery-flow' 'This is an LTSC/IoT edition. The Settings Recovery page exists, but the in-place "Reinstall now" repair option is not offered on every LTSC build — if the button is missing, this repair has nothing to hand you.' }
      $c
    })
  'chkdsk-scan'   = (New-Rule -Requires @('cmdlet:Repair-Volume'))
  'chkdsk-spotfix'= (New-Rule -Requires @('cmdlet:Repair-Volume'))
  'chkdsk-full-repair' = (New-Rule -Requires @('exe:chkdsk.exe') `
    -English 'Whether the offline check was actually scheduled is decided from the dirty bit and the boot-execute list first; chkdsk''s English console prompt text is only the last rung.')
  'network-flush' = (New-Rule -Requires @('exe:ipconfig.exe'))
  'dns-change-resolver' = (New-Rule -Requires @('cmdlet:Set-DnsClientServerAddress') -Softens @('exe:ipconfig.exe'))
  'winsock-reset' = (New-Rule -Requires @('exe:netsh.exe'))
  'store-cache-reset' = (New-Rule -Requires @('exe:WSReset.exe') -Rule { Get-StoreConstraints })
  'store-services-enable' = (New-Rule -Requires @('cmdlet:Set-Service') -Softens @('svc:AppXSvc','svc:ClipSVC','svc:InstallService','svc:DoSvc') -Rule { Get-StoreConstraints })
  'store-reregister' = (New-Rule -Requires @('cmdlet:Get-AppxPackage','cmdlet:Add-AppxPackage') -Rule { Get-StoreConstraints })
  'store-reregister-all' = (New-Rule -Requires @('cmdlet:Get-AppxPackage','cmdlet:Add-AppxPackage') -Rule { Get-StoreConstraints })
  'search-index-rebuild' = (New-Rule -Requires @('svc:WSearch','cmdlet:Set-Service'))
  'shell-restart' = (New-Rule -Rule {
      $c = @()
      if ($script:Probes['ff-display'].remoteSession -eq $true) {
        $c += New-Constraint 'degraded' 'remote-session' 'You are in a remote-desktop session. Restarting Explorer here restarts the shell of THIS session only, and the screen will go blank for a few seconds while it comes back.'
      }
      $c
    })
  'spooler-clear-queue' = (New-Rule -Requires @('svc:Spooler'))
  'audio-restart' = (New-Rule -Requires @('svc:AudioEndpointBuilder','svc:Audiosrv','cmdlet:Restart-Service'))
  'ntp-resync' = (New-Rule -Requires @('svc:w32time','exe:w32tm.exe') `
    -English 'The current NTP configuration is captured from the W32Time registry values; w32tm''s English status labels are only the second rung, and a sync time that cannot be read is reported as unknown rather than as stale.' `
    -Rule {
      $c = @()
      if ((Get-Fact 'mgmt:w32time-domain-hierarchy') -eq $true) {
        $c += New-Constraint 'degraded' 'domain-time-hierarchy' 'This machine takes its clock from the domain hierarchy (W32Time Type = NT5DS). The repair deliberately SKIPS the step that points the clock at a public NTP pool — doing that on a domain member breaks Kerberos — so only the service restart and resync steps will run.'
      }
      $c
    })
  'temp-clean' = (New-Rule -Rule {
      $c = @()
      if ((Get-Fact 'env:admin') -eq $false) {
        $c += New-Constraint 'degraded' 'partial-without-admin' 'Without elevation this cleans only your own %TEMP%. The machine-wide %SystemRoot%\Temp folder — usually the larger of the two — needs administrator rights and will be skipped.'
      }
      $c
    })
  'component-cleanup' = (New-Rule -Requires @('exe:Dism.exe'))
  'component-cleanup-resetbase' = (New-Rule -Requires @('exe:Dism.exe'))
  'activation-retry' = (New-Rule -Requires @('exe:cscript.exe','exe:slmgr.vbs') -Softens @('cimclass:SoftwareLicensingProduct'))
  'winget-repair' = (New-Rule -Rule {
      $c = @()
      $c += New-Constraint 'degraded' 'network-not-probed' 'This repair reaches the PowerShell Gallery and then Microsoft''s servers to reinstall the package manager. compat.ps1 makes no network request of its own — a compatibility check has no business generating traffic — so whether those endpoints are reachable from here is NOT part of this verdict.'
      if ($script:Probes['os-identity'].isServer -eq $true) {
        $c += New-Constraint 'degraded' 'server-app-installer' 'This is a Server installation. The App Installer package that provides winget is not part of a Server image, so a repair may install it into a configuration Microsoft does not support there.'
      } elseif ((Get-Fact 'cap:store') -eq $false) {
        $c += New-Constraint 'degraded' 'no-store-delivery' (Get-FactDetail 'cap:store')
      }
      $c
    })
  'enable-netfx3' = (New-Rule -Requires @('cmdlet:Enable-WindowsOptionalFeature','cmdlet:Get-WindowsOptionalFeature') -Rule { Get-OptionalFeatureConstraints })
  'enable-netfx4-advsrvs' = (New-Rule -Requires @('cmdlet:Enable-WindowsOptionalFeature','cmdlet:Get-WindowsOptionalFeature') -Rule { Get-OptionalFeatureConstraints })
  'enable-directplay' = (New-Rule -Requires @('cmdlet:Enable-WindowsOptionalFeature','cmdlet:Get-WindowsOptionalFeature') -Rule { Get-OptionalFeatureConstraints })
}

function Get-StoreConstraints {
  $c = @()
  $s = Get-Fact 'cap:store'
  if ($s -eq $false) { $c += New-Constraint 'unavailable' 'no-store-on-this-edition' (Get-FactDetail 'cap:store') }
  elseif ($null -eq $s) { $c += New-Constraint 'unknown' 'store-undetermined' (Get-FactDetail 'cap:store') }
  $c
}

function Get-ManagedUpdateConstraints {
  <#
    On a managed machine the Windows Update reset deliberately does LESS: it skips the WinHTTP
    proxy reset and skips clearing the WSUS client identity, because on a managed network both
    would cut the machine off rather than fix it. That is correct behaviour and a real
    limitation, so it is reported as one.
  #>
  $c = @()
  $who = @()
  if ((Get-Fact 'mgmt:wsus-managed') -eq $true) { $who += "pinned to the WSUS server $($script:Probes['mgmt-management'].wsusServer)" }
  if ((Get-Fact 'mgmt:mdm-enrolled') -eq $true) { $who += 'enrolled in MDM' }
  if ((Get-Fact 'mgmt:domain-joined') -eq $true) { $who += 'domain-joined' }
  if ($who.Count -gt 0) {
    $c += New-Constraint 'degraded' 'managed-update-client' "This machine is $($who -join ' and '). The reset will deliberately SKIP the WinHTTP proxy reset and the WSUS client-identity clear — on a managed network those two steps disconnect the machine from updates instead of fixing it, and this repair is not reversible. The service, BITS queue and cache-folder steps still run."
  }
  $c
}

function Get-OptionalFeatureConstraints {
  $c = @()
  if ((Get-Fact 'mgmt:optional-feature-payload-blocked') -eq $true) {
    $c += New-Constraint 'degraded' 'payload-source-blocked' (Get-FactDetail 'mgmt:optional-feature-payload-blocked')
  }
  $mgmt = $script:Probes['mgmt-management']
  if ((Get-Fact 'mgmt:wsus-managed') -eq $true -and $mgmt.optionalFeaturePayload.repairContentServerSource -ne 2) {
    $c += New-Constraint 'degraded' 'wsus-payload-source' "Windows Update on this machine is pinned to the WSUS server $($mgmt.wsusServer), and Group Policy does not set RepairContentServerSource = 2 (download feature payload straight from Windows Update). WSUS servers commonly do not carry Features on Demand payload, so enabling a feature whose payload has been removed is likely to fail here unless -SourcePath points at installation media. FrameForge has NOT contacted that server to confirm — this is a warning from configuration, not a measurement."
  }
  $c
}

# ---------------------------------------------------------------------------
# build applicability — the same rule repair.ps1 applies, read from the catalog
# ---------------------------------------------------------------------------
function Test-CompatBuildApplicable {
  <#
    Mirrors repair.ps1's build gate: null minBuild/maxBuild mean "no bound", generation 'any'
    means every generation. A DECLARED requirement that cannot be evaluated because the build is
    unreadable is 'could not determine' — never "yes".
  #>
  param($Repair)
  $out = [ordered]@{ applicable = $true; reason = $null; minBuild = $null; maxBuild = $null; generation = 'any'; unparseable = @() }
  # A DECLARED bound that cannot be PARSED used to be dropped on the floor by the -match
  # guard, which left $declares false and the repair judged applicable - a catalog typo
  # ('22000+', '') silently turning into a green "yes, this applies here".
  foreach ($f in @('minBuild','maxBuild')) {
    if (-not (Test-CompatProperty $Repair $f)) { continue }
    $raw = $null
    try { $raw = $Repair.$f } catch { $out.unparseable += "$f (could not be read from the catalog)"; continue }
    if ($null -eq $raw) { continue }
    if ("$raw" -notmatch '\S') { continue }
    if ("$raw" -match '^\d+$') {
      if ($f -eq 'minBuild') { $out.minBuild = [int]"$raw" } else { $out.maxBuild = [int]"$raw" }
    } else { $out.unparseable += "$f = '$raw'" }
  }
  try { if ("$($Repair.generation)" -match '\S') { $out.generation = "$($Repair.generation)".ToLowerInvariant() } } catch {}
  if (@($out.unparseable).Count -gt 0) {
    $out.applicable = $null
    $out.reason = "This repair declares a build bound FrameForge could not parse ($(@($out.unparseable) -join ', ')), so whether it applies to this Windows could not be determined. That is 'could not determine', not 'yes'."
    return $out
  }
  $declares = ($null -ne $out.minBuild -or $null -ne $out.maxBuild -or ($out.generation -ne 'any'))
  if (-not $declares) { return $out }
  $os = $script:Probes['os-identity']
  if ($null -eq $os.build) {
    $out.applicable = $null
    $out.reason = 'This repair declares a build or generation requirement, but the Windows build number could not be read here — so FrameForge cannot tell whether it applies. That is "could not determine", not "yes".'
    return $out
  }
  if ($null -ne $out.minBuild -and $os.build -lt $out.minBuild) {
    $out.applicable = $false
    $out.reason = "This repair needs Windows build $($out.minBuild) or newer; this machine is build $($os.buildString)."
    return $out
  }
  if ($null -ne $out.maxBuild -and $os.build -gt $out.maxBuild) {
    $out.applicable = $false
    $out.reason = "This repair applies only up to Windows build $($out.maxBuild) — the mechanism it uses was removed after that. This machine is build $($os.buildString)."
    return $out
  }
  if ($out.generation -ne 'any') {
    if ($null -eq $os.generation) {
      $out.applicable = $null
      $out.reason = "This repair is declared $($out.generation)-only, but this machine's Windows generation could not be determined from build $($os.build)."
      return $out
    }
    if ($os.generation -ne $out.generation) {
      $out.applicable = $false
      $out.reason = "This repair applies to $($out.generation) only; this machine is $($os.generation) (build $($os.buildString))."
      return $out
    }
  }
  return $out
}

# ---------------------------------------------------------------------------
# verdict assembly
# ---------------------------------------------------------------------------

function Get-BaseConstraints {
  <#
    Constraints that apply to every capability, health or repair.

    All three gates are TRI-STATE here. They used to fire only on an explicit $false, so a
    machine where the PowerShell version or the language mode could not be READ produced no
    base constraint at all and every row started from a clean slate - i.e. an unmeasured
    platform could reach 'supported'. An undetermined gate is now an 'unknown' constraint,
    which outranks both 'supported' and 'needs-admin'.
  #>
  param([switch]$Mutating)
  $c = @()
  $psOk = Get-Fact 'env:powershell-supported'
  if ($psOk -eq $false) {
    $c += New-Constraint 'unavailable' 'powershell-too-old' (Get-FactDetail 'env:powershell-supported')
  } elseif ($null -eq $psOk) {
    $c += New-Constraint 'unknown' 'powershell-version-undetermined' "The PowerShell version on this host could not be read, so FrameForge cannot confirm its engines will even parse here. $(Get-FactDetail 'env:powershell-supported')"
  }
  $fl = Get-Fact 'env:full-language'
  if ($fl -eq $false) {
    $c += New-Constraint 'unavailable' 'constrained-language' (Get-FactDetail 'env:full-language')
  } elseif ($null -eq $fl) {
    $c += New-Constraint 'unknown' 'language-mode-undetermined' 'The PowerShell language mode could not be read, so whether an application-control policy (WDAC/AppLocker) blocks FrameForge here is undetermined.'
  }
  $sup = Get-Fact 'env:os-supported'
  if ($sup -eq $false) {
    $os = $script:Probes['os-identity']
    if ($Mutating) {
      $c += New-Constraint 'degraded' 'unvalidated-platform' "$($os.unsupportedReason) repair.ps1 gates repairs on the catalog's minBuild / maxBuild / generation only, so a repair declaring generation 'any' is NOT refused here — it would run, unvalidated. Treat any result on this platform as unproven."
    } else {
      $c += New-Constraint 'degraded' 'unvalidated-platform' "$($os.unsupportedReason) health.ps1 changes nothing, so its probes still run read-only — but their verdicts have not been validated on this platform."
    }
  } elseif ($null -eq $sup) {
    $c += New-Constraint 'unknown' 'platform-undetermined' (Get-FactDetail 'env:os-supported')
  }
  return $c
}

function Get-RequirementConstraints {
  param($Rule)
  $c = @()
  foreach ($id in @($Rule.requires)) {
    $v = Get-Fact $id
    if ($v -eq $false) { $c += New-Constraint 'unavailable' 'missing-requirement' (Get-FactDetail $id) }
    elseif ($null -eq $v) { $c += New-Constraint 'unknown' 'requirement-undetermined' (Get-FactDetail $id) }
  }
  foreach ($id in @($Rule.softens)) {
    $v = Get-Fact $id
    if ($v -eq $false) { $c += New-Constraint 'degraded' 'missing-optional-dependency' (Get-FactDetail $id) }
    elseif ($null -eq $v) { $c += New-Constraint 'unknown' 'optional-dependency-undetermined' (Get-FactDetail $id) }
  }
  return $c
}

function Get-EnglishConstraint {
  param($Rule)
  if ([string]::IsNullOrWhiteSpace($Rule.english)) { return @() }
  $en = Get-Fact 'env:english-ui'
  if ($en -eq $false) {
    return @(New-Constraint 'degraded' 'english-only-fallback-lost' "$(Get-FactDetail 'env:english-ui') For this check specifically: $($Rule.english)")
  }
  if ($null -eq $en) {
    return @(New-Constraint 'unknown' 'ui-language-undetermined' "$(Get-FactDetail 'env:english-ui') For this check specifically: $($Rule.english)")
  }
  return @()
}

function Get-AdminConstraint {
  param($Rule)
  if (-not $Rule.admin) { return @() }
  $a = Get-Fact 'env:admin'
  if ($a -eq $false) {
    $extra = ''
    if ((Get-Fact 'env:can-elevate') -eq $false) { $extra = ' The signed-in user is not a local administrator, so re-launching elevated is not an option for them — an administrator has to run FrameForge.' }
    return @(New-Constraint 'needs-admin' 'needs-elevation' "Some of this check's signals are only readable with administrator rights; unelevated it reports what it could not read rather than assuming it is fine.$extra")
  }
  if ($null -eq $a) { return @(New-Constraint 'unknown' 'elevation-undetermined' 'Whether this process is elevated could not be determined, so FrameForge cannot say which of this check''s signals will be readable.') }
  return @()
}

function Invoke-CompatRule {
  <#
    Run a capability rule's scriptblock so that a rule which FAILS cannot pass as a rule that
    found nothing wrong.

    This was the worst doctrine-rule-2 hole in this file and it is worth spelling out.
    $ErrorActionPreference is SilentlyContinue for the whole script, the call site was
    `$c += @(& $rule.rule)`, and a throwing rule therefore contributed NOTHING to the
    constraint list. The row then had zero constraints, Resolve-Verdict returned 'supported',
    and New-CapabilityRow printed "Every dependency this needs was measured and present on
    this machine." Measured, before this fix, with a rule of { throw 'probe exploded' }:
        verdict=supported reason=Every dependency this needs was measured and present ...
    A rule that could not be evaluated now yields 'unknown' with the failure quoted. The
    capability was not judged, so it does not get a verdict that says it was.
  #>
  param($Rule, [string]$Id)
  if ($null -eq $Rule -or $null -eq $Rule.rule) { return @() }
  $v = $null; $e = $null
  try { $v = & $Rule.rule } catch { $e = "$($_.Exception.Message)" }
  if ($null -ne $e) {
    return @(New-Constraint 'unknown' 'rule-evaluation-failed' "FrameForge's own compatibility rule for '$Id' could not be evaluated on this machine ($e), so whether this can run here was NOT determined. That is 'could not determine', not 'yes'.")
  }
  return @($v)
}

function New-CapabilityRow {
  param([string]$Id, [string]$Name, [string]$Kind, [string]$Category, $Rule, $Constraints, $Extra)
  $c = @($Constraints)
  $verdict = Resolve-Verdict $c
  $worst = $null
  foreach ($x in $c) { if ($null -eq $worst -or $script:VerdictRank[$x.verdict] -gt $script:VerdictRank[$worst.verdict]) { $worst = $x } }
  # The no-constraint sentence has to be true of THIS row. The old one claimed
  # "Every dependency this needs was measured and present" for every green row, including
  # the rows that declare no dependency at all and so had nothing measured for them.
  $reason = $null
  $deps = @(@($Rule.requires) + @($Rule.softens) | Where-Object { "$_" -match '\S' })
  if ($null -ne $worst) { $reason = $worst.reason }
  elseif ($deps.Count -gt 0) { $reason = "Every dependency this needs was measured and found present on this machine: $($deps -join ', ')." }
  else { $reason = 'This capability declares no dependency of its own, and none of the machine-wide checks (PowerShell version, language mode, supported platform, elevation) raised anything against it. Nothing specific to it was measured, because there is nothing specific to measure.' }
  $row = [ordered]@{
    id       = $Id
    name     = $Name
    kind     = $Kind
    category = $Category
    verdict  = $verdict
    reason   = $reason
    reasons  = @($c)
    requires = @($Rule.requires)
    softens  = @($Rule.softens)
  }
  if ($null -ne $Extra) { foreach ($k in @($Extra.Keys)) { $row[$k] = $Extra[$k] } }
  return $row
}

function Get-HealthVerdicts {
  param($HealthCatalogChecks)
  $rows = @()
  foreach ($id in @($script:HealthRules.Keys)) {
    $rule = $script:HealthRules[$id]
    $meta = @($HealthCatalogChecks | Where-Object { "$($_.id)" -eq $id }) | Select-Object -First 1
    $name = $id
    if ($null -ne $meta -and "$($meta.name)" -match '\S') { $name = "$($meta.name)" }
    $c = @()
    $c += Get-BaseConstraints
    $c += Get-RequirementConstraints $rule
    $c += Get-AdminConstraint $rule
    $c += Get-EnglishConstraint $rule
    $c += Invoke-CompatRule $rule $id
    $rows += New-CapabilityRow -Id $id -Name $name -Kind 'health-category' -Category 'health' -Rule $rule -Constraints $c -Extra $null
  }
  return $rows
}

function Get-RepairVerdicts {
  param($RepairCatalog)
  $rows = @()
  foreach ($r in @($RepairCatalog)) {
    $id = "$($r.id)"
    $rule = $null
    $ruleDeclared = (Test-KeyPresent $script:RepairRules $id)
    if ($ruleDeclared) { $rule = $script:RepairRules[$id] } else { $rule = (New-Rule) }
    $c = @()
    $c += Get-BaseConstraints -Mutating
    # -Action selftest fails when data\repairs.json carries a repair this file has no rule for,
    # so this branch means the two have drifted since the last selftest run. An empty rule
    # produces no constraints, which used to resolve to a confident 'supported' for a repair
    # whose requirements nothing had looked at.
    if (-not $ruleDeclared) {
      $c += New-Constraint 'unknown' 'no-capability-rule' "compat.ps1 has no capability rule for the repair '$id' in data\repairs.json, so its requirements were never checked on this machine. FrameForge will not call a repair supported on the strength of a rule that does not exist."
    }

    # 1. Build / generation gate — the same rule repair.ps1 applies before anything else.
    $appl = Test-CompatBuildApplicable $r
    if ($appl.applicable -eq $false) { $c += New-Constraint 'unavailable' 'not-applicable-on-this-build' $appl.reason }
    elseif ($null -eq $appl.applicable) { $c += New-Constraint 'unknown' 'build-undetermined' $appl.reason }

    # 2. Elevation. requiresAdmin comes from the catalog, so it cannot drift from the engine -
    #    but [bool]$r.requiresAdmin on an object with no such member is $false with no error,
    #    so a MISSING field used to read as a measured "this repair does not need admin".
    $needsAdmin = $null
    if (Test-CompatProperty $r 'requiresAdmin') { try { $needsAdmin = [bool]$r.requiresAdmin } catch {} }
    if ($null -eq $needsAdmin) {
      $c += New-Constraint 'unknown' 'catalog-field-missing' "data\repairs.json does not declare requiresAdmin for '$id', so FrameForge cannot say whether this repair needs administrator rights on this machine."
    } elseif ($needsAdmin) {
      $a = Get-Fact 'env:admin'
      if ($a -eq $false) {
        $extra = ''
        if ((Get-Fact 'env:can-elevate') -eq $false) { $extra = ' The signed-in user is not a local administrator, so an administrator has to run FrameForge for this.' }
        $c += New-Constraint 'needs-admin' 'needs-elevation' "This repair changes machine-wide state and needs administrator rights.$extra"
      } elseif ($null -eq $a) {
        $c += New-Constraint 'unknown' 'elevation-undetermined' 'Whether this process is elevated could not be determined, so FrameForge cannot say whether this repair would be allowed to run.'
      }
    }

    # 3. Enforced restore point. These repairs create a checkpoint as their FIRST step and abort
    #    if they cannot — so a machine that cannot make one cannot run them as designed.
    if (-not (Test-CompatProperty $r 'restorePoint')) {
      $c += New-Constraint 'unknown' 'catalog-field-missing' "data\repairs.json does not declare restorePoint for '$id', so FrameForge cannot say whether this repair insists on a System Restore checkpoint before it runs."
    } elseif ("$($r.restorePoint)" -eq 'enforced') {
      $sr = Get-Fact 'cap:system-restore'
      if ($sr -eq $false) {
        $c += New-Constraint 'degraded' 'restore-point-unavailable' "$(Get-FactDetail 'cap:system-restore') This repair is in the aggressive tier: it creates a System Restore checkpoint as its first step and ABORTS if it cannot, so as things stand it will refuse to run. -NoRestorePoint is the documented, deliberate opt-out."
      } elseif ($null -eq $sr) {
        $c += New-Constraint 'unknown' 'restore-point-undetermined' "$(Get-FactDetail 'cap:system-restore') This repair aborts if a checkpoint cannot be created, so FrameForge cannot promise it will start here."
      }
    }

    # 4. Detection. Every repair with a healthCheck runs its detect and verify passes by
    #    re-invoking health.ps1 as a CHILD process with -File — the one path the Electron host's
    #    scriptblock workaround does not cover.
    $epAllows = Get-Fact 'env:execution-policy-allows-file'
    if ("$($r.healthCheck)" -match '\S' -and $null -eq $epAllows) {
      $c += New-Constraint 'unknown' 'execution-policy-undetermined' "This repair detects and verifies by running engine\health.ps1 as a child process with -File, and whether Group Policy refuses unsigned script files here could not be determined. $(Get-FactDetail 'env:execution-policy-allows-file')"
    }
    if ("$($r.healthCheck)" -match '\S' -and $epAllows -eq $false) {
      $c += New-Constraint 'degraded' 'child-script-blocked-by-policy' "This repair detects and verifies by running engine\health.ps1 as a child process with -File, and Group Policy ($($script:Probes['rt-execution-policy'].blockingValue) in the $($script:Probes['rt-execution-policy'].blockingScope) scope) refuses unsigned script FILES here. The Electron host's in-memory workaround does not reach that inner call, so detection would fail and the repair would refuse with 'probe-failure' rather than run blind. Signing the engine scripts is the fix."
    }

    $c += Get-RequirementConstraints $rule
    $c += Get-EnglishConstraint $rule
    $c += Invoke-CompatRule $rule $id

    $extra = [ordered]@{
      tier = "$($r.tier)"
      requiresAdmin = $needsAdmin
      requiresReboot = $r.requiresReboot
      reversible = $r.reversible
      restorePoint = "$($r.restorePoint)"
      healthCheck = $r.healthCheck
      applicableOnThisBuild = $appl.applicable
    }
    $rows += New-CapabilityRow -Id $id -Name "$($r.name)" -Kind 'repair' -Category "$($r.category)" -Rule $rule -Constraints $c -Extra $extra
  }
  return $rows
}

# ---------------------------------------------------------------------------
# catalogs
# ---------------------------------------------------------------------------
function Import-CompatCatalog {
  # -Encoding UTF8 is load-bearing: these catalogs have no BOM, and PowerShell 5.1 would
  # otherwise decode them as Windows-1252 and mangle every em-dash in the user-facing copy.
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Catalog not found: $Path" }
  return (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json)
}

# ===========================================================================
# DISPATCH
# ===========================================================================
$out = $null
$exitCode = 0

try {
  if ($ValidActions -notcontains $Action) {
    $out = [ordered]@{ ok = $false; error = "Unknown action '$Action'."; validActions = $ValidActions }
    $exitCode = 2
  }
  elseif ($Action -eq 'list') {
    $repairIds = @()
    $healthIds = @()
    try { $repairIds = @((Import-CompatCatalog $RepairsCatalog).repairs | ForEach-Object { "$($_.id)" }) } catch {}
    try { $healthIds = @((Import-CompatCatalog $HealthCatalog).checks | ForEach-Object { "$($_.id)" }) } catch {}
    $out = [ordered]@{
      ok = $true
      action = 'list'
      probes = @($script:ProbeIds)
      verdictVocabulary = @($script:VerdictRank.Keys)
      healthCategories = @($script:HealthRules.Keys)
      repairs = @($script:RepairRules.Keys)
      catalogHealthCategories = $healthIds
      catalogRepairs = $repairIds
      note = 'No probing was done for this action. -Action check runs the probes and returns the machine''s capability profile.'
    }
  }
  elseif ($Action -eq 'selftest') {
    # Integrity of this file against the catalogs it must never drift from. Read-only.
    $failures = @()
    $checks = @()

    $repairCat = $null; $healthCat = $null; $compatCat = $null
    try { $repairCat = (Import-CompatCatalog $RepairsCatalog).repairs } catch { $failures += "data\repairs.json could not be read: $($_.Exception.Message)" }
    try { $healthCat = (Import-CompatCatalog $HealthCatalog).checks } catch { $failures += "data\health-checks.json could not be read: $($_.Exception.Message)" }
    try { $compatCat = (Import-CompatCatalog $CompatCatalog) } catch { $failures += "data\compat.json could not be read: $($_.Exception.Message)" }

    if ($null -ne $repairCat) {
      $catIds = @($repairCat | ForEach-Object { "$($_.id)" })
      $ruleIds = @($script:RepairRules.Keys)
      $missing = @($catIds | Where-Object { $ruleIds -notcontains $_ })
      $extra   = @($ruleIds | Where-Object { $catIds -notcontains $_ })
      if ($missing.Count -gt 0) { $failures += "compat.ps1 has no capability rule for these repairs in data\repairs.json: $($missing -join ', ')" }
      if ($extra.Count -gt 0)   { $failures += "compat.ps1 declares rules for repairs that do not exist in data\repairs.json: $($extra -join ', ')" }
      $checks += [ordered]@{ check = 'repair-ids-resolve'; ok = ($missing.Count -eq 0 -and $extra.Count -eq 0); catalogCount = $catIds.Count; ruleCount = $ruleIds.Count }
    }
    if ($null -ne $healthCat) {
      $catIds = @($healthCat | ForEach-Object { "$($_.id)" })
      $ruleIds = @($script:HealthRules.Keys)
      $missing = @($catIds | Where-Object { $ruleIds -notcontains $_ })
      $extra   = @($ruleIds | Where-Object { $catIds -notcontains $_ })
      if ($missing.Count -gt 0) { $failures += "compat.ps1 has no capability rule for these health categories: $($missing -join ', ')" }
      if ($extra.Count -gt 0)   { $failures += "compat.ps1 declares rules for health categories that do not exist in data\health-checks.json: $($extra -join ', ')" }
      $checks += [ordered]@{ check = 'health-ids-resolve'; ok = ($missing.Count -eq 0 -and $extra.Count -eq 0); catalogCount = $catIds.Count; ruleCount = $ruleIds.Count }
    }

    # The fact-id contract: every id a rule depends on must actually be produced by the probes.
    # Without this, a typo in a `requires` list silently becomes a permanent "unknown".
    $null = Invoke-CompatProbes
    $referenced = @()
    foreach ($tbl in @($script:HealthRules, $script:RepairRules)) {
      foreach ($k in @($tbl.Keys)) {
        foreach ($id in @($tbl[$k].requires)) { $referenced += $id }
        foreach ($id in @($tbl[$k].softens))  { $referenced += $id }
      }
    }
    $referenced = @($referenced | Select-Object -Unique)
    $undeclared = @($referenced | Where-Object { -not (Test-FactDeclared $_) })
    if ($undeclared.Count -gt 0) { $failures += "these fact ids are referenced by a capability rule but are never produced by the probes: $($undeclared -join ', ')" }
    $checks += [ordered]@{ check = 'fact-ids-produced'; ok = ($undeclared.Count -eq 0); referenced = $referenced.Count; produced = @($script:Facts.Keys).Count }

    # The local OS-identity fallback must agree with _lib.ps1's Get-FFOsInfo wherever both can
    # answer. This is what keeps the duplication honest instead of letting it drift.
    $emitted = @($script:Probes.Keys)
    $idsMissing = @($emitted | Where-Object { $script:ProbeIds -notcontains $_ })
    $idsExtra   = @($script:ProbeIds | Where-Object { $emitted -notcontains $_ })
    if ($idsMissing.Count -gt 0) { $failures += "-Action check emits probes that `$script:ProbeIds (and therefore -Action list) does not declare: $($idsMissing -join ', ')" }
    if ($idsExtra.Count -gt 0)   { $failures += "`$script:ProbeIds declares probes that -Action check does not emit: $($idsExtra -join ', ')" }
    $checks += [ordered]@{ check = 'probe-id-list-matches-emitted'; ok = ($idsMissing.Count -eq 0 -and $idsExtra.Count -eq 0); declared = @($script:ProbeIds).Count; emitted = $emitted.Count }

    # No probe may have FAILED during the selftest run: a probe that throws would otherwise
    # hide behind its placeholder and let the integrity checks pass on a machine where half
    # the report is missing.
    $failedProbes = @($emitted | Where-Object { $script:Probes[$_].probeFailed -eq $true })
    if ($failedProbes.Count -gt 0) { $failures += "these probes failed during the selftest run, so the capability profile they feed would be undetermined: $($failedProbes -join ', ')" }
    $checks += [ordered]@{ check = 'all-probes-ran'; ok = ($failedProbes.Count -eq 0); failed = @($failedProbes) }

    $agree = $script:Probes['os-identity'].localAgreesWithLibrary
    if ($agree -eq $false) { $failures += 'the local OS-identity fallback in compat.ps1 disagrees with _lib.ps1 Get-FFOsInfo about the build or the supported verdict' }
    $checks += [ordered]@{ check = 'os-identity-fallback-agrees'; ok = ($agree -ne $false); result = $agree; note = 'null means only one of the two rungs could answer, which is not a failure.' }

    if ($null -ne $compatCat) {
      $docIds = @()
      try { $docIds = @($compatCat.probes | ForEach-Object { "$($_.id)" }) } catch {}
      $engineIds = @($script:Probes.Keys)
      $missing = @($engineIds | Where-Object { $docIds -notcontains $_ })
      $extra   = @($docIds | Where-Object { $engineIds -notcontains $_ })
      if ($missing.Count -gt 0) { $failures += "data\compat.json does not document these probes: $($missing -join ', ')" }
      if ($extra.Count -gt 0)   { $failures += "data\compat.json documents probes compat.ps1 does not emit: $($extra -join ', ')" }
      $vocab = @()
      try { $vocab = @($compatCat.verdictVocabulary.PSObject.Properties | ForEach-Object { $_.Name }) } catch {}
      $vocabOk = (@(@($script:VerdictRank.Keys) | Where-Object { $vocab -notcontains $_ }).Count -eq 0)
      if (-not $vocabOk) { $failures += 'data\compat.json verdictVocabulary does not cover every verdict compat.ps1 can emit' }
      $checks += [ordered]@{ check = 'compat-catalog-documents-every-probe'; ok = ($missing.Count -eq 0 -and $extra.Count -eq 0); documented = $docIds.Count; emitted = $engineIds.Count }
      $checks += [ordered]@{ check = 'compat-catalog-verdict-vocabulary'; ok = $vocabOk }

      # Doctrine rule 5: every reason code a user can be shown must be documented.
      $docCodes = @()
      try { $docCodes = @($compatCat.constraintCodes.PSObject.Properties | ForEach-Object { "$($_.Name)" }) } catch {}
      $codesUndocumented = @($script:ConstraintCodes | Where-Object { $docCodes -notcontains $_ })
      $codesOrphaned     = @($docCodes | Where-Object { $script:ConstraintCodes -notcontains $_ })
      if ($codesUndocumented.Count -gt 0) { $failures += "compat.ps1 can emit these constraint codes but data\compat.json does not document them: $($codesUndocumented -join ', ')" }
      if ($codesOrphaned.Count -gt 0)     { $failures += "data\compat.json documents constraint codes compat.ps1 cannot emit: $($codesOrphaned -join ', ')" }
      $checks += [ordered]@{ check = 'compat-catalog-documents-every-constraint-code'; ok = ($codesUndocumented.Count -eq 0 -and $codesOrphaned.Count -eq 0); declared = @($script:ConstraintCodes).Count; documented = $docCodes.Count }
    }

    # Build the real verdict rows (read-only) and confirm nothing they emit is an undeclared
    # code. This catches a code that was typed straight into a New-Constraint call and never
    # added to $script:ConstraintCodes, for every code that fires on this machine.
    $emittedCodes = @()
    $allRows = @()
    if ($null -ne $healthCat) { $allRows += @(Get-HealthVerdicts $healthCat) }
    if ($null -ne $repairCat) { $allRows += @(Get-RepairVerdicts $repairCat) }
    foreach ($row in @($allRows)) { foreach ($x in @($row.reasons)) { $emittedCodes += "$($x.code)" } }
    $emittedCodes = @($emittedCodes | Select-Object -Unique)
    $undeclaredCodes = @($emittedCodes | Where-Object { $script:ConstraintCodes -notcontains $_ })
    if ($undeclaredCodes.Count -gt 0) { $failures += "these constraint codes were emitted on this machine but are not in compat.ps1's declared code list: $($undeclaredCodes -join ', ')" }
    $checks += [ordered]@{ check = 'emitted-codes-are-declared'; ok = ($undeclaredCodes.Count -eq 0); emitted = $emittedCodes.Count }

    # Every row's verdict must be the one its OWN reasons produce, and a row with any reason
    # at all must not be 'supported'. This is the property doctrine rule 2 turns on: the
    # verdict is a function of the evidence printed beside it, not something written
    # separately that a reader has to take on trust.
    $inconsistent = @()
    foreach ($row in @($allRows)) {
      $expected = Resolve-Verdict $row.reasons
      if ("$expected" -ne "$($row.verdict)") { $inconsistent += "$($row.id) says '$($row.verdict)' but its own reasons resolve to '$expected'" }
      elseif ("$($row.verdict)" -eq 'supported' -and @($row.reasons).Count -gt 0) { $inconsistent += "$($row.id) says 'supported' while carrying $(@($row.reasons).Count) reason(s) against it" }
    }
    if ($inconsistent.Count -gt 0) { $failures += "these capability rows carry a verdict their own evidence does not support: $($inconsistent -join '; ')" }
    $checks += [ordered]@{ check = 'verdicts-follow-their-own-evidence'; ok = ($inconsistent.Count -eq 0); rows = @($allRows).Count }

    $out = [ordered]@{
      ok = ($failures.Count -eq 0)
      action = 'selftest'
      checks = @($checks)
      failures = @($failures)
      note = 'Read-only. This proves compat.ps1 cannot drift from data\repairs.json, data\health-checks.json or data\compat.json without the check failing.'
    }
    if ($failures.Count -gt 0) { $exitCode = 1 }
  }
  else {
    # ---- check ----
    $durationMs = Invoke-CompatProbes
    $repairCat = $null; $healthCat = $null
    $catalogError = $null
    try { $repairCat = (Import-CompatCatalog $RepairsCatalog).repairs } catch { $catalogError = "data\repairs.json could not be read: $($_.Exception.Message)" }
    try { $healthCat = (Import-CompatCatalog $HealthCatalog).checks } catch { if ($null -eq $catalogError) { $catalogError = "data\health-checks.json could not be read: $($_.Exception.Message)" } }

    $healthRows = @(Get-HealthVerdicts $healthCat)
    $repairRows = @()
    if ($null -ne $repairCat) { $repairRows = @(Get-RepairVerdicts $repairCat) }
    # A capability profile that is MISSING every repair because data\repairs.json could not be
    # read used to come back ok:true with a summary counting only the health categories -
    # "9 of 12 capabilities can run here" - which reads as a complete report of a machine
    # where 28 repairs were never judged at all. The omission is now stated.
    $capabilitiesComplete = ($null -ne $repairCat -and $null -ne $healthCat)

    $all = @($healthRows + $repairRows)
    $totals = [ordered]@{}
    foreach ($v in @($script:VerdictRank.Keys)) { $totals[$v] = @($all | Where-Object { $_.verdict -eq $v }).Count }

    # Blockers: the things that stop FrameForge being useful here at all, said once, plainly,
    # at the top — so a user does not have to read 40 rows to find out why everything is red.
    $blockers = @()
    if ((Get-Fact 'env:full-language') -eq $false) {
      $blockers += [ordered]@{ id = 'constrained-language'; severity = 'blocking'; detail = (Get-FactDetail 'env:full-language'); fix = 'An administrator has to allow FrameForge''s script directory in the WDAC or AppLocker policy.' }
    }
    if ((Get-Fact 'env:execution-policy-allows-file') -eq $false) {
      $blockers += [ordered]@{ id = 'execution-policy-blocks-script-files'; severity = 'blocking'; detail = $script:Probes['rt-execution-policy'].detail; fix = 'Authenticode-sign the engine scripts, or have an administrator relax "Turn on Script Execution" for this machine.' }
    }
    if ((Get-Fact 'env:powershell-supported') -eq $false) {
      $blockers += [ordered]@{ id = 'powershell-too-old'; severity = 'blocking'; detail = (Get-FactDetail 'env:powershell-supported'); fix = 'Windows PowerShell 5.1 ships with Windows 10 and 11; on an older host, install it.' }
    }
    if ((Get-Fact 'env:os-supported') -eq $false) {
      $blockers += [ordered]@{ id = 'unvalidated-platform'; severity = 'warning'; detail = $script:Probes['os-identity'].unsupportedReason; fix = 'FrameForge is validated on Windows 11 client builds (22000 and newer). Read-only checks still run; treat every repair result here as unproven.' }
    }
    if ((Get-Fact 'env:admin') -eq $false) {
      $needsAdminCount = @($all | Where-Object { $_.verdict -eq 'needs-admin' }).Count
      $fix = 'Re-launch FrameForge as administrator.'
      if ((Get-Fact 'env:can-elevate') -eq $false) { $fix = 'The signed-in user is not a local administrator, so an administrator has to run FrameForge.' }
      $blockers += [ordered]@{ id = 'not-elevated'; severity = 'warning'; detail = "FrameForge is running unelevated, so $needsAdminCount check(s) and repair(s) cannot run as designed. $($script:Probes['rt-elevation'].detail)"; fix = $fix }
    }
    if ((Get-Fact 'env:english-ui') -eq $false) {
      $blockers += [ordered]@{ id = 'non-english-ui'; severity = 'info'; detail = (Get-FactDetail 'env:english-ui'); fix = 'Nothing to do. FrameForge reports "could not determine" where an English-only rung was its last resort — it does not guess, and it never reports a healthy result it did not measure.' }
    }
    if ((Get-Fact 'cap:system-restore') -eq $false) {
      $blockers += [ordered]@{ id = 'no-restore-point'; severity = 'warning'; detail = (Get-FactDetail 'cap:system-restore'); fix = 'Turn System Restore back on for the system drive, or accept the documented -NoRestorePoint opt-out for the aggressive-tier repairs.' }
    }
    if ($null -eq (Get-Fact 'env:admin')) {
      $blockers += [ordered]@{ id = 'elevation-undetermined'; severity = 'warning'; detail = "FrameForge could not determine whether it is running elevated on this machine, so it cannot say which administrator-gated checks and repairs would be allowed to run. $($script:Probes['rt-elevation'].detail)"; fix = 'Re-launch FrameForge as administrator to remove the doubt; every capability that depends on elevation is reported as undetermined until then.' }
    }
    if ($null -eq (Get-Fact 'env:os-supported')) {
      $blockers += [ordered]@{ id = 'platform-undetermined'; severity = 'warning'; detail = (Get-FactDetail 'env:os-supported'); fix = 'Nothing to do here. FrameForge reports the platform as undetermined rather than assuming it is one of the Windows 11 client builds it is validated on.' }
    }
    if ($null -eq (Get-Fact 'env:execution-policy-allows-file')) {
      $blockers += [ordered]@{ id = 'execution-policy-undetermined'; severity = 'warning'; detail = (Get-FactDetail 'env:execution-policy-allows-file'); fix = 'Run Get-ExecutionPolicy -List as an administrator to see the policy scopes. Until then FrameForge cannot promise its engine files will be allowed to run.' }
    }
    if ($null -eq (Get-Fact 'env:english-ui')) {
      $blockers += [ordered]@{ id = 'ui-language-undetermined'; severity = 'info'; detail = (Get-FactDetail 'env:english-ui'); fix = 'Nothing to do. Where a probe keeps an English-only last-resort rung, FrameForge reports that it could not determine the answer instead of guessing.' }
    }
    if ($null -eq (Get-Fact 'cap:system-restore')) {
      $blockers += [ordered]@{ id = 'restore-point-undetermined'; severity = 'warning'; detail = (Get-FactDetail 'cap:system-restore'); fix = 'The aggressive-tier repairs create a System Restore checkpoint as their first step and abort if they cannot. FrameForge is not going to promise that will work here.' }
    }
    if ($totals['unknown'] -gt 0) {
      $blockers += [ordered]@{ id = 'undetermined-capabilities'; severity = 'warning'; detail = "$($totals['unknown']) of $($all.Count) FrameForge capabilities could NOT be determined on this machine: something they depend on could not be read, so FrameForge will not say either way. Each row carries the reading that failed."; fix = 'Open the affected rows and read the reason. An undetermined capability is not a broken one - it is one FrameForge refuses to guess about.' }
    }
    if ($null -ne $catalogError) {
      $blockers += [ordered]@{ id = 'catalog-unreadable'; severity = 'blocking'; detail = "$catalogError This report is therefore INCOMPLETE: the capability list below covers only the catalog(s) that could be read, and the totals count only those."; fix = 'Reinstall or repair the FrameForge installation; data\\repairs.json and data\\health-checks.json ship with it.' }
    }
    foreach ($pk in @($script:Probes.Keys)) {
      if ($script:Probes[$pk].probeFailed -eq $true) {
        $blockers += [ordered]@{ id = "probe-failed:$pk"; severity = 'warning'; detail = "$($script:Probes[$pk].probeError) Everything that probe would have measured is reported as undetermined rather than assumed."; fix = 'Nothing to do here; the affected capabilities are marked unknown instead of being guessed at.' }
      }
    }
    if ((Get-Fact 'env:virtual-machine') -eq $true) {
      $blockers += [ordered]@{ id = 'virtual-machine'; severity = 'info'; detail = $script:Probes['ff-virtualization'].detail; fix = 'Nothing to do. Hardware-facing findings describe the hypervisor''s virtual devices; take them to the host, not to this guest.' }
    }

    $summaryBits = @()
    $summaryBits += "$($totals['supported']) of $($all.Count) FrameForge capabilities can run here as designed"
    if ($totals['needs-admin'] -gt 0) { $summaryBits += "$($totals['needs-admin']) need administrator rights" }
    if ($totals['degraded'] -gt 0)    { $summaryBits += "$($totals['degraded']) run with a named limitation" }
    if ($totals['unknown'] -gt 0)     { $summaryBits += "$($totals['unknown']) could not be determined" }
    if ($totals['unavailable'] -gt 0) { $summaryBits += "$($totals['unavailable']) cannot run on this machine at all" }
    if (-not $capabilitiesComplete) { $summaryBits += 'and this list is INCOMPLETE because a catalog could not be read, so capabilities are missing from it entirely' }

    $out = [ordered]@{
      ok             = $true
      schemaVersion  = 1
      action         = 'check'
      checkedAt      = (Get-Date).ToString('s')
      durationMs     = $durationMs
      summary        = (($summaryBits -join '; ') + '.')
      totals         = $totals
      blockers       = @($blockers)
      capabilities   = @($all)
      probes         = $script:Probes
      facts          = $script:Facts
      languageMode   = $script:LanguageMode
      libraryLoaded  = $script:LibLoaded
      libraryError   = $script:LibError
      catalogError   = $catalogError
      capabilitiesComplete = $capabilitiesComplete
      note           = 'Verdicts rank unavailable > degraded > unknown > needs-admin > supported, mirroring health.ps1''s status rank. "unknown" means FrameForge could not determine whether the capability works here — it is deliberately worse than "needs-admin" and never collapses into "supported". Every verdict traces to a fact id in .facts, and every fact is tri-state: true / false / null, where null is "could not determine".'
    }
  }
} catch {
  $out = [ordered]@{ ok = $false; errorCode = 'compat-failed'; error = "$($_.Exception.Message)"; action = $Action; languageMode = $script:LanguageMode }
  $exitCode = 1
}

if ($null -eq $out) {
  $out = [ordered]@{ ok = $false; errorCode = 'no-result'; error = "Action '$Action' produced no result document."; action = $Action }
  $exitCode = 1
}

Write-CompatJson -InputObject $out -Depth 16 -AsPretty:$Pretty
exit $exitCode
