<#
  FrameForge :: repair.ps1
  Measurement-driven repair engine. Every repair follows the doctrine:

      detect  ->  fix  ->  verify

  where detect and verify are the SAME read-only probe (engine/health.ps1 invoked as a
  child process, or a local read-only check for the two categories health.ps1 does not
  cover: time sync and winget). A repair REFUSES to run when detection says the
  subsystem is healthy — "nothing is broken here" is a first-class result, not an
  error — unless -Force is given.

  State is captured BEFORE any mutation wherever state exists (service start types,
  DNS/adapter configuration, registry values, service security descriptors, cache
  folder names) and written progressively — step by step — to
  %LOCALAPPDATA%\FrameForge\state\repairs-ledger.json (NOT the install tree - see the
  runtime-state note below), so a mid-repair failure reports exactly which step
  failed and what had already changed. Cache-clearing repairs rename to .bak-<timestamp>
  or move files to %LOCALAPPDATA%\FrameForge\state\backups\ instead of deleting (manual recovery stays
  possible), and are declared reversible:false in data/repairs.json.

  Deliberately SCOPED vs WinUtil: the Windows Update reset never deletes Policies
  hives, never removes GroupPolicy folders, and never runs secedit. The aggressive
  tier's sc.exe sdset captures the current descriptors via sdshow first.

  Repairs whose tier is 'aggressive' (or that are otherwise not recoverable from the
  ledger) carry restorePoint:"enforced" in the catalog: a System Restore checkpoint is
  created as the FIRST step, and if it cannot be created the repair aborts rather than
  proceeding unprotected. -NoRestorePoint is the explicit, documented opt-out.

  Usage:
    repair.ps1 -Action list                          # catalog + live detection status per repair
    repair.ps1 -Action selftest                      # catalog integrity: every health-checks.json
                                                     # fixesAvailable id resolves; whatItRuns matches
                                                     # the real step commands LINE BY LINE as text
                                                     # (normalized for %SystemRoot%-class tokens and
                                                     # the backup <timestamp> only). Read-only.
    repair.ps1 -Action preflight -Id <repairId>      # detection + exact commands + reversibility (no mutation)
    repair.ps1 -Action run -Id <repairId> [-DryRun] [-Force] [-NoRestorePoint] [-SourcePath <wim/esd[:index]> | <sxs folder>]
    repair.ps1 -Action undo -Id <repairId> [-DryRun] # only for reversible repairs, from the ledger
    repair.ps1 -Action ledger                        # the repair ledger

  Output is always a single JSON document on stdout — including for invalid input, which
  exits non-zero WITH a JSON error document (the Electron host parses exactly one doc per
  run, so a bare PowerShell binding error would break the contract; that is why -Action is
  validated in the body instead of with [ValidateSet]).
  -Json is accepted for interface symmetry. PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
  # NOTE: deliberately NOT [ValidateSet] — a binding failure would exit with no JSON at
  # all. Validated in the body so bad input still returns one JSON document.
  [string]$Action = 'list',
  [string]$Id,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$Json,
  # dism-restorehealth: an install.wim/install.esd, optionally :<index>.
  # enable-netfx3 / enable-netfx4-advsrvs / enable-directplay: a folder of feature
  # payload, i.e. <mounted media>\sources\sxs. Any other repair rejects it.
  [string]$SourcePath,
  [switch]$NoRestorePoint,
  [string]$DnsProvider = 'cloudflare'
)
$ValidActions = @('list','selftest','preflight','run','undo','ledger')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- culture pin (must precede EVERY other statement in this process) ----------------
# CORRECTION of a maintainer note that used to sit in ConvertTo-FFNormalizedCommand and was
# FACTUALLY WRONG. It said "PowerShell's own -match / -ieq operators are already culture-invariant
# and need no change." Only -eq / -ieq are. -match, -notmatch, -like, -replace and -split fold case
# with the CURRENT CULTURE, so under the Turkish/Azerbaijani dotted-I rules they stop matching plain
# ASCII. Measured here, Windows PowerShell 5.1, CurrentCulture forced to tr-TR:
#     ('info'         -match   'INFO')                -> False
#     ('INFO'         -match   '(?i)info')            -> False    (an inline (?i) does NOT help)
#     ('CLIENT'       -like    'Client*')             -> False
#     ('FILE'         -replace 'file','X')            -> 'FILE'   (no replacement happened)
#     ('is NOT DIRTY' -match   'is\s+NOT\s+Dirty')    -> False    (a real decision this file makes)
#     ('file'         -eq      'FILE')                -> True     (-eq really is invariant)
# Those are verdicts about a real machine, so the fix has to be structural rather than site-by-site.
# Pinning the THREAD's CurrentCulture to the invariant culture makes -match / -like / -replace fold
# case invariantly for the whole process.
# ORDERING IS LOAD-BEARING: PowerShell caches compiled Regex objects keyed by pattern + options, so a
# pattern first evaluated under tr-TR keeps the tr-TR casing table even after the culture changes.
# Measured: pin AFTER a match -> that pattern still returns False; pin BEFORE any match -> True. Hence
# this block runs before _lib.ps1 is dot-sourced and before anything else in this file executes.
# CurrentUICulture is deliberately NOT touched: it is what localizes the OS text this engine reads,
# and pretending that text is English would be the opposite of honest.
# Belt AND braces: the decision-critical text parses below also go through Test-FFIMatch /
# Test-FFILike, which pass CultureInvariant explicitly, so their correctness does not depend on this
# pin having succeeded (it is a property set on a non-core type, which ConstrainedLanguage blocks).
$script:FFCulturePinned = $false
try {
  [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
  $script:FFCulturePinned = $true
} catch {}

. (Join-Path $PSScriptRoot '_lib.ps1')

# ---------------- SCOPE RULE FOR EVERY FILE-LEVEL VARIABLE IN THIS ENGINE ----------------
# Any file-level variable that is EVER read back as $script:<name> must also be ASSIGNED as
# $script:<name>. This is not style — it is what makes the engine work under BOTH of the Electron
# host's invocation modes.
#
#   -File mode           the file is a script, so its top level IS the script scope: `$X = 1` and
#                        `$script:X` are the same variable. Both spellings work.
#   scriptblock mode     when a policy scope blocks script FILES, electron/main.js runs the engine
#                        as `& ([scriptblock]::Create($text)) <args>` (see psArgsForMode there).
#                        `&` gives that scriptblock a NEW CHILD scope, so a bare `$X = 1` at its top
#                        level lands in that child scope while `$script:X` still resolves to the
#                        OUTER script/global scope — a different variable, and always empty.
# Measured, PS 5.1: inside `& ([scriptblock]::Create('$Foo=1; function f{ $script:Foo }; f'))`,
# f returns EMPTY. Nine variables here were assigned bare and read back through $script:
# (IsAdmin, StateDir, BackupDir, DnsProviders, DefaultDnsProviderKey, OptionalFeatureRepairs,
# WsusIdentityValues, WuPolicyKey, SystemRestoreKey), so in scriptblock mode elevation read as
# $false, the backup destination and the WSUS policy key were empty paths, and the optional-feature
# repairs stopped recognising themselves. All nine are qualified now; keep it that way.
$script:IsAdmin = Test-Admin

# ---------------- culture-invariant text matching ----------------
# DUPLICATED DELIBERATELY, byte for byte, in engine/image.ps1 (search for "Test-FFIMatch" there).
# They are not in engine/_lib.ps1 because health.ps1 owns that file and the fixers for these files
# work in parallel; duplicating with a comment naming the other site is the coordination-free option.
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

$Root            = Split-Path -Parent $PSScriptRoot
$CatalogPath     = Join-Path $Root 'data\repairs.json'
$HealthCatalog   = Join-Path $Root 'data\health-checks.json'
$HealthPath      = Join-Path $PSScriptRoot 'health.ps1'

# ---------------- runtime state location ----------------
# State NEVER lives in the install tree. This is the same rule, and deliberately the same folder,
# that engine.ps1:34-45 already uses: a per-machine install under %ProgramFiles%, a read-only or
# network copy, Controlled Folder Access, or a OneDrive Known-Folder-Move profile all make
# <install>\data\state unwritable — and an engine that cannot write its ledger cannot undo anything
# (doctrine rule 3). Concretely, this file has FIVE non-admin repairs (wu-repair-reinstall,
# store-cache-reset, store-reregister, shell-restart, temp-clean) that a standard user could not run
# at all on a normal per-machine install, and the qmgr*.dat / spool backups that are the ONLY
# recovery path for the reversible:false repairs lived in the install tree too, where an uninstall
# destroys them.
#
# OVERRIDE CONTRACT — $env:FRAMEFORGE_STATE_DIR  (consumed by engine\test\, documented for it here)
# ----------------------------------------------------------------------------------------------
# Moving state out of the install tree was right, but it also moved it out of the TEST SANDBOX:
# New-FFSandbox copies engine\ + data\ to %TEMP% and relies on the engine resolving everything
# relative to its own location, so once the ledger became an absolute %LOCALAPPDATA% path a suite
# run wrote to the INVOKING USER'S REAL repair ledger, and ten SAFETY assertions of the form
# `Assert-False (Test-Path "<sandbox>\data\state\repairs-ledger.json")` began checking a path the
# engine can never write — they passed no matter what the engine did.
#
# THE CONTRACT, exactly:
#   * If $env:FRAMEFORGE_STATE_DIR is set to a non-blank value, THAT directory is the state root,
#     verbatim. It holds repairs-ledger.json and backups\ exactly as %LOCALAPPDATA%\FrameForge\state
#     otherwise would. Relative paths are resolved by Windows against the process working directory;
#     pass an absolute path.
#   * It is read ONCE, here, before anything is created — so every ledger read, ledger write, backup
#     and log in this file follows it. There is NO other state root in repair.ps1.
#   * A set-but-unusable override is a hard, reported failure (Initialize-FFStateDir returns ok=false
#     and every write path refuses). It NEVER silently falls back to %LOCALAPPDATA%: a test that
#     believes it is sandboxed must not be able to write the real ledger by accident.
#   * When the override is in force the v1 install-tree migration is SKIPPED. The override names the
#     state root explicitly, and in a sandbox the legacy path can be the same directory — copying a
#     file onto itself, or seeding a "migrated" ledger the test never asked for.
#   * Both the resolved root and where it came from are reported in `-Action ledger`
#     (stateDir / stateDirSource) so a run can prove which one it used.
# Every consumer of the state root reads it through $script:StateDir / $script:LedgerPath /
# $script:BackupDir; nothing recomputes it from $env:LOCALAPPDATA.
$script:StateDirSource = 'localappdata'
$StateOverride = "$($env:FRAMEFORGE_STATE_DIR)".Trim()
$StateBase = $env:LOCALAPPDATA
if (-not $StateBase) { $StateBase = $env:TEMP; $script:StateDirSource = 'temp-fallback' }
# Plain concatenation, not Join-Path: Join-Path resolves the PSDrive and THROWS under
# $ErrorActionPreference='Stop' when the root is bogus, which would kill the script before it could
# emit the one JSON document the Electron host parses. (Same reasoning, same comment, as engine.ps1.)
if ($StateOverride) {
  $script:StateDir      = $StateOverride.TrimEnd('\')
  $script:StateDirSource = 'env-override'
} else {
  $script:StateDir      = ($StateBase.TrimEnd('\')) + '\FrameForge\state'
}
$script:BackupDir  = $script:StateDir + '\backups'
$LedgerPath        = $script:StateDir + '\repairs-ledger.json'
# v1 wrote both of these into the install tree. They are MIGRATED (copied, never moved) on first use
# so an existing record is never orphaned; see Initialize-FFStateDir.
$LegacyStateDir  = Join-Path $Root 'data\state'
$LegacyLedger    = Join-Path $LegacyStateDir 'repairs-ledger.json'
$LegacyBackupDir = Join-Path $LegacyStateDir 'backups'

# DNS resolvers offered by dns-change-resolver (WinUtil's config/dns.json provider set).
# 'dhcp' is the escape hatch back to automatic/DHCP-provided servers.
$script:DnsProviders = [ordered]@{
  'cloudflare' = [ordered]@{ name='Cloudflare';        ipv4=@('1.1.1.1','1.0.0.1');       ipv6=@('2606:4700:4700::1111','2606:4700:4700::1001') }
  'google'     = [ordered]@{ name='Google';            ipv4=@('8.8.8.8','8.8.4.4');       ipv6=@('2001:4860:4860::8888','2001:4860:4860::8844') }
  'quad9'      = [ordered]@{ name='Quad9';             ipv4=@('9.9.9.9','149.112.112.112'); ipv6=@('2620:fe::fe','2620:fe::9') }
  'adguard'    = [ordered]@{ name='AdGuard';           ipv4=@('94.140.14.14','94.140.15.15'); ipv6=@('2a10:50c0::ad1:ff','2a10:50c0::ad2:ff') }
  'opendns'    = [ordered]@{ name='OpenDNS Home';      ipv4=@('208.67.222.222','208.67.220.220'); ipv6=@('2620:119:35::35','2620:119:53::53') }
  'dhcp'       = [ordered]@{ name='Automatic (DHCP)';  ipv4=@();                          ipv6=@() }
}
# MUST stay equal to the -DnsProvider parameter default above. selftest builds the DNS
# step list with this key so the catalog is always measured against a default invocation,
# whatever -DnsProvider the caller happened to pass to selftest itself.
$script:DefaultDnsProviderKey = 'cloudflare'

# Optional Windows features FrameForge treats as REPAIRS (an application refuses to start
# without them) rather than as capability additions. See optionalFeaturesNote in
# data/repairs.json for what is deliberately not offered and why.
$script:OptionalFeatureRepairs = @('enable-netfx3','enable-netfx4-advsrvs','enable-directplay')

# ---------------- catalog ----------------

function Load-Catalog {
  if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "repairs.json not found at $CatalogPath" }
  # -Encoding UTF8 is load-bearing: repairs.json has no BOM, and PS 5.1 would
  # otherwise decode it as Windows-1252 and mangle every em-dash in user-facing copy.
  #
  # -LiteralPath, not -Path, and the same goes for EVERY file cmdlet in this file that touches a
  # path the user can influence. -Path is a WILDCARD parameter: an install directory containing
  # '[' or ']' (e.g. "C:\Program Files [beta]\FrameForge v1") makes the pattern match nothing, the
  # FileSystem provider is then never resolved, its DYNAMIC parameters (-Raw among them) are never
  # added, and binding fails with the meaningless "A parameter cannot be found that matches
  # parameter name 'Raw'". Measured before the fix: from such a path, repair.ps1 -Action list,
  # preflight, run, undo, ledger and selftest ALL died with that message — the entire repair engine
  # — while health.ps1, engine.ps1, image.ps1 and compat.ps1 succeeded from the same folder.
  # engine.ps1:69-71 documents the same hazard by name.
  (Get-Content -Raw -Encoding UTF8 -LiteralPath $CatalogPath | ConvertFrom-Json).repairs
}
function Get-RepairById { param($RepairId) @(Load-Catalog) | Where-Object { $_.id -eq $RepairId } | Select-Object -First 1 }

# ---------------- ledger (state-capture journal, style of v0.1 applied.json) ----------------

$script:StateMigration = $null

function Initialize-FFStateDir {
  <#
    Makes the state root usable, and ONCE copies a v1 ledger that was written into the install tree
    so the move does not orphan an existing record.

    COPY, never move: the in-tree file is left exactly as it was found, so a half-finished migration
    can never lose the only evidence of what a repair changed (doctrine rule 3).
    The legacy backups folder (qmgr*.dat, spool files — the sole recovery path for the
    reversible:false repairs) is copied for the same reason.

    STATE ROOT: whatever $script:StateDir resolved to at the top of this file — either
    %LOCALAPPDATA%\FrameForge\state or the $env:FRAMEFORGE_STATE_DIR override (see the override
    contract there). Nothing here recomputes it, so the sandbox override cannot be bypassed.

    Returns @{ ok; stateDir; stateDirSource; error; migrated; migratedFrom; note }. ok=$false is a
    REFUSAL signal: a caller that is about to write must abort rather than mutate unrecorded.
  #>
  if ($null -ne $script:StateMigration) { return $script:StateMigration }
  $res = [ordered]@{ ok = $false; stateDir = $StateDir; stateDirSource = "$($script:StateDirSource)"; error = $null; migrated = $false; migratedFrom = $null; note = $null }
  try {
    # New-Item has NO -LiteralPath in PS 5.1 (measured: (Get-Command New-Item).Parameters has no
    # such key). Measured too: `New-Item -ItemType Directory -Force -Path "<...>\a [b] c"` SUCCEEDS —
    # it is the FileSystem provider's *dynamic* parameters (-Raw on Get-Content, -Encoding on
    # Set-Content) that go missing when a bracketed -Path resolves to nothing, and New-Item takes
    # none of those. So -Path is correct and safe here; every read/write below uses -LiteralPath.
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir -ErrorAction Stop | Out-Null }
    $res.ok = $true
  } catch {
    $where = 'Check that %LOCALAPPDATA% is writable (Controlled Folder Access and some roaming-profile policies block it), then try again.'
    if ($script:StateDirSource -eq 'env-override') {
      # NEVER fall back to the real %LOCALAPPDATA% ledger here: a caller that set the override
      # (a test sandbox, an embedder) must fail loudly rather than silently write the user's own.
      $where = "That path came from `$env:FRAMEFORGE_STATE_DIR, so FrameForge used it and nothing else — it does NOT fall back to %LOCALAPPDATA%. Point the variable at a writable directory, or clear it."
    }
    $res.error = ("FrameForge could not create or reach its state folder at '$StateDir': $($_.Exception.Message). " +
                  'The repair ledger lives there, and a repair that cannot record what it changed must not change anything. ' +
                  $where)
    $script:StateMigration = $res
    return $res
  }
  if ($script:StateDirSource -eq 'env-override') {
    # The override names the state root explicitly (a test sandbox, an embedder, a portable
    # install). Migrating the install tree into it would seed a record nobody asked for — and in a
    # sandbox, where the legacy path IS this path, it would be a copy of a file onto itself.
    $res.note = "State root taken from `$env:FRAMEFORGE_STATE_DIR ('$StateDir'); the v1 install-tree migration is skipped for an explicitly named state root."
    $script:StateMigration = $res
    return $res
  }
  try {
    if ((Test-Path -LiteralPath $LegacyLedger -PathType Leaf) -and -not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
      Copy-Item -LiteralPath $LegacyLedger -Destination $LedgerPath -Force -ErrorAction Stop
      $res.migrated = $true
      $res.migratedFrom = $LegacyLedger
      $res.note = "A v1 repair ledger was found in the install tree and COPIED to '$LedgerPath'. The original was left in place on purpose; nothing was deleted."
    }
  } catch { $res.note = "A v1 repair ledger at '$LegacyLedger' could NOT be copied to the new state folder: $($_.Exception.Message). It is still readable where it is." }
  try {
    if ((Test-Path -LiteralPath $LegacyBackupDir -PathType Container) -and -not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
      Copy-Item -LiteralPath $LegacyBackupDir -Destination $BackupDir -Recurse -Force -ErrorAction Stop
      $res.note = "$($res.note) Backups from the install tree were copied to '$BackupDir' as well.".Trim()
    }
  } catch { $res.note = "$($res.note) Backups at '$LegacyBackupDir' could not be copied: $($_.Exception.Message).".Trim() }
  $script:StateMigration = $res
  return $res
}

function Get-RepairLedgerState {
  <#
    The ledger, WITH the read outcome attached.

    DOCTRINE BUG this replaces: the old Load-RepairLedger caught every read failure and returned
    @(), so an UNREADABLE ledger was reported to the user as an EMPTY one — "no repairs recorded"
    for a file holding a full record. Measured: from an install path containing brackets,
    `-Action ledger` returned {ok:true,count:0} while data/state/repairs-ledger.json held 4350 bytes.
    That is doctrine rule 2 broken on the single record `undo` depends on.

    Returns @{ readable; entries; count; path; source; error }. readable=$false means COULD NOT BE
    READ and entries is $null — never an empty array standing in for an unread file.
  #>
  $mig = Initialize-FFStateDir
  $out = [ordered]@{ readable = $false; entries = $null; count = $null; path = $LedgerPath; source = $null; error = $null; migration = $mig }
  # Prefer the new location; fall back to the in-tree v1 file so a failed migration still SHOWS the
  # record instead of silently reporting an empty ledger.
  $read = $LedgerPath; $src = 'state-dir'
  if (-not (Test-Path -LiteralPath $read -PathType Leaf)) {
    # The install-tree fallback exists for ONE situation: a v1 ledger that the migration could not
    # copy. It is switched off when $env:FRAMEFORGE_STATE_DIR named the state root, because that
    # caller (a test sandbox, an embedder) said where its state lives and must not be handed a
    # record from somewhere else — the override contract says it never falls back.
    $useLegacy = ($script:StateDirSource -ne 'env-override') -and (Test-Path -LiteralPath $LegacyLedger -PathType Leaf)
    if ($useLegacy) { $read = $LegacyLedger; $src = 'legacy-install-tree' }
    elseif (-not $mig.ok) {
      # The state root itself could not be created or reached. "No file there" is then not the same
      # statement as "no repair has run", and reporting count=0 would be exactly the empty-ledger
      # lie the rest of this function exists to prevent.
      $out.error = ("No repair ledger could be read because the state folder itself is unusable: $($mig.error) " +
                    "That is NOT the same as 'no repairs recorded' — FrameForge cannot say what has or has not been run until that path works.")
      return $out
    } else {
      $out.readable = $true; $out.entries = @(); $out.count = 0; $out.source = 'absent'
      return $out
    }
  }
  $out.path = $read; $out.source = $src
  $raw = $null
  try { $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $read -ErrorAction Stop }
  catch {
    $out.error = "The repair ledger at '$read' exists but could not be READ: $($_.Exception.Message)"
    return $out
  }
  if ($null -eq $raw -or -not ("$raw".Trim())) {
    # A zero-byte file is a truncated write, not "no repairs" — say so rather than guessing.
    $out.error = "The repair ledger at '$read' is empty (0 bytes). That is a truncated or interrupted write, not a record that no repair has run."
    return $out
  }
  $parsed = $null
  try { $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
  catch {
    $out.error = "The repair ledger at '$read' could not be parsed as JSON: $($_.Exception.Message). It is $((("$raw").Length)) characters long, so there IS a record in it — do not treat this as 'no repairs recorded'."
    return $out
  }
  if ($null -eq $parsed) { $out.readable = $true; $out.entries = @(); $out.count = 0; return $out }
  $out.readable = $true
  $out.entries = @($parsed)
  $out.count = @($parsed).Count
  return $out
}

function Load-RepairLedger {
  <# The entries, or a THROW naming why they could not be read. Every caller that goes on to write
     or to undo runs through here, so an unreadable ledger aborts before anything is mutated. #>
  $s = Get-RepairLedgerState
  if (-not $s.readable) { throw "$($s.error) FrameForge will not act on a ledger it could not read: an unreadable ledger is not an empty one." }
  return @($s.entries)
}

function Save-RepairLedger {
  param($Entries)
  $mig = Initialize-FFStateDir
  if (-not $mig.ok) { throw $mig.error }
  $arr = @($Entries)
  if ($arr.Count -eq 0) { Set-Content -LiteralPath $LedgerPath -Value '[]' -Encoding UTF8; return }
  # Serialize each entry independently and join — deterministic JSON array regardless of
  # PS 5.1 single-element ConvertTo-Json quirks (same pattern as engine.ps1's ledger).
  $items = foreach ($r in $arr) { ConvertTo-Json -InputObject $r -Depth 14 }
  Set-Content -LiteralPath $LedgerPath -Value ("[`r`n" + (($items) -join ",`r`n") + "`r`n]") -Encoding UTF8
}
function Sync-LedgerEntry {
  # Upsert by runId. Called after every step so the ledger always reflects progress —
  # a crash mid-repair leaves an honest partial record, not silence.
  param($Entry)
  $others = @(Load-RepairLedger | Where-Object { "$($_.runId)" -ne "$($Entry.runId)" })
  Save-RepairLedger ($others + @($Entry))
}

# ---------------- detection (health.ps1 as the single source of probe truth) ----------------

$script:ProbeCache = @{}

function Invoke-HealthProbe {
  <# Runs health.ps1 -Action probe -Category X in a child PowerShell (its stdout is a
     single JSON doc written via [Console]::Out, which in-process invocation cannot
     capture — and its trailing `exit` would kill us). Cached per category+depth so a
     `list` does not probe the same category twice. #>
  param([string]$Category, [switch]$Deep, [switch]$Fresh)
  $key = "$Category|$([bool]$Deep)"
  if (-not $Fresh -and $script:ProbeCache.ContainsKey($key)) { return $script:ProbeCache[$key] }
  if (-not (Test-Path -LiteralPath $HealthPath)) { return $null }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$HealthPath,'-Action','probe','-Category',$Category)
  if ($Deep) { $argList += '-Deep' }
  $doc = $null
  try {
    $raw = & $psExe @argList
    $doc = ((@($raw) | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  } catch { $doc = $null }
  $script:ProbeCache[$key] = $doc
  return $doc
}

# Detection 'reason' vocabulary (only meaningful when state = 'indeterminate'):
#   probe-failure   the probe could not run / its output could not be parsed  -> REFUSE
#   not-applicable  the subsystem this repair targets does not exist here     -> REFUSE
#   unparseable     the probe ran but its answer could not be read            -> REFUSE
#   needs-admin     the probe ran but needed elevation to decide              -> may proceed
#   shallow-probe   only the fast probe ran; the deciding deep probe has not  -> may proceed
#   user-initiated  the probe read the real state, but whether that state is
#                   a PROBLEM is a question only the user can answer (the
#                   optional-feature repairs: "NetFx3 is disabled" is the
#                   Windows default, not a fault)                             -> may proceed
# The distinction is load-bearing: a FAILED probe must never be treated as "go ahead",
# which is what a single 'indeterminate' bucket silently did.
$script:RefuseReasons = @('probe-failure','not-applicable','unparseable')

# ---------------- locale- and environment-independent readers ----------------
# Everything below reads STRUCTURE (registry values, CIM properties, numeric event ids,
# exit codes) rather than command prose, because command prose is localized on ~70% of
# Windows installs. Where a text parse is genuinely unavoidable it is layered exactly
# like image.ps1's language detection: the English-only parse is DOCUMENTED as such and
# is never the only rung, and the last rung is always an honest "could not determine"
# rather than a confident default.

function Get-FFDomainState {
  <#
    Domain membership from CIM — Win32_ComputerSystem.PartOfDomain is a boolean, not text.
    readable=$false means the query failed: callers must then treat domain membership as
    UNKNOWN and take the cautious branch, never assume a standalone workstation.
  #>
  $out = [ordered]@{ partOfDomain = $null; domain = $null; readable = $false; error = $null }
  try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $out.partOfDomain = [bool]$cs.PartOfDomain
    $out.domain = "$($cs.Domain)"
    $out.readable = $true
  } catch { $out.error = "$($_.Exception.Message)" }
  $out
}

function Get-W32TimeConfig {
  <#
    The Windows Time peer list and sync type, read from the REGISTRY, where Windows stores
    them verbatim and UNLOCALIZED:
      HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters
        NtpServer  REG_SZ   e.g. 'time.windows.com,0x9'
        Type       REG_SZ   'NTP' | 'NT5DS' | 'AllSync' | 'NoSync'
    `w32tm /query /configuration` prints the same two values behind the LOCALIZED labels
    'NtpServer:' and 'Type:', which is why that parse is only ever a documented
    English-only second rung here — it can never be the primary read.

    readable=$false means NEITHER rung answered. That is a first-class result: the ntp
    capture records it, and undo REFUSES rather than applying an assumed default.
  #>
  $out = [ordered]@{ ntpServer = $null; type = $null; source = $null; readable = $false; error = $null }
  $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
  try {
    $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $ns = ''; $ty = ''
    try { $ns = "$($p.NtpServer)" } catch {}
    try { $ty = "$($p.Type)" } catch {}
    if ($ns -match '\S') { $out.ntpServer = $ns.Trim() }
    if ($ty -match '\S') { $out.type      = $ty.Trim() }
    if ($out.ntpServer -or $out.type) {
      $out.source = 'registry'
      $out.readable = $true
      return $out
    }
  } catch { $out.error = "$($_.Exception.Message)" }
  # Rung 2 — DOCUMENTED ENGLISH-ONLY. The labels below exist only on an English UI, so
  # this rung silently does nothing everywhere else. That is fine: it is a supplement to
  # the registry read, never a substitute for it.
  try {
    $cfg = (@(cmd /c "w32tm /query /configuration 2>nul") | ForEach-Object { "$_" }) -join "`n"
    # Invariant [regex] rather than -match: -match's case folding is culture-bound, and this
    # rung's whole job is to recognise English labels.
    $mNtp = [regex]::Match($cfg, 'NtpServer:\s*([^\r\n\(]+)', $script:FFReIC)
    $mTyp = [regex]::Match($cfg, 'Type:\s*([^\r\n\(]+)',      $script:FFReIC)
    if ($mNtp.Success) { $out.ntpServer = $mNtp.Groups[1].Value.Trim() }
    if ($mTyp.Success) { $out.type      = $mTyp.Groups[1].Value.Trim() }
    if ($out.ntpServer -or $out.type) { $out.source = 'w32tm-configuration-text-english'; $out.readable = $true }
  } catch {}
  $out
}

# The Windows product's ApplicationID in the Software Licensing service. Not localized, not
# version-dependent; it is what separates Windows rows from Office rows in the same class.
$script:WindowsSlpApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'

function Get-FFLicenseState {
  <#
    The licensing picture, read from SoftwareLicensingProduct.

    WHAT THIS REPLACES: the old capture ran
        SELECT ... WHERE ApplicationID = '<windows>' AND PartialProductKey IS NOT NULL
    and then took `Select-Object -First 1`. CIM does not promise an order, so on any machine with
    more than one keyed Windows row — a channel transition, a KMS client that also carries a
    digital licence, an Enterprise subscription over a Pro base — that -First 1 was an ARBITRARY
    pick reported as THE licence status. Measured on this machine: the query returns 61 Windows
    rows, of which exactly 1 carries a PartialProductKey, so the old code was right here BY LUCK.
    Every keyed row is now enumerated and reported; `primary` states which row the verdict came
    from and why.

    CHANNEL is read structurally, best rung first:
      1. ProductKeyChannel — a short invariant token ('Retail', 'OEM:DM', 'Volume:GVLK',
         'Volume:MAK', 'Volume:CSVLK'). Measured on this machine: 'Retail'.
      2. the CHANNEL TOKEN inside Description ('... RETAIL channel', 'VOLUME_KMSCLIENT',
         'VOLUME_MAK', 'SUBSCRIPTION'). These are invariant identifiers embedded in the string,
         not translated prose, but it is still a text rung so it sits below rung 1.
      3. 'unknown'. Never guessed — an unknown channel is reported as unknown.

    Returns @{ readable; error; rows; keyedRows; primary; channel; channelSource; status;
               statusText; product; kmsHost }.
    readable=$false means the licensing service could not be queried at all; status stays $null.
  #>
  $map = @{ 0='Unlicensed'; 1='Licensed'; 2='Out-of-box grace'; 3='Out-of-tolerance grace'; 4='Non-genuine grace'; 5='Notification'; 6='Extended grace' }
  $out = [ordered]@{
    readable = $false; error = $null; rows = @(); keyedRows = 0; primary = $null
    channel = 'unknown'; channelSource = $null; status = $null; statusText = $null; product = $null
    kmsHost = $null; primaryChosenBy = $null
  }
  $lics = @()
  try {
    $q = "SELECT Name, Description, LicenseStatus, LicenseStatusReason, PartialProductKey, ProductKeyChannel, LicenseFamily, GracePeriodRemaining, DiscoveredKeyManagementServiceMachineName FROM SoftwareLicensingProduct WHERE ApplicationID = '$($script:WindowsSlpApplicationId)' AND PartialProductKey IS NOT NULL"
    $lics = @(Get-CimInstance -Query $q -ErrorAction Stop)
    $out.readable = $true
  } catch { $out.error = "$($_.Exception.Message)"; return $out }
  $out.keyedRows = $lics.Count
  foreach ($l in $lics) {
    $st = $null
    try { $st = [int]$l.LicenseStatus } catch {}
    $out.rows += [ordered]@{
      name              = "$($l.Name)"
      description       = "$($l.Description)"
      licenseFamily     = "$($l.LicenseFamily)"
      productKeyChannel = "$($l.ProductKeyChannel)"
      partialProductKey = "$($l.PartialProductKey)"
      licenseStatus     = $st
      licenseStatusText = $(if ($null -ne $st -and $map.ContainsKey($st)) { $map[$st] } else { $null })
      licenseStatusReason = $(try { "0x{0:X8}" -f ([uint32]$l.LicenseStatusReason) } catch { $null })
      gracePeriodMinutes = $(try { [int]$l.GracePeriodRemaining } catch { $null })
      kmsHost           = $(if ("$($l.DiscoveredKeyManagementServiceMachineName)" -match '\S') { "$($l.DiscoveredKeyManagementServiceMachineName)" } else { $null })
    }
  }
  if ($out.rows.Count -eq 0) {
    $out.error = 'The Software Licensing service answered, but this machine has no Windows product row carrying a partial product key — there is no licence here to retry.'
    return $out
  }
  # Prefer a Licensed row; otherwise the row in the most advanced non-zero state; otherwise the
  # first. Whichever it is, primaryChosenBy records the rule so the pick is never silent.
  $licensed = @($out.rows | Where-Object { $_.licenseStatus -eq 1 })
  if ($licensed.Count -gt 0) { $out.primary = $licensed[0]; $out.primaryChosenBy = "the row reporting LicenseStatus 1 (Licensed) out of $($out.rows.Count) keyed row(s)" }
  else {
    $ranked = @($out.rows | Sort-Object { -([int]("0" + "$($_.licenseStatus)")) })
    $out.primary = $ranked[0]
    $out.primaryChosenBy = "no keyed row reports Licensed; the row in the highest LicenseStatus state was taken out of $($out.rows.Count) keyed row(s)"
  }
  $out.status     = $out.primary.licenseStatus
  $out.statusText = $out.primary.licenseStatusText
  $out.product    = $out.primary.name
  $out.kmsHost    = $out.primary.kmsHost

  $pkc = "$($out.primary.productKeyChannel)"
  $desc = "$($out.primary.description)"
  if     (Test-FFIMatch $pkc '^Volume:GVLK$')  { $out.channel = 'kms-client';   $out.channelSource = 'product-key-channel' }
  elseif (Test-FFIMatch $pkc '^Volume:CSVLK$') { $out.channel = 'kms-host';     $out.channelSource = 'product-key-channel' }
  elseif (Test-FFIMatch $pkc '^Volume:MAK$')   { $out.channel = 'mak';          $out.channelSource = 'product-key-channel' }
  elseif (Test-FFIMatch $pkc '^Retail')        { $out.channel = 'retail';       $out.channelSource = 'product-key-channel' }
  elseif (Test-FFIMatch $pkc '^OEM')           { $out.channel = 'oem';          $out.channelSource = 'product-key-channel' }
  elseif (Test-FFIMatch $desc 'SUBSCRIPTION')  { $out.channel = 'subscription'; $out.channelSource = 'description-channel-token' }
  elseif (Test-FFIMatch $desc 'VOLUME_KMSCLIENT') { $out.channel = 'kms-client'; $out.channelSource = 'description-channel-token' }
  elseif (Test-FFIMatch $desc 'VOLUME_MAK')    { $out.channel = 'mak';          $out.channelSource = 'description-channel-token' }
  elseif (Test-FFIMatch $desc 'RETAIL')        { $out.channel = 'retail';       $out.channelSource = 'description-channel-token' }
  elseif (Test-FFIMatch $desc 'OEM_')          { $out.channel = 'oem';          $out.channelSource = 'description-channel-token' }
  # A SUBSCRIPTION token anywhere in the keyed rows beats a base channel: subscription activation
  # rides on top of a Pro/Enterprise base licence, and it is the thing /ato cannot fix.
  if ($out.channel -ne 'subscription') {
    foreach ($r in $out.rows) {
      if (Test-FFIMatch "$($r.description) $($r.licenseFamily) $($r.name)" 'SUBSCRIPTION') {
        $out.channel = 'subscription'; $out.channelSource = 'subscription-row-present'; break
      }
    }
  }
  $out
}

function Get-WuManagementState {
  <#
    Is this machine's update pipeline MANAGED by something other than the user? Three
    structural signals, none of them text:
      - HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate  WUServer / WUStatusServer /
        UseWUServer / TargetGroup   (WSUS pinning, set by Group Policy)
      - HKLM\SOFTWARE\Microsoft\Enrollments\*\ProviderID        (MDM / Intune enrolment)
      - Win32_ComputerSystem.PartOfDomain                       (domain membership)
    The codebase never read any of these, which is why wu-reset told WSUS-managed machines
    that Windows Update "will re-register with Microsoft" — false on exactly those
    machines. readable=$false on the policy read means UNKNOWN, and the steps that consult
    this take the cautious branch when they cannot tell.
  #>
  $out = [ordered]@{
    wsusServer = $null; wsusStatusServer = $null; useWUServer = $null; targetGroup = $null
    wsusManaged = $null; mdmEnrolled = $null; mdmProviders = @()
    partOfDomain = $null; domain = $null
    managed = $null; policyReadable = $false; error = $null
  }
  $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  try {
    if (Test-Path -LiteralPath $policyKey) {
      $p = Get-ItemProperty -LiteralPath $policyKey -ErrorAction Stop
      try { if ("$($p.WUServer)"       -match '\S') { $out.wsusServer       = "$($p.WUServer)".Trim() } } catch {}
      try { if ("$($p.WUStatusServer)" -match '\S') { $out.wsusStatusServer = "$($p.WUStatusServer)".Trim() } } catch {}
      try { if ("$($p.TargetGroup)"    -match '\S') { $out.targetGroup      = "$($p.TargetGroup)".Trim() } } catch {}
      try { if ($null -ne $p.UseWUServer) { $out.useWUServer = [int]$p.UseWUServer } } catch {}
    }
    $out.policyReadable = $true
    $out.wsusManaged = [bool]$out.wsusServer
  } catch { $out.error = "$($_.Exception.Message)" }
  # MDM enrolment. CAUTION, verified on a stock consumer Windows 11 Pro box:
  # HKLM\SOFTWARE\Microsoft\Enrollments carries ~35 built-in subkeys out of the factory,
  # three of which have a ProviderID ('Deploy Authority', 'Cloud Authority', 'Local
  # Authority'). Treating "a ProviderID exists" as enrolment therefore reported EVERY home
  # PC as managed, which would have skipped the WinHTTP proxy reset and the WSUS identity
  # step on machines that are not managed at all — dropping a working capability, which is
  # exactly what the doctrine forbids. A real enrolment has a DiscoveryServiceFullURL (the
  # management endpoint it talks to); the stubs never do.
  if (Get-Command -Name 'Get-FFEdition' -ErrorAction SilentlyContinue) {
    try {
      $ed = Get-FFEdition
      if ($null -ne $ed.isMdmEnrolled) { $out.mdmEnrolled = [bool]$ed.isMdmEnrolled }
    } catch {}
  }
  try {
    $provs = @()
    $realEnrollments = 0
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
      try {
        $e = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
        $url = ''; try { $url = "$($e.DiscoveryServiceFullURL)" } catch {}
        if (-not ($url -match '\S')) { continue }   # a stub, not an enrolment
        $realEnrollments++
        $provider = ''
        try { $provider = "$($e.ProviderID)" } catch {}
        if ($provider -match '\S') { $provs += $provider } else { $provs += "(enrolled: $url)" }
      } catch {}
    }
    $out.mdmProviders = @($provs | Select-Object -Unique)
    if ($null -eq $out.mdmEnrolled) { $out.mdmEnrolled = ($realEnrollments -gt 0) }
  } catch {}
  $dom = Get-FFDomainState
  $out.partOfDomain = $dom.partOfDomain
  $out.domain = $dom.domain
  if ($out.policyReadable) {
    $out.managed = [bool]($out.wsusManaged -or $out.mdmEnrolled -or ($out.partOfDomain -eq $true))
  }
  $out
}

function Get-VolumeDirtyState {
  <#
    The NTFS dirty bit, WITHOUT deciding anything from `fsutil dirty query` prose ('is
    Dirty' / 'is NOT Dirty' are English). dirty=$null / readable=$false means COULD NOT
    DETERMINE and must never be read as "clean".

    Rung 1 is _lib.ps1's Get-FFVolumeDirtyBit, which asks the file system directly through
    FSCTL_IS_VOLUME_DIRTY — completely locale-independent, and readable unelevated. This
    wrapper exists so repair.ps1 keeps one small shape (drive / dirty / readable / source /
    error) and still works if that helper is not present in an older _lib.ps1; rungs 2 and 3
    below are the same ladder in miniature.
  #>
  param([string]$DriveLetter = $env:SystemDrive)
  $dl = "$DriveLetter".Trim().TrimEnd('\')
  if ($dl -match '^[A-Za-z]$') { $dl = "$dl`:" }
  $out = [ordered]@{ drive = $dl; dirty = $null; readable = $false; source = $null; error = $null }
  if (Get-Command -Name 'Get-FFVolumeDirtyBit' -ErrorAction SilentlyContinue) {
    try {
      $r = Get-FFVolumeDirtyBit -Volume $dl -IsAdmin ([bool]$script:IsAdmin)
      $out.source = "$($r.source)"
      $out.error = "$($r.detail)"
      if ($null -ne $r.dirty) { $out.dirty = [bool]$r.dirty; $out.readable = $true }
      return $out
    } catch { $out.error = "$($_.Exception.Message)" }
  }
  # Rung 2 — CIM. Win32_Volume.DirtyBitSet is a boolean, but it needs elevation and comes
  # back $null unelevated.
  try {
    $v = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$dl'" -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $v -and $null -ne $v.DirtyBitSet) {
      $out.dirty = [bool]$v.DirtyBitSet
      $out.readable = $true
      $out.source = 'cim-win32volume-dirtybitset'
      return $out
    }
  } catch { $out.error = "$($_.Exception.Message)" }
  # Rung 3 — DOCUMENTED ENGLISH-ONLY, and only ever a supplement. The negative must be
  # tested first: 'is NOT Dirty' contains 'Dirty'.
  try {
    $o = & (Join-Path $env:SystemRoot 'System32\fsutil.exe') dirty query $dl 2>&1
    $txt = ((@($o) | ForEach-Object { "$_" }) -join ' ')
    # Test-FFIMatch, not -match. MEASURED under tr-TR: ('is NOT DIRTY' -match 'is\s+NOT\s+Dirty')
    # is False, because the dotted-I folding rules break the 'i' in 'Dirty'. That turned a clean
    # volume into "could not determine" — and, worse, would have done the same for 'is Dirty'.
    if     (Test-FFIMatch $txt 'is\s+NOT\s+Dirty') { $out.dirty = $false; $out.readable = $true; $out.source = 'fsutil-text-english' }
    elseif (Test-FFIMatch $txt 'is\s+Dirty')       { $out.dirty = $true;  $out.readable = $true; $out.source = 'fsutil-text-english' }
    elseif (-not $out.error) { $out.error = $txt.Trim() }
  } catch {}
  $out
}

function Get-BootExecuteEntries {
  <#
    HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\BootExecute, the multi-string
    where a scheduled offline chkdsk actually lives. 'autocheck autochk *' is the DEFAULT
    entry present on every healthy machine and means nothing on its own; a scheduled check
    adds a SECOND entry naming the volume, e.g. 'autocheck autochk /r \??\C:'.
    readable=$false means the value could not be read at all.
  #>
  $out = [ordered]@{ entries = @(); readable = $false; error = $null }
  try {
    $bex = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name BootExecute -ErrorAction Stop).BootExecute
    $out.entries = @(@($bex) | ForEach-Object { "$_" })
    $out.readable = $true
  } catch { $out.error = "$($_.Exception.Message)" }
  $out
}

function Test-BootExecuteSchedulesVolume {
  <#
    Does any BootExecute entry schedule an autocheck of THIS volume? Matches the NT device
    form autochk writes ('\??\C:') and the bare drive letter, but deliberately NOT the
    wildcard default 'autocheck autochk *', which is present on every machine and proves
    nothing. Structural: drive letters and \??\ are not localized.
  #>
  param($Entries, [string]$DriveLetter = $env:SystemDrive)
  $letter = "$DriveLetter".TrimEnd(':', '\')
  foreach ($e in @($Entries)) {
    $s = "$e"
    # Test-FFIMatch throughout: these three decide whether an offline chkdsk is scheduled, and
    # -match's IgnoreCase folding is culture-bound (see the culture-pin note at the top).
    if (-not (Test-FFIMatch $s 'autochk')) { continue }
    if (Test-FFIMatch $s ('\\\?\?\\' + [regex]::Escape($letter) + ':')) { return $true }
    if (Test-FFIMatch $s ('(^|\s)' + [regex]::Escape($letter) + ':(\s|$)')) { return $true }
  }
  $false
}

function Get-RepairOsInfo {
  <#
    The machine identity the catalog's build gates are evaluated against. Same source as
    image.ps1's Get-FFOsIdentity (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion), read
    locally so repair.ps1 does not depend on another engine script's internals.
    readable=$false means the build could NOT be determined — and a build gate that cannot
    be evaluated reports applicable=$null ("could not determine"), never a confident yes.
  #>
  if ($script:OsInfoCache) { return $script:OsInfoCache }
  $out = [ordered]@{ currentBuild = $null; ubr = $null; displayVersion = $null; productName = $null; generation = $null; readable = $false; error = $null }
  # Rung 1: the shared reader in _lib.ps1, which also consults Win32_OperatingSystem and
  # knows that CurrentVersion\ProductName lies ("Windows 10 Pro" on Windows 11).
  if (Get-Command -Name 'Get-FFOsInfo' -ErrorAction SilentlyContinue) {
    try {
      $o = Get-FFOsInfo
      if ($null -ne $o.build) {
        $out.currentBuild = [int]$o.build
        try { if ($null -ne $o.ubr) { $out.ubr = [int]$o.ubr } } catch {}
        $out.displayVersion = "$($o.displayVersion)"
        $out.productName = "$($o.caption)"
        if ("$($o.generation)" -eq 'win11' -or "$($o.generation)" -eq 'win10') { $out.generation = "$($o.generation)" }
        $out.readable = $true
        $script:OsInfoCache = $out
        return $out
      }
    } catch { $out.error = "$($_.Exception.Message)" }
  }
  try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    try { $out.currentBuild = [int]$cv.CurrentBuildNumber } catch {}
    try { $out.ubr = [int]$cv.UBR } catch {}
    $out.displayVersion = "$($cv.DisplayVersion)"
    $out.productName = "$($cv.ProductName)"
    if ($null -ne $out.currentBuild) {
      $out.readable = $true
      # Windows 11 is build 22000 and up; 10240..21999 is Windows 10. ProductName still
      # says "Windows 10" on Windows 11, so the build number is the only honest signal.
      if ($out.currentBuild -ge 22000) { $out.generation = 'win11' }
      elseif ($out.currentBuild -ge 10240) { $out.generation = 'win10' }
    }
  } catch { $out.error = "$($_.Exception.Message)" }
  $script:OsInfoCache = $out
  $out
}

# Build/generation applicability. schemaVersion 3 of data/repairs.json adds three fields to
# every entry — minBuild, maxBuild, generation — so the catalog can finally SAY where a
# repair applies instead of returning an identical list on 21H2, 25H2, Windows 10 and
# Server. null minBuild/maxBuild mean "no bound"; generation 'any' means every generation.
# Entries are never HIDDEN when they do not apply: the user is told the rung exists and why
# it is unavailable here, which is more useful than a silently shorter list.
$script:ValidGenerations = @('any','win10','win11')

function Get-RepairApplicability {
  <#
    Returns @{ applicable; notApplicableReason; minBuild; maxBuild; generation; build }.
    applicable is $true / $false / $null, and $null — "could not determine" — is a
    first-class result: it happens when the entry declares a bound and the machine's build
    could not be read. The run gate treats $null as "do not run without -Force", because
    running a build-gated repair on an unknown build is fixing blind.
  #>
  param($Repair)
  $os = Get-RepairOsInfo
  $minB = $null; $maxB = $null; $gen = 'any'
  try { if ($null -ne $Repair.minBuild -and "$($Repair.minBuild)" -match '^\d+$') { $minB = [int]$Repair.minBuild } } catch {}
  try { if ($null -ne $Repair.maxBuild -and "$($Repair.maxBuild)" -match '^\d+$') { $maxB = [int]$Repair.maxBuild } } catch {}
  try { if ("$($Repair.generation)" -match '\S') { $gen = "$($Repair.generation)".ToLowerInvariant() } } catch {}
  if ($script:ValidGenerations -notcontains $gen) { $gen = 'any' }
  $res = [ordered]@{ applicable = $true; notApplicableReason = $null; minBuild = $minB; maxBuild = $maxB; generation = $gen; build = $os.currentBuild; osGeneration = $os.generation }
  if ($null -eq $minB -and $null -eq $maxB -and $gen -eq 'any') { return $res }
  if (-not $os.readable) {
    $res.applicable = $null
    $res.notApplicableReason = "This repair declares a build or generation requirement, but the Windows build number could not be read from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion$(if ($os.error) { " ($($os.error))" }) — so FrameForge cannot tell whether it applies here. That is 'could not determine', not 'yes'."
    return $res
  }
  if ($null -ne $minB -and $os.currentBuild -lt $minB) {
    $res.applicable = $false
    $res.notApplicableReason = "This repair requires Windows build $minB or newer. This machine is build $($os.currentBuild)$(if ("$($os.displayVersion)" -match '\S') { " ($($os.displayVersion))" })."
    return $res
  }
  if ($null -ne $maxB -and $os.currentBuild -gt $maxB) {
    $res.applicable = $false
    $res.notApplicableReason = "This repair applies only up to Windows build $maxB (the mechanism it uses was removed after that). This machine is build $($os.currentBuild)$(if ("$($os.displayVersion)" -match '\S') { " ($($os.displayVersion))" })."
    return $res
  }
  if ($gen -ne 'any') {
    if ($null -eq $os.generation) {
      $res.applicable = $null
      $res.notApplicableReason = "This repair is declared $gen-only, but this machine's Windows generation could not be determined from build $($os.currentBuild)."
      return $res
    }
    if ($os.generation -ne $gen) {
      $res.applicable = $false
      $res.notApplicableReason = "This repair applies to $gen only. This machine is $($os.generation) (build $($os.currentBuild))."
      return $res
    }
  }
  $res
}

function Get-FFInvariantStamp {
  <#
    Timestamps for folder names and ledger keys, rendered with the INVARIANT culture.
    'yyyyMMdd-HHmmss' through a Thai or Hijri default calendar renders a Buddhist (2569) or
    Hijri (1447) year, which is neither comparable with the ISO 's' timestamps written
    elsewhere in the same ledger nor sortable against them.
  #>
  (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-DetectionRefuses {
  param($Detection)
  if ("$($Detection.state)" -eq 'healthy') { return $true }
  if ("$($Detection.state)" -eq 'indeterminate' -and ($script:RefuseReasons -contains "$($Detection.reason)")) { return $true }
  $false
}
function Get-RefusalKind {
  param($Detection)
  if ("$($Detection.state)" -eq 'healthy') { return 'nothing-broken' }
  if ("$($Detection.reason)" -eq 'probe-failure') { return 'indeterminate-probe-failure' }
  if ("$($Detection.reason)" -eq 'not-applicable') { return 'indeterminate-not-applicable' }
  if ("$($Detection.reason)" -eq 'unparseable')    { return 'indeterminate-unparseable' }
  return 'nothing-broken'
}

function Get-NtpDetection {
  <#
    Local read-only detection: health.ps1 has no time category.

    LOCALE: the old version decided everything by matching 'Last Successful Sync Time:' in
    `w32tm /query /status`, an English label. On every non-English UI that match failed,
    detection returned reason='unparseable' — a RefuseReason — so ntp-resync could never
    run outside English Windows however far the clock had drifted. It also called
    [datetime]::Parse on a system-locale-formatted date using the USER's culture, which
    can silently swap day and month.

    The deciding evidence is now the System event log, keyed by NUMERIC event id (numbers
    are not localized). Microsoft-Windows-Time-Service:
        35  the time service is now synchronizing with a time source   -> SUCCESS
        36  the time service has not synchronized (no response)        -> failure signal
        47  the time provider did not respond                          -> failure signal
        50  the time service is behaving unreliably / no good source   -> failure signal
    The question this probe actually has to answer is "has the clock synced recently?",
    so it asks the log directly for a successful sync inside the staleness window instead
    of reconstructing a timestamp from prose.

    ENVIRONMENT: a DOMAIN member must take its time from the domain hierarchy (W32Time
    Type = NT5DS). Repointing it at pool.ntp.org takes it off the hierarchy, and once the
    clock passes the Kerberos five-minute skew tolerance the user cannot log on, reach
    shares, or authenticate to anything. The undo path already knew NT5DS mattered; the
    run path did not. Domain membership is now a first-class gate here, reported through
    the EXISTING 'not-applicable' refuse reason (rather than a new vocabulary value the
    renderer would not know) with the domain explanation in `detail`. -Force still
    overrides deliberately, and the fix step is DOMHIER-safe when it does.
  #>
  $det = [ordered]@{ method='local'; category='time'; categoryStatus=$null; state='indeterminate'; reason=$null; detail=''; relevantFindings=@() }
  $svc = $null
  try { $svc = Get-Service -Name 'w32time' -ErrorAction Stop } catch {}
  if ($null -eq $svc) {
    $det.reason = 'not-applicable'
    $det.detail = 'The Windows Time service (w32time) is not present on this system.'
    return $det
  }

  $dom = Get-FFDomainState
  $cfg = Get-W32TimeConfig
  # Additive diagnostic fields; the renderer ignores unknown keys.
  $det.domain = $dom
  $det.timeConfig = $cfg

  if ($dom.partOfDomain -eq $true) {
    $typeTxt = 'could not be read'
    if ($cfg.readable -and "$($cfg.type)" -match '\S') { $typeTxt = "is '$($cfg.type)'" }
    $isDomHier = (Test-FFIMatch "$($cfg.type)" '^NT5DS$')
    # NT5DS proven, OR the type could not be read on a machine that IS domain-joined —
    # in the second case FrameForge does not know it is safe, so it does not act.
    if ($isDomHier -or -not $cfg.readable -or -not ("$($cfg.type)" -match '\S')) {
      $det.reason = 'not-applicable'
      $whose = "domain '$($dom.domain)'"
      if (-not ("$($dom.domain)" -match '\S')) { $whose = 'a Windows domain' }
      $det.detail = ("This machine is joined to $whose and its W32Time source type $typeTxt. A domain member takes its clock from the domain " +
                     "hierarchy (Type: NT5DS); repointing it at pool.ntp.org would take it off the hierarchy and risk Kerberos logon, share and " +
                     "authentication failures once the clock drifts past the five-minute tolerance — and Group Policy would likely revert the change " +
                     "at the next refresh anyway. Fix domain time at the PDC emulator instead. -Force overrides this deliberately; if you do, the fix " +
                     'step runs the DOMHIER-preserving form (w32tm /resync against the hierarchy) rather than rewriting the peer list.')
      $det.relevantFindings = @([ordered]@{ id='ntp-domain-managed'; severity='info'; detail=$det.detail })
      return $det
    }
  }

  # NOTE on ordering: the service-state check deliberately comes AFTER the sync evidence
  # below, not before it. On stock Windows 11 w32time is Manual/demand-start and is
  # normally STOPPED between syncs (verified: Start=3, Status=Stopped, last successful sync
  # four hours earlier). Treating "not Running" as a problem on its own therefore reported a
  # fault on every healthy machine and would have repointed a perfectly good clock at
  # pool.ntp.org. A recent successful sync is proof the service is doing its job whatever
  # its current status; only the absence of one makes a stopped service a finding.
  $svcRunning = ("$($svc.Status)" -eq 'Running')
  $svcStartType = $null
  try { $svcStartType = "$($svc.StartType)" } catch {}
  $det.service = [ordered]@{ status = "$($svc.Status)"; startType = $svcStartType }

  $staleDays = 7
  $window = (Get-Date).AddDays(-$staleDays)

  # PRIMARY (locale-independent): a successful-sync event inside the staleness window.
  $recentOk = @(Get-FFEvents -Filter @{ LogName='System'; ProviderName='Microsoft-Windows-Time-Service'; Id=35; StartTime=$window } -MaxEvents 1)
  # An empty result means two very different things. _lib.ps1's Get-FFEvents distinguishes
  # them via $script:FFLastEventUnreadable ($true = the channel/provider could not be read,
  # so the emptiness proves NOTHING). Older _lib builds only set $FFLastEventError.
  $recentUnreadable = $false
  try { $recentUnreadable = [bool]$script:FFLastEventUnreadable } catch {}
  $recentErr = $script:FFLastEventError
  if ($recentErr) { $recentUnreadable = $true }
  $lastOk = @(Get-FFEvents -Filter @{ LogName='System'; ProviderName='Microsoft-Windows-Time-Service'; Id=35 } -MaxEvents 1)
  $lastOkAt = $null
  if ($lastOk.Count -gt 0 -and $lastOk[0].TimeCreated) { $lastOkAt = $lastOk[0].TimeCreated }

  if ($recentOk.Count -gt 0) {
    $when = ConvertTo-FFTime $recentOk[0].TimeCreated
    $det.state = 'healthy'
    $svcNote = ''
    if (-not $svcRunning) { $svcNote = " The service is currently $($svc.Status), which is NORMAL: w32time is a demand-start service (start type $svcStartType) and stops between syncs — the event above is the proof it is working." }
    $det.detail = "Time synchronization is working: the Windows Time service logged a successful sync (System event 35) at $when, inside the last $staleDays days.$svcNote"
    return $det
  }

  # Does the System log even COVER the window? Absence of event 35 proves nothing if the
  # log rolled over. This is the difference between "it has not synced" and "we cannot
  # tell", and doctrine rule 2 says the second one has to be said out loud. It is measured
  # BEFORE the stopped-service branch below, so that branch can never assert "no sync in the
  # last N days" from a log that does not reach back that far.
  $logCovers = @(Get-FFEvents -Filter @{ LogName='System'; StartTime=$window } -MaxEvents 1)
  $logErr = $script:FFLastEventError
  $logUnreadable = $false
  try { $logUnreadable = [bool]$script:FFLastEventUnreadable } catch {}
  if ($logErr) { $logUnreadable = $true }
  $windowMeasured = ($logCovers.Count -gt 0 -and -not $recentUnreadable -and -not $logUnreadable)

  # No recent sync, and the log genuinely covers the window. NOW a stopped service is a
  # finding, and the more specific one.
  if ($windowMeasured -and -not $svcRunning) {
    $det.state = 'problem'
    $det.detail = "The Windows Time service is $($svc.Status) (start type $svcStartType) and the System log — which does cover the last $staleDays days — holds no successful time-sync event (id 35) in that window. The clock is not synchronizing."
    $det.relevantFindings = @([ordered]@{ id='w32time-not-running'; severity='warning'; detail=$det.detail })
    return $det
  }

  if ($windowMeasured) {
    $failSignals = @(Get-FFEvents -Filter @{ LogName='System'; ProviderName='Microsoft-Windows-Time-Service'; Id=@(36,47,50); StartTime=$window } -MaxEvents 3)
    $det.state = 'problem'
    $lastTxt = 'no successful sync is recorded anywhere in the retained System log'
    if ($null -ne $lastOkAt) { $lastTxt = "the last recorded successful sync was $(ConvertTo-FFTime $lastOkAt)" }
    $det.detail = "The System log covers the last $staleDays days but contains no successful time-sync event (id 35) in that window — $lastTxt. Synchronization looks stuck."
    $findings = @([ordered]@{ id='ntp-sync-stale'; severity='warning'; detail=$det.detail })
    foreach ($f in @(ConvertTo-FFEventEvidence $failSignals 3)) {
      $findings += [ordered]@{ id='ntp-sync-failure-event'; severity='warning'; detail="System event $($f.id) at $($f.time): $($f.message)" }
    }
    $det.relevantFindings = $findings
    return $det
  }

  # Rung 2 — DOCUMENTED ENGLISH-ONLY. Only reached when the event log could not answer.
  # Kept because it still works on the English installs it was written for; it is a
  # supplement, never the decision-maker, and its date is parsed with an EXPLICIT
  # invariant culture through TryParse (which cannot throw and cannot day/month-swap).
  $txt = ''
  try { $txt = (@(cmd /c "w32tm /query /status 2>nul") | ForEach-Object { "$_" }) -join "`n" } catch {}
  $mSync = [regex]::Match($txt, 'Last Successful Sync Time:\s*(.+)', $script:FFReIC)
  if ($mSync.Success) {
    $when = $mSync.Groups[1].Value.Trim()
    if (Test-FFIMatch $when 'unspecified') {
      $det.state = 'problem'
      $det.detail = 'The time service has never successfully synced (w32tm reports the last successful sync time as unspecified).'
      $det.relevantFindings = @([ordered]@{ id='ntp-never-synced'; severity='warning'; detail=$det.detail })
      return $det
    }
    $dt = [datetime]::MinValue
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ([datetime]::TryParse($when, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
      if ($dt -lt $window) {
        $det.state = 'problem'
        $det.detail = "The clock last synced on $when — more than $staleDays days ago; synchronization looks stuck. (Read from w32tm's English status text; the event log could not answer.)"
        $det.relevantFindings = @([ordered]@{ id='ntp-sync-stale'; severity='warning'; detail=$det.detail })
      } else {
        $det.state = 'healthy'
        $det.detail = "Time synchronization is working (last successful sync: $when, read from w32tm's English status text)."
      }
      return $det
    }
  }

  # Honest unknown. Every rung failed; this NEVER falls through to 'healthy'.
  $why = 'the System event log could not be read'
  if ($recentUnreadable) { $why = "the System event log or the Time-Service provider could not be read$(if ($recentErr) { " ($recentErr)" })" }
  elseif ($logUnreadable) { $why = "the System event log could not be read$(if ($logErr) { " ($logErr)" })" }
  elseif ($logCovers.Count -eq 0) { $why = "the System event log does not reach back $staleDays days (it has rolled over), so the absence of a sync event proves nothing" }
  $det.reason = 'unparseable'
  $det.detail = "Could not determine when the clock last synchronized: $why, and w32tm's status text is localized on this machine so it could not be read either. Detection is INDETERMINATE — this repair refuses rather than guessing. -Force overrides deliberately."
  $det
}

function Get-WingetDetection {
  # Local read-only detection: is winget on PATH and does `winget --version` succeed.
  $det = [ordered]@{ method='local'; category='apps'; categoryStatus=$null; state='indeterminate'; reason=$null; detail=''; relevantFindings=@() }
  $cmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { $cmd = Get-Command -Name 'winget' -ErrorAction SilentlyContinue }
  if ($null -eq $cmd) {
    $det.state = 'problem'
    $det.detail = 'winget is not on PATH — the App Installer package is missing or broken.'
    $det.relevantFindings = @([ordered]@{ id='winget-missing'; severity='warning'; detail=$det.detail })
    return $det
  }
  $v = $null; $code = 1
  try { $v = ((@(& $cmd.Source --version) | ForEach-Object { "$_" }) -join ' ').Trim(); $code = $LASTEXITCODE } catch { $code = 1 }
  if ($code -eq 0 -and $v) {
    $det.state = 'healthy'
    $det.detail = "winget responds normally (version $v)."
  } else {
    $det.state = 'problem'
    $det.detail = "winget is present but 'winget --version' failed (exit code $code) — the package manager is broken."
    $det.relevantFindings = @([ordered]@{ id='winget-broken'; severity='warning'; detail=$det.detail })
  }
  $det
}

function Get-OptionalFeatureDetection {
  <#
    Local read-only detection for the optional-feature repairs: ask DISM what state the
    feature is actually in (Get-WindowsOptionalFeature -Online), never assume.

    The honest bit is the DISABLED case. "NetFx3 is disabled" is the Windows DEFAULT on a
    clean install — it is NOT a fault, and reporting state:'problem' would put a red dot
    on every healthy machine in the list. But it is not 'healthy' either, because there IS
    something this repair can do. So it reports indeterminate/reason='user-initiated':
    the engine states the feature's real state and says plainly that only the user knows
    whether an application needs it. Test-DetectionRefuses lets that reason through, so
    the repair runs on request WITHOUT needing -Force, while an ALREADY-ENABLED feature
    still refuses with the first-class "nothing to do here" result.
  #>
  param([string]$FeatureName, [string]$Purpose)
  $det = [ordered]@{ method='local'; category='optional-features'; categoryStatus=$null; state='indeterminate'; reason=$null; detail=''; relevantFindings=@() }
  if (-not $FeatureName) {
    $det.reason = 'probe-failure'
    $det.detail = 'This repair declares no optionalFeature name in data/repairs.json — the catalog and the engine disagree, so detection cannot run.'
    return $det
  }
  if (-not (Get-Command -Name 'Get-WindowsOptionalFeature' -ErrorAction SilentlyContinue)) {
    $det.reason = 'probe-failure'
    $det.detail = "The DISM PowerShell module (Get-WindowsOptionalFeature) is not available on this system, so the state of '$FeatureName' cannot be read. Detection FAILED — this repair refuses to enable a feature blind."
    return $det
  }
  if (-not $IsAdmin) {
    # Get-WindowsOptionalFeature -Online genuinely requires elevation; that is a
    # needs-admin ("the probe could run, elevated"), not a broken probe.
    $det.reason = 'needs-admin'
    $det.detail = "Reading the state of the '$FeatureName' optional feature needs administrator rights (Get-WindowsOptionalFeature -Online is an elevated call). Re-run elevated to see whether it is already enabled."
    return $det
  }
  $f = $null; $err = $null; $hres = $null
  try { $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop }
  catch {
    $err = "$($_.Exception.Message)"
    try { $hres = [int]$_.Exception.HResult } catch {}
  }
  if ($null -eq $f) {
    # CBS_E_IMAGE_UNSERVICEABLE / "feature name is unknown" surfaces as HRESULT 0x800F080C.
    # Classify on the NUMBER first: HRESULTs are not localized, the exception MESSAGE is.
    # The text match below is kept as a documented English-only second rung — without the
    # numeric rung, a German or Japanese machine that simply has no such feature was told
    # its probe was broken ("fix the probe") instead of the truth.
    # NOTE for maintainers: in PS 5.1 the literal 0x800F080C is an Int32 and therefore
    # NEGATIVE (-2146498548) — exactly what Exception.HResult holds. Do NOT "fix" this
    # into a -band 0xFFFFFFFF comparison: that promotes the left side to a positive Int64
    # while the right stays negative, and the test silently never matches.
    $unknownFeature = $false
    if ($null -ne $hres -and $hres -eq 0x800F080C) { $unknownFeature = $true }
    if (-not $unknownFeature -and (Test-FFIMatch "$err" '0x800f080c|feature name .* is unknown|not (?:present|recognized|found)')) { $unknownFeature = $true }
    if ($unknownFeature) {
      $det.reason = 'not-applicable'
      $det.detail = "This Windows image has no optional feature called '$FeatureName', so there is nothing to enable. ($err)"
    } else {
      $det.reason = 'probe-failure'
      $det.detail = "Could not read the state of the '$FeatureName' optional feature: $err. Detection FAILED — this repair refuses to enable a feature blind."
    }
    return $det
  }
  $state = "$($f.State)"
  $det.categoryStatus = $state
  $what = "$Purpose"
  if (-not $what) { $what = "the '$FeatureName' optional feature" }
  switch -Regex ($state) {
    '^Enabled$' {
      $det.state = 'healthy'
      $det.detail = "The '$FeatureName' optional feature is already Enabled — $what is present, so there is nothing to install. Nothing is broken here."
      return $det
    }
    '^EnablePending$' {
      $det.state = 'healthy'
      $det.detail = "The '$FeatureName' optional feature is EnablePending: it has already been enabled and only needs a restart to finish. Restart rather than enabling it again."
      return $det
    }
    '^(Disabled|DisabledWithPayloadRemoved|DisablePending)$' {
      $det.reason = 'user-initiated'
      $extra = ''
      if ($state -eq 'DisabledWithPayloadRemoved') { $extra = " Its payload has been REMOVED from this image, so enabling it must download the files from Windows Update (internet required) or read them from installation media (-SourcePath <mounted media>\sources\sxs)." }
      if ($state -eq 'DisablePending') { $extra = ' A pending disable is outstanding; restart first so the state settles, then re-check.' }
      $det.detail = ("The '$FeatureName' optional feature is currently $state. An optional feature being off is a CONFIGURATION, not a detected fault — it only matters if an application you want to run requires $what and refuses to start without it. " +
                     "FrameForge cannot know that; you can. This repair is therefore symptom-driven: it reports the real state and enables the feature on request, without pretending it detected a problem.$extra")
      $det.relevantFindings = @([ordered]@{ id='optional-feature-not-enabled'; severity='info'; detail="$FeatureName is $state." })
      return $det
    }
  }
  $det.reason = 'unparseable'
  $det.detail = "Get-WindowsOptionalFeature returned an unrecognized state ('$state') for '$FeatureName'."
  $det
}

function Get-RepairDetection {
  <# The doctrine's detect step. Maps a repair to its health probe (or local check)
     and reduces the probe to: problem / healthy / indeterminate FOR THIS REPAIR —
     a category can be unhealthy for reasons a given repair does not address (e.g.
     windows-update warning solely for a pending reboot must NOT trigger wu-reset). #>
  param($Repair, [switch]$Fresh, [switch]$ShallowOnly)
  $localKind = $null
  try { $localKind = $Repair.localDetect } catch {}
  if ($localKind -eq 'ntp')    { return Get-NtpDetection }
  if ($localKind -eq 'winget') { return Get-WingetDetection }
  if ($localKind -eq 'optional-feature') { return Get-OptionalFeatureDetection -FeatureName "$($Repair.optionalFeature)" -Purpose "$($Repair.featurePurpose)" }

  # ENVIRONMENT GATE for activation-retry, in the same shape as the domain gate on ntp-resync.
  # slmgr /ato is the right tool for a RETAIL / OEM / MAK licence that is present but not Licensed.
  # It is the WRONG tool on the two channels below, and the catalog's own summary ("against
  # Microsoft's activation servers") stops being a true description of what runs:
  #   kms-client (Volume:GVLK)  the client activates against a KMS host on the local network, not
  #                             Microsoft. A KMS client that will not activate is a DNS SRV record,
  #                             a firewall, or a KMS host problem; retrying /ato from the client
  #                             changes nothing on the machine that is actually broken.
  #   subscription              Windows subscription activation (E3/E5, Windows Enterprise
  #                             subscription) is driven by the user's entitlement in Entra ID, not
  #                             by a key on the device. /ato cannot grant or refresh it.
  # Reported through the EXISTING 'not-applicable' refuse reason so no renderer needs a new value.
  # -Force still overrides deliberately, exactly as everywhere else in this engine.
  if ("$($Repair.id)" -eq 'activation-retry') {
    $lic = Get-FFLicenseState
    if ($lic.readable -and ($lic.channel -eq 'kms-client' -or $lic.channel -eq 'subscription')) {
      $d = [ordered]@{ method='local'; category="$($Repair.healthCheck)"; categoryStatus=$null; state='indeterminate'; reason='not-applicable'; detail=''; relevantFindings=@() }
      $d.licenses = $lic
      if ($lic.channel -eq 'kms-client') {
        $kmsName = $lic.kmsHost
        $whichHost = 'no KMS host has been discovered yet'
        if ($kmsName) { $whichHost = "the discovered KMS host is '$kmsName'" }
        $d.detail = ("This machine holds a VOLUME/KMS client licence ('$($lic.product)', channel read from $($lic.channelSource)), so it activates against a Key Management Service host on your network rather than against Microsoft's activation servers — $whichHost. " +
                     'Retrying slmgr /ato from here cannot fix a KMS problem, because the thing that is failing is name resolution to the KMS host (the _VLMCS._tcp SRV record), a firewall on TCP 1688, or the host itself. Ask whoever runs your volume licensing. -Force overrides this deliberately.')
        $d.relevantFindings = @([ordered]@{ id='activation-kms-managed'; severity='info'; detail=$d.detail })
      } else {
        $d.detail = ("This machine's Windows licence includes a SUBSCRIPTION component ('$($lic.product)', detected via $($lic.channelSource)). Subscription activation is granted by the signed-in user's entitlement in Entra ID (Microsoft 365 / Windows Enterprise subscription), not by a product key on the device, " +
                     'so slmgr /ato cannot obtain or refresh it. Check the account, its licence assignment, and the device''s Entra ID join state instead. -Force overrides this deliberately.')
        $d.relevantFindings = @([ordered]@{ id='activation-subscription-managed'; severity='info'; detail=$d.detail })
      }
      return $d
    }
  }

  $deep = $false
  if ($Repair.probeDeep -and -not $ShallowOnly) { $deep = $true }
  $probe = Invoke-HealthProbe -Category $Repair.healthCheck -Deep:$deep -Fresh:$Fresh
  $det = [ordered]@{ method='health-probe'; category="$($Repair.healthCheck)"; categoryStatus=$null; state='indeterminate'; reason=$null; detail=''; relevantFindings=@() }
  if ($null -eq $probe) {
    # health.ps1 is missing, crashed, or emitted something unparseable. This is a FAILED
    # probe, not a quiet "we don't know" — it must refuse, never fix blindly.
    $det.reason = 'probe-failure'
    $det.detail = "The health probe for '$($Repair.healthCheck)' could not be run or its output could not be parsed (engine/health.ps1 missing, crashed, or returned invalid JSON). Detection FAILED — this repair refuses to run blind. Fix the probe, or use -Force to override deliberately."
    return $det
  }
  $status = "$($probe.status)"
  $det.categoryStatus = $status

  $patterns = @()
  if ($Repair.relevantFindings) { $patterns = @($Repair.relevantFindings) }
  $rel = @()
  foreach ($f in @($probe.findings)) {
    if ("$($f.severity)" -eq 'info') { continue }
    $match = $false
    if ($patterns.Count -eq 0) { $match = $true }
    # Test-FFILike, not -like: -like's IgnoreCase folding is culture-bound too, and this is the
    # test that decides whether a health finding belongs to this repair at all.
    else { foreach ($p in $patterns) { if (Test-FFILike "$($f.id)" "$p") { $match = $true; break } } }
    if ($match) { $rel += [ordered]@{ id="$($f.id)"; severity="$($f.severity)"; detail="$($f.detail)" } }
  }
  $det.relevantFindings = $rel

  # ---- faults, holes, and the difference between them --------------------------------------
  # BLOCKER THIS FIXES. The decision used to be made from $probe.status ALONE, and health.ps1's
  # Resolve-Status ranks critical > warning > unknown > needs-admin > ok — so a single warning
  # MASKS every 'unknown' finding underneath it. A category that reported 'warning' for something
  # this repair does not address therefore landed in the "healthy FOR THIS REPAIR" arm even when
  # the signal this repair actually keys on had NOT BEEN MEASURED AT ALL (severity 'unknown'), and
  # even when the probe had told us it was running blind. The engine then said "nothing is broken
  # here" about a thing it never looked at — doctrine rule 2 broken in the function that decides
  # whether a repair runs.
  #
  # The three answers are now decided from the FINDINGS, which are not rank-masked, in health.ps1's
  # own order (fault > hole > needs-elevation > ok):
  #   fault      severity warning/critical  -> a measured problem
  #   hole       severity 'unknown'         -> NOT a fault and NOT health: "could not determine",
  #                                            reported through the existing 'unparseable' refusal
  #   elevation  status needs-admin         -> "elevate me and I will know" (may proceed)
  # An 'unknown' that MATCHES this repair's patterns can no longer make it run either: an unmeasured
  # signal is not evidence of a fault any more than it is evidence of health.
  $relFaults  = @($rel | Where-Object { "$($_.severity)" -eq 'warning' -or "$($_.severity)" -eq 'critical' })
  $relUnknown = @($rel | Where-Object { "$($_.severity)" -eq 'unknown' })
  $catUnknown = @(@($probe.findings) | Where-Object { "$($_.severity)" -eq 'unknown' })
  $catUnknownIds = (@($catUnknown | ForEach-Object { "$($_.id)" }) -join ', ')
  # Additive and tolerant: health.ps1's per-category document does not currently publish a
  # needsAdmin flag of its own (its needs-admin-ness reaches us only through .status, which the
  # rank masks the moment any warning exists). If it ever does, this reads it — and until then the
  # masked case falls into the honest 'unknown'/'unparseable' arms above rather than into 'healthy'.
  $probeNeedsAdmin = $false
  try { if ($null -ne $probe.needsAdmin) { $probeNeedsAdmin = [bool]$probe.needsAdmin } } catch {}

  if ($relFaults.Count -gt 0) {
    $det.state = 'problem'
    $ids = @($relFaults | ForEach-Object { $_.id }) -join ', '
    $det.detail = "$($probe.summary) Relevant to this repair: $ids."
  } elseif ($relUnknown.Count -gt 0) {
    # The repair's OWN signal was not measured. This is the worst case doctrine rule 2 exists for,
    # so it is named first and refuses.
    $det.reason = 'unparseable'
    $ids = @($relUnknown | ForEach-Object { $_.id }) -join ', '
    $det.detail = ("The signal this repair keys on was NOT MEASURED: the '$($Repair.healthCheck)' probe reported $($relUnknown.Count) finding(s) at severity 'unknown' that match this repair ($ids). " +
                   "That is 'could not determine', not 'nothing is broken' and not 'something is broken' — running would be fixing blind. $($probe.summary)")
  } elseif ($catUnknown.Count -gt 0) {
    # A hole elsewhere in the same category. The category status may well read 'warning' or
    # 'critical' for an unrelated fault; that must not be turned into a clean bill of health for
    # this repair while part of the category went unread.
    $det.reason = 'unparseable'
    $det.detail = ("The '$($Repair.healthCheck)' category reports '$status' and none of its FAULTS are ones this repair addresses, but $($catUnknown.Count) of its signal(s) could not be read at all ($catUnknownIds), " +
                   "so 'nothing is broken here' cannot be claimed for this repair. $($probe.summary)")
  } elseif ($status -eq 'needs-admin' -or $probeNeedsAdmin) {
    # The probe RAN; it just could not see everything without elevation. That is a
    # different animal from a broken probe: the run path may proceed via the admin gate.
    $det.reason = 'needs-admin'
    $det.detail = "The probe ran but needed administrator rights to check this category fully (status: $status). $($probe.summary)"
  } elseif ($status -eq 'ok') {
    $det.state = 'healthy'
    $det.detail = "$($probe.summary)"
  } elseif ($status -eq 'warning' -or $status -eq 'critical') {
    # The category has issues, every signal in it WAS read, and none of the issues is one this
    # repair addresses — for THIS repair that is healthy.
    $det.state = 'healthy'
    $det.detail = "The '$($Repair.healthCheck)' category reports '$status', but none of its findings are ones this repair addresses. $($probe.summary)"
  } elseif ($status -eq 'unknown') {
    # health.ps1's first-class "could not determine" for the whole category, arriving without a
    # finding to name. Same answer as a hole: refuse, and say so.
    $det.reason = 'unparseable'
    $det.detail = "The '$($Repair.healthCheck)' probe reported status 'unknown': at least one of its signals could not be read, so whether this repair is needed COULD NOT BE DETERMINED. $($probe.summary)"
  } else {
    $det.reason = 'unparseable'
    $det.detail = "The probe returned an unrecognized status ('$status') for this category. $($probe.summary)"
  }
  # ---- the ADMIN-GATED SIGNAL gate (catalog fact: detectionNeedsAdmin) ---------------------
  # The other half of the same blocker. health.ps1's per-category document reports its
  # needs-admin-ness ONLY through .status, and Resolve-Status ranks critical > warning > unknown >
  # needs-admin — so on this very machine the unelevated system-files probe returns status
  # 'warning' (a pending servicing reboot) with the component-store check NEVER RUN, and the
  # "warning it does not address" arm above then graded sfc-scannow / dism-restorehealth
  # 'healthy'. Measured before this gate: state=healthy, detail "...none of its findings are ones
  # this repair addresses. The component-store corruption check needs administrator rights; only
  # the pending-reboot key was checked." — a clean bill of health quoting the sentence that says
  # nothing was checked.
  #
  # Two defences, because one of them is not mine to write:
  #   1. $probe.needsAdmin, read tolerantly above — the moment health.ps1 publishes that flag on
  #      the category document (it already has it in hand: Get-CategoryDoc's $r.needsAdmin), the
  #      masked case is answered from the probe's own measurement.
  #   2. THIS gate, which needs nothing from health.ps1: data/repairs.json declares, per repair,
  #      whether the signal that repair keys on is readable at all without elevation. It is set on
  #      exactly the three system-files repairs, whose relevantFindings (component-store-corrupt,
  #      component-store-scanhealth, sfc-verify-violations) are every one of them emitted inside
  #      `if ($IsAdmin)` in Probe-SystemFiles. Unelevated, a 'healthy' from those probes is not a
  #      measurement, so it becomes the honest "elevate me and I will know".
  # Only a would-be HEALTHY verdict is upgraded: a fault this repair addresses that was visible
  # even unelevated stays a fault, and an existing refusal keeps its own reason.
  if ($det.state -eq 'healthy' -and $Repair.detectionNeedsAdmin -and -not $script:IsAdmin) {
    $det.state = 'indeterminate'
    $det.reason = 'needs-admin'
    $det.detail = ("The signal this repair keys on is only readable with administrator rights (the catalog marks it detectionNeedsAdmin), and FrameForge is NOT running elevated — so the '$($Repair.healthCheck)' probe could not measure it. " +
                   "That is 'could not determine', not 'nothing is broken here'. Re-run FrameForge as administrator for a real answer. $($det.detail)")
  }
  if ($ShallowOnly -and $Repair.probeDeep -and $det.state -eq 'healthy') {
    $det.state = 'indeterminate'
    $det.reason = 'shallow-probe'
    $det.detail = "$($det.detail) (Shallow probe only — the deciding deep probe runs at preflight/run.)"
  }
  $det
}

# ---------------- state capture (read-only, before any mutation) ----------------

function Get-SvcSnapshot {
  param([string[]]$Names)
  $rows = @()
  foreach ($n in $Names) {
    try {
      $s = Get-Service -Name $n -ErrorAction Stop
      $st = $null; try { $st = "$($s.StartType)" } catch {}
      $rows += [ordered]@{ name=$n; status="$($s.Status)"; startType=$st; present=$true }
    } catch {
      $rows += [ordered]@{ name=$n; status='NotFound'; startType=$null; present=$false }
    }
  }
  $rows
}

function Get-NetConfigSnapshot {
  $rows = @()
  try {
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction Stop)) {
      $ip = $null;  try { $ip  = (@($c.IPv4Address        | ForEach-Object { "$($_.IPAddress)" }) -join ', ') } catch {}
      $gw = $null;  try { $gw  = (@($c.IPv4DefaultGateway | ForEach-Object { "$($_.NextHop)" })   -join ', ') } catch {}
      $dns = $null; try { $dns = (@($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', ') } catch {}
      $rows += [ordered]@{ alias="$($c.InterfaceAlias)"; ipv4=$ip; gateway=$gw; dnsServers=$dns }
    }
  } catch {}
  $rows
}

# Documented Microsoft default start types for the update pipeline. Used ONLY to
# re-enable a service that detection found Disabled — never applied to a service that
# is already enabled (that would overwrite an administrator's deliberate choice).
$WuServiceDefaults = [ordered]@{
  'wuauserv'  = 'Manual'
  'bits'      = 'Manual'
  'cryptSvc'  = 'Automatic'
  'msiserver' = 'Manual'
  'appidsvc'  = 'Manual'
  'DoSvc'     = 'Automatic'
  'UsoSvc'    = 'Automatic'
}
$StoreServiceDefaults = [ordered]@{
  'AppXSvc'        = 'Manual'
  'ClipSVC'        = 'Manual'
  'InstallService' = 'Manual'
  'DoSvc'          = 'Automatic'
}
$script:WsusIdentityValues = @('AccountDomainSid','PingID','SusClientId','SusClientIdValidation')
$script:WuPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'

function Get-WinHttpProxySnapshot {
  $out = [ordered]@{ raw = $null; readable = $false }
  try {
    $o = & (Join-Path $env:SystemRoot 'System32\netsh.exe') winhttp show proxy
    $out.raw = ((@($o) | Where-Object { "$_" -match '\S' }) -join ' | ').Trim()
    $out.readable = ($LASTEXITCODE -eq 0)
  } catch {}
  $out
}
function Get-WsusIdentitySnapshot {
  $rows = @()
  foreach ($n in $WsusIdentityValues) {
    $row = [ordered]@{ name=$n; present=$false; value=$null }
    try {
      $v = Get-ItemProperty -LiteralPath $WuPolicyKey -Name $n -ErrorAction Stop
      $row.present = $true
      $row.value = "$($v.$n)"
    } catch {}
    $rows += $row
  }
  $rows
}

function Get-RepairCapture {
  # Read-only. Returns the 'before' blob written to the ledger.
  param($Repair)
  switch ($Repair.id) {
    { $_ -eq 'wu-reset' -or $_ -eq 'wu-reset-aggressive' } {
      $cap = [ordered]@{
        # startType is the load-bearing field: a Disabled service is ALSO Stopped, so
        # without capturing (and restoring) the start type the reset silently no-ops.
        services = @(Get-SvcSnapshot @('wuauserv','cryptSvc','bits','msiserver','appidsvc','DoSvc','UsoSvc'))
        softwareDistributionExists = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'SoftwareDistribution'))
        catroot2Exists = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\catroot2'))
        winHttpProxy = (Get-WinHttpProxySnapshot)
        wsusClientIdentity = @(Get-WsusIdentitySnapshot)
        # Management state — WSUS/WUfB policy, MDM enrolment, domain membership. Nothing
        # in this codebase read any of it before, which is why the reset told WSUS-pinned
        # machines their client would "re-register with Microsoft" (false) and cleared a
        # mandatory WinHTTP proxy that was the machine's only route to updates.
        wuPolicy = (Get-WuManagementState)
        bitsQueueFiles = @()
        bitsJobCount = $null
      }
      try {
        $qdir = Join-Path $env:ALLUSERSPROFILE 'Microsoft\Network\Downloader'
        foreach ($f in @(Get-ChildItem -LiteralPath $qdir -Filter 'qmgr*.dat' -File -Force -ErrorAction Stop)) {
          $cap.bitsQueueFiles += [ordered]@{ name="$($f.Name)"; sizeBytes=[int64]$f.Length; lastWrite=$f.LastWriteTime.ToString('s') }
        }
      } catch {}
      try { $cap.bitsJobCount = @(Get-BitsTransfer -AllUsers -ErrorAction Stop).Count } catch {}
      if ($Repair.id -eq 'wu-reset-aggressive') {
        # Capture the CURRENT security descriptors before sdset overwrites them —
        # the thing WinUtil never does. sc.exe sdshow is read-only.
        $sd = [ordered]@{}
        foreach ($svcName in @('wuauserv','bits')) {
          try {
            $o = & (Join-Path $env:SystemRoot 'System32\sc.exe') sdshow $svcName
            $txt = ((@($o) | Where-Object { "$_" -match '\S' }) -join '').Trim()
            if ($LASTEXITCODE -eq 0 -and $txt) { $sd[$svcName] = $txt }
            else { $sd[$svcName] = "capture failed (exit $LASTEXITCODE): $txt" }
          } catch { $sd[$svcName] = "capture failed: $($_.Exception.Message)" }
        }
        $cap.securityDescriptors = $sd
      }
      return $cap
    }
    { $_ -eq 'dism-restorehealth' -or $_ -eq 'sfc-scannow' } {
      return [ordered]@{ note = 'No restorable prior state: DISM/SFC replace corrupt files with canonical Microsoft-signed content; nothing user-specific is changed.' }
    }
    { $_ -eq 'network-flush' -or $_ -eq 'winsock-reset' } {
      return [ordered]@{ adapters = @(Get-NetConfigSnapshot) }
    }
    'dns-change-resolver' {
      # Per-adapter DNS servers AND whether they are DHCP-assigned — undo has to know
      # the difference between "no servers set" and "servers came from DHCP".
      $rows = @()
      try {
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { "$($_.Status)" -eq 'Up' })) {
          $row = [ordered]@{ alias="$($a.Name)"; ifIndex=[int]$a.ifIndex; ipv4Servers=@(); ipv6Servers=@(); dhcpAssigned=$null }
          try { $row.ipv4Servers = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch {}
          try { $row.ipv6Servers = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses) } catch {}
          try {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$((Get-NetAdapter -InterfaceIndex $a.ifIndex -ErrorAction Stop).InterfaceGuid)"
            $ns = (Get-ItemProperty -LiteralPath $key -Name NameServer -ErrorAction Stop).NameServer
            $row.dhcpAssigned = [string]::IsNullOrWhiteSpace("$ns")
          } catch {}
          $rows += $row
        }
      } catch {}
      return [ordered]@{ adapters = $rows; requestedProvider = $script:ResolvedDnsProviderKey }
    }
    { Test-FFILike "$_" 'chkdsk-*' } {
      $cap = [ordered]@{ systemDrive = "$env:SystemDrive"; dirtyBit = $null; dirtyBitRead = $null; volume = $null; scheduledAtBoot = $null; bootExecuteEntries = @(); alreadyScheduled = $null }
      # CIM first (Win32_Volume.DirtyBitSet is a boolean), fsutil's English prose only as a
      # documented second rung, and $null — "could not determine" — when neither answered.
      $dirty = Get-VolumeDirtyState -DriveLetter $env:SystemDrive
      $cap.dirtyBitRead = $dirty
      if ($dirty.readable) { $cap.dirtyBit = $dirty.dirty }
      try {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $cap.volume = [ordered]@{ fileSystem="$($v.FileSystem)"; healthStatus="$($v.HealthStatus)"; sizeBytes=[int64]$v.Size; freeBytes=[int64]$v.SizeRemaining }
      } catch {}
      $bex = Get-BootExecuteEntries
      $cap.bootExecuteEntries = @($bex.entries)
      if ($bex.readable) {
        $cap.scheduledAtBoot = (@($bex.entries) -join ' ; ')
        # 'autocheck autochk *' is the default on every machine and is NOT a scheduled
        # check; only an entry naming this volume is.
        $cap.alreadyScheduled = (Test-BootExecuteSchedulesVolume $bex.entries $env:SystemDrive)
      }
      return $cap
    }
    'store-services-enable' {
      return [ordered]@{ services = @(Get-SvcSnapshot @('AppXSvc','ClipSVC','InstallService','DoSvc')) }
    }
    'activation-retry' {
      # ALL keyed licence rows, not an arbitrary Select-Object -First 1 (see Get-FFLicenseState for
      # what that used to hide). The three scalar fields are kept so an existing renderer that reads
      # them keeps working; `licenses` is the additive full picture.
      $lic = Get-FFLicenseState
      return [ordered]@{
        licenseStatus     = $lic.status
        licenseStatusText = $lic.statusText
        product           = $lic.product
        licenses          = $lic
      }
    }
    { $_ -eq 'store-cache-reset' -or $_ -eq 'store-reregister' -or $_ -eq 'store-reregister-all' } {
      $pkg = $null
      try { $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 } catch {}
      $row = $null
      if ($null -ne $pkg) { $row = [ordered]@{ name="$($pkg.Name)"; version="$($pkg.Version)"; status="$($pkg.Status)" } }
      return [ordered]@{ storePackage = $row; services = @(Get-SvcSnapshot @('AppXSvc','ClipSVC','InstallService','DoSvc')) }
    }
    'search-index-rebuild' {
      $cap = [ordered]@{ services = @(Get-SvcSnapshot @('WSearch')); indexFile = $null; setupCompletedSuccessfully = $null }
      $dir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
      foreach ($cand in @('Windows.edb','Windows.db')) {
        try {
          $f = Get-Item -LiteralPath (Join-Path $dir $cand) -Force -ErrorAction Stop
          $cap.indexFile = [ordered]@{ path="$($f.FullName)"; sizeBytes=[int64]$f.Length }
          break
        } catch {}
      }
      try { $cap.setupCompletedSuccessfully = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -ErrorAction Stop).SetupCompletedSuccessfully } catch {}
      return $cap
    }
    'shell-restart' {
      $running = @()
      try { $running = @(Get-Process -Name @('StartMenuExperienceHost','SearchHost','explorer') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Select-Object -Unique) } catch {}
      return [ordered]@{ runningProcesses = $running }
    }
    'spooler-clear-queue' {
      $cap = [ordered]@{ services = @(Get-SvcSnapshot @('Spooler')); spoolFiles = @(); spoolFolderReadable = $true }
      try {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'System32\spool\PRINTERS') -File -Force -ErrorAction Stop)
        foreach ($f in ($files | Select-Object -First 200)) {
          $cap.spoolFiles += [ordered]@{ name="$($f.Name)"; sizeBytes=[int64]$f.Length; lastWrite=$f.LastWriteTime.ToString('s') }
        }
      } catch { $cap.spoolFolderReadable = $false }
      return $cap
    }
    'audio-restart' {
      return [ordered]@{ services = @(Get-SvcSnapshot @('AudioEndpointBuilder','Audiosrv')) }
    }
    'ntp-resync' {
      # The prior peer list and sync type come from the REGISTRY, where they are stored
      # verbatim and unlocalized. The old capture matched the English labels 'NtpServer:'
      # and 'Type:' in w32tm's output, so on a localized Windows both stayed $null — and
      # undo then applied an ASSUMED default (time.windows.com), which on a domain member
      # converted domain-hierarchy sync into a manual internet peer. `readable` is written
      # to the ledger so undo can tell "captured nothing" from "captured empty" and REFUSE
      # instead of guessing.
      $cfg = Get-W32TimeConfig
      $cap = [ordered]@{
        services = @(Get-SvcSnapshot @('w32time'))
        ntp = [ordered]@{ ntpServer=$cfg.ntpServer; type=$cfg.type; readable=[bool]$cfg.readable; source=$cfg.source; readError=$cfg.error }
        domain = (Get-FFDomainState)
      }
      return $cap
    }
    'temp-clean' {
      $rows = @()
      foreach ($t in @(@{label='user temp'; path=$env:TEMP}, @{label='system temp'; path=(Join-Path $env:SystemRoot 'Temp')})) {
        $row = [ordered]@{ label=$t.label; path=$t.path; fileCount=$null; bytes=$null }
        try {
          $files = @(Get-ChildItem -LiteralPath $t.path -Recurse -Force -File -ErrorAction SilentlyContinue)
          [int64]$b = 0; foreach ($f in $files) { $b += $f.Length }
          $row.fileCount = $files.Count; $row.bytes = $b
        } catch {}
        $rows += $row
      }
      return [ordered]@{ tempFolders = $rows }
    }
    { $_ -eq 'component-cleanup' -or $_ -eq 'component-cleanup-resetbase' } {
      return [ordered]@{ note = 'No restorable prior state: component-store cleanup is one-way by design (the safe tier keeps updates uninstallable; /ResetBase does not).' }
    }
    'wu-repair-reinstall' {
      # Guided handoff: FrameForge opens a Settings page and changes nothing itself, so
      # there is no prior state of its own to capture. The build identity IS worth
      # recording, because whether this rung exists at all is a build question.
      $os = Get-RepairOsInfo
      return [ordered]@{
        note = 'No state is captured: this repair opens Settings > System > Recovery and changes nothing itself. Whatever you start from that page is an in-place component reinstall that FrameForge neither performs nor records.'
        os = [ordered]@{ build = $os.currentBuild; displayVersion = $os.displayVersion; generation = $os.generation; readable = [bool]$os.readable }
      }
    }
    'winget-repair' {
      $det = Get-WingetDetection
      # winget-repair is reversible:false and its bootstrap installs a module MACHINE-WIDE
      # into %ProgramFiles%\WindowsPowerShell\Modules. Recording whether the module was
      # already present is what makes the leftover documented instead of silent.
      $mod = [ordered]@{ name='Microsoft.WinGet.Client'; presentBefore=$false; paths=@(); repairCmdletAvailable=$false }
      try { $mod.repairCmdletAvailable = [bool](Get-Command -Name Repair-WinGetPackageManager -ErrorAction SilentlyContinue) } catch {}
      try {
        $found = @(Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -ErrorAction SilentlyContinue)
        $mod.presentBefore = ($found.Count -gt 0)
        $mod.paths = @($found | ForEach-Object { "$($_.ModuleBase)" } | Select-Object -Unique)
      } catch {}
      $lang = ''
      try { $lang = "$script:FFLanguageMode" } catch {}
      if (-not ($lang -match '\S') -or $lang -eq 'Unknown') {
        try { $lang = "$($ExecutionContext.SessionState.LanguageMode)" } catch { $lang = 'unknown' }
      }
      return [ordered]@{ wingetBefore = "$($det.detail)"; wingetClientModule = $mod; languageMode = $lang }
    }
    default {
      if ($script:OptionalFeatureRepairs -contains "$($Repair.id)") {
        # The exact prior State is what makes undo real rather than assumed: restoring a
        # DisabledWithPayloadRemoved feature to plain 'Disabled' would leave the payload
        # on disk, which is NOT where the machine started. Undo reproduces the captured
        # state, including -Remove when that is what it was.
        $name = "$($Repair.optionalFeature)"
        $cap = [ordered]@{ featureName=$name; state=$null; readable=$false; readError=$null; parentFeatures=@() }
        try {
          $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
          $cap.state = "$($f.State)"
          $cap.readable = $true
          try { $cap.parentFeatures = @(@($f.CustomProperties) | ForEach-Object { "$($_.Name)=$($_.Value)" }) } catch {}
        } catch { $cap.readError = "$($_.Exception.Message)" }
        return $cap
      }
      return [ordered]@{ note = 'No state captured for this repair.' }
    }
  }
}

