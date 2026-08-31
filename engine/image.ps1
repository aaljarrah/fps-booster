<#
  FrameForge :: image.ps1
  Fresh-image repair engine: reinstall a fresh Windows image over a broken one
  without losing files, apps, or settings. Implements the full flow from
  docs/research/fresh-image-repair.md:

    detect              What identity must the media match? (edition/lang/build/arch)
                        plus safety-rail status. Read-only.
    validate            Mount an ISO, inventory install.wim/esd, verdict on whether
                        it can repair THIS machine. Read-only (mount/dismount only).
    acquire-url         Step 1 of the acquisition ladder: fetch Fido.ps1 from the
                        official pbatard/Fido GitHub (SHA-256 recorded, HTTPS only,
                        run out-of-process) and ask Microsoft's own servers for a
                        direct, ~24h-valid ISO URL. Falls back to MCT/manual as a
                        structured result - never crashes. Does NOT download the ISO.
    download            BITS transfer of a given URL to a destination + SHA-256.
    dism-source-repair  The lighter rung: use the ISO's install.wim/esd as an
                        offline DISM /RestoreHealth source (/LimitAccess). Admin.
    consent             Return the consent contract on its own (rails + the exact
                        commands that will pass /eula accept), so the UI can collect
                        acceptance BEFORE anything runs. Read-only.
    preflight           Full safety rails + setup.exe /compat scanonly (exit-code
                        translated). The compat scan is Windows Setup itself and it
                        REQUIRES /eula accept, so it is gated behind -AcceptEula
                        exactly like launch is gated behind -Confirm. Admin.
    launch              Construct the in-place repair command. Without -Confirm it
                        only returns the exact command + a consent contract for the
                        UI. With -Confirm AND admin AND green rails it starts
                        setup.exe (consent-gated handoff - doctrine rule 3).
    verify              Post-repair check against the ledger written at launch. Reads
                        SetupDiag's actual results (XML + HKLM\SYSTEM\Setup\SetupDiag\
                        Results) and names the cause, rather than only noting that a
                        results file exists. NOT scheduled automatically after the
                        upgrade restarts - see the `scheduling` block it returns.

  EULA HONESTY: two commands here pass '/eula accept' to Windows Setup - preflight's
  compat scan and launch's upgrade. BOTH are consent-gated (-AcceptEula and -Confirm
  respectively) and the consent contract says so. The contract used to claim nothing
  passes it until you consent, while preflight passed it unprompted one step earlier;
  that contradiction is gone.

  PORTABILITY: every environment-dependent fact here is read through a documented
  LADDER (structured API first, locale-independent codes next, honest unknown last),
  the same shape Get-FFUiLanguage has always used:
    architecture   PROCESSOR_ARCHITEW6432 -> .NET OSArchitecture -> Win32_Processor -> process env
    productName    Win32_OperatingSystem.Caption -> synthesised from build+edition ->
                   registry ProductName (which still says "Windows 10" on every Windows 11)
    build          registry CurrentBuildNumber -> Win32_OperatingSystem.BuildNumber
    AC power       WinForms PowerStatus -> Win32_Battery (no battery == line power) -> unknown
    BitLocker      Get-BitLockerVolume -> Win32_EncryptableVolume (Home has this; the
                   BitLocker module ships only with Pro/Enterprise/Education) -> unsupported
    access denied  exception type / HRESULT / CIM NativeErrorCode / error category, and only
                   then English message text
  A rung that cannot answer says so; nothing here converts an unread value into a
  confident verdict (doctrine rule 2).

  GENERATION RULE (rule zero of the matching rules): a repair must not change WHICH
  Windows you are running. Windows 11 media on a Windows 10 machine passes the
  edition/language/arch/build rules and would silently perform a major-version upgrade,
  so it is refused outright. A newer build of the SAME generation (23H2 -> 25H2) is a
  feature update rather than a same-build repair: it is refused unless -AllowFeatureUpdate
  is passed, and the consent contract then states the version change explicitly.

  Output: exactly ONE JSON document on stdout (house style; -Json accepted for
  interface symmetry) - including for invalid input, which is why -Action is validated
  in the body rather than with [ValidateSet] (a parameter-binding failure would exit
  with no JSON at all and break the one-document contract the Electron host relies on).
  The whole action dispatch runs inside a try/catch for the same reason.
  PowerShell 5.1 compatible. UTF-8 with BOM.

  Exit codes:
    0  a valid result document was produced (including honest structured
       fallbacks such as acquire-url's "use MCT instead" and consent-contract mode)
    2  invalid input (unknown action, missing/unknown ISO path, missing required parameter)
    3  refused: an action that was going to DO something declined to. Specifically:
         acquire-url  without -ConsentRunFido, or the pinned -FidoSha256 did not match
         preflight    the compat scan was refused for missing EULA consent, or (with
                      consent given) for want of administrator rights
         launch       -Confirm given but admin / setup.exe / media / rails are not green
       Note preflight still exits 0 when it RAN its scan and merely reports red rails or
       incompatible media: that is a successful pre-flight delivering a "no" answer, and
       readyToLaunch:false is where that lives.
    1  an unexpected error - still emitted as a JSON error document

  Nothing here mutates the system except the explicitly consent-gated actions:
  dism-source-repair (repairs the component store; admin, -DryRun available),
  preflight's compat scan (non-destructive but writes setup logs; -AcceptEula + admin),
  acquire-url's Fido fetch/run (-ConsentRunFido), and launch (only with -Confirm).
  detect/consent/validate/verify are read-only.
#>
[CmdletBinding()]
param(
  # NOTE: deliberately NOT [ValidateSet] - see the EULA/output notes above. Validated in
  # the body so an unknown action still returns exactly one JSON document.
  [Parameter(Position = 0)]
  [string]$Action = 'detect',
  [string]$IsoPath,
  [string]$SourcePath,      # already-extracted media folder (contains sources\install.wim|esd) as an alternative to -IsoPath
  [string]$Url,             # download: source URL (from acquire-url)
  [string]$Dest,            # download: destination file path
  # [string], not [int], for the same reason -Action is not [ValidateSet]: a parameter
  # binding failure ("-Index abc") would exit with no JSON at all. Parsed in the body.
  [string]$Index = '0',     # optional explicit image-index override for validate/dism-source-repair
  [switch]$Json,            # accepted for symmetry; output is always JSON
  [switch]$DryRun,          # heavy actions: report the exact command(s) without running them
  [switch]$AcceptEula,      # preflight: the user has accepted the Microsoft Software License Terms in the UI
  [switch]$Confirm,         # launch: the explicit consent gate - without it nothing starts
  [switch]$ConsentRunFido,  # acquire-url: consent to fetch and run the third-party Fido script
  [string]$FidoSha256,      # acquire-url: pin an expected SHA-256; a mismatch refuses to run the script
  [switch]$SuspendBitLocker, # launch: also Suspend-BitLocker -RebootCount 3 before setup
  # Media that is NEWER than the installed build (same Windows generation) is a feature
  # update, not a same-build repair. It is refused by default because the repair consent
  # contract describes a same-version reinstall; this switch is the explicit opt-in, and
  # the contract then carries isFeatureUpdate:true plus the exact version change.
  [switch]$AllowFeatureUpdate
)
$ValidActions = @('detect','consent','validate','acquire-url','download','dism-source-repair','preflight','launch','verify')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# ---------------- culture pin (must precede EVERY other statement in this process) ----------------
# IDENTICAL BLOCK, and identical reasoning, to engine/repair.ps1 - keep the two in step.
# PowerShell's -match, -notmatch, -like, -replace and -split fold case with the CURRENT CULTURE;
# only -eq / -ieq are invariant. Measured on Windows PowerShell 5.1 with CurrentCulture = tr-TR:
#     ('info' -match 'INFO') -> False,  ('INFO' -match '(?i)info') -> False,
#     ('CLIENT' -like 'Client*') -> False,  ('FILE' -replace 'file','X') -> 'FILE'.
# This file decides media compatibility, setup outcomes and rollback verdicts from text, so the
# fold has to be invariant. ORDERING IS LOAD-BEARING: PowerShell caches compiled Regex objects by
# pattern + options, so a pattern first evaluated under the machine culture keeps that culture's
# casing table even after the pin - measured. Hence this runs before _lib.ps1 is dot-sourced.
# CurrentUICulture is deliberately untouched: it is what localizes the OS text this file reads.
$script:FFCulturePinned = $false
try {
  [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
  $script:FFCulturePinned = $true
} catch {}

. (Join-Path $PSScriptRoot '_lib.ps1')
$IsAdmin = Test-Admin

# ---------------- culture-invariant text matching ----------------
# DUPLICATED DELIBERATELY, byte for byte, in engine/repair.ps1 (search for "Test-FFIMatch" there).
# Not in engine/_lib.ps1 because health.ps1 owns that file and the fixers work in parallel.
$script:FFReIC = ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
function Test-FFIMatch {
  <# Case-insensitive regex test that is invariant WHATEVER the thread culture is. Use this rather
     than -match wherever the answer decides what FrameForge reports about a machine. #>
  param([string]$Text, [string]$Pattern)
  if ($null -eq $Text) { return $false }
  try { return [regex]::IsMatch("$Text", $Pattern, $script:FFReIC) } catch { return $false }
}
function Test-FFILike {
  <# Case-insensitive wildcard test, invariant. -like's IgnoreCase folding is culture-bound too. #>
  param([string]$Text, [string]$Pattern)
  try {
    $opts = ([System.Management.Automation.WildcardOptions]::IgnoreCase -bor [System.Management.Automation.WildcardOptions]::CultureInvariant)
    return (New-Object System.Management.Automation.WildcardPattern($Pattern, $opts)).IsMatch("$Text")
  } catch { return $false }
}

$DataDir     = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'

# ---------------- runtime state location ----------------
# State NEVER lives in the install tree. Same rule, same folder, same reasoning as engine.ps1:34-45
# and engine/repair.ps1: a per-machine install under %ProgramFiles%, a read-only or network copy,
# Controlled Folder Access, or a OneDrive Known-Folder-Move profile all make <install>\data\state
# unwritable - and the launch ledger written here is the ONLY thing 'verify' can compare a
# post-upgrade machine against, so an unwritable state folder means no verdict at all afterwards.
# The Fido copy and the copied setup logs live here too.
$StateBase = $env:LOCALAPPDATA
if (-not $StateBase) { $StateBase = $env:TEMP }
# Plain concatenation, not Join-Path: Join-Path resolves the PSDrive and can throw when the root is
# bogus, which would kill the script before it emits the one JSON document the host parses.
$StateDir       = ($StateBase.TrimEnd('\')) + '\FrameForge\state'
$ToolsDir       = $StateDir + '\tools'
$LedgerPath     = $StateDir + '\image-repair-ledger.json'
$SetupLogDir    = $StateDir + '\setup-logs'
# v1 wrote these into the install tree. The ledger is MIGRATED (copied, never moved) on first use so
# a launch recorded by an earlier version can still be verified against.
$LegacyStateDir  = Join-Path $DataDir 'state'
$LegacyLedger    = Join-Path $LegacyStateDir 'image-repair-ledger.json'
$LegacyToolsDir  = Join-Path $LegacyStateDir 'tools'

$MinFreeGB = 30   # research doc: Microsoft floor is 20 GB; enforce 30 to cover ISO + working set

# Official Fido locations (pbatard/Fido, GPLv3; fetched at runtime and run
# out-of-process so the GPL script never links into the app). HTTPS only.
$FidoPrimaryUrl  = 'https://github.com/pbatard/Fido/releases/latest/download/Fido.ps1'
$FidoFallbackUrl = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
$ManualDownloadUrl = 'https://www.microsoft.com/software-download/windows11'
$ManualDownloadUrlWin10 = 'https://www.microsoft.com/software-download/windows10'

# ---------------- error classification (locale-independent) ----------------

function Test-FFAccessDenied {
  <#
    Was this failure an access denial? Decided STRUCTURALLY, because the exception
    MESSAGE is translated on every non-English Windows and a message match there
    silently returns "no" - which used to turn "re-run elevated" into "your ISO is
    unreadable". Ladder, most reliable first:
      1. exception type      [UnauthorizedAccessException]
      2. CIM/WMI             Exception.NativeErrorCode enum ('AccessDenied') - an enum,
                             never a translated string
      3. HRESULT / Win32     0x80070005 (E_ACCESSDENIED), 5, 1314 (privilege not held)
      4. error category      $_.CategoryInfo.Category -eq 'PermissionDenied'
      5. English message text - documented English-only, kept LAST, and it can only ADD
                             a positive: it never overturns a structural answer.
    Returns @{ denied = <bool>; via = <which rung answered, or $null> }.
  #>
  param($ErrorRecord)
  $r = [ordered]@{ denied = $false; via = $null }
  if ($null -eq $ErrorRecord) { return $r }
  $ex = $null
  try { $ex = $ErrorRecord.Exception } catch {}
  if ($null -ne $ex) {
    if ($ex -is [System.UnauthorizedAccessException]) { $r.denied = $true; $r.via = 'exception-type'; return $r }
    $native = $null
    try { $native = "$($ex.NativeErrorCode)" } catch {}
    if ($native -eq 'AccessDenied') { $r.denied = $true; $r.via = 'cim-native-error-code'; return $r }
    $h = $null
    try { $h = [int64]$ex.HResult } catch {}
    if ($null -ne $h -and $h -ne 0) {
      $code = ($h -band 0xFFFF)
      $facility = ($h -band 0x07FF0000)
      if ($facility -eq 0x00070000 -and ($code -eq 5 -or $code -eq 1314)) { $r.denied = $true; $r.via = 'hresult'; return $r }
      if ($h -eq 5 -or $h -eq 1314) { $r.denied = $true; $r.via = 'win32-code'; return $r }
    }
  }
  try {
    if ("$($ErrorRecord.CategoryInfo.Category)" -eq 'PermissionDenied') { $r.denied = $true; $r.via = 'error-category'; return $r }
  } catch {}
  try {
    # Documented English-only last rung.
    # Test-FFIMatch: 'denied' contains an 'i', so under tr-TR this rung silently answered "no".
    if (Test-FFIMatch "$($ex.Message)" 'denied|elevat|0x80070005') { $r.denied = $true; $r.via = 'english-message-text' }
  } catch {}
  $r
}

function Get-FFProp {
  <# Read one member off either a hashtable/ordered dictionary or a PSObject. #>
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  try {
    if ($Obj -is [System.Collections.IDictionary]) {
      if ($Obj.Contains($Name)) { return $Obj[$Name] }
      return $null
    }
  } catch {}
  try {
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
  } catch {}
  $null
}

function ConvertFrom-FFTimestamp {
  <#
    Parse a timestamp THIS codebase wrote with .ToString('s'). ToString('s') is invariant
    on the way out, but [datetime]::Parse() reads with the CurrentCulture INCLUDING its
    calendar. Measured on Windows PowerShell 5.1: the exact ISO 8601 'T' form happens to
    be recognised and read as Gregorian even under th-TH, but ANY other spelling of the
    same instant is not - '2026-08-30 18:07:00' (a space instead of the T: an older ledger
    entry, a hand-edited file, a different writer) is read as a Buddhist year under th-TH
    and lands in 1483 AD, and under ar-SA (Umm al-Qura) the same string throws outright.
    Relying on the parser's ISO special case is a coin flip on a value that decides a
    verify verdict, so this is invariant round-trip only; $null when it cannot be parsed,
    so callers report "unknown" instead of comparing against a garbage date.
  #>
  param([string]$Text)
  if (-not $Text) { return $null }
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  try { return [datetime]::ParseExact($Text, 's', $inv) } catch {}
  try { return [datetime]::Parse($Text, $inv, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
  $null
}

# ---------------- identity detection ----------------

function Get-FFUiLanguage {
  <#
    System DEFAULT UI language - the value the media language must match exactly
    (strict since Win11 22H2). Ladder:
      1. dism /English /Online /Get-Intl (authoritative; needs admin). /English forces
         DISM to emit English labels whatever the system language is, so the parse below
         is not the English-only accident it used to be - but it is still a TEXT parse,
         so it stays rung 1 with locale-independent rungs beneath it.
      2. HKLM Nls\Language InstallLanguage (hex LCID -> culture tag)
      3. [CultureInfo]::InstalledUICulture
    tag is $null with source 'unknown' when all three fail. Callers must treat that as
    "not measured", never as a mismatch.
  #>
  if ($IsAdmin) {
    try {
      $raw = & "$env:SystemRoot\System32\Dism.exe" /English /Online /Get-Intl 2>&1
      $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')
      # Invariant match: the label contains 'i' characters, and this rung decides the media
      # language rule that makes setup exit silently when it is wrong.
      $mLang = [regex]::Match($txt, 'Default system UI language\s*:\s*([A-Za-z]{2,3}(?:-[A-Za-z0-9]+){0,2})', $script:FFReIC)
      if ($mLang.Success) {
        return [ordered]@{ tag = $mLang.Groups[1].Value; source = 'dism-get-intl' }
      }
    } catch {}
  }
  try {
    $hex = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name InstallLanguage -ErrorAction Stop).InstallLanguage
    $ci = [System.Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($hex, 16))
    return [ordered]@{ tag = $ci.Name; source = 'registry-installlanguage' }
  } catch {}
  try {
    return [ordered]@{ tag = [System.Globalization.CultureInfo]::InstalledUICulture.Name; source = 'installed-ui-culture' }
  } catch {}
  [ordered]@{ tag = $null; source = 'unknown' }
}

function Convert-FFArchToken {
  <# Normalise any architecture spelling onto this file's vocabulary. #>
  param($Value)
  switch -Regex ("$Value") {
    '^(amd64|x64)$' { return 'x64' }
    '^(arm64)$'     { return 'arm64' }
    '^(x86|i386|i686)$' { return 'x86' }
    '^(arm)$'       { return 'arm' }
  }
  $null
}

function Get-FFOsArchitecture {
  <#
    The OS architecture - NOT the process architecture. $env:PROCESSOR_ARCHITECTURE
    describes the PROCESS: a 32-bit PowerShell host on 64-bit Windows reports 'x86',
    after which acquire-url refused ("no consumer ISO channel for x86") and the media
    arch rule failed against perfectly correct x64 media. Ladder:
      1. PROCESSOR_ARCHITEW6432 - set only under WOW64, and it holds the real OS arch
      2. [RuntimeInformation]::OSArchitecture - .NET's own OS-level answer
      3. Win32_Processor.Architecture (0=x86, 5=ARM, 9=x64, 12=ARM64)
      4. PROCESSOR_ARCHITECTURE - the process answer, last, and labelled as such
    Never guesses: 'unknown' with source 'unknown' if every rung fails.
  #>
  $out = [ordered]@{ value = 'unknown'; source = 'unknown'; wow64 = $false; processArchitecture = $null; note = $null }
  $out.processArchitecture = (Convert-FFArchToken $env:PROCESSOR_ARCHITECTURE)
  $w6432 = (Convert-FFArchToken $env:PROCESSOR_ARCHITEW6432)
  if ($w6432) {
    $out.wow64 = $true
    $out.value = $w6432
    $out.source = 'processor-architew6432'
    $out.note = "This engine is running as a $($out.processArchitecture) process on a $w6432 Windows (WOW64). The OS architecture, not the process architecture, is what the media must match."
    return $out
  }
  try {
    $osa = Convert-FFArchToken ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
    if ($osa) { $out.value = $osa; $out.source = 'dotnet-osarchitecture'; return $out }
  } catch {}
  try {
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop) | Select-Object -First 1
    if ($null -ne $cpu) {
      $a = $null
      switch ([int]$cpu.Architecture) {
        0  { $a = 'x86' }
        5  { $a = 'arm' }
        9  { $a = 'x64' }
        12 { $a = 'arm64' }
      }
      if ($a) { $out.value = $a; $out.source = 'cim-win32-processor'; return $out }
    }
  } catch {}
  if ($out.processArchitecture) {
    $out.value = $out.processArchitecture
    $out.source = 'processor-architecture-env-process-level'
    $out.note = 'Only the PROCESS architecture could be read; on a 64-bit Windows running a 32-bit host this can understate the OS.'
  }
  $out
}

function Get-FFGeneration {
  <#
    Which Windows this build belongs to. Used by matching rule zero: a repair must not
    change WHICH Windows you run. $null means "could not be determined" - never assume.
  #>
  param($Build)
  $b = $null
  try { if ($null -ne $Build -and "$Build" -match '^\d+$') { $b = [int]$Build } } catch {}
  if ($null -eq $b -or $b -le 0) { return $null }
  if ($b -ge 22000) { return 'win11' }
  if ($b -ge 10240) { return 'win10' }
  'legacy'
}

function Get-FFProductName {
  <#
    The human product name. HKLM\...\CurrentVersion\ProductName was NEVER updated for
    Windows 11: it reads "Windows 10 Pro" on every Windows 11 machine, and the fresh-image
    page rendered that verbatim at the consent gate for a full OS reinstall. Ladder:
      1. Win32_OperatingSystem.Caption      -> 'Microsoft Windows 11 Pro'
      2. synthesised from build + EditionID -> 'Windows 11 Professional'
      3. registry ProductName, tagged source 'registry-productname-known-stale'
    Returns @{ value; source; registryValue }.
  #>
  param($Cv, $Build)
  $out = [ordered]@{ value = $null; source = 'unknown'; registryValue = $null }
  try { if ($null -ne $Cv) { $out.registryValue = "$($Cv.ProductName)" } } catch {}
  try {
    $cap = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption)".Trim()
    if ($cap) { $out.value = $cap; $out.source = 'cim-win32-operatingsystem-caption'; return $out }
  } catch {}
  $gen = Get-FFGeneration -Build $Build
  $edition = $null
  try { if ($null -ne $Cv) { $edition = "$($Cv.EditionID)".Trim() } } catch {}
  if ($gen -eq 'win11' -or $gen -eq 'win10') {
    $num = $(if ($gen -eq 'win11') { '11' } else { '10' })
    $out.value = ("Windows $num $edition").Trim()
    $out.source = 'synthesised-from-build-and-edition'
    return $out
  }
  if ($out.registryValue) {
    $out.value = $out.registryValue
    $out.source = 'registry-productname-known-stale'
  }
  $out
}

function Get-FFOsIdentity {
  $cv = $null
  try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch {}
  $build = $null; $ubr = $null; $buildSource = 'unknown'
  if ($cv) {
    # NB: [int]$null is 0, not an error. Casting a missing registry value straight to
    # [int] therefore produced build 0 - a number, which silenced the CIM fallback below
    # and then read as "the media is NEWER than the installed build (26200 vs 0)".
    # Digits or nothing.
    $rawBuild = $null; $rawUbr = $null
    try { $rawBuild = "$($cv.CurrentBuildNumber)".Trim() } catch {}
    try { $rawUbr = "$($cv.UBR)".Trim() } catch {}
    if ($rawBuild -match '^\d+$') { $b = [int]$rawBuild; if ($b -gt 0) { $build = $b } }
    if ($rawUbr -match '^\d+$') { $ubr = [int]$rawUbr }
  }
  if ($null -ne $build) { $buildSource = 'registry-currentbuildnumber' }
  else {
    # GPO-hardened / Server Core images can hide the registry value. Without this the
    # build reads null and the media comparison blamed the ISO for it.
    try {
      $b = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber
      if ($b -gt 0) { $build = $b; $buildSource = 'cim-win32-operatingsystem-buildnumber' }
    } catch {}
  }
  $archInfo = Get-FFOsArchitecture
  $arch = $archInfo.value
  $productName = Get-FFProductName -Cv $cv -Build $build
  $buildString = $null
  if ($null -ne $build) {
    if ($null -ne $ubr) { $buildString = "$build.$ubr" } else { $buildString = "$build" }
  }
  [ordered]@{
    editionId          = "$(if ($cv) { $cv.EditionID })"
    productName        = "$($productName.value)"
    productNameSource  = $productName.source
    productNameRegistry= $productName.registryValue
    displayVersion     = "$(if ($cv) { $cv.DisplayVersion })"
    currentBuild       = $build
    currentBuildSource = $buildSource
    ubr                = $ubr
    buildString        = $buildString
    generation         = (Get-FFGeneration -Build $build)
    architecture       = $arch
    architectureSource = $archInfo.source
    architectureDetail = $archInfo
    language           = (Get-FFUiLanguage)
  }
}

# ---------------- safety rails ----------------

function Test-FFPendingReboot {
  <#
    The triple check (same signals health.ps1 uses), reported so the output explains
    itself. The old shape returned pendingFileRenames:true alongside any:false, which
    reads as a flat self-contradiction in any UI that renders it - the reasoning lived
    only in a source comment. There is no 'any' field now: 'blocksSetup' says exactly
    what the rail means, and 'explanation' says why.
  #>
  $pr = [ordered]@{
    cbsRebootPending    = $false
    wuRebootRequired    = $false
    pendingFileRenames  = $false
    anySignalPresent    = $false   # literally "is any of the three set"
    blocksSetup         = $false   # the rail: would Windows Setup refuse with 0xC1900107
    explanation         = $null
  }
  try { $pr.cbsRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' } catch {}
  try { $pr.wuRebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' } catch {}
  try {
    $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    $pr.pendingFileRenames = ($null -ne $v.PendingFileRenameOperations -and @($v.PendingFileRenameOperations).Count -gt 0)
  } catch {}
  $pr.anySignalPresent = ($pr.cbsRebootPending -or $pr.wuRebootRequired -or $pr.pendingFileRenames)
  # Setup 0xC1900107 is triggered by servicing/WU pendings. PendingFileRenameOperations
  # alone is common and benign - ordinary installers and updaters set it constantly - so
  # it is reported but does NOT turn the rail red by itself.
  $pr.blocksSetup = ($pr.cbsRebootPending -or $pr.wuRebootRequired)
  $blockers = @()
  if ($pr.cbsRebootPending) { $blockers += 'component servicing (CBS RebootPending)' }
  if ($pr.wuRebootRequired) { $blockers += 'Windows Update (RebootRequired)' }
  if ($pr.blocksSetup) {
    $pr.explanation = "A restart is pending from $($blockers -join ' and '). Windows Setup refuses to start with 0xC1900107 while that is true - restart the PC first."
  } elseif ($pr.pendingFileRenames) {
    $pr.explanation = 'PendingFileRenameOperations is set, but nothing here blocks Windows Setup. That value is written by ordinary installers to finish moving files at the next boot; only the component-servicing and Windows Update pending-reboot signals cause setup error 0xC1900107. Reported for completeness, deliberately not treated as a blocker.'
  } else {
    $pr.explanation = 'No pending restart of any kind. Windows Setup will not hit 0xC1900107.'
  }
  $pr
}

function Get-FFPowerStatus {
  <#
    AC power, as a TRI-STATE. The old shape initialised onAc=$false and only ever set it
    inside the WinForms try block, so a failed Add-Type (WDAC/ConstrainedLanguage) or a
    firmware that reports ACLineStatus=Unknown(255) produced the confident claim
    "Not on AC power" about a desktop that has no battery at all - while the very same
    object carried the note "AC rail passes trivially". Ladder:
      1. WinForms SystemInformation.PowerStatus (Online/Offline is an answer; anything
         else, including Unknown, is not)
      2. Win32_Battery: NO instances means there is no system battery, which means the
         machine is by definition on line power - the desktop case, decided by CIM rather
         than by a WinForms enum that some firmware refuses to fill in. With a battery
         present, BatteryStatus discriminates charging/AC from discharging.
      3. neither answered -> acKnown:$false, and the rail must say "could not be
         determined", never "not on AC power".
    onAc stays a boolean (the renderer reads it); acKnown says whether it was measured.
  #>
  $out = [ordered]@{ lineStatus = 'unknown'; onAc = $false; acKnown = $false; batteryPresent = $null; source = $null; note = $null; layers = @() }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $out.lineStatus = "$($ps.PowerLineStatus)"
    $chg = "$($ps.BatteryChargeStatus)"
    if (Test-FFIMatch $chg 'NoSystemBattery') { $out.batteryPresent = $false }
    elseif ((Test-FFIMatch $chg 'Unknown') -or $chg -eq '255') { $out.batteryPresent = $null }
    else { $out.batteryPresent = $true }
    if ($out.lineStatus -eq 'Online' -or $out.lineStatus -eq 'Offline') {
      $out.onAc = ($out.lineStatus -eq 'Online')
      $out.acKnown = $true
      $out.source = 'winforms-powerstatus'
    } else {
      $out.layers += "WinForms PowerStatus returned line status '$($out.lineStatus)' - the firmware did not report whether the charger is connected."
    }
  } catch {
    $out.layers += "WinForms PowerStatus is unavailable in this host: $($_.Exception.Message)"
  }
  $batteries = $null
  try { $batteries = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { $out.layers += "Win32_Battery could not be queried: $($_.Exception.Message)" }
  if ($null -ne $batteries) {
    if ($batteries.Count -eq 0) {
      # No system battery: line power is the only way this machine is running.
      if ($out.acKnown -and -not $out.onAc) { $out.layers += "WinForms reported line status '$($out.lineStatus)', but Win32_Battery reports no system battery at all - a machine with no battery is on line power, so the CIM answer wins." }
      $out.batteryPresent = $false
      $out.onAc = $true
      $out.acKnown = $true
      $out.source = 'cim-no-system-battery'
      $out.note = 'Desktop (no system battery detected via Win32_Battery) - the AC rail passes trivially.'
    } else {
      $out.batteryPresent = $true
      if (-not $out.acKnown) {
        $st = $null
        try { $st = [int]$batteries[0].BatteryStatus } catch {}
        # Win32_Battery.BatteryStatus: 1 discharging; 2 on AC; 3 fully charged; 6-9 charging.
        # 4/5 (low/critical), 10 (undefined) and 11 (partially charged) do NOT reliably say
        # whether the charger is connected, so they stay undetermined rather than guessing.
        if ($st -eq 1) { $out.onAc = $false; $out.acKnown = $true; $out.source = 'cim-battery-status' }
        elseif ($null -ne $st -and @(2, 3, 6, 7, 8, 9) -contains $st) { $out.onAc = $true; $out.acKnown = $true; $out.source = 'cim-battery-status' }
        else { $out.layers += "Win32_Battery.BatteryStatus is '$st', which does not say whether the charger is connected." }
      }
    }
  }
  if (-not $out.acKnown) {
    $out.source = 'none'
    $out.note = "AC power state could not be determined. $(@($out.layers) -join ' ')".Trim()
  } elseif (-not $out.note) {
    $out.note = "Line power: $(if ($out.onAc) { 'connected' } else { 'running on battery' }) (read via $($out.source))."
  }
  $out
}

function Get-FFBitLockerStatus {
  <#
    BitLocker/Device Encryption on the system drive + whether a numeric RecoveryPassword
    protector exists (the thing the user must be able to produce if a recovery prompt
    appears after the upgrade's reboots).

    The BitLocker POWERSHELL MODULE ships only with Pro/Enterprise/Education. On Windows 11
    Home - about half of consumer installs, and the population most likely to be silently
    Device-Encrypted on 24H2/25H2 - Get-BitLockerVolume does not exist at all, so the old
    code reported status 'error' with a raw CommandNotFoundException as the rail note (or
    'needs-admin', which sent the user off to elevate for a problem elevation cannot fix).
    Either way bitlockerKnown stayed false and the entire in-place repair path was
    permanently unreachable on Home. Ladder:
      1. Get-BitLockerVolume, when the cmdlet actually exists
      2. Win32_EncryptableVolume in root\cimv2\security\MicrosoftVolumeEncryption - the
         provider Device Encryption itself uses, present on Home. ProtectionStatus and
         ConversionStatus are numeric enums (locale-independent) and GetKeyProtectors(3)
         answers the recovery-password question. It needs the same elevation the rail
         already requires; unelevated it returns a structured AccessDenied.
      3. neither -> status 'unsupported': this edition has no BitLocker management
         provider, so the system drive cannot be BitLocker/Device-Encryption protected.
    manage-bde.exe is deliberately NOT parsed as a further rung: its output is localized
    free text and this file's whole doctrine puts text matching last, behind structured
    answers. 'source' records which rung answered; 'layers' keeps the raw failures as
    evidence so no raw exception text ever becomes the rail's note.
  #>
  $out = [ordered]@{ status = 'unknown'; source = $null; volumeStatus = $null; protectionStatus = $null; recoveryPasswordProtector = $null; keyProtectorTypes = @(); note = $null; layers = @() }
  $sysDrive = "$env:SystemDrive"
  $denied = $false

  # --- rung 1: the BitLocker module ---
  $haveCmdlet = $false
  try { $haveCmdlet = [bool](Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) } catch {}
  if ($haveCmdlet) {
    try {
      $bv = Get-BitLockerVolume -MountPoint $sysDrive -ErrorAction Stop
      $out.status = 'checked'
      $out.source = 'get-bitlockervolume'
      $out.volumeStatus = "$($bv.VolumeStatus)"
      $out.protectionStatus = "$($bv.ProtectionStatus)"
      $out.keyProtectorTypes = @($bv.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
      $out.recoveryPasswordProtector = (@($out.keyProtectorTypes | Where-Object { $_ -eq 'RecoveryPassword' }).Count -gt 0)
      if ($out.protectionStatus -eq 'On' -and -not $out.recoveryPasswordProtector) {
        $out.note = 'BitLocker is on but no numeric recovery-password protector exists - the user must confirm access to a recovery key (aka.ms/myrecoverykey) before an in-place repair.'
      } else {
        $out.note = "BitLocker protection on $sysDrive is '$($out.protectionStatus)' (volume $($out.volumeStatus)), read with Get-BitLockerVolume."
      }
      return $out
    } catch {
      $d = Test-FFAccessDenied $_
      if ($d.denied) { $denied = $true }
      $out.layers += "Get-BitLockerVolume failed$(if ($d.denied) { " with an access denial (detected via $($d.via))" }): $($_.Exception.Message)"
    }
  } else {
    $out.layers += 'Get-BitLockerVolume is not present: the BitLocker PowerShell module ships only with Pro/Enterprise/Education editions.'
  }

  # --- rung 2: the volume-encryption WMI provider (present on Home) ---
  $vols = $null
  $providerMissing = $false
  try {
    $vols = @(Get-CimInstance -Namespace 'root\cimv2\security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$sysDrive'" -ErrorAction Stop)
  } catch {
    $native = ''
    try { $native = "$($_.Exception.NativeErrorCode)" } catch {}
    if ($native -eq 'InvalidNamespace' -or $native -eq 'InvalidClass') { $providerMissing = $true }
    $d = Test-FFAccessDenied $_
    if ($d.denied) { $denied = $true }
    $out.layers += "Win32_EncryptableVolume could not be queried (CIM error '$native')."
  }
  if ($null -ne $vols -and $vols.Count -gt 0) {
    $v = $vols[0]
    $out.status = 'checked'
    $out.source = 'cim-win32-encryptablevolume'
    $psv = $null
    try { $psv = [int]$v.ProtectionStatus } catch {}
    switch ($psv) {
      0 { $out.protectionStatus = 'Off' }
      1 { $out.protectionStatus = 'On' }
      default { $out.protectionStatus = 'Unknown' }
    }
    $csv = $null
    try { $csv = [int]$v.ConversionStatus } catch {}
    switch ($csv) {
      0 { $out.volumeStatus = 'FullyDecrypted' }
      1 { $out.volumeStatus = 'FullyEncrypted' }
      2 { $out.volumeStatus = 'EncryptionInProgress' }
      3 { $out.volumeStatus = 'DecryptionInProgress' }
      4 { $out.volumeStatus = 'EncryptionPaused' }
      5 { $out.volumeStatus = 'DecryptionPaused' }
      default { $out.volumeStatus = $null }
    }
    try {
      $kp = Invoke-CimMethod -InputObject $v -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction Stop
      if ($null -ne $kp -and [int]$kp.ReturnValue -eq 0) {
        $ids = @($kp.VolumeKeyProtectorID | Where-Object { "$_" -match '\S' })
        $out.recoveryPasswordProtector = ($ids.Count -gt 0)
        if ($ids.Count -gt 0) { $out.keyProtectorTypes = @('RecoveryPassword') }
      } else {
        $out.recoveryPasswordProtector = $null
        $out.layers += "GetKeyProtectors(RecoveryPassword) returned $(if ($null -ne $kp) { $kp.ReturnValue } else { 'no result' })."
      }
    } catch {
      $out.recoveryPasswordProtector = $null
      $out.layers += "GetKeyProtectors(RecoveryPassword) failed: $($_.Exception.Message)"
    }
    if ($out.protectionStatus -eq 'On' -and $out.recoveryPasswordProtector -eq $false) {
      $out.note = 'Encryption is ON for this drive but no numeric recovery-password protector exists - confirm access to a recovery key (aka.ms/myrecoverykey) before an in-place repair.'
    } elseif ($out.protectionStatus -eq 'On' -and $null -eq $out.recoveryPasswordProtector) {
      $out.note = "Encryption is ON for $sysDrive (read via the volume-encryption WMI provider), but whether a numeric recovery-password protector exists could NOT be read - so this rail is unknown, not green."
    } elseif ($out.protectionStatus -eq 'Unknown') {
      $out.note = "The volume-encryption provider answered, but it reported protection status 'unknown' for $sysDrive - the encryption state was not established."
    } else {
      $out.note = "Encryption on $sysDrive is '$($out.protectionStatus)' (volume $($out.volumeStatus)), read via the volume-encryption WMI provider (this edition has no BitLocker PowerShell module)."
    }
    return $out
  }

  # --- rung 3: no provider at all, or no answer ---
  if ($null -ne $vols -and $vols.Count -eq 0) {
    $out.layers += "The volume-encryption provider answered but returned no volume for $sysDrive."
  }
  if ($providerMissing -and -not $haveCmdlet) {
    $out.status = 'unsupported'
    $out.source = 'none'
    $out.note = 'This Windows edition has no BitLocker management provider (Home editions ship without the BitLocker module, and this system has no volume-encryption WMI provider either), so the system drive cannot be BitLocker- or Device-Encryption-protected. Nothing to suspend and no recovery key to lose.'
    return $out
  }
  if ($denied -or -not $IsAdmin) {
    $out.status = 'needs-admin'
    $out.source = 'none'
    $out.note = $(if ($haveCmdlet) {
      'Reading the BitLocker state was denied - it requires administrator rights. Re-run elevated.'
    } else {
      'This edition has no BitLocker PowerShell module, so the encryption state can only come from the volume-encryption WMI provider - and that provider denies unelevated reads. Re-run elevated.'
    })
    return $out
  }
  $out.status = 'error'
  $out.source = 'none'
  $out.note = 'The drive encryption state could not be read from either the BitLocker module or the volume-encryption WMI provider. It is unknown, not green - see bitlocker.layers for what each attempt reported.'
  $out
}

function Get-FFRails {
  $sysDrive = "$env:SystemDrive"
  $freeGB = $null
  try {
    $d = Get-PSDrive -Name ($sysDrive.TrimEnd(':')) -ErrorAction Stop
    $freeGB = [math]::Round($d.Free / 1GB, 1)
  } catch {}
  $power = Get-FFPowerStatus
  $bitlocker = Get-FFBitLockerStatus
  $pending = Test-FFPendingReboot
  $diskOk = ($null -ne $freeGB -and $freeGB -ge $MinFreeGB)
  # BitLocker only blocks when protection is ON and no recovery-password protector
  # exists; 'needs-admin'/'error' mean the rail is UNKNOWN, not green - callers that
  # execute must treat unknown as red. 'unsupported' is different from unknown: this
  # edition has no BitLocker management provider at all, so the drive cannot be
  # BitLocker/Device-Encryption protected and the rail is satisfied (the consent
  # checkbox already reads "...or this drive is not encrypted").
  $blBlocking = $false; $blKnown = $false; $blBasis = $null
  switch ("$($bitlocker.status)") {
    'checked' {
      if ($bitlocker.protectionStatus -eq 'On') {
        if ($bitlocker.recoveryPasswordProtector -eq $true) { $blKnown = $true; $blBasis = 'protected-with-recovery-password' }
        elseif ($bitlocker.recoveryPasswordProtector -eq $false) { $blKnown = $true; $blBlocking = $true; $blBasis = 'protected-without-recovery-password' }
        else { $blBasis = 'protection-on-protectors-unreadable' }   # honest unknown
      } elseif ($bitlocker.protectionStatus -eq 'Off') {
        $blKnown = $true; $blBasis = 'not-protected'
      } else {
        $blBasis = 'protection-status-unknown'
      }
    }
    'unsupported' { $blKnown = $true; $blBasis = 'no-bitlocker-management-provider-on-this-edition' }
    default { $blBasis = "state-not-read ($($bitlocker.status))" }
  }
  [ordered]@{
    systemDrive           = $sysDrive
    freeSystemDriveGB     = $freeGB
    minRequiredGB         = $MinFreeGB
    diskOk                = $diskOk
    power                 = $power
    acKnown               = [bool]$power.acKnown
    bitlocker             = $bitlocker
    bitlockerKnown        = $blKnown
    bitlockerBlocking     = $blBlocking
    bitlockerBasis        = $blBasis
    pendingReboot         = $pending
  }
}

function Test-FFRailsGreen {
  # Strict: every rail must be affirmatively green (unknown = red) - used only by
  # execute paths. Reporting paths surface the individual rails instead.
  param($Rails)
  $reasons = @()
  if (-not $Rails.diskOk) { $reasons += "Free space on $($Rails.systemDrive) is $($Rails.freeSystemDriveGB) GB; at least $MinFreeGB GB is required." }
  # "could not be determined" is not the same claim as "on battery" - say which it is.
  if (-not $Rails.power.acKnown) {
    $reasons += "AC power state could not be determined ($($Rails.power.note)) - confirm the charger is connected before launching."
  } elseif (-not $Rails.power.onAc) {
    $reasons += "Not on AC power (line status: $($Rails.power.lineStatus), read via $($Rails.power.source))."
  }
  if ($Rails.pendingReboot.blocksSetup) { $reasons += "$($Rails.pendingReboot.explanation)" }
  if (-not $Rails.bitlockerKnown) { $reasons += "The drive encryption state is unknown ($($Rails.bitlocker.status)): $($Rails.bitlocker.note) It must be established before launch." }
  if ($Rails.bitlockerBlocking) { $reasons += 'BitLocker protection is on with no recovery-password protector - confirm recovery-key access first.' }
  [ordered]@{ green = ($reasons.Count -eq 0); reasons = $reasons }
}

# ---------------- media handling ----------------

function Resolve-FFMedia {
  <#
    Turns -IsoPath (mounted via Mount-DiskImage) or -SourcePath (already-extracted
    folder) into @{ ok; error; errorCode; root; imageFile; kind; mountedByUs; isoPath }.
    kind is 'wim' or 'esd'. Caller MUST pass the result to Complete-FFMedia when done.
  #>
  param([string]$Iso, [string]$Source)
  $out = [ordered]@{ ok = $false; error = $null; errorCode = $null; root = $null; imageFile = $null; kind = $null; mountedByUs = $false; isoPath = $null }
  if (-not $Iso -and -not $Source) {
    $out.error = 'No media given: pass -IsoPath <file.iso> or -SourcePath <extracted media folder>.'
    $out.errorCode = 'no-media-param'
    return $out
  }
  if ($Source) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
      $out.error = "SourcePath not found or not a folder: $Source"
      $out.errorCode = 'source-not-found'
      return $out
    }
    $out.root = (Resolve-Path -LiteralPath $Source).Path
  } else {
    if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
      $out.error = "ISO file not found: $Iso"
      $out.errorCode = 'iso-not-found'
      return $out
    }
    $abs = (Resolve-Path -LiteralPath $Iso).Path
    $out.isoPath = $abs
    $wasAttached = $false
    try {
      $pre = Get-DiskImage -ImagePath $abs -ErrorAction Stop
      $wasAttached = [bool]$pre.Attached
    } catch {}
    try {
      $null = Mount-DiskImage -ImagePath $abs -PassThru -ErrorAction Stop
      $out.mountedByUs = (-not $wasAttached)
    } catch {
      $out.error = "Could not mount the ISO: $($_.Exception.Message)"
      $out.errorCode = 'mount-failed'
      return $out
    }
    # The volume can take a moment to surface after mounting.
    $letter = $null
    for ($i = 0; $i -lt 10 -and -not $letter; $i++) {
      try {
        $vol = Get-DiskImage -ImagePath $abs -ErrorAction Stop | Get-Volume -ErrorAction Stop
        if ($vol -and $vol.DriveLetter) { $letter = "$($vol.DriveLetter)" }
      } catch {}
      if (-not $letter) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $letter) {
      if ($out.mountedByUs) { try { Dismount-DiskImage -ImagePath $abs -ErrorAction Stop | Out-Null } catch {} }
      $out.mountedByUs = $false
      $out.error = 'The ISO mounted but no drive letter appeared for it.'
      $out.errorCode = 'no-drive-letter'
      return $out
    }
    $out.root = "$letter`:"
  }
  foreach ($cand in @('install.wim', 'install.esd')) {
    $p = Join-Path (Join-Path $out.root 'sources') $cand
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $out.imageFile = $p
      $out.kind = [System.IO.Path]::GetExtension($cand).TrimStart('.')
      break
    }
  }
  if (-not $out.imageFile) {
    $out.error = "No sources\install.wim or sources\install.esd under '$($out.root)' - this is not Windows install media."
    $out.errorCode = 'not-windows-media'
    Complete-FFMedia $out
    return $out
  }
  $out.ok = $true
  $out
}

function Complete-FFMedia {
  param($Media)
  if ($Media -and $Media.mountedByUs -and $Media.isoPath) {
    try { Dismount-DiskImage -ImagePath $Media.isoPath -ErrorAction Stop | Out-Null } catch {}
    $Media.mountedByUs = $false
  }
}

function Convert-FFImageArch {
  # Get-WindowsImage Architecture arrives as an int (0/5/9/12) or a display string.
  param($Value)
  $s = "$Value"
  switch -Regex ($s) {
    '^(9|x64|AMD64)$'  { return 'x64' }
    '^(12|ARM64)$'     { return 'arm64' }
    '^(0|x86)$'        { return 'x86' }
    '^(5|ARM)$'        { return 'arm' }
  }
  if ($s) { return $s.ToLowerInvariant() }
  $null
}

function Get-FFMediaInventory {
  <#
    Per-index inventory of an install.wim/esd. The bare listing gives index+name;
    edition/version/languages/arch need a per-index query. One broken index must
    not break the inventory (detailError is recorded instead).
  #>
  param([string]$ImageFile)
  $rows = @()
  $list = @(Get-WindowsImage -ImagePath $ImageFile -ErrorAction Stop)
  foreach ($e in $list) {
    $row = [ordered]@{
      index = [int]$e.ImageIndex; name = "$($e.ImageName)"
      editionId = $null; version = $null; build = $null; ubr = $null
      languages = @(); architecture = $null; detailError = $null
    }
    try {
      $d = Get-WindowsImage -ImagePath $ImageFile -Index $row.index -ErrorAction Stop
      $row.editionId = "$($d.EditionId)"
      $row.version = "$($d.Version)"
      $row.languages = @(@($d.Languages) | ForEach-Object { "$_" })
      $row.architecture = Convert-FFImageArch $d.Architecture
      # Version is 10.0.<build>[.<ubr>]; WIM metadata may carry the UBR in SPBuild.
      $parts = @("$($d.Version)" -split '\.')
      if ($parts.Count -ge 3) { try { $row.build = [int]$parts[2] } catch {} }
      if ($parts.Count -ge 4) { try { $row.ubr = [int]$parts[3] } catch {} }
      if ($null -eq $row.ubr -and $null -ne $d.SPBuild) { try { $row.ubr = [int]$d.SPBuild } catch {} }
    } catch {
      $row.detailError = "$($_.Exception.Message)"
    }
    $rows += $row
  }
  $rows
}

function Compare-FFMediaToOs {
  <#
    The matching rules from the research doc (§4), in order of how a human would
    reason about them:
      0. generation - the media must be the SAME Windows as the one installed. Windows 11
                      media on a Windows 10 machine passes every rule below (EditionID
                      'Professional' matches, language matches, arch matches, build 26200
                      is "newer" than 19045) and would turn "repair my Windows" into a
                      major-version upgrade. Refused outright.
      1. edition   - exact EditionID match against an image index
      2. language  - STRICT since 22H2: the system default UI language must be in
                     the image's language list (even en-US vs en-GB fails)
      3. arch      - x64 media on x64
      4. build     - same-or-newer than the installed build; older is refused for
                     repair-upgrade AND useless as a DISM source (0x800f081f). NEWER, in
                     the same generation, is a feature update rather than a repair: it
                     needs -AllowFeatureUpdate, because the consent contract the user
                     accepted describes a same-version reinstall.

    THREE outcomes, not two. A rule that could not be EVALUATED (unknown UI language,
    unreadable OS build, unknown architecture) goes to $undetermined, which sets
    determined:$false - "not proven compatible", not "proven incompatible". Only an
    actually-measured failure goes to $reasons. Checks carry pass:$null for the
    undetermined ones. Nothing here reports a mismatch it never measured.

    Returns @{ determined; compatible; reasons[]; undetermined[]; checks[];
               selectedIndex; imageInfo; notes[]; isFeatureUpdate; featureUpdateAllowed }.
  #>
  param($Os, $Rows, [int]$ForceIndex = 0, [switch]$AllowFeatureUpdate)
  $reasons = @(); $checks = @(); $notes = @(); $undetermined = @()
  $isFeatureUpdate = $null
  $selected = $null

  if ($ForceIndex -gt 0) {
    $selected = @($Rows | Where-Object { $_.index -eq $ForceIndex }) | Select-Object -First 1
    if ($null -eq $selected) {
      $reasons += "Requested index $ForceIndex does not exist on the media (indices: $(@($Rows | ForEach-Object { $_.index }) -join ', '))."
    } else {
      $notes += "Index $ForceIndex was explicitly requested; edition auto-matching was bypassed."
    }
  } else {
    $selected = @($Rows | Where-Object { $_.editionId -and $Os.editionId -and ($_.editionId -ieq $Os.editionId) }) | Select-Object -First 1
  }

  # 1. Edition
  $mediaEditions = @($Rows | ForEach-Object { $_.editionId } | Where-Object { $_ } | Select-Object -Unique)
  if ($null -eq $selected) {
    $checks += [ordered]@{ check = 'edition'; pass = $false; detail = "No image on the media matches installed edition '$($Os.editionId)' (media editions: $(if ($mediaEditions.Count) { $mediaEditions -join ', ' } else { 'unreadable' }))." }
    $reasons += "Edition mismatch: the installed edition is '$($Os.editionId)' but the media has no matching image. A repair install requires matching media (Home->Home, Pro->Pro; Enterprise needs Enterprise media)."
  } else {
    $editionPass = ($ForceIndex -gt 0) -or ($selected.editionId -ieq $Os.editionId)
    $checks += [ordered]@{ check = 'edition'; pass = $editionPass; detail = "Installed: '$($Os.editionId)'; selected index $($selected.index) ('$($selected.name)') is '$($selected.editionId)'." }
    if (-not $editionPass) { $reasons += "Edition mismatch on forced index $($selected.index): media '$($selected.editionId)' vs installed '$($Os.editionId)'." }
  }

  if ($null -ne $selected -and $null -eq $selected.detailError) {
    # 0. Generation - rule zero: a repair must not change WHICH Windows you are running.
    $osGen = $Os.generation
    $mediaGen = Get-FFGeneration -Build $selected.build
    if ($null -eq $osGen -or $null -eq $mediaGen) {
      $checks += [ordered]@{ check = 'generation'; pass = $null; detail = "OS generation: $(if ($osGen) { $osGen } else { 'could not be determined' }) (build '$($Os.currentBuild)'); media generation: $(if ($mediaGen) { $mediaGen } else { 'could not be determined' }) (build '$($selected.build)')." }
      $undetermined += "Which Windows generation is installed and/or on the media could not be determined (OS build '$($Os.currentBuild)', media build '$($selected.build)'), so the rule that a repair must not change your Windows version could NOT be checked."
    } else {
      $genPass = ($osGen -eq $mediaGen)
      $checks += [ordered]@{ check = 'generation'; pass = $genPass; detail = "OS is $osGen (build $($Os.currentBuild)); media is $mediaGen (build $($selected.build))." }
      if (-not $genPass) {
        $reasons += "Generation mismatch: this is $mediaGen media on a $osGen machine. An in-place run of this media is a MAJOR VERSION UPGRADE, not a repair. FrameForge refuses it: a repair must not change which Windows you are running. If you actually want to move from $osGen to $mediaGen, that is an upgrade decision to make deliberately with Microsoft's own upgrade path, not through a repair flow."
      }
    }

    # 2. Language (strict 22H2 rule)
    $osLang = "$($Os.language.tag)"
    if (-not $osLang) {
      # The language ladder failed on every rung. That is an UNMEASURED check, not a
      # mismatch: emitting "Language mismatch ... requires media in ('')" refused correct
      # media because FrameForge could not read the system's language.
      $checks += [ordered]@{ check = 'language'; pass = $null; detail = "The system default UI language could not be determined (language.source: '$($Os.language.source)'), so the strict 22H2 language rule could not be evaluated. Media languages: $(if ($selected.languages.Count) { $selected.languages -join ', ' } else { '(none listed)' })." }
      $undetermined += "The system default UI language could not be determined, so the Windows 11 22H2 rule that the media must match it exactly could NOT be evaluated. This is not a mismatch - it is an unmeasured check. Check the media language by hand against this PC's Windows display language before continuing."
    } else {
      $langPass = (@($selected.languages | Where-Object { $_ -ieq $osLang }).Count -gt 0)
      $checks += [ordered]@{ check = 'language'; pass = $langPass; detail = "System default UI language: '$osLang' (source: $($Os.language.source)); media languages: $(if ($selected.languages.Count) { $selected.languages -join ', ' } else { '(none listed)' })." }
      if (-not $langPass) {
        $reasons += "Language mismatch: since Windows 11 22H2 a repair install strictly requires media in the system default UI language ('$osLang'). Even en-US vs en-GB fails - setup exits silently (0xC1900204). Get media in '$osLang'."
      }
    }

    # 3. Architecture
    if ($Os.architecture -eq 'unknown' -or $null -eq $selected.architecture) {
      $checks += [ordered]@{ check = 'architecture'; pass = $null; detail = "OS: $($Os.architecture) (source: $($Os.architectureSource)); media: $(if ($selected.architecture) { $selected.architecture } else { 'unreadable' })." }
      $undetermined += "The architecture rule could not be evaluated: $(if ($Os.architecture -eq 'unknown') { "this PC's own architecture could not be determined" } else { 'the media does not report an architecture' })."
    } else {
      $archPass = ($selected.architecture -eq $Os.architecture)
      $checks += [ordered]@{ check = 'architecture'; pass = $archPass; detail = "OS: $($Os.architecture) (source: $($Os.architectureSource)); media: $($selected.architecture)." }
      if (-not $archPass) { $reasons += "Architecture mismatch: $($Os.architecture) OS vs $($selected.architecture) media." }
    }

    # 4. Build: same-or-newer
    if ($null -ne $selected.build -and $null -ne $Os.currentBuild) {
      if ($selected.build -lt $Os.currentBuild) {
        $checks += [ordered]@{ check = 'build'; pass = $false; detail = "Media build $($selected.build) is OLDER than installed build $($Os.currentBuild)." }
        $reasons += "Build too old: media is build $($selected.build), the OS is $($Os.currentBuild). You cannot repair-downgrade, and an older image is also useless as a DISM /Source (payload mismatch, 0x800f081f). Honestly: this ISO cannot help this machine - get current media."
      } elseif ($selected.build -gt $Os.currentBuild) {
        # Same generation (rule 0 already refused a cross-generation run), newer build:
        # this is a FEATURE UPDATE. Apps and files survive, but the Windows version
        # changes - which is not the action the repair consent contract describes.
        $isFeatureUpdate = $true
        $checks += [ordered]@{ check = 'build'; pass = $true; detail = "Media build $($selected.build) is newer than installed $($Os.currentBuild) - this is a feature update, not a same-build repair." }
        if ($AllowFeatureUpdate) {
          $notes += "FEATURE UPDATE EXPLICITLY ALLOWED (-AllowFeatureUpdate): your Windows version WILL CHANGE from $($Os.displayVersion) (build $($Os.currentBuild)) to build $($selected.build). Setup runs this as a feature update rather than a pure same-build repair; apps and files are still kept, and the consent contract states the version change."
        } else {
          $reasons += "This media is NEWER than the installed build ($($selected.build) vs $($Os.currentBuild)), so running it in place is a FEATURE UPDATE - your Windows version changes from $($Os.displayVersion) to build $($selected.build) - not the same-version repair this flow's consent contract describes. FrameForge refuses it by default. Either get media for the installed release ($($Os.displayVersion), build $($Os.currentBuild)), or, if a version change is genuinely what you want, re-run with -AllowFeatureUpdate and accept the version-change consent contract."
        }
      } else {
        $isFeatureUpdate = $false
        $checks += [ordered]@{ check = 'build'; pass = $true; detail = "Media and OS are both build $($selected.build)." }
        if ($null -ne $selected.ubr -and $null -ne $Os.ubr -and $selected.ubr -lt $Os.ubr) {
          $notes += "The OS has a newer cumulative update ($($Os.currentBuild).$($Os.ubr)) than the media ($($selected.build).$($selected.ubr)). Fine for the in-place repair, but as a DISM /Source it may fail with 0x800f081f - if that happens, use plain /RestoreHealth (Windows Update source) instead."
        }
      }
    } elseif ($null -eq $Os.currentBuild) {
      # Tell the two null cases apart. Blaming the media for an unreadable OS build sent
      # users hunting for different media while their ISO was fine.
      $checks += [ordered]@{ check = 'build'; pass = $null; detail = 'The INSTALLED build number could not be read (registry CurrentBuildNumber and Win32_OperatingSystem.BuildNumber both failed).' }
      $undetermined += "This PC's own build number could not be determined, so the same-or-newer rule could NOT be checked. The media is not at fault."
    } else {
      $checks += [ordered]@{ check = 'build'; pass = $null; detail = 'The MEDIA build could not be read from the image metadata.' }
      $undetermined += 'The media build could not be determined, so the same-or-newer rule could NOT be checked.'
    }
  } elseif ($null -ne $selected -and $null -ne $selected.detailError) {
    $undetermined += "The matching image's metadata could not be read, so none of the matching rules could be evaluated: $($selected.detailError)"
  }

  $determined = ($undetermined.Count -eq 0)
  $compatible = ($reasons.Count -eq 0 -and $determined)
  if (-not $determined) {
    $notes += 'One or more matching rules could not be EVALUATED (see undetermined[]). compatible:false here means "not proven compatible", not "proven incompatible" - FrameForge will not claim a mismatch it did not measure, and will not run a repair on an unproven match either.'
  }
  $selIdx = $null; if ($null -ne $selected) { $selIdx = $selected.index }
  [ordered]@{
    determined    = $determined   # were ALL the rules actually evaluated?
    compatible    = $compatible
    # reasons[] carries both measured failures and unevaluated rules, because it is what
    # the UI renders as "why this is not a green light"; undetermined[] is the subset that
    # was never measured, and checks[] carries pass:$null for exactly those.
    reasons       = @($reasons + $undetermined)
    failures      = @($reasons)
    undetermined  = @($undetermined)
    checks        = $checks
    notes         = $notes
    selectedIndex = $selIdx
    imageInfo     = $selected
    isFeatureUpdate      = $isFeatureUpdate
    featureUpdateAllowed = [bool]$AllowFeatureUpdate
  }
}

# ---------------- Fido helpers (acquire-url) ----------------

# Fido's -Lang wants Microsoft's display names, not BCP-47 tags. Full map of the
# languages Microsoft offers the consumer Win11 ISO in.
$FidoLangMap = @{
  'ar-SA' = 'Arabic';        'pt-BR' = 'Brazilian Portuguese'; 'bg-BG' = 'Bulgarian'
  'zh-CN' = 'Chinese Simplified'; 'zh-TW' = 'Chinese Traditional'; 'hr-HR' = 'Croatian'
  'cs-CZ' = 'Czech';         'da-DK' = 'Danish';          'nl-NL' = 'Dutch'
  'en-US' = 'English';       'en-GB' = 'English International'; 'et-EE' = 'Estonian'
  'fi-FI' = 'Finnish';       'fr-FR' = 'French';          'fr-CA' = 'French Canadian'
  'de-DE' = 'German';        'el-GR' = 'Greek';           'he-IL' = 'Hebrew'
  'hu-HU' = 'Hungarian';     'it-IT' = 'Italian';         'ja-JP' = 'Japanese'
  'ko-KR' = 'Korean';        'lv-LV' = 'Latvian';         'lt-LT' = 'Lithuanian'
  'nb-NO' = 'Norwegian';     'pl-PL' = 'Polish';          'pt-PT' = 'Portuguese'
  'ro-RO' = 'Romanian';      'ru-RU' = 'Russian';         'sr-Latn-RS' = 'Serbian Latin'
  'sk-SK' = 'Slovak';        'sl-SI' = 'Slovenian';       'es-ES' = 'Spanish'
  'es-MX' = 'Spanish (Mexico)'; 'sv-SE' = 'Swedish';      'th-TH' = 'Thai'
  'tr-TR' = 'Turkish';       'uk-UA' = 'Ukrainian'
}

# EditionID -> which acquisition channel can actually produce media for it. An explicit
# TABLE, not a regex: the old switch had arms for ProfessionalEducation and
# ProfessionalWorkstation but not for their N spellings, so a Pro-for-Workstations-N user
# fell into the default arm and was told - falsely - that their edition needs media "from
# your license channel". Anything not in either table is UNRECOGNISED, which is a
# different, honest answer from "volume licence only".
$FidoEditionMap = [ordered]@{
  'Core'                    = 'Pro'   # consumer multi-edition ISO; setup picks the edition by channel/key
  'CoreN'                   = 'Pro'
  'CoreSingleLanguage'      = 'Pro'
  'CoreCountrySpecific'     = 'Pro'
  'Professional'            = 'Pro'
  'ProfessionalN'           = 'Pro'
  'ProfessionalEducation'   = 'Pro'
  'ProfessionalEducationN'  = 'Pro'
  'ProfessionalWorkstation' = 'Pro'
  'ProfessionalWorkstationN'= 'Pro'
  'Education'               = 'Pro'
  'EducationN'              = 'Pro'
}
# Editions distributed only through a licensing channel. LTSC (EnterpriseS/SN) has its own.
$FFVolumeLicenseEditions = @(
  'Enterprise','EnterpriseN','EnterpriseS','EnterpriseSN','EnterpriseG','EnterpriseGN',
  'IoTEnterprise','IoTEnterpriseS','IoTEnterpriseK','ServerRdsh','CloudEdition','CloudEditionN'
)

function Get-FFEditionChannel {
  <#
    Which acquisition channel covers this EditionID.
      consumer        -> the multi-edition retail ISO (Fido can fetch it; MCT can build it)
      volume-license  -> Enterprise/LTSC/IoT/Cloud: their own channel, named honestly
      unrecognised    -> FrameForge does not know this EditionID and will NOT guess which
                         ISO matches it, nor claim anything about its licence channel
    Returns @{ editionId; channel; fidoEdition; licenseChannels[]; note }.
  #>
  param([string]$EditionId)
  $id = "$EditionId".Trim()
  $out = [ordered]@{ editionId = $id; channel = 'unrecognised'; fidoEdition = $null; licenseChannels = @(); note = $null }
  if (-not $id) {
    $out.note = 'The installed EditionID could not be read, so no acquisition channel can be chosen for it.'
    return $out
  }
  if ($FidoEditionMap.Contains($id)) {
    $out.channel = 'consumer'
    $out.fidoEdition = $FidoEditionMap[$id]
    $out.note = "'$id' is carried by the consumer multi-edition ISO."
    return $out
  }
  if ($FFVolumeLicenseEditions -contains $id) {
    $out.channel = 'volume-license'
    if ($id -eq 'EnterpriseS' -or $id -eq 'EnterpriseSN') {
      $out.licenseChannels = @('The LTSC channel specifically (Volume Licensing Service Center / Microsoft 365 admin center -> Windows 11 Enterprise LTSC)', 'Visual Studio subscriptions, where the LTSC ISO is published')
    } else {
      $out.licenseChannels = @('Microsoft 365 admin center (Volume Licensing)', 'Volume Licensing Service Center (VLSC)', 'Azure Marketplace / Visual Studio subscriptions')
    }
    $out.note = "'$id' is not offered through the consumer download channels; it comes from its own licensing channel."
    return $out
  }
  $out.note = "FrameForge does not recognise the installed edition '$id'."
  $out
}

function Get-FFFidoEdition {
  <# Fido's -Ed value for this EditionID, or $null when no consumer ISO covers it. #>
  param([string]$EditionId)
  (Get-FFEditionChannel -EditionId $EditionId).fidoEdition
}

function Get-FFMctEdition {
  <#
    The /MediaEdition token for the Media Creation Tool, derived from the actual EditionID
    with the N suffix PRESERVED. The old code sent every non-Core edition to 'Professional',
    so an EducationN or ProfessionalN user was handed a command that builds media whose
    edition string this very file then refuses on the exact-match rule.
    $null means MCT cannot build media for this edition at all.
  #>
  param([string]$EditionId)
  switch ("$EditionId") {
    'Core'                     { return 'Home' }
    'CoreN'                    { return 'Home N' }
    'CoreSingleLanguage'       { return 'Home Single Language' }
    'CoreCountrySpecific'      { return 'Home' }
    'Professional'             { return 'Professional' }
    'ProfessionalN'            { return 'Professional N' }
    'ProfessionalEducation'    { return 'Professional Education' }
    'ProfessionalEducationN'   { return 'Professional Education N' }
    'ProfessionalWorkstation'  { return 'Professional Workstation' }
    'ProfessionalWorkstationN' { return 'Professional Workstation N' }
    'Education'                { return 'Education' }
    'EducationN'               { return 'Education N' }
  }
  $null
}

function Get-FFFallbackLadder {
  <#
    The remaining rungs, spelled out for the UI whenever Fido cannot deliver. Every rung
    is derived from THIS machine (edition with its N suffix, real OS architecture,
    generation), because a rung that hands the user a command producing media FrameForge
    itself would then refuse is worse than no rung at all:
      - MCT builds consumer editions only, and only for x64/x86 - never ARM64, never
        Enterprise/LTSC/IoT. Where it cannot deliver, the rung is replaced with the
        channel that can, and mctUnavailable says why.
      - The manual rung names the actual architecture and the exact edition string the
        media must carry, since image.ps1 enforces an exact EditionID match.
    Keys are stable (mct / mctUnavailable / volumeLicense / manual); the ones that do not
    apply are null rather than absent.
  #>
  param([string]$LangCode, [string]$Edition, [string]$Arch = 'x64', [string]$Generation = 'win11')
  $chan = Get-FFEditionChannel -EditionId $Edition
  $mediaEdition = Get-FFMctEdition -EditionId $Edition
  $archToken = $(if ($Arch -and $Arch -ne 'unknown') { $Arch } else { 'x64' })
  $productWord = $(if ($Generation -eq 'win10') { 'Windows 10' } else { 'Windows 11' })
  $manualUrl = $(if ($Generation -eq 'win10') { $ManualDownloadUrlWin10 } else { $ManualDownloadUrl })
  $langNote = $(if ($LangCode) { "the SYSTEM DEFAULT UI LANGUAGE ('$LangCode')" } else { 'the system default UI language (which FrameForge could not read here - check it in Settings > Time & language > Language & region, "Windows display language")' })
  $editionNote = $(if ($chan.editionId) { "The media must contain the '$($chan.editionId)' edition exactly - image.ps1 enforces an exact EditionID match and refuses anything else." } else { 'The installed EditionID could not be read, so the media edition must be checked by hand.' })

  $mct = $null; $mctUnavailable = $null; $volumeLicense = $null
  if ($archToken -eq 'arm64') {
    $mctUnavailable = [ordered]@{
      what = 'The Media Creation Tool rung does not apply to this machine.'
      why  = 'This is an ARM64 Windows install, and the Media Creation Tool does not produce ARM64 media at all. Following an MCT command here would build x64 media that this engine then refuses on the architecture rule.'
      instead = "Download the ARM64 $productWord ISO from Microsoft's download page (the manual rung below)."
    }
  } elseif ($chan.channel -eq 'volume-license') {
    $mctUnavailable = [ordered]@{
      what = 'The Media Creation Tool rung does not apply to this machine.'
      why  = "The Media Creation Tool builds consumer editions only; it cannot produce '$($chan.editionId)' media. Following an MCT command here would build media that this engine then refuses on the edition rule."
      instead = 'Use the licensing channel below.'
    }
  } elseif ($null -eq $mediaEdition) {
    $mctUnavailable = [ordered]@{
      what = 'The Media Creation Tool rung is not offered for this machine.'
      why  = "FrameForge does not recognise the installed edition '$($chan.editionId)', so it will not guess a /MediaEdition token for it."
      instead = 'Use the manual rung and pick media whose edition string matches exactly.'
    }
  } else {
    $mct = [ordered]@{
      what    = 'Microsoft Media Creation Tool (first-party; uses the ESD delivery channel, never IP-banned).'
      command = "MediaCreationTool.exe /Eula Accept /Retail /MediaArch $archToken /MediaLangCode $LangCode /MediaEdition `"$mediaEdition`""
      mediaEdition = $mediaEdition
      mediaArch    = $archToken
      note    = "Semi-automated: the wizard UI still appears with choices pre-populated; /Eula Accept accepts the MCT EULA on the user's behalf - surface that first. Output media carries install.esd. $editionNote If the tool rejects the /MediaEdition token, drop that switch and pick the edition in the wizard - the token is a convenience, the exact edition string in the resulting media is the requirement."
    }
  }
  if ($chan.channel -eq 'volume-license') {
    $volumeLicense = [ordered]@{
      what     = "'$($chan.editionId)' media comes from your licensing channel, not from a consumer download page."
      channels = $chan.licenseChannels
      note     = "$editionNote Do not substitute a consumer ISO: the edition string will not match and Windows Setup exits without repairing anything."
    }
  }
  [ordered]@{
    mct            = $mct
    mctUnavailable = $mctUnavailable
    volumeLicense  = $volumeLicense
    manual = [ordered]@{
      what = 'Official Microsoft download page in the default browser + "I already have an ISO" file picker.'
      url  = $manualUrl
      note = "Choose the $productWord multi-edition ISO for $archToken devices in $langNote, then verify SHA-256 against the hash list published on that page. $editionNote"
    }
  }
}

function Invoke-FFProcess {
  <#
    Runs a command out-of-process with redirected stdout/stderr and a hard
    timeout. Async reads avoid the classic redirected-pipe deadlock.
    Returns @{ exitCode; stdout; stderr; timedOut }.
  #>
  param([string]$FilePath, [string]$Arguments, [int]$TimeoutSec = 300)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { $p.Kill() } catch {}
    try { $null = $p.WaitForExit(5000) } catch {}
  }
  $stdout = ''; $stderr = ''
  try { $stdout = $outTask.Result } catch {}
  try { $stderr = $errTask.Result } catch {}
  $code = $null
  try { $code = $p.ExitCode } catch {}
  [ordered]@{ exitCode = $code; stdout = $stdout; stderr = $stderr; timedOut = $timedOut }
}

# ---------------- setup.exe exit-code translation ----------------

function Convert-FFSetupExitCode {
  param($Code)
  $hex = $null
  # NB: the literal 0xFFFFFFFF parses as int32 -1 in PowerShell, which would make
  # the mask a no-op and print negative codes as 16 hex digits - use the decimal
  # int64 literal instead.
  try { $hex = '0x{0:X8}' -f ([int64]$Code -band [int64]4294967295) } catch { $hex = "$Code" }
  $known = @{
    '0xC1900210' = @('clean',    'Compatibility scan found no issues - green light for the in-place repair.')
    '0xC1900208' = @('blocked',  'Compatibility issues found (hard block). Parse the compat XML in C:\$WINDOWS.~BT\Sources\Panther for the named blocker.')
    '0xC190010E' = @('error',    'EULA was not accepted in unattended context (MOSETUP_E_EULA_ACCEPT_REQUIRED).')
    '0xC1900107' = @('blocked',  'A previous setup attempt is pending cleanup/reboot - restart the PC, then retry.')
    '0xC190020E' = @('blocked',  'Insufficient disk space on the system drive.')
    '0x80070070' = @('blocked',  'Insufficient disk space (ERROR_DISK_FULL).')
    '0xC1900204' = @('blocked',  'Install choice unavailable (MOSETUP_E_COMPAT_INSTALLREQ_BLOCK) - typically an edition or language mismatch between media and OS.')
    '0xC1900101' = @('rollback', 'Generic rollback - almost always a driver/filter-driver crash during a boot phase. Run SetupDiag against the Panther logs; common culprits are AV filter drivers, storage drivers, old AIB utilities.')
    '0x00000000' = @('success',  'Setup reported success.')
  }
  if ($known.ContainsKey($hex)) {
    return [ordered]@{ exitCode = $Code; hex = $hex; verdict = $known[$hex][0]; meaning = $known[$hex][1] }
  }
  [ordered]@{ exitCode = $Code; hex = $hex; verdict = 'unknown'; meaning = "Unrecognized setup exit code $hex - check C:\`$WINDOWS.~BT\Sources\Panther\setupact.log / setuperr.log and run SetupDiag." }
}

# ---------------- ledger ----------------

$script:StateMigration = $null

function Initialize-FFStateDir {
  <#
    Makes %LOCALAPPDATA%\FrameForge\state usable and, ONCE, copies a v1 launch ledger and Fido copy
    that were written into the install tree. COPY, never move: the in-tree files are left exactly as
    they were found, so a half-finished migration cannot lose the only record of a launch.
    Returns @{ ok; stateDir; error; migrated; migratedFrom; note }.
  #>
  if ($null -ne $script:StateMigration) { return $script:StateMigration }
  $res = [ordered]@{ ok = $false; stateDir = $StateDir; error = $null; migrated = $false; migratedFrom = $null; note = $null }
  try {
    # New-Item has no -LiteralPath in PS 5.1, and does not need one: measured, `New-Item -ItemType
    # Directory -Force -Path "<...>\a [b] c"` succeeds. It is Get-Content -Raw / Set-Content
    # -Encoding whose FileSystem DYNAMIC parameters disappear on an unresolvable wildcard -Path.
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop | Out-Null }
    $res.ok = $true
  } catch {
    $res.error = ("FrameForge could not create or reach its state folder at '$StateDir': $($_.Exception.Message). " +
                  "The launch ledger lives there, and without it 'verify' has nothing to compare a post-upgrade machine against. " +
                  'Check that %LOCALAPPDATA% is writable (Controlled Folder Access and some roaming-profile policies block it).')
    $script:StateMigration = $res
    return $res
  }
  try {
    if ((Test-Path -LiteralPath $LegacyLedger -PathType Leaf) -and -not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
      Copy-Item -LiteralPath $LegacyLedger -Destination $LedgerPath -Force -ErrorAction Stop
      $res.migrated = $true
      $res.migratedFrom = $LegacyLedger
      $res.note = "A v1 image-repair ledger was found in the install tree and COPIED to '$LedgerPath'. The original was left in place on purpose."
    }
  } catch { $res.note = "A v1 image-repair ledger at '$LegacyLedger' could NOT be copied: $($_.Exception.Message). It is still readable where it is." }
  try {
    if ((Test-Path -LiteralPath $LegacyToolsDir -PathType Container) -and -not (Test-Path -LiteralPath $ToolsDir -PathType Container)) {
      Copy-Item -LiteralPath $LegacyToolsDir -Destination $ToolsDir -Recurse -Force -ErrorAction Stop
    }
  } catch {}
  $script:StateMigration = $res
  return $res
}

function Get-FFLedgerState {
  <#
    The launch ledger WITH its read outcome attached.

    DOCTRINE BUG this replaces: Read-FFLedger swallowed every read failure and returned @(), and
    'verify' then rendered verdict 'no-ledger' - "either nothing was launched through FrameForge, or
    the ledger was cleared" - for a file that was sitting right there and simply could not be read.
    An unreadable ledger is not an absent one, and only one of those two is a statement this tool is
    entitled to make.

    Returns @{ readable; entries; count; path; source; error; migration }.
  #>
  $mig = Initialize-FFStateDir
  $out = [ordered]@{ readable = $false; entries = $null; count = $null; path = $LedgerPath; source = $null; error = $null; migration = $mig }
  $read = $LedgerPath; $src = 'state-dir'
  if (-not (Test-Path -LiteralPath $read -PathType Leaf)) {
    if (Test-Path -LiteralPath $LegacyLedger -PathType Leaf) { $read = $LegacyLedger; $src = 'legacy-install-tree' }
    else { $out.readable = $true; $out.entries = @(); $out.count = 0; $out.source = 'absent'; return $out }
  }
  $out.path = $read; $out.source = $src
  $raw = $null
  try { $raw = Get-Content -LiteralPath $read -Raw -ErrorAction Stop }
  catch { $out.error = "The image-repair ledger at '$read' exists but could not be READ: $($_.Exception.Message)"; return $out }
  if ($null -eq $raw -or -not ("$raw".Trim())) {
    $out.error = "The image-repair ledger at '$read' is empty (0 bytes) - a truncated or interrupted write, not a record that nothing was launched."
    return $out
  }
  $doc = $null
  try { $doc = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
  catch { $out.error = "The image-repair ledger at '$read' could not be parsed as JSON: $($_.Exception.Message). There IS content in it, so this must not be read as 'nothing was launched'."; return $out }
  if ($null -eq $doc) { $out.readable = $true; $out.entries = @(); $out.count = 0; return $out }
  $out.readable = $true
  $out.entries = @($doc)
  $out.count = @($doc).Count
  return $out
}

function Read-FFLedger {
  <# Entries only. Callers that must tell "unreadable" from "empty" use Get-FFLedgerState. #>
  $s = Get-FFLedgerState
  if (-not $s.readable) { return @() }
  return @($s.entries)
}

function Write-FFLedger {
  param($Entries)
  try {
    $mig = Initialize-FFStateDir
    if (-not $mig.ok) { return $false }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 8
    [System.IO.File]::WriteAllText($LedgerPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $true
  } catch { return $false }
}

# ---------------- shared assembly for media-based actions ----------------

function Get-FFMediaVerdict {
  <#
    Resolve media -> inventory -> verdict, with every failure mode structured.
    Returns @{ ok; errorCode; error; media; inventory; verdict; needsAdmin }.
    Caller must Complete-FFMedia on .media when non-null.
  #>
  param([string]$Iso, [string]$Source, [int]$ForceIndex, $Os, [switch]$AllowFeatureUpdate)
  $res = [ordered]@{ ok = $false; errorCode = $null; error = $null; media = $null; inventory = @(); verdict = $null; needsAdmin = $false; rawError = $null }
  $media = Resolve-FFMedia -Iso $Iso -Source $Source
  $res.media = $media
  if (-not $media.ok) {
    $res.errorCode = $media.errorCode
    $res.error = $media.error
    return $res
  }
  try {
    $res.inventory = @(Get-FFMediaInventory -ImageFile $media.imageFile)
  } catch {
    # Classify by TYPE and CODE, never by the message text: a localized "Zugriff verweigert"
    # never matched 'denied', so an access-denied inventory read was reported as
    # "Could not read the install image inventory" - telling the user their ISO is broken
    # when the real answer was "re-run elevated". The raw message stays as evidence only.
    $msg = "$($_.Exception.Message)"
    $res.rawError = $msg
    $denied = Test-FFAccessDenied $_
    if ($denied.denied) {
      $res.needsAdmin = $true
      $res.errorCode = 'inventory-needs-admin'
      $res.error = "Reading the install image inventory was denied (access denial detected via $($denied.via)) - it requires administrator rights. Re-run elevated. The media itself has not been judged."
    } elseif (-not $IsAdmin) {
      # Get-WindowsImage against install media genuinely requires elevation, so an
      # unelevated failure is needs-admin by default rather than a verdict on the media.
      $res.needsAdmin = $true
      $res.errorCode = 'inventory-needs-admin'
      $res.error = "The install image inventory could not be read while running WITHOUT administrator rights, which is what Get-WindowsImage against install media requires - so that is the most likely cause and FrameForge is NOT claiming your media is broken. Re-run elevated; if it still fails, the underlying error was: $msg"
    } else {
      $res.errorCode = 'inventory-failed'
      $res.error = "Could not read the install image inventory: $msg"
    }
    return $res
  }
  if (@($res.inventory).Count -eq 0) {
    $res.errorCode = 'inventory-empty'
    $res.error = 'The install image contains no images.'
    return $res
  }
  $res.verdict = Compare-FFMediaToOs -Os $Os -Rows $res.inventory -ForceIndex $ForceIndex -AllowFeatureUpdate:$AllowFeatureUpdate
  $res.ok = $true
  $res
}

function New-FFUndeterminedVerdict {
  <#
    A verdict object for the case where the media inventory could not be read at all.
    Previously the callers emitted verdict:null while still reporting ok:true, so any
    consumer reading verdict.compatible null-referenced. The shape is now always the
    same shape; 'determined' says whether the rules were actually evaluated.
  #>
  param([string]$Reason)
  [ordered]@{
    determined    = $false
    compatible    = $false
    reasons       = @($Reason)
    failures      = @()
    undetermined  = @($Reason)
    checks        = @()
    notes         = @('The media could not be inventoried, so the generation/edition/language/architecture/build rules were never evaluated. compatible:false here means "not proven compatible", not "proven incompatible".')
    selectedIndex = $null
    imageInfo     = $null
    isFeatureUpdate      = $null
    featureUpdateAllowed = $false
  }
}

function New-FFConsentContract {
  <#
    The honest consent copy the UI must show BEFORE anything passes /eula accept.
    Two commands do: preflight's '/compat scanonly' dress rehearsal and launch's
    '/auto upgrade'. Both are gated (-AcceptEula, -Confirm). The previous wording
    promised nothing would pass /eula accept until this checkbox, while preflight - the
    step BEFORE this one in the documented flow - passed it with no gate at all.

    The contract is no longer static text. When the media is a NEWER build than the
    installed one, the run is a feature update and the user's Windows version changes -
    an action the old fixed wording never mentioned while still calling itself the
    consent gate (doctrine rule 4). Pass the media verdict and the OS identity and the
    version change is stated first, with isFeatureUpdate:$true so the UI can require a
    second, distinctly worded acceptance. $Verdict may be $null (the plain 'consent'
    action reads no media): then isFeatureUpdate is $null - unknown, and said so - never
    a quiet $false.
  #>
  param($Verdict, $Os)
  $mediaBuild = $null
  $isFeatureUpdate = $null
  $versionChange = $null
  if ($null -ne $Verdict) {
    $isFeatureUpdate = Get-FFProp $Verdict 'isFeatureUpdate'
    $imageInfo = Get-FFProp $Verdict 'imageInfo'
    if ($null -ne $imageInfo) { $mediaBuild = Get-FFProp $imageInfo 'build' }
  }
  $osBuild = $null; $osDisplay = $null
  if ($null -ne $Os) { $osBuild = Get-FFProp $Os 'currentBuild'; $osDisplay = Get-FFProp $Os 'displayVersion' }
  $whatIsReset = @(
    'All system binaries and the component store (the point of the repair)',
    'Some defaults (default apps can reset)',
    'Custom services / patched system files',
    'Third-party shell extensions may need repair or reinstall'
  )
  if ($isFeatureUpdate -eq $true) {
    $versionChange = [ordered]@{
      fromDisplayVersion = "$osDisplay"
      fromBuild          = $osBuild
      toBuild            = $mediaBuild
      note               = "This media is build $mediaBuild; this PC is on $osDisplay (build $osBuild). Windows Setup will run this as a FEATURE UPDATE."
    }
    $whatIsReset = @(
      "YOUR WINDOWS VERSION WILL CHANGE: from $osDisplay (build $osBuild) to build $mediaBuild. This is a FEATURE UPDATE, not a same-version repair.",
      'Feature-update-era policy defaults: a feature update re-runs the OOBE-era default settings pass, so some privacy/telemetry/default-app choices can be reset to the new version''s defaults.',
      'The rollback window is the feature update''s: "Go back" returns you to the OLD Windows version, not to a freshly repaired copy of the current one.'
    ) + $whatIsReset
  }
  [ordered]@{
    # Tri-state on purpose: $true feature update, $false same-version repair, $null the
    # media has not been read yet at this step.
    isFeatureUpdate  = $isFeatureUpdate
    versionChange    = $versionChange
    requiresSecondConsent = ($isFeatureUpdate -eq $true)
    versionNote      = $(if ($isFeatureUpdate -eq $true) {
        "This run CHANGES your Windows version (from $osDisplay / build $osBuild to build $mediaBuild). The repair consent below is not enough on its own: a version change must be accepted separately, and 'launch' refuses this media unless -AllowFeatureUpdate is passed."
      } elseif ($isFeatureUpdate -eq $false) {
        'This run is a same-version repair: the media is the same build as the installed Windows, so your Windows version does not change.'
      } else {
        'Whether this run is a same-version repair or a feature update is NOT known at this step, because no media has been read yet. Run validate/pre-flight with the actual ISO - the contract returned there states it.'
      })
    eulaConsentCoversTwoCommands = @(
      'Pre-flight compatibility scan:  setup.exe /auto upgrade /quiet /eula accept /compat scanonly /noreboot',
      'The repair itself:              setup.exe /auto upgrade /eula accept ... /noreboot'
    )
    eulaNote         = 'BOTH the pre-flight compatibility scan and the repair itself pass /eula accept to Windows Setup, because the scan IS Windows Setup running its own dress rehearsal and it will not run unattended without that switch. Accepting here means accepting the Microsoft Software License Terms for this Windows version. FrameForge does not accept them for you: the scan runs only with -AcceptEula and the repair only with -Confirm, and neither switch is passed unless you consent in the UI first.'
    whenAcceptanceHappens = 'At the pre-flight step - one step earlier than the launch button. That is why consent is collected before pre-flight, not after it.'
    whatIsPreserved  = @(
      'User accounts and profiles',
      'Personal files',
      'Installed Win32 and Store apps',
      'Most settings and drivers (/migratedrivers all)',
      'Windows activation'
    )
    whatIsReset      = $whatIsReset
    durationEstimate = $(if ($isFeatureUpdate -eq $true) { '30-90 minutes on modern NVMe hardware; the down-level phase is 10-30 minutes. A feature update is usually at the longer end.' } else { '30-90 minutes on modern NVMe hardware; the down-level phase is 10-30 minutes.' })
    rebootCount      = '2-3 restarts. /noreboot suppresses only the FIRST one - you choose when to restart; later restarts happen automatically.'
    rollbackNote     = 'A failed upgrade rolls back automatically. The previous OS is kept in C:\Windows.old with "Go back" available for ~10 days, then auto-cleaned.'
    bitlockerNote    = 'Setup normally keeps or auto-suspends BitLocker, but a recovery-key prompt after reboot is possible (TPM+PIN, firmware changes). Confirm you can access your recovery key first: https://aka.ms/myrecoverykey'
  }
}

# ---------------- SetupDiag results (verify) ----------------

function Get-FFSetupDiagNames {
  <#
    Pull the concrete nouns out of SetupDiag's free-text failure data: driver binaries,
    device instance paths, and the setup error codes. This is the bit the user actually
    acts on - "0xC1900101 during SYSPREP" is not a fix, "iaStorAC.sys" is.
  #>
  param([string]$Text)
  $out = [ordered]@{ drivers = @(); devices = @(); errorCodes = @(); extendedCodes = @() }
  if (-not $Text) { return $out }
  $drv = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b([A-Za-z0-9_\-\.]{1,64}\.(?:sys|dll|exe))\b')) { $drv += $m.Groups[1].Value }
  # setup's own binaries are noise, not the culprit
  $noise = @('setup.exe','setuphost.exe','setupplatform.exe','setupplatform.dll','windows.exe','poqexec.exe')
  $out.drivers = @($drv | Where-Object { $noise -notcontains "$_".ToLowerInvariant() } | Select-Object -Unique | Select-Object -First 10)
  $dev = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b((?:PCI|USB|HDAUDIO|ACPI|SCSI|ROOT|SWD|HID)\\[^\s,;"'')]{4,120})')) { $dev += $m.Groups[1].Value }
  $out.devices = @($dev | Select-Object -Unique | Select-Object -First 10)
  $codes = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b(0x[0-9A-F]{4,8})\b')) { $codes += ('0x' + $m.Groups[1].Value.Substring(2).ToUpperInvariant()) }
  $out.errorCodes = @($codes | Select-Object -Unique | Select-Object -First 10)
  # The 0xC1900101 family is only actionable WITH its extended code (0xC1900101 - 0x4000D
  # says which setup phase died), and the extended half is often shorter than 8 digits.
  $ext = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b(0x[0-9A-F]{8})\s*-\s*(0x[0-9A-F]{4,8})\b')) {
    $ext += ('0x' + $m.Groups[1].Value.Substring(2).ToUpperInvariant() + ' - 0x' + $m.Groups[2].Value.Substring(2).ToUpperInvariant())
  }
  $out.extendedCodes = @($ext | Select-Object -Unique | Select-Object -First 10)
  $out
}

function Get-FFSetupDiagResults {
  <#
    Parse what SetupDiag actually wrote, instead of only noting that a file exists.

    verify used to do nothing but Test-Path on SetupDiagResults.xml while the verdict text
    told the user "SetupDiag names the cause" - it did not, and the user was left to open
    the XML themselves. fresh-image-repair.md line 156 and section 6 step 8 both require
    the named cause to be surfaced, so it is read from BOTH places modern setup writes it:
      %WinDir%\Logs\SetupDiag\SetupDiagResults.xml
      HKLM\SYSTEM\Setup\SetupDiag\Results
    The XML schema has changed across SetupDiag versions (a single <SetupDiag> element in
    1.x, a <Results>/<Failure> collection later), so the parse is deliberately
    schema-agnostic: it walks for ProfileName/ProfileGuid/Remediation/FailureData nodes
    wherever they sit. And per the research doc, when several failures are logged the LAST
    one is usually the fatal one - so entries are kept IN ORDER and the last is reported
    as likelyFatal rather than silently averaging them together.
  #>
  param([string]$XmlPath, [string]$RegistryPath = 'HKLM:\SYSTEM\Setup\SetupDiag\Results')
  $res = [ordered]@{
    parsed = $false; source = $null; parseError = $null
    entryCount = 0; entries = @(); likelyFatal = $null
    namedCause = $null; message = $null; remediation = $null
    namedDrivers = @(); namedDevices = @(); errorCodes = @(); extendedCodes = @()
    multipleFailuresNote = $null
    registryValues = $null
  }
  $sources = @()

  # --- XML ---
  $entries = @()
  if ($XmlPath -and (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
    try {
      $doc = New-Object System.Xml.XmlDocument
      $doc.PreserveWhitespace = $false
      $doc.Load($XmlPath)
      # Each element that carries a ProfileName is one logged failure, whatever it is called.
      $hosts = @()
      foreach ($n in @($doc.SelectNodes('//*[local-name()="ProfileName"]'))) {
        if ($null -ne $n.ParentNode) { $hosts += $n.ParentNode }
      }
      if ($hosts.Count -eq 0 -and $null -ne $doc.DocumentElement) { $hosts = @($doc.DocumentElement) }
      foreach ($h in $hosts) {
        $e = [ordered]@{ profileName=$null; profileGuid=$null; remediation=$null; dateTime=$null; version=$null; failureData=@() }
        foreach ($pair in @(
            @{ k='profileName'; x='ProfileName' }, @{ k='profileGuid'; x='ProfileGuid' },
            @{ k='remediation'; x='Remediation' }, @{ k='dateTime'; x='DateTime' },
            @{ k='version';     x='Version' })) {
          $v = $h.SelectSingleNode('.//*[local-name()="' + $pair.x + '"]')
          if ($null -ne $v) { $e[$pair.k] = "$($v.InnerText)".Trim() }
        }
        $fd = @()
        foreach ($s in @($h.SelectNodes('.//*[local-name()="FailureData"]//*[local-name()="string"]'))) { $fd += "$($s.InnerText)".Trim() }
        if ($fd.Count -eq 0) {
          foreach ($s in @($h.SelectNodes('.//*[local-name()="FailureData"]'))) {
            $t = "$($s.InnerText)".Trim()
            if ($t) { $fd += $t }
          }
        }
        $e.failureData = @($fd | Where-Object { "$_" -match '\S' })
        if ($e.profileName -or $e.failureData.Count -gt 0) { $entries += $e }
      }
      if ($entries.Count -gt 0) { $sources += 'xml' }
    } catch { $res.parseError = "SetupDiagResults.xml could not be parsed: $($_.Exception.Message)" }
  }

  # --- registry (setup writes the same verdict here; it survives the XML being cleaned up) ---
  try {
    if (Test-Path -LiteralPath $RegistryPath) {
      $p = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
      $vals = [ordered]@{}
      foreach ($prop in @($p.PSObject.Properties)) {
        if (Test-FFIMatch "$($prop.Name)" '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
        $vals["$($prop.Name)"] = "$($prop.Value)"
      }
      if ($vals.Keys.Count -gt 0) {
        $res.registryValues = $vals
        $sources += 'registry'
        if ($entries.Count -eq 0) {
          $e = [ordered]@{ profileName=$null; profileGuid=$null; remediation=$null; dateTime=$null; version=$null; failureData=@() }
          foreach ($k in @($vals.Keys)) {
            switch -Regex ($k) {
              '^ProfileName$'  { $e.profileName = $vals[$k] }
              '^ProfileGuid$'  { $e.profileGuid = $vals[$k] }
              '^Remediation$'  { $e.remediation = $vals[$k] }
              '^DateTime$'     { $e.dateTime = $vals[$k] }
              '^(SetupDiag)?Version$' { $e.version = $vals[$k] }
              '^FailureData'   { $e.failureData += $vals[$k] }
              default { }
            }
          }
          if ($e.profileName -or $e.failureData.Count -gt 0) { $entries += $e }
        }
      }
    }
  } catch {}

  if ($entries.Count -eq 0) {
    if (-not $res.parseError -and $XmlPath -and (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
      $res.parseError = 'SetupDiagResults.xml exists but contained no recognisable failure entry (no ProfileName and no FailureData). Read the file directly.'
    }
    return $res
  }

  # In-order; the LAST logged failure is usually the fatal one (fresh-image-repair.md:156).
  for ($i = 0; $i -lt $entries.Count; $i++) { $entries[$i]['index'] = $i }
  $res.parsed = $true
  $res.source = ($sources | Select-Object -Unique) -join '+'
  $res.entryCount = $entries.Count
  $res.entries = @($entries)
  $fatal = $entries[$entries.Count - 1]
  $res.likelyFatal = $fatal
  $res.namedCause = $fatal.profileName
  $res.message = (@($fatal.failureData) -join ' ')
  $res.remediation = $fatal.remediation
  $named = Get-FFSetupDiagNames -Text ("$($fatal.profileName) $($res.message) $($fatal.remediation)")
  $res.namedDrivers = @($named.drivers)
  $res.namedDevices = @($named.devices)
  $res.errorCodes = @($named.errorCodes)
  $res.extendedCodes = @($named.extendedCodes)
  if ($entries.Count -gt 1) {
    $res.multipleFailuresNote = "SetupDiag logged $($entries.Count) failures. They are listed in order in entries[]; the LAST one is reported as likelyFatal because with multiple failures logged the last is usually the one that actually stopped setup. The earlier ones are often consequences of it, so read them as context, not as separate problems to chase."
  }
  $res
}

function Get-FFSetupDiagSentence {
  <# One human sentence naming the cause, for appending to the verdict text. #>
  param($Parsed)
  if ($null -eq $Parsed) { return $null }
  if (-not $Parsed.parsed) {
    if ($Parsed.parseError) { return "SetupDiag results are present but could not be read: $($Parsed.parseError)" }
    return $null
  }
  $bits = @()
  if ($Parsed.namedCause) { $bits += "SetupDiag names the cause as '$($Parsed.namedCause)'" } else { $bits += 'SetupDiag logged a failure' }
  if (@($Parsed.namedDrivers).Count -gt 0) { $bits += "and points at: $((@($Parsed.namedDrivers)) -join ', ')" }
  elseif (@($Parsed.namedDevices).Count -gt 0) { $bits += "and points at device: $((@($Parsed.namedDevices))[0])" }
  if (@($Parsed.extendedCodes).Count -gt 0) { $bits += "(codes: $((@($Parsed.extendedCodes)) -join ', '))" }
  elseif (@($Parsed.errorCodes).Count -gt 0) { $bits += "(codes: $((@($Parsed.errorCodes)) -join ', '))" }
  $s = ($bits -join ' ') + '.'
  if ($Parsed.remediation) { $s = "$s SetupDiag's suggested remediation: $($Parsed.remediation)" }
  if ($Parsed.entryCount -gt 1) { $s = "$s $($Parsed.multipleFailuresNote)" }
  if (-not $Parsed.namedCause -and $Parsed.message) { $s = "$s Failure data: $($Parsed.message)" }
  $s
}

# ---------------- actions ----------------

$out = $null
$exitCode = 0
$Os = $null

# Application control (WDAC / AppLocker) forces ConstrainedLanguage, where the [Security.Principal]
# identity casts behind Test-Admin, the [xml] cast SetupDiag parsing depends on, and Add-Type in
# _lib.ps1 all throw - so this engine cannot do its job and, worse, could not even say so: it exited
# with empty stdout and the host could only report "the engine returned no output". Emit the same
# single JSON error document health.ps1 emits, from the same shared helper in _lib.ps1 (health owns
# that file; this is the consumer side), and exit 3 - a refusal, not a crash.
if (-not (Test-FFFullLanguage)) {
  Write-FFJson -InputObject (New-FFLanguageModeError) -Depth 6
  exit 3
}

# The whole dispatch is guarded: $ErrorActionPreference is SilentlyContinue here, but a
# TERMINATING error (a bad cast, a missing type, a null method call) still unwinds the
# script - and without this guard it would exit with no JSON at all, breaking the
# one-document contract the Electron host depends on. Every exit path below emits
# exactly one document.
try {
$Os = Get-FFOsIdentity   # every action reasons against the machine identity

$IndexValue = 0
$IndexValid = [int]::TryParse("$Index", [ref]$IndexValue)
if (-not $IndexValid -or $IndexValue -lt 0) { $IndexValid = $false }

# PLATFORM GATE for the three actions that RUN something on the machine.
# health.ps1 attaches supportedOs / unvalidatedPlatform to every document and documents that "the
# mutating engines (repair.ps1 -Action run, image.ps1 preflight/launch/acquire-url) use [it] to
# refuse with errorCode 'unsupported-os'". That refusal did not exist here, so the promise was only
# half kept. These three are the actions that start Windows Setup (preflight's /compat scanonly and
# launch's in-place upgrade) or fetch and execute third-party code (acquire-url's Fido), and
# FrameForge is validated on Windows 11 CLIENT builds only. Doing any of that on a Server SKU, on
# Windows 10, or on a machine whose build could not even be READ is acting on untested ground, and
# an in-place upgrade is the least reversible thing this product can do.
# Deliberately NOT gated, so the user is not left with nothing: detect, consent, validate, download,
# dism-source-repair and verify. The first three and the last are read-only; download writes only to
# a path the caller names; dism-source-repair is a normal DISM RestoreHealth that is supported on
# every build it runs on and is separately admin- and -DryRun-gated. There is no override switch
# here on purpose - unlike repair.ps1, this engine has no -Force, and inventing one for a Windows
# Setup handoff is not a decision to make in a bug-fix round.
$OsSupport = Get-FFOsInfo
$PlatformGatedActions = @('acquire-url','preflight','launch')
$platformRefused = (($PlatformGatedActions -contains $Action) -and (-not $OsSupport.supported))

if ($ValidActions -notcontains $Action) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'unknown-action'; error = "Unknown action '$Action'."; validActions = $ValidActions }
  $exitCode = 2
} elseif (-not $IndexValid) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'bad-index'; error = "-Index must be a non-negative whole number (0 = auto-select by edition) - got '$Index'." }
  $exitCode = 2
} elseif ($platformRefused) {
  $out = [ordered]@{
    ok = $false; action = "$Action"; errorCode = 'unsupported-os'
    error = ("'$Action' was REFUSED on this platform: $($OsSupport.unsupportedReason) " +
             "This action either starts Windows Setup or fetches and runs third-party code, and FrameForge will not do that on a platform whose behaviour nobody here has measured - an in-place upgrade is the least reversible thing this product can do. " +
             "The read-only actions still work and still tell you what they see: detect, consent, validate, verify. dism-source-repair also still works.")
    supportedOs = [bool]$OsSupport.supported
    unvalidatedPlatform = $true
    unsupportedReason = $OsSupport.unsupportedReason
    os = $Os
    platform = [ordered]@{
      build = $OsSupport.buildString; installationType = $OsSupport.installationType
      generation = $OsSupport.generation; caption = $OsSupport.caption
    }
    stillAvailable = @('detect','consent','validate','download','dism-source-repair','verify')
  }
  $exitCode = 3
} else {
switch ($Action) {

  'consent' {
    # Consent BEFORE pre-flight: the UI shows this, the user accepts, and only then may
    # -AcceptEula (pre-flight) and -Confirm (launch) be passed. Read-only - it reports
    # the rails and the exact commands, and starts nothing.
    $rails = Get-FFRails
    $railCheck = Test-FFRailsGreen -Rails $rails
    $setupExe = $null
    if ($IsoPath) { $setupExe = '<mounted ISO>\setup.exe' } elseif ($SourcePath) { $setupExe = (Join-Path $SourcePath 'setup.exe') } else { $setupExe = '<media root>\setup.exe' }
    $out = [ordered]@{
      ok = $true; action = 'consent'; mode = 'consent-contract'; executed = $false
      isAdmin = $IsAdmin
      contract = (New-FFConsentContract -Verdict $null -Os $Os)
      commandsThatRequireThisConsent = [ordered]@{
        preflightCompatScan = "`"$setupExe`" /auto upgrade /quiet /eula accept /compat scanonly /noreboot"
        repairInstall       = "`"$setupExe`" /auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs `"$SetupLogDir`" /noreboot"
      }
      rails = $rails
      railCheck = $railCheck
      howToProceed = 'After the user accepts: image.ps1 -Action preflight -IsoPath <iso> -AcceptEula (elevated). Then, only if pre-flight is green: image.ps1 -Action launch -IsoPath <iso> -Confirm (elevated).'
      note = 'Read-only: nothing was mounted, nothing was started, and no EULA was passed to Windows Setup by this action.'
    }
  }

  'detect' {
    $rails = Get-FFRails
    $componentStore = [ordered]@{ status = 'needs-admin'; imageHealthState = $null }
    if ($IsAdmin) {
      try {
        $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
        $componentStore.status = 'checked'
        $componentStore.imageHealthState = "$($r.ImageHealthState)"
      } catch {
        $componentStore.status = 'error'
        $componentStore.imageHealthState = $null
        $componentStore.error = "$($_.Exception.Message)"
      }
    }
    $out = [ordered]@{
      ok             = $true
      action         = 'detect'
      isAdmin        = $IsAdmin
      at             = (Get-Date).ToString('s')
      os             = $Os
      mediaMustMatch = [ordered]@{
        edition  = $Os.editionId
        language = $Os.language.tag
        build    = "same-or-newer than $($Os.currentBuild)"
        arch     = $Os.architecture
        rule     = 'Since Windows 11 22H2 the repair media must exactly match the system default UI language, match the edition, be the same-or-newer build, and match the architecture. Any mismatch and setup exits silently.'
      }
      rails          = $rails
      componentStore = $componentStore
    }
  }

  'validate' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os -AllowFeatureUpdate:$AllowFeatureUpdate
    try {
      if (-not $mv.ok) {
        $out = [ordered]@{
          ok = $false; action = 'validate'; errorCode = $mv.errorCode; error = $mv.error
          isAdmin = $IsAdmin; needsAdmin = [bool]$mv.needsAdmin
          os = $Os
        }
        if ($mv.errorCode -eq 'inventory-failed' -or $mv.errorCode -eq 'inventory-needs-admin' -or $mv.errorCode -eq 'inventory-empty' -or $mv.errorCode -eq 'not-windows-media') {
          # A real answer about the media, not bad input: exit 0 with ok=false. The
          # verdict is always the same shape so a consumer reading verdict.compatible
          # never null-references, with determined:false saying the rules never ran.
          $out.verdict = New-FFUndeterminedVerdict -Reason "$($mv.error)"
        } else {
          $exitCode = 2
        }
      } else {
        $out = [ordered]@{
          ok        = $true
          action    = 'validate'
          isAdmin   = $IsAdmin
          os        = $Os
          media     = [ordered]@{ root = $mv.media.root; imageFile = $mv.media.imageFile; kind = $mv.media.kind; isoPath = $mv.media.isoPath }
          inventory = $mv.inventory
          verdict   = $mv.verdict
        }
        if ($mv.media.kind -eq 'esd') {
          $out.verdict.notes = @($out.verdict.notes) + @('Media carries install.esd (MCT-style): fine for setup.exe and as a DISM esd: source; not mountable for file extraction.')
        }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'acquire-url' {
    $chan = Get-FFEditionChannel -EditionId $Os.editionId
    $ed = $chan.fidoEdition
    $lang = $null
    if ($Os.language.tag -and $FidoLangMap.ContainsKey($Os.language.tag)) { $lang = $FidoLangMap[$Os.language.tag] }
    $arch = $Os.architecture
    $ladder = Get-FFFallbackLadder -LangCode "$($Os.language.tag)" -Edition $Os.editionId -Arch $arch -Generation "$($Os.generation)"

    # Generation gate FIRST. -Win was hard-coded to 11: on a Windows 10 machine this
    # action fetched a Windows 11 ISO and handed it to a flow that used to accept it as
    # "compatible" - a major-version upgrade behind a repair button.
    if ($Os.generation -ne 'win11') {
      $reason = $(if ($null -eq $Os.generation) {
          "This machine's Windows generation could not be determined (its build number could not be read), so FrameForge will not guess which ISO to ask Microsoft for. Use the manual path and match the media to this PC by hand."
        } elseif ($Os.generation -eq 'win10') {
          "FrameForge's built-in ISO acquisition fetches Windows 11 media (build 22000+); this machine reports build $($Os.currentBuild), which is Windows 10. Fetching Windows 11 media here would be a major-version UPGRADE, not a repair, so this rung refuses. The fallback ladder below points at the Windows 10 download page instead."
        } else {
          "FrameForge's built-in ISO acquisition covers Windows 10 and Windows 11; this machine reports build $($Os.currentBuild), which is neither."
        })
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'; errorCode = 'generation-unsupported'
        reason = $reason
        generation = [ordered]@{ os = $Os.generation; osBuild = $Os.currentBuild; fidoWouldRequest = '11' }
        fallbackDetail = $ladder; os = $Os
      }
      break
    }
    $fidoWin = '11'

    if ($null -eq $ed) {
      $reason = $(if ($chan.channel -eq 'volume-license') {
          "Installed edition '$($Os.editionId)' is not covered by the consumer multi-edition ISO Fido can fetch - it comes from its own licensing channel ($((@($chan.licenseChannels)) -join '; '))."
        } else {
          "FrameForge does not recognise the installed edition '$($Os.editionId)' and will not guess which ISO matches it. Use the manual download path and pick media whose edition string matches '$($Os.editionId)' exactly - that is what this engine checks, and it is the honest answer rather than a claim about your licence channel that FrameForge never verified."
        })
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        errorCode = $(if ($chan.channel -eq 'volume-license') { 'edition-volume-license' } else { 'edition-unrecognised' })
        reason = $reason
        editionChannel = $chan
        fallbackDetail = $ladder; os = $Os
      }
      break
    }
    if ($null -eq $lang) {
      $reason = $(if ($Os.language.tag) {
          "System UI language '$($Os.language.tag)' could not be mapped to a Microsoft ISO language name - pick the language manually on the download page (it must exactly match '$($Os.language.tag)')."
        } else {
          'The system default UI language could not be determined on this machine, so FrameForge will not ask Microsoft for a language it has not measured. Check this PC''s Windows display language (Settings > Time & language > Language & region) and pick that exact language on the download page.'
        })
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        errorCode = $(if ($Os.language.tag) { 'language-unmapped' } else { 'language-undetermined' })
        reason = $reason
        fallbackDetail = $ladder; os = $Os
      }
      break
    }
    if ($arch -ne 'x64' -and $arch -ne 'arm64') {
      $reason = $(if ($arch -eq 'unknown') {
          "This machine's OS architecture could not be determined (architecture.source: $($Os.architectureSource)), so FrameForge will not request an ISO for a guess."
        } else {
          "Architecture '$arch' (resolved from $($Os.architectureSource)) has no Windows 11 consumer ISO channel."
        })
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        errorCode = $(if ($arch -eq 'unknown') { 'architecture-undetermined' } else { 'architecture-unsupported' })
        reason = $reason
        architecture = $Os.architectureDetail
        fallbackDetail = $ladder; os = $Os
      }
      break
    }

    # Which RELEASE to ask for. '-Rel Latest' was hard-coded, so a 23H2 machine was always
    # handed 25H2 media and the same-build repair this page promises was unreachable
    # through the product's own recommended path. Ask for the installed release by name
    # when it looks like one; fall back to Latest only if Fido cannot serve it, and SAY SO.
    $installedRelease = "$($Os.displayVersion)".Trim()
    $relRequested = 'Latest'
    if ($installedRelease -match '^\d{2}H\d$') { $relRequested = $installedRelease }
    $relDelivered = $relRequested
    $releaseFallbackUsed = $false

    $fidoPath = Join-Path $ToolsDir 'Fido.ps1'
    $fidoArgsFor = {
      param([string]$Rel)
      "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fidoPath`" -Win $fidoWin -Rel $Rel -Ed $ed -Lang `"$lang`" -Arch $arch -GetUrl"
    }
    $fidoArgs = & $fidoArgsFor $relRequested
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # What is and is NOT verified about the third-party script. Stating this plainly is
    # the point: the SHA-256 used to be advertised as a safety property while it was in
    # fact computed AFTER download and never compared to anything.
    $fidoTrust = [ordered]@{
      verified = @(
        'Transport: HTTPS only. A non-https:// URL is skipped outright.',
        "Origin: the official pbatard/Fido repository's latest release asset ($FidoPrimaryUrl).",
        'Shape: the first 80 lines must look like the Fido script (a CDN error page or an HTML redirect is refused, not executed).',
        'Isolation: it runs out-of-process under powershell.exe with a 300 s timeout, so it cannot touch this engine''s state and its GPLv3 code never links into the app.',
        'Result: the returned URL must be https:// on a microsoft.com host, or it is refused.'
      )
      notVerified = @(
        'The SHA-256 is COMPUTED AND REPORTED, not checked against a pinned known-good value. Fido publishes a new script with every release, so a hard-coded hash would break the feature on the next release instead of protecting anyone.',
        "The fallback URL $FidoFallbackUrl is a moving target: it is the tip of the master branch, not a signed release asset. It is used only if the release asset cannot be fetched, and the source actually used is reported in fido.source.",
        'The script is not code-signed and FrameForge does not audit its contents.'
      )
      howToPin = 'Pass -FidoSha256 <hash> to require an exact script. The hash of the script that was fetched is always in fido.sha256, so a first run can be used to pin later runs. On a mismatch the script is NOT executed AND the rejected download is deleted - it never reaches data\state\tools\Fido.ps1 at all, because the download lands on a temp name and is only renamed into place after the hash and shape checks pass. A previously-good copy is therefore never overwritten by a bad one.'
      pinnedHash = $(if ($FidoSha256) { "$FidoSha256" } else { $null })
    }

    if ($DryRun) {
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'; dryRun = $true
        wouldDownload = [ordered]@{ primary = $FidoPrimaryUrl; fallback = $FidoFallbackUrl; to = $fidoPath }
        wouldRun = "powershell.exe $fidoArgs"
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch; windowsGeneration = $Os.generation }
        release = [ordered]@{ installedDisplayVersion = $installedRelease; installedBuild = $Os.currentBuild; requested = $relRequested; delivered = $null; fallbackToLatestUsed = $false; note = 'Fido is asked for the INSTALLED release by name so a same-build repair is possible; if it cannot serve that release, one retry asks for Latest and the result then carries a versionChange block saying the ISO may be a newer Windows.' }
        trust = $fidoTrust
        consentRequired = $true
        fallbackDetail = $ladder
        note = 'Nothing was downloaded or executed (-DryRun). Outside -DryRun this action needs -ConsentRunFido: it fetches and runs a third-party GPLv3 script that works by presenting a non-Windows browser identity to Microsoft''s download page. Show trust.verified / trust.notVerified to the user and let them decide.'
      }
      break
    }

    if (-not $ConsentRunFido) {
      # Same shape as launch's consent-contract mode: report exactly what would happen,
      # do none of it. Downloading and executing third-party code on the user's machine
      # is a decision the user makes, not a side effect of clicking "get media".
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'; mode = 'consent-contract'; executed = $false
        wouldDownload = [ordered]@{ primary = $FidoPrimaryUrl; fallback = $FidoFallbackUrl; to = $fidoPath }
        wouldRun = "powershell.exe $fidoArgs"
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch; windowsGeneration = $Os.generation }
        release = [ordered]@{ installedDisplayVersion = $installedRelease; installedBuild = $Os.currentBuild; requested = $relRequested; delivered = $null; fallbackToLatestUsed = $false; note = 'Fido is asked for the INSTALLED release by name so a same-build repair is possible; if it cannot serve that release, one retry asks for Latest and the result then carries a versionChange block saying the ISO may be a newer Windows.' }
        trust = $fidoTrust
        needsConsent = $true
        howToExecute = 'Re-run with -ConsentRunFido after the user has accepted, optionally with -FidoSha256 <hash> to pin the script. Or skip this rung entirely and use fallbackDetail.mct / fallbackDetail.manual, which download nothing but Microsoft''s own bits.'
        fallbackDetail = $ladder
      }
      $exitCode = 3
      break
    }

    # 1. Fetch Fido.ps1 (HTTPS, official repo only), record SHA-256 of what we got.
    #
    # DOWNLOAD-TO-QUARANTINE, then promote. The download lands on a temp name and is only
    # renamed onto Fido.ps1 after BOTH gates pass (pinned hash, then shape). Previously a
    # tampered or wrong file was written straight to data\state\tools\Fido.ps1, and the
    # mismatch path then refused to RUN it while leaving it sitting on disk - and it had
    # already overwritten a previously-good copy on the way in. Now a rejected file is
    # deleted and any existing good copy is untouched.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $fetchedFrom = $null; $fetchError = $null
    $fidoTempPath = Join-Path $ToolsDir ("Fido.download-" + [guid]::NewGuid().ToString('N') + ".tmp")
    $priorCopyExisted = $false
    try { $priorCopyExisted = Test-Path -LiteralPath $fidoPath -PathType Leaf } catch {}
    function Remove-FFRejectedDownload {
      param([string]$Path)
      $r = [ordered]@{ deleted = $false; error = $null }
      try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        $r.deleted = $true
      } catch { $r.error = "$($_.Exception.Message)" }
      $r
    }
    try {
      if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
      foreach ($u in @($FidoPrimaryUrl, $FidoFallbackUrl)) {
        if ($u -notmatch '^https://') { continue }  # HTTPS is non-negotiable
        try {
          Invoke-WebRequest -Uri $u -OutFile $fidoTempPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
          $fetchedFrom = $u
          break
        } catch { $fetchError = "$($_.Exception.Message)" }
      }
    } catch { $fetchError = "$($_.Exception.Message)" }
    if ($null -eq $fetchedFrom) {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "Fido.ps1 could not be fetched from GitHub: $fetchError"
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; existingCopyPreserved = $priorCopyExisted }
        fallbackDetail = $ladder
      }
      break
    }
    $fidoSha256 = $null
    try { $fidoSha256 = (Get-FileHash -LiteralPath $fidoTempPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
    # Hash pinning, when the caller asked for it: checked BEFORE the file is promoted and
    # long before anything is executed.
    if ($FidoSha256) {
      $want = "$FidoSha256".Trim().Replace('-','').ToUpperInvariant()
      $got = "$fidoSha256".Trim().ToUpperInvariant()
      if ($want -ne $got) {
        $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
        $out = [ordered]@{
          ok = $false; action = 'acquire-url'; fallback = 'manual'
          reason = "SHA-256 mismatch: -FidoSha256 pinned $want but the script fetched from $fetchedFrom hashes to $got. Refusing to run it, and the rejected download has been DELETED rather than left on disk. Either the upstream released a new version (check the repository and re-pin) or the download was tampered with."
          fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; expectedSha256 = $want; path = $null; executed = $false }
          quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted
                                   note = 'The download never reached data\state\tools\Fido.ps1: it is written to a temp name and only renamed into place after the hash and shape checks pass, so a rejected file cannot overwrite a previously-good copy.' }
          trust = $fidoTrust
          fallbackDetail = $ladder
        }
        $exitCode = 3
        break
      }
    }
    $looksLikeFido = $false
    try {
      $head = Get-Content -LiteralPath $fidoTempPath -TotalCount 80 -ErrorAction Stop
      $headTxt = ($head -join "`n")
      # Test-FFIMatch: 'Fido' contains an 'i'. This is the shape gate that decides whether a
      # downloaded script is promoted onto Fido.ps1, so a culture-dependent miss here would reject
      # the genuine article on every Turkish machine.
      $looksLikeFido = ((Test-FFIMatch $headTxt 'Fido') -and (Test-FFIMatch $headTxt 'param'))
    } catch {}
    if (-not $looksLikeFido) {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = 'The fetched file does not look like the Fido PowerShell script (possible CDN error page) - refusing to run it, and the rejected download has been deleted rather than left on disk.'
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $null; executed = $false }
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
      break
    }
    # Both gates passed - promote the quarantined file into place.
    try {
      Move-Item -LiteralPath $fidoTempPath -Destination $fidoPath -Force -ErrorAction Stop
    } catch {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "The fetched script passed its checks but could not be moved into place at '$fidoPath': $($_.Exception.Message)"
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $null; executed = $false }
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
      break
    }

    # 2. Run it OUT-of-process (GPLv3 isolation + crash isolation) and parse the URL.
    #    Asking for the INSTALLED release first is what makes a same-build repair reachable
    #    at all; if Fido cannot serve that release, one retry with Latest happens and the
    #    result says plainly that what comes back may be a newer Windows.
    function Get-FFFidoUrl {
      param([string]$Arguments)
      $r = Invoke-FFProcess -FilePath $psExe -Arguments $Arguments -TimeoutSec 300
      $lines = @()
      if ($r.stdout) { $lines = @($r.stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() }) }
      $url = $null
      foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -match '^https://\S+$') { $url = $t }
      }
      $ms = $false
      if ($url) {
        try {
          $u = [Uri]$url
          # Test-FFIMatch: 'microsoft' contains an 'i', and this is the allowlist that decides
          # whether a URL a third-party script produced is accepted at all.
          $ms = ($u.Scheme -eq 'https' -and (Test-FFIMatch "$($u.Host)" '(^|\.)microsoft\.com$'))
        } catch {}
      }
      [ordered]@{ run = $r; urlLine = $url; isMsUrl = $ms; allText = "$($r.stdout)`n$($r.stderr)" }
    }
    $attempt = Get-FFFidoUrl -Arguments $fidoArgs
    if (-not $attempt.isMsUrl -and $relRequested -ne 'Latest') {
      $firstAttemptText = $attempt.allText
      $retryArgs = & $fidoArgsFor 'Latest'
      $retry = Get-FFFidoUrl -Arguments $retryArgs
      if ($retry.isMsUrl) {
        $attempt = $retry
        $fidoArgs = $retryArgs
        $relDelivered = 'Latest'
        $releaseFallbackUsed = $true
      } else {
        # Keep the FIRST failure as the reported one, but note the retry happened.
        $attempt.allText = "$firstAttemptText`n[retry with -Rel Latest]`n$($retry.allText)"
      }
    }
    $run = $attempt.run
    $urlLine = $attempt.urlLine
    $allText = $attempt.allText
    $isMsUrl = $attempt.isMsUrl
    # Honest statement of what this URL may deliver. FrameForge cannot read a build number
    # out of a download URL, so it does not claim one: it says what was asked for, what is
    # coming, and that validate is where the actual build is established - before anything
    # is installed.
    $versionChange = $null
    if ($isMsUrl -and $relDelivered -eq 'Latest') {
      $versionChange = [ordered]@{
        from = $(if ($installedRelease) { $installedRelease } else { "build $($Os.currentBuild)" })
        fromBuild = $Os.currentBuild
        toAtLeast = 'latest retail release'
        mustShowBeforeDownload = $true
        note = $(if ($releaseFallbackUsed) {
            "Fido could not serve media for this PC's installed release ($installedRelease), so this URL is for the LATEST retail release. If that ISO is a newer build than $($Os.currentBuild), running it in place is a FEATURE UPDATE - your Windows version changes - not a same-build repair."
          } else {
            "This URL is for the LATEST retail release; this PC's installed release could not be requested by name (displayVersion: '$installedRelease'). If that ISO is a newer build than $($Os.currentBuild), running it in place is a FEATURE UPDATE - your Windows version changes - not a same-build repair."
          })
        howItIsEnforced = 'validate reads the ISO and reports the exact build; launch refuses a newer-build ISO unless -AllowFeatureUpdate is passed and the version-change consent contract is accepted.'
      }
    }
    if ($isMsUrl) {
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'
        url = $urlLine
        expiresNote = 'Microsoft direct-download URLs are time-limited (typically ~24 hours). Download promptly, then verify the ISO SHA-256 against the hash list on the Microsoft download page - that comparison is the one that matters, and it is one FrameForge cannot make for you because Microsoft publishes those hashes only on the page itself.'
        versionChange = $versionChange
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch; windowsGeneration = $Os.generation }
        release = [ordered]@{ installedDisplayVersion = $installedRelease; installedBuild = $Os.currentBuild; requested = $relRequested; delivered = $relDelivered; fallbackToLatestUsed = $releaseFallbackUsed }
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; pinnedSha256 = $(if ($FidoSha256) { "$FidoSha256" } else { $null }); path = $fidoPath; ranOutOfProcess = $true; executed = $true; exitCode = $run.exitCode }
        trust = $fidoTrust
        nextStep = "image.ps1 -Action download -Url <url> -Dest <path.iso>"
      }
    } else {
      # Structured failure - classify, never crash.
      $fallback = 'mct'; $reason = $null
      if ($run.timedOut) {
        $reason = 'Fido timed out after 300 s querying Microsoft''s servers.'
      } elseif (Test-FFIMatch $allText '715-123130|Sentinel|banned') {
        $reason = 'Microsoft''s Sentinel anti-abuse layer rejected the scripted request (error 715-123130, IP-reputation ban; it does not self-clear). Use the Media Creation Tool - Microsoft''s own suggested workaround.'
      } elseif ($urlLine) {
        $fallback = 'manual'
        $reason = "Fido returned a URL outside microsoft.com ('$urlLine') - refusing it."
      } else {
        $reason = 'Fido did not return a download URL (its output could not be parsed).'
      }
      $excerpt = $allText.Trim()
      if ($excerpt.Length -gt 800) { $excerpt = $excerpt.Substring(0, 800) + ' ...' }
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = $fallback; reason = $reason
        release = [ordered]@{ installedDisplayVersion = $installedRelease; installedBuild = $Os.currentBuild; requested = $relRequested; delivered = $null; fallbackToLatestUsed = $releaseFallbackUsed }
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $fidoPath; executed = $true; exitCode = $run.exitCode; timedOut = $run.timedOut; outputExcerpt = $excerpt }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
    }
  }

  'download' {
    if (-not $Url -or -not $Dest) {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'missing-param'; error = 'download requires -Url <https url> and -Dest <destination file path>.' }
      $exitCode = 2
      break
    }
    $uriOk = $false
    try { $u = [Uri]$Url; $uriOk = ($u.Scheme -eq 'https') } catch {}
    if (-not $uriOk) {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'not-https'; error = 'Refusing a non-HTTPS download URL.' }
      $exitCode = 2
      break
    }
    if ($DryRun) {
      $out = [ordered]@{ ok = $true; action = 'download'; dryRun = $true; wouldRun = "Start-BitsTransfer -Source '$Url' -Destination '$Dest'"; then = 'Get-FileHash -Algorithm SHA256 on the result.' }
      break
    }
    try {
      $destDir = Split-Path -Path $Dest -Parent
      if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null }
      Import-Module BitsTransfer -ErrorAction Stop
      Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName 'FrameForge Windows ISO' -Description 'Official Microsoft ISO download' -ErrorAction Stop
      $fi = Get-Item -LiteralPath $Dest -ErrorAction Stop
      $hash = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256 -ErrorAction Stop).Hash
      $out = [ordered]@{
        ok = $true; action = 'download'
        dest = $fi.FullName
        sizeBytes = [int64]$fi.Length
        sizeGB = [math]::Round($fi.Length / 1GB, 2)
        sha256 = $hash
        verifyNote = 'Compare this SHA-256 against the hash list Microsoft publishes on the download page before using the ISO.'
      }
    } catch {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'transfer-failed'; error = "BITS transfer failed: $($_.Exception.Message)" }
    }
  }

  'dism-source-repair' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os -AllowFeatureUpdate:$AllowFeatureUpdate
    try {
      if (-not $mv.ok) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      $idx = $mv.verdict.selectedIndex
      if ($null -eq $idx) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'no-matching-index'; error = 'No image index on this media matches the installed edition - see verdict.'; verdict = $mv.verdict }
        break
      }
      $srcSpec = "$($mv.media.kind):$($mv.media.imageFile):$idx"
      $dismCmd = "DISM /Online /Cleanup-Image /RestoreHealth /Source:$srcSpec /LimitAccess"
      $psCmd   = "Repair-WindowsImage -Online -RestoreHealth -Source '$srcSpec' -LimitAccess"
      $followUp = [ordered]@{
        engine    = 'repair.ps1'
        catalogId = 'sfc-scannow'
        why       = 'DISM repairs the component store; SFC then repairs live system files FROM the repaired store. Always run SFC after.'
      }
      if ($DryRun) {
        $out = [ordered]@{
          ok = $true; action = 'dism-source-repair'; dryRun = $true
          selectedIndex = $idx
          sourceSpec = $srcSpec
          wouldRun = $dismCmd
          powershellForm = $psCmd
          verdict = $mv.verdict
          followUp = $followUp
          note = 'Nothing was executed (-DryRun). The command repairs C:\Windows\WinSxS payloads offline; /LimitAccess blocks the Windows Update fallback so the repair is deterministic.'
        }
        break
      }
      if (-not $IsAdmin) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'needs-admin'; error = 'RestoreHealth requires administrator rights. Re-run elevated, or use -DryRun to preview the exact command.'; wouldRun = $dismCmd }
        $exitCode = 3
        break
      }
      if (-not $mv.verdict.compatible) {
        # Honest refusal: a wrong-build/edition source yields 0x800f081f, not a repair.
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'media-incompatible'; error = 'This media does not match the installed OS - as a DISM source it would fail with 0x800f081f. See verdict.reasons.'; verdict = $mv.verdict }
        $exitCode = 3
        break
      }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $r = Repair-WindowsImage -Online -RestoreHealth -Source $srcSpec -LimitAccess -ErrorAction Stop
        $sw.Stop()
        $out = [ordered]@{
          ok = $true; action = 'dism-source-repair'
          ran = $dismCmd
          selectedIndex = $idx
          imageHealthState = "$($r.ImageHealthState)"
          restartNeeded = [bool]$r.RestartNeeded
          durationMs = [int]$sw.ElapsedMilliseconds
          verdict = $mv.verdict
          followUp = $followUp
          log = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
        }
      } catch {
        $sw.Stop()
        $msg = "$($_.Exception.Message)"
        $hint = $null
        if ($msg -match '0x800f081f') { $hint = 'Source files not found: the image build/LCU is older than the running OS or the index edition is wrong. Use newer media, or run plain RestoreHealth (Windows Update source).' }
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'restorehealth-failed'; error = $msg; hint = $hint; ran = $dismCmd; durationMs = [int]$sw.ElapsedMilliseconds; log = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log') }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'preflight' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os -AllowFeatureUpdate:$AllowFeatureUpdate
    try {
      if (-not $mv.media.ok) {
        $out = [ordered]@{ ok = $false; action = 'preflight'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      $mediaVerified = ($mv.ok -and $mv.verdict.compatible)
      $rails = Get-FFRails
      $railCheck = Test-FFRailsGreen -Rails $rails
      # Never emit verdict:null alongside ok:true - a consumer reading verdict.compatible
      # would null-reference. An unreadable inventory gets a real, honest verdict object.
      $verdict = $mv.verdict
      if (-not $mv.ok) {
        $verdict = New-FFUndeterminedVerdict -Reason "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
        $railCheck.reasons = @($railCheck.reasons) + @("Media inventory could not be read ($($mv.errorCode)): $($mv.error)")
        $railCheck.green = $false
      }
      $setupExe = Join-Path $mv.media.root 'setup.exe'
      $setupPresent = (Test-Path -LiteralPath $setupExe -PathType Leaf)
      $scanArgs = '/auto upgrade /quiet /eula accept /compat scanonly /noreboot'
      $scanCmd = "`"$setupExe`" $scanArgs"
      # The contract is built FROM the verdict, so a feature update says so here rather
      # than describing a same-version repair the user is not actually about to get.
      $contract = New-FFConsentContract -Verdict $verdict -Os $Os

      # --- EULA gate. The compat scan passes /eula accept: it IS Windows Setup running
      # its own dress rehearsal, and it will not run unattended without that switch.
      # Passing it silently while a later screen promised "FrameForge will not pass it
      # until you consent here" was a documented lie. Consent is collected first
      # (-Action consent), then represented to this action as -AcceptEula.
      $compatScan = $null
      $needsEulaConsent = $false
      $needsAdminRefusal = $false
      if ($DryRun) {
        $compatScan = [ordered]@{ ran = $false; wouldRun = $scanCmd; note = 'Skipped (-DryRun). The scan is non-destructive - setup runs the full compatibility check and exits with a translated code (0xC1900210 clean / 0xC1900208 blocked) - but it DOES pass /eula accept, so outside -DryRun it needs -AcceptEula. It also writes setup logs and briefly consumes CPU/disk.' }
      } elseif (-not $AcceptEula) {
        $needsEulaConsent = $true
        $compatScan = [ordered]@{
          ran = $false
          wouldRun = $scanCmd
          skippedBecause = 'eula-consent-required'
          detail = 'The compatibility scan passes /eula accept to Windows Setup - it is Windows Setup, and it refuses to run unattended without that switch. FrameForge will not accept the Microsoft Software License Terms on your behalf, so this scan does not run until you have consented. Show the contract (image.ps1 -Action consent), then re-run pre-flight with -AcceptEula.'
          contract = $contract
        }
      } elseif (-not $IsAdmin) {
        # Exit 3, per the documented contract at the top of this file: this is a REFUSAL
        # for want of administrator rights, on the execute path (consent has been given,
        # the scan was going to run, and it did not). Exiting 0 here reported the same
        # code as a pre-flight that actually ran its dress rehearsal, which made the
        # documented meaning of exit 3 untrue.
        $needsAdminRefusal = $true
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'needs-admin'; wouldRun = $scanCmd; detail = 'Windows Setup requires administrator rights even for /compat scanonly. The EULA consent was accepted, so the only thing missing is elevation: re-run pre-flight elevated. Exit code 3 (refused: needs administrator rights).' }
      } elseif (-not $setupPresent) {
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'setup-missing'; error = "setup.exe not found at '$setupExe'." }
      } elseif (-not $mediaVerified) {
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'media-not-verified'; detail = 'Media is not verified compatible (unreadable inventory or failed matching rules) - a compat scan against wrong media proves nothing. Fix the media first.' }
      } else {
        try {
          $p = Start-Process -FilePath $setupExe -ArgumentList $scanArgs -Wait -PassThru -ErrorAction Stop
          $translated = Convert-FFSetupExitCode -Code $p.ExitCode
          $compatScan = [ordered]@{ ran = $true; command = $scanCmd; eulaAccepted = $true; result = $translated; compatXmlHint = 'On 0xC1900208, the blockers are named in C:\$WINDOWS.~BT\Sources\Panther\CompatData*.xml.' }
        } catch {
          $compatScan = [ordered]@{ ran = $false; skippedBecause = 'start-failed'; error = "Could not start the compatibility scan: $($_.Exception.Message)" }
        }
      }

      $green = ($railCheck.green -and $mediaVerified)
      $scanVerdict = $null
      if ($compatScan -and $compatScan.Contains('result')) { $scanVerdict = $compatScan.result.verdict }
      if ($null -ne $scanVerdict -and $scanVerdict -ne 'clean') { $green = $false }
      # A pre-flight whose dress rehearsal never ran has not proven anything.
      if (-not $compatScan.ran) { $green = $false }
      if (($needsEulaConsent -or $needsAdminRefusal) -and -not $DryRun) { $exitCode = 3 }
      $out = [ordered]@{
        ok = $true; action = 'preflight'; dryRun = [bool]$DryRun
        isAdmin = $IsAdmin
        eulaAccepted = [bool]$AcceptEula
        needsEulaConsent = $needsEulaConsent
        needsAdmin = $needsAdminRefusal
        contract = $contract
        media = [ordered]@{ root = $mv.media.root; imageFile = $mv.media.imageFile; kind = $mv.media.kind; setupExePresent = $setupPresent }
        verdict = $verdict
        rails = $rails
        railCheck = $railCheck
        compatScan = $compatScan
        readyToLaunch = $green
        nextStep = $(if ($needsEulaConsent) { 'Show contract (image.ps1 -Action consent). After the user accepts: re-run pre-flight with -AcceptEula, elevated.' }
                     elseif ($needsAdminRefusal) { 'Re-run pre-flight elevated (with -AcceptEula) so Windows Setup can run its compatibility scan. Everything else above was checked.' }
                     elseif ($green -and -not $DryRun) { 'image.ps1 -Action launch -IsoPath <iso> (returns the consent contract again; add -Confirm only after the user consents in the UI)' }
                     else { 'Resolve the red items above, then re-run preflight.' })
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'launch' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os -AllowFeatureUpdate:$AllowFeatureUpdate
    try {
      if (-not $mv.media.ok) {
        # Media itself could not be resolved (no file / not Windows media) - no
        # command can even be constructed. Structured error.
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      if (-not $mv.ok -and $Confirm -and -not $DryRun) {
        # Executing requires a readable, verified inventory - refuse.
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        $exitCode = 3
        break
      }
      $rails = Get-FFRails
      $railCheck = Test-FFRailsGreen -Rails $rails
      $setupExe = Join-Path $mv.media.root 'setup.exe'
      $setupPresent = (Test-Path -LiteralPath $setupExe -PathType Leaf)
      $launchArgs = "/auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs `"$SetupLogDir`" /noreboot"
      $launchCmd = "`"$setupExe`" $launchArgs"
      $lVerdict = $mv.verdict
      if ($null -eq $lVerdict) {
        $lVerdict = New-FFUndeterminedVerdict -Reason "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
      }
      # Built FROM the verdict: when the media is newer than the installed build, the
      # contract states the version change and sets isFeatureUpdate/requiresSecondConsent
      # instead of describing a same-version repair the user is not getting.
      $contract = New-FFConsentContract -Verdict $lVerdict -Os $Os

      if (-not $Confirm -or $DryRun) {
        # Consent-contract mode: the exact command and the honest terms, nothing runs.
        $blockers = @()
        if (-not $setupPresent) { $blockers += "setup.exe not found at '$setupExe'." }
        if ($null -eq $mv.verdict) {
          $blockers += "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
        }
        elseif (-not $lVerdict.compatible) { $blockers += 'Media failed the matching rules (see verdict.reasons).' }
        $blockers += @($railCheck.reasons)
        if (-not $IsAdmin) { $blockers += 'Administrator rights are required to launch.' }
        $out = [ordered]@{
          ok = $true; action = 'launch'; mode = 'consent-contract'
          executed = $false
          command = $launchCmd
          optionalBitLockerStep = 'Suspend-BitLocker -MountPoint C: -RebootCount 3   (pass -SuspendBitLocker to include it)'
          contract = $contract
          verdict = $lVerdict
          rails = $rails
          railCheck = $railCheck
          blockers = $blockers
          howToExecute = 'Re-run with -Confirm (elevated) AFTER the user has accepted the contract in the UI. FrameForge never launches this silently (doctrine rule 3).'
        }
        break
      }

      # -Confirm path: every gate must be green.
      if (-not $IsAdmin) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'needs-admin'; error = 'Launching the in-place repair requires administrator rights.' }
        $exitCode = 3
        break
      }
      if (-not $setupPresent) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'setup-missing'; error = "setup.exe not found at '$setupExe'." }
        $exitCode = 3
        break
      }
      if (-not $mv.verdict.compatible) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'media-incompatible'; error = 'Refusing to launch: the media does not match this machine.'; verdict = $mv.verdict }
        $exitCode = 3
        break
      }
      if (-not $railCheck.green) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'rails-red'; error = 'Refusing to launch: safety rails are not green.'; railCheck = $railCheck; rails = $rails }
        $exitCode = 3
        break
      }

      # Ledger BEFORE launch: verify() diffs against this.
      $entry = [ordered]@{
        launchedAt    = (Get-Date).ToString('s')
        isoPath       = $mv.media.isoPath
        sourceRoot    = $mv.media.root
        imageKind     = $mv.media.kind
        selectedIndex = $mv.verdict.selectedIndex
        mediaBuild    = $mv.verdict.imageInfo.build
        mediaUbr      = $mv.verdict.imageInfo.ubr
        preOs         = [ordered]@{ editionId = $Os.editionId; displayVersion = $Os.displayVersion; build = $Os.currentBuild; ubr = $Os.ubr; language = $Os.language.tag }
        command       = $launchCmd
        bitLockerSuspended = $false
      }
      $bl = $null
      if ($SuspendBitLocker) {
        # Suspend-BitLocker lives in the BitLocker module, which ships only with
        # Pro/Enterprise/Education. On Home there is nothing to call - say that plainly
        # instead of surfacing a CommandNotFoundException as if the suspend had failed.
        $haveBlCmdlets = $false
        try { $haveBlCmdlets = [bool](Get-Command Suspend-BitLocker -ErrorAction SilentlyContinue) } catch {}
        if (-not $haveBlCmdlets) {
          $bl = "This Windows edition has no BitLocker PowerShell module, so FrameForge cannot suspend protection here (the module ships with Pro/Enterprise/Education only). Windows Setup's own TryKeepActive handling still applies, and on a Home machine using Device Encryption setup suspends and resumes it itself. Encryption state as read by the rails: $($rails.bitlocker.status)/$($rails.bitlocker.protectionStatus)."
        } else {
        try {
          $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
          if ("$($blv.ProtectionStatus)" -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 3 -ErrorAction Stop | Out-Null
            $entry.bitLockerSuspended = $true
            $bl = 'BitLocker suspended for 3 reboots (auto-resumes).'
          } else {
            $bl = 'BitLocker protection is not on - nothing to suspend.'
          }
        } catch { $bl = "Suspend-BitLocker failed (setup's TryKeepActive default still applies): $($_.Exception.Message)" }
        }
      }
      $ledger = @(Read-FFLedger) + @($entry)
      $ledgerWritten = Write-FFLedger -Entries $ledger
      try {
        if (-not (Test-Path -LiteralPath $SetupLogDir)) { New-Item -ItemType Directory -Path $SetupLogDir -Force -ErrorAction Stop | Out-Null }
      } catch {}
      try {
        $p = Start-Process -FilePath $setupExe -ArgumentList $launchArgs -PassThru -ErrorAction Stop
        $out = [ordered]@{
          ok = $true; action = 'launch'; mode = 'executed'; executed = $true
          command = $launchCmd
          setupPid = $p.Id
          bitLockerNote = $bl
          ledgerWritten = $ledgerWritten
          ledgerPath = $LedgerPath
          note = 'Setup is running its down-level phase (10-30 min). /noreboot means YOU choose when to restart; do not dismount the ISO - setup copies what it needs to C:\$WINDOWS.~BT first, and the mount clears at reboot anyway. Run image.ps1 -Action verify after the final restart.'
        }
        # Deliberately NOT dismounting: setup reads from the mounted media.
        $mv.media.mountedByUs = $false
      } catch {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'start-failed'; error = "setup.exe could not start: $($_.Exception.Message)"; ledgerWritten = $ledgerWritten }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'verify' {
    # Get-FFLedgerState, not Read-FFLedger: an UNREADABLE ledger must not become verdict
    # 'no-ledger', whose text asserts "either nothing was launched through FrameForge, or the
    # ledger was cleared" - a claim nobody measured. It gets its own verdict below.
    $ledgerState = Get-FFLedgerState
    $ledger = @()
    if ($ledgerState.readable) { $ledger = @($ledgerState.entries) }
    $last = $null
    if ($ledger.Count -gt 0) { $last = $ledger[$ledger.Count - 1] }

    $setupState = [ordered]@{ systemSetupInProgress = $null; setupPhase = $null; setupType = $null }
    try {
      $ss = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
      $setupState.systemSetupInProgress = $ss.SystemSetupInProgress
      $setupState.setupPhase = $ss.SetupPhase
      $setupState.setupType = $ss.SetupType
    } catch {}

    $setupDiag = [ordered]@{ resultsXml = $null; resultsXmlPresent = $false; registryResults = $false }
    $sdPath = Join-Path $env:SystemRoot 'Logs\SetupDiag\SetupDiagResults.xml'
    $sdRegPath = 'HKLM:\SYSTEM\Setup\SetupDiag\Results'
    try { $setupDiag.resultsXmlPresent = Test-Path -LiteralPath $sdPath -PathType Leaf } catch {}
    if ($setupDiag.resultsXmlPresent) { $setupDiag.resultsXml = $sdPath }
    try { $setupDiag.registryResults = Test-Path $sdRegPath } catch {}
    # Actually READ them. Presence alone told the user nothing while the verdict text
    # claimed "SetupDiag names the cause"; now the named cause is in the document.
    $setupDiag.parsed = Get-FFSetupDiagResults -XmlPath $sdPath -RegistryPath $sdRegPath
    $setupDiag.namedCause = $setupDiag.parsed.namedCause
    $setupDiag.summary = Get-FFSetupDiagSentence -Parsed $setupDiag.parsed
    if (-not $setupDiag.resultsXmlPresent -and -not $setupDiag.registryResults) {
      $setupDiag.absentNote = "No SetupDiag results exist on this machine ($sdPath is absent and $sdRegPath does not exist). Modern Windows Setup runs SetupDiag itself on failure, so their absence is normal on a machine that has not had a failed upgrade. If setup failed and left nothing, run SetupDiag by hand against the Panther logs: https://go.microsoft.com/fwlink/?linkid=870142 (FrameForge does not download it for you)."
    }

    # --- Evidence gathering. The build/UBR delta alone is NOT a sufficient verdict: the
    # primary scenario for this whole flow is a SAME-BUILD repair install (media UBR ==
    # OS UBR), where a completely successful repair changes neither number. Keying only
    # on the delta reported that success as "unchanged ... or it rolled back", which is
    # the exact opposite of what happened. Windows.old, the post-upgrade Panther folder,
    # and setup's own registry state are the signals that actually distinguish
    # "ran and succeeded", "ran and rolled back", and "never ran".
    # launchedAt was written with .ToString('s') (invariant). It must be READ invariantly
    # too: [datetime]::Parse() uses the CurrentCulture's CALENDAR, and any ledger entry
    # that is not in the exact ISO 'T' spelling is then read as a Buddhist year under
    # th-TH (2026 -> 1483 AD) or rejected outright under ar-SA - after which every
    # afterLaunch comparison flips and verify confidently reports 'repaired-same-build'
    # for a setup that never ran, or 'not-run' after a successful repair. $null on
    # failure, which leaves afterLaunch null (honest unknown) and yields the
    # 'launch-time-unreadable' verdict rather than a fabricated one.
    $launchedAt = $null
    $launchedAtParsed = $null
    if ($null -ne $last) {
      $launchedAt = ConvertFrom-FFTimestamp -Text "$($last.launchedAt)"
      $launchedAtParsed = ($null -ne $launchedAt)
    }
    function Test-FFNewerThanLaunch { param([string]$Path, [switch]$UseCreation)
      $r = [ordered]@{ present = $false; timestamp = $null; afterLaunch = $null }
      try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $r.present = $true
        $t = $(if ($UseCreation) { $it.CreationTime } else { $it.LastWriteTime })
        $r.timestamp = $t.ToString('s')
        if ($null -ne $script:FFLaunchedAt) { $r.afterLaunch = ($t -ge $script:FFLaunchedAt.AddMinutes(-5)) }
      } catch {}
      $r
    }
    $script:FFLaunchedAt = $launchedAt

    $windowsOldPath = Join-Path $env:SystemDrive 'Windows.old'
    $windowsOld     = Test-FFNewerThanLaunch -Path $windowsOldPath -UseCreation
    $newOsPanther   = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemRoot 'Panther\NewOs')
    $setupAct       = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemRoot 'Panther\setupact.log')
    $btFolder       = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemDrive '$WINDOWS.~BT')
    $setupDiagFresh = $null
    if ($setupDiag.resultsXmlPresent) {
      $sdInfo = Test-FFNewerThanLaunch -Path $sdPath
      $setupDiag.resultsXmlWritten = $sdInfo.timestamp
      $setupDiagFresh = $sdInfo.afterLaunch
      $setupDiag.writtenAfterLaunch = $setupDiagFresh
    }

    $evidence = [ordered]@{
      windowsOld     = $windowsOld
      pantherNewOs   = $newOsPanther
      pantherSetupAct= $setupAct
      windowsBT      = $btFolder
      setupDiagAfterLaunch = $setupDiagFresh
      launchedAtParsed = $launchedAtParsed
      note = $(if ($null -ne $last -and $launchedAtParsed -eq $false) {
          "The ledger's launchedAt ('$($last.launchedAt)') could not be parsed as an invariant round-trip timestamp, so every afterLaunch value is null: FrameForge will not compare file times against a date it could not read. Read the timestamps below by eye instead."
        } else {
          'afterLaunch is computed against the ledger''s launchedAt (parsed with the invariant calendar, never the current culture''s) with a 5-minute tolerance; it is null when there is no launch on record or the recorded timestamp could not be parsed.'
        })
    }

    $comparison = $null; $verdict = 'no-ledger'
    if (-not $ledgerState.readable) { $verdict = 'ledger-unreadable' }
    if ($null -ne $last) {
      $pre = $last.preOs
      $buildChanged = $false; $ubrChanged = $false
      try { $buildChanged = ([int]$Os.currentBuild -ne [int]$pre.build) } catch {}
      try { $ubrChanged = ([int]$Os.ubr -ne [int]$pre.ubr) } catch {}
      $sameBuildMedia = $false
      try { $sameBuildMedia = ([int]$last.mediaBuild -eq [int]$pre.build -and [int]$last.mediaUbr -eq [int]$pre.ubr) } catch {}
      $comparison = [ordered]@{
        launchedAt = $last.launchedAt
        preBuild   = "$($pre.build).$($pre.ubr)"
        nowBuild   = $Os.buildString
        mediaBuild = "$($last.mediaBuild)$(if ($null -ne $last.mediaUbr) { '.' + $last.mediaUbr })"
        buildChanged = $buildChanged
        ubrChanged  = $ubrChanged
        sameBuildRepairExpected = $sameBuildMedia
        note = 'A same-build repair install (media UBR == OS UBR) is EXPECTED to leave build and UBR identical. buildChanged:false is therefore not evidence of failure on this path - see evidence.'
      }
      $ranEvidence = ([bool]$windowsOld.afterLaunch -or [bool]$newOsPanther.afterLaunch)
      if ($setupState.systemSetupInProgress -eq 1) { $verdict = 'in-progress' }
      elseif ($buildChanged -or $ubrChanged)       { $verdict = 'os-binaries-replaced' }
      # Everything below this line is a comparison against launchedAt. If that timestamp
      # could not be parsed there is nothing to compare against, and falling through to
      # 'not-run' would be a confident verdict built on an unread value.
      elseif ($launchedAtParsed -eq $false)        { $verdict = 'launch-time-unreadable' }
      elseif ($windowsOld.afterLaunch -and $newOsPanther.afterLaunch) { $verdict = 'repaired-same-build' }
      elseif ($ranEvidence -and $setupDiagFresh)   { $verdict = 'rolled-back' }
      elseif ($ranEvidence)                        { $verdict = 'ran-outcome-unclear' }
      elseif ($setupDiagFresh)                     { $verdict = 'failed-before-completion' }
      elseif ($setupAct.afterLaunch -or $btFolder.afterLaunch) { $verdict = 'started-not-completed' }
      else                                         { $verdict = 'not-run' }
    } elseif ($setupState.systemSetupInProgress -eq 1) {
      $verdict = 'in-progress'
    }

    $verdictText = @{
      'no-ledger'                = 'No launch is recorded in the ledger - either nothing was launched through FrameForge, or the ledger was cleared. Current OS state is reported anyway.'
      'ledger-unreadable'        = 'The launch ledger EXISTS but could not be read, so FrameForge cannot say whether a repair install was ever launched from here, let alone how it went. This is deliberately not reported as "nothing was launched": that would be a claim about a file nobody could open. See ledgerError for the reason and ledgerPath for the file. Current OS state is reported anyway.'
      'in-progress'              = 'Windows Setup reports it is still in progress - verify again after the remaining restarts.'
      'os-binaries-replaced'     = 'The OS build/UBR changed since launch - the image was reinstalled. Now confirm health with the read-only probes below.'
      'repaired-same-build'      = 'The repair install completed on the SAME build - which is exactly what a same-build repair does, and why the build number is unchanged. The evidence is a C:\Windows.old created at/after launch plus a post-upgrade C:\Windows\Panther\NewOs written at/after launch: setup ran to completion and did not roll back. Now confirm health with the read-only probes below.'
      'rolled-back'              = 'Setup ran but did NOT complete: there is fresh setup activity and a SetupDiag result written after launch, with no post-upgrade Panther\NewOs. This is the rollback path - read SetupDiag''s named cause (it is almost always a driver, often an AV filter driver) before retrying.'
      'ran-outcome-unclear'      = 'Setup left fresh traces since launch, but the completion evidence is mixed. Do not assume either way: read C:\Windows\Panther\setupact.log and SetupDiag, and re-run verify after any remaining restarts.'
      'failed-before-completion' = 'A SetupDiag result was written after launch and there is no sign the upgrade completed - setup failed early. SetupDiag names the cause.'
      'started-not-completed'    = 'Setup wrote logs (or staged C:\$WINDOWS.~BT) after launch, but the machine has not been through the upgrade restarts yet. Restart to let setup finish, then verify again.'
      'launch-time-unreadable'   = 'The launch time recorded in the ledger could not be read as a timestamp, so FrameForge cannot tell which setup traces are newer than the launch and will not guess. The OS build did not change. Judge it from the evidence timestamps below and the logs, and check the ledger file.'
      'not-run'                  = 'Nothing indicates Windows Setup ran at all since the recorded launch: no fresh Windows.old, no post-upgrade Panther folder, no setup logs newer than launch. Most likely setup exited immediately - check the media matching rules (edition/language mismatch makes setup exit silently) and the launch exit code.'
    }[$verdict]

    # The rollback/failure verdicts promise a named cause. Deliver it in the same sentence
    # rather than telling the user to go and read an XML file themselves.
    $sdSentence = $setupDiag.summary
    if ($sdSentence -and @('rolled-back','failed-before-completion','ran-outcome-unclear','started-not-completed') -contains $verdict) {
      $verdictText = "$verdictText $sdSentence"
    } elseif (@('rolled-back','failed-before-completion') -contains $verdict -and -not $sdSentence) {
      $verdictText = "$verdictText A SetupDiag result was detected but nothing could be read out of it, so the cause is NOT named here - open $sdPath yourself."
    }

    $out = [ordered]@{
      ok = $true; action = 'verify'
      verdict = $verdict
      verdictText = $verdictText
      ledgerReadable = [bool]$ledgerState.readable
      ledgerPath = $ledgerState.path
      ledgerSource = $ledgerState.source
      ledgerError = $ledgerState.error
      stateDir = $StateDir
      stateMigration = $ledgerState.migration
      namedCause = $setupDiag.namedCause
      os = $Os
      comparison = $comparison
      evidence = $evidence
      setupState = $setupState
      setupDiag = $setupDiag
      windowsOldPresent = [bool]$windowsOld.present
      rollbackNote = $(if ($windowsOld.present) { "C:\Windows.old exists (created $($windowsOld.timestamp)) - the previous OS is preserved for rollback (~10 days)." } else { 'C:\Windows.old was not found. After a completed repair install that means either the 10-day window has passed and Windows cleaned it up, or the upgrade never completed.' })
      logs = [ordered]@{
        downLevel  = (Join-Path $env:SystemRoot 'Panther')
        preReboot  = 'C:\$WINDOWS.~BT\Sources\Panther'
        postUpgrade = (Join-Path $env:SystemRoot 'Panther\NewOs')
        copyLogs   = $SetupLogDir
      }
      scheduling = [ordered]@{
        automatic = $false
        detail = 'FrameForge does NOT schedule this check to run itself after the upgrade restarts. fresh-image-repair.md section 6 step 8 describes a post-reboot RunOnce or scheduled task; FrameForge deliberately does not register one, because that means writing a persistent HKLM RunOnce entry or a scheduled task onto the machine as a side effect of pressing "repair" - a standing change that outlives the repair and survives if setup never completes, installed by a tool whose whole argument is that it does not leave things behind. So this is a manual step, and saying so plainly is the honest version.'
        whatYouDo = 'After the FINAL restart (setup does 2-3; verify again if the verdict below says in-progress), run this check again: the Verify step in the Repair Center, or "image.ps1 -Action verify" from the engine folder.'
        ifYouWantItAutomatic = 'Add it yourself, and it is yours to remove: reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v FrameForgeVerify /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path>\engine\image.ps1 -Action verify"  (RunOnce deletes its own entry when it fires).'
      }
      postChecks = @(
        [ordered]@{ engine = 'health.ps1'; invocation = 'health.ps1 -Action probe -Category system-files -Deep'; why = 'DISM CheckHealth/ScanHealth + sfc /verifyonly - the same read-only probe that diagnosed the problem must confirm the repair (doctrine rule 1).' },
        [ordered]@{ engine = 'repair.ps1'; catalogId = 'sfc-scannow'; why = 'sfc /scannow should now report no integrity violations against the fresh store.' },
        [ordered]@{ engine = 'repair.ps1'; catalogId = 'dism-restorehealth'; why = 'Only if system-files still reports corruption after the reinstall.' }
      )
    }
  }
}
}
} catch {
  # An unexpected TERMINATING error. Without this the script would exit with no JSON at
  # all, and the Electron host - which parses exactly one document per run - would see a
  # silent failure. Exit 1 WITH a document instead.
  $out = [ordered]@{
    ok        = $false
    action    = "$Action"
    errorCode = 'unhandled-exception'
    error     = "$($_.Exception.Message)"
    where     = "$($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)"
    type      = "$($_.Exception.GetType().FullName)"
  }
  $exitCode = 1
}

if ($null -eq $out) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'no-result'; error = "Action '$Action' produced no result document." }
  $exitCode = 1
}
Write-FFJson -InputObject $out -Depth 12
exit $exitCode
