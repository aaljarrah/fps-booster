<#
  FrameForge :: engine.ps1
  Transactional tweak engine. Every apply records the exact prior state to a backup ledger so
  every change is perfectly reversible. Supports detect / apply / revert / detect-all / revert-all /
  restore-point. Data-driven from data/tweaks.json (single source of truth, shared with the UI).

  Usage:
    engine.ps1 -Action detect-all
    engine.ps1 -Action apply  -Id <tweakId> [-DryRun]
    engine.ps1 -Action revert -Id <tweakId> [-DryRun]
    engine.ps1 -Action revert-all [-DryRun]
    engine.ps1 -Action restore-point -Description "FrameForge"
    engine.ps1 -Action identity                # whose Windows profile is this engine writing?

  Every action accepts -OriginSid <SID>: the SID the unelevated FrameForge read from its own
  token before relaunching itself elevated. Per-user (HKCU) work is REFUSED when that account
  is not the one this process is running as — see the PER-USER SCOPE INTEGRITY block below.

  Always emits a single JSON object/array on stdout, including for an unknown -Action
  (ok:false + validActions, exit 2). Nothing here ever exits with empty stdout.
#>
[CmdletBinding()]
param(
  # NO [ValidateSet] here, deliberately. A ValidateSet failure is a PowerShell PARAMETER
  # BINDING error: the script never starts, stdout is empty and a raw binding exception goes
  # to stderr. The Electron host parses exactly one JSON document per run, so it saw nothing
  # at all and had to invent a reason. The action is validated in the body instead (see
  # $ValidActions), which emits the standard {ok:false, error, validActions} document and
  # still exits non-zero. repair.ps1, image.ps1 and compat.ps1 already do it this way.
  # 'identity' is additive: it reports which Windows account this engine is running for.
  [Parameter(Mandatory)]
  [string]$Action,
  [string]$Id,
  [string]$Description = 'FrameForge optimization',
  [switch]$DryRun,
  # The SID the UNELEVATED FrameForge read from its own token before relaunching itself
  # elevated. It is the only certain answer to "who is at the keyboard", because it came from
  # that user's own process. Optional: when absent the engine probes for it and says so.
  [string]$OriginSid
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Without this, non-ASCII in tweak copy (em-dashes, arrows) is substituted on the way to
# stdout and the emitted JSON stops parsing. Matches engine/_lib.ps1.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$Root      = Split-Path -Parent $PSScriptRoot
$TweaksDb  = Join-Path $Root 'data\tweaks.json'

# Runtime state NEVER lives in the install tree. A per-machine install under %ProgramFiles%, a
# read-only/network copy, Controlled Folder Access, or a OneDrive Known-Folder-Move profile all
# make <install>\data\state unwritable — and an engine that cannot write its ledger cannot undo
# anything (doctrine rule 3). %LOCALAPPDATA% is per-user and always writable.
$StateBase = $env:LOCALAPPDATA
if (-not $StateBase) { $StateBase = $env:TEMP }
# Plain concatenation, not Join-Path: Join-Path resolves the PSDrive and THROWS under
# $ErrorActionPreference='Stop' when the root is bogus, which would kill the script before it
# could emit the one-JSON error document the host needs.
$StateDir       = ($StateBase.TrimEnd('\')) + '\FrameForge\state'
$LegacyStateDir = Join-Path $Root 'data\state'
$Ledger         = $StateDir + '\applied.json'

function Write-FFOut { param($Object) [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Object -Depth 12 -Compress)) }

try {
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  # One-time migration of a v0.1 ledger that was written into the install tree.
  $legacyLedger = Join-Path $LegacyStateDir 'applied.json'
  if ((Test-Path -LiteralPath $legacyLedger) -and -not (Test-Path -LiteralPath $Ledger)) {
    Copy-Item -LiteralPath $legacyLedger -Destination $Ledger -Force -ErrorAction SilentlyContinue
  }
} catch {
  # Never die before emitting JSON: the host parses stdout, and empty stdout reads as a crash.
  Write-FFOut ([ordered]@{ action=$Action; success=$false; ok=$false; determined=$false
    message="FrameForge could not create its state folder at '$StateDir': $($_.Exception.Message)" })
  exit 0
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$IsAdmin = Test-Admin

# ============================================================================
#  PER-USER SCOPE INTEGRITY — which Windows profile are we actually writing to?
#
#  The app elevates by relaunching itself with `Start-Process -Verb RunAs`. On a PC whose
#  interactive user is NOT an administrator (school, work and family machines) UAC asks for a
#  different account, and from that moment the whole engine runs as the helper. HKCU is the
#  HELPER's hive. $env:LOCALAPPDATA is the HELPER's folder, so this script's undo ledger goes
#  there too. Four tweaks (disable-gamedvr, game-mode-on, disable-visual-effects,
#  mouse-accel-off) are pure HKCU writes with requiresAdmin:false, so nothing stopped them:
#  they were written into the administrator's profile and reported applied AND verified — the
#  verify read back the same wrong hive — while the gamer's own profile never changed. A later
#  unelevated "Revert all tweaks" then read an EMPTY ledger and reported success.
#
#  Everything below exists to make that impossible. It answers a TRI-STATE:
#    $false = measured, same account        -> per-user work proceeds normally
#    $true  = measured, different account   -> per-user work is REFUSED, by name
#    $null  = could not determine           -> per-user work is REFUSED while elevated, and
#                                              detection answers "could not determine"
#  It is never allowed to default to $false.
# ============================================================================
$script:FFIdentity = $null
$FFSidPattern = '^S-1-[0-9\-]{1,60}$'

function Get-FFInteractiveSid {
  <# The SID of the person at the keyboard. Structural rungs first; the account-name rung is a
     documented last resort; "could not determine" is a real answer. #>
  $err = @()
  $sessionId = $null
  try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { $err += "Could not read this process's session id: $($_.Exception.Message)" }

  # RUNG 1 (structural, SID-native, no text anywhere): the owner of the shell process in OUR
  # OWN session. Over-the-shoulder UAC elevation creates the elevated process in the SAME
  # interactive session, so the explorer.exe sharing our SessionId belongs to the gamer.
  if ($null -ne $sessionId) {
    try {
      $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                 Where-Object { $_.SessionId -eq $sessionId })
      $sids = @()
      foreach ($p in $procs) {
        try {
          $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
          if ($o -and [int]$o.ReturnValue -eq 0 -and $o.Sid) { $sids += "$($o.Sid)" }
          elseif ($o) { $err += "GetOwnerSid returned $($o.ReturnValue) for pid $($p.ProcessId)." }
        } catch { $err += "GetOwnerSid failed for pid $($p.ProcessId): $($_.Exception.Message)" }
      }
      $distinct = @($sids | Sort-Object -Unique)
      if ($distinct.Count -eq 1) {
        return [pscustomobject]@{ sid = $distinct[0]; source = 'shell-owner-sid'; error = $null }
      }
      if ($distinct.Count -gt 1) { $err += "More than one account owns a shell process in session $sessionId, so the interactive user is ambiguous." }
      elseif ($procs.Count -eq 0) { $err += "No shell process (explorer.exe) is running in session $sessionId." }
    } catch { $err += "Could not enumerate shell processes: $($_.Exception.Message)" }
  }

  # RUNG 2 (last resort, name-based): the console user CIM reports, translated to a SID. An
  # account name is an identifier rather than localized display text, but the translation needs
  # a reachable authority — on a disconnected domain member it fails, and then we say so.
  try {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if ($u) {
      $sid = (New-Object System.Security.Principal.NTAccount("$u")).Translate([System.Security.Principal.SecurityIdentifier]).Value
      if ("$sid" -match $FFSidPattern) {
        return [pscustomobject]@{ sid = "$sid"; source = 'console-username-translated'; error = (@($err) -join ' ') }
      }
    } else { $err += 'Windows reports no interactive user on this computer.' }
  } catch { $err += "Could not resolve the console user to a SID: $($_.Exception.Message)" }

  [pscustomobject]@{ sid = $null; source = $null; error = (@($err) -join ' ') }
}

function Get-FFIdentity {
  <# Cached. Fields:
       tokenSid/tokenName   who this process IS
       interactiveSid       who is at the keyboard ($null = could not determine)
       basis                how interactiveSid was obtained
       profileMismatch      $true / $false / $null (tri-state, never defaults)
       reason               why it is $null, when it is
       ledgerPath           the undo ledger this account actually reads and writes #>
  if ($script:FFIdentity) { return $script:FFIdentity }
  $tokenSid = $null; $tokenName = $null
  try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $tokenSid = "$($wi.User.Value)"; $tokenName = "$($wi.Name)"
  } catch {}

  # The pre-elevation SID handed down by the unelevated instance outranks every probe: it was
  # read from that process's OWN token, so it cannot be wrong. The probe is the fallback for a
  # FrameForge that was started elevated in the first place.
  # NOT named $originSid: PowerShell variable names are case-insensitive, so a local
  # `$originSid` IS the `$OriginSid` parameter and assigning $null to it silently threw the
  # caller's value away. (Measured: originSidGiven came back false for a SID that was passed.)
  $givenSid = $null
  if ($OriginSid -and ("$OriginSid" -match $FFSidPattern)) { $givenSid = "$OriginSid" }
  $probe = Get-FFInteractiveSid
  $interactive = $givenSid
  $basis = 'origin-sid'
  if (-not $interactive) { $interactive = $probe.sid; $basis = $probe.source }

  $mismatch = $null; $reason = $null
  if (-not $tokenSid) {
    $reason = 'FrameForge could not read the Windows account it is running as, so it cannot tell whose settings it would be changing.'
    $basis = $null
  } elseif ($interactive) {
    $mismatch = -not ($interactive -eq $tokenSid)
  } elseif (-not $IsAdmin) {
    # Not elevated. FrameForge can only end up under a different account by being elevated
    # (or by a deliberate `runas`, which the probes above DO catch — rung 2 works for a
    # standard user). With no elevation and no probe answer, the account that launched this
    # process is the account that owns the desktop it was launched from.
    $mismatch = $false
    $basis = 'not-elevated'
    $reason = "The interactive user could not be identified directly ($($probe.error)), but FrameForge is not running elevated, so it is running as whoever started it."
  } else {
    $reason = "FrameForge is running elevated and could not identify the interactive user, so it cannot prove whose profile it would write to. $($probe.error)"
  }

  $script:FFIdentity = [ordered]@{
    action          = 'identity'
    measured        = $true
    ok              = $true
    isAdmin         = [bool]$IsAdmin
    tokenSid        = $tokenSid
    tokenName       = $tokenName
    interactiveSid  = $interactive
    interactiveName = $null
    basis           = $basis
    originSidGiven  = [bool]$givenSid
    profileMismatch = $mismatch
    reason          = $reason
    probeError      = $probe.error
    ledgerPath      = $Ledger
  }
  # Display name for the interactive SID: cosmetic only, and its absence changes nothing.
  if ($interactive) {
    try { $script:FFIdentity.interactiveName = "$((New-Object System.Security.Principal.SecurityIdentifier($interactive)).Translate([System.Security.Principal.NTAccount]).Value)" } catch {}
  }
  $script:FFIdentity
}

function Get-FFUserScopedPaths {
  <# Every HKCU path an op would write. Empty array = the op is not per-user. #>
  param($op)
  $out = @()
  if (-not $op) { return @() }
  if ("$($op.type)" -eq 'multi') {
    foreach ($sub in @($op.ops)) { $out += (Get-FFUserScopedPaths $sub) }
    return @($out)
  }
  if ("$($op.type)" -eq 'registry') {
    $r = "$($op.root)".Trim().ToUpperInvariant()
    if ($r -eq 'HKCU' -or $r -eq 'HKEY_CURRENT_USER') { $out += "HKCU\$($op.path)\$($op.name)" }
  }
  @($out)
}

function Get-FFProfileScopeRefusal {
  <# The refusal message for a per-user op FrameForge must not perform under this token, or
     $null when it is safe. Doctrine rule 2: an unproven scope is a refusal, not a silent write. #>
  param($op)
  $paths = @(Get-FFUserScopedPaths $op)
  if ($paths.Count -eq 0) { return $null }
  $id = Get-FFIdentity
  if ($id.profileMismatch -eq $false) { return $null }
  if ($id.profileMismatch -eq $true) {
    $who = $id.interactiveName; if (-not $who) { $who = $id.interactiveSid }
    $me  = $id.tokenName;       if (-not $me)  { $me  = $id.tokenSid }
    return ("This is a per-user setting, and FrameForge is running as '$me' while '$who' is the account signed in at this PC. " +
            'Writing it now would change the wrong account''s settings and leave yours untouched, so FrameForge did not write anything. ' +
            'Per-user tweaks do not need administrator rights: close this window, start FrameForge normally (without "Run as administrator") and apply it there.')
  }
  return ('This is a per-user setting, and FrameForge could not confirm which Windows account it is writing for ' +
          "($($id.reason)). It will not change per-user settings it cannot prove belong to you. " +
          'Per-user tweaks do not need administrator rights: start FrameForge without "Run as administrator" and apply it there.')
}

function Get-FFPowerScopeWarning {
  <# powercfg acts on the CALLING account's power configuration. When the token is not the
     interactive user's, that is worth saying out loud — but FrameForge does not claim to have
     measured that it lands in the wrong place, so this is a warning, not a refusal. #>
  param($op)
  if (-not $op) { return $null }
  if ("$($op.type)" -eq 'multi') {
    foreach ($sub in @($op.ops)) { $w = Get-FFPowerScopeWarning $sub; if ($w) { return $w } }
    return $null
  }
  if ("$($op.type)" -notlike 'powercfg*') { return $null }
  $id = Get-FFIdentity
  if ($id.profileMismatch -ne $true) { return $null }
  $who = $id.interactiveName; if (-not $who) { $who = $id.interactiveSid }
  $me  = $id.tokenName;       if (-not $me)  { $me  = $id.tokenSid }
  return "FrameForge is running as '$me', not as the signed-in user '$who'. Windows applies power settings for the account that changes them, so this may not affect '$who'."
}

function Load-Tweaks {
  # -LiteralPath everywhere: a bracket in the install path ("FrameForge [beta]") makes Test-Path
  # return $false and makes Get-Content -Path -Raw fail outright, killing the whole tweak engine.
  if (-not (Test-Path -LiteralPath $TweaksDb)) { throw "tweaks.json not found at $TweaksDb" }
  # -Encoding UTF8 is load-bearing: tweaks.json has no BOM, so PS 5.1 would decode it
  # as Windows-1252 and mangle every em-dash — which broke `-Action list` JSON outright.
  (Get-Content -Raw -Encoding UTF8 -LiteralPath $TweaksDb | ConvertFrom-Json).tweaks
}
function Get-Tweak { param($Id) Load-Tweaks | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Get-FFLedgerForeign {
  <# Ledger records written by a DIFFERENT Windows account. A record carries the SID that wrote
     it, so an undo can never quietly "restore" a value it never captured — under a mismatched
     token the HKCU value in the record belongs to another hive entirely. Records written before
     stamping existed have no userSid and are treated as foreign ONLY when the account cannot be
     confirmed, so an ordinary same-user upgrade keeps working. #>
  param($Records)
  $id = Get-FFIdentity
  $out = @()
  foreach ($r in @($Records)) {
    if (-not $r) { continue }
    $sid = $null
    try { if ($r.PSObject.Properties.Name -contains 'userSid') { $sid = "$($r.userSid)" } } catch {}
    if ($sid) { if ($id.tokenSid -and $sid -ne $id.tokenSid) { $out += $r } }
    elseif ($id.profileMismatch -ne $false) { $out += $r }
  }
  @($out)
}

function Load-Ledger {
  if (-not (Test-Path -LiteralPath $Ledger)) { return @() }
  $parsed = Get-Content -Raw -Encoding UTF8 -LiteralPath $Ledger | ConvertFrom-Json
  if ($null -eq $parsed) { return @() }
  # Defensive: tolerate a legacy {value:[...],Count:n} wrapper from an older serializer.
  if ($parsed.PSObject.Properties.Name -contains 'value' -and $parsed.PSObject.Properties.Name -contains 'Count') { $parsed = $parsed.value }
  @($parsed)
}
function Save-Ledger {
  param($Records)
  $arr = @($Records)
  if ($arr.Count -eq 0) { Set-Content -LiteralPath $Ledger -Value '[]' -Encoding UTF8; return }
  # Serialize each record independently and join — deterministic JSON array regardless of PS 5.1
  # single-element ConvertTo-Json quirks.
  $items = foreach ($r in $arr) { ConvertTo-Json -InputObject $r -Depth 10 }
  Set-Content -LiteralPath $Ledger -Value ("[`r`n" + (($items) -join ",`r`n") + "`r`n]") -Encoding UTF8
}
function Upsert-Ledger {
  param($Record)
  $all = @(Load-Ledger | Where-Object { $_.id -ne $Record.id })
  $all += $Record
  Save-Ledger $all
}
function Remove-FromLedger { param($Id) Save-Ledger @(Load-Ledger | Where-Object { $_.id -ne $Id }) }

# ---------------- powercfg helpers (locale-independent) ----------------
# powercfg's CONSOLE TEXT is localized: "Current AC Power Setting Index:", the scheme names in
# /list, everything. Deciding anything by matching that English text silently fails on the ~70%
# of Windows installs that are not English. Everything below is keyed on GUIDs and registry
# values, which are locale-invariant; powercfg.exe is used only to WRITE, and every write is
# exit-code checked. Text parsing survives only as a documented English-only LAST resort that
# answers "could not determine" ($null) instead of guessing when it does not match.
$PowerSchemesKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$GuidPattern     = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
$SUB_PROCESSOR   = '54533251-82be-4824-96c1-47b60b740d00'
$PROCTHROTTLEMIN = '893dee8e-2bef-41e0-89c6-b55d0929964c'

function Invoke-PowerCfg {
  <# Runs powercfg.exe and returns @{ ok; exit; output }. Never throws.
     $ErrorActionPreference is dropped to Continue for the call because PS 5.1 turns native
     stderr under `2>&1` into NativeCommandError records, which would throw under 'Stop'. #>
  param([string[]]$Arguments)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $code = -1; $text = ''
  try {
    $global:LASTEXITCODE = 0
    $raw = & powercfg.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ((@($raw) | ForEach-Object { "$_" }) -join ' ').Trim()
  } catch {
    $text = "$($_.Exception.Message)"
  } finally { $ErrorActionPreference = $prev }
  [pscustomobject]@{ ok = ($code -eq 0); exit = $code; output = $text }
}

function Get-ActiveSchemeGuid {
  <# Active power scheme GUID. $null means "could not determine" — never a fake default. #>
  try {
    $v = (Get-ItemProperty -LiteralPath $PowerSchemesKey -Name 'ActivePowerScheme' -ErrorAction Stop).ActivePowerScheme
    if ("$v" -match $GuidPattern) { return $Matches[1].ToLower() }
  } catch {}
  # Fallback: powercfg's own output — we read only the GUID from it, never the scheme NAME.
  $r = Invoke-PowerCfg @('/getactivescheme')
  if ($r.ok -and $r.output -match $GuidPattern) { return $Matches[1].ToLower() }
  return $null
}

function Get-InstalledSchemeGuids {
  <# GUIDs of every installed power scheme, from the registry subkey names.
     $null = could not enumerate (distinct from "none installed"). #>
  try {
    return @(Get-ChildItem -LiteralPath $PowerSchemesKey -ErrorAction Stop |
             ForEach-Object { "$($_.PSChildName)" } |
             Where-Object { $_ -match ('^' + $GuidPattern + '$') } |
             ForEach-Object { $_.ToLower() })
  } catch { return $null }
}

function Get-SchemeTemplateId {
  <# WHICH built-in plan a scheme is (or was duplicated from), locale-invariantly. A plan's
     FriendlyName registry value is an MUI reference of the form
     '@C:\WINDOWS\system32\powrprof.dll,-19,Ultimate Performance' — the resource id (-19) is the
     identity and never changes; only the trailing display text is localized, and it is ignored.
     Verified on the dev box: the built-in Ultimate Performance plan and the duplicate created
     from it both carry 'powrprof.dll,-19'. Returns e.g. 'powrprof.dll,-19', or $null. #>
  param([string]$SchemeGuid)
  if (-not $SchemeGuid) { return $null }
  try {
    $p = Get-ItemProperty -LiteralPath ($PowerSchemesKey + '\' + $SchemeGuid) -Name 'FriendlyName' -ErrorAction Stop
    if ("$($p.FriendlyName)" -match '(?i)@.*[\\/]([^\\/,]+\.dll)\s*,\s*(-?\d+)') { return ($Matches[1] + ',' + $Matches[2]).ToLower() }
  } catch {}
  return $null
}

function Find-SchemeByTemplate {
  <# An already-installed scheme that is the given built-in plan or a duplicate of it. Stops the
     old behaviour of duplicating a new plan on EVERY apply because a localized name never matched. #>
  param([string]$TemplateGuid)
  $tid = Get-SchemeTemplateId $TemplateGuid
  $installed = Get-InstalledSchemeGuids
  if (-not $installed) { return $null }
  if ($installed -contains "$TemplateGuid".ToLower()) { return "$TemplateGuid".ToLower() }
  if (-not $tid) { return $null }
  foreach ($g in $installed) { if ((Get-SchemeTemplateId $g) -eq $tid) { return $g } }
  return $null
}

function Get-PowerCfgIndex {
  <# The AC or DC setting index for a subgroup/setting under a scheme.
     Registry -> CIM -> (documented English-only) powercfg text -> $null. #>
  param($Subgroup, $Setting, [ValidateSet('AC', 'DC')]$Which, $SchemeGuid)
  if (-not $SchemeGuid) { $SchemeGuid = Get-ActiveSchemeGuid }
  if (-not $SchemeGuid) { return $null }
  $valueName = 'ACSettingIndex'
  if ($Which -eq 'DC') { $valueName = 'DCSettingIndex' }
  # 1) The registry values powercfg itself reads and writes.
  try {
    $key = $PowerSchemesKey + '\' + $SchemeGuid + '\' + $Subgroup + '\' + $Setting
    $p = Get-ItemProperty -LiteralPath $key -Name $valueName -ErrorAction Stop
    return [int]$p.$valueName
  } catch {}
  # 2) Structured CIM: root\cimv2\power Win32_PowerSettingDataIndex. Enumerated values, no text.
  try {
    $pat = '(?i)\{?' + [regex]::Escape($SchemeGuid) + '\}?\\' + $Which + '\\\{?' + [regex]::Escape($Subgroup) + '\}?\\\{?' + [regex]::Escape($Setting) + '\}?$'
    $inst = @(Get-CimInstance -Namespace 'root\cimv2\power' -ClassName Win32_PowerSettingDataIndex -ErrorAction Stop |
              Where-Object { "$($_.InstanceID)" -match $pat })
    if ($inst.Count -gt 0) { return [int]$inst[0].SettingIndexValue }
  } catch {}
  # 3) LAST RESORT, ENGLISH-ONLY BY CONSTRUCTION. powercfg /query prints localized labels, so
  #    this matches only on an en-US machine. It exists so an English box with an unreadable
  #    registry still answers; on every other locale it simply does not match and we return
  #    $null ("could not determine") rather than inventing a value.
  try {
    $q = Invoke-PowerCfg @('/query', $SchemeGuid, $Subgroup, $Setting)
    if ($q.ok) {
      $pat2 = 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)'
      if ($Which -eq 'DC') { $pat2 = 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)' }
      if ($q.output -match $pat2) { return [Convert]::ToInt32($Matches[1], 16) }
    }
  } catch {}
  return $null
}

function Set-PowerCfgIndex {
  <# Writes one index through powercfg.exe (the only supported writer) and CHECKS the exit code.
     Returns $null on success or an error string. #>
  param($SchemeGuid, $Subgroup, $Setting, [ValidateSet('AC', 'DC')]$Which, $Value)
  $verb = '/setacvalueindex'
  if ($Which -eq 'DC') { $verb = '/setdcvalueindex' }
  $r = Invoke-PowerCfg @($verb, "$SchemeGuid", "$Subgroup", "$Setting", "$Value")
  if ($r.ok) { return $null }
  return "powercfg $verb (exit $($r.exit)): $($r.output)"
}

function Get-OpPowerScopes {
  <# Which power indexes an op is allowed to touch. Default 'ac' — writing the DC index changes
     what a laptop does on battery, and doctrine rule 5 says the catalog documents what runs. #>
  param($op, [string]$Field = 'scope')
  $s = 'ac'
  if ($op -and ($op.PSObject.Properties.Name -contains $Field) -and $op.$Field) { $s = "$($op.$Field)".ToLower() }
  if ($s -eq 'ac+dc' -or $s -eq 'dc+ac' -or $s -eq 'both') { return @('AC', 'DC') }
  if ($s -eq 'dc') { return @('DC') }
  return @('AC')
}

# ---------------- Machine identity probes (tri-state; $null = unknown) ----------------
$script:BatteryCache = 'unset'
function Get-BatteryPowered {
  <# $true = battery-powered form factor, $false = not, $null = could not determine.
     Ultimate Performance is not exposed on battery-powered systems, so this gates it. #>
  if ($script:BatteryCache -ne 'unset') { return $script:BatteryCache }
  $answered = $false
  $result = $null
  try {
    $b = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
    $answered = $true
    if ($b.Count -gt 0) { $result = $true }
  } catch {}
  if ($null -eq $result) {
    try {
      $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
      $types = @()
      foreach ($e in @(Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop)) { $types += @($e.ChassisTypes) }
      if ($types.Count -gt 0) {
        $answered = $true
        foreach ($t in $types) { if ($portable -contains [int]$t) { $result = $true; break } }
      }
    } catch {}
  }
  if ($null -eq $result -and $answered) { $result = $false }
  $script:BatteryCache = $result
  $result
}

$script:CpuScopeCache = $null
function Get-CpuScope {
  <# CPU identity from locale-invariant sources. HKLM\HARDWARE\...\CentralProcessor\0 carries
     VendorIdentifier ('GenuineIntel') and Identifier ('Intel64 Family 6 Model 183 Stepping 1'),
     both written by the HAL from CPUID — ASCII, never localized. Win32_Processor.Description is
     the same string and is the fallback.
     isDesktopRaptorLake is tri-state: $true / $false (a different CPU) / $null (unknown). #>
  if ($null -ne $script:CpuScopeCache) { return $script:CpuScopeCache }
  $vendor = $null; $ident = $null; $family = $null; $model = $null
  try {
    $k = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
    if ($k.PSObject.Properties.Name -contains 'VendorIdentifier') { $vendor = "$($k.VendorIdentifier)".Trim() }
    if ($k.PSObject.Properties.Name -contains 'Identifier')       { $ident  = "$($k.Identifier)".Trim() }
  } catch {}
  if (-not $ident -or -not $vendor) {
    try {
      $p = @(Get-CimInstance Win32_Processor -ErrorAction Stop) | Select-Object -First 1
      if ($p) {
        if (-not $vendor) { $vendor = "$($p.Manufacturer)".Trim() }
        if (-not $ident)  { $ident  = "$($p.Description)".Trim() }
      }
    } catch {}
  }
  if ($ident -match 'Family\s+(\d+)\s+Model\s+(\d+)') { $family = [int]$Matches[1]; $model = [int]$Matches[2] }

  $isRpl = $null
  if ($vendor -and ($vendor -ne 'GenuineIntel')) {
    $isRpl = $false                                   # AMD / ARM64 / anything else: out of scope
  } elseif ($null -ne $family -and $null -ne $model) {
    # CPUID family 6, model 0xB7 (183) / 0xBF (191) = Raptor Lake S/HX. Model alone cannot tell
    # a desktop S part from a mobile HX part, and their microcode series are unrelated — so the
    # form factor decides, and an unknown form factor stays unknown.
    if ($family -eq 6 -and (@(183, 191) -contains $model)) {
      $bat = Get-BatteryPowered
      if ($bat -eq $true) { $isRpl = $false } elseif ($bat -eq $false) { $isRpl = $true } else { $isRpl = $null }
    } else { $isRpl = $false }
  }
  $script:CpuScopeCache = [pscustomobject]@{
    vendor = $vendor; identifier = $ident; family = $family; model = $model
    isDesktopRaptorLake = $isRpl
  }
  $script:CpuScopeCache
}

function Test-MdmEnrolled {
  <# A REAL MDM/Intune enrollment, not the local placeholder records Windows 11 writes on every
     consumer box. Verified on the dev machine: HKLM\...\PolicyManager\current\device exists and
     HKLM\...\Enrollments holds ~30 EnrollmentState=1 keys on a plain personal PC, so neither is
     usable on its own. A managing server always writes DiscoveryServiceFullURL (or identifies
     itself as 'MS DM Server'); the built-in Local/Deploy/Cloud Authority providers do not. #>
  $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
  try {
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
      if ("$($k.PSChildName)" -notmatch '^[0-9A-Fa-f]{8}-') { continue }
      try {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
        $names = $p.PSObject.Properties.Name
        if (($names -contains 'EnrollmentState') -and ([int]$p.EnrollmentState -ne 1)) { continue }
        if (($names -contains 'DiscoveryServiceFullURL') -and "$($p.DiscoveryServiceFullURL)".Trim()) { return $true }
        if (($names -contains 'ProviderID') -and ("$($p.ProviderID)".Trim() -eq 'MS DM Server')) { return $true }
      } catch {}
    }
  } catch {}
  return $false
}

$script:ManagedCache = $null
function Get-ManagedState {
  <# Is this machine's policy owned by someone else (domain GP or MDM/Intune)? #>
  if ($null -ne $script:ManagedCache) { return $script:ManagedCache }
  $domain = $null
  try { $domain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { $domain = $null }
  $mdm = Test-MdmEnrolled
  $script:ManagedCache = [pscustomobject]@{
    domainJoined = $domain; mdmEnrolled = $mdm; managed = (($domain -eq $true) -or $mdm)
  }
  $script:ManagedCache
}

function Get-OpBlock {
  <# A refusal message when an op must not be written on THIS machine, or $null when it is fine.
     Today the only blocker is the Group Policy hive on a managed machine: the GP engine rewrites
     that key at the next background refresh (90 min + jitter) and the MDM CSP re-applies at the
     next sync, so "Applied" would become a lie without anyone touching anything. #>
  param($op)
  if (-not $op) { return $null }
  if ($op.type -eq 'multi') {
    foreach ($sub in $op.ops) { $b = Get-OpBlock $sub; if ($b) { return $b } }
    return $null
  }
  if ($op.type -ne 'registry') { return $null }
  if ("$($op.path)" -notmatch '(?i)^\\*SOFTWARE\\+(WOW6432Node\\+)?Policies\\+') { return $null }
  $m = Get-ManagedState
  if (-not $m.managed) { return $null }
  $who = 'MDM'
  if ($m.domainJoined -eq $true -and $m.mdmEnrolled) { $who = 'domain policy and MDM' }
  elseif ($m.domainJoined -eq $true) { $who = 'domain policy' }
  return ("This setting lives in the Group Policy hive (HKLM\$($op.path)) and this machine is managed by $who. " +
          'Any value FrameForge writes here will be overwritten at the next policy refresh — ask your administrator to set it instead.')
}

# ---------------- Verify (read-only health) checks ----------------
# TRI-STATE by contract: $true = healthy, $false = positively unhealthy, $null = COULD NOT
# DETERMINE. A check that did not actually run must never fall through to a confident answer in
# either direction — that is doctrine rule 2, and it is the worst bug this codebase can have.
function Test-Verify {
  param([string]$Check)
  switch ($Check) {
    'hags' {
      try {
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop
        if ($k -and ($k.PSObject.Properties.Name -contains 'HwSchMode')) { return ([int]$k.HwSchMode -eq 2) }
        # Value absent: HAGS is not exposed (no WDDM 2.7+ GPU, or the driver never wrote it).
        # That is "unknown", NOT "off".
        Add-DetectNote 'HwSchMode is not present, so hardware-accelerated GPU scheduling could not be read on this GPU/driver.'
        return $null
      } catch {
        Add-DetectNote "Could not read HwSchMode: $($_.Exception.Message)"
        return $null
      }
    }
    'microcode' {
      # Microcode revision numbering is PER-CPUID, not global: a Ryzen revision (~0x0A20120E)
      # sails past 0x125 and would show a green "Raptor Lake microcode OK" on a CPU that has no
      # Raptor Lake microcode at all. Gate on CPUID before comparing anything.
      $scope = Get-CpuScope
      if ($scope.isDesktopRaptorLake -ne $true) {
        if ($null -eq $scope.isDesktopRaptorLake) { Add-DetectNote 'Could not identify this CPU, so the Raptor Lake microcode check was not run.' }
        else { Add-DetectNote 'This check only applies to desktop Intel 13th/14th-gen (Raptor Lake S) CPUs.' }
        return $null
      }
      try {
        $bytes = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
        if (-not $bytes -or $bytes.Length -lt 4) { Add-DetectNote 'Update Revision is missing or too short to decode.'; return $null }
        # Format varies: 8-byte stores the revision in the high dword; 4-byte stores it whole.
        $rev = if ($bytes.Length -ge 8) { [System.BitConverter]::ToUInt32($bytes, 4) } else { [System.BitConverter]::ToUInt32($bytes, 0) }
        if ($rev -eq 0) { $rev = [System.BitConverter]::ToUInt32($bytes, 0) }
        # Fixed Raptor Lake microcodes are 0x125 / 0x129 / 0x12B and up.
        return ($rev -ge 0x125)
      } catch {
        Add-DetectNote "Could not read the microcode revision: $($_.Exception.Message)"
        return $null
      }
    }
    'rss' {
      # Only $true when at least one adapter was actually queried. Zero adapters queried
      # (unelevated refusal, only virtual/USB NICs, nothing up) is $null, not "healthy".
      try {
        $queried = 0; $sawDisabled = $false
        $ads = @()
        try { $ads = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) }
        catch { Add-DetectNote "Could not enumerate network adapters: $($_.Exception.Message)"; return $null }
        foreach ($a in $ads) {
          try {
            $r = Get-NetAdapterRss -Name $a.Name -ErrorAction Stop
            if ($r) { $queried++; if ($r.Enabled -eq $false) { $sawDisabled = $true } }
          } catch {}
        }
        if ($queried -eq 0) {
          Add-DetectNote 'No network adapter could be queried for Receive Side Scaling, so its state is unknown.'
          return $null
        }
        return (-not $sawDisabled)
      } catch {
        Add-DetectNote "Receive Side Scaling could not be checked: $($_.Exception.Message)"
        return $null
      }
    }
    default { Add-DetectNote "Unknown verify check '$Check'."; return $null }
  }
}

function Resolve-Hive { param($Root)
  switch ($Root) {
    'HKLM' { 'HKLM:' } 'HKCU' { 'HKCU:' } 'HKCR' { 'HKCR:' } 'HKU' { 'HKU:' } default { "$Root`:" }
  }
}
function Get-RegState {
  param($RootHive, $Path, $Name)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  $exists = $false; $value = $null; $keyExists = $false; $err = $null
  try { $keyExists = [bool](Test-Path -LiteralPath $full -ErrorAction Stop) } catch { $err = "$($_.Exception.Message)" }
  if ($keyExists) {
    try {
      $item = Get-ItemProperty -LiteralPath $full -ErrorAction Stop
      if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { $exists = $true; $value = $item.$Name }
    } catch { $err = "$($_.Exception.Message)" }
  }
  # 'error' is what separates "the value is not set" from "we could not look".
  [pscustomobject]@{ exists = $exists; value = $value; full = $full; keyExists = $keyExists; error = $err }
}
function Set-RegValue {
  param($RootHive, $Path, $Name, $ValueType, $Value)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  if (-not (Test-Path -LiteralPath $full)) { New-Item -Path $full -Force | Out-Null }
  New-ItemProperty -LiteralPath $full -Name $Name -PropertyType $ValueType -Value $Value -Force | Out-Null
}
function Remove-RegValue {
  param($RootHive, $Path, $Name)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  if (Test-Path -LiteralPath $full) { Remove-ItemProperty -LiteralPath $full -Name $Name -ErrorAction SilentlyContinue }
}

# ---------------- Per-op DETECT ----------------
# TRI-STATE: $true applied, $false not applied, $null COULD NOT DETERMINE.
# Notes explaining a $null (or a partial match) are collected in $script:DetectNotes.
$script:DetectNotes = @()
# Deduplicated: a 'multi' op runs the same profile-scope check once per sub-op, and printing
# the identical sentence three times reads like three separate problems.
function Add-DetectNote { param([string]$Text) if ($Text -and (@($script:DetectNotes) -notcontains $Text)) { $script:DetectNotes += $Text } }

function Get-LedgerSchemeGuid {
  <# The power-scheme GUID recorded when this tweak was applied. A duplicated Ultimate
     Performance scheme gets a NEW guid that is not the catalog template guid, and its NAME is
     localized — so the ledger is the only locale-independent way to recognise it later. #>
  param([string]$TweakId)
  if (-not $TweakId) { return $null }
  try {
    $rec = @(Load-Ledger | Where-Object { $_.id -eq $TweakId }) | Select-Object -First 1
    if ($rec -and $rec.before -and ($rec.before.PSObject.Properties.Name -contains 'schemeGuid') -and $rec.before.schemeGuid) {
      return "$($rec.before.schemeGuid)".ToLower()
    }
  } catch {}
  return $null
}

function Detect-Op {
  param($op, [string]$TweakId)
  switch ($op.type) {
    'registry' {
      # HKCU resolves to the hive of the account this PROCESS runs as. If that is not the
      # account at the keyboard, reading it answers a question nobody asked — and answering
      # "not applied" (or "applied") from the wrong hive is exactly the class of lie doctrine
      # rule 2 forbids. Undetermined is the only honest answer.
      $r = "$($op.root)".Trim().ToUpperInvariant()
      if ($r -eq 'HKCU' -or $r -eq 'HKEY_CURRENT_USER') {
        $id = Get-FFIdentity
        if ($id.profileMismatch -eq $true) {
          $who = $id.interactiveName; if (-not $who) { $who = $id.interactiveSid }
          Add-DetectNote "This is a per-user setting and FrameForge is running as '$($id.tokenName)', not as the signed-in user '$who', so it read a different account's settings and is not reporting them as yours."
          return $null
        }
        if ($null -eq $id.profileMismatch) {
          Add-DetectNote "This is a per-user setting and FrameForge could not confirm which Windows account it is reading for. $($id.reason)"
          return $null
        }
      }
      $s = Get-RegState $op.root $op.path $op.name
      if ($s.error) { Add-DetectNote "Could not read $($s.full) -> $($op.name): $($s.error)"; return $null }
      return ($s.exists -and "$($s.value)" -eq "$($op.value)")
    }
    'multi' {
      # A definite "no" from any sub-op wins; otherwise an undetermined sub-op makes the whole
      # thing undetermined. Never collapse "unknown" into "not applied".
      $anyFalse = $false; $anyUnknown = $false
      foreach ($sub in $op.ops) {
        $r = Detect-Op $sub -TweakId $TweakId
        if ($null -eq $r) { $anyUnknown = $true } elseif (-not $r) { $anyFalse = $true }
      }
      if ($anyFalse) { return $false }
      if ($anyUnknown) { return $null }
      return $true
    }
    'powercfg-scheme' {
      # GUIDs only — the scheme NAME in `powercfg /list` is localized in every language pack.
      $active = Get-ActiveSchemeGuid
      if (-not $active) { Add-DetectNote 'Could not read the active power scheme.'; return $null }
      $targets = @()
      $led = Get-LedgerSchemeGuid $TweakId
      if ($led) { $targets += $led }
      if ($op.guid) { $targets += "$($op.guid)".ToLower() }
      if ($op.batteryGuid) { $targets += "$($op.batteryGuid)".ToLower() }
      $match = ($targets -contains $active)
      if (-not $match) {
        # The active plan may be a DUPLICATE of the catalog plan (its own GUID, a localized name).
        # The MUI resource id in FriendlyName identifies the original, in any language.
        $activeTmpl = Get-SchemeTemplateId $active
        if ($activeTmpl) {
          foreach ($t in $targets) {
            if ((Get-SchemeTemplateId $t) -eq $activeTmpl) { $match = $true; break }
          }
        }
      }
      if (-not $match) { return $false }
      # The plan is active. Also verify the min-processor-state un-pin actually landed.
      if ($null -ne $op.procMinState) {
        $unknown = $false
        foreach ($w in (Get-OpPowerScopes $op 'procMinScope')) {
          $cur = Get-PowerCfgIndex $SUB_PROCESSOR $PROCTHROTTLEMIN $w $active
          if ($null -eq $cur) { $unknown = $true; Add-DetectNote "Could not read the $w minimum processor state for the active plan."; continue }
          if ([int]$cur -ne [int]$op.procMinState) { return $false }
        }
        if ($unknown) { return $null }
      }
      return $true
    }
    'verify' { return (Test-Verify $op.check) }
    'powercfg-setting' {
      $scheme = Get-ActiveSchemeGuid
      if (-not $scheme) { Add-DetectNote 'Could not read the active power scheme.'; return $null }
      $scopes = @(Get-OpPowerScopes $op)
      $unknown = $false; $mismatch = @()
      foreach ($w in $scopes) {
        $cur = Get-PowerCfgIndex $op.subgroup $op.setting $w $scheme
        if ($null -eq $cur) { $unknown = $true; Add-DetectNote "Could not read the $w power setting index."; continue }
        if ([int]$cur -ne [int]$op.value) { $mismatch += $w }
      }
      # Informational: say plainly when the tweak is scoped to AC and battery is left alone,
      # so the UI never implies a laptop's battery behaviour changed (or did not).
      if ($scopes -notcontains 'DC') {
        $dc = Get-PowerCfgIndex $op.subgroup $op.setting 'DC' $scheme
        if ($null -ne $dc -and [int]$dc -ne [int]$op.value) {
          Add-DetectNote 'Applies on AC power only; the battery (DC) value is unchanged by design.'
        }
      }
      if ($mismatch.Count -gt 0) { Add-DetectNote ("Not applied on: " + ($mismatch -join ', ') + '.'); return $false }
      if ($unknown) { return $null }
      return $true
    }
    'service' {
      $svc = $null
      try { $svc = @(Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction Stop) | Select-Object -First 1 }
      catch { Add-DetectNote "Could not query service '$($op.name)': $($_.Exception.Message)"; return $null }
      if (-not $svc) { return $true } # absent service = effectively disabled
      $want = $op.startup
      $mode = $svc.StartMode  # Auto / Manual / Disabled
      $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Automatic'='Auto' }
      return ($mode -eq $map[$want])
    }
    'advise' { return $false }
    default { Add-DetectNote "Unknown op type '$($op.type)'."; return $null }
  }
}

function Test-OpSupported {
  param($op)
  switch ($op.type) {
    'service' {
      try { return [bool](@(Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction Stop).Count -gt 0) } catch { return $false }
    }
    'verify' {
      # A check that cannot apply to this hardware is UNSUPPORTED, so the UI hides it and the
      # score excludes it — rather than scoring a green tick that was never measured.
      if ($op.check -eq 'microcode') { return ((Get-CpuScope).isDesktopRaptorLake -eq $true) }
      return $true
    }
    'registry' { return (-not (Get-OpBlock $op)) }
    'multi' {
      foreach ($sub in $op.ops) { if (-not (Test-OpSupported $sub)) { return $false } }
      return $true
    }
    default   { return $true }
  }
}

function Get-UnsupportedReason {
  param($op)
  $b = Get-OpBlock $op
  if ($b) { return $b }
  if ($op.type -eq 'verify' -and $op.check -eq 'microcode') {
    $s = Get-CpuScope
    if ($s.isDesktopRaptorLake -eq $false) { return 'This check only applies to desktop Intel 13th/14th-gen (Raptor Lake S) CPUs; yours is a different CPU.' }
    if ($null -eq $s.isDesktopRaptorLake) { return 'FrameForge could not identify this CPU, so it will not claim anything about its microcode.' }
  }
  if ($op.type -eq 'service') { return "The '$($op.name)' service does not exist on this machine." }
  return $null
}

# ---------------- Per-op APPLY (returns a 'before' backup blob) ----------------
function Apply-Op {
  param($op, [switch]$DryRun)
  switch ($op.type) {
    'registry' {
      $s = Get-RegState $op.root $op.path $op.name
      $before = @{ kind='registry'; root=$op.root; path=$op.path; name=$op.name; valueType=$op.valueType; existed=$s.exists; value=$s.value }
      if (-not $DryRun) { Set-RegValue $op.root $op.path $op.name $op.valueType $op.value }
      return $before
    }
    'multi' {
      # Collect every sub-backup even when a later sub-op fails: the ledger must still hold the
      # prior state of whatever DID change, or that part becomes un-undoable (doctrine rule 3).
      $backs = @(); $err = $null
      foreach ($sub in $op.ops) {
        try { $backs += (Apply-Op $sub -DryRun:$DryRun) }
        catch { $err = "$($_.Exception.Message)"; break }
      }
      $res = @{ kind='multi'; ops=$backs }
      if ($err) { $res.error = $err }
      return $res
    }
    'powercfg-scheme' {
      # GUIDs end to end. `powercfg /list` prints LOCALIZED scheme names, so the old name-match
      # duplicated a new plan on every apply on non-English Windows and then activated the
      # built-in TEMPLATE guid, which is not an installed scheme — silently doing nothing.
      $prevGuid = Get-ActiveSchemeGuid
      $battery  = Get-BatteryPowered
      $template = "$($op.guid)".ToLower()
      $usedAlt  = $false
      # Microsoft does not expose Ultimate Performance on battery-powered systems, so
      # -duplicatescheme fails there. Fall back to the built-in plan named by the catalog.
      if ($battery -eq $true -and $op.batteryGuid) { $template = "$($op.batteryGuid)".ToLower(); $usedAlt = $true }
      $before = [ordered]@{
        kind='powercfg-scheme'; prevGuid=$prevGuid; schemeGuid=$null; batteryAlternative=$usedAlt
        createdScheme=$false; procMinAc=$null; procMinDc=$null; procMinCaptured=$false; warnings=@()
      }
      if ($DryRun) { $before.schemeGuid = $template; return $before }
      if (-not $prevGuid) { throw 'Could not read the currently active power plan, so it cannot be captured for undo. Refusing to change the power plan.' }

      $installedBefore = Get-InstalledSchemeGuids
      # Reuse an existing copy of this plan (the template itself, or an earlier duplicate
      # recognised by its locale-invariant MUI id) instead of piling up a new one every apply.
      $useGuid = Find-SchemeByTemplate $template
      if (-not $useGuid) {
        $dup = Invoke-PowerCfg @('-duplicatescheme', $template)
        if (-not $dup.ok) {
          # One explicit degrade: the catalog's battery-safe built-in plan, if it is installed.
          $alt = $null
          if ($op.batteryGuid -and -not $usedAlt) { $alt = "$($op.batteryGuid)".ToLower() }
          $inst2 = Get-InstalledSchemeGuids
          if ($alt -and $inst2 -and ($inst2 -contains $alt)) {
            $useGuid = $alt; $usedAlt = $true; $before.batteryAlternative = $true
            $before.warnings += "This system does not offer the Ultimate Performance plan (powercfg exit $($dup.exit)); FrameForge activated the built-in High Performance plan instead."
          } else {
            throw "powercfg -duplicatescheme $template failed (exit $($dup.exit)): $($dup.output)"
          }
        } else {
          # GUIDs are never localized, so reading one out of powercfg's output is safe.
          if ($dup.output -match $GuidPattern) { $useGuid = $Matches[1].ToLower() }
          if (-not $useGuid) {
            $installedAfter = Get-InstalledSchemeGuids
            if ($installedAfter -and $installedBefore) {
              $new = @($installedAfter | Where-Object { $installedBefore -notcontains $_ })
              if ($new.Count -eq 1) { $useGuid = $new[0] }
            }
          }
          if (-not $useGuid) { throw 'powercfg reported that it duplicated the power plan but FrameForge could not identify the new plan GUID, so it will not activate anything.' }
          $before.createdScheme = $true
        }
      }
      $before.schemeGuid = $useGuid
      # Capture the TARGET plan's prior min-processor-state so revert restores real prior state
      # (doctrine rule 3), not an assumed default.
      if ($null -ne $op.procMinState) {
        $before.procMinAc = Get-PowerCfgIndex $SUB_PROCESSOR $PROCTHROTTLEMIN 'AC' $useGuid
        $before.procMinDc = Get-PowerCfgIndex $SUB_PROCESSOR $PROCTHROTTLEMIN 'DC' $useGuid
        $before.procMinCaptured = (($null -ne $before.procMinAc) -or ($null -ne $before.procMinDc))
        if (-not $before.procMinCaptured) { $before.warnings += 'The plan''s prior minimum processor state could not be read, so revert cannot restore it.' }
      }
      $act = Invoke-PowerCfg @('/setactive', $useGuid)
      if (-not $act.ok) { throw "powercfg /setactive $useGuid failed (exit $($act.exit)): $($act.output)" }
      # Past this point the machine HAS changed, so failures are recorded (and caught by the
      # verify-after in Do-Apply) instead of thrown — a throw here would lose the undo record.
      if ($null -ne $op.procMinState) {
        # Critically: do NOT pin minimum processor state at 100% on Raptor Lake. Un-pin it.
        foreach ($w in (Get-OpPowerScopes $op 'procMinScope')) {
          $e = Set-PowerCfgIndex $useGuid $SUB_PROCESSOR $PROCTHROTTLEMIN $w $op.procMinState
          if ($e) { $before.warnings += $e }
        }
        $re = Invoke-PowerCfg @('/setactive', $useGuid)
        if (-not $re.ok) { $before.warnings += "powercfg /setactive (re-apply) exit $($re.exit): $($re.output)" }
      }
      return $before
    }
    'verify' { return @{ kind = 'verify'; check = $op.check } }
    'powercfg-setting' {
      $guid = Get-ActiveSchemeGuid
      if (-not $guid) { throw 'Could not read the active power plan, so the prior power setting cannot be captured for undo. Refusing to change it.' }
      $scopes = @(Get-OpPowerScopes $op)
      $before = [ordered]@{
        kind='powercfg-setting'; guid=$guid; subgroup=$op.subgroup; setting=$op.setting
        scopes=$scopes; warnings=@()
        ac = (Get-PowerCfgIndex $op.subgroup $op.setting 'AC' $guid)
        dc = (Get-PowerCfgIndex $op.subgroup $op.setting 'DC' $guid)
      }
      # Honest about an unreadable prior value: revert must say it cannot restore rather than
      # removing the ledger entry and reporting success over a no-op undo.
      foreach ($w in $scopes) {
        $prior = $before.ac; if ($w -eq 'DC') { $prior = $before.dc }
        if ($null -eq $prior) { $before.warnings += "The prior $w value could not be read, so FrameForge will not be able to restore it." }
      }
      if (-not $DryRun) {
        $wrote = 0
        foreach ($w in $scopes) {
          $e = Set-PowerCfgIndex $guid $op.subgroup $op.setting $w $op.value
          if ($e) { $before.warnings += $e } else { $wrote++ }
        }
        # Nothing at all landed -> nothing to undo, so fail loudly and write no ledger entry.
        if ($wrote -eq 0) { throw ("powercfg refused every write for this setting. " + (@($before.warnings) -join ' ')) }
        $act = Invoke-PowerCfg @('/setactive', $guid)
        if (-not $act.ok) { $before.warnings += "powercfg /setactive $guid exit $($act.exit): $($act.output)" }
      }
      return $before
    }
    'service' {
      $svc = Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction SilentlyContinue
      $before = @{ kind='service'; name=$op.name; startup=($svc.StartMode); state=($svc.State) }
      if (-not $DryRun -and $svc) {
        $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Automatic'='Automatic' }
        Set-Service -Name $op.name -StartupType $map[$op.startup] -ErrorAction SilentlyContinue
        if ($op.state -eq 'Stopped') { Stop-Service -Name $op.name -Force -ErrorAction SilentlyContinue }
        elseif ($op.state -eq 'Running') { Start-Service -Name $op.name -ErrorAction SilentlyContinue }
      }
      return $before
    }
    'advise' { return @{ kind='advise' } }
    default { throw "Unknown op type: $($op.type)" }
  }
}

# ---------------- Per-op REVERT (consumes the 'before' backup blob) ----------------
# Returns an ARRAY of problem strings — empty means the undo really happened. A revert that
# could not restore captured prior state must SAY SO; silently skipping and reporting success
# (while deleting the ledger entry) is an unrecoverable fake undo.
function Revert-Op {
  param($before, [switch]$DryRun)
  $problems = @()
  switch ("$($before.kind)") {
    'registry' {
      if (-not $DryRun) {
        try {
          if ($before.existed) { Set-RegValue $before.root $before.path $before.name $before.valueType $before.value }
          else { Remove-RegValue $before.root $before.path $before.name }
        } catch { $problems += "Could not restore $($before.root)\$($before.path) -> $($before.name): $($_.Exception.Message)" }
      }
    }
    'multi' { foreach ($b in $before.ops) { $problems += @(Revert-Op $b -DryRun:$DryRun) } }
    'powercfg-setting' {
      if (-not $before.guid) { $problems += 'The power plan this setting belonged to was not recorded, so it cannot be restored.'; break }
      $scopes = @('AC')
      if ($before.PSObject.Properties.Name -contains 'scopes' -and $before.scopes) { $scopes = @($before.scopes) }
      elseif ($null -ne $before.dc) { $scopes = @('AC', 'DC') }   # v0.1 records wrote both
      foreach ($w in $scopes) {
        $prior = $before.ac
        if ($w -eq 'DC') { $prior = $before.dc }
        if ($null -eq $prior) {
          $problems += "The $w value in force before this tweak was never readable, so FrameForge cannot restore it — set it by hand in Power Options."
          continue
        }
        if (-not $DryRun) {
          $e = Set-PowerCfgIndex $before.guid $before.subgroup $before.setting $w $prior
          if ($e) { $problems += "Could not restore the $w value: $e" }
        }
      }
      if (-not $DryRun) {
        $act = Invoke-PowerCfg @('/setactive', "$($before.guid)")
        if (-not $act.ok) { $problems += "powercfg /setactive exit $($act.exit): $($act.output)" }
      }
    }
    'powercfg-scheme' {
      if (-not $DryRun -and $before.schemeGuid -and $before.procMinCaptured) {
        foreach ($w in @('AC', 'DC')) {
          $prior = $before.procMinAc
          if ($w -eq 'DC') { $prior = $before.procMinDc }
          if ($null -eq $prior) { continue }
          $e = Set-PowerCfgIndex $before.schemeGuid $SUB_PROCESSOR $PROCTHROTTLEMIN $w $prior
          if ($e) { $problems += "Could not restore the $w minimum processor state: $e" }
        }
      }
      if (-not $before.prevGuid) {
        $problems += 'The power plan that was active before this tweak was not recorded, so FrameForge cannot switch back to it — pick your plan in Power Options.'
      } elseif (-not $DryRun) {
        $act = Invoke-PowerCfg @('/setactive', "$($before.prevGuid)")
        if (-not $act.ok) { $problems += "Could not switch back to the previous power plan (powercfg exit $($act.exit)): $($act.output)" }
      }
    }
    'service' {
      if (-not $before.startup) { $problems += "The prior start type of service '$($before.name)' was not recorded, so it cannot be restored."; break }
      if (-not $DryRun) {
        $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Auto'='Automatic'; 'Automatic'='Automatic' }
        $st = $map["$($before.startup)"]
        if (-not $st) { $problems += "Unrecognised prior start type '$($before.startup)' for '$($before.name)'." }
        else {
          try { Set-Service -Name $before.name -StartupType $st -ErrorAction Stop }
          catch { $problems += "Could not restore the start type of '$($before.name)': $($_.Exception.Message)" }
        }
        if ($before.state -eq 'Running') { Start-Service -Name $before.name -ErrorAction SilentlyContinue }
        elseif ($before.state -eq 'Stopped') { Stop-Service -Name $before.name -Force -ErrorAction SilentlyContinue }
      }
    }
    'verify' { }
    'advise' { }
    default  { $problems += "Nothing is known about how to undo a '$($before.kind)' change." }
  }
  return @($problems)
}

# ---------------- High-level actions ----------------
function Get-BackupWarnings {
  <# Non-fatal problems recorded while applying (a powercfg write that was refused, a plan the
     system does not offer). Works on both a live [ordered] backup and one round-tripped through
     the ledger as a PSCustomObject. #>
  param($b)
  $out = @()
  if (-not $b) { return @() }
  $get = {
    param($obj, $name)
    if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($name)) { return $obj[$name] }; return $null }
    if ($obj -and $obj.PSObject -and ($obj.PSObject.Properties.Name -contains $name)) { return $obj.$name }
    return $null
  }
  $w = & $get $b 'warnings'
  if ($w) { $out += @($w) }
  $kind = & $get $b 'kind'
  if ("$kind" -eq 'multi') {
    foreach ($sub in @(& $get $b 'ops')) { $out += @(Get-BackupWarnings $sub) }
  }
  $err = & $get $b 'error'
  if ($err) { $out += @("$err") }
  @($out)
}