# ---------------- step builders (the fix; exact commands declared next to the code) ----------------

function New-RepairContext {
  param($Repair)
  # Get-FFInvariantStamp, not Get-Date -Format: a custom format string renders through the
  # CurrentCulture's CALENDAR, so on th-TH / ar-SA this produced Buddhist (2569…) or Hijri
  # (1447…) years in backup folder names — timestamps that neither sort nor compare
  # against the ISO 's' timestamps written elsewhere in the same ledger entry.
  $ctx = @{ ts = (Get-FFInvariantStamp); mutations = @(); sourceArg = $null; repairName = "$($Repair.name)" }
  if ($Repair.id -eq 'dism-restorehealth' -and $script:ResolvedSourceArg) { $ctx.sourceArg = $script:ResolvedSourceArg }
  $ctx.dnsProviderKey = $script:ResolvedDnsProviderKey
  $ctx
}

function Test-RestorePointEnforced {
  <# Enforced by default for the aggressive tier and for any repair the catalog marks
     restorePoint:"enforced". -NoRestorePoint is the explicit, recorded opt-out —
     WinUtil's restore point is an opt-IN checkbox, which is the wrong default. #>
  param($Repair)
  if ($NoRestorePoint) { return $false }
  $flag = $null
  try { $flag = "$($Repair.restorePoint)" } catch {}
  if ($flag -eq 'enforced') { return $true }
  if ($flag -eq 'none') { return $false }
  return ("$($Repair.tier)" -eq 'aggressive')
}

