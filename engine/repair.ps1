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
  data/state/repairs-ledger.json, so a mid-repair failure reports exactly which step
  failed and what had already changed. Cache-clearing repairs rename to .bak-<timestamp>
  or move files to data/state/backups/ instead of deleting (manual recovery stays
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

. (Join-Path $PSScriptRoot '_lib.ps1')
$IsAdmin = Test-Admin

$Root            = Split-Path -Parent $PSScriptRoot
$CatalogPath     = Join-Path $Root 'data\repairs.json'
$HealthCatalog   = Join-Path $Root 'data\health-checks.json'
$StateDir        = Join-Path $Root 'data\state'
$BackupDir       = Join-Path $StateDir 'backups'
$LedgerPath      = Join-Path $StateDir 'repairs-ledger.json'
$HealthPath      = Join-Path $PSScriptRoot 'health.ps1'

# DNS resolvers offered by dns-change-resolver (WinUtil's config/dns.json provider set).
# 'dhcp' is the escape hatch back to automatic/DHCP-provided servers.
$DnsProviders = [ordered]@{
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
$DefaultDnsProviderKey = 'cloudflare'

# Optional Windows features FrameForge treats as REPAIRS (an application refuses to start
# without them) rather than as capability additions. See optionalFeaturesNote in
# data/repairs.json for what is deliberately not offered and why.
$OptionalFeatureRepairs = @('enable-netfx3','enable-netfx4-advsrvs','enable-directplay')

# ---------------- catalog ----------------

function Load-Catalog {
  if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "repairs.json not found at $CatalogPath" }
  # -Encoding UTF8 is load-bearing: repairs.json has no BOM, and PS 5.1 would
  # otherwise decode it as Windows-1252 and mangle every em-dash in user-facing copy.
  (Get-Content -Raw -Encoding UTF8 -Path $CatalogPath | ConvertFrom-Json).repairs
}
function Get-RepairById { param($RepairId) @(Load-Catalog) | Where-Object { $_.id -eq $RepairId } | Select-Object -First 1 }

# ---------------- ledger (state-capture journal, style of v0.1 applied.json) ----------------

function Load-RepairLedger {
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return @() }
  $parsed = $null
  try { $parsed = Get-Content -Raw -Encoding UTF8 -Path $LedgerPath | ConvertFrom-Json } catch { return @() }
  if ($null -eq $parsed) { return @() }
  return @($parsed)
}
function Save-RepairLedger {
  param($Entries)
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  $arr = @($Entries)
  if ($arr.Count -eq 0) { Set-Content -Path $LedgerPath -Value '[]' -Encoding UTF8; return }
  # Serialize each entry independently and join — deterministic JSON array regardless of
  # PS 5.1 single-element ConvertTo-Json quirks (same pattern as engine.ps1's ledger).
  $items = foreach ($r in $arr) { ConvertTo-Json -InputObject $r -Depth 14 }
  Set-Content -Path $LedgerPath -Value ("[`r`n" + (($items) -join ",`r`n") + "`r`n]") -Encoding UTF8
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
  # Local read-only detection: health.ps1 has no time category. W32Time service state
  # plus the last-successful-sync timestamp from w32tm /query /status.
  $det = [ordered]@{ method='local'; category='time'; categoryStatus=$null; state='indeterminate'; reason=$null; detail=''; relevantFindings=@() }
  $svc = $null
  try { $svc = Get-Service -Name 'w32time' -ErrorAction Stop } catch {}
  if ($null -eq $svc) {
    $det.reason = 'not-applicable'
    $det.detail = 'The Windows Time service (w32time) is not present on this system.'
    return $det
  }
  if ("$($svc.Status)" -ne 'Running') {
    $det.state = 'problem'
    $det.detail = "The Windows Time service is $($svc.Status) — the clock cannot synchronize."
    $det.relevantFindings = @([ordered]@{ id='w32time-not-running'; severity='warning'; detail=$det.detail })
    return $det
  }
  $txt = ''
  try { $txt = (@(cmd /c "w32tm /query /status 2>nul") | ForEach-Object { "$_" }) -join "`n" } catch {}
  if ($LASTEXITCODE -ne 0 -or -not $txt) {
    $det.state = 'problem'
    $det.reason = $null
    $det.detail = 'The time service is running but w32tm /query /status failed — the service is not responding to queries.'
    $det.relevantFindings = @([ordered]@{ id='w32tm-query-failed'; severity='warning'; detail=$det.detail })
    return $det
  }
  if ($txt -match 'Last Successful Sync Time:\s*(.+)') {
    $when = $Matches[1].Trim()
    if ($when -match '(?i)unspecified') {
      $det.state = 'problem'
      $det.detail = 'The time service has never successfully synced (Last Successful Sync Time: unspecified).'
      $det.relevantFindings = @([ordered]@{ id='ntp-never-synced'; severity='warning'; detail=$det.detail })
    } else {
      $dt = $null
      try { $dt = [datetime]::Parse($when) } catch {}
      if ($null -eq $dt) {
        $det.reason = 'unparseable'
        $det.detail = "Could not parse the last sync time ('$when') — detection is indeterminate."
      } elseif ($dt -lt (Get-Date).AddDays(-7)) {
        $det.state = 'problem'
        $det.detail = "The clock last synced on $when — more than 7 days ago; synchronization looks stuck."
        $det.relevantFindings = @([ordered]@{ id='ntp-sync-stale'; severity='warning'; detail=$det.detail })
      } else {
        $det.state = 'healthy'
        $det.detail = "Time synchronization is working (last successful sync: $when)."
      }
    }
  } else {
    $det.reason = 'unparseable'
    $det.detail = 'w32tm /query /status output did not include a last-sync line — detection is indeterminate.'
  }
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
  $f = $null; $err = $null
  try { $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop } catch { $err = "$($_.Exception.Message)" }
  if ($null -eq $f) {
    if ("$err" -match '(?i)0x800f080c|feature name .* is unknown|not (?:present|recognized|found)') {
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
    else { foreach ($p in $patterns) { if ("$($f.id)" -like "$p") { $match = $true; break } } }
    if ($match) { $rel += [ordered]@{ id="$($f.id)"; severity="$($f.severity)"; detail="$($f.detail)" } }
  }
  $det.relevantFindings = $rel

  if ($rel.Count -gt 0) {
    $det.state = 'problem'
    $ids = @($rel | ForEach-Object { $_.id }) -join ', '
    $det.detail = "$($probe.summary) Relevant to this repair: $ids."
  } elseif ($status -eq 'ok') {
    $det.state = 'healthy'
    $det.detail = "$($probe.summary)"
  } elseif ($status -eq 'warning' -or $status -eq 'critical') {
    # The category has issues, but none this repair addresses — for THIS repair that is healthy.
    $det.state = 'healthy'
    $det.detail = "The '$($Repair.healthCheck)' category reports '$status', but none of its findings are ones this repair addresses. $($probe.summary)"
  } elseif ($status -eq 'needs-admin') {
    # The probe RAN; it just could not see everything without elevation. That is a
    # different animal from a broken probe: the run path may proceed via the admin gate.
    $det.reason = 'needs-admin'
    $det.detail = "The probe ran but needed administrator rights to check this category fully (status: $status). $($probe.summary)"
  } else {
    $det.reason = 'unparseable'
    $det.detail = "The probe returned an unrecognized status ('$status') for this category. $($probe.summary)"
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
$WsusIdentityValues = @('AccountDomainSid','PingID','SusClientId','SusClientIdValidation')
$WuPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'

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
      $v = Get-ItemProperty -Path $WuPolicyKey -Name $n -ErrorAction Stop
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
            $ns = (Get-ItemProperty -Path $key -Name NameServer -ErrorAction Stop).NameServer
            $row.dhcpAssigned = [string]::IsNullOrWhiteSpace("$ns")
          } catch {}
          $rows += $row
        }
      } catch {}
      return [ordered]@{ adapters = $rows; requestedProvider = $script:ResolvedDnsProviderKey }
    }
    { $_ -like 'chkdsk-*' } {
      $cap = [ordered]@{ systemDrive = "$env:SystemDrive"; dirtyBit = $null; volume = $null; scheduledAtBoot = $null }
      try {
        $o = & (Join-Path $env:SystemRoot 'System32\fsutil.exe') dirty query $env:SystemDrive
        $txt = ((@($o) | ForEach-Object { "$_" }) -join ' ')
        if ($txt -match '(?i)is\s+Dirty')      { $cap.dirtyBit = $true }
        elseif ($txt -match '(?i)is\s+NOT\s+Dirty') { $cap.dirtyBit = $false }
      } catch {}
      try {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $cap.volume = [ordered]@{ fileSystem="$($v.FileSystem)"; healthStatus="$($v.HealthStatus)"; sizeBytes=[int64]$v.Size; freeBytes=[int64]$v.SizeRemaining }
      } catch {}
      try {
        $bex = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name BootExecute -ErrorAction Stop).BootExecute
        $cap.scheduledAtBoot = (@($bex) -join ' ; ')
      } catch {}
      return $cap
    }
    'store-services-enable' {
      return [ordered]@{ services = @(Get-SvcSnapshot @('AppXSvc','ClipSVC','InstallService','DoSvc')) }
    }
    'activation-retry' {
      $cap = [ordered]@{ licenseStatus = $null; licenseStatusText = $null; product = $null }
      try {
        $q = "SELECT Name, LicenseStatus, LicenseStatusReason FROM SoftwareLicensingProduct " +
             "WHERE ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
        $lic = Get-CimInstance -Query $q -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $lic) {
          $map = @{ 0='Unlicensed'; 1='Licensed'; 2='Out-of-box grace'; 3='Out-of-tolerance grace'; 4='Non-genuine grace'; 5='Notification'; 6='Extended grace' }
          $cap.licenseStatus = [int]$lic.LicenseStatus
          $cap.licenseStatusText = $map[[int]$lic.LicenseStatus]
          $cap.product = "$($lic.Name)"
        }
      } catch {}
      return $cap
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
      try { $cap.setupCompletedSuccessfully = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -ErrorAction Stop).SetupCompletedSuccessfully } catch {}
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
      $cap = [ordered]@{ services = @(Get-SvcSnapshot @('w32time')); ntp = [ordered]@{ ntpServer=$null; type=$null } }
      try {
        $cfg = (@(cmd /c "w32tm /query /configuration 2>nul") | ForEach-Object { "$_" }) -join "`n"
        if ($cfg -match 'NtpServer:\s*([^\r\n\(]+)') { $cap.ntp.ntpServer = $Matches[1].Trim() }
        if ($cfg -match 'Type:\s*([^\r\n\(]+)')      { $cap.ntp.type      = $Matches[1].Trim() }
      } catch {}
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
    'winget-repair' {
      $det = Get-WingetDetection
      return [ordered]@{ wingetBefore = "$($det.detail)" }
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
  $ctx = @{ ts = (Get-Date -Format 'yyyyMMdd-HHmmss'); mutations = @(); sourceArg = $null; repairName = "$($Repair.name)" }
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

$SystemRestoreKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

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
        $priorFreq = (Get-ItemProperty -Path $srKey -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency
        $priorFreqPresent = $true
      } catch {}
      try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue } catch {}

      $throttleBypassed = $false
      $throttleSetError = $null
      try {
        New-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
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
              Set-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value ([int]$priorFreq) -Type DWord -ErrorAction Stop
              $restoreNote = "the 24h System Restore throttle was put back to its captured prior value ($priorFreq)"
              $ctx.mutations += [ordered]@{ type='registry-restore'; key=$srKey; name='SystemRestorePointCreationFrequency'; how='set'; restoredTo=$priorFreq; ok=$true }
            } else {
              Remove-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Force -ErrorAction Stop
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
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name Start -Value $map[$target] -Type DWord -ErrorAction Stop
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
      if ($missing.Count -gt 0)  { $parts += "Not present on this system: $($missing -join ', ')" }
      if ($failed.Count -gt 0)   { $parts += "FAILED to re-enable: $($failed -join '; ')" }
      if ($failed.Count -gt 0) { throw ($parts -join '. ') }
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
  #    to data\state\backups\ so the ledger points at something recoverable.
  $steps += @{ name='move-bits-queue-files'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Move-Item %ALLUSERSPROFILE%\Microsoft\Network\Downloader\qmgr*.dat -> data\state\backups\bits-queue-<timestamp>\  (moved, not deleted)")
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
    commands=@('netsh winhttp reset proxy   (current setting captured via "netsh winhttp show proxy" in the ledger before-state)')
    exec={ param($ctx)
      $o = & (Join-Path $env:SystemRoot 'System32\netsh.exe') winhttp reset proxy
      $txt = ((@($o) | Where-Object { "$_" -match '\S' }) -join ' ').Trim()
      if ($LASTEXITCODE -ne 0) { throw "netsh winhttp reset proxy failed (exit $LASTEXITCODE): $txt" }
      $ctx.mutations += [ordered]@{ type='winhttp-proxy-reset'; note='Prior WinHTTP proxy setting is in the ledger before-state (winHttpProxy.raw); re-apply with "netsh winhttp set proxy <server>".' }
      "WinHTTP proxy reset to direct access. $txt"
    } }
  # 5. WSUS client identity. On a machine that was once domain-joined or pointed at a
  #    now-dead WSUS server, these values pin Windows Update to a server that no longer
  #    answers. Values are captured (not just deleted) so they can be re-created.
  $steps += @{ name='clear-wsus-client-identity'; always=$false; continueOnFail=$true; bestEffort=$false
    commands=@("Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -Name AccountDomainSid, PingID, SusClientId, SusClientIdValidation  (prior values captured to the ledger)")
    exec={ param($ctx)
      $removed = @(); $absent = @(); $failed = @()
      foreach ($n in $script:WsusIdentityValues) {
        $has = $false
        try { $null = Get-ItemProperty -Path $script:WuPolicyKey -Name $n -ErrorAction Stop; $has = $true } catch { $absent += $n }
        if (-not $has) { continue }
        try {
          Remove-ItemProperty -Path $script:WuPolicyKey -Name $n -Force -ErrorAction Stop
          $ctx.mutations += [ordered]@{ type='registry-remove'; key=$script:WuPolicyKey; name=$n; note='Prior value is in the ledger before-state (wsusClientIdentity).' }
          $removed += $n
        } catch { $failed += "$n ($($_.Exception.Message))" }
      }
      if ($failed.Count -gt 0) { throw "Removed: $($removed -join ', '). FAILED: $($failed -join '; ')" }
      if ($removed.Count -eq 0) { return 'No WSUS client-identity values were present — this machine is not pinned to a WSUS server. Nothing removed.' }
      "Removed WSUS client identity value(s): $($removed -join ', ') (prior values recorded in the ledger). Windows Update will re-register with Microsoft on the next scan."
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
    commands=@('UsoClient.exe StartScan')
    exec={ param($ctx)
      $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
      if (-not (Test-Path -LiteralPath $uso)) { return 'UsoClient.exe not found — scan trigger skipped.' }
      & $uso StartScan | Out-Null
      'Triggered a Windows Update scan (UsoClient StartScan).'
    } }
  $steps
}

function Get-SfcStep {
  @{ name='sfc-scannow'; always=$false; continueOnFail=$false; bestEffort=$false
    commands=@('sfc.exe /scannow')
    exec={ param($ctx)
      $raw = & (Join-Path $env:SystemRoot 'System32\sfc.exe') /scannow
      $code = $LASTEXITCODE
      # sfc emits UTF-16; strip interleaved NULs so text matching works (same as health.ps1).
      $txt = ((@($raw) | ForEach-Object { "$_" }) -join ' ') -replace "`0", ''
      $ctx.mutations += [ordered]@{ type='sfc-scannow'; exitCode=$code }
      if ($txt -match 'did not find any integrity violations') { $ctx.sfcOutcome='clean';    return 'SFC: no integrity violations found.' }
      if ($txt -match 'successfully repaired')                 { $ctx.sfcOutcome='repaired'; return 'SFC: corrupt files were found and successfully repaired (details: C:\Windows\Logs\CBS\CBS.log, [SR] lines). Reboot recommended.' }
      if ($txt -match 'unable to fix')                         { $ctx.sfcOutcome='unfixable'; return 'SFC: corrupt files were found but some could NOT be fixed — re-run dism-restorehealth with -SourcePath (a mounted same-build ISO), then SFC again.' }
      $ctx.sfcOutcome = 'indeterminate'
      if ($code -ne 0) { throw "sfc /scannow failed (exit code $code). See C:\Windows\Logs\CBS\CBS.log." }
      'SFC finished with an unrecognized result — see C:\Windows\Logs\CBS\CBS.log.'
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
      $dismCmd = 'Dism.exe /Online /Cleanup-Image /RestoreHealth  [+ /Source:WIM:<path>:<index> /LimitAccess  or  /Source:ESD:<path>:<index> /LimitAccess  when -SourcePath is given]'
      if ($ctx.sourceArg) { $dismCmd = "Dism.exe /Online /Cleanup-Image /RestoreHealth $($ctx.sourceArg) /LimitAccess" }
      $steps = @()
      $steps += @{ name='dism-restorehealth'; always=$false; continueOnFail=$false; bestEffort=$false
        commands=@($dismCmd)
        exec={ param($ctx)
          $dismArgs = @('/Online','/Cleanup-Image','/RestoreHealth')
          if ($ctx.sourceArg) { $dismArgs += $ctx.sourceArg; $dismArgs += '/LimitAccess' }
          $raw = & (Join-Path $env:SystemRoot 'System32\Dism.exe') @dismArgs
          $code = $LASTEXITCODE
          $txt = ((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
          $ctx.mutations += [ordered]@{ type='dism-restorehealth'; exitCode=$code; usedSource=("$($ctx.sourceArg)" -ne '') }
          if ($code -eq 0 -or $code -eq 3010) {
            $msg = "DISM RestoreHealth completed (exit code $code)."
            if ($txt -match '(?m)^(The restore operation completed successfully.*)$') { $msg = "DISM: $($Matches[1])" }
            if ($code -eq 3010) { $msg = "$msg A reboot is required to finish." }
            return $msg
          }
          $tail = (@(($txt -split "`n") | Where-Object { "$_" -match '\S' } | Select-Object -Last 3) -join ' | ')
          throw "DISM RestoreHealth failed (exit code $code). Log: C:\Windows\Logs\DISM\dism.log. Tail: $tail"
        } }
      $steps += Get-SfcStep
      return $steps
    }
    'sfc-scannow' { return @(Get-SfcStep) }
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
          commands=@('netsh int ip reset')
          exec={ param($ctx)
            $raw = & (Join-Path $env:SystemRoot 'System32\netsh.exe') int ip reset
            $txt = (@($raw) | ForEach-Object { "$_" }) -join "`n"
            $ctx.mutations += [ordered]@{ type='ip-stack-reset'; exitCode=$LASTEXITCODE }
            if ($LASTEXITCODE -eq 0) { return 'TCP/IP stack reset to defaults. A reboot is required to complete it.' }
            if ($txt -match '(?i)resetting') {
              return "IP stack reset completed with warnings (exit code $LASTEXITCODE) — 'Access is denied' on a few ACL-protected subkeys is a known, benign result. A reboot is still required."
            }
            throw "netsh int ip reset failed (exit code $LASTEXITCODE)."
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
            if ($res -match '(?i)NoErrorsFound') { return "Online scan of ${letter}: found no file-system errors (result: $res). Nothing was repaired because nothing needed repairing." }
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
            if ($res -match '(?i)NoErrorsFound') { return "SpotFix ran on ${letter}: and found nothing queued to fix (result: $res)." }
            "SpotFix on ${letter}: returned '$res'. Restart to let any deferred correction complete, then re-run the disk probe."
          } }
      )
    }
    'chkdsk-full-repair' {
      return @(
        @{ name='schedule-offline-chkdsk'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@('chkdsk.exe <system drive> /f /r   (answering Y to "schedule this volume to be checked the next time the system restarts?" — the system volume can never be checked while Windows is running)')
          exec={ param($ctx)
            $drive = "$env:SystemDrive"
            $chkdsk = Join-Path $env:SystemRoot 'System32\chkdsk.exe'
            # chkdsk asks a Y/N question when the target is the volume Windows runs from;
            # piping Y schedules the check for the next boot instead of hanging forever.
            $raw = 'Y' | & $chkdsk $drive /f /r 2>&1
            $code = $LASTEXITCODE
            $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')
            $scheduled = ($txt -match '(?i)will be checked|scheduled|next time the system restarts')
            $ctx.mutations += [ordered]@{ type='chkdsk-schedule'; drive=$drive; exitCode=$code; scheduledAtNextBoot=[bool]$scheduled }
            if ($scheduled) {
              return "chkdsk $drive /f /r is SCHEDULED for the next restart. It runs before Windows starts, cannot be interrupted safely, and /r (surface scan of every sector) can take hours on a large drive. Cancel with: chkntfs /x $drive"
            }
            # No "completed in place" branch exists on purpose. This repair only ever
            # targets $env:SystemDrive, and the volume Windows is running from can never
            # be locked for a /f /r pass — Windows ALWAYS defers it to the next boot, which
            # is exactly what data/repairs.json says. Claiming "completed, no reboot needed"
            # here would have been the catalog and the code contradicting each other in
            # print, so an exit-0-without-a-schedule is reported as the unexpected result
            # it is rather than dressed up as success.
            $tail = (@(($txt -split "`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' | ')
            if ($code -ne 0) {
              throw "chkdsk $drive /f /r exited with code $code and did not report a scheduled check. Output tail: $tail"
            }
            throw ("chkdsk $drive /f /r exited 0 but never reported that $drive is scheduled to be checked at the next restart. " +
                   "The system volume cannot be checked in place, so this is NOT a 'finished without a reboot' result — nothing has been scheduled. " +
                   "Confirm with 'chkntfs $drive' (it prints whether the volume is dirty / scheduled) and re-run. Output tail: $tail")
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
          commands=@('cscript.exe //nologo C:\Windows\System32\slmgr.vbs /ato   (force an online activation attempt against Microsoft''s activation servers)')
          exec={ param($ctx)
            $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
            $slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
            if (-not (Test-Path -LiteralPath $slmgr)) { throw 'slmgr.vbs was not found — this system has no scriptable licensing client.' }
            $raw = & $cscript //nologo $slmgr /ato 2>&1
            $code = $LASTEXITCODE
            $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '').Trim()
            $ctx.mutations += [ordered]@{ type='activation-attempt'; exitCode=$code }
            if ($txt -match '(?i)successfully') { return "Activation succeeded: $txt" }
            $err = $null
            if ($txt -match '(0x[0-9A-Fa-f]{8})') { $err = $Matches[1] }
            $hint = ''
            if ($err -eq '0xC004F213') { $hint = ' (0xC004F213: no product key or digital licence found for this device — a key must be entered, or this is a hardware-change case.)' }
            elseif ($err -eq '0xC004C003') { $hint = ' (0xC004C003: the activation server refused the key, typically after a hardware change — use Settings > Activation > Troubleshoot with the Microsoft account holding the digital licence.)' }
            throw "slmgr /ato did not activate Windows (exit code $code).$hint Output: $txt"
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
            $ctx.mutations += [ordered]@{ type='appx-reregister-all'; succeeded=$ok; failed=$failCount }
            $sample = ''
            if ($failSample.Count -gt 0) { $sample = " (sample: $($failSample -join ', '))" }
            "Re-registered $ok of $($pkgs.Count) packages; $failCount failed$sample — protected/staged system packages fail by design and are harmless."
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
            try { $prior = (Get-ItemProperty -Path $key -Name SetupCompletedSuccessfully -ErrorAction Stop).SetupCompletedSuccessfully } catch {}
            Set-ItemProperty -Path $key -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction Stop
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
          commands=@("Move-Item $env:SystemRoot\System32\spool\PRINTERS\* -> data\state\backups\spool-$($ctx.ts)\  (moved, not deleted)")
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
          commands=@('w32tm /config /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL /update')
          exec={ param($ctx)
            $w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
            $raw = & $w32tm /config '/manualpeerlist:pool.ntp.org,0x8' /syncfromflags:MANUAL /update
            if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed (exit code $LASTEXITCODE): $((@($raw) -join ' '))" }
            $ctx.mutations += [ordered]@{ type='w32tm-config'; peer='pool.ntp.org,0x8'; syncFromFlags='MANUAL' }
            'Configured pool.ntp.org as the manual NTP peer (prior configuration is in the ledger before-state).'
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
            if ($LASTEXITCODE -ne 0) { throw "w32tm /resync failed (exit code $LASTEXITCODE): $((@($raw) -join ' ')) — the peer may be unreachable; the service will retry on its schedule." }
            'Clock resynchronized against pool.ntp.org.'
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
      $cmdText = 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup'
      if ($resetBase) { $cmdText = "$cmdText /ResetBase" }
      $step = @{ name='component-cleanup'; always=$false; continueOnFail=$false; bestEffort=$false
        commands=@($cmdText)
        exec={ param($ctx)
          $dismArgs = @('/Online','/Cleanup-Image','/StartComponentCleanup')
          if ($ctx.resetBase) { $dismArgs += '/ResetBase' }
          $raw = & (Join-Path $env:SystemRoot 'System32\Dism.exe') @dismArgs
          $code = $LASTEXITCODE
          $ctx.mutations += [ordered]@{ type='component-cleanup'; resetBase=[bool]$ctx.resetBase; exitCode=$code }
          if ($code -eq 0 -or $code -eq 3010) {
            $msg = "Component-store cleanup completed (exit code $code)."
            if ($ctx.resetBase) { $msg = "$msg /ResetBase was applied: installed updates are now permanent and can no longer be uninstalled." }
            return $msg
          }
          throw "DISM StartComponentCleanup failed (exit code $code). Log: C:\Windows\Logs\DISM\dism.log"
        } }
      $ctx.resetBase = $resetBase
      return @($step)
    }
    'winget-repair' {
      return @(
        @{ name='bootstrap-winget-module'; always=$false; continueOnFail=$false; bestEffort=$false
          commands=@(
            'Install-PackageProvider -Name NuGet -Force  (only if Repair-WinGetPackageManager is not already available)',
            'Install-Module -Name Microsoft.WinGet.Client -Force  (only if not already available)')
          exec={ param($ctx)
            if (Get-Command -Name Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
              return 'The Microsoft.WinGet.Client module is already available — bootstrap skipped.'
            }
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
            $ctx.mutations += [ordered]@{ type='module-install'; name='Microsoft.WinGet.Client' }
            'Installed the Microsoft.WinGet.Client PowerShell module from the PowerShell Gallery.'
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
          if ($msg -match '0x800F0906|0x800F081F|0x800f0950') {
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
  [ordered]@{
    ok = $true
    id = "$($Repair.id)"
    action = 'preflight'
    name = "$($Repair.name)"
    tier = "$($Repair.tier)"
    isAdmin = $IsAdmin
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
  if ($ctx.ContainsKey('sfcOutcome') -and $ctx.sfcOutcome -eq 'unfixable') { $stepsCompleted = $false }
  $verified = ($postDet.state -eq 'healthy')
  $addressed = ($stepsCompleted -and $verified)

  $detail = ''
  if ($aborted) {
    $detail = "Step '$failedStep' failed; later steps were skipped (recovery steps marked 'always' still ran). The ledger entry records exactly what changed before the failure."
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
      $peer = $null; $type = $null
      try { $peer = "$($entry.before.ntp.ntpServer)" } catch {}
      try { $type = "$($entry.before.ntp.type)" } catch {}
      $wasStopped = $false
      try {
        $svcRow = @($entry.before.services) | Where-Object { "$($_.name)" -eq 'w32time' } | Select-Object -First 1
        if ($svcRow -and "$($svcRow.status)" -ne 'Running') { $wasStopped = $true }
      } catch {}
      if ($type -match 'NT5DS') { $plan += 'w32tm /config /syncfromflags:DOMHIER /update  (restore domain-hierarchy sync)' }
      elseif ($peer) { $plan += "w32tm /config /manualpeerlist:`"$peer`" /syncfromflags:MANUAL /update  (restore the captured peer list)" }
      else { $plan += 'w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:MANUAL /update  (no prior peer captured; Windows default)' }
      $plan += 'Restart-Service -Name w32time'
      $plan += 'w32tm /resync  (best effort)'
      if ($wasStopped) { $plan += 'Stop-Service -Name w32time  (the service was stopped before the repair ran)' }
      if (-not $DryRun) {
        $w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
        if ($type -match 'NT5DS') { $raw = & $w32tm /config /syncfromflags:DOMHIER /update }
        elseif ($peer) { $raw = & $w32tm /config "/manualpeerlist:$peer" /syncfromflags:MANUAL /update }
        else { $raw = & $w32tm /config '/manualpeerlist:time.windows.com,0x9' /syncfromflags:MANUAL /update }
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed during undo (exit code $LASTEXITCODE): $((@($raw) -join ' '))" }
        $actions += 'Restored the captured NTP configuration.'
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
  foreach ($r in $catalog) {
    $det = $null
    try { $det = Get-RepairDetection $r -ShallowOnly }
    catch { $det = [ordered]@{ state='indeterminate'; detail="Detection failed: $($_.Exception.Message)" } }
    $rows += [ordered]@{
      id = "$($r.id)"
      name = "$($r.name)"
      category = "$($r.category)"
      tier = "$($r.tier)"
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
    count = $rows.Count
    byTier = [ordered]@{
      standard   = @($catalog | Where-Object { $_.tier -eq 'standard' }).Count
      aggressive = @($catalog | Where-Object { $_.tier -eq 'aggressive' }).Count
    }
    reversibleCount = @($catalog | Where-Object { $_.reversible }).Count
    restorePointEnforcedCount = @($catalog | Where-Object { Test-RestorePointEnforced $_ }).Count
    note = 'Detection states here use fast probes; repairs marked probeDeep report indeterminate (reason: shallow-probe) until their deep probe runs at preflight/run. detection.reason distinguishes a probe that FAILED (probe-failure — the repair refuses) from one that merely needs elevation (needs-admin — the repair may proceed) and from one that read the real state but cannot judge it for you (user-initiated — the optional-feature repairs: a disabled feature is the Windows default, not a fault, so the engine reports the state and lets you decide).'
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
    $s = [regex]::Replace($s, [regex]::Escape("$($p.v)"), "$($p.t)".Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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
    $s = [regex]::Replace($s, [regex]::Escape($p.f), $p.t.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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
    try { $healthDoc = Get-Content -Raw -Encoding UTF8 -Path $HealthCatalog | ConvertFrom-Json } catch { $healthError = "$($_.Exception.Message)" }
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

  $allOk = ($dangling.Count -eq 0 -and $mismatches.Count -eq 0 -and $textMismatches.Count -eq 0 -and $null -eq $healthError)
  [ordered]@{
    ok = $allOk
    action = 'selftest'
    repairCount = $catalog.Count
    repairIds = $ids
    healthCatalog = $HealthCatalog
    healthCatalogError = $healthError
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
          $entries = @(Load-RepairLedger)
          $out = [ordered]@{ ok=$true; count=$entries.Count; ledgerPath=$LedgerPath; entries=$entries }
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
            'run'       { $out = Invoke-RepairRun $repair }
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