function Do-Detect {
  param($tweak)
  $script:DetectNotes = @()
  $supported = $true
  try { $supported = [bool](Test-OpSupported $tweak.op) } catch { $supported = $false }
  $reason = $null
  if (-not $supported) { $reason = Get-UnsupportedReason $tweak.op }
  $applied = $false; $determined = $true
  try {
    $r = Detect-Op $tweak.op -TweakId $tweak.id
    if ($null -eq $r) { $determined = $false } else { $applied = [bool]$r }
  } catch { $determined = $false; Add-DetectNote "$($_.Exception.Message)" }
  # 'applied' stays a boolean for the renderer; 'determined' is the new, additive third state.
  # applied=$false with determined=$false means "could not determine", NOT "not applied".
  # Additive: whether this tweak writes the CURRENT USER's registry, and whether that user is
  # the one at the keyboard. The renderer needs both to explain a refusal it did not cause.
  $userPaths = @(Get-FFUserScopedPaths $tweak.op)
  $ffId = Get-FFIdentity
  [ordered]@{
    id=$tweak.id; applied=$applied; determined=$determined; supported=$supported
    requiresAdmin=$tweak.requiresAdmin; unsupportedReason=$reason; notes=@($script:DetectNotes)
    perUser=($userPaths.Count -gt 0); profileMismatch=$ffId.profileMismatch
  }
}