$script:SystemRestoreKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

function Get-RestorePointStep {
  <# Same pattern as engine/engine.ps1's Do-RestorePoint: enable System Protection on the
     system drive, TEMPORARILY bypass the once-per-24h creation throttle, then
     Checkpoint-Computer. continueOnFail = $false on purpose: if the safety net cannot be
     created, the aggressive repair does NOT proceed unprotected.

     The throttle bypass is temporary and guaranteed-reverted. Writing
     SystemRestorePointCreationFrequency=0 and walking away is a permanent, system-wide
     policy change (System Restore would then create a checkpoint on EVERY qualifying
     event, forever) left behind by the one step whose entire job is safety — precisely
     the "leaves changes behind, captures nothing" behaviour winutil-dissection.md
     section 8 criticises. So: the prior value (or its absence) is captured, and the
     restore runs in a `finally`, i.e. even when Checkpoint-Computer throws. Both the set
     and the restore are written to the mutation record; a FAILED restore is reported
     loudly instead of being swallowed. #>
  param($Repair)
  @{ name='create-restore-point'; always=$false; continueOnFail=$false; bestEffort=$false
    commands=@(
      'Enable-ComputerRestore -Drive "%SystemDrive%\"',
      "New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force  (TEMPORARY: bypasses the once-per-24h throttle; the prior value — or its absence — is captured first)",
      "Checkpoint-Computer -Description 'FrameForge: before <repair name>' -RestorePointType MODIFY_SETTINGS",
      "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value <captured prior value>  — or Remove-ItemProperty when the value did not exist before. Runs in a finally block, so the throttle is put back even if Checkpoint-Computer fails.")
    exec={ param($ctx)
      $srKey = $script:SystemRestoreKey
      $desc = "FrameForge: before $($ctx.repairName)"
      $priorFreq = $null
      $priorFreqPresent = $false
      try {
        $priorFreq = (Get-ItemProperty -LiteralPath $srKey -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency
        $priorFreqPresent = $true
      } catch {}
      try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue } catch {}

      $throttleBypassed = $false
      $throttleSetError = $null
      try {
        New-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $throttleBypassed = $true
        $ctx.mutations += [ordered]@{
          type='registry'; key=$srKey; name='SystemRestorePointCreationFrequency'
          priorValue=$priorFreq; priorValuePresent=$priorFreqPresent; newValue=0
          temporary=$true
          note='Temporary throttle bypass for this one checkpoint. Reverted in the same step (see the matching registry-restore mutation).'
        }
      } catch { $throttleSetError = "$($_.Exception.Message)" }

      $before = @()
      try { $before = @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object { [int]$_.SequenceNumber }) } catch {}

      $checkpointError = $null
      $restoreNote = 'the throttle bypass was not applied, so there was nothing to put back'
      $restoreOk = $true
      try {
        Checkpoint-Computer -Description $desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
      } catch {
        $checkpointError = "$($_.Exception.Message)"
      } finally {
        # GUARANTEED revert. Runs whether the checkpoint succeeded, failed, or threw.
        if ($throttleBypassed) {
          try {
            if ($priorFreqPresent) {
              Set-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value ([int]$priorFreq) -Type DWord -ErrorAction Stop
              $restoreNote = "the 24h System Restore throttle was put back to its captured prior value ($priorFreq)"
              $ctx.mutations += [ordered]@{ type='registry-restore'; key=$srKey; name='SystemRestorePointCreationFrequency'; how='set'; restoredTo=$priorFreq; ok=$true }
            } else {
              Remove-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Force -ErrorAction Stop
              $restoreNote = 'the 24h System Restore throttle was put back by DELETING SystemRestorePointCreationFrequency, which did not exist before this repair'
              $ctx.mutations += [ordered]@{ type='registry-restore'; key=$srKey; name='SystemRestorePointCreationFrequency'; how='remove'; restoredTo=$null; ok=$true }
            }
          } catch {
            $restoreOk = $false
            $restoreNote = "FAILED to put the 24h System Restore throttle back ($($_.Exception.Message)) — SystemRestorePointCreationFrequency is still 0 on this machine. Fix it by hand under $srKey"
            $ctx.mutations += [ordered]@{ type='registry-restore'; key=$srKey; name='SystemRestorePointCreationFrequency'; how=$(if ($priorFreqPresent) { 'set' } else { 'remove' }); restoredTo=$null; ok=$false; error="$($_.Exception.Message)" }
          }
        }
      }

      if ($checkpointError) {
        throw "Could not create a System Restore checkpoint: $("$checkpointError".TrimEnd('.', ' ')). System Protection is probably off for $env:SystemDrive. Turn it on (SystemPropertiesProtection.exe), or re-run with -NoRestorePoint to proceed deliberately without a checkpoint. Cleaning up after itself either way: $restoreNote."
      }

      $after = @(); $seq = $null; $created = $null
      try {
        $rp = @(Get-ComputerRestorePoint -ErrorAction Stop)
        $after = @($rp | ForEach-Object { [int]$_.SequenceNumber })
        $new = @($after | Where-Object { $before -notcontains $_ })
        if ($new.Count -gt 0) { $seq = ($new | Sort-Object -Descending)[0] }
        if ($null -ne $seq) { $created = @($rp | Where-Object { [int]$_.SequenceNumber -eq [int]$seq }) | Select-Object -First 1 }
      } catch {}
      $ctx.mutations += [ordered]@{
        type='restore-point'; description=$desc; sequenceNumber=$seq
        priorCreationFrequency=$priorFreq
        priorCreationFrequencyPresent=$priorFreqPresent
        throttleBypassApplied=$throttleBypassed
        throttleBypassSetError=$throttleSetError
        throttleRestored=$restoreOk
        throttleRestoreDetail=$restoreNote
        note='Roll back with: Restore-Computer -RestorePoint <sequenceNumber>, or rstrui.exe. The 24h throttle bypass this step needs is temporary — see the registry and registry-restore mutations either side of this one.'
      }
      $tail = " Nothing else was left behind: $restoreNote."
      if (-not $restoreOk) { $tail = " WARNING — $restoreNote." }
      if ($null -ne $seq) { return "System Restore checkpoint created: '$desc' (sequence number $seq). Roll back with 'Restore-Computer -RestorePoint $seq' or rstrui.exe.$tail" }
      "System Restore checkpoint created (its sequence number could not be read back; it is listed in rstrui.exe).$tail"
    } }
}

function Get-ServiceEnableStep {
  <# Blocker the catalog used to lie about: a Disabled service is ALSO Stopped, so it
     lands in the "already stopped" bucket and the restart step reports "nothing to
     restart" while the repair claims fixed:true. This step restores the documented
     default start type — and ONLY for services detection found Disabled, so an
     administrator's deliberate Manual/Automatic choice is never overwritten. The prior
     start type is captured in the ledger before-state and in the mutation record. #>
  param([string]$Name, $Defaults, [string]$Label)
  $pairs = @()
  foreach ($k in $Defaults.Keys) { $pairs += "$k=$($Defaults[$k])" }
  @{ name=$Name; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Set-Service -StartupType <documented default> on any DISABLED service among: $($pairs -join ', ')  (prior start type captured to the ledger; enabled services are left alone). Fallback when Set-Service is refused on a PROTECTED service (appidsvc is the usual one): Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\<name>' -Name Start -Value <2=Automatic|3=Manual> -Type DWord")
    exec={ param($ctx)
      $defaults = $ctx.serviceDefaults
      $reEnabled = @(); $left = @(); $missing = @(); $failed = @(); $reEnabledNames = @()
      foreach ($n in $defaults.Keys) {
        $svc = $null
        try { $svc = Get-Service -Name $n -ErrorAction Stop } catch { $missing += $n; continue }
        $st = $null
        try { $st = "$($svc.StartType)" } catch {}
        if ($st -ne 'Disabled') { $left += "$n ($st)"; continue }
        $target = "$($defaults[$n])"
        try {
          Set-Service -Name $n -StartupType $target -ErrorAction Stop
          $ctx.mutations += [ordered]@{ type='service-starttype'; name=$n; priorStartType='Disabled'; newStartType=$target }
          $reEnabled += "$n (Disabled -> $target)"; $reEnabledNames += $n
        } catch {
          # appidsvc and a few others are protected services: sc.exe/Set-Service are
          # refused, but the Start value under the service key is writable by SYSTEM/BA.
          $done = $false
          try {
            $map = @{ 'Automatic' = 2; 'Manual' = 3; 'Disabled' = 4 }
            Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name Start -Value $map[$target] -Type DWord -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='service-starttype'; name=$n; priorStartType='Disabled'; newStartType=$target; via='registry Start value (protected service)' }
            $reEnabled += "$n (Disabled -> $target, via the registry: protected service)"; $reEnabledNames += $n
            $done = $true
          } catch {}
          if (-not $done) { $failed += "$n ($($_.Exception.Message))" }
        }
      }
      $ctx.reEnabledServices = $reEnabled
      $ctx.reEnabledNames = $reEnabledNames
      $parts = @()
      if ($reEnabled.Count -gt 0) { $parts += "Re-enabled: $($reEnabled -join ', ')" } else { $parts += 'No disabled service found — nothing to re-enable' }
      if ($left.Count -gt 0)     { $parts += "Left untouched (not disabled): $($left -join ', ')" }
      if ($missing.Count -gt 0)  { $parts += "NOT PRESENT on this system, so their start type could not be read or restored: $($missing -join ', ')" }
      if ($failed.Count -gt 0)   { $parts += "FAILED to re-enable: $($failed -join '; ')" }
      if ($failed.Count -gt 0) { throw ($parts -join '. ') }
      # DOCTRINE 2. A service that is not present AT ALL is an unmeasured thing, and this step used
      # to fold it into a cheerful sentence ("Not present on this system: …") and return normally —
      # so the step recorded status 'ok' and, with no other failure, the whole repair reported
      # stepsCompleted = true while the service it exists to re-enable had never been looked at.
      # Every name in these sets is a core Windows client service (wuauserv, cryptSvc, bits,
      # msiserver, appidsvc, WSearch); one of them being absent is a broken or stripped image, not a
      # normal configuration. Throwing makes the step 'failed', which drives stepsCompleted to false
      # and puts the reason in front of the user instead of hiding it in prose.
      # This step is continueOnFail = $true, so the rest of the repair (including its 'always'
      # recovery steps) still runs — the capability degrades explicitly, it is not removed.
      if ($missing.Count -gt 0) {
        throw (($parts -join '. ') + ". These are core Windows services that exist on every supported build, so FrameForge cannot tell whether they were disabled and cannot restore a start type it never read. This is reported as a failed step rather than as a completed one. A missing core service usually means a damaged image: run sfc-scannow and dism-restorehealth.")
      }
      ($parts -join '. ') + '.'
    } }
}