function Do-Apply {
  param($tweak, [switch]$DryRun)
  if ($tweak.op.type -eq 'advise' -or $tweak.op.type -eq 'verify') {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$true; advisory=$true; message=$tweak.summary }
  }
  $block = Get-OpBlock $tweak.op
  if ($block) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; blocked=$true; managed=$true; determined=$true; message=$block }
  }
  if ($tweak.requiresAdmin -and -not $IsAdmin -and -not $DryRun) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; needsElevation=$true; message='This tweak requires administrator rights.' }
  }
  # Per-user scope gate. A DryRun is refused too: a dry run that says "this would be applied"
  # about the wrong profile is still a false statement about this PC.
  $scopeRefusal = Get-FFProfileScopeRefusal $tweak.op
  if ($scopeRefusal) {
    $ident = Get-FFIdentity
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; blocked=$true; determined=$true
                       errorCode='profile-scope'; wrongProfile=($ident.profileMismatch -eq $true)
                       profileMismatch=$ident.profileMismatch; runningAs=$ident.tokenName
                       signedInUser=$ident.interactiveName; message=$scopeRefusal }
  }
  $before = $null
  try { $before = Apply-Op $tweak.op -DryRun:$DryRun }
  catch {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; dryRun=[bool]$DryRun; verified=$false
                       message="Could not apply '$($tweak.name)': $($_.Exception.Message)" }
  }
  if ($DryRun) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$true; dryRun=$true; verified=$false
                       requiresReboot=$tweak.requiresReboot; message="Dry run: '$($tweak.name)' was NOT changed." }
  }
  # Ledger FIRST — the machine has already changed, so the undo record must exist even when the
  # verify below says the change did not take. The record carries the SID that wrote it, so a
  # later undo run by a different account can refuse instead of restoring into the wrong hive.
  $ffId = Get-FFIdentity
  Upsert-Ledger ([ordered]@{ id=$tweak.id; name=$tweak.name; appliedAt=(Get-Date).ToString('s')
                             userSid=$ffId.tokenSid; userName=$ffId.tokenName
                             before=$before; reverted=$false })

  # Doctrine rule 1: verify AFTER, with the same read-only probe detect uses. Do-Apply used to
  # return success=$true unconditionally, so a change that never landed was reported as applied.
  $script:DetectNotes = @()
  $warnings = @(Get-BackupWarnings $before)
  $powerWarn = Get-FFPowerScopeWarning $tweak.op
  if ($powerWarn) { $warnings += $powerWarn }
  $v = $null
  try { $v = Detect-Op $tweak.op -TweakId $tweak.id } catch { $v = $null; Add-DetectNote "$($_.Exception.Message)" }
  $tail = ''
  if ($warnings.Count -gt 0) { $tail = ' ' + ($warnings -join ' ') }
  if ($v -eq $true) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$true; dryRun=$false; verified=$true; determined=$true
                       requiresReboot=$tweak.requiresReboot; notes=@($script:DetectNotes)
                       message="Applied '$($tweak.name)'.$tail" }
  }
  if ($v -eq $false) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; dryRun=$false; verified=$false; determined=$true
                       requiresReboot=$tweak.requiresReboot; notes=@($script:DetectNotes)
                       message="Applied '$($tweak.name)' but verification says the value did not take — it may be managed or overridden elsewhere. The undo record was kept.$tail" }
  }
  [ordered]@{ id=$tweak.id; action='apply'; success=$true; dryRun=$false; verified=$false; determined=$false
              requiresReboot=$tweak.requiresReboot; notes=@($script:DetectNotes)
              message="Applied '$($tweak.name)', but FrameForge could not verify the result on this system, so it is not claiming the change took effect.$tail" }
}