function Get-WuResetSteps {
  param($ctx, [bool]$Aggressive)
  $ctx.serviceDefaults = $WuServiceDefaults
  $steps = @()
  # 1. Re-enable anything DISABLED first. Without this the whole reset is theatre on a
  #    machine whose update services were disabled: they are already Stopped, so the
  #    stop step no-ops, the restart step has nothing to restart, and the repair would
  #    still report fixed:true. (health.ps1 emits wu-service-disabled for exactly this.)
  $steps += Get-ServiceEnableStep -Name 'enable-update-services' -Defaults $WuServiceDefaults -Label 'update pipeline'
  # 2. Drain the BITS job queue while BITS can still be enumerated (WinUtil does the
  #    same, but after stopping the service, where enumeration is unreliable).
  $steps += @{ name='clear-bits-jobs'; always=$false; continueOnFail=$true; bestEffort=$true
    commands=@('Get-BitsTransfer -AllUsers | Remove-BitsTransfer')
    exec={ param($ctx)
      $jobs = @()
      try { $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop) } catch { return "BITS jobs could not be enumerated ($($_.Exception.Message)) — skipping; the qmgr*.dat move below clears the queue anyway." }
      if ($jobs.Count -eq 0) { return 'The BITS job queue is empty — nothing to remove.' }
      $removed = 0; $failed = 0
      foreach ($j in $jobs) { try { Remove-BitsTransfer -BitsJob $j -ErrorAction Stop; $removed++ } catch { $failed++ } }
      $ctx.mutations += [ordered]@{ type='bits-jobs-removed'; removed=$removed; failed=$failed }
      "Removed $removed of $($jobs.Count) stuck BITS transfer job(s); $failed could not be removed."
    } }
  $steps += @{ name='stop-update-services'; always=$false; continueOnFail=$false; bestEffort=$false
    commands=@('Stop-Service -Name wuauserv, cryptSvc, bits, msiserver, appidsvc -Force')
    exec={ param($ctx)
      $stopped=@(); $already=@()
      foreach ($n in @('wuauserv','cryptSvc','bits','msiserver','appidsvc')) {
        $svc = $null
        try { $svc = Get-Service -Name $n -ErrorAction Stop } catch { continue }
        if ("$($svc.Status)" -eq 'Stopped') { $already += $n; continue }
        Stop-Service -Name $n -Force -ErrorAction Stop
        $stopped += $n
        $ctx.mutations += [ordered]@{ type='service-stop'; name=$n }
      }
      $ctx.stoppedServices = $stopped
      $sTxt = '(none)'; if ($stopped.Count -gt 0) { $sTxt = $stopped -join ', ' }
      $aTxt = '(none)'; if ($already.Count -gt 0) { $aTxt = $already -join ', ' }
      "Stopped: $sTxt. Already stopped: $aTxt."
    } }
  # 3. The BITS queue database itself. WinUtil DELETES qmgr*.dat; FrameForge moves them
  #    to %LOCALAPPDATA%\FrameForge\state\backups\ so the ledger points at something recoverable.
  $steps += @{ name='move-bits-queue-files'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Move-Item %ALLUSERSPROFILE%\Microsoft\Network\Downloader\qmgr*.dat -> %LOCALAPPDATA%\FrameForge\state\backups\bits-queue-<timestamp>\  (moved, not deleted)")
    exec={ param($ctx)
      $qdir = Join-Path $env:ALLUSERSPROFILE 'Microsoft\Network\Downloader'
      $files = @()
      try { $files = @(Get-ChildItem -LiteralPath $qdir -Filter 'qmgr*.dat' -File -Force -ErrorAction Stop) } catch { return "The BITS queue folder could not be read ($qdir) — nothing moved." }
      if ($files.Count -eq 0) { return 'No qmgr*.dat queue files present — nothing to move.' }
      $dest = Join-Path $script:BackupDir "bits-queue-$($ctx.ts)"
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      $moved = 0; $failed = 0
      foreach ($f in $files) { try { Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop; $moved++ } catch { $failed++ } }
      $ctx.mutations += [ordered]@{ type='move'; from=$qdir; to=$dest; movedFiles=$moved; failedFiles=$failed }
      "Moved $moved of $($files.Count) BITS queue file(s) to $dest; BITS rebuilds them on next start. $failed still locked."
    } }
  $steps += @{ name='rename-softwaredistribution'; always=$false; continueOnFail=$false; bestEffort=$false
    commands=@("Rename-Item $env:SystemRoot\SoftwareDistribution -> SoftwareDistribution.bak-$($ctx.ts)")
    exec={ param($ctx)
      $src = Join-Path $env:SystemRoot 'SoftwareDistribution'
      if (-not (Test-Path -LiteralPath $src)) { return 'SoftwareDistribution does not exist — nothing to rename.' }
      $newName = "SoftwareDistribution.bak-$($ctx.ts)"
      Rename-Item -LiteralPath $src -NewName $newName -ErrorAction Stop
      $ctx.mutations += [ordered]@{ type='rename'; from=$src; to=(Join-Path $env:SystemRoot $newName) }
      "Renamed SoftwareDistribution -> $newName (recorded in the ledger; delete later to reclaim space)."
    } }
  $steps += @{ name='rename-catroot2'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Rename-Item $env:SystemRoot\System32\catroot2 -> catroot2.bak-$($ctx.ts)")
    exec={ param($ctx)
      $src = Join-Path $env:SystemRoot 'System32\catroot2'
      if (-not (Test-Path -LiteralPath $src)) { return 'catroot2 does not exist — nothing to rename.' }
      $newName = "catroot2.bak-$($ctx.ts)"
      Rename-Item -LiteralPath $src -NewName $newName -ErrorAction Stop
      $ctx.mutations += [ordered]@{ type='rename'; from=$src; to=(Join-Path $env:SystemRoot ('System32\' + $newName)) }
      "Renamed catroot2 -> $newName (recorded in the ledger)."
    } }
  # 4. A stale WinHTTP proxy is one of the most common causes of "Windows Update just
  #    hangs at 0%" — the WU stack uses WinHTTP, not the per-user IE/Edge proxy.
  $steps += @{ name='reset-winhttp-proxy'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@('netsh winhttp reset proxy   (current setting captured via "netsh winhttp show proxy" in the ledger before-state; SKIPPED without running when this machine is WSUS-pinned, MDM-enrolled or domain-joined AND a proxy is actually configured — on a managed network clearing it cuts the machine off from updates rather than fixing them, and this repair is reversible:false so there would be no automatic way back)')
    exec={ param($ctx)
      $before = Get-WinHttpProxySnapshot
      $mgmt = Get-WuManagementState
      # A stale WinHTTP proxy is a common cause of "Windows Update hangs at 0%" on an
      # UNMANAGED machine. On a managed one the proxy is usually mandatory and clearing it
      # is the opposite of a repair — so the managed case is skipped, loudly, instead of
      # being executed and then apologised for in the risks text.
      $hasProxy = $false
      if ($before.readable -and (Test-FFIMatch "$($before.raw)" 'proxyserver|proxy\s*server|=|:\d')) { $hasProxy = $true }
      # Structural rung, because "Direct access (no proxy server)" is LOCALIZED prose: the
      # stored value itself. A direct-access default is a 12-byte blob; anything longer
      # carries a proxy string. Unioned with the text rung on purpose — on a managed
      # machine an ambiguous read must err toward NOT clearing the proxy.
      try {
        $wp = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttpSettings' -Name WinHttpSettings -ErrorAction Stop).WinHttpSettings
        if (@($wp).Count -gt 12) { $hasProxy = $true }
      } catch {}
      $isManaged = ($mgmt.managed -eq $true -or -not $mgmt.policyReadable)
      if ($isManaged -and $hasProxy) {
        $who = @()
        if ($mgmt.wsusManaged) { $who += "pinned to the WSUS server $($mgmt.wsusServer) by Group Policy" }
        if ($mgmt.mdmEnrolled) { $who += "enrolled in MDM ($($mgmt.mdmProviders -join ', '))" }
        if ($mgmt.partOfDomain -eq $true) { $who += "joined to domain $($mgmt.domain)" }
        if (-not $mgmt.policyReadable) { $who += 'and its update policy could not be read, so FrameForge cannot prove it is unmanaged' }
        $ctx.mutations += [ordered]@{ type='winhttp-proxy-reset-skipped'; managed=$true; reason=($who -join '; '); priorSetting="$($before.raw)" }
        return ("SKIPPED — a WinHTTP proxy is configured on a MANAGED machine ($($who -join '; ')). Clearing it would very likely cut this PC off from Windows Update, the Store and activation instead of repairing them, " +
                "and this repair has no automatic undo. Nothing was changed. Current setting: $($before.raw). If you are certain the proxy is stale, clear it deliberately with: netsh winhttp reset proxy")
      }
      $o = & (Join-Path $env:SystemRoot 'System32\netsh.exe') winhttp reset proxy
      $txt = ((@($o) | Where-Object { "$_" -match '\S' }) -join ' ').Trim()
      if ($LASTEXITCODE -ne 0) { throw "netsh winhttp reset proxy failed (exit $LASTEXITCODE): $txt" }
      $ctx.mutations += [ordered]@{
        type='winhttp-proxy-reset'; priorSetting="$($before.raw)"; priorSettingReadable=[bool]$before.readable
        note='This repair is reversible:false — there is NO automatic undo for this step. Re-apply the prior setting BY HAND with: netsh winhttp set proxy "<the priorSetting recorded here>". The same value is in the ledger before-state (winHttpProxy.raw).'
      }
      "WinHTTP proxy reset to direct access (prior setting, recorded in this run's mutation record and in the ledger: $($before.raw) — re-apply it by hand with 'netsh winhttp set proxy' if this was wrong; there is no automatic undo). $txt"
    } }
  # 5. WSUS client identity. On a machine that was once domain-joined or pointed at a
  #    now-dead WSUS server, these values pin Windows Update to a server that no longer
  #    answers. Values are captured (not just deleted) so they can be re-created.
  $steps += @{ name='clear-wsus-client-identity'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -Name AccountDomainSid, PingID, SusClientId, SusClientIdValidation  (prior values captured to the ledger; NOT run when HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\WUServer pins this machine to a live WSUS server — removing a managed client's identity is an administrator action, not a user one)")
    exec={ param($ctx)
      $mgmt = Get-WuManagementState
      # The old version deleted these unconditionally and then claimed "Windows Update will
      # re-register with Microsoft on the next scan." On a WSUS-pinned machine that sentence
      # is simply false — the client re-registers with the WSUS server named by policy — and
      # the forced re-registration makes the machine vanish from the WSUS console until it
      # reports in, which an administrator reads as FrameForge having broken update
      # management. So an actively-pinned machine is now REFUSED, by name, instead.
      if ($mgmt.wsusManaged -eq $true) {
        $ctx.mutations += [ordered]@{ type='wsus-identity-clear-skipped'; managed=$true; wsusServer="$($mgmt.wsusServer)"; useWUServer=$mgmt.useWUServer; targetGroup="$($mgmt.targetGroup)" }
        return ("SKIPPED — nothing was removed. This machine is pinned to the WSUS server $($mgmt.wsusServer) by Group Policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\WUServer). " +
                "Deleting SusClientId / SusClientIdValidation / PingID / AccountDomainSid here would force a full re-registration against THAT server — not against Microsoft — and the machine would disappear from the WSUS console until it next reported in. " +
                'That is an administrator action on a managed fleet, so FrameForge will not take it for you. The policy itself was not touched.')
      }
      if (-not $mgmt.policyReadable) {
        $ctx.mutations += [ordered]@{ type='wsus-identity-clear-skipped'; managed=$null; reason='update policy could not be read'; error="$($mgmt.error)" }
        return ("SKIPPED — nothing was removed. The Windows Update policy key could not be read ($($mgmt.error)), so FrameForge cannot tell whether this machine is pinned to a WSUS server. " +
                'Clearing the client identity on a managed machine is an administrator action, and a failed read is not permission to take it. Check HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\WUServer by hand.')
      }
      $removed = @(); $absent = @(); $failed = @()
      foreach ($n in $script:WsusIdentityValues) {
        $has = $false
        try { $null = Get-ItemProperty -LiteralPath $script:WuPolicyKey -Name $n -ErrorAction Stop; $has = $true } catch { $absent += $n }
        if (-not $has) { continue }
        try {
          Remove-ItemProperty -LiteralPath $script:WuPolicyKey -Name $n -Force -ErrorAction Stop
          $ctx.mutations += [ordered]@{ type='registry-remove'; key=$script:WuPolicyKey; name=$n; note='Prior value is in the ledger before-state (wsusClientIdentity).' }
          $removed += $n
        } catch { $failed += "$n ($($_.Exception.Message))" }
      }
      if ($failed.Count -gt 0) { throw "Removed: $($removed -join ', '). FAILED: $($failed -join '; ')" }
      if ($removed.Count -eq 0) { return 'No WSUS client-identity values were present — this machine is not pinned to a WSUS server. Nothing removed.' }
      # No WUServer policy, so the client really does re-register with Microsoft — unless
      # it is MDM-enrolled or domain-joined, in which case say what is actually true rather
      # than repeating a sentence that only holds on a standalone consumer PC.
      $tail = 'Windows Update will re-register with Microsoft on the next scan.'
      if ($mgmt.mdmEnrolled -eq $true -or $mgmt.partOfDomain -eq $true) {
        $ctxWho = @()
        if ($mgmt.mdmEnrolled -eq $true) { $ctxWho += "MDM-enrolled ($($mgmt.mdmProviders -join ', '))" }
        if ($mgmt.partOfDomain -eq $true) { $ctxWho += "joined to domain $($mgmt.domain)" }
        $tail = ("No WSUS server is set by policy, so the client re-registers on the next scan with whatever update endpoint policy points it at — NOT necessarily Microsoft: this machine is $($ctxWho -join ' and '), " +
                 'so a Windows Update for Business or Intune policy may redirect it. Expect it to re-report itself to that service rather than appear immediately.')
      }
      "Removed WSUS client identity value(s): $($removed -join ', ') (prior values recorded in the ledger). $tail"
    } }
  if ($Aggressive) {
    $sd = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
    # PS 5.1 closures do not capture loop variables per-iteration, so each sdset step is
    # written out explicitly rather than generated in a loop.
    $steps += @{ name='sdset-wuauserv'; always=$false; continueOnFail=$true; bestEffort=$false
      commands=@("sc.exe sdset wuauserv `"$sd`"")
      exec={ param($ctx)
        $sdVal = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
        $o = & (Join-Path $env:SystemRoot 'System32\sc.exe') sdset wuauserv $sdVal
        if ($LASTEXITCODE -ne 0) { throw "sc.exe sdset wuauserv failed (exit $LASTEXITCODE): $((@($o) -join ' '))" }
        $ctx.mutations += [ordered]@{ type='sdset'; service='wuauserv'; newDescriptor=$sdVal }
        'Reset the wuauserv security descriptor to the documented default (prior descriptor is in the ledger before-state).'
      } }
    $steps += @{ name='sdset-bits'; always=$false; continueOnFail=$true; bestEffort=$false
      commands=@("sc.exe sdset bits `"$sd`"")
      exec={ param($ctx)
        $sdVal = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
        $o = & (Join-Path $env:SystemRoot 'System32\sc.exe') sdset bits $sdVal
        if ($LASTEXITCODE -ne 0) { throw "sc.exe sdset bits failed (exit $LASTEXITCODE): $((@($o) -join ' '))" }
        $ctx.mutations += [ordered]@{ type='sdset'; service='bits'; newDescriptor=$sdVal }
        'Reset the BITS security descriptor to the documented default (prior descriptor is in the ledger before-state).'
      } }
  }
  $steps += @{ name='restart-update-services'; always=$true; continueOnFail=$false; bestEffort=$false
    commands=@('Start-Service on each service this run stopped, plus any this run re-enabled from Disabled')
    exec={ param($ctx)
      $toStart = @()
      if ($ctx.ContainsKey('stoppedServices')) { $toStart += @($ctx.stoppedServices) }
      # Services that were DISABLED were never "stopped by this run" (they were already
      # stopped) — but having just re-enabled them, leaving them stopped would be the
      # same silent no-op this repair exists to end.
      if ($ctx.ContainsKey('reEnabledNames')) {
        foreach ($n in @($ctx.reEnabledNames)) { if ($toStart -notcontains $n) { $toStart += $n } }
      }
      if ($toStart.Count -eq 0) { return 'No service was stopped or re-enabled by this run — nothing to restart.' }
      $started=@(); $failed=@()
      foreach ($n in $toStart) {
        try { Start-Service -Name $n -ErrorAction Stop; $started += $n }
        catch { $failed += "$n ($($_.Exception.Message))" }
      }
      if ($failed.Count -gt 0) { throw "Restarted: $($started -join ', '). FAILED to start: $($failed -join '; ')" }
      "Restarted: $($started -join ', ')."
    } }
  $steps += @{ name='trigger-update-scan'; always=$false; continueOnFail=$true; bestEffort=$true
    commands=@('UsoClient.exe StartScan   (exit code checked, not discarded; when the verb is refused or missing on this build, (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() is used instead, and a scan that could not be triggered at all is reported as such)')
    exec={ param($ctx)
      # UsoClient's verbs have changed repeatedly across 21H2..25H2 (wuauclt's were removed
      # outright, several UsoClient verbs were neutered). The old code piped both stdout and
      # $LASTEXITCODE to Out-Null and then claimed the scan had been triggered no matter
      # what happened — and the verify step, finding no NEW failure events, called the
      # repair a success on a machine whose update pipeline was never re-scanned.
      # Do NOT reintroduce wuauclt here: it is dead on every supported build.
      $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
      if (-not (Test-Path -LiteralPath $uso)) {
        $ctx.mutations += [ordered]@{ type='wu-scan-trigger'; tool='UsoClient StartScan'; exitCode=$null; triggered=$false; note='UsoClient.exe not present on this build.' }
        try {
          (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
          $ctx.mutations += [ordered]@{ type='wu-scan-trigger'; tool='Microsoft.Update.AutoUpdate.DetectNow'; exitCode=0; triggered=$true }
          return 'UsoClient.exe is not present on this build; triggered a scan through Microsoft.Update.AutoUpdate.DetectNow() instead.'
        } catch {
          return "COULD NOT TRIGGER A SCAN: UsoClient.exe is not present on this build and Microsoft.Update.AutoUpdate.DetectNow() failed ($($_.Exception.Message)). Open Settings > Windows Update and click Check for updates."
        }
      }
      $out = & $uso StartScan 2>&1
      $code = $LASTEXITCODE
      $ctx.mutations += [ordered]@{ type='wu-scan-trigger'; tool='UsoClient StartScan'; exitCode=$code; triggered=($code -eq 0) }
      if ($code -ne 0) {
        $tail = ((@($out) | ForEach-Object { "$_" } | Where-Object { "$_" -match '\S' }) -join ' | ')
        try {
          (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
          $ctx.mutations += [ordered]@{ type='wu-scan-trigger'; tool='Microsoft.Update.AutoUpdate.DetectNow'; exitCode=0; triggered=$true }
          return "UsoClient StartScan returned exit code $code ($tail); triggered a scan through Microsoft.Update.AutoUpdate.DetectNow() instead."
        } catch {
          return "COULD NOT TRIGGER A SCAN: UsoClient StartScan exited $code ($tail) and Microsoft.Update.AutoUpdate.DetectNow() failed ($($_.Exception.Message)). Open Settings > Windows Update and click Check for updates."
        }
      }
      'Triggered a Windows Update scan (UsoClient StartScan, exit code 0).'
    } }
  $steps
}

# ---------------- CBS.log [SR] marker set ----------------
# SHARED CONTRACT. The identical set is used by engine/health.ps1's system-files probe (search that
# file for '$srCannot'); the two engines must agree, because health.ps1 is the probe that decides
# whether this repair was needed and whether it worked. The set is duplicated rather than moved into
# engine/_lib.ps1 because health.ps1 owns that file and the two are maintained in parallel — if you
# change one, change the other.
#
# WHAT IS AND IS NOT SOURCED. docs/research/repair-ladder.md documents only the three ENGLISH CONSOLE
# strings sfc.exe prints; it validates none of these log markers. Everything below is therefore
# either a marker observed verbatim in real CBS logs or nothing at all — no marker is invented to
# make a bucket fire, and anything unrecognised falls through to outcome=$null ("could not
# determine"), never to 'clean'.
#
# THE BUGS THIS SPELLING FIXES:
#  1. "[SR] Cannot verify component files for <x>, hashes for file member do not match" matched
#     NEITHER the cannot-repair nor the repaired pattern, so a log carrying it plus a 'Verify
#     complete' graded CLEAN. It is a corruption signal and now has its own bucket.
#  2. REGRESSION, fixed here and never to be reintroduced: 'complete' was once widened to OR in
#     '\[SR\]\s+Verifying\s+\d+', the line the component store writes when a verification pass
#     STARTS. A scan that was killed, timed out, or aborted mid-transaction writes 'Beginning
#     Verify and Repair transaction' plus one or more 'Verifying N (0x...) components' lines and
#     then simply stops — and with that alternative in place an sfc pass that only BEGAN graded
#     outcome='clean'. START IS NOT COMPLETION. health.ps1 models this correctly (search that file
#     for '$srComplete' / '$srStarted') and this set now mirrors it exactly:
#       complete  ONLY the real terminators, '[SR] Verify complete' / '[SR] Repair complete'
#       started   a SEPARATE set that grades NOTHING. It is read only to word the honest unknown
#                 ("the scan started but never finished"), exactly as health.ps1 uses $srStarted.
#     A started-but-unterminated scan is therefore outcome=$null (indeterminate), never 'clean'.
$script:SfcSrMarkers = [ordered]@{
  # At least one corrupt file could NOT be repaired.
  cannotRepair = '\[SR\]\s+Cannot repair member file'
  # A file whose hashes do not match. Corruption named; repair status decided by the other buckets.
  cannotVerify = '\[SR\]\s+Cannot verify component files'
  # Corruption found and repaired. Both the '-ing' and '-ed' spellings occur, with and without
  # the word 'corrupted'.
  repaired     = '\[SR\]\s+Repair(ing|ed)\s+corrupted\s+file|\[SR\]\s+Repair(ing|ed)\s+file'
  # COMPLETION MEANS COMPLETION. Terminators only — the same two health.ps1 accepts. Nothing that
  # merely announces a pass belongs in this bucket.
  complete     = '\[SR\]\s+(Verify|Repair)\s+complete'
  # NOT a verdict. 'Verifying \d+' deliberately stops before 'components' so the "(0x00000064)" the
  # component store writes between them cannot break the match. Counted so an unterminated scan can
  # be NAMED as unterminated; it can never grade a run.
  started      = '\[SR\]\s+Verifying\s+\d+|\[SR\]\s+Beginning Verify and Repair transaction'
}

function Get-SfcCbsOutcome {
  <#
    Decide the outcome of an SFC pass from the CBS servicing log instead of from sfc.exe's
    localized console text.

    Why this is a legitimate rung and not just a different string match: CBS.log is a servicing
    TRACE written by the component store, not UI. Its [SR] markers are emitted in English on every
    UI language. It is still text, so its failure mode is 'could not determine', never 'clean'.

    BLOCKER THIS FIXES — TIME SCOPING. This function used to grade the run from the last 6000 [SR]
    lines with NO time bound at all, so it graded TODAY's scan using a scan from weeks ago. On a
    localized Windows this is the DECIDING rung (rung 1, sfc's English console text, never matches
    there), so a German or Japanese user got "SFC: no integrity violations found" and
    stepsCompleted=true for a scan that produced no evidence whatsoever. Reproduced in a harness
    before the fix: a log whose only [SR] lines were dated three weeks earlier returned
    outcome='clean'; a 40-day-old 'Cannot repair member file' returned outcome='unfixable' and was
    applied as an override outranking the console text. health.ps1 already defends against exactly
    this and says so in a comment ("a 'Verify complete' left over from a previous scan must never be
    allowed to grade today's one"). -Since is now REQUIRED in effect: with no line attributable to
    this run the answer is $null, not a verdict.

    CBS lines look like: "2026-08-30 12:34:56, Info    CBS    [SR] Verify complete".
    The leading stamp is local wall-clock written by another process, so callers pass a start time
    with a few seconds of skew allowance.

    Returns @{ outcome; evidence; readable; error; logPath; since; srLinesTotal; srLinesThisRun;
               timestamped; markers }. outcome is one of clean|repaired|unfixable|$null, and $null
    means the log could not decide — the caller must then report indeterminate.
  #>
  param([datetime]$Since, [int]$TailLines = 6000)
  $out = [ordered]@{
    outcome = $null; evidence = @(); readable = $false
    logPath = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'); error = $null
    since = $null; srLinesTotal = 0; srLinesThisRun = 0; timestamped = $false
    markers = [ordered]@{ cannotRepair = 0; cannotVerify = 0; repaired = 0; complete = 0; started = 0; unrecognised = 0 }
  }
  if ($PSBoundParameters.ContainsKey('Since') -and $null -ne $Since) { $out.since = $Since.ToString('s') }
  $all = @()
  try {
    # -Encoding UTF8 matches health.ps1's read of the same file, so the two engines cannot decode
    # the same bytes differently. Test-FFIMatch, not -match: see the culture-pin note at the top.
    $all = @(Get-Content -LiteralPath $out.logPath -Tail $TailLines -Encoding UTF8 -ErrorAction Stop |
             Where-Object { Test-FFIMatch "$_" '\[SR\]' } | ForEach-Object { "$_".Trim() })
    $out.readable = $true
  } catch { $out.error = "$($_.Exception.Message)"; return $out }
  $out.srLinesTotal = $all.Count
  if ($all.Count -eq 0) { $out.error = "The CBS log holds no [SR] lines in its last $TailLines lines."; return $out }

  # ---- attribute every line to THIS run, or to no run at all ----
  $lines = @()
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  foreach ($line in $all) {
    $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
    if (-not $m.Success) { continue }
    $out.timestamped = $true
    $ts = $null
    try { $ts = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $inv) } catch {}
    if ($null -eq $ts) { continue }
    if ($null -eq $out.since -or $ts -ge $Since) { $lines += $line }
  }
  $out.srLinesThisRun = $lines.Count
  if ($lines.Count -eq 0) {
    if (-not $out.timestamped) {
      $out.error = "The CBS log's $($all.Count) [SR] line(s) carry no parseable leading timestamp, so none of them could be attributed to this scan. The outcome is NOT graded from lines that may belong to a previous run."
    } else {
      $out.error = "None of the CBS log's $($all.Count) recent [SR] line(s) were written at or after this scan started ($($out.since)), so this scan left no evidence in the log. An older scan's lines are deliberately NOT used to grade it."
    }
    return $out
  }

  $cannotRepair = @($lines | Where-Object { Test-FFIMatch "$_" $script:SfcSrMarkers.cannotRepair })
  $cannotVerify = @($lines | Where-Object { Test-FFIMatch "$_" $script:SfcSrMarkers.cannotVerify })
  $repaired     = @($lines | Where-Object { Test-FFIMatch "$_" $script:SfcSrMarkers.repaired })
  $complete     = @($lines | Where-Object { Test-FFIMatch "$_" $script:SfcSrMarkers.complete })
  # Recognised, but a verdict for NOBODY: these say a pass began, not that it finished.
  $started      = @($lines | Where-Object { Test-FFIMatch "$_" $script:SfcSrMarkers.started })
  $out.markers.cannotRepair = $cannotRepair.Count
  $out.markers.cannotVerify = $cannotVerify.Count
  $out.markers.repaired     = $repaired.Count
  $out.markers.complete     = $complete.Count
  $out.markers.started      = $started.Count
  $out.markers.unrecognised = @($lines | Where-Object {
      -not (Test-FFIMatch "$_" $script:SfcSrMarkers.cannotRepair) -and
      -not (Test-FFIMatch "$_" $script:SfcSrMarkers.cannotVerify) -and
      -not (Test-FFIMatch "$_" $script:SfcSrMarkers.repaired) -and
      -not (Test-FFIMatch "$_" $script:SfcSrMarkers.complete) -and
      -not (Test-FFIMatch "$_" $script:SfcSrMarkers.started) }).Count

  if ($cannotRepair.Count -gt 0) {
    $out.outcome = 'unfixable'
    $out.evidence = @($cannotRepair | Select-Object -Last 5)
  } elseif ($repaired.Count -gt 0) {
    $out.outcome = 'repaired'
    $out.evidence = @($repaired | Select-Object -Last 5)
  } elseif ($cannotVerify.Count -gt 0) {
    # Hashes that do not match, and NOTHING in this run's log says those files were repaired. That
    # is corruption left in place, so it is graded exactly like a cannot-repair rather than being
    # allowed to sit next to a 'Verify complete' and pass as clean. The user-facing advice for
    # 'unfixable' (re-run DISM RestoreHealth from media, then SFC) is the right advice here too.
    $out.outcome = 'unfixable'
    $out.evidence = @($cannotVerify | Select-Object -Last 5)
  } elseif ($complete.Count -gt 0) {
    $out.outcome = 'clean'
    $out.evidence = @($complete | Select-Object -Last 3)
  } elseif ($started.Count -gt 0) {
    # STARTED IS NOT COMPLETE. The pass announced itself and then stopped: killed, timed out, or
    # aborted mid-transaction. There is no terminator, so there is no verdict — and this branch
    # exists precisely so the start markers can NAME the reason without ever grading the run.
    # Same reasoning, same words, as health.ps1's 'sfc-verify-indeterminate' rung.
    $out.error = "The scan STARTED ($($started.Count) '[SR] Verifying ... components' / 'Beginning Verify and Repair transaction' entries written at or after it began) but CBS.log records no '[SR] Verify complete' or '[SR] Repair complete' terminator for this run, so the verification did NOT finish and its outcome CANNOT be determined. An unterminated scan is never graded clean."
    $out.evidence = @($started | Select-Object -Last 3)
  } else {
    # ESCAPE HATCH, deliberately explicit: this run DID write [SR] lines, and not one of them is a
    # marker this parse understands. That is 'could not determine', and inventing a verdict from
    # unrecognised text is the exact failure doctrine rule 2 exists to prevent.
    $out.error = "This scan wrote $($lines.Count) CBS [SR] line(s), none of which carries a marker this parse understands, so the outcome CANNOT be determined from the log. Sample: $((@($lines | Select-Object -Last 3)) -join ' // ')"
    $out.evidence = @($lines | Select-Object -Last 3)
  }
  $out
}

function Get-SfcStep {
  <#
    LOCALE BLOCKER this replaces: the outcome used to be decided ONLY by matching
    'did not find any integrity violations' / 'successfully repaired' / 'unable to fix' in
    sfc.exe's console output. sfc.exe exits 0 even when it reports files it could not
    repair, so on every non-English UI the result fell through to sfcOutcome='indeterminate',
    the `if ($ctx.sfcOutcome -eq 'unfixable')` guard in Invoke-RepairRun never fired, and
    the run record reported stepsCompleted/fixed = true for a repair SFC had explicitly
    said it could not complete — while the follow-up advice to re-run DISM with -SourcePath
    was never shown. That is doctrine rule 2 broken in the worst direction.

    Layered decision now, and every rung is recorded in the ledger mutation so the claim is
    auditable:
      0. exit code  — non-zero is a hard failure, whatever any text says
      1. the CBS.log [SR] lines WRITTEN BY THIS RUN, which the component store emits in English on
         every UI language. Rung 1 rather than rung 2 because it is the locale-independent one, and
         because it is the only rung that can tell a localized machine's "repaired everything" from
         "could not repair some of it". This matches health.ps1, which orders its rungs the same way
         for the same reason — the probe and the repair must not grade the same machine differently.
      2. sfc's own console text, DOCUMENTED as English-only (kept so an en-US machine whose CBS.log
         is unreadable still gets an answer; never reached on a localized one)
      3. honest 'indeterminate' — and Invoke-RepairRun treats indeterminate exactly like unfixable,
         because a result nobody read is not a completed repair.
    Whichever rung answers, an 'unfixable' from EITHER wins: the safe direction is always "this is
    not finished".

    TIME SCOPING (the blocker): $sfcStart is captured BEFORE sfc.exe is invoked and only [SR] lines
    stamped at or after it are read. Without that, a 'Verify complete' from a scan weeks ago graded
    today's run — and on a localized machine, where rung 2 never matches, it was the deciding rung.
  #>
  @{ name='sfc-scannow'; always=$false; continueOnFail=$false; bestEffort=$false
    commands=@('sfc.exe /scannow   (outcome decided by exit code, then the [SR] markers written to %SystemRoot%\Logs\CBS\CBS.log AT OR AFTER this scan started, then sfc''s English console text — an outcome that none of those can establish is reported as indeterminate, never as success)')
    exec={ param($ctx)
      $cbsLog = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
      # 5 s of skew allowance: CBS.log timestamps are local wall-clock written by another process.
      # Identical allowance and identical reason as health.ps1's system-files probe.
      $sfcStart = (Get-Date).AddSeconds(-5)
      $raw = & (Join-Path $env:SystemRoot 'System32\sfc.exe') /scannow
      $code = $LASTEXITCODE
      # sfc emits UTF-16; strip interleaved NULs so text matching works (same as health.ps1).
      $txt = ((@($raw) | ForEach-Object { "$_" }) -join ' ') -replace "`0", ''

      # Rung 1: the servicing log, scoped to THIS run.
      $cbs = Get-SfcCbsOutcome -Since $sfcStart
      $outcome = $null; $decidedBy = $null
      if ($null -ne $cbs.outcome) { $outcome = $cbs.outcome; $decidedBy = 'cbs-log-sr-markers (this run only)' }

      # Rung 2: sfc's own words. English-only by construction — it simply does not match anywhere
      # else, which is why it is not allowed to be the deciding rung.
      # Test-FFIMatch, not -match: -match's IgnoreCase folding is culture-bound (see the culture-pin
      # note at the top of this file), and these three strings decide a repair's verdict.
      $consoleOutcome = $null
      if     (Test-FFIMatch $txt 'did not find any integrity violations') { $consoleOutcome = 'clean' }
      elseif (Test-FFIMatch $txt 'unable to fix')                         { $consoleOutcome = 'unfixable' }
      elseif (Test-FFIMatch $txt 'successfully repaired')                 { $consoleOutcome = 'repaired' }
      if ($null -eq $outcome -and $null -ne $consoleOutcome) { $outcome = $consoleOutcome; $decidedBy = 'sfc-console-text-english' }

      # An 'unfixable' from EITHER rung outranks a cheerful answer from the other: if the log says a
      # member file could not be repaired, or sfc says it was unable to fix, the repair did not
      # complete, full stop.
      # The override test keys on the two rungs DISAGREEING, not on $outcome still being unset:
      # rung 1 above may already have set $outcome from the CBS log, which would leave
      # `$outcome -ne 'unfixable'` permanently false and make this branch dead for the exact case it
      # exists to record — the log reporting a member file it could not repair while sfc's console
      # text says all clear. The verdict was right either way; the audit trail was not.
      if ($cbs.outcome -eq 'unfixable' -and $null -ne $consoleOutcome -and $consoleOutcome -ne 'unfixable') {
        $outcome = 'unfixable'; $decidedBy = 'cbs-log-sr-markers (this run only; overrode the console text)'
      }
      elseif ($cbs.outcome -eq 'unfixable' -and $outcome -ne 'unfixable') { $outcome = 'unfixable'; $decidedBy = 'cbs-log-sr-markers (this run only)' }
      elseif ($consoleOutcome -eq 'unfixable' -and $outcome -ne 'unfixable') { $outcome = 'unfixable'; $decidedBy = 'sfc-console-text-english (overrode the CBS log)' }

      if ($null -eq $outcome) { $outcome = 'indeterminate'; $decidedBy = 'none — no rung could decide' }
      $ctx.sfcOutcome = $outcome
      $ctx.mutations += [ordered]@{
        type='sfc-scannow'; exitCode=$code; outcome=$outcome; decidedBy=$decidedBy
        cbsLogPath=$cbsLog; cbsLogReadable=[bool]$cbs.readable; cbsLogError=$cbs.error
        # The whole grading window and what was found in it, so the claim is auditable from the
        # ledger alone rather than having to be taken on trust.
        cbsWindowStart=$sfcStart.ToString('s'); cbsSrLinesTotal=$cbs.srLinesTotal
        cbsSrLinesThisRun=$cbs.srLinesThisRun; cbsMarkers=$cbs.markers
        consoleOutcomeEnglish=$consoleOutcome
        cbsEvidence=@($cbs.evidence)
      }

      if ($code -ne 0) { throw "sfc /scannow failed (exit code $code). See $cbsLog." }

      $ev = ''
      if (@($cbs.evidence).Count -gt 0) { $ev = " CBS.log [SR] evidence from this run: $((@($cbs.evidence) | Select-Object -First 2) -join ' // ')" }
      switch ($outcome) {
        'clean'     { return "SFC: no integrity violations found (decided by: $decidedBy).$ev" }
        'repaired'  { return "SFC: corrupt files were found and successfully repaired (decided by: $decidedBy; details: $cbsLog, [SR] lines). Reboot recommended.$ev" }
        'unfixable' { return "SFC: corrupt files were found but some could NOT be fixed (decided by: $decidedBy) — re-run dism-restorehealth with -SourcePath (a mounted same-build ISO), then SFC again.$ev" }
      }
      ("SFC exited 0, but FrameForge COULD NOT DETERMINE what it found: sfc's console text is localized on this machine, and the CBS log carried no [SR] line this scan can be graded from" +
       "$(if ($cbs.error) { " ($($cbs.error))" }). This is NOT a completed repair — the run is reported as not completed rather than claiming success on a result nobody read. Read $cbsLog yourself (search for '[SR]'), or re-run dism-restorehealth with -SourcePath.")
    } }
}

function Get-RepairSteps {
  <# Wrapper: prepends the enforced System Restore checkpoint where the catalog (or the
     aggressive tier) demands one. Keeping it here means EVERY consumer of the step list
     — preflight, dry run, real run, and the whatItRuns self-test — sees the same list. #>
  param($Repair, $ctx)
  $ctx.repairName = "$($Repair.name)"
  $core = @(Get-RepairStepsCore $Repair $ctx)
  if (Test-RestorePointEnforced $Repair) { return @(Get-RestorePointStep $Repair) + $core }
  $core
}

function Get-RepairStepsCore {
  param($Repair, $ctx)
  switch ($Repair.id) {
    'wu-reset'            { return @(Get-WuResetSteps $ctx $false) }
    'wu-reset-aggressive' { return @(Get-WuResetSteps $ctx $true) }
    'dism-restorehealth' {
      # With no -SourcePath the engine really does run the bare command — and says so,
      # while still disclosing the switch it would add if one were given. Rendering the
      # disclosure keeps the catalog's whatItRuns line literally identical to what the
      # engine emits for a default invocation, which is what selftest now enforces.
      # /English FIRST, on both the disclosed line and the real invocation. DISM's console output is
      # MUI-localized; the success-line scrape below and the failure tail recorded in the ledger are
      # English by construction, so without /English they are dead text on ~70% of installs — the
      # failure tail a user is asked to read back would arrive in a language the catalog never
      # described. /English changes only the OUTPUT LANGUAGE, never the operation or the exit code,
      # which is what makes it safe to add to a documented command. image.ps1 already passes it to
      # its own `Dism.exe /English /Online /Get-Intl` for the same reason.
      $dismCmd = 'Dism.exe /English /Online /Cleanup-Image /RestoreHealth  [+ /Source:WIM:<path>:<index> /LimitAccess  or  /Source:ESD:<path>:<index> /LimitAccess  when -SourcePath is given]'
      if ($ctx.sourceArg) { $dismCmd = "Dism.exe /English /Online /Cleanup-Image /RestoreHealth $($ctx.sourceArg) /LimitAccess" }
      $steps = @()
      $steps += @{ name='dism-restorehealth'; always=$false; continueOnFail=$false; bestEffort=$false
        commands=@($dismCmd)
        exec={ param($ctx)
          $dismArgs = @('/English','/Online','/Cleanup-Image','/RestoreHealth')
          if ($ctx.sourceArg) { $dismArgs += $ctx.sourceArg; $dismArgs += '/LimitAccess' }
          $raw = & (Join-Path $env:SystemRoot 'System32\Dism.exe') @dismArgs
          $code = $LASTEXITCODE
          $txt = ((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
          $ctx.mutations += [ordered]@{ type='dism-restorehealth'; exitCode=$code; usedSource=("$($ctx.sourceArg)" -ne ''); englishForced=$true }
          if ($code -eq 0 -or $code -eq 3010) {
            $msg = "DISM RestoreHealth completed (exit code $code)."
            # Cosmetic only: the verdict is the EXIT CODE above, and this scrape merely upgrades the
            # wording when DISM's own sentence is available. Culture-invariant so the Turkish-I
            # casing rules cannot silently drop it.
            $m = [regex]::Match($txt, '(?m)^(The restore operation completed successfully.*)$', $script:FFReIC)
            if ($m.Success) { $msg = "DISM: $($m.Groups[1].Value)" }
            if ($code -eq 3010) { $msg = "$msg A reboot is required to finish." }
            return $msg
          }
          $tail = (@(($txt -split "`n") | Where-Object { "$_" -match '\S' } | Select-Object -Last 3) -join ' | ')
          throw "DISM RestoreHealth failed (exit code $code). Log: $(Join-Path $env:SystemRoot 'Logs\DISM\dism.log'). Tail: $tail"
        } }
      $steps += Get-SfcStep
      return $steps
    }
    'sfc-scannow' { return @(Get-SfcStep) }
    'wu-repair-reinstall' {
      # The missing rung between "DISM/SFC did not fix it" and "30-90 minutes of ISO
      # in-place repair". Settings > System > Recovery > "Fix problems using Windows
      # Update" > Reinstall now does the same component replacement from Windows Update
      # with ONE reboot and no ISO. It exists on Windows 11 23H2 (22631) and newer, which
      # is why the catalog entry carries minBuild 22631 rather than being hidden or hacked
      # in as a special case.
      #
      # This is a GUIDED handoff on purpose. The flow is a Settings UI action with no
      # documented CLI, so FrameForge opens the page and says exactly what to click. It
      # does NOT try to script the click, and it does not claim to have run anything.
      return @(
        @{ name='open-recovery-settings'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Start-Process ms-settings:recovery   (opens Settings > System > Recovery; the user clicks "Fix problems using Windows Update" > Reinstall now)')
          exec={ param($ctx)
            Start-Process 'ms-settings:recovery' -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='guided-handoff'; target='ms-settings:recovery'; note='FrameForge opened the Settings page only. Nothing was reinstalled by this step, and the run result does not claim otherwise — the reinstall is a UI action the user performs.' }
            ('Opened Settings > System > Recovery. Click "Fix problems using Windows Update", then "Reinstall now". Windows re-downloads and replaces the current build''s system files from Windows Update, ' +
             'keeping your files, apps and settings, and reboots ONCE. It takes roughly 20-40 minutes on a normal connection. ' +
             'FrameForge only opened the page: it cannot click the button for you, and this run does NOT report the reinstall as done — re-run the system-files probe after the reboot to confirm.')
          } }
      )
    }
    'network-flush' {
      return @(
        @{ name='flush-dns'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('ipconfig /flushdns')
          exec={ param($ctx)
            $raw = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns
            if ($LASTEXITCODE -ne 0) { throw "ipconfig /flushdns failed (exit code $LASTEXITCODE)." }
            $ctx.mutations += [ordered]@{ type='dns-flush' }
            'DNS resolver cache flushed.'
          } },
        @{ name='release-dhcp-lease'; always=$false; continueOnFail=$true; bestEffort=$false
          commands=@('ipconfig /release')
          exec={ param($ctx)
            $raw = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /release
            $ctx.mutations += [ordered]@{ type='dhcp-release'; exitCode=$LASTEXITCODE }
            if ($LASTEXITCODE -ne 0) { return "ipconfig /release exited $LASTEXITCODE (normal on adapters with static IPs) — continuing to renew." }
            'DHCP lease released (connectivity drops until renew completes).'
          } },
        @{ name='renew-dhcp-lease'; always=$true; continueOnFail=$false; bestEffort=$false
          commands=@('ipconfig /renew')
          exec={ param($ctx)
            $raw = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /renew
            $ctx.mutations += [ordered]@{ type='dhcp-renew'; exitCode=$LASTEXITCODE }
            if ($LASTEXITCODE -ne 0) { throw "ipconfig /renew failed (exit code $LASTEXITCODE) — check the adapter; the captured pre-repair configuration is in the ledger." }
            'DHCP lease renewed.'
          } }
      )
    }
    'winsock-reset' {
      return @(
        @{ name='winsock-reset'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('netsh winsock reset')
          exec={ param($ctx)
            $raw = & (Join-Path $env:SystemRoot 'System32\netsh.exe') winsock reset
            $txt = (@($raw) | ForEach-Object { "$_" }) -join ' '
            $ctx.mutations += [ordered]@{ type='winsock-reset'; exitCode=$LASTEXITCODE }
            if ($LASTEXITCODE -ne 0) { throw "netsh winsock reset failed (exit code $LASTEXITCODE): $txt" }
            'Winsock catalog reset. A reboot is required to complete it.'
          } },
        @{ name='ip-stack-reset'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('netsh int ip reset "%LOCALAPPDATA%\FrameForge\state\logs\ip-reset-<timestamp>.log"   (an explicit log path, so a non-zero exit can be judged by whether netsh actually wrote a reset log instead of by matching English words in its output)')
          exec={ param($ctx)
            # LOCALE: `netsh int ip reset` normally exits NON-ZERO because a handful of
            # ACL-protected registry subkeys report access denied — a known benign result.
            # The old code recognised that only by matching the English word 'resetting',
            # so on a localized Windows a SUCCESSFUL reset was thrown as a failure, the run
            # was marked failed, later steps were skipped, and the user was invited to run
            # it again on a stack that had already been reset and only needed a reboot.
            # The structural signal is the log file netsh writes as it works.
            $logDir = Join-Path $script:StateDir 'logs'
            try { if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } } catch {}
            $logPath = Join-Path $logDir "ip-reset-$($ctx.ts).log"
            $raw = & (Join-Path $env:SystemRoot 'System32\netsh.exe') int ip reset $logPath
            $code = $LASTEXITCODE
            $txt = (@($raw) | ForEach-Object { "$_" }) -join "`n"
            $logBytes = $null
            try { if (Test-Path -LiteralPath $logPath) { $logBytes = [int64](Get-Item -LiteralPath $logPath -Force).Length } } catch {}
            $ctx.mutations += [ordered]@{ type='ip-stack-reset'; exitCode=$code; logPath=$logPath; logBytes=$logBytes }
            if ($code -eq 0) { return "TCP/IP stack reset to defaults (exit code 0; log: $logPath). A reboot is required to complete it." }
            if ($null -ne $logBytes -and $logBytes -gt 0) {
              return ("IP stack reset APPLIED with benign warnings (exit code $code — 5 / ERROR_ACCESS_DENIED on a few ACL-protected subkeys is the normal result even when the reset succeeds). " +
                      "netsh wrote $logBytes bytes to $logPath, which is the proof it did the work. A reboot is still required; do NOT re-run this.")
            }
            $tail = (@(($txt -split "`n") | Where-Object { "$_" -match '\S' } | Select-Object -Last 3) -join ' | ')
            throw "netsh int ip reset failed (exit code $code) and wrote no reset log to $logPath, so the stack was NOT reset. Output tail: $tail"
          } }
      )
    }
    'dns-change-resolver' {
      # Render the EXACT command for the chosen provider — "<provider IPv4 + IPv6>" would
      # be a placeholder, and doctrine rule 5 says the catalog shows what actually runs.
      # data/repairs.json's whatItRuns carries this same line rendered for the DEFAULT
      # provider, and selftest compares them character-for-character.
      $pk = $script:ResolvedDnsProviderKey
      if (-not $pk) { $pk = $script:DefaultDnsProviderKey }
      $pv = $DnsProviders[$pk]
      if ($pk -eq 'dhcp') {
        $dnsCmdText = 'Set-DnsClientServerAddress -InterfaceIndex <each connected physical adapter> -ResetServerAddresses   (-DnsProvider dhcp: hand DNS back to whatever DHCP hands out)'
      } else {
        $v4 = @($pv.ipv4) -join ', '
        $v6 = @($pv.ipv6) -join ', '
        $dnsCmdText = "Set-DnsClientServerAddress -InterfaceIndex <each connected physical adapter> -ServerAddresses $v4  [+ $v6 on adapters with IPv6 bound]   (-DnsProvider $pk = $($pv.name))"
      }
      return @(
        @{ name='set-dns-servers'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@($dnsCmdText)
          exec={ param($ctx)
            $key = $ctx.dnsProviderKey
            $prov = $script:DnsProviders[$key]
            $adapters = @()
            try { $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { "$($_.Status)" -eq 'Up' }) } catch { throw "Could not enumerate network adapters: $($_.Exception.Message)" }
            if ($adapters.Count -eq 0) { throw 'No connected physical network adapter — there is nothing to point at a different resolver.' }
            $done = @(); $failed = @()
            foreach ($a in $adapters) {
              try {
                if ($key -eq 'dhcp') {
                  Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                  $ctx.mutations += [ordered]@{ type='dns-servers'; adapter="$($a.Name)"; ifIndex=[int]$a.ifIndex; newServers=@(); reset=$true }
                  $done += "$($a.Name) -> automatic (DHCP)"
                } else {
                  $addrs = @($prov.ipv4)
                  # IPv6 resolvers are only set on adapters that actually have IPv6 bound,
                  # otherwise the cmdlet errors and the whole adapter would be skipped.
                  $hasV6 = $false
                  try { $hasV6 = [bool](Get-NetAdapterBinding -InterfaceAlias $a.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop).Enabled } catch {}
                  if ($hasV6) { $addrs += @($prov.ipv6) }
                  Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $addrs -ErrorAction Stop
                  $ctx.mutations += [ordered]@{ type='dns-servers'; adapter="$($a.Name)"; ifIndex=[int]$a.ifIndex; newServers=$addrs; reset=$false }
                  $done += "$($a.Name) -> $($addrs -join ', ')"
                }
              } catch { $failed += "$($a.Name) ($($_.Exception.Message))" }
            }
            if ($done.Count -eq 0) { throw "No adapter could be changed: $($failed -join '; ')" }
            $msg = "Set the $($prov.name) resolver on: $($done -join '; ')."
            if ($failed.Count -gt 0) { $msg = "$msg Failed on: $($failed -join '; ')." }
            "$msg Prior per-adapter DNS servers are in the ledger before-state, and undo restores them."
          } },
        @{ name='flush-dns-cache'; always=$true; continueOnFail=$true; bestEffort=$true
          commands=@('ipconfig /flushdns')
          exec={ param($ctx)
            $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns
            $ctx.mutations += [ordered]@{ type='dns-flush' }
            'Flushed the resolver cache so the new servers are used immediately.'
          } }
      )
    }
    'chkdsk-scan' {
      return @(
        @{ name='chkdsk-online-scan'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Repair-Volume -DriveLetter <system drive> -Scan      (equivalent to "chkdsk C: /scan": online, read-only, no lock, never repairs)')
          exec={ param($ctx)
            $letter = $env:SystemDrive.TrimEnd(':')
            $r = $null
            try { $r = Repair-Volume -DriveLetter $letter -Scan -ErrorAction Stop } catch { throw "Repair-Volume -Scan failed on ${letter}: $($_.Exception.Message)" }
            $res = "$r"
            $ctx.chkdskScanResult = $res
            $ctx.mutations += [ordered]@{ type='chkdsk-scan'; drive="${letter}:"; result=$res; readOnly=$true }
            if (Test-FFIMatch $res 'NoErrorsFound') { return "Online scan of ${letter}: found no file-system errors (result: $res). Nothing was repaired because nothing needed repairing." }
            "Online scan of ${letter}: returned '$res'. This scan NEVER repairs — escalate to chkdsk-spotfix (fast, targeted) or chkdsk-full-repair (offline, next boot)."
          } }
      )
    }
    'chkdsk-spotfix' {
      return @(
        @{ name='chkdsk-spotfix'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Repair-Volume -DriveLetter <system drive> -SpotFix   (equivalent to "chkdsk C: /spotfix": fixes only what the scan already flagged)')
          exec={ param($ctx)
            $letter = $env:SystemDrive.TrimEnd(':')
            $r = $null
            try { $r = Repair-Volume -DriveLetter $letter -SpotFix -ErrorAction Stop }
            catch {
              throw ("Repair-Volume -SpotFix failed on ${letter}: $($_.Exception.Message). On the volume Windows is running from, SpotFix needs the volume offline for a few seconds; " +
                     'Windows normally defers that to the next restart. If this reports the volume is in use, restart and re-run, or use chkdsk-full-repair which schedules the offline pass explicitly.')
            }
            $res = "$r"
            $ctx.spotfixResult = $res
            $ctx.mutations += [ordered]@{ type='chkdsk-spotfix'; drive="${letter}:"; result=$res }
            if (Test-FFIMatch $res 'NoErrorsFound') { return "SpotFix ran on ${letter}: and found nothing queued to fix (result: $res)." }
            "SpotFix on ${letter}: returned '$res'. Restart to let any deferred correction complete, then re-run the disk probe."
          } }
      )
    }
    'chkdsk-full-repair' {
      return @(
        @{ name='schedule-offline-chkdsk'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('chkdsk.exe <system drive> /f /r   (answering Y to "schedule this volume to be checked the next time the system restarts?" — the system volume can never be checked while Windows is running. Whether the check was actually scheduled is then read STRUCTURALLY from HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\BootExecute and the volume dirty bit, not from chkdsk''s output text)')
          exec={ param($ctx)
            $drive = "$env:SystemDrive"
            $chkdsk = Join-Path $env:SystemRoot 'System32\chkdsk.exe'

            # LOCALE BLOCKER this replaces: scheduling used to be decided by matching
            # 'will be checked|scheduled|next time the system restarts' in chkdsk's output.
            # On a localized Windows that match failed even when the check HAD been
            # scheduled, so this step threw "nothing has been scheduled", the run was
            # recorded as failed, the ledger recorded scheduledAtNextBoot=false — and the
            # user was then ambushed at the next boot by a multi-hour /r surface scan the
            # tool had insisted it did not schedule. Asserting the OPPOSITE of what
            # happened is the worst possible shape for this bug.
            #
            # The scheduling lives in BootExecute. 'autocheck autochk *' is the default on
            # every machine and proves nothing, so the proof is a NEW entry naming this
            # volume — captured before and compared after.
            $bexBefore = Get-BootExecuteEntries
            $wasScheduled = $false
            if ($bexBefore.readable) { $wasScheduled = (Test-BootExecuteSchedulesVolume $bexBefore.entries $drive) }

            # chkdsk asks a Y/N question when the target is the volume Windows runs from;
            # piping Y schedules the check for the next boot instead of hanging forever.
            $raw = 'Y' | & $chkdsk $drive /f /r 2>&1
            $code = $LASTEXITCODE
            $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')

            $bexAfter = Get-BootExecuteEntries
            $bootExecuteProof = $null
            if ($bexAfter.readable) { $bootExecuteProof = (Test-BootExecuteSchedulesVolume $bexAfter.entries $drive) }
            $dirty = Get-VolumeDirtyState -DriveLetter $drive
            # Rung 3, DOCUMENTED ENGLISH-ONLY: kept because it is precise where it applies,
            # but it is now corroboration, never the decision.
            $textProof = (Test-FFIMatch $txt 'will be checked|scheduled|next time the system restarts')

            $scheduled = $null
            $decidedBy = $null
            if ($bootExecuteProof -eq $true)      { $scheduled = $true;  $decidedBy = 'BootExecute names this volume' }
            elseif ($dirty.readable -and $dirty.dirty -eq $true) { $scheduled = $true; $decidedBy = "volume dirty bit is set ($($dirty.source))" }
            elseif ($textProof)                   { $scheduled = $true;  $decidedBy = 'chkdsk console text (English)' }
            elseif ($bexAfter.readable -and $dirty.readable) { $scheduled = $false; $decidedBy = 'BootExecute and the volume dirty bit were both read and neither shows a scheduled check' }

            $ctx.mutations += [ordered]@{
              type='chkdsk-schedule'; drive=$drive; exitCode=$code
              scheduledAtNextBoot=$scheduled
              decidedBy=$decidedBy
              bootExecuteBefore=@($bexBefore.entries); bootExecuteAfter=@($bexAfter.entries)
              bootExecuteReadable=[bool]$bexAfter.readable
              alreadyScheduledBefore=$wasScheduled
              dirtyBit=$dirty.dirty; dirtyBitSource=$dirty.source; dirtyBitReadable=[bool]$dirty.readable
            }

            if ($scheduled -eq $true) {
              $note = ''
              if ($wasScheduled) { $note = ' (a check was ALREADY scheduled for this volume before this run — BootExecute carried an entry for it.)' }
              return ("chkdsk $drive /f /r is SCHEDULED for the next restart — confirmed structurally: $decidedBy. It runs before Windows starts, cannot be interrupted safely, and /r " +
                      "(surface scan of every sector) can take hours on a large drive. Cancel with: chkntfs /x $drive$note")
            }

            $tail = (@(($txt -split "`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' | ')
            if ($scheduled -eq $false) {
              # Both structural reads succeeded and both say no. Now — and only now — is it
              # honest to assert that nothing was scheduled.
              if ($code -ne 0) {
                throw "chkdsk $drive /f /r exited with code $code, and neither BootExecute nor the volume dirty bit shows a scheduled check, so nothing was scheduled. Output tail: $tail"
              }
              throw ("chkdsk $drive /f /r exited 0, but BootExecute carries no autocheck entry for $drive and the volume dirty bit is not set — so nothing has been scheduled. " +
                     "The system volume cannot be checked in place, so this is NOT a 'finished without a reboot' result. Confirm with 'chkntfs $drive' and re-run. Output tail: $tail")
            }

            # Neither structural read could answer (typically an unelevated or restricted
            # session). Doctrine rule 2: say so. Do NOT assert that nothing was scheduled —
            # a check may well be waiting at the next boot.
            $why = @()
            if (-not $bexAfter.readable) { $why += "BootExecute could not be read ($($bexAfter.error))" }
            if (-not $dirty.readable)    { $why += "the volume dirty bit could not be read ($($dirty.error))" }
            throw ("COULD NOT CONFIRM whether an offline check was scheduled for $drive (chkdsk exit code $code): $($why -join '; '), and chkdsk's own output is localized on this machine. " +
                   "FrameForge will NOT claim either way — a check may or may not be waiting at the next restart. Verify with 'chkntfs $drive', and cancel with 'chkntfs /x $drive' if you did not want it. Output tail: $tail")
          } }
      )
    }
    'store-services-enable' {
      $ctx.serviceDefaults = $StoreServiceDefaults
      return @(
        (Get-ServiceEnableStep -Name 'enable-store-services' -Defaults $StoreServiceDefaults -Label 'Store dependency'),
        @{ name='start-store-services'; always=$true; continueOnFail=$true; bestEffort=$false
          commands=@('Start-Service on each service this run re-enabled from Disabled')
          exec={ param($ctx)
            $names = @()
            if ($ctx.ContainsKey('reEnabledNames')) { $names = @($ctx.reEnabledNames) }
            if ($names.Count -eq 0) { return 'No service was re-enabled by this run — nothing to start.' }
            $started=@(); $failed=@()
            foreach ($n in $names) {
              # AppXSvc and ClipSVC are demand-started; starting them directly can be
              # refused, which is normal — the start type is what actually matters.
              try { Start-Service -Name $n -ErrorAction Stop; $started += $n }
              catch { $failed += "$n (start refused: $($_.Exception.Message) — normal for demand-start services; the restored start type is what matters)" }
            }
            $parts = @()
            if ($started.Count -gt 0) { $parts += "Started: $($started -join ', ')" }
            if ($failed.Count -gt 0)  { $parts += "Not started: $($failed -join '; ')" }
            ($parts -join '. ') + '.'
          } }
      )
    }
    'activation-retry' {
      return @(
        @{ name='force-online-activation'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@("cscript.exe //nologo $env:SystemRoot\System32\slmgr.vbs /ato   (force an online activation attempt against Microsoft's activation servers; the RESULT is then read from SoftwareLicensingProduct.LicenseStatus — the same structured source the health probe and the state capture use — not from slmgr's localized output)")
          exec={ param($ctx)
            $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
            $slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
            if (-not (Test-Path -LiteralPath $slmgr)) { throw 'slmgr.vbs was not found — this system has no scriptable licensing client.' }
            $raw = & $cscript //nologo $slmgr /ato 2>&1
            $code = $LASTEXITCODE
            $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '').Trim()

            # LOCALE: success used to be decided by `$txt -match '(?i)successfully'`, and
            # slmgr's output is fully localized. On a German or Japanese machine a
            # SUCCESSFUL activation therefore fell through to the throw below, the step was
            # recorded as failed and stepsCompleted=false — while Windows was, in fact,
            # activated. Ask the licensing service instead: LicenseStatus is an enum, and
            # this is the exact query Get-RepairCapture and the health probe already use,
            # so fix and verify are now judged by the same evidence (doctrine rule 1).
            # Get-FFLicenseState enumerates EVERY keyed Windows row and says which one the verdict
            # came from; the old inline query took Select-Object -First 1 out of an unordered CIM
            # result set and reported that arbitrary row as the answer.
            $licState = Get-FFLicenseState
            $status = $licState.status; $statusText = $licState.statusText; $product = $licState.product
            $queryError = $null
            if (-not $licState.readable) { $queryError = $licState.error }

            $err = $null
            # Hex result codes are NOT localized, so this extraction still works everywhere. The
            # character class is explicit, so no case folding is involved.
            if ($txt -match '(0x[0-9A-Fa-f]{8})') { $err = $Matches[1] }
            $ctx.mutations += [ordered]@{
              type='activation-attempt'; exitCode=$code; licenseStatusAfter=$status; licenseStatusTextAfter=$statusText
              resultCode=$err; licenseQueryError=$queryError
              channel=$licState.channel; channelSource=$licState.channelSource
              keyedRows=$licState.keyedRows; primaryChosenBy=$licState.primaryChosenBy; licenses=@($licState.rows)
            }

            if ($status -eq 1) { return "Windows is activated: SoftwareLicensingProduct reports LicenseStatus 1 (Licensed) for '$product' after the activation attempt (slmgr exit code $code). Licence channel: $($licState.channel) (read from $($licState.channelSource)); verdict taken from $($licState.primaryChosenBy)." }

            $hint = ''
            if ($err -eq '0xC004F213') { $hint = ' (0xC004F213: no product key or digital licence found for this device — a key must be entered, or this is a hardware-change case.)' }
            elseif ($err -eq '0xC004C003') { $hint = ' (0xC004C003: the activation server refused the key, typically after a hardware change — use Settings > Activation > Troubleshoot with the Microsoft account holding the digital licence.)' }
            elseif ($err) { $hint = " (result code $err.)" }
            # Reached only with -Force: detection refuses these channels outright. Say plainly that
            # the wrong tool was pointed at the problem instead of blaming the licence.
            if ($licState.channel -eq 'kms-client') { $hint = "$hint This is a VOLUME/KMS client licence, so /ato asked a KMS host on your network, not Microsoft — check the _VLMCS._tcp SRV record, TCP 1688, and the KMS host itself." }
            elseif ($licState.channel -eq 'subscription') { $hint = "$hint This licence has a SUBSCRIPTION component, which /ato cannot grant: it comes from the signed-in user's entitlement in Entra ID." }
            if ($null -eq $status) {
              throw ("slmgr /ato ran (exit code $code) but the licensing service could not be queried afterwards$(if ($queryError) { " ($queryError)" }), so FrameForge CANNOT SAY whether Windows is now activated.$hint " +
                     "Check Settings > System > Activation. slmgr output: $txt")
            }
            throw "slmgr /ato did not activate Windows: LicenseStatus is still $status ($statusText) after the attempt (slmgr exit code $code), out of $($licState.keyedRows) keyed licence row(s).$hint Output: $txt"
          } }
      )
    }
    'store-cache-reset' {
      return @(
        @{ name='wsreset'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('WSReset.exe  (started hidden, waited on for up to 120 s)')
          exec={ param($ctx)
            $exe = Join-Path $env:SystemRoot 'System32\WSReset.exe'
            if (-not (Test-Path -LiteralPath $exe)) { throw 'WSReset.exe not found on this system.' }
            $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(120000)) {
              try { $p.Kill() } catch {}
              throw 'WSReset.exe did not finish within 120 seconds and was terminated.'
            }
            $ctx.mutations += [ordered]@{ type='wsreset'; exitCode=$p.ExitCode }
            "Store cache cleared (WSReset exit code $($p.ExitCode)). The Store app may open by itself — that is WSReset's normal behavior."
          } }
      )
    }
    'store-reregister' {
      return @(
        @{ name='reregister-store-package'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Get-AppxPackage -Name Microsoft.WindowsStore | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" }')
          exec={ param($ctx)
            $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $pkg) { throw 'The Microsoft Store package is not installed for this user — use store-reregister-all, or a Windows repair.' }
            Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='appx-reregister'; package="$($pkg.PackageFullName)" }
            "Re-registered $($pkg.Name) $($pkg.Version) from its own manifest."
          } }
      )
    }
    'store-reregister-all' {
      return @(
        @{ name='reregister-all-packages'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Get-AppxPackage -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" }  (each package individually try/caught)')
          exec={ param($ctx)
            $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
            $ok = 0; $failCount = 0; $failSample = @()
            foreach ($p in $pkgs) {
              if (-not $p.InstallLocation) { $failCount++; continue }
              try {
                Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $p.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
                $ok++
              } catch {
                $failCount++
                if ($failSample.Count -lt 3) { $failSample += "$($p.Name)" }
              }
            }
            # DOCTRINE 2. This step claims the 'store-missing' and 'store-package-broken' findings,
            # and it used to report success purely from a bulk count — "re-registered 207 of 214" —
            # while excusing every failure as "protected/staged system packages fail by design".
            # The Microsoft Store could be one of the failures and the repair would still report
            # stepsCompleted = true for the exact package the user came here about. So the thing the
            # repair is FOR is now measured by name, with the same read-only probe shape the health
            # check uses, and it decides the step.
            $storeAfter = $null
            $storeErr = $null
            try { $storeAfter = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 } catch { $storeErr = "$($_.Exception.Message)" }
            $storeOk = ($null -ne $storeAfter)
            $ctx.mutations += [ordered]@{
              type='appx-reregister-all'; succeeded=$ok; failed=$failCount
              storeRegisteredAfter=$storeOk
              storePackage=$(if ($storeOk) { "$($storeAfter.PackageFullName)" } else { $null })
              storeStatus=$(if ($storeOk) { "$($storeAfter.Status)" } else { $null })
              storeQueryError=$storeErr
            }
            $sample = ''
            if ($failSample.Count -gt 0) { $sample = " (sample: $($failSample -join ', '))" }
            $bulk = "Re-registered $ok of $($pkgs.Count) packages; $failCount failed$sample — protected/staged system packages fail by design and are harmless."
            if ($null -ne $storeErr) {
              throw "$bulk But FrameForge COULD NOT CHECK whether the Microsoft Store itself is registered for this user afterwards ($storeErr), and a bulk count is not evidence about the one package this repair is for. Open the Store and see; if it still will not start, a Windows repair install (image.ps1) is the next rung."
            }
            if (-not $storeOk) {
              throw "$bulk The Microsoft Store package is STILL not registered for this user after the pass, so this repair did NOT do the thing it is for — the bulk count above says nothing about it. The package is most likely deprovisioned or missing from the image entirely, which re-registration cannot recover: use a Windows repair install (image.ps1)."
            }
            "$bulk The Microsoft Store itself is registered for this user afterwards ($($storeAfter.PackageFullName), status $($storeAfter.Status)) — checked by name, because a bulk count is not evidence about the one package this repair is for."
          } }
      )
    }
    'search-index-rebuild' {
      # WSearch set to Disabled is a state health.ps1 reports (wsearch-disabled) and
      # Start-Service cannot recover from — the start type has to be restored first,
      # or the final 'start-wsearch' step fails and the rebuild never begins.
      $ctx.serviceDefaults = [ordered]@{ 'WSearch' = 'Automatic' }
      return @(
        (Get-ServiceEnableStep -Name 'enable-wsearch' -Defaults $ctx.serviceDefaults -Label 'Windows Search'),
        @{ name='stop-wsearch'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Stop-Service -Name WSearch -Force')
          exec={ param($ctx)
            $svc = Get-Service -Name WSearch -ErrorAction Stop
            if ("$($svc.Status)" -eq 'Running') {
              Stop-Service -Name WSearch -Force -ErrorAction Stop
              $ctx.mutations += [ordered]@{ type='service-stop'; name='WSearch' }
              $ctx.wsearchStopped = $true
              return 'Stopped the Windows Search service.'
            }
            'WSearch was already stopped.'
          } },
        @{ name='rename-index-database'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@("Rename-Item %ProgramData%\Microsoft\Search\Data\Applications\Windows\Windows.edb -> Windows.edb.bak-$($ctx.ts)  (retried while the indexer releases its lock)")
          exec={ param($ctx)
            $dir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
            $file = $null; $name = $null
            foreach ($cand in @('Windows.edb','Windows.db')) {
              $p = Join-Path $dir $cand
              if (Test-Path -LiteralPath $p) { $file = $p; $name = $cand; break }
            }
            if ($null -eq $file) { return 'No index database file found — the rebuild flag alone will recreate it.' }
            $bak = "$name.bak-$($ctx.ts)"
            $tries = 0
            while ($true) {
              try { Rename-Item -LiteralPath $file -NewName $bak -ErrorAction Stop; break }
              catch {
                $tries++
                if ($tries -ge 5) { throw "Could not rename $name after $tries attempts (the indexer may still be holding it): $($_.Exception.Message)" }
                Start-Sleep -Seconds 2
              }
            }
            $ctx.mutations += [ordered]@{ type='rename'; from=$file; to=(Join-Path $dir $bak) }
            "Renamed $name -> $bak (recorded in the ledger; delete later to reclaim space)."
          } },
        @{ name='set-rebuild-flag'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@("Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0")
          exec={ param($ctx)
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
            $prior = $null
            try { $prior = (Get-ItemProperty -LiteralPath $key -Name SetupCompletedSuccessfully -ErrorAction Stop).SetupCompletedSuccessfully } catch {}
            Set-ItemProperty -LiteralPath $key -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='registry'; key=$key; name='SetupCompletedSuccessfully'; priorValue=$prior; newValue=0 }
            "Set SetupCompletedSuccessfully=0 (was: $prior) — WSearch rebuilds the index on next start."
          } },
        @{ name='start-wsearch'; always=$true; continueOnFail=$false; bestEffort=$false
          commands=@('Start-Service -Name WSearch')
          exec={ param($ctx)
            Start-Service -Name WSearch -ErrorAction Stop
            'Started the Windows Search service — the index rebuild begins now and runs for hours in the background.'
          } }
      )
    }
    'shell-restart' {
      return @(
        @{ name='restart-shell'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@(
            'Stop-Process -Name StartMenuExperienceHost, SearchHost -Force  (if running)',
            'Stop-Process -Name explorer -Force',
            'Start-Process explorer.exe  (only if Windows has not already relaunched it)')
          exec={ param($ctx)
            foreach ($n in @('StartMenuExperienceHost','SearchHost')) {
              try { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue } catch {}
            }
            Stop-Process -Name explorer -Force -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='process-restart'; names=@('StartMenuExperienceHost','SearchHost','explorer') }
            Start-Sleep -Seconds 3
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
              Start-Process explorer.exe
              Start-Sleep -Seconds 2
              return 'Shell hosts stopped; Explorer did not auto-relaunch and was started manually.'
            }
            'Shell hosts restarted; Explorer relaunched automatically.'
          } }
      )
    }
    'spooler-clear-queue' {
      return @(
        @{ name='stop-spooler'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Stop-Service -Name Spooler -Force')
          exec={ param($ctx)
            $svc = Get-Service -Name Spooler -ErrorAction Stop
            if ("$($svc.Status)" -eq 'Running') {
              Stop-Service -Name Spooler -Force -ErrorAction Stop
              $ctx.mutations += [ordered]@{ type='service-stop'; name='Spooler' }
              return 'Stopped the Print Spooler.'
            }
            'The Print Spooler was already stopped.'
          } },
        @{ name='move-spool-files'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@("Move-Item $env:SystemRoot\System32\spool\PRINTERS\* -> %LOCALAPPDATA%\FrameForge\state\backups\spool-$($ctx.ts)\  (moved, not deleted)")
          exec={ param($ctx)
            $dir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Stop)
            if ($files.Count -eq 0) { return 'The spool folder is already empty — nothing to move.' }
            $dest = Join-Path $script:BackupDir "spool-$($ctx.ts)"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            $moved = 0; $failed = 0
            foreach ($f in $files) {
              try { Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop; $moved++ }
              catch { $failed++ }
            }
            $ctx.mutations += [ordered]@{ type='move'; from=$dir; to=$dest; movedFiles=$moved; failedFiles=$failed }
            if ($failed -gt 0) { return "Moved $moved of $($files.Count) spool file(s) to $dest; $failed could not be moved (still locked)." }
            "Moved $moved spool file(s) to $dest (recorded in the ledger)."
          } },
        @{ name='start-spooler'; always=$true; continueOnFail=$false; bestEffort=$false
          commands=@('Start-Service -Name Spooler')
          exec={ param($ctx)
            Start-Service -Name Spooler -ErrorAction Stop
            'Started the Print Spooler.'
          } }
      )
    }
    'audio-restart' {
      return @(
        @{ name='restart-endpoint-builder'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Restart-Service -Name AudioEndpointBuilder -Force  (Audiosrv restarts with it as a dependent)')
          exec={ param($ctx)
            Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='service-restart'; name='AudioEndpointBuilder' }
            'Restarted AudioEndpointBuilder (dependents, including Audiosrv, restart with it).'
          } },
        @{ name='ensure-audiosrv-running'; always=$true; continueOnFail=$false; bestEffort=$false
          commands=@('Start-Service -Name Audiosrv  (if it did not come back on its own)')
          exec={ param($ctx)
            $svc = Get-Service -Name Audiosrv -ErrorAction Stop
            if ("$($svc.Status)" -ne 'Running') {
              Start-Service -Name Audiosrv -ErrorAction Stop
              $ctx.mutations += [ordered]@{ type='service-start'; name='Audiosrv' }
              return 'Started Audiosrv.'
            }
            'Audiosrv came back on its own.'
          } }
      )
    }
    'ntp-resync' {
      return @(
        @{ name='ensure-w32time-running'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Start-Service -Name w32time  (if stopped)')
          exec={ param($ctx)
            $svc = Get-Service -Name w32time -ErrorAction Stop
            if ("$($svc.Status)" -ne 'Running') {
              Start-Service -Name w32time -ErrorAction Stop
              $ctx.mutations += [ordered]@{ type='service-start'; name='w32time' }
              return 'Started the Windows Time service.'
            }
            'The Windows Time service is already running.'
          } },
        @{ name='configure-ntp-peer'; always=$false; continueOnFail=$false; bestEffort=$false
          # ONE command line, decided at execution time rather than at list-build time, on
          # purpose. Emitting a different step list on a domain-joined machine would make
          # `repair.ps1 -Action selftest` report a fabricated whatItRuns divergence on every
          # corporate PC — the same cry-wolf failure the Turkish-casing bug caused. The line
          # therefore documents BOTH branches and the condition that selects them, which is
          # what doctrine rule 5 actually asks for.
          commands=@('w32tm /config /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL /update   — EXCEPT on a domain-joined machine whose W32Time Type is NT5DS (or cannot be read), where this becomes "w32tm /config /syncfromflags:DOMHIER /update": a domain member must keep taking its clock from the domain hierarchy, because repointing it at pool.ntp.org risks Kerberos logon failures once the clock drifts past the five-minute tolerance')
          exec={ param($ctx)
            $w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
            $dom = Get-FFDomainState
            $cfg = Get-W32TimeConfig
            # Detection already refuses on a domain member; reaching here means -Force. Even
            # then the fix must not take the machine off the domain time hierarchy — being
            # asked to run is not permission to break Kerberos. Unknown type on a domain
            # member takes the same safe branch.
            $domHier = ($dom.partOfDomain -eq $true -and ((Test-FFIMatch "$($cfg.type)" '^NT5DS$') -or -not ("$($cfg.type)" -match '\S')))
            if ($domHier) {
              $raw = & $w32tm /config /syncfromflags:DOMHIER /update
              if ($LASTEXITCODE -ne 0) { throw "w32tm /config /syncfromflags:DOMHIER /update failed (exit code $LASTEXITCODE): $((@($raw) -join ' '))" }
              $ctx.mutations += [ordered]@{ type='w32tm-config'; peer=$null; syncFromFlags='DOMHIER'; domainJoined=$true; priorType="$($cfg.type)"; note='Domain member: the peer list was deliberately NOT rewritten. Time sync stays on the domain hierarchy.' }
              return ("This machine is domain-joined (domain '$($dom.domain)', W32Time Type '$($cfg.type)'), so the peer list was NOT repointed at pool.ntp.org — that would take it off the domain hierarchy and risk Kerberos failures. " +
                      'Re-applied domain-hierarchy sync instead (w32tm /config /syncfromflags:DOMHIER /update). If domain time itself is wrong, it has to be fixed at the PDC emulator.')
            }
            $raw = & $w32tm /config '/manualpeerlist:pool.ntp.org,0x8' /syncfromflags:MANUAL /update
            if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed (exit code $LASTEXITCODE): $((@($raw) -join ' '))" }
            $ctx.mutations += [ordered]@{ type='w32tm-config'; peer='pool.ntp.org,0x8'; syncFromFlags='MANUAL'; domainJoined=[bool]($dom.partOfDomain -eq $true); priorType="$($cfg.type)" }
            'Configured pool.ntp.org as the manual NTP peer (prior configuration is in the ledger before-state, read from the W32Time registry parameters).'
          } },
        @{ name='restart-w32time'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Restart-Service -Name w32time')
          exec={ param($ctx)
            Restart-Service -Name w32time -ErrorAction Stop
            'Restarted the Windows Time service.'
          } },
        @{ name='force-resync'; always=$false; continueOnFail=$true; bestEffort=$false
          commands=@('w32tm /resync')
          exec={ param($ctx)
            $w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
            $raw = & $w32tm /resync
            if ($LASTEXITCODE -ne 0) { throw "w32tm /resync failed (exit code $LASTEXITCODE): $((@($raw) -join ' ')) — the source may be unreachable; the service will retry on its schedule." }
            $src = 'pool.ntp.org'
            try { $c = Get-W32TimeConfig; if (Test-FFIMatch "$($c.type)" '^NT5DS$') { $src = 'the domain time hierarchy' } elseif ("$($c.ntpServer)" -match '\S') { $src = "$($c.ntpServer)" } } catch {}
            "Clock resynchronized against $src."
          } }
      )
    }
    'temp-clean' {
      return @(
        @{ name='clean-temp-folders'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@(
            "Get-ChildItem $env:TEMP -Recurse -Force -File | Remove-Item  (each file individually; in-use files skipped)",
            "Get-ChildItem $env:SystemRoot\Temp -Recurse -Force -File | Remove-Item  (elevated only; same per-file handling)")
          exec={ param($ctx)
            $targets = @([ordered]@{ label='user temp'; path=$env:TEMP })
            if ($script:IsAdmin) { $targets += [ordered]@{ label='system temp'; path=(Join-Path $env:SystemRoot 'Temp') } }
            $parts = @()
            foreach ($t in $targets) {
              $deleted = 0; [int64]$bytes = 0; $skipped = 0
              $files = @()
              try { $files = @(Get-ChildItem -LiteralPath $t.path -Recurse -Force -File -ErrorAction SilentlyContinue) } catch {}
              foreach ($f in $files) {
                try {
                  $len = $f.Length
                  Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                  $deleted++; $bytes += $len
                } catch { $skipped++ }
              }
              # Best-effort removal of now-empty subdirectories, deepest first.
              try {
                $dirs = @(Get-ChildItem -LiteralPath $t.path -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
                foreach ($d in $dirs) {
                  try {
                    if (@(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                      Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
                    }
                  } catch {}
                }
              } catch {}
              $mb = [math]::Round($bytes / 1MB, 1)
              $parts += "$($t.label): deleted $deleted file(s) ($mb MB), skipped $skipped in use"
              $ctx.mutations += [ordered]@{ type='temp-clean'; path=$t.path; deletedFiles=$deleted; deletedBytes=$bytes; skippedInUse=$skipped }
            }
            if (-not $script:IsAdmin) { $parts += 'system temp: skipped (needs administrator rights)' }
            $parts -join '. '
          } }
      )
    }
    { $_ -eq 'component-cleanup' -or $_ -eq 'component-cleanup-resetbase' } {
      $resetBase = ($Repair.id -eq 'component-cleanup-resetbase')
      # /English first — same reason as dism-restorehealth above: it fixes the LANGUAGE of the
      # output that lands in the ledger and in the error a user is asked to read, and changes
      # neither the operation nor the exit code that decides the verdict.
      $cmdText = 'Dism.exe /English /Online /Cleanup-Image /StartComponentCleanup'
      if ($resetBase) { $cmdText = "$cmdText /ResetBase" }
      $step = @{ name='component-cleanup'; always=$false; continueOnFail=$false; bestEffort=$false
        commands=@($cmdText)
        exec={ param($ctx)
          $dismArgs = @('/English','/Online','/Cleanup-Image','/StartComponentCleanup')
          if ($ctx.resetBase) { $dismArgs += '/ResetBase' }
          $raw = & (Join-Path $env:SystemRoot 'System32\Dism.exe') @dismArgs
          $code = $LASTEXITCODE
          $ctx.mutations += [ordered]@{ type='component-cleanup'; resetBase=[bool]$ctx.resetBase; exitCode=$code; englishForced=$true }
          if ($code -eq 0 -or $code -eq 3010) {
            $msg = "Component-store cleanup completed (exit code $code)."
            if ($ctx.resetBase) { $msg = "$msg /ResetBase was applied: installed updates are now permanent and can no longer be uninstalled." }
            return $msg
          }
          throw "DISM StartComponentCleanup failed (exit code $code). Log: $(Join-Path $env:SystemRoot 'Logs\DISM\dism.log')"
        } }
      $ctx.resetBase = $resetBase
      return @($step)
    }
    'winget-repair' {
      return @(
        @{ name='bootstrap-winget-module'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@(
            'Read $ExecutionContext.SessionState.LanguageMode, then Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2" -UseBasicParsing -TimeoutSec 10   (read-only preflight: WDAC/AppLocker ConstrainedLanguage or a blocked gallery is named as the cause instead of surfacing a raw PowerShellGet exception)',
            'Install-PackageProvider -Name NuGet -Force  (only if Repair-WinGetPackageManager is not already available)',
            'Install-Module -Name Microsoft.WinGet.Client -Force  (only if not already available; installs machine-wide under %ProgramFiles%\WindowsPowerShell\Modules, and the install is recorded in the run''s mutations because this repair is reversible:false and the module is left behind)')
          exec={ param($ctx)
            if (Get-Command -Name Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
              return 'The Microsoft.WinGet.Client module is already available — bootstrap skipped.'
            }
            # SKU/ENVIRONMENT: on a hardened fleet (WDAC or AppLocker in enforce mode)
            # PowerShell drops to ConstrainedLanguage, where Install-Module and the
            # PackageManagement provider bootstrap simply cannot run; and a corporate proxy
            # often blocks the PowerShell Gallery outright. Both used to abort this repair
            # on a raw PowerShellGet exception ("Cannot invoke method. Method invocation is
            # supported only on core types in this language mode" / "Unable to resolve
            # package source") that tells the user nothing about why.
            # Read it through _lib.ps1's shared $script:FFLanguageMode (captured once at
            # dot-source time) and fall back to $ExecutionContext only if that is absent,
            # so every engine reports the same mode from the same source.
            $mode = ''
            try { $mode = "$script:FFLanguageMode" } catch {}
            if (-not ($mode -match '\S') -or $mode -eq 'Unknown') {
              try { $mode = "$($ExecutionContext.SessionState.LanguageMode)" } catch { $mode = 'unknown' }
            }
            if ($mode -ne 'FullLanguage') {
              throw ("PowerShell is running in $mode language mode (WDAC/AppLocker enforcement) — the Microsoft.WinGet.Client module cannot be installed here, and no amount of retrying will change that. " +
                     'Repair App Installer from the Microsoft Store instead, or ask your administrator to deploy winget through Intune.')
            }
            try { $null = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop }
            catch {
              throw ("The PowerShell Gallery is not reachable from this machine ($($_.Exception.Message)) — a corporate proxy or a blocked endpoint, not a broken winget. " +
                     'Repair App Installer from the Microsoft Store, or ask your administrator to deploy winget through Intune.')
            }
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
            $base = $null
            try { $base = @(Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.ModuleBase)" } | Select-Object -Unique) -join '; ' } catch {}
            $ctx.mutations += [ordered]@{
              type='module-install'; name='Microsoft.WinGet.Client'; scope='AllUsers'; path=$base
              note='winget-repair is reversible:false, so this module is left installed machine-wide. Whether it was present beforehand is in the ledger before-state (wingetClientModule.presentBefore). Remove it by hand with Uninstall-Module -Name Microsoft.WinGet.Client -AllVersions if you do not want it.'
            }
            "Installed the Microsoft.WinGet.Client PowerShell module from the PowerShell Gallery, machine-wide$(if ($base) { " ($base)" }). It is NOT removed by any undo — this repair is not reversible — and the ledger records whether it was already present."
          } },
        @{ name='repair-winget'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('Repair-WinGetPackageManager -AllUsers -Latest')
          exec={ param($ctx)
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            Repair-WinGetPackageManager -AllUsers -Latest -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='winget-repair' }
            'Repair-WinGetPackageManager completed.'
          } }
      )
    }
    default {
      if ($script:OptionalFeatureRepairs -contains "$($Repair.id)") { return @(Get-OptionalFeatureSteps $Repair $ctx) }
      throw "No step builder for repair id '$($Repair.id)'."
    }
  }
}

function Get-OptionalFeatureSteps {
  <#
    One shared builder for the optional-feature repairs. Enable-WindowsOptionalFeature is
    the documented, reversible mechanism (Disable-WindowsOptionalFeature undoes it), which
    is why these are repairs FrameForge is willing to ship: prior state is captured, undo
    restores that captured state, and detection can prove the outcome.

    Payload honesty: several of these features are "Features on Demand" — the files are
    NOT on disk. Enabling them downloads from Windows Update, so an offline machine (or
    one whose WU is pointed at a WSUS server that does not carry FoD) fails with
    0x800F0906/0x800F081F. -SourcePath <mounted media>\sources\sxs makes it an offline
    install with -LimitAccess. The step text says so in both modes.
  #>
  param($Repair, $ctx)
  $name = "$($Repair.optionalFeature)"
  $src = $script:ResolvedFeatureSource
  $ctx.featureName = $name
  $ctx.featureSource = $src
  if ($src) {
    $cmdText = "Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -Source `"$src`" -LimitAccess   (offline install from the media folder given with -SourcePath; -LimitAccess stops it falling back to Windows Update)"
  } else {
    $cmdText = "Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart   (payload comes from Windows Update on demand, so this needs working internet; pass -SourcePath <mounted media>\sources\sxs to install offline instead)"
  }
  @(
    @{ name='enable-optional-feature'; always=$false; continueOnFail=$false; bestEffort=$false
      commands=@($cmdText)
      exec={ param($ctx)
        $fname = $ctx.featureName
        $fsrc  = $ctx.featureSource
        $r = $null
        try {
          if ($fsrc) { $r = Enable-WindowsOptionalFeature -Online -FeatureName $fname -All -NoRestart -Source $fsrc -LimitAccess -ErrorAction Stop }
          else       { $r = Enable-WindowsOptionalFeature -Online -FeatureName $fname -All -NoRestart -ErrorAction Stop }
        } catch {
          $msg = "$($_.Exception.Message)"
          $hint = ''
          if (Test-FFIMatch $msg '0x800F0906|0x800F081F|0x800f0950') {
            $hint = (" This is the Features-on-Demand payload error: the files are not on this machine and could not be fetched. " +
                     "Either this machine has no route to Windows Update (or a WSUS policy is blocking Feature on Demand), or the source is wrong. " +
                     "Mount matching Windows installation media and re-run with -SourcePath <drive>:\sources\sxs.")
          }
          throw "Enable-WindowsOptionalFeature failed for '$fname': $msg.$hint Log: $env:SystemRoot\Logs\DISM\dism.log"
        }
        $restart = $false
        try { $restart = [bool]$r.RestartNeeded } catch {}
        $ctx.mutations += [ordered]@{
          type='optional-feature-enable'; featureName=$fname; usedSource=("$fsrc" -ne ''); source=$fsrc; restartNeeded=$restart
          note='Undo restores the exact State captured in the ledger before-state (Disable-WindowsOptionalFeature, with -Remove when the payload had been removed).'
        }
        $tail = ''
        if ($restart) { $tail = ' A restart is required to finish enabling it.' }
        "Enabled the '$fname' optional feature.$tail The prior state is recorded in the ledger, and undo puts it back."
      } }
  )
}

# ---------------- actions ----------------

function ConvertTo-StepDocs {
  param($Steps)
  $docs = @()
  foreach ($s in @($Steps)) { $docs += [ordered]@{ name=$s.name; commands=@($s.commands) } }
  $docs
}

function Invoke-Preflight {
  param($Repair)
  $det = Get-RepairDetection $Repair
  $capture = $null
  try { $capture = Get-RepairCapture $Repair } catch { $capture = [ordered]@{ captureError = "$($_.Exception.Message)" } }
  $ctx = New-RepairContext $Repair
  $steps = @(Get-RepairSteps $Repair $ctx)
  $rpEnforced = Test-RestorePointEnforced $Repair
  $refuses = Test-DetectionRefuses $det
  $appl = Get-RepairApplicability $Repair
  # Management state is surfaced for EVERY repair, before anything runs. The user should
  # see "this machine is WSUS-pinned / MDM-enrolled / domain-joined" before choosing a
  # repair, not discover it in the result text afterwards — several steps behave
  # differently on a managed machine and two of them now refuse outright.
  $mgmt = $null
  try { $mgmt = Get-WuManagementState } catch { $mgmt = [ordered]@{ error = "$($_.Exception.Message)" } }
  $mgmtNote = 'This machine shows no WSUS pinning, MDM enrolment or domain membership: the update-pipeline repairs behave as documented.'
  if ($null -ne $mgmt) {
    if (-not $mgmt.policyReadable) {
      $mgmtNote = "The Windows Update policy key could not be read ($($mgmt.error)), so FrameForge cannot tell whether this machine is managed. Steps that would be unsafe on a managed machine (clearing the WinHTTP proxy, clearing the WSUS client identity) take the cautious branch and skip."
    } elseif ($mgmt.managed -eq $true) {
      $bits = @()
      if ($mgmt.wsusManaged) { $bits += "pinned by Group Policy to the WSUS server $($mgmt.wsusServer)" }
      if ($mgmt.mdmEnrolled) { $bits += "MDM-enrolled ($($mgmt.mdmProviders -join ', '))" }
      if ($mgmt.partOfDomain -eq $true) { $bits += "joined to domain $($mgmt.domain)" }
      $mgmtNote = ("THIS MACHINE IS MANAGED: $($bits -join '; '). wu-reset will NOT clear the WinHTTP proxy (on a managed network that is the machine's only route to updates) " +
                   'and will NOT delete the WSUS client identity (that is an administrator action, and the client would re-register with the WSUS server, not with Microsoft). ' +
                   'ntp-resync refuses on a domain member rather than taking it off the domain time hierarchy. Nothing here touches Group Policy.')
    }
  }
  [ordered]@{
    ok = $true
    id = "$($Repair.id)"
    action = 'preflight'
    name = "$($Repair.name)"
    tier = "$($Repair.tier)"
    isAdmin = $IsAdmin
    applicability = $appl
    managementState = $mgmt
    managementNote = $mgmtNote
    requiresAdmin = [bool]$Repair.requiresAdmin
    wouldNeedElevation = [bool]($Repair.requiresAdmin -and -not $IsAdmin)
    requiresReboot = [bool]$Repair.requiresReboot
    reversible = [bool]$Repair.reversible
    detection = $det
    wouldRefuse = $refuses
    refusalKind = $(if ($refuses) { Get-RefusalKind $det } else { $null })
    restorePoint = [ordered]@{
      policy = $(if ("$($Repair.restorePoint)") { "$($Repair.restorePoint)" } else { $(if ("$($Repair.tier)" -eq 'aggressive') { 'enforced' } else { 'none' }) })
      wouldCreate = $rpEnforced
      optedOut = [bool]$NoRestorePoint
      detail = $(if ($rpEnforced) { 'A System Restore checkpoint is created as the FIRST step of this repair. If it cannot be created (System Protection off), the repair aborts instead of running unprotected. -NoRestorePoint is the explicit opt-out.' }
                 elseif ($NoRestorePoint) { 'This repair normally enforces a System Restore checkpoint, but -NoRestorePoint was passed: it would run WITHOUT one.' }
                 else { 'No checkpoint is created for this tier: the repair is either reversible from the ledger or changes nothing System Restore captures.' })
    }
    whatWouldRun = @(ConvertTo-StepDocs $steps)
    currentState = $capture
    risks = "$($Repair.risks)"
    verifyAfter = "$($Repair.verifyAfter)"
    note = 'Preflight is read-only: nothing was changed, no restore point was created, and no ledger entry was written.'
  }
}

function Invoke-RepairRun {
  param($Repair)
  # 0a) PLATFORM GATE. health.ps1 attaches supportedOs / unvalidatedPlatform to every document and
  #     documents that "the mutating engines (repair.ps1 -Action run, image.ps1 preflight/launch/
  #     acquire-url) use [it] to refuse with errorCode 'unsupported-os'". That refusal did not exist
  #     here, so the promise was only ever half kept: FrameForge is validated on Windows 11 client
  #     builds, and a repair that reconfigures services, renames servicing folders or schedules an
  #     offline chkdsk on a Server SKU, on Windows 10, or on a machine whose build could not even be
  #     READ, is acting on ground nobody tested. Read-only actions (list, preflight, selftest,
  #     ledger, and -DryRun) stay available so the user is not left with nothing — they mutate
  #     nothing. -Force overrides deliberately, as everywhere else in this engine.
  $osInfo = Get-FFOsInfo
  if (-not $osInfo.supported -and -not $Force -and -not $DryRun) {
    return [ordered]@{
      ok = $false
      id = "$($Repair.id)"
      action = 'run'
      ran = $false
      refused = $true
      success = $false
      errorCode = 'unsupported-os'
      # Stays inside the EXISTING refusal vocabulary so a renderer switching on `reason` /
      # `refusalKind` keeps working; errorCode is the additive field new code reads.
      reason = 'indeterminate-not-applicable'
      refusalKind = 'indeterminate-not-applicable'
      message = ("'$($Repair.name)' was NOT run: $($osInfo.unsupportedReason) FrameForge refuses to mutate a platform it has not been validated on rather than pretending the result would mean the same thing here. " +
                 'Read-only actions (list, preflight, ledger, selftest) and -DryRun still work. -Force overrides this deliberately.')
      platform = [ordered]@{
        supportedOs = [bool]$osInfo.supported
        unvalidatedPlatform = (-not $osInfo.supported)
        unsupportedReason = $osInfo.unsupportedReason
        build = $osInfo.buildString
        installationType = $osInfo.installationType
        generation = $osInfo.generation
        caption = $osInfo.caption
      }
    }
  }
  # 0b) BUILD GATE. The catalog can now say WHERE a repair applies (minBuild / maxBuild /
  #    generation), so a rung that does not exist on this build refuses before anything
  #    else runs. applicable=$null ("the build could not be read") refuses too: running a
  #    build-gated repair on an unknown build is fixing blind, which is the same mistake as
  #    running on a failed probe. -Force overrides deliberately, as everywhere else.
  $appl = Get-RepairApplicability $Repair
  if ($appl.applicable -ne $true -and -not $Force -and -not $DryRun) {
    return [ordered]@{
      ok = $false
      id = "$($Repair.id)"
      action = 'run'
      ran = $false
      refused = $true
      success = $false
      errorCode = 'not-applicable-on-this-build'
      # `reason` / `refusalKind` stay inside the EXISTING refusal vocabulary so a renderer
      # that switches on them keeps working; `errorCode` is the additive field new code
      # reads to tell a build mismatch from the other not-applicable cases.
      reason = 'indeterminate-not-applicable'
      refusalKind = 'indeterminate-not-applicable'
      message = "'$($Repair.name)' was NOT run: $($appl.notApplicableReason) -Force overrides deliberately."
      applicability = $appl
    }
  }

  # 1) DETECT (read-only) — this happens before ANY admin check or mutation, so an
  #    unelevated run against a healthy subsystem refuses cleanly instead of asking
  #    for elevation it will never need.
  $preDet = Get-RepairDetection $Repair
  # A FAILED probe is not a licence to fix blindly: refuse on healthy AND on the
  # indeterminate reasons that mean "detection did not actually happen".
  $wouldRefuse = Test-DetectionRefuses $preDet
  $refusalKind = Get-RefusalKind $preDet

  if ($DryRun) {
    $capture = $null
    try { $capture = Get-RepairCapture $Repair } catch { $capture = [ordered]@{ captureError = "$($_.Exception.Message)" } }
    $ctx = New-RepairContext $Repair
    $steps = @(Get-RepairSteps $Repair $ctx)
    $doc = [ordered]@{
      ok = $true
      id = "$($Repair.id)"
      action = 'run'
      dryRun = $true
      mutated = $false
      isAdmin = $IsAdmin
      applicability = $appl
      wouldRefuse = $wouldRefuse
      refusalKind = $(if ($wouldRefuse) { $refusalKind } else { $null })
      detection = $preDet
      wouldCapture = $capture
      steps = @(ConvertTo-StepDocs $steps)
      tier = "$($Repair.tier)"
      reversible = [bool]$Repair.reversible
      requiresAdmin = [bool]$Repair.requiresAdmin
      requiresReboot = [bool]$Repair.requiresReboot
      wouldCreateRestorePoint = (Test-RestorePointEnforced $Repair)
      note = 'Dry run: detection and state capture are read-only; none of the listed commands were executed, no restore point was created, and no ledger entry was written.'
    }
    $doc.platform = [ordered]@{
      supportedOs = [bool]$osInfo.supported
      unvalidatedPlatform = (-not $osInfo.supported)
      unsupportedReason = $osInfo.unsupportedReason
      build = $osInfo.buildString
      installationType = $osInfo.installationType
      generation = $osInfo.generation
    }
    if (-not $osInfo.supported) {
      $doc.wouldRefuseUnsupportedOs = $true
      $doc.unsupportedOsNote = "Without -DryRun this run would REFUSE with errorCode 'unsupported-os': $($osInfo.unsupportedReason) -Force would override."
    }
    if ($appl.applicable -ne $true) {
      $doc.wouldRefuseNotApplicable = $true
      $doc.notApplicableNote = "Without -DryRun this run would REFUSE with errorCode 'not-applicable-on-this-build': $($appl.notApplicableReason) -Force would override."
    }
    if ($wouldRefuse) {
      if ($refusalKind -eq 'nothing-broken') {
        $doc.refusalNote = "Without -DryRun this run would REFUSE: detection reports healthy, and 'nothing is broken here' is a first-class result. -Force would override."
      } else {
        $doc.refusalNote = "Without -DryRun this run would REFUSE with '$refusalKind': detection did not actually complete, so running would be fixing blind. Fix the probe first; -Force would override deliberately."
      }
    }
    return $doc
  }

  # 2) REFUSE-IF-HEALTHY / REFUSE-IF-UNDETECTED (unless -Force)
  if ($wouldRefuse -and -not $Force) {
    $msg = "Detection reports this subsystem is healthy, so '$($Repair.name)' was NOT run. Nothing is broken here — that is a result, not an error. Use -Force to run anyway."
    if ($refusalKind -eq 'indeterminate-probe-failure') {
      $msg = "The health probe for '$($Repair.healthCheck)' could not be run or parsed, so '$($Repair.name)' was NOT run. A failed probe is not permission to fix blind — repair the probe (engine/health.ps1) and try again. -Force overrides deliberately."
    } elseif ($refusalKind -eq 'indeterminate-not-applicable') {
      $msg = "The subsystem '$($Repair.name)' targets does not exist on this machine, so it was NOT run. $($preDet.detail) -Force overrides deliberately."
    } elseif ($refusalKind -eq 'indeterminate-unparseable') {
      $msg = "Detection ran but its answer could not be read, so '$($Repair.name)' was NOT run. $($preDet.detail) -Force overrides deliberately."
    }
    return [ordered]@{
      ok = $true
      id = "$($Repair.id)"
      action = 'run'
      ran = $false
      refused = $true
      reason = $refusalKind
      message = $msg
      detection = $preDet
    }
  }

  # 3) elevation gate
  if ($Repair.requiresAdmin -and -not $IsAdmin) {
    return [ordered]@{
      ok = $false
      id = "$($Repair.id)"
      action = 'run'
      success = $false
      needsElevation = $true
      message = 'This repair requires administrator rights.'
      detection = $preDet
    }
  }

  # 4) CAPTURE state (read-only), build steps, open the ledger entry BEFORE mutating.
  $capture = $null
  try { $capture = Get-RepairCapture $Repair } catch { $capture = [ordered]@{ captureError = "$($_.Exception.Message)" } }
  $ctx = New-RepairContext $Repair
  $steps = @(Get-RepairSteps $Repair $ctx)
  $entry = [ordered]@{
    runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    id = "$($Repair.id)"
    name = "$($Repair.name)"
    ranAt = (Get-Date).ToString('s')
    tier = "$($Repair.tier)"
    reversible = [bool]$Repair.reversible
    forced = [bool]($Force -and $wouldRefuse)
    forcedPast = $(if ($Force -and $wouldRefuse) { $refusalKind } else { $null })
    restorePointEnforced = (Test-RestorePointEnforced $Repair)
    restorePointOptOut = [bool]$NoRestorePoint
    before = $capture
    detection = [ordered]@{ pre = $preDet; post = $null }
    steps = @()
    mutations = @()
    result = $null
    undone = $false
    undoneAt = $null
  }
  foreach ($s in $steps) {
    $entry.steps += [ordered]@{ name=$s.name; commands=@($s.commands); status='pending'; detail=$null; at=$null }
  }
  Sync-LedgerEntry $entry

  # 5) EXECUTE — each step individually try/caught; the ledger is re-saved after every
  #    step so a mid-repair failure leaves an exact record of what already changed.
  $aborted = $false
  $failedStep = $null
  for ($i = 0; $i -lt $steps.Count; $i++) {
    $s = $steps[$i]
    $rec = $entry.steps[$i]
    if ($aborted -and -not $s.always) {
      $rec.status = 'skipped'
      $rec.detail = 'Skipped because an earlier step failed.'
      Sync-LedgerEntry $entry
      continue
    }
    $rec.at = (Get-Date).ToString('s')
    $rec.status = 'running'
    Sync-LedgerEntry $entry
    try {
      $d = & $s.exec $ctx
      $rec.status = 'ok'
      $rec.detail = "$d"
    } catch {
      $rec.status = 'failed'
      $rec.detail = "$($_.Exception.Message)"
      if ($null -eq $failedStep) { $failedStep = $s.name }
      if (-not $s.continueOnFail) { $aborted = $true }
    }
    $entry.mutations = @($ctx.mutations)
    Sync-LedgerEntry $entry
  }

  # 6) VERIFY — the same probe that detected the problem, re-run fresh.
  $settleIds = @('wu-reset','wu-reset-aggressive','audio-restart','shell-restart','search-index-rebuild','spooler-clear-queue','ntp-resync')
  if ($settleIds -contains $Repair.id) { Start-Sleep -Seconds 3 }
  $postDet = Get-RepairDetection $Repair -Fresh
  $entry.detection.post = $postDet

  $hardFailures = @($entry.steps | Where-Object { $_.status -eq 'failed' })
  # bestEffort steps (e.g. the update-scan trigger) may fail without unfixing the repair.
  $countedFailures = 0
  for ($i = 0; $i -lt $steps.Count; $i++) {
    if ($entry.steps[$i].status -eq 'failed' -and -not $steps[$i].bestEffort) { $countedFailures++ }
  }
  # NAMING, because the old name was a small lie. This flag has only ever meant "every
  # step that counts ran without erroring" — NOT "the finding the user came here with is
  # gone". spooler-clear-queue, for instance, claims the printer-error-state finding but
  # cannot do anything about a printer that is simply Offline: all its steps succeed and
  # the printer is still offline. So the flag is now called stepsCompleted, `addressed`
  # carries the honest meaning (steps ran AND the same probe now says healthy), and
  # `fixed` survives ONLY as a deprecated alias of stepsCompleted so the current renderer
  # keeps working. New consumers must read addressed/verified, never fixed.
  $stepsCompleted = ($countedFailures -eq 0)
  # SFC gate. 'unfixable' means SFC said out loud that it could not repair everything.
  # 'indeterminate' means NOBODY COULD READ what SFC found — sfc.exe exits 0 either way,
  # so before this both localized cases sailed through as stepsCompleted/fixed = true. A
  # result nobody read is not a completed repair, so indeterminate is treated exactly like
  # unfixable here. This is the whole point of doctrine rule 2.
  $sfcBlock = $null
  if ($ctx.ContainsKey('sfcOutcome')) {
    if ($ctx.sfcOutcome -eq 'unfixable') { $stepsCompleted = $false; $sfcBlock = 'unfixable' }
    elseif ($ctx.sfcOutcome -eq 'indeterminate') { $stepsCompleted = $false; $sfcBlock = 'indeterminate' }
  }
  $verified = ($postDet.state -eq 'healthy')
  $addressed = ($stepsCompleted -and $verified)

  $detail = ''
  if ($aborted) {
    $detail = "Step '$failedStep' failed; later steps were skipped (recovery steps marked 'always' still ran). The ledger entry records exactly what changed before the failure."
  } elseif ($sfcBlock -eq 'unfixable') {
    $detail = ('Every step ran, but SFC reported corrupt files it could NOT repair, so this is NOT a completed repair. ' +
               'Re-run dism-restorehealth with -SourcePath pointing at a mounted same-build ISO, then run SFC again. The CBS.log evidence is in the run mutations.')
  } elseif ($sfcBlock -eq 'indeterminate') {
    $detail = ('Every step ran, but FrameForge COULD NOT DETERMINE what SFC found — sfc.exe exits 0 whether or not it repaired anything, its console text is localized on this machine, and the CBS.log [SR] tail could not be read. ' +
               "This is reported as NOT completed rather than claimed as success on a result nobody read. Read $(Join-Path $env:SystemRoot 'Logs\CBS\CBS.log') (search for '[SR]'), or re-run dism-restorehealth with -SourcePath.")
  } elseif (-not $stepsCompleted) {
    $detail = "One or more steps failed — see the step list. The ledger records exactly what changed."
  } elseif ($verified) {
    $detail = 'All steps completed, and the same probe that detected the problem now reports healthy.'
  } elseif ($postDet.state -eq 'problem') {
    $detail = "All steps completed, but the verification probe still reports a problem: $($postDet.detail) $($Repair.verifyAfter)"
  } else {
    $detail = "All steps completed; the verification probe was indeterminate: $($postDet.detail)"
  }
  $entry.result = [ordered]@{
    stepsCompleted = $stepsCompleted
    verified       = $verified
    addressed      = $addressed
    fixed          = $stepsCompleted
    sfcOutcome     = $(if ($ctx.ContainsKey('sfcOutcome')) { "$($ctx.sfcOutcome)" } else { $null })
    fieldNote      = "stepsCompleted = every step that counts ran without error. verified = the same read-only probe that detected the problem now reports healthy. addressed = both, and it is the only one of the three that means 'the problem is gone'. 'fixed' is a DEPRECATED alias of stepsCompleted, kept so existing UI keeps rendering; it does not mean the finding was resolved and new code must not read it."
    detail         = $detail
  }
  Sync-LedgerEntry $entry

  [ordered]@{
    ok = $true
    id = "$($Repair.id)"
    action = 'run'
    dryRun = $false
    ranAt = "$($entry.ranAt)"
    forced = [bool]$entry.forced
    detection = $entry.detection
    steps = @($entry.steps)
    mutations = @($entry.mutations)
    restorePoint = @($entry.mutations | Where-Object { "$($_.type)" -eq 'restore-point' } | Select-Object -First 1)
    result = $entry.result
    requiresReboot = [bool]$Repair.requiresReboot
    reversible = [bool]$Repair.reversible
    ledgerRunId = "$($entry.runId)"
  }
}

function Invoke-RepairUndo {
  param($Repair)
  $entries = @(Load-RepairLedger | Where-Object { "$($_.id)" -eq "$($Repair.id)" -and -not $_.undone })
  if ($entries.Count -eq 0) {
    return [ordered]@{ ok=$true; id="$($Repair.id)"; action='undo'; noop=$true; message="No completed run of '$($Repair.name)' is on record in the ledger — nothing to undo." }
  }
  $entry = $entries | Sort-Object { "$($_.ranAt)" } | Select-Object -Last 1
  if (-not $Repair.reversible) {
    return [ordered]@{
      ok = $false
      id = "$($Repair.id)"
      action = 'undo'
      success = $false
      reversible = $false
      message = "'$($Repair.name)' is declared not reversible, so there is no automatic undo. The ledger entry records exactly what was renamed or moved (nothing was deleted where a rename/move was possible), so manual recovery remains possible."
      ledgerRunId = "$($entry.runId)"
      recordedMutations = @($entry.mutations)
    }
  }
  if ($Repair.requiresAdmin -and -not $IsAdmin -and -not $DryRun) {
    return [ordered]@{ ok=$false; id="$($Repair.id)"; action='undo'; success=$false; needsElevation=$true; message='Undoing this repair requires administrator rights.' }
  }

  $plan = @()
  $actions = @()
  switch ($Repair.id) {
    'ntp-resync' {
      $peer = $null; $type = $null; $captureReadable = $false
      try { $peer = "$($entry.before.ntp.ntpServer)" } catch {}
      try { $type = "$($entry.before.ntp.type)" } catch {}
      try { $captureReadable = [bool]$entry.before.ntp.readable } catch {}
      # Ledger entries written before the registry-based capture landed have no `readable`
      # field at all. Treat a present peer/type as proof the capture worked, so old entries
      # still undo correctly instead of being refused.
      if (-not $captureReadable -and (("$peer" -match '\S') -or ("$type" -match '\S'))) { $captureReadable = $true }
      $wasStopped = $false
      try {
        $svcRow = @($entry.before.services) | Where-Object { "$($_.name)" -eq 'w32time' } | Select-Object -First 1
        if ($svcRow -and "$($svcRow.status)" -ne 'Running') { $wasStopped = $true }
      } catch {}

      # DOCTRINE RULE 3. The old code fell through to an ASSUMED default
      # (time.windows.com,0x9 + MANUAL) whenever the capture was empty — which, because the
      # capture used to match the English labels 'NtpServer:' / 'Type:', was EVERY
      # non-English machine. On a domain member that "undo" converted domain-hierarchy time
      # sync into a manual internet peer and then reported "Restored the captured NTP
      # configuration." Undo restores captured state or it refuses; it never guesses.
      if (-not $captureReadable -or (-not ("$peer" -match '\S') -and -not ("$type" -match '\S'))) {
        return [ordered]@{
          ok=$false; id="$($Repair.id)"; action='undo'; success=$false
          message=("The prior Windows Time configuration was never captured (the pre-repair read of HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters returned nothing), so there is no captured state to restore. " +
                   "FrameForge will NOT guess a default — applying time.windows.com here would silently convert a domain member's hierarchy sync into a manual internet peer and break Kerberos. " +
                   'Restore it by hand: on a domain member run "w32tm /config /syncfromflags:DOMHIER /update"; on a standalone PC run "w32tm /config /manualpeerlist:\"time.windows.com,0x9\" /syncfromflags:MANUAL /update", then "Restart-Service w32time".')
          ledgerRunId="$($entry.runId)"
          recordedBefore=$entry.before
        }
      }

      if (Test-FFIMatch $type 'NT5DS') { $plan += 'w32tm /config /syncfromflags:DOMHIER /update  (restore the captured domain-hierarchy sync)' }
      else { $plan += "w32tm /config /manualpeerlist:`"$peer`" /syncfromflags:MANUAL /update  (restore the captured peer list)" }
      $plan += 'Restart-Service -Name w32time'
      $plan += 'w32tm /resync  (best effort)'
      if ($wasStopped) { $plan += 'Stop-Service -Name w32time  (the service was stopped before the repair ran)' }
      if (-not $DryRun) {
        $w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
        if (Test-FFIMatch $type 'NT5DS') { $raw = & $w32tm /config /syncfromflags:DOMHIER /update }
        else { $raw = & $w32tm /config "/manualpeerlist:$peer" /syncfromflags:MANUAL /update }
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed during undo (exit code $LASTEXITCODE): $((@($raw) -join ' '))" }
        if (Test-FFIMatch $type 'NT5DS') { $actions += "Restored the captured NTP configuration (Type NT5DS — domain-hierarchy sync)." }
        else { $actions += "Restored the captured NTP configuration (peer list '$peer', Type '$type')." }
        Restart-Service -Name w32time -ErrorAction Stop
        $actions += 'Restarted the Windows Time service.'
        try { & $w32tm /resync | Out-Null; if ($LASTEXITCODE -eq 0) { $actions += 'Resynced the clock.' } } catch {}
        if ($wasStopped) { Stop-Service -Name w32time -Force -ErrorAction Stop; $actions += 'Stopped w32time (matching its pre-repair state).' }
      }
    }
    'audio-restart' {
      $rows = @()
      try { $rows = @($entry.before.services) } catch {}
      foreach ($r in $rows) {
        $plan += "Ensure $($r.name) matches its captured state ($($r.status), start type $($r.startType))"
        if (-not $DryRun) {
          try {
            $now = Get-Service -Name $r.name -ErrorAction Stop
            if ("$($r.status)" -eq 'Running' -and "$($now.Status)" -ne 'Running') { Start-Service -Name $r.name -ErrorAction Stop; $actions += "Started $($r.name)." }
            elseif ("$($r.status)" -eq 'Stopped' -and "$($now.Status)" -eq 'Running') { Stop-Service -Name $r.name -Force -ErrorAction Stop; $actions += "Stopped $($r.name)." }
            else { $actions += "$($r.name) already matches its captured state ($($r.status))." }
          } catch { $actions += "$($r.name): could not restore — $($_.Exception.Message)" }
        }
      }
    }
    'shell-restart' {
      $plan += '(nothing to execute: the restarted shell hosts are stateless and relaunched automatically)'
      if (-not $DryRun) { $actions += 'Nothing to restore: shell hosts are stateless; the restart left no state to undo.' }
    }
    'dns-change-resolver' {
      $rows = @()
      try { $rows = @($entry.before.adapters) } catch {}
      if ($rows.Count -eq 0) { $plan += '(no adapter DNS configuration was captured — nothing can be restored)' }
      foreach ($r in $rows) {
        $prior = @(); try { $prior = @($r.ipv4Servers) + @($r.ipv6Servers) | Where-Object { "$_" -match '\S' } } catch {}
        $wasDhcp = $false; try { $wasDhcp = [bool]$r.dhcpAssigned } catch {}
        if ($wasDhcp -or $prior.Count -eq 0) {
          $plan += "Set-DnsClientServerAddress -InterfaceIndex $($r.ifIndex) -ResetServerAddresses   (adapter '$($r.alias)' had DHCP-assigned resolvers)"
        } else {
          $plan += "Set-DnsClientServerAddress -InterfaceIndex $($r.ifIndex) -ServerAddresses $($prior -join ', ')   (adapter '$($r.alias)')"
        }
        if (-not $DryRun) {
          try {
            if ($wasDhcp -or $prior.Count -eq 0) {
              Set-DnsClientServerAddress -InterfaceIndex ([int]$r.ifIndex) -ResetServerAddresses -ErrorAction Stop
              $actions += "$($r.alias): restored automatic (DHCP-assigned) resolvers."
            } else {
              Set-DnsClientServerAddress -InterfaceIndex ([int]$r.ifIndex) -ServerAddresses $prior -ErrorAction Stop
              $actions += "$($r.alias): restored the captured resolvers ($($prior -join ', '))."
            }
          } catch { $actions += "$($r.alias): could not restore — $($_.Exception.Message)" }
        }
      }
      $plan += 'ipconfig /flushdns'
      if (-not $DryRun) {
        try { $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns; $actions += 'Flushed the resolver cache.' } catch {}
      }
    }
    default {
      if ($script:OptionalFeatureRepairs -contains "$($Repair.id)") {
        # True state-capture undo: put the feature back into the EXACT State the ledger
        # recorded, not into an assumed default. DisabledWithPayloadRemoved is restored
        # with -Remove, because 'Disabled with the payload still on disk' is a different
        # machine state from the one this repair started with.
        $fname = $null; $priorState = $null; $readable = $false
        try { $fname = "$($entry.before.featureName)" } catch {}
        try { $priorState = "$($entry.before.state)" } catch {}
        try { $readable = [bool]$entry.before.readable } catch {}
        if (-not $fname) { $fname = "$($Repair.optionalFeature)" }
        if (-not $readable -or -not $priorState) {
          return [ordered]@{
            ok=$false; id="$($Repair.id)"; action='undo'; success=$false
            message="The prior state of '$fname' was never captured (the pre-repair read failed), so there is no captured state to restore. FrameForge will not guess a default — disable it by hand with Disable-WindowsOptionalFeature -Online -FeatureName $fname -NoRestart if that is what you want."
            ledgerRunId="$($entry.runId)"
            recordedBefore=$entry.before
          }
        }
        if ($priorState -eq 'Enabled' -or $priorState -eq 'EnablePending') {
          $plan += "(nothing to execute: '$fname' was already $priorState before this repair ran, so its captured state is the state it is in now)"
          if (-not $DryRun) { $actions += "'$fname' was already $priorState before the repair — nothing to restore." }
        } elseif ($priorState -eq 'DisabledWithPayloadRemoved') {
          $plan += "Disable-WindowsOptionalFeature -Online -FeatureName $fname -Remove -NoRestart   (captured prior state: DisabledWithPayloadRemoved — -Remove reproduces it exactly, payload off disk)"
          if (-not $DryRun) {
            try {
              $r = Disable-WindowsOptionalFeature -Online -FeatureName $fname -Remove -NoRestart -ErrorAction Stop
              $actions += "Disabled '$fname' and removed its payload, restoring the captured state ($priorState)$(if ($r.RestartNeeded) { ' — a restart is required to finish' })."
            } catch { $actions += "'$fname': could not restore — $($_.Exception.Message)" }
          }
        } else {
          $plan += "Disable-WindowsOptionalFeature -Online -FeatureName $fname -NoRestart   (captured prior state: $priorState)"
          if (-not $DryRun) {
            try {
              $r = Disable-WindowsOptionalFeature -Online -FeatureName $fname -NoRestart -ErrorAction Stop
              $actions += "Disabled '$fname', restoring the captured state ($priorState)$(if ($r.RestartNeeded) { ' — a restart is required to finish' })."
            } catch { $actions += "'$fname': could not restore — $($_.Exception.Message)" }
          }
        }
        break
      }
      return [ordered]@{ ok=$false; id="$($Repair.id)"; action='undo'; success=$false; message="No undo implementation exists for '$($Repair.id)' despite reversible=true — this is a catalog/engine mismatch."; ledgerRunId="$($entry.runId)" }
    }
  }

  if ($DryRun) {
    return [ordered]@{
      ok = $true
      id = "$($Repair.id)"
      action = 'undo'
      dryRun = $true
      mutated = $false
      ledgerRunId = "$($entry.runId)"
      wouldRun = @($plan)
      note = 'Dry run: nothing was executed and the ledger entry was not marked undone.'
    }
  }
  $entry.undone = $true
  $entry.undoneAt = (Get-Date).ToString('s')
  Sync-LedgerEntry $entry
  [ordered]@{
    ok = $true
    id = "$($Repair.id)"
    action = 'undo'
    success = $true
    restored = @($actions)
    ledgerRunId = "$($entry.runId)"
  }
}