function Do-Revert {
  param($tweak, [switch]$DryRun)
  $rec = Load-Ledger | Where-Object { $_.id -eq $tweak.id -and -not $_.reverted } | Select-Object -First 1
  $ffId = Get-FFIdentity
  if (-not $rec) {
    # No recorded backup. On a same-account run that genuinely means "nothing to undo". Under a
    # mismatched or unproven token it means "this account's ledger is empty", which is NOT the
    # same statement — the gamer's ledger lives in their own %LOCALAPPDATA% and we cannot see
    # it. Saying "reverted" here is the fake undo doctrine rule 3 exists to prevent.
    if ($ffId.profileMismatch -ne $false) {
      $who = $ffId.interactiveName; if (-not $who) { $who = $ffId.interactiveSid }
      $tail = "FrameForge could not confirm which account's undo history it is reading. $($ffId.reason)"
      if ($ffId.profileMismatch -eq $true) {
        $tail = "FrameForge is running as '$($ffId.tokenName)', so this is that account's undo history, not the one belonging to '$who'."
      }
      return [ordered]@{ id=$tweak.id; action='revert'; success=$false; noop=$true; determined=$false
                         errorCode='profile-scope'; profileMismatch=$ffId.profileMismatch
                         ledgerPath=$ffId.ledgerPath
                         message=("Nothing was undone. $tail Start FrameForge without ""Run as administrator"" to undo per-user tweaks.") }
    }
    return [ordered]@{ id=$tweak.id; action='revert'; success=$true; noop=$true; message='No applied change on record to revert.' }
  }
  if ($tweak.requiresAdmin -and -not $IsAdmin -and -not $DryRun) {
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; needsElevation=$true; message='Reverting this tweak requires administrator rights.' }
  }
  # Same gate as apply: an undo writes to HKCU exactly like an apply does.
  $scopeRefusal = Get-FFProfileScopeRefusal $tweak.op
  if ($scopeRefusal) {
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; blocked=$true; determined=$true
                       errorCode='profile-scope'; profileMismatch=$ffId.profileMismatch
                       runningAs=$ffId.tokenName; signedInUser=$ffId.interactiveName
                       message=$scopeRefusal }
  }
  # A record written by another account holds THAT account's prior values. Restoring them here
  # would write one profile's history into another's (doctrine rule 3: undo restores captured
  # prior state — the state captured for THIS account, not somebody else's).
  if (@(Get-FFLedgerForeign @($rec)).Count -gt 0) {
    $owner = $null
    try { if ($rec.PSObject.Properties.Name -contains 'userName') { $owner = "$($rec.userName)" } } catch {}
    if (-not $owner) { try { if ($rec.PSObject.Properties.Name -contains 'userSid') { $owner = "$($rec.userSid)" } } catch {} }
    if (-not $owner) { $owner = 'an account FrameForge cannot identify' }
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; determined=$true
                       errorCode='foreign-ledger-record'; profileMismatch=$ffId.profileMismatch
                       message=("This undo record was written by $owner, not by '$($ffId.tokenName)'. Restoring it from here would write another account's old values, so FrameForge did not touch anything. The undo record was kept.") }
  }
  $problems = @()
  try { $problems = @(Revert-Op $rec.before -DryRun:$DryRun) }
  catch { $problems = @("$($_.Exception.Message)") }
  if ($DryRun) {
    return [ordered]@{ id=$tweak.id; action='revert'; success=($problems.Count -eq 0); dryRun=$true
                       requiresReboot=$tweak.requiresReboot; problems=$problems
                       message="Dry run: '$($tweak.name)' was NOT changed." }
  }
  if ($problems.Count -gt 0) {
    # The ledger entry STAYS so the user can retry; reporting success here would be the fake
    # undo doctrine rule 3 exists to prevent.
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; dryRun=$false; verified=$false
                       requiresReboot=$tweak.requiresReboot; problems=$problems
                       message=("Could not fully undo '$($tweak.name)': " + ($problems -join ' ') + ' The undo record was kept.') }
  }
  # Verify-after with the same probe: if it still reads as applied, say so instead of claiming success.
  $script:DetectNotes = @()
  $v = $null
  try { $v = Detect-Op $tweak.op -TweakId $tweak.id } catch { $v = $null }
  if ($v -eq $true) {
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; verified=$false; determined=$true
                       requiresReboot=$tweak.requiresReboot; notes=@($script:DetectNotes)
                       message="Undo ran but '$($tweak.name)' still reads as applied. The undo record was kept." }
  }
  Remove-FromLedger $tweak.id
  [ordered]@{ id=$tweak.id; action='revert'; success=$true; dryRun=$false; verified=($v -eq $false); determined=($null -ne $v)
              requiresReboot=$tweak.requiresReboot; notes=@($script:DetectNotes)
              message="Reverted '$($tweak.name)'." }
}

$SystemRestoreKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

function Get-SystemRestoreBlock {
  <# Distinguishes "System Protection is off" (FrameForge can turn it on) from "System Restore
     is disabled by administrator policy" (it cannot) and from "the VSS service is disabled".
     Returns a message or $null. #>
  $policy = $null
  foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')) {
    try {
      $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
      if ($p.PSObject.Properties.Name -contains 'DisableSR' -and [int]$p.DisableSR -eq 1) {
        $policy = 'System Restore is disabled by administrator policy (DisableSR=1), so FrameForge cannot create a checkpoint. Ask your administrator.'
      }
    } catch {}
  }
  if ($policy) { return $policy }
  try {
    $vss = @(Get-CimInstance Win32_Service -Filter "Name='VSS'" -ErrorAction Stop) | Select-Object -First 1
    if ($vss -and $vss.StartMode -eq 'Disabled') {
      return 'The Volume Shadow Copy service (VSS) is disabled, so no restore point can be created. Set VSS to Manual and retry.'
    }
  } catch {}
  return $null
}

function Do-RestorePoint {
  <# The v0.1 version wrote SystemRestorePointCreationFrequency=0 and walked away, permanently
     making Windows checkpoint on EVERY qualifying event — the "leaves changes behind, captures
     nothing" behaviour repair.ps1 criticises. This is the corrected pattern ported from
     repair.ps1's Get-RestorePointStep: capture the prior value (or its absence), do the work in
     try/catch/finally, and put the throttle back either way, reporting a failed restore loudly. #>
  param($Description)
  if (-not $IsAdmin) { return [ordered]@{ action='restore-point'; success=$false; needsElevation=$true; message='Creating a restore point requires administrator rights.' } }

  $blocked = Get-SystemRestoreBlock
  if ($blocked) { return [ordered]@{ action='restore-point'; success=$false; blocked=$true; message=$blocked } }

  $srKey = $SystemRestoreKey
  $priorFreq = $null; $priorFreqPresent = $false
  try {
    $priorFreq = (Get-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop).SystemRestorePointCreationFrequency
    $priorFreqPresent = $true
  } catch {}

  $protectionEnabled = $false; $enableError = $null
  try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; $protectionEnabled = $true }
  catch { $enableError = "$($_.Exception.Message)" }

  $throttleBypassed = $false
  try {
    New-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    $throttleBypassed = $true
  } catch {}

  $checkpointError = $null
  $restoreOk = $true
  $restoreNote = 'the 24h throttle bypass was not applied, so there was nothing to put back'
  try {
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
  } catch {
    $checkpointError = "$($_.Exception.Message)"
  } finally {
    # GUARANTEED revert of the temporary throttle bypass — runs whether the checkpoint worked or not.
    if ($throttleBypassed) {
      try {
        if ($priorFreqPresent) {
          Set-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value ([int]$priorFreq) -Type DWord -ErrorAction Stop
          $restoreNote = "the 24h System Restore throttle was put back to its captured prior value ($priorFreq)"
        } else {
          Remove-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Force -ErrorAction Stop
          $restoreNote = 'the 24h System Restore throttle was put back by DELETING SystemRestorePointCreationFrequency, which did not exist before'
        }
      } catch {
        $restoreOk = $false
        $restoreNote = "FAILED to put the 24h System Restore throttle back ($($_.Exception.Message)) — SystemRestorePointCreationFrequency is still 0 on this machine. Fix it by hand under $srKey"
      }
    }
  }

  if ($checkpointError) {
    $why = 'System Protection is probably off for ' + $env:SystemDrive + ' (FrameForge can enable it in SystemPropertiesProtection.exe).'
    if ($enableError) { $why = "System Protection could not be enabled for $env:SystemDrive ($enableError)." }
    return [ordered]@{
      action='restore-point'; success=$false; throttleRestored=$restoreOk
      message="Could not create a restore point: $checkpointError $why Nothing else was left behind: $restoreNote."
    }
  }
  $tail = " Nothing else was left behind: $restoreNote."
  if (-not $restoreOk) { $tail = " WARNING — $restoreNote." }
  [ordered]@{
    action='restore-point'; success=$true; protectionEnabled=$protectionEnabled
    throttleRestored=$restoreOk; message="System restore point created.$tail"
  }
}