function Invoke-List {
  $catalog = @(Load-Catalog)
  $rows = @()
  $os = Get-RepairOsInfo
  foreach ($r in $catalog) {
    # Build gate FIRST: probing a category to decide whether to offer a rung that does not
    # exist on this build is wasted work, and the detection state would be misleading next
    # to notApplicableReason. Entries are still RETURNED when they do not apply — the user
    # should be able to see the rung exists and why it is unavailable here.
    $appl = Get-RepairApplicability $r
    $det = $null
    if ($appl.applicable -eq $false) {
      $det = [ordered]@{ state='indeterminate'; reason='not-applicable'; detail="$($appl.notApplicableReason)" }
    } else {
      try { $det = Get-RepairDetection $r -ShallowOnly }
      catch { $det = [ordered]@{ state='indeterminate'; detail="Detection failed: $($_.Exception.Message)" } }
    }
    $rows += [ordered]@{
      id = "$($r.id)"
      name = "$($r.name)"
      category = "$($r.category)"
      tier = "$($r.tier)"
      applicable = $appl.applicable
      notApplicableReason = $appl.notApplicableReason
      minBuild = $appl.minBuild
      maxBuild = $appl.maxBuild
      generation = $appl.generation
      reversible = [bool]$r.reversible
      requiresAdmin = [bool]$r.requiresAdmin
      requiresReboot = [bool]$r.requiresReboot
      summary = "$($r.summary)"
      restorePoint = (Test-RestorePointEnforced $r)
      detection = [ordered]@{ state = "$($det.state)"; reason = "$($det.reason)"; detail = "$($det.detail)" }
    }
  }
  [ordered]@{
    ok = $true
    isAdmin = $IsAdmin
    generatedAt = (Get-Date).ToString('s')
    os = [ordered]@{ build = $os.currentBuild; displayVersion = $os.displayVersion; generation = $os.generation; readable = [bool]$os.readable; error = $os.error }
    count = $rows.Count
    applicableCount = @($rows | Where-Object { $_.applicable -eq $true }).Count
    notApplicableCount = @($rows | Where-Object { $_.applicable -eq $false }).Count
    applicabilityUnknownCount = @($rows | Where-Object { $null -eq $_.applicable }).Count
    byTier = [ordered]@{
      standard   = @($catalog | Where-Object { $_.tier -eq 'standard' }).Count
      aggressive = @($catalog | Where-Object { $_.tier -eq 'aggressive' }).Count
      # 'guided' is a repair FrameForge cannot script: it opens the right Windows UI and
      # says what to click, and never claims the action was performed. wu-repair-reinstall
      # is the first of these. Counted separately so a renderer that only knew about
      # standard/aggressive keeps working while a newer one can show the tier.
      guided     = @($catalog | Where-Object { $_.tier -eq 'guided' }).Count
    }
    reversibleCount = @($catalog | Where-Object { $_.reversible }).Count
    restorePointEnforcedCount = @($catalog | Where-Object { Test-RestorePointEnforced $_ }).Count
    note = 'Every repair carries applicable / notApplicableReason computed from this machine''s build against the catalog''s minBuild / maxBuild / generation. A repair that does not apply here is still LISTED (with applicable:false and the reason) rather than hidden, so the ladder stays visible; applicable:null means the build could not be read, which is "could not determine", not "yes". Detection states here use fast probes; repairs marked probeDeep report indeterminate (reason: shallow-probe) until their deep probe runs at preflight/run. detection.reason distinguishes a probe that FAILED (probe-failure — the repair refuses) from one that merely needs elevation (needs-admin — the repair may proceed) and from one that read the real state but cannot judge it for you (user-initiated — the optional-feature repairs: a disabled feature is the Windows default, not a fault, so the engine reports the state and lets you decide).'
    repairs = $rows
  }
}

# ---------------- selftest: catalog integrity (read-only) ----------------

# Documented normalization applied to BOTH sides before whatItRuns is compared to the
# engine's step commands. Everything in here is a token whose VALUE legitimately varies
# per machine or per run; nothing here can hide a difference in what is actually executed.
$script:CommandNormalizationRules = @(
  'Expanded environment paths collapse to their token: %SystemRoot% (also %windir% / $env:SystemRoot), %ProgramData% (also %ALLUSERSPROFILE% / $env:ProgramData / $env:ALLUSERSPROFILE), %TEMP% ($env:TEMP). Matching is case-insensitive, so C:\WINDOWS and C:\Windows are the same path.',
  'A backup timestamp (yyyyMMdd-HHmmss) collapses to the literal token <timestamp>.',
  'Runs of whitespace collapse to a single space, and both ends are trimmed.',
  'Nothing else is normalized. After these substitutions the comparison is case-SENSITIVE and character-exact, so any real difference in a command, switch, path, or explanatory clause fails the test.'
)

function ConvertTo-FFNormalizedCommand {
  <# Applies $script:CommandNormalizationRules. Used on both the catalog text and the
     engine text so the comparison is between what they SAY, not between whose machine
     spells C:\WINDOWS in capitals. #>
  param([string]$Text)
  $s = "$Text"
  # IgnoreCase ALONE case-folds with the CURRENT CULTURE. Under Turkish (tr-TR) and
  # Azerbaijani casing rules the 'I' in C:\WINDOWS does not fold to the 'i' in C:\Windows,
  # so the %SystemRoot% normalization below silently failed, catalog and engine text stopped
  # matching, and `repair.ps1 -Action selftest` reported fabricated whatItRuns divergences
  # and exited 1 — the catalog-integrity gate crying wolf on every Turkish machine.
  # CultureInvariant is required at EVERY explicit [regex] call in this file.
  #
  # THE NOTE THAT USED TO BE HERE WAS WRONG, and it licensed unguarded matching everywhere else in
  # this file. It said: "PowerShell's own -match / -ieq operators are already culture-invariant and
  # need no change." Only -eq / -ieq are. -match, -notmatch, -like, -replace and -split all fold
  # case with the CURRENT CULTURE. Measured under CurrentCulture = tr-TR on PS 5.1:
  #     ('info' -match 'INFO')            -> False        ('file' -eq 'FILE') -> True
  #     ('CLIENT' -like 'Client*')        -> False        ('INFO' -match '(?i)info') -> False
  #     ('FILE' -replace 'file','X')      -> 'FILE'
  # The engine-wide answer is the invariant-culture thread pin at the top of this file, plus
  # Test-FFIMatch / Test-FFILike at the sites whose correctness DEPENDS on case-insensitive
  # matching. The explicit RegexOptions below stay regardless: they are what makes this function
  # correct even if the pin is refused (ConstrainedLanguage blocks the property set).
  $reOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
  # Expanded paths first, longest expansion first so nested paths collapse correctly.
  $expansions = @()
  foreach ($p in @(
      @{ v = "$env:SystemRoot";       t = '%SystemRoot%' },
      @{ v = "$env:TEMP";             t = '%TEMP%' },
      @{ v = "$env:ProgramData";      t = '%ProgramData%' },
      @{ v = "$env:ALLUSERSPROFILE";  t = '%ProgramData%' })) {
    if ("$($p.v)" -match '\S') { $expansions += $p }
  }
  foreach ($p in @($expansions | Sort-Object { -("$($_.v)".Length) })) {
    $s = [regex]::Replace($s, [regex]::Escape("$($p.v)"), "$($p.t)".Replace('$', '$$'), $reOpts)
  }
  # Then the literal spellings of the same tokens.
  foreach ($p in @(
      @{ f = '$env:SystemRoot';      t = '%SystemRoot%' },
      @{ f = '$env:windir';          t = '%SystemRoot%' },
      @{ f = '%windir%';             t = '%SystemRoot%' },
      @{ f = '$env:ALLUSERSPROFILE'; t = '%ProgramData%' },
      @{ f = '%ALLUSERSPROFILE%';    t = '%ProgramData%' },
      @{ f = '$env:ProgramData';     t = '%ProgramData%' },
      @{ f = '$env:TEMP';            t = '%TEMP%' })) {
    $s = [regex]::Replace($s, [regex]::Escape($p.f), $p.t.Replace('$', '$$'), $reOpts)
  }
  $s = [regex]::Replace($s, '\d{8}-\d{6}', '<timestamp>')
  $s = [regex]::Replace($s, '\s+', ' ')
  $s.Trim()
}

function Invoke-SelfTest {
  <#
    Proves two contracts that used to drift silently:
      1. Every id in data/health-checks.json `fixesAvailable` resolves to a real repair
         in data/repairs.json. A dangling id is a promise the UI cannot keep.
      2. For every repair, `whatItRuns` matches the engine's step commands LINE BY LINE,
         in order, as text — after the documented normalization above. This used to
         compare COUNTS ONLY while data/repairs.json claimed the lists were "positionally
         identical", which let eleven repairs drift (stale prose, an un-rendered
         "<chosen provider IPv4 + IPv6>" placeholder) without the test noticing. Counts
         are still reported, but a count match is no longer a pass.
    Read-only: builds step lists, never executes them.

    Step lists are built for a DEFAULT invocation — no -SourcePath, and -DnsProvider at
    its default — because that is what the catalog documents. Non-default switches change
    what the engine emits (correctly, and preflight shows it), and the catalog says so.
  #>
  $catalog = @(Load-Catalog)
  $ids = @($catalog | ForEach-Object { "$($_.id)" })

  $checkRows = @(); $dangling = @()
  $healthDoc = $null
  $healthError = $null
  if (Test-Path -LiteralPath $HealthCatalog) {
    # Same -Encoding UTF8 lesson as repairs.json: PS 5.1 would otherwise decode a
    # BOM-free UTF-8 catalog as Windows-1252 and mangle every non-ASCII character.
    try { $healthDoc = Get-Content -Raw -Encoding UTF8 -LiteralPath $HealthCatalog | ConvertFrom-Json } catch { $healthError = "$($_.Exception.Message)" }
  } else { $healthError = "health-checks.json not found at $HealthCatalog" }
  if ($null -ne $healthDoc) {
    foreach ($c in @($healthDoc.checks)) {
      $missing = @()
      foreach ($f in @($c.fixesAvailable)) { if ($ids -notcontains "$f") { $missing += "$f"; $dangling += "$($c.id) -> $f" } }
      $checkRows += [ordered]@{ check="$($c.id)"; fixesAvailable=@(@($c.fixesAvailable) | ForEach-Object { "$_" }); unresolved=$missing; ok=($missing.Count -eq 0) }
    }
  }

  # Deterministic, default invocation: whatever -DnsProvider / -SourcePath the caller
  # passed must not change what the catalog is measured against.
  $savedDnsKey = $script:ResolvedDnsProviderKey
  $savedSource = $script:ResolvedSourceArg
  $savedFeatureSource = $script:ResolvedFeatureSource
  $script:ResolvedDnsProviderKey = $script:DefaultDnsProviderKey
  $script:ResolvedSourceArg = $null
  $script:ResolvedFeatureSource = $null

  # Build-applicability schema. Every entry must declare minBuild, maxBuild and generation
  # EXPLICITLY — null is a fine value, a missing key is not. Without this the field can be
  # silently forgotten on the next repair added, and the catalog goes back to being unable
  # to say where a repair applies.
  $applicabilityRows = @(); $applicabilityProblems = @()
  foreach ($r in $catalog) {
    $names = @()
    try { $names = @($r.PSObject.Properties | ForEach-Object { "$($_.Name)" }) } catch {}
    $missing = @()
    foreach ($f in @('minBuild','maxBuild','generation')) { if ($names -notcontains $f) { $missing += $f } }
    $gen = $null
    try { $gen = "$($r.generation)" } catch {}
    $genOk = ($missing -contains 'generation') -or ($script:ValidGenerations -contains "$gen".ToLowerInvariant())
    if (-not $genOk) { $missing += "generation='$gen' is not one of $($script:ValidGenerations -join '/')" }
    $row = [ordered]@{
      id = "$($r.id)"
      minBuild = $(if ($names -contains 'minBuild') { $r.minBuild } else { $null })
      maxBuild = $(if ($names -contains 'maxBuild') { $r.maxBuild } else { $null })
      generation = $gen
      missing = $missing
      ok = ($missing.Count -eq 0)
    }
    $applicabilityRows += $row
    if ($missing.Count -gt 0) { $applicabilityProblems += "$($r.id): $($missing -join ', ')" }
  }

  $stepRows = @(); $mismatches = @(); $textMismatches = @()
  foreach ($r in $catalog) {
    $declaredList = @(@($r.whatItRuns) | ForEach-Object { "$_" })
    $declared = $declaredList.Count
    $actual = $null; $err = $null
    $engineList = @()
    try {
      $ctx = New-RepairContext $r
      $steps = @(Get-RepairSteps $r $ctx)
      foreach ($s in $steps) { foreach ($c in @($s.commands)) { $engineList += "$c" } }
      $actual = $engineList.Count
    } catch { $err = "$($_.Exception.Message)" }
    $countOk = ($null -ne $actual -and $actual -eq $declared)
    if (-not $countOk) { $mismatches += "$($r.id) (whatItRuns=$declared, engine=$actual$(if ($err) { "; $err" }))" }

    # LINE-BY-LINE text comparison, the thing the catalog actually promises.
    $divergences = @()
    if ($null -ne $actual) {
      $n = [Math]::Max($declared, $actual)
      for ($i = 0; $i -lt $n; $i++) {
        $cat = ''; if ($i -lt $declared) { $cat = $declaredList[$i] }
        $eng = ''; if ($i -lt $actual)   { $eng = $engineList[$i] }
        $catN = ConvertTo-FFNormalizedCommand $cat
        $engN = ConvertTo-FFNormalizedCommand $eng
        if ($catN -cne $engN) {
          $divergences += [ordered]@{ index=$i; catalog=$cat; engine=$eng; catalogNormalized=$catN; engineNormalized=$engN }
          $textMismatches += "$($r.id)[$i]"
        }
      }
    }
    $textOk = ($null -ne $actual -and $divergences.Count -eq 0)
    $ok = ($countOk -and $textOk)
    $stepRows += [ordered]@{
      id="$($r.id)"; whatItRunsCount=$declared; engineCommandCount=$actual
      countOk=$countOk; textOk=$textOk; divergences=$divergences; error=$err; ok=$ok
    }
  }

  $script:ResolvedDnsProviderKey = $savedDnsKey
  $script:ResolvedSourceArg = $savedSource
  $script:ResolvedFeatureSource = $savedFeatureSource

  # Every relevantFindings pattern should be able to match something health.ps1 emits.
  # Purely informational (patterns may be wildcards), but it catches renamed findings.
  $findingPatterns = @()
  foreach ($r in $catalog) {
    foreach ($p in @($r.relevantFindings)) { $findingPatterns += [ordered]@{ repair="$($r.id)"; pattern="$p" } }
  }

  $allOk = ($dangling.Count -eq 0 -and $mismatches.Count -eq 0 -and $textMismatches.Count -eq 0 -and $applicabilityProblems.Count -eq 0 -and $null -eq $healthError)
  [ordered]@{
    ok = $allOk
    action = 'selftest'
    repairCount = $catalog.Count
    repairIds = $ids
    healthCatalog = $HealthCatalog
    healthCatalogError = $healthError
    buildApplicabilityIntegrity = [ordered]@{
      ok = ($applicabilityProblems.Count -eq 0)
      requiredFields = @('minBuild','maxBuild','generation')
      validGenerations = @($script:ValidGenerations)
      problems = $applicabilityProblems
      byRepair = $applicabilityRows
      note = 'Every catalog entry must declare all three fields EXPLICITLY; null means "no bound" and is a valid value, a missing key is not. This is what stops the next repair added from silently losing its build gate.'
    }
    fixesAvailableIntegrity = [ordered]@{
      ok = ($dangling.Count -eq 0)
      checked = $checkRows.Count
      distinctIdsReferenced = @(@($checkRows | ForEach-Object { $_.fixesAvailable }) | ForEach-Object { $_ } | Select-Object -Unique).Count
      unresolved = $dangling
      byCheck = $checkRows
    }
    whatItRunsIntegrity = [ordered]@{
      ok = ($mismatches.Count -eq 0 -and $textMismatches.Count -eq 0)
      mode = 'normalized-line-by-line-text'
      builtWith = [ordered]@{ dnsProvider = "$($script:DefaultDnsProviderKey)"; sourcePath = $null; featureSource = $null }
      countMismatches = $mismatches
      textMismatches = $textMismatches
      normalization = @($script:CommandNormalizationRules)
      byRepair = $stepRows
    }
    relevantFindingPatterns = $findingPatterns
    note = 'Read-only: step lists were built but never executed; no ledger entry and no restore point were created. Run this after any catalog edit. whatItRunsIntegrity is a real line-by-line text comparison (see whatItRunsIntegrity.normalization for exactly what is normalized first) — a matching command COUNT is no longer enough to pass.'
  }
}

# ---------------- SourcePath validation ----------------

function Resolve-SourceArg {
  param([string]$Path)
  if (-not $Path) { return $null }
  $m = [regex]::Match($Path, '^(?<file>.+\.(?<ext>[Ww][Ii][Mm]|[Ee][Ss][Dd]))(?::(?<idx>\d+))?$')
  if (-not $m.Success) { throw "-SourcePath must point to an install.wim or install.esd, optionally with :<index> appended (e.g. E:\sources\install.esd:1) — got '$Path'." }
  $file = $m.Groups['file'].Value
  if (-not (Test-Path -LiteralPath $file)) { throw "-SourcePath file not found: $file" }
  $idx = '1'
  if ($m.Groups['idx'].Success) { $idx = $m.Groups['idx'].Value }
  $prefix = 'WIM'
  if ($m.Groups['ext'].Value -match '^[Ee]') { $prefix = 'ESD' }
  # The WIM:/ESD: prefix is case-sensitive in practice; /LimitAccess is added by the
  # step so DISM cannot fall back to a broken Windows Update.
  return "/Source:${prefix}:${file}:${idx}"
}

# ---------------- dispatch ----------------

$out = $null
$exitCode = 0

# -SourcePath is NOT resolved yet: doing that here meant that
# `preflight -Id sfc-scannow -SourcePath C:\nope\install.wim` answered "file not found"
# when the real answer is "that repair does not take a source". Resolution happens after
# the repair id is known, so the more fundamental error wins.
$script:ResolvedSourceArg = $null
$script:ResolvedDnsProviderKey = $null
$script:ResolvedFeatureSource = $null

# Application control (WDAC / AppLocker) forces ConstrainedLanguage, where the [Security.Principal]
# identity casts behind Test-Admin, Add-Type (the volume/power APIs in _lib.ps1) and [xml] casts all
# throw — so this engine cannot do its job and, worse, could not even say so: it died with empty
# stdout and the host could only report "the engine returned no output". Emit the same single JSON
# error document health.ps1 emits, from the same shared helper in _lib.ps1 (health owns that file;
# this is the consumer side), and exit 3 — a refusal, not a crash.
if (-not (Test-FFFullLanguage)) {
  Write-FFJson -InputObject (New-FFLanguageModeError) -Depth 6
  exit 3
}

try {
  if ($ValidActions -notcontains $Action) {
    $out = [ordered]@{ ok=$false; error="Unknown action '$Action'."; validActions=$ValidActions }
    $exitCode = 2
  } else {
    # -DnsProvider is validated up front for every action so `list` and `preflight`
    # report the same provider the run would use.
    $script:ResolvedDnsProviderKey = "$DnsProvider".ToLowerInvariant()
    if (-not $DnsProviders.Contains($script:ResolvedDnsProviderKey)) {
      $out = [ordered]@{ ok=$false; error="Unknown -DnsProvider '$DnsProvider'."; validProviders=@($DnsProviders.Keys) }
      $exitCode = 2
    } else {
      switch ($Action) {
        'list'     { $out = Invoke-List }
        'selftest' { $out = Invoke-SelfTest; if (-not $out.ok) { $exitCode = 1 } }
        'ledger' {
          # An UNREADABLE ledger is not an empty one, and it must never render as "no repairs
          # recorded" (see Get-RepairLedgerState). count stays $null when nothing was counted.
          $st = Get-RepairLedgerState
          if (-not $st.readable) {
            $out = [ordered]@{
              ok = $false
              errorCode = 'ledger-unreadable'
              error = "$($st.error) No usable ledger could be read from that file, so FrameForge cannot say what has or has not been run — which is a different answer from 'no repairs recorded', and it must not be rendered as one. `undo` has nothing to work from until the file can be read."
              count = $null
              ledgerPath = $st.path
              ledgerSource = $st.source
              stateDir = $StateDir
              # Where the state root came from: 'localappdata' | 'env-override' | 'temp-fallback'.
              # 'env-override' means $env:FRAMEFORGE_STATE_DIR named it (a test sandbox or an embedder).
              stateDirSource = "$($script:StateDirSource)"
              legacyLedgerPath = $LegacyLedger
              migration = $st.migration
              entries = $null
            }
            $exitCode = 1
          } else {
            $out = [ordered]@{
              ok = $true
              count = $st.count
              ledgerPath = $st.path
              # Additive provenance so a support conversation never has to guess which file was read.
              ledgerSource = $st.source
              stateDir = $StateDir
              # Where the state root came from: 'localappdata' | 'env-override' | 'temp-fallback'.
              # 'env-override' means $env:FRAMEFORGE_STATE_DIR named it (a test sandbox or an embedder).
              stateDirSource = "$($script:StateDirSource)"
              legacyLedgerPath = $LegacyLedger
              migration = $st.migration
              entries = @($st.entries)
            }
          }
        }
        default {
          if (-not $Id) {
            $out = [ordered]@{ ok=$false; error="Action '$Action' requires -Id."; validIds=@(@(Load-Catalog) | ForEach-Object { $_.id }) }
            $exitCode = 2
            break
          }
          $repair = Get-RepairById $Id
          if ($null -eq $repair) {
            $out = [ordered]@{ ok=$false; error="Unknown repair id '$Id'."; validIds=@(@(Load-Catalog) | ForEach-Object { $_.id }) }
            $exitCode = 2
            break
          }
          # -SourcePath means two different (documented) things depending on the repair:
          #   dism-restorehealth        an install.wim/esd file, optionally :<index>
          #   the optional-feature set  a FOLDER of feature payload, i.e. <media>\sources\sxs
          # Anything else takes no source at all and says so rather than silently ignoring it.
          $takesFeatureSource = ($OptionalFeatureRepairs -contains "$($repair.id)")
          if ($SourcePath -and $repair.id -ne 'dism-restorehealth' -and -not $takesFeatureSource) {
            $out = [ordered]@{ ok=$false; error="-SourcePath only applies to 'dism-restorehealth' (an install.wim/esd) and the optional-feature repairs ($($OptionalFeatureRepairs -join ', '), a <media>\sources\sxs folder); '$($repair.id)' takes no source."; givenSourcePath=$SourcePath }
            $exitCode = 2
            break
          }
          if ($SourcePath -and $takesFeatureSource) {
            if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
              $out = [ordered]@{ ok=$false; error="-SourcePath for '$($repair.id)' must be an existing FOLDER holding the feature payload — normally <mounted media>\sources\sxs. Not found (or not a folder): $SourcePath"; action=$Action; id=$repair.id }
              $exitCode = 2
              break
            }
            $script:ResolvedFeatureSource = (Resolve-Path -LiteralPath $SourcePath).Path
          } elseif ($SourcePath) {
            try { $script:ResolvedSourceArg = Resolve-SourceArg $SourcePath }
            catch {
              $out = [ordered]@{ ok=$false; error="$($_.Exception.Message)"; action=$Action; id=$repair.id }
              $exitCode = 2
              break
            }
          }
          switch ($Action) {
            'preflight' { $out = Invoke-Preflight $repair }
            'run'       {
              $out = Invoke-RepairRun $repair
              # A repair that does not exist on this build, or a platform FrameForge is not
              # validated on, is its own exit code, so a caller can tell "wrong build / wrong
              # Windows" from "the repair failed" (1) and from "bad input" (2) without parsing prose.
              if ("$($out.errorCode)" -eq 'not-applicable-on-this-build' -or "$($out.errorCode)" -eq 'unsupported-os') { $exitCode = 3 }
            }
            'undo'      { $out = Invoke-RepairUndo $repair }
          }
        }
      }
    }
  }
} catch {
  $out = [ordered]@{ ok=$false; error="$($_.Exception.Message)"; action=$Action; id=$Id }
  $exitCode = 1
}

if ($null -eq $out) {
  $out = [ordered]@{ ok=$false; error="Action '$Action' produced no result document."; action=$Action; id=$Id }
  $exitCode = 1
}
Write-FFJson -InputObject $out -Depth 14
exit $exitCode