# ---------------- Dispatch ----------------
function Get-TweakOrThrow { param($TweakId)
  $t = Get-Tweak $TweakId
  if (-not $t) { throw "Unknown tweak id '$TweakId'." }
  $t
}

# The single source of truth for what -Action accepts. Kept next to the dispatch so the two
# cannot drift; the header's usage block lists the same set.
$ValidActions = @('detect','apply','revert','detect-all','revert-all','restore-point','list','identity')

try {
  if ($ValidActions -notcontains $Action) {
    # One JSON document, always — even for input the host should never have sent.
    Write-FFOut ([ordered]@{
      action = $Action; ok = $false; success = $false; determined = $false
      errorCode = 'unknown-action'
      error = "Unknown action '$Action'."
      message = "Unknown action '$Action'. FrameForge did not run anything."
      validActions = $ValidActions
    })
    exit 2
  }
  $out = switch ($Action) {
    'list'        { ,(@(Load-Tweaks)) }
    'detect-all'  { ,(@(foreach ($t in (Load-Tweaks)) { Do-Detect $t })) }
    'detect'      { Do-Detect (Get-TweakOrThrow $Id) }
    'apply'       { Do-Apply  (Get-TweakOrThrow $Id) -DryRun:$DryRun }
    'revert'      { Do-Revert (Get-TweakOrThrow $Id) -DryRun:$DryRun }
    'revert-all'  {
      $ffId = Get-FFIdentity
      $pending = @(Load-Ledger | Where-Object { -not $_.reverted })
      $results = @()
      foreach ($rec in $pending) {
        $t = Get-Tweak $rec.id
        if ($t) { $results += (Do-Revert $t -DryRun:$DryRun) }
      }
      $res = [ordered]@{
        action='revert-all'; count=$results.Count
        success=(@($results | Where-Object { -not $_.success }).Count -eq 0)
        determined=$true; results=$results
        profileMismatch=$ffId.profileMismatch; runningAs=$ffId.tokenName
        signedInUser=$ffId.interactiveName; ledgerPath=$ffId.ledgerPath
      }
      # THE BUG THIS EXISTS TO STOP: under a mismatched (or unproven) token the ledger read
      # above is a DIFFERENT account's ledger — usually empty — so the loop did nothing and the
      # old code reported count=0, success=true. "Everything is undone" is then a statement
      # about a profile FrameForge never touched. It is not allowed to make it.
      if ($ffId.profileMismatch -ne $false) {
        $who = $ffId.interactiveName; if (-not $who) { $who = $ffId.interactiveSid }
        $res.success = $false
        $res.determined = $false
        $res.errorCode = 'profile-scope'
        if ($ffId.profileMismatch -eq $true) {
          $res.message = ("FrameForge is running as '$($ffId.tokenName)', not as the signed-in user '$who', so it can only see that account's undo history " +
                          "($($ffId.ledgerPath)). It is NOT claiming your tweaks were undone. Close this window, start FrameForge without ""Run as administrator"" and revert from there.")
        } else {
          $res.message = ("FrameForge could not confirm which Windows account's undo history it just read ($($ffId.reason)), so it is not claiming that everything was undone. " +
                          'Start FrameForge without "Run as administrator" and revert from there.')
        }
      }
      $res
    }
    'identity'    { Get-FFIdentity }
    'restore-point' { Do-RestorePoint $Description }
  }
  # -InputObject (not the pipeline) so a single-element array stays a JSON array — the PS 5.1
  # ConvertTo-Json unrolling pitfall the renderer would choke on.
  Write-FFOut $out
} catch {
  Write-FFOut ([ordered]@{ action=$Action; id=$Id; success=$false; ok=$false; determined=$false
                           message="$($_.Exception.Message)" })
}
