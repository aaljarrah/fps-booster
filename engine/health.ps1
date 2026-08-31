<#
  FrameForge :: health.ps1
  Read-only Windows health detection. Runs the detection signals from
  docs/research/repair-ladder.md §3 and emits a single JSON object on stdout.
  NOTHING in this script mutates system state, with two documented bookkeeping
  exceptions: (1) -Deep DISM ScanHealth records its verdict in the component
  store's corruption flag and writes %WINDIR%\Logs\DISM\dism.log, and (2) the
  DNS-based probes (Resolve-DnsName / Test-NetConnection by name) populate the
  local resolver cache. The same probes serve as the post-fix verification step.

  Usage:
    health.ps1 -Action scan [-Deep]            # all categories (fast probes; -Deep adds slow read-only scans)
    health.ps1 -Action probe -Category disk    # one category
    health.ps1 -Action list                    # category ids

  Output is always a single JSON document; -Json is accepted for interface
  symmetry with the other engine scripts.

  Non-admin behavior: probes that require elevation degrade to status
  "needs-admin" (or skip that sub-signal) — they never crash the scan.

  STATUS VOCABULARY (per category): ok | needs-admin | unknown | warning | critical.
  'unknown' is the doctrine's first-class "could not determine" (docs/GAUNTLET.md rule 2). It was
  already emitted for a probe that threw; it is now ALSO the status of any category whose signal
  could not be read — a denied event channel, an unparseable tool result, a failed query. It
  ranks above 'ok' and 'needs-admin' precisely so a failed measurement can never be rendered as
  a green tick. Finding severities are info | unknown | warning | critical, matching that rank.

  Every document also carries the platform it was measured on: os, edition, supportedOs,
  unvalidatedPlatform, languageMode.
#>
[CmdletBinding()]
param(
  # NOT [ValidateSet]. A ValidateSet on -Action fails PARAMETER BINDING before the script body
  # ever runs: PowerShell writes a multi-line error to stderr, stdout stays EMPTY, and the
  # process exits 1. The Electron host parses exactly one JSON document per run and would get
  # nothing at all — the same "the engine returned no output" dead end as the constrained-language
  # bug. repair.ps1 and image.ps1 already validate in the body for exactly this reason; health.ps1
  # now matches them. The valid list lives in $ValidActions below and is reported in the error doc.
  [string]$Action = 'scan',
  [string]$Category,
  [switch]$Deep,
  [switch]$Json
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot '_lib.ps1')
$IsAdmin = Test-Admin

# ---------------- shared helpers (health-specific) ----------------

function New-Finding {
  param(
    [Parameter(Mandatory)][string]$Id,
    # 'unknown' is a FIRST-CLASS severity, not a synonym for 'info'. It means "this signal could
    # not be read", and it exists so a failed or unmatched check can never fall through to a
    # confident 'ok' (docs/GAUNTLET.md rule 2). Use it for every *-indeterminate,
    # *-query-failed and *-unreadable outcome.
    [Parameter(Mandatory)][ValidateSet('info','unknown','warning','critical')][string]$Severity,
    [Parameter(Mandatory)][string]$Detail,
    $Evidence = $null
  )
  [ordered]@{ id = $Id; severity = $Severity; detail = $Detail; evidence = $Evidence }
}

function Resolve-Status {
  # Rank: critical > warning > unknown > needs-admin > ok.
  # info findings never degrade the status. 'unknown' ranks ABOVE 'ok' and 'needs-admin' because
  # needs-admin means "elevate me and I will know", while unknown means "I did not measure this
  # at all". repair.ps1's Get-RepairDetection has no 'unknown' arm, so it falls through to
  # reason='unparseable' — a repair then refuses WITH A NAMED REASON instead of claiming
  # "nothing is broken here", which is exactly the intended behaviour.
  param($Findings, [bool]$NeedsAdmin)
  $f = @($Findings)
  if (@($f | Where-Object { $_.severity -eq 'critical' }).Count -gt 0) { return 'critical' }
  if (@($f | Where-Object { $_.severity -eq 'warning' }).Count -gt 0)  { return 'warning' }
  if (@($f | Where-Object { $_.severity -eq 'unknown' }).Count -gt 0)  { return 'unknown' }
  if ($NeedsAdmin) { return 'needs-admin' }
  return 'ok'
}

function Get-IssueCount {
  # FAULTS only. An 'unknown' finding is not a fault, it is a hole in the measurement, and a
  # summary has to word the two differently — so probes never use `severity -ne 'info'` for this.
  param($Findings)
  @(@($Findings) | Where-Object { $_.severity -eq 'warning' -or $_.severity -eq 'critical' }).Count
}

function Get-UnknownCount {
  param($Findings)
  @(@($Findings) | Where-Object { $_.severity -eq 'unknown' }).Count
}

function Add-UnknownNote {
  # Appends the honest "and here is what I could NOT read" clause to a healthy-branch summary,
  # naming the signals by finding id so the claim is bounded by the evidence.
  param([string]$Summary, $Findings)
  $u = @(@($Findings) | Where-Object { $_.severity -eq 'unknown' })
  if ($u.Count -eq 0) { return $Summary }
  $ids = @($u | ForEach-Object { $_.id }) -join ', '
  return "$Summary This is NOT a clean bill of health: $($u.Count) signal(s) could not be read ($ids)."
}

# Services that Windows 11 client ships by DEFAULT. A missing entry here is not "not
# applicable" — it was deleted (`sc delete` on exactly these names is what the popular
# "optimize Windows for gaming" debloat scripts do), and a probe that filters on `present`
# silently grades a deleted service as healthy. Get-ServiceInfo therefore tags every row with
# `expected`, and each probe turns expected-but-absent into a real finding.
$script:FFExpectedServices = [ordered]@{
  'wuauserv'             = 'Windows Update'
  'bits'                 = 'Background Intelligent Transfer'
  'cryptsvc'             = 'Cryptographic Services'
  'DoSvc'                = 'Delivery Optimization'
  'UsoSvc'               = 'Update Orchestrator'
  'AppXSvc'              = 'AppX Deployment'
  'ClipSVC'              = 'Client License'
  'InstallService'       = 'Microsoft Store Install'
  'WSearch'              = 'Windows Search'
  'Spooler'              = 'Print Spooler'
  'Audiosrv'             = 'Windows Audio'
  'AudioEndpointBuilder' = 'Windows Audio Endpoint Builder'
}

function Get-ServiceInfo {
  <#
    THE BUG THIS REPLACED (docs/GAUNTLET.md rule 2, the fabricated-FAULT direction): every
    Get-Service failure — access denied, an RPC failure to the Service Control Manager, a
    stripped Microsoft.PowerShell.Management module — arrived down one bare catch and became
    `present = $false`. Five categories then asserted AT CRITICAL SEVERITY that core Windows
    services had been DELETED by a debloat script, on a machine where the query had simply
    never run. Verified with a throwing Get-Service stub: windows-update, store and audio all
    went 'critical' with '<name>-missing' findings, printing and search went 'warning'.

    `present` is now TRI-STATE, decided by ERROR IDENTITY, never by message text:
      $true  — Get-Service returned the service.
      $false — Get-Service RAN and answered "no such service": FullyQualifiedErrorId
               NoServiceFoundForGivenName*, or a ServiceCommandException in the ObjectNotFound
               category. Measured, and the service genuinely does not exist.
      $null  — the query itself could not run. NOTHING was measured about this service, and a
               caller must NOT read it as absence.
    `measured` ($true/$false), `queryErrorKind` and `queryError` carry the same distinction
    explicitly, for any consumer that cannot express a tri-state. All three fields are ADDITIVE;
    `name`, `status`, `startType`, `expected` and `friendlyName` keep their existing meaning.
  #>
  param([string[]]$Names)
  $out = @()
  foreach ($n in $Names) {
    $expected = $script:FFExpectedServices.Contains($n)
    $friendly = $n
    if ($expected) { $friendly = $script:FFExpectedServices[$n] }
    try {
      $s = Get-Service -Name $n -ErrorAction Stop
      $st = $null
      try { $st = "$($s.StartType)" } catch {}
      $out += [ordered]@{ name = $n; status = "$($s.Status)"; startType = $st; present = $true; measured = $true; queryErrorKind = $null; queryError = $null; expected = $expected; friendlyName = $friendly }
    } catch {
      $rec = $_
      $fqid = ''; try { $fqid = "$($rec.FullyQualifiedErrorId)" } catch {}
      $cat  = ''; try { $cat  = "$($rec.CategoryInfo.Category)" } catch {}
      # The type is compared BY NAME, not with a [type] literal: on a host where the Management
      # module is the thing that is broken, a literal for one of its types is itself unresolvable.
      $exType = ''; try { $exType = "$($rec.Exception.GetType().FullName)" } catch {}
      $msg = ''; try { $msg = "$($rec.Exception.Message)" } catch {}
      $absent = ($fqid -like 'NoServiceFoundForGivenName*') -or
                ($exType -eq 'Microsoft.PowerShell.Commands.ServiceCommandException' -and $cat -eq 'ObjectNotFound')
      if ($absent) {
        $out += [ordered]@{ name = $n; status = 'NotFound'; startType = $null; present = $false; measured = $true; queryErrorKind = 'absent'; queryError = $msg; expected = $expected; friendlyName = $friendly }
      } else {
        $kind = 'query-failed'
        if (Test-FFAccessDenied -ErrorRecord $rec) { $kind = 'access-denied' }
        elseif ($fqid -like 'CommandNotFoundException*') { $kind = 'cmdlet-missing' }
        # status 'Unknown' rather than 'NotFound': the string is evidence too, and 'NotFound'
        # is a claim this row is explicitly not making.
        $out += [ordered]@{ name = $n; status = 'Unknown'; startType = $null; present = $null; measured = $false; queryErrorKind = $kind; queryError = $msg; expected = $expected; friendlyName = $friendly }
      }
    }
  }
  # Emitted plainly — collect with @(...) at the call site.
  $out
}

function New-ServiceQueryFindings {
  <#
    One '<name>-query-failed' finding at severity 'unknown' per service whose query never ran.
    This is the counterpart to New-MissingServiceFindings: absence gets a fault, an unmeasured
    result gets a hole. Neither may be silent, and they must never be the same finding.
  #>
  param($Services)
  $out = @()
  foreach ($s in @($Services)) {
    if ($s.measured -eq $false) {
      $out += New-Finding "$($s.name)-query-failed" 'unknown' "The $($s.friendlyName) service ($($s.name)) could not be queried ($($s.queryErrorKind)), so neither its existence nor its state was measured. This is NOT a statement that the service is missing: $($s.queryError)" ([ordered]@{ service = $s.name; friendlyName = $s.friendlyName; present = $null; measured = $false; errorKind = $s.queryErrorKind; error = $s.queryError })
    }
  }
  $out
}

function New-MissingServiceFindings {
  <#
    One '<name>-missing' finding per EXPECTED service that does not exist. Deleting a service is
    not the same as disabling it: Set-Service cannot bring it back, so this is reported as a
    fault in its own right rather than left as silence.
  #>
  param(
    $Services,
    [ValidateSet('warning','critical')][string]$Severity = 'warning',
    [string]$Consequence = ''
  )
  $out = @()
  foreach ($s in @($Services)) {
    # `-eq $false` and NOT `-not $s.present`: present is tri-state now, and $null (the query
    # never ran) must fall through to New-ServiceQueryFindings, not into a deletion claim.
    if ($s.expected -and $s.present -eq $false) {
      $out += New-Finding "$($s.name)-missing" $Severity ("The $($s.friendlyName) service ($($s.name)) does not exist on this system — it was deleted, not merely disabled. $Consequence Set-Service cannot recreate a deleted service; this usually comes from a debloat/'gaming optimizer' script.").Trim() ([ordered]@{ service = $s.name; friendlyName = $s.friendlyName; present = $false })
    }
  }
  $out
}

function Format-ServicePresence {
  <#
    "5 of 5 update services present and enabled" — a claim bounded by what was actually checked.
    The denominator is the number of services that were MEASURED, not the number asked about:
    with the tri-state `present`, counting unmeasured rows in the denominator turned a broken
    Service Control Manager into the sentence "0 of 5 update services present and enabled",
    which is the same fabricated absence in a different costume. Services whose query never ran
    are named separately instead.
  #>
  param($Services, [string]$Label)
  $all = @($Services)
  $unmeasured = @($all | Where-Object { $_.measured -eq $false })
  $measured = @($all | Where-Object { $_.measured -ne $false })
  $present = @($measured | Where-Object { $_.present -eq $true })
  $enabled = @($present | Where-Object { $_.startType -ne 'Disabled' })
  if ($measured.Count -eq 0) {
    return "none of the $($all.Count) $Label could be queried, so their presence is unknown"
  }
  $txt = "$($enabled.Count) of $($measured.Count) $Label present and enabled"
  if ($unmeasured.Count -gt 0) {
    $txt = "$txt ($($unmeasured.Count) could not be queried: $((@($unmeasured | ForEach-Object { $_.name }) -join ', ')))"
  }
  return $txt
}

# ---------------- category probes ----------------
# Each returns @{ summary = <sentence>; findings = @(...); needsAdmin = <bool> }.
# Every sub-signal is individually try/caught: one failure cannot break the category.

function Probe-SystemFiles {
  $findings = @(); $needsAdmin = $false
  $healthState = $null

  # DISM corruption flag (structured, fast). Requires elevation.
  if ($IsAdmin) {
    try {
      $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
      $healthState = "$($r.ImageHealthState)"
      if ($healthState -ne 'Healthy') {
        $sev = 'warning'
        if ($healthState -eq 'NonRepairable') { $sev = 'critical' }
        $findings += New-Finding 'component-store-corrupt' $sev "The Windows component store reports '$healthState' — DISM repair is indicated before SFC." ([ordered]@{ imageHealthState = $healthState })
      }
    } catch {
      $findings += New-Finding 'dism-checkhealth-failed' 'unknown' "DISM CheckHealth could not run, so component-store corruption was not measured: $($_.Exception.Message)" $null
    }
  } else {
    $needsAdmin = $true
  }

  # CBS pending reboot key (readable without admin)
  $cbsPending = $false
  $cbsPendingRead = $false
  try {
    $cbsPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction Stop
    $cbsPendingRead = $true
    if ($cbsPending) {
      $findings += New-Finding 'cbs-reboot-pending' 'warning' 'Component servicing has a pending reboot — some system-file repairs only complete after a restart.' ([ordered]@{ registryKey = 'HKLM\...\Component Based Servicing\RebootPending'; present = $true })
    }
  } catch {}

  # Deep, still read-only: sfc /verifyonly + DISM ScanHealth (slow, admin-only)
  if ($Deep) {
    if ($IsAdmin) {
      try {
        # 5 s of skew allowance: CBS.log timestamps are local wall-clock, written by another process.
        $sfcStart = (Get-Date).AddSeconds(-5)
        $sfc = Invoke-FFNative -FilePath (Join-Path $env:SystemRoot 'System32\sfc.exe') -Arguments @('/verifyonly')
        # sfc emits UTF-16; Invoke-FFNative's NUL-strip is what makes any parse of it possible.
        $txt = "$($sfc.text)"

        # ---- Rung 1 (authoritative, locale-independent): the [SR] tail of CBS.log ----
        # CBS.log is a servicing TRACE written by the component-based-servicing stack, and its
        # [SR] lines are invariant English on every Windows UI language — unlike sfc's console
        # output, which is fully MUI-localized and matches nothing outside en-US. This rung is
        # therefore the verdict, and the English console text is only a fallback below.
        # DEPENDENCY, stated plainly: this rung assumes CBS.log stays English-invariant. If that
        # ever changes, this falls through to rung 2 and then to an honest 'unknown' — never to
        # a confident "clean".
        # Lines look like: "2026-08-30 12:34:56, Info   CBS    [SR] Verify complete"
        # Every line is time-filtered to THIS run first: a "Verify complete" left over from a
        # previous scan must never be allowed to grade today's one.
        $srAll = @(); $srRun = @(); $srTimed = $false; $cbsReadError = $null
        $cbsLog = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
        try {
          $srAll = @(Get-Content -Path $cbsLog -Tail 6000 -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_ -match '\[SR\]' } | ForEach-Object { "$_".Trim() })
          foreach ($line in $srAll) {
            if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
              $srTimed = $true
              $ts = $null
              try { $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
              if ($null -ne $ts -and $ts -ge $sfcStart) { $srRun += $line }
            }
          }
        } catch { $cbsReadError = "$($_.Exception.Message)" }

        $evi = [ordered]@{
          sfcExitCode    = $sfc.exitCode
          log            = $cbsLog
          srLinesThisRun = $srRun.Count
          srTail         = @($srRun | Select-Object -Last 20)
          srTailAny      = @($srAll | Select-Object -Last 10)
          cbsReadError   = $cbsReadError
          verdictSource  = $null
        }
        $srCannot   = @($srRun | Where-Object { $_ -match '\[SR\]\s+Cannot repair member file' })
        $srRepaired = @($srRun | Where-Object { $_ -match '\[SR\]\s+Repair(ing|ed) corrupted file|\[SR\]\s+Repairing file' })
        # COMPLETION means COMPLETION. The old pattern also accepted '[SR] Verifying 100 (0x...)
        # components', which sfc writes when a verification pass STARTS. A scan that was killed,
        # timed out, or aborted mid-transaction logs 'Beginning Verify and Repair transaction'
        # plus one or more 'Verifying N components' lines and then simply stops — and that was
        # graded 'sfc-verify-clean' at severity 'info': an INCOMPLETE scan reported as a
        # completed clean one, counting as neither an issue nor an unknown. Only a real
        # terminator counts now; a started-but-unterminated tail falls through to the honest
        # 'unknown' rung below, which names the partial scan as the reason.
        $srComplete = @($srRun | Where-Object { $_ -match '\[SR\]\s+(Verify|Repair) complete' })
        $srStarted  = @($srRun | Where-Object { $_ -match '\[SR\]\s+Verifying\s+\d+|\[SR\]\s+Beginning Verify and Repair transaction' })

        if ($srCannot.Count -gt 0) {
          $evi.verdictSource = 'cbs-log-sr-lines'
          $findings += New-Finding 'sfc-verify-violations' 'warning' "SFC verification found integrity violations it could not repair ($($srCannot.Count) '[SR] Cannot repair member file' entries logged by this run) — run DISM RestoreHealth, then sfc /scannow." $evi
        } elseif ($srRepaired.Count -gt 0) {
          $evi.verdictSource = 'cbs-log-sr-lines'
          $findings += New-Finding 'sfc-verify-violations' 'warning' "SFC verification found integrity violations ($($srRepaired.Count) corrupted file(s) named in this run's CBS [SR] log) — run DISM RestoreHealth, then sfc /scannow." $evi
        } elseif ($srComplete.Count -gt 0) {
          $evi.verdictSource = 'cbs-log-sr-lines'
          $findings += New-Finding 'sfc-verify-clean' 'info' 'SFC verification completed and named no corrupted files in the CBS [SR] log for this run.' $evi
        } elseif ($txt -match 'did not find any integrity violations') {
          # ---- Rung 2: DOCUMENTED ENGLISH-ONLY console parse (kept so the capability survives
          #      on en-US machines whose CBS.log is unreadable; never reached on localized ones) ----
          $evi.verdictSource = 'sfc-console-english'
          $findings += New-Finding 'sfc-verify-clean' 'info' 'SFC verification found no integrity violations (English console-output parse; the CBS [SR] log for this run could not be used).' $evi
        } elseif ($txt -match 'found integrity violations') {
          $evi.verdictSource = 'sfc-console-english'
          $findings += New-Finding 'sfc-verify-violations' 'warning' 'SFC verification found integrity violations (English console-output parse) — run DISM RestoreHealth, then sfc /scannow.' $evi
        } else {
          # ---- Rung 3: honest unknown. Severity 'unknown' so the category cannot resolve to 'ok'. ----
          $evi.verdictSource = 'none'
          $evi.consoleTail = "$txt".Trim()
          $evi.srStartMarkers = $srStarted.Count
          $reason = 'no [SR] entries for this run were found in CBS.log'
          if ($null -ne $cbsReadError) { $reason = "CBS.log could not be read ($cbsReadError)" }
          elseif ((-not $srTimed) -and $srAll.Count -gt 0) { $reason = 'the CBS.log [SR] entries carried no parseable timestamp, so none could be attributed to this run' }
          elseif ($srStarted.Count -gt 0) { $reason = "the scan STARTED ($($srStarted.Count) '[SR] Verifying ... components' / 'Beginning Verify and Repair transaction' entries) but CBS.log records no '[SR] Verify complete' or '[SR] Repair complete' terminator for this run, so the verification did not finish" }
          $findings += New-Finding 'sfc-verify-indeterminate' 'unknown' "SFC ran (exit code $($sfc.exitCode)) but its verdict could not be determined: $reason, and the console output did not match the documented English form. System-file integrity is UNKNOWN, not clean." $evi
        }
      } catch {
        $findings += New-Finding 'sfc-verify-failed' 'unknown' "sfc /verifyonly could not run, so system-file integrity was not measured: $($_.Exception.Message)" $null
      }
      try {
        $r2 = Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop
        $deepState = "$($r2.ImageHealthState)"
        if ($deepState -ne 'Healthy') {
          $sev2 = 'warning'
          if ($deepState -eq 'NonRepairable') { $sev2 = 'critical' }
          $findings += New-Finding 'component-store-scanhealth' $sev2 "Deep DISM scan reports the component store is '$deepState'." ([ordered]@{ imageHealthState = $deepState })
        } else {
          $findings += New-Finding 'component-store-scanhealth-clean' 'info' 'Deep DISM scan confirms the component store is healthy.' $null
        }
      } catch {
        $findings += New-Finding 'dism-scanhealth-failed' 'unknown' "DISM ScanHealth could not run, so the deep component-store scan produced no result: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $summary = ''
  if ($null -ne $healthState -and $healthState -eq 'Healthy') {
    if ($cbsPending) { $summary = 'Component store is healthy, but a servicing reboot is pending.' }
    # Test-Path returns $false for a key it cannot read as readily as for one that is absent, so
    # "no servicing reboot is pending" may only be said when the read actually completed.
    elseif ($cbsPendingRead) { $summary = 'Component store reports healthy and no servicing reboot is pending.' }
    else { $summary = 'Component store reports healthy; the pending-servicing-reboot key could not be read, so a pending reboot cannot be ruled out.' }
  } elseif ($null -ne $healthState) {
    $summary = "Component store reports '$healthState'."
  } elseif ($needsAdmin) {
    $summary = 'The component-store corruption check needs administrator rights; only the pending-reboot key was checked.'
  } else {
    $summary = 'Component-store state could not be determined.'
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Disk {
  $findings = @(); $needsAdmin = $false
  $sysDrive = $env:SystemDrive
  $dirtyKnown = $false

  # NTFS dirty bit — read structurally via FSCTL_IS_VOLUME_DIRTY (see Get-FFVolumeDirtyBit in
  # _lib.ps1 for the full ladder). That call is locale-independent AND works unelevated, so the
  # signal that gates chkdsk-scan / chkdsk-spotfix / chkdsk-full-repair is no longer decided by
  # matching the English strings 'is Dirty' / 'is NOT Dirty' in fsutil's output. The identical
  # helper is what repair.ps1's chkdsk capture should call, so the ledger and this probe agree.
  $dirtyInfo = $null
  try {
    $dirtyInfo = Get-FFVolumeDirtyBit -Volume $sysDrive -IsAdmin $IsAdmin
    if ($dirtyInfo.dirty -eq $true) {
      $dirtyKnown = $true
      $findings += New-Finding 'ntfs-dirty-bit' 'critical' "The NTFS dirty bit is set on $sysDrive — the file system needs a disk check before anything else." $dirtyInfo
    } elseif ($dirtyInfo.dirty -eq $false) {
      $dirtyKnown = $true
    } elseif ($dirtyInfo.needsAdmin) {
      $needsAdmin = $true
      $findings += New-Finding 'dirty-query-indeterminate' 'unknown' "The NTFS dirty bit on $sysDrive could not be read: $($dirtyInfo.detail)" $dirtyInfo
    } else {
      $findings += New-Finding 'dirty-query-indeterminate' 'unknown' "The NTFS dirty bit on $sysDrive could not be read, so it is UNKNOWN rather than clean: $($dirtyInfo.detail)" $dirtyInfo
    }
  } catch {
    $findings += New-Finding 'dirty-query-indeterminate' 'unknown' "The NTFS dirty bit on $sysDrive could not be read: $($_.Exception.Message)" $null
    if (-not $IsAdmin) { $needsAdmin = $true }
  }

  # Physical disk health + reliability counters
  $diskEvidence = @()
  $diskQueryError = $null
  try {
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
      $h = "$($d.HealthStatus)"
      $row = [ordered]@{ name = "$($d.FriendlyName)"; healthStatus = $h; operationalStatus = "$($d.OperationalStatus)" }
      if ($h -and $h -ne 'Healthy') {
        $findings += New-Finding 'physical-disk-unhealthy' 'critical' "Drive '$($d.FriendlyName)' reports health status '$h'." $row
      }
      try {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($rc) {
          $row.wearPct = $rc.Wear
          $row.readErrorsTotal = $rc.ReadErrorsTotal
          $row.writeErrorsTotal = $rc.WriteErrorsTotal
          $row.temperatureC = $rc.Temperature
          if (($null -ne $rc.ReadErrorsTotal -and [int64]$rc.ReadErrorsTotal -gt 0) -or ($null -ne $rc.WriteErrorsTotal -and [int64]$rc.WriteErrorsTotal -gt 0)) {
            $findings += New-Finding 'disk-media-errors' 'warning' "Drive '$($d.FriendlyName)' has logged media errors (read: $($rc.ReadErrorsTotal), write: $($rc.WriteErrorsTotal))." $row
          }
          if ($null -ne $rc.Wear -and [int]$rc.Wear -ge 95) {
            $findings += New-Finding 'ssd-wear-critical' 'critical' "Drive '$($d.FriendlyName)' reports $($rc.Wear)% wear — near end of rated life." $row
          } elseif ($null -ne $rc.Wear -and [int]$rc.Wear -ge 80) {
            $findings += New-Finding 'ssd-wear-high' 'warning' "Drive '$($d.FriendlyName)' reports $($rc.Wear)% wear." $row
          }
        }
      } catch {} # reliability counters are frequently access-denied without admin — that is fine
      $diskEvidence += $row
    }
  } catch { $diskQueryError = "$($_.Exception.Message)" }
  if ($diskEvidence.Count -gt 0) {
    $findings += New-Finding 'physical-disk-inventory' 'info' "Per-drive health captured for $($diskEvidence.Count) physical drive(s)." ([ordered]@{ drives = $diskEvidence })
  }
  if ($null -ne $diskQueryError) {
    $findings += New-Finding 'physical-disk-query-failed' 'unknown' "Physical drive health could not be queried, so drive health is UNKNOWN: $diskQueryError" ([ordered]@{ drivesInspected = $diskEvidence.Count })
  }

  # NTFS / disk / storage-controller error events, last 7 days.
  #   Ntfs 55/98/130, disk 7/51/153, storahci|stornvme 129 = controller reset, 157 = surprise removal.
  # storahci is the SATA/AHCI port driver and logs NOTHING on an NVMe-only machine, which is
  # near-universal on this hardware class — stornvme (and the Intel RST drivers) must be asked too.
  # But provider names are NOT free to add: Get-WinEvent rejects the WHOLE query with
  # NoMatchingProvidersFound when one name is unknown here (verified: 'iaStorAC' on a stock NVMe
  # box kills the entire query), so the candidates are filtered to the providers that exist and
  # the summary below names the ones actually queried.
  $diskProviders = @(Get-FFEventProviders -Candidates @('Ntfs','disk','storahci','stornvme','iaStorAC','iaStorAVC'))
  $ev = @()
  $diskEventUnreadable = $false; $diskEventError = $null
  if ($diskProviders.Count -eq 0) {
    $diskEventUnreadable = $true
    # Worded as a failure to CONFIRM, not as a fact: Get-FFEventProviders reports a provider as
    # absent whenever Get-WinEvent -ListProvider does not answer for it, which also covers a
    # denied or broken provider lookup. The severity is 'unknown' either way, and the sentence
    # must not out-claim it.
    $diskEventError = 'None of the candidate storage providers (Ntfs, disk, storahci, stornvme, iaStorAC, iaStorAVC) could be confirmed to exist on this machine, so no storage-error query could be built.'
  } else {
    $ev = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = $diskProviders; Id = @(55,98,130,7,51,153,129,157); StartTime = (Get-Date).AddDays(-7) })
    $diskEventUnreadable = $script:FFLastEventUnreadable
    $diskEventError = $script:FFLastEventError
  }
  if ($ev.Count -gt 0) {
    $sev = 'warning'
    if (@($ev | Where-Object { $_.Id -eq 55 -or $_.Id -eq 98 }).Count -gt 0) { $sev = 'critical' }
    $findings += New-Finding 'disk-error-events' $sev "$($ev.Count) NTFS/disk/storage-controller error event(s) in the System log in the last 7 days." ([ordered]@{ count = $ev.Count; providersQueried = $diskProviders; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($diskEventUnreadable) {
    $findings += New-Finding 'disk-error-events-unreadable' 'unknown' "The System log could not be read for storage error events, so 'no disk errors' cannot be claimed: $diskEventError" ([ordered]@{ providersQueried = $diskProviders; error = $diskEventError })
  }

  # Deep, read-only: online chkdsk scan (Repair-Volume -Scan detects only, never repairs)
  if ($Deep) {
    if ($IsAdmin) {
      try {
        $letter = $sysDrive.TrimEnd(':')
        $scan = Repair-Volume -DriveLetter $letter -Scan -ErrorAction Stop
        if ("$scan" -match 'NoErrorsFound') {
          $findings += New-Finding 'chkdsk-scan-clean' 'info' "Online chkdsk scan of $sysDrive found no errors." ([ordered]@{ result = "$scan" })
        } else {
          $findings += New-Finding 'chkdsk-scan-errors' 'warning' "Online chkdsk scan of $sysDrive reported '$scan' — a spot fix is indicated." ([ordered]@{ result = "$scan" })
        }
      } catch {
        $findings += New-Finding 'chkdsk-scan-failed' 'unknown' "Online chkdsk scan could not run, so the file system was not scanned: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $unhealthy = Get-IssueCount $findings
  $summary = ''
  if ($unhealthy -eq 0) {
    # Never assert drive health that was not actually inspected, and never claim "no disk error
    # events" for a driver stack that was not in the query — name the providers that were.
    $drivePart = "all $($diskEvidence.Count) physical drive(s) report healthy"
    if ($null -ne $diskQueryError) { $drivePart = 'physical drive health could not be inspected (query failed)' }
    elseif ($diskEvidence.Count -eq 0) { $drivePart = 'no physical drives were enumerated' }
    $eventPart = 'no disk error events'
    if ($diskEventUnreadable) { $eventPart = 'disk error events could not be read' }
    else { $eventPart = "no error events from $($diskProviders -join '/')" }
    if ($dirtyKnown) { $summary = "No dirty bit, $eventPart, and $drivePart." }
    elseif ($needsAdmin) { $summary = "$eventPart and $drivePart; the NTFS dirty-bit check needs administrator rights." }
    else { $summary = "$eventPart and $drivePart." }
  } else {
    $summary = "Disk problems detected — see findings ($unhealthy issue(s))."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function ConvertTo-FFHotfixDate {
  <#
    Win32_QuickFixEngineering.InstalledOn is a LOCALE-FORMATTED STRING in the WMI provider, and
    Get-HotFix parses it with the CURRENT culture — which is why on many non-en-US installs the
    cmdlet returns an EMPTY InstalledOn and every hotfix silently disappears from a
    `Where-Object { $_.InstalledOn }` filter. Parse it here instead, under InvariantCulture,
    over the shapes the provider is actually known to emit, including the hex-FILETIME form.
    Returns [datetime] or $null. $null means "could not parse", never "no update".

    KNOWN LIMIT, stated rather than hidden: '01/02/2026' is genuinely ambiguous and no invariant
    parse can resolve it — M/d/yyyy is tried first, so it reads as 2 January. That can be off by
    up to eleven months in the worst case, which is why the resulting finding always reports the
    hotfix id and the `source` rung the date came from, and why the staleness threshold is a
    coarse 60 days rather than something a month of slop could flip.
  #>
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value }
  $s = "$Value".Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  # Hex FILETIME (e.g. "01d1a2b3c4d5e6f7") — some providers report the raw 64-bit value.
  if ($s -match '^(0x)?[0-9A-Fa-f]{16}$') {
    try {
      $hex = $s -replace '^0x', ''
      return [datetime]::FromFileTimeUtc([Convert]::ToInt64($hex, 16)).ToLocalTime()
    } catch {}
  }
  foreach ($fmt in @('M/d/yyyy','MM/dd/yyyy','d/M/yyyy','dd/MM/yyyy','yyyy-MM-dd','yyyyMMdd','dd.MM.yyyy','yyyy/MM/dd',
                     'M/d/yyyy HH:mm:ss','MM/dd/yyyy HH:mm:ss','dd/MM/yyyy HH:mm:ss','yyyy-MM-dd HH:mm:ss')) {
    try { return [datetime]::ParseExact($s, $fmt, $inv) } catch {}
  }
  # WMI CIM_DATETIME (yyyymmddHHMMSS.ffffff+UUU)
  if ($s -match '^(\d{14})\.\d{6}[+-]\d{3}$') {
    try { return [datetime]::ParseExact($Matches[1], 'yyyyMMddHHmmss', $inv) } catch {}
  }
  try { return [datetime]::Parse($s, $inv) } catch {}
  return $null
}

function Get-FFUpdateRecency {
  <#
    When did a real Windows update last install? Layered, and honest when it cannot tell.
      Rung 1: Get-HotFix InstalledOn (works wherever the cmdlet's culture parse works).
      Rung 2: Win32_QuickFixEngineering.InstalledOn parsed with ConvertTo-FFHotfixDate under
              InvariantCulture — this is the rung that survives a non-en-US locale.
      Rung 3: the COM update history's newest SUCCEEDED operation Date (a real DateTime, not text).
              Reported separately as lastOperation and deliberately NOT used for staleness: on
              virtually every machine that history is dominated by Microsoft Defender security-
              intelligence updates that install several times a DAY (verified here), so using it
              for recency would make wu-stale unable to fire at all — trading a false positive
              for a permanent false negative.
    Returns @{ date; source; hotfixId; lastOperation; lastOperationSource; error }.
  #>
  param($History)
  $out = [ordered]@{ date = $null; source = 'none'; hotfixId = $null; lastOperation = $null; lastOperationSource = $null; error = $null }
  try {
    $hf = @(Get-HotFix -ErrorAction Stop)
    $withDate = @($hf | Where-Object { $_.InstalledOn -is [datetime] } | Sort-Object InstalledOn -Descending)
    if ($withDate.Count -gt 0) {
      $out.date = $withDate[0].InstalledOn; $out.source = 'get-hotfix'; $out.hotfixId = "$($withDate[0].HotFixID)"
    }
  } catch { $out.error = "$($_.Exception.Message)" }
  if ($null -eq $out.date) {
    try {
      $best = $null; $bestId = $null
      foreach ($q in @(Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop)) {
        $d = ConvertTo-FFHotfixDate $q.InstalledOn
        if ($null -ne $d -and ($null -eq $best -or $d -gt $best)) { $best = $d; $bestId = "$($q.HotFixID)" }
      }
      if ($null -ne $best) { $out.date = $best; $out.source = 'qfe-invariant-parse'; $out.hotfixId = $bestId }
    } catch { if ($null -eq $out.error) { $out.error = "$($_.Exception.Message)" } }
  }
  try {
    $succeeded = @(@($History) | Where-Object { $_.ResultCode -eq 2 -and $_.Date -is [datetime] } | Sort-Object Date -Descending)
    if ($succeeded.Count -gt 0) { $out.lastOperation = $succeeded[0].Date; $out.lastOperationSource = 'com-update-history' }
  } catch {}
  return $out
}

function Get-FFUpdateDeferral {
  <#
    Is this machine deliberately held back from updates? A deferral, a pause, or a WSUS pin is a
    CONFIGURATION, not a fault, and grading it as one both paints a managed machine yellow and
    unlocks wu-reset / wu-reset-aggressive on a box that needs neither.
    Returns @{ deferred = $bool; reasons = @(); values = @{}; wsus = $null }.
  #>
  $out = [ordered]@{ deferred = $false; reasons = @(); values = [ordered]@{}; wsus = $null }
  $pol = $null
  try { $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop } catch {}
  if ($null -ne $pol) {
    foreach ($n in @('DeferQualityUpdatesPeriodInDays','DeferFeatureUpdatesPeriodInDays','PauseQualityUpdatesStartTime','PauseFeatureUpdatesStartTime','WUServer','TargetReleaseVersionInfo')) {
      $v = $pol.$n
      if ($null -ne $v -and "$v" -ne '' -and "$v" -ne '0') { $out.values[$n] = $v }
    }
    if ($out.values.Contains('DeferQualityUpdatesPeriodInDays')) { $out.reasons += "quality updates deferred by $($out.values['DeferQualityUpdatesPeriodInDays']) day(s) by policy" }
    if ($out.values.Contains('DeferFeatureUpdatesPeriodInDays')) { $out.reasons += "feature updates deferred by $($out.values['DeferFeatureUpdatesPeriodInDays']) day(s) by policy" }
    if ($out.values.Contains('PauseQualityUpdatesStartTime'))    { $out.reasons += "quality updates paused by policy since $($out.values['PauseQualityUpdatesStartTime'])" }
    if ($out.values.Contains('PauseFeatureUpdatesStartTime'))    { $out.reasons += "feature updates paused by policy since $($out.values['PauseFeatureUpdatesStartTime'])" }
    if ($out.values.Contains('WUServer')) { $out.wsus = "$($out.values['WUServer'])"; $out.reasons += "updates are managed by WSUS at $($out.wsus), not by Microsoft Update" }
    if ($out.values.Contains('TargetReleaseVersionInfo')) { $out.reasons += "pinned to Windows release $($out.values['TargetReleaseVersionInfo']) by policy" }
  }
  # User-initiated pause from Settings.
  try {
    $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction Stop
    $expiry = $ux.PauseUpdatesExpiryTime
    if ($null -ne $expiry -and "$expiry" -ne '') {
      $out.values['PauseUpdatesExpiryTime'] = "$expiry"
      $out.reasons += "updates are paused in Settings until $expiry"
    }
  } catch {}
  $out.deferred = ($out.reasons.Count -gt 0)
  return $out
}

function Probe-WindowsUpdate {
  $findings = @(); $needsAdmin = $false

  # Service pipeline. Stopped is normal for demand-start services; Disabled start type is the
  # signal — and a service that is MISSING ENTIRELY is a stronger signal still, which the old
  # `$_.present -and ...` filter swallowed in silence.
  $svc = @(Get-ServiceInfo @('wuauserv','bits','cryptsvc','DoSvc','UsoSvc'))
  $findings += @(New-ServiceQueryFindings -Services $svc)
  $findings += @(New-MissingServiceFindings -Services @($svc | Where-Object { $_.name -in 'wuauserv','bits','cryptsvc' }) -Severity 'critical' -Consequence 'Windows Update cannot run at all without it.')
  $findings += @(New-MissingServiceFindings -Services @($svc | Where-Object { $_.name -in 'DoSvc','UsoSvc' }) -Severity 'warning' -Consequence 'Update download/orchestration will not work normally without it.')
  $disabled = @($svc | Where-Object { $_.present -and $_.startType -eq 'Disabled' })
  if ($disabled.Count -gt 0) {
    $names = @($disabled | ForEach-Object { $_.name }) -join ', '
    $findings += New-Finding 'wu-service-disabled' 'warning' "Update pipeline service(s) disabled: $names — Windows Update cannot work until re-enabled." ([ordered]@{ services = $svc })
  }

  # Failure events, last 30 days (20 = install failure, 31 = scan failure)
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = @(20,31); StartTime = (Get-Date).AddDays(-30) })
  $wuEventUnreadable = $script:FFLastEventUnreadable
  $wuEventError = $script:FFLastEventError
  if ($ev.Count -gt 0) {
    $findings += New-Finding 'wu-failure-events' 'warning' "$($ev.Count) Windows Update failure event(s) in the last 30 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($wuEventUnreadable) {
    $findings += New-Finding 'wu-events-unreadable' 'unknown' "The Windows Update client log could not be read, so 'no recent update failures' cannot be claimed: $wuEventError" ([ordered]@{ error = $wuEventError })
  }

  # Update history via COM (works unelevated) — failure HResults from the last 25 operations
  $historyChecked = $false
  $hist = @()
  try {
    $sess = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
    $hist = @($sess.CreateUpdateSearcher().QueryHistory(0, 25))
    $historyChecked = $true
    # ResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
    $fails = @($hist | Where-Object { $_.ResultCode -eq 4 -or $_.ResultCode -eq 5 })
    if ($fails.Count -gt 0) {
      $hres = @($fails | ForEach-Object { '0x{0:X8}' -f ($_.HResult -band 0xFFFFFFFF) } | Select-Object -Unique)
      $titles = @($fails | Select-Object -First 2 | ForEach-Object { "$($_.Title)" })
      $sev = 'warning'
      $ok = @($hist | Where-Object { $_.ResultCode -eq 2 })
      if ($ok.Count -eq 0 -and $fails.Count -ge 3) { $sev = 'critical' }
      $findings += New-Finding 'wu-history-failures' $sev "$($fails.Count) of the last $($hist.Count) update operations failed (HRESULTs: $($hres -join ', '))." ([ordered]@{ failed = $fails.Count; total = $hist.Count; hresults = $hres; sampleTitles = $titles })
    }
  } catch {}

  # Staleness — only AFTER establishing (a) whether a date could be read at all and
  # (b) whether this machine is deliberately held back by policy.
  $rec = Get-FFUpdateRecency -History $hist
  $defer = Get-FFUpdateDeferral
  $lastHotfix = $null
  $deferralApplied = $false
  if ($null -ne $rec.date) {
    $lastHotfix = $rec.date.ToString('yyyy-MM-dd')
    $ageDays = [int]((Get-Date) - $rec.date).TotalDays
    $evi = [ordered]@{
      lastHotfix = $rec.hotfixId; installedOn = $lastHotfix; ageDays = $ageDays; source = $rec.source
      lastUpdateOperation = (ConvertTo-FFTime $rec.lastOperation); lastUpdateOperationSource = $rec.lastOperationSource
      deferral = $defer
    }
    if ($ageDays -gt 60) {
      if ($defer.deferred) {
        $deferralApplied = $true
        $findings += New-Finding 'wu-deferred-by-policy' 'info' "No update has installed in $ageDays days, but this machine is deliberately held back: $($defer.reasons -join '; '). That is a configuration, not a stuck update stack." $evi
      } else {
        $findings += New-Finding 'wu-stale' 'warning' "No update has installed in $ageDays days (last: $($rec.hotfixId) on $lastHotfix) — updates may be stuck. No deferral, pause, or WSUS pin is in force." $evi
      }
    } elseif ($defer.deferred) {
      $findings += New-Finding 'wu-deferred-by-policy' 'info' "Windows Update is managed on this machine: $($defer.reasons -join '; ')." $evi
      $deferralApplied = $true
    }
  } else {
    $findings += New-Finding 'wu-recency-unknown' 'unknown' "The date of the last installed update could not be determined (Get-HotFix returned no parseable InstalledOn and the Win32_QuickFixEngineering fallback did not yield a date either), so update staleness was NOT assessed." ([ordered]@{
      getHotFixError = $rec.error
      lastUpdateOperation = (ConvertTo-FFTime $rec.lastOperation)
      lastUpdateOperationNote = 'The COM update history is dominated by Defender security-intelligence updates, so it cannot stand in for quality-update recency.'
      deferral = $defer
    })
  }

  # Pending reboot triple check
  $pr = [ordered]@{ cbsRebootPending = $false; wuRebootRequired = $false; pendingFileRenames = $false }
  try { $pr.cbsRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' } catch {}
  try { $pr.wuRebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' } catch {}
  try {
    $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    $pr.pendingFileRenames = ($null -ne $v.PendingFileRenameOperations -and @($v.PendingFileRenameOperations).Count -gt 0)
  } catch {}
  if ($pr.cbsRebootPending -or $pr.wuRebootRequired) {
    $findings += New-Finding 'wu-reboot-pending' 'warning' 'A reboot is pending from servicing or Windows Update — restart before judging update health.' $pr
  } elseif ($pr.pendingFileRenames) {
    # Common and usually benign (installers set it constantly); informational only.
    $findings += New-Finding 'pending-file-renames' 'info' 'PendingFileRenameOperations is set — common after app installs, usually harmless on its own.' $pr
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    # Claim only what was actually verified: how many of the named services exist and are
    # enabled, and whether an install date was readable — never a blanket "look normal".
    $svcPart = Format-ServicePresence -Services $svc -Label 'update services'
    if ($null -ne $lastHotfix) { $summary = "$svcPart; the last update installed on $lastHotfix (source: $($rec.source))." }
    else { $summary = "$svcPart; the date of the last installed update could not be read." }
    if ($deferralApplied) { $summary = $summary + " Windows Update is managed here: $($defer.reasons -join '; ')." }
    if (-not $historyChecked) { $summary = $summary + ' (Update history could not be read.)' }
  } else {
    $summary = "Windows Update shows $issues issue(s) — see findings."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Network {
  $findings = @(); $needsAdmin = $false

  # Link layer. -ErrorAction SilentlyContinue collapsed a FAILED enumeration and a machine with
  # genuinely no physical NIC into the same empty array, and `link = ($up.Count -gt 0)` was then
  # graded from it — the emptiness-equals-measurement trap. Separate the two by whether the
  # enumeration itself completed.
  $adapters = @(); $adapterQueryRan = $false; $adapterQueryError = $null
  try { $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop); $adapterQueryRan = $true }
  catch { $adapterQueryError = "$($_.Exception.Message)" }
  $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
  $adapterEvidence = @()
  foreach ($a in $adapters) {
    $adapterEvidence += [ordered]@{ name = "$($a.Name)"; description = "$($a.InterfaceDescription)"; status = "$($a.Status)"; linkSpeed = "$($a.LinkSpeed)" }
  }
  if (-not $adapterQueryRan) {
    $findings += New-Finding 'adapter-query-failed' 'unknown' "Physical network adapters could not be enumerated (Get-NetAdapter failed), so link state was NOT measured and neither link nor its absence can be claimed: $adapterQueryError" ([ordered]@{ error = $adapterQueryError })
  } elseif ($adapters.Count -eq 0) {
    # Measured, and there is genuinely no physical adapter. Not automatically a fault: -Physical
    # excludes virtual NICs, so a VM or a tunnel-only host can legitimately land here. Whether it
    # matters is decided by the reachability layers below and by the emptiness guard.
    $findings += New-Finding 'no-physical-adapter' 'info' 'The adapter list was read successfully and contains no physical network adapter (Get-NetAdapter -Physical excludes virtual adapters).' ([ordered]@{ adapters = @() })
  } elseif ($up.Count -eq 0) {
    $findings += New-Finding 'no-link' 'critical' 'No physical network adapter has link — check cable/Wi-Fi before anything else.' ([ordered]@{ adapters = $adapterEvidence })
  }

  # Default gateway — BOTH address families. An IPv6-only network (464XLAT cellular, some
  # campus/enterprise networks, a growing share of consumer ISPs) has no 0.0.0.0/0 route at all,
  # and treating that as "no default route" invents a DHCP fault on a perfectly healthy machine.
  # Get-NetRoute THROWS when nothing matches, so "there is no default route" and "the routing
  # table could not be read at all" arrived down the same catch. Swallowing both meant a machine
  # whose NetTCPIP module was stripped, or whose CIM/WMI stack is broken, was told 'no default
  # route ... DHCP/IP configuration problem' at severity CRITICAL about a routing table this
  # probe never actually read — doctrine rule 2 in its fabricated-FAULT direction. The two are
  # separated by error identity: CmdletizationQuery_NotFound_* / ObjectNotFound means the query
  # ran and genuinely matched nothing; anything else means it did not run.
  $gw4 = $null; $gw6 = $null
  $routeQueryRan = $false; $routeQueryError = $null
  foreach ($fam in @(@{ prefix = '0.0.0.0/0'; v = 4 }, @{ prefix = '::/0'; v = 6 })) {
    try {
      $r = Get-NetRoute -DestinationPrefix $fam.prefix -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
      $routeQueryRan = $true
      if ($r) { if ($fam.v -eq 4) { $gw4 = "$($r.NextHop)" } else { $gw6 = "$($r.NextHop)" } }
    } catch {
      $fq = ''; try { $fq = "$($_.FullyQualifiedErrorId)" } catch {}
      $cat = ''; try { $cat = "$($_.CategoryInfo.Category)" } catch {}
      if ($fq -like 'CmdletizationQuery_NotFound*' -or $cat -eq 'ObjectNotFound') {
        # Measured: this family has no default route. Verified error identity on Windows 11 25H2.
        $routeQueryRan = $true
      } elseif ($null -eq $routeQueryError) {
        $routeQueryError = "$($_.Exception.Message)"
      }
    }
  }
  $gw = $gw4
  if (-not $gw) { $gw = $gw6 }
  $gwOk = $false; $gwMeasured = $false; $gwError = $null
  if ($gw) {
    # A gateway that drops ICMP RETURNS $false (measured, and handled by gateway-icmp-blocked
    # below); a throw means the probe itself could not run.
    try { $gwOk = [bool](Test-NetConnection -ComputerName $gw -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop); $gwMeasured = $true }
    catch { $gwOk = $false; $gwError = "$($_.Exception.Message)" }
  } elseif (-not $routeQueryRan) {
    $findings += New-Finding 'route-query-failed' 'unknown' "The routing table could not be read (Get-NetRoute failed for both 0.0.0.0/0 and ::/0), so the presence of a default route was NOT measured and no DHCP/IP fault can be claimed: $routeQueryError" ([ordered]@{ error = $routeQueryError })
  } elseif ($up.Count -gt 0) {
    # Only when BOTH families were successfully queried and both are missing.
    $findings += New-Finding 'no-default-route' 'critical' 'A network adapter is up but there is no default route for either IPv4 (0.0.0.0/0) or IPv6 (::/0) — DHCP/IP configuration problem.' ([ordered]@{ adapters = $adapterEvidence })
  }

  # Raw-IP internet, per family, WITHOUT DNS. Probed over TCP/443 rather than ICMP: ICMP echo is
  # filtered on a large share of real networks (corporate LANs, hotel/campus/captive Wi-Fi, CGNAT,
  # endpoint-protection suites), and a filtered ping is an absence of observation, not a fault.
  #
  # EVERY reachability probe below is TRI-STATE. `catch { $x = $false }` made "the measurement
  # ran and the answer is no" indistinguishable from "the measurement could not run", which is
  # exactly how a machine with no network stack at all reported a green tick. Test-NetConnection
  # -InformationLevel Quiet RETURNS $false for a refused/timed-out connection; it THROWS only
  # when the cmdlet or the stack under it is unavailable (these targets are IP literals, so
  # there is no name for it to fail on). The throw is therefore "unmeasured", not "unreachable".
  $ip4Ok = $false; $ip6Ok = $false; $ip4Icmp = $false
  $ip4Measured = $false; $ip6Measured = $false; $icmpMeasured = $false
  $netProbeError = $null
  try { $ip4Ok = [bool](Test-NetConnection -ComputerName '1.1.1.1' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop); $ip4Measured = $true }
  catch { $ip4Ok = $false; if ($null -eq $netProbeError) { $netProbeError = "$($_.Exception.Message)" } }
  try { $ip6Ok = [bool](Test-NetConnection -ComputerName '2606:4700:4700::1111' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop); $ip6Measured = $true }
  catch { $ip6Ok = $false; if ($null -eq $netProbeError) { $netProbeError = "$($_.Exception.Message)" } }
  try { $ip4Icmp = [bool](Test-NetConnection -ComputerName '1.1.1.1' -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop); $icmpMeasured = $true }
  catch { $ip4Icmp = $false; if ($null -eq $netProbeError) { $netProbeError = "$($_.Exception.Message)" } }
  $ipOk = ($ip4Ok -or $ip6Ok)
  $ipMeasured = ($ip4Measured -or $ip6Measured)

  # DNS is the one probe whose THROW is itself a measurement: a resolver that answers SERVFAIL /
  # NXDOMAIN / times out throws, and that is a real "no". Only a MISSING cmdlet (the DnsClient
  # module stripped, a constrained host) leaves DNS unmeasured.
  $dnsOk = $false; $dnsMeasured = $false; $dnsError = $null
  try { $null = Resolve-DnsName -Name 'microsoft.com' -Type A_AAAA -ErrorAction Stop; $dnsOk = $true; $dnsMeasured = $true }
  catch {
    $dnsOk = $false
    $dnsError = "$($_.Exception.Message)"
    $dnsFq = ''; try { $dnsFq = "$($_.FullyQualifiedErrorId)" } catch {}
    $dnsMeasured = -not (($dnsFq -like 'CommandNotFoundException*') -or ($_.Exception -is [System.Management.Automation.CommandNotFoundException]))
    if (-not $dnsMeasured -and $null -eq $netProbeError) { $netProbeError = $dnsError }
  }

  # NCSI-style captive-portal probe (§3.4): HTTP reachability of the connectivity endpoint.
  # This target is a NAME, so a throw here can also mean "the name did not resolve" — either
  # way the HTTP layer was not measured, and the DNS layer above is what reports the resolver.
  $ncsiOk = $false; $ncsiMeasured = $false
  try { $ncsiOk = [bool](Test-NetConnection -ComputerName 'www.msftconnecttest.com' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop); $ncsiMeasured = $true }
  catch { $ncsiOk = $false; if ($null -eq $netProbeError) { $netProbeError = "$($_.Exception.Message)" } }

  # Configured DNS servers (both families). A bare catch here made an unreadable configuration
  # look identical to "no resolvers are configured", so whether the read happened is recorded.
  $dnsServers = @()
  $dnsServersRead = $false; $dnsServersError = $null
  try {
    $dnsServers = @(Get-DnsClientServerAddress -ErrorAction Stop |
      Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
    $dnsServersRead = $true
  } catch { $dnsServersError = "$($_.Exception.Message)" }

  # Positive evidence that traffic actually flows, independent of ICMP.
  $reachable = ($dnsOk -or $ncsiOk -or $ipOk)

  $layers = [ordered]@{
    # link is TRI-STATE: $null when the adapter enumeration itself failed. $false here means
    # "measured, and no adapter has link"; it must never mean "nobody looked".
    link = $(if ($adapterQueryRan) { ($up.Count -gt 0) } else { $null })
    gateway = $gwOk; internetByIp = $ipOk; dns = $dnsOk; ncsiHttp = $ncsiOk
    gatewayAddress = $gw; dnsServers = $dnsServers
    ipv4 = [ordered]@{ defaultRoute = $gw4; tcp443 = $ip4Ok; icmp = $ip4Icmp }
    ipv6 = [ordered]@{ defaultRoute = $gw6; tcp443 = $ip6Ok }
    family = $(if ($gw4 -and $gw6) { 'dual-stack' } elseif ($gw6) { 'ipv6-only' } elseif ($gw4) { 'ipv4-only' } else { 'none' })
    # ADDITIVE. Which of the booleans above are actual measurements. A $false layer whose
    # `measured` entry is $false carries NO information about this machine.
    measured = [ordered]@{
      link = $adapterQueryRan; route = $routeQueryRan; gateway = $gwMeasured
      ipv4Tcp443 = $ip4Measured; ipv6Tcp443 = $ip6Measured; icmp = $icmpMeasured
      dns = $dnsMeasured; ncsiHttp = $ncsiMeasured; dnsServerList = $dnsServersRead
    }
    errors = [ordered]@{ adapter = $adapterQueryError; route = $routeQueryError; gateway = $gwError; probe = $netProbeError; dns = $dnsError; dnsServerList = $dnsServersError }
  }

  # ICMP filtered while traffic flows — say so instead of inventing a router fault. This branch
  # is placed FIRST so it can never be shadowed by the gateway-unreachable arm below.
  # Requires the ping to have ACTUALLY RUN: an unmeasured ICMP probe is not a filtered one.
  $icmpFiltered = ($icmpMeasured -and (-not $ip4Icmp) -and $reachable)
  if ($icmpFiltered) {
    $findings += New-Finding 'icmp-filtered' 'info' 'ICMP echo is filtered on this network (ping to 1.1.1.1 fails) while TCP/DNS/HTTP checks succeed — connectivity is fine; the ping-based layers simply could not be measured.' $layers
  }

  # THE FAULT ARMS. Every one of them now requires the signal it is accusing to have been
  # MEASURED: an unmeasured probe left its variable at $false, and `-not $false` would otherwise
  # let each of these assert a fault about something nobody looked at.
  # The discriminator: IP works but DNS fails => resolver problem, not connectivity.
  if ($ipOk -and $dnsMeasured -and -not $dnsOk) {
    $findings += New-Finding 'dns-broken' 'critical' 'The internet is reachable by raw IP but name resolution fails — this is a DNS problem (flush DNS / change resolver), not a connectivity problem.' $layers
  } elseif ($ipMeasured -and -not $ipOk -and -not $reachable -and $gwOk) {
    $findings += New-Finding 'wan-down' 'critical' 'The gateway responds but the internet is unreachable — the problem is upstream (modem/ISP), not this PC.' $layers
  } elseif ($ipMeasured -and -not $ipOk -and -not $reachable -and $gw -and $gwMeasured -and -not $gwOk -and $up.Count -gt 0) {
    $findings += New-Finding 'gateway-unreachable' 'critical' 'Link is up, the default gateway does not respond, and no TCP, DNS, or HTTP check succeeded either — local network or router problem.' $layers
  }

  # IP + DNS work but the NCSI HTTP endpoint does not: captive portal / HTTP filtering.
  if ($ipOk -and $dnsOk -and $ncsiMeasured -and -not $ncsiOk) {
    $findings += New-Finding 'captive-portal-suspected' 'warning' 'Raw IP and DNS work but the NCSI connectivity endpoint is unreachable over HTTP — possible captive portal or HTTP-level filtering.' $layers
  }

  # Gateway drops ICMP while traffic flows: informational, not a fault.
  if ($gw -and $gwMeasured -and -not $gwOk -and $reachable) {
    $findings += New-Finding 'gateway-icmp-blocked' 'info' 'The default gateway does not answer ICMP ping while internet or DNS still works — the router likely just drops ping; traffic itself is flowing.' $layers
  }

  # ---- Layer roll-up, and THE EMPTINESS GUARD ----
  # $okLayers is the list the healthy summary is built from. An EMPTY list used to render as
  # "Healthy network layers (none): ." and the category graded 'ok' — a green tick on a machine
  # with no network at all (reproduced with Get-NetAdapter returning nothing, Get-NetRoute
  # answering ObjectNotFound for both families, and Test-NetConnection / Resolve-DnsName all
  # throwing). Zero successful measurements is NEVER health. It is one of exactly two things,
  # and they are graded differently: nothing could be measured -> 'unknown'; everything was
  # measured and everything is down -> a fault.
  $okLayers = @()
  if ($adapterQueryRan -and $up.Count -gt 0) { $okLayers += 'link' }
  if ($gwOk) { $okLayers += 'gateway' }
  if ($ip4Ok) { $okLayers += 'IPv4 internet (TCP 443)' }
  if ($ip6Ok) { $okLayers += 'IPv6 internet (TCP 443)' }
  if ($dnsOk) { $okLayers += 'DNS resolution' }
  if ($ncsiOk) { $okLayers += 'HTTP (NCSI)' }

  # Layers whose measurement could not run at all. The gateway ping is only counted when there
  # WAS a gateway to ping — no default route is a measured absence, not an unmeasured layer.
  $unmeasuredLayers = @()
  if (-not $adapterQueryRan) { $unmeasuredLayers += 'link' }
  if (-not $routeQueryRan)   { $unmeasuredLayers += 'default route' }
  if ($gw -and -not $gwMeasured) { $unmeasuredLayers += 'gateway' }
  if (-not $ip4Measured)     { $unmeasuredLayers += 'IPv4 internet (TCP 443)' }
  if (-not $ip6Measured)     { $unmeasuredLayers += 'IPv6 internet (TCP 443)' }
  if (-not $dnsMeasured)     { $unmeasuredLayers += 'DNS resolution' }
  if (-not $ncsiMeasured)    { $unmeasuredLayers += 'HTTP (NCSI)' }

  $guardEvi = [ordered]@{ okLayers = $okLayers; unmeasuredLayers = $unmeasuredLayers; layers = $layers }
  if ($okLayers.Count -eq 0) {
    if ($unmeasuredLayers.Count -gt 0) {
      $findings += New-Finding 'network-unmeasured' 'unknown' "No network layer could be confirmed working, and $($unmeasuredLayers.Count) of them could not be measured at all ($($unmeasuredLayers -join ', ')). Network health is UNKNOWN, not healthy — nothing here says this machine's network is either working or broken." $guardEvi
    } elseif ((Get-IssueCount $findings) -eq 0) {
      # Everything was measured, everything answered no, and no arm above named it.
      $findings += New-Finding 'network-all-layers-down' 'critical' 'Every network layer was measured and none of them responded: no adapter has link, no default route exists, and no TCP, DNS, or HTTP check succeeded. This machine has no working network path.' $guardEvi
    }
  } elseif ($unmeasuredLayers.Count -gt 0) {
    $findings += New-Finding 'network-partially-unmeasured' 'unknown' "$($unmeasuredLayers.Count) network layer(s) could not be measured ($($unmeasuredLayers -join ', ')), so the layers that did pass do not add up to a clean bill of health." $guardEvi
  }

  $summary = ''
  if ((Get-IssueCount $findings) -eq 0) {
    if ($okLayers.Count -eq 0) {
      # Guaranteed to be the unmeasured case: the all-down case raised a critical above.
      $summary = "No network layer could be confirmed working, and $($unmeasuredLayers.Count) of them could not be measured at all ($($unmeasuredLayers -join ', ')). This machine's network health is UNKNOWN — not healthy."
    } else {
      # Build the healthy summary from the per-layer results — never assert a layer that did not
      # pass, and label a ping-derived layer as NOT MEASURABLE rather than dropping it silently.
      $summary = "Healthy network layers ($($layers.family)): $($okLayers -join ', ')."
      if ($unmeasuredLayers.Count -gt 0) { $summary = $summary + " Not measured: $($unmeasuredLayers -join ', ')." }
      if ($icmpFiltered) { $summary = $summary + ' ICMP echo is filtered here, so the ping-based gateway/internet layers were not measurable.' }
      elseif ($gw -and $gwMeasured -and -not $gwOk) { $summary = $summary + ' Gateway ICMP is blocked/unreachable while traffic flows normally.' }
    }
  } else {
    # Only a MEASURED failure may be named as broken; the rest is listed as not measured.
    $broken = @()
    if ($adapterQueryRan -and $up.Count -eq 0 -and $adapters.Count -gt 0) { $broken += 'link' }
    if ($gwMeasured -and -not $gwOk -and -not $icmpFiltered) { $broken += 'gateway' }
    if ($ipMeasured -and -not $ipOk) { $broken += 'internet' }
    if ($dnsMeasured -and -not $dnsOk) { $broken += 'DNS' }
    if ($ncsiMeasured -and -not $ncsiOk) { $broken += 'HTTP (NCSI)' }
    if ($broken.Count -gt 0) { $summary = "Network problem at: $($broken -join ', ') — see findings for which layer to fix." }
    else { $summary = 'Network findings were raised without any single layer measuring as broken — see findings.' }
    if ($unmeasuredLayers.Count -gt 0) { $summary = $summary + " Not measured: $($unmeasuredLayers -join ', ')." }
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Store {
  $findings = @(); $needsAdmin = $false

  # Which Windows is this? Enterprise/IoT LTSC and every Server SKU ship WITHOUT the Microsoft
  # Store by design, so an absent Store there is the shipped configuration, not a fault — and
  # grading it as one escalates into offering store-reregister-all, an AGGRESSIVE repair with an
  # enforced restore point that re-registers every Appx package on the box to fix nothing.
  $edition = Get-FFEdition
  $storeCap = Test-FFCapability -Name 'Store'
  $storeByDesignAbsent = (($edition.isLtsc -eq $true) -or ($edition.isServer -eq $true) -or ($storeCap.available -eq $false))

  # Store package status (per-user query works unelevated; -AllUsers needs admin)
  $pkgStatus = $null
  $pkgQueryFailed = $false
  $pkgQueryError = $null
  try {
    if ($IsAdmin) { $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 }
    else          { $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 }
    if (-not $pkg) {
      $evi = [ordered]@{ editionId = $edition.editionId; installationType = $edition.installationType; isLtsc = $edition.isLtsc; storeCapability = $storeCap }
      if ($storeByDesignAbsent) {
        $findings += New-Finding 'store-not-in-this-edition' 'info' "This Windows edition ($($edition.editionId), $($edition.installationType)) ships without the Microsoft Store by design — there is nothing broken and nothing to re-register." $evi
      } else {
        $findings += New-Finding 'store-missing' 'warning' 'The Microsoft Store package is not installed for this user, and this edition is one that normally ships with it.' $evi
      }
    } else {
      $pkgStatus = "$($pkg.Status)"
      if ($pkgStatus -ne 'Ok') {
        $findings += New-Finding 'store-package-broken' 'warning' "The Microsoft Store package reports status '$pkgStatus' — re-registration is indicated." ([ordered]@{ name = "$($pkg.Name)"; version = "$($pkg.Version)"; status = $pkgStatus })
      }
    }
  } catch {
    # A failed query is NOT "no problems detected" — the Appx stack itself may be broken or
    # stripped, which is precisely the population the Store repairs exist for.
    $pkgQueryFailed = $true
    $pkgQueryError = "$($_.Exception.Message)"
    $findings += New-Finding 'store-query-failed' 'unknown' "The Microsoft Store package could not be queried, so its state is UNKNOWN rather than healthy: $pkgQueryError" ([ordered]@{ error = $pkgQueryError; editionId = $edition.editionId })
  }

  # Dependency services (demand-start; Disabled is the failure signal; deleted is worse)
  $svc = @(Get-ServiceInfo @('AppXSvc','ClipSVC','InstallService','DoSvc'))
  $findings += @(New-ServiceQueryFindings -Services $svc)
  if (-not $storeByDesignAbsent) {
    $findings += @(New-MissingServiceFindings -Services @($svc | Where-Object { $_.name -in 'AppXSvc','ClipSVC' }) -Severity 'critical' -Consequence 'App deployment and licensing cannot work at all without it.')
    $findings += @(New-MissingServiceFindings -Services @($svc | Where-Object { $_.name -in 'InstallService','DoSvc' }) -Severity 'warning' -Consequence 'Store installs and update downloads will not work normally without it.')
  }
  $disabled = @($svc | Where-Object { $_.present -and $_.startType -eq 'Disabled' })
  if ($disabled.Count -gt 0) {
    $names = @($disabled | ForEach-Object { $_.name }) -join ', '
    $findings += New-Finding 'store-service-disabled' 'warning' "Store dependency service(s) disabled: $names — Store installs/licensing will fail." ([ordered]@{ services = $svc })
  }

  # App deployment errors, last 7 days
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-7) })
  $appxUnreadable = $script:FFLastEventUnreadable
  $appxError = $script:FFLastEventError
  if ($ev.Count -ge 5) {
    $findings += New-Finding 'appx-deploy-errors' 'warning' "$($ev.Count) app deployment error(s) in the last 7 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($ev.Count -gt 0) {
    $findings += New-Finding 'appx-deploy-errors-few' 'info' "$($ev.Count) app deployment error(s) in the last 7 days — occasional errors here are normal." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($appxUnreadable) {
    $findings += New-Finding 'appx-log-unreadable' 'unknown' "The AppX deployment log could not be read, so 'no deployment errors' cannot be claimed: $appxError" ([ordered]@{ error = $appxError })
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    $svcPart = Format-ServicePresence -Services $svc -Label 'Store dependency services'
    if ($pkgQueryFailed) {
      $summary = "$svcPart, but the Store package itself could not be queried ($pkgQueryError) — its state is unknown."
    } elseif ($storeByDesignAbsent -and $null -eq $pkgStatus) {
      $summary = "This Windows edition ($($edition.editionId)) ships without the Microsoft Store; $svcPart."
    } elseif ($pkgStatus -eq 'Ok') {
      $summary = "The Store package reports Ok and $svcPart."
    } else {
      $summary = "$svcPart; the Store package reported no status."
    }
  } else {
    $summary = "Microsoft Store shows $issues issue(s) — see findings."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Search {
  $findings = @(); $needsAdmin = $false

  # Indexer service. A DELETED WSearch is a fault, not a footnote: at severity 'info' the
  # category still graded 'ok' and the summary claimed "the search indexer is running normally"
  # about a service that does not exist.
  $svc = @(Get-ServiceInfo @('WSearch'))[0]
  if ($svc.measured -eq $false) {
    # The query never ran. `-not $svc.present` used to be true here and claimed a deleted service.
    $findings += @(New-ServiceQueryFindings -Services @($svc))
  } elseif ($svc.present -eq $false) {
    $findings += New-Finding 'wsearch-missing' 'warning' 'The Windows Search service (WSearch) does not exist on this system — it was deleted, not merely disabled. Search and Start-menu results will not work, and Set-Service cannot recreate it; this usually comes from a debloat/"gaming optimizer" script.' ([ordered]@{ service = 'WSearch'; present = $false })
  } elseif ($svc.startType -eq 'Disabled') {
    $findings += New-Finding 'wsearch-disabled' 'warning' 'The Windows Search service is disabled — search and Start-menu results will not work.' $svc
  } elseif ($svc.status -ne 'Running') {
    $findings += New-Finding 'wsearch-not-running' 'warning' "The Windows Search service is $($svc.status) (start type: $($svc.startType))." $svc
  }

  # Indexer / shell host processes. SearchHost only lives while the search UI is open,
  # so its absence is NOT flagged; a missing StartMenuExperienceHost is only informational.
  # The process list must be told apart from a FAILED process enumeration: an empty $running from
  # a broken/denied Get-Process would otherwise fire 'indexer-process-missing' at severity
  # WARNING — a fabricated "the indexer may be crashing" about a list nobody could read.
  # -ErrorAction SilentlyContinue is kept for the per-name "no such process" case (that IS the
  # measurement); the enumeration is considered to have run when the call itself returned.
  $procNames = @('SearchIndexer','SearchHost','StartMenuExperienceHost')
  $running = @()
  $procQueryRan = $false; $procQueryError = $null
  try {
    $running = @(Get-Process -Name $procNames -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Select-Object -Unique)
    $procQueryRan = $true
  } catch { $procQueryError = "$($_.Exception.Message)" }
  if (-not $procQueryRan) {
    $findings += New-Finding 'process-query-failed' 'unknown' "The running-process list could not be read, so whether the search/Start-menu host processes are running was NOT measured: $procQueryError" ([ordered]@{ processes = $procNames; error = $procQueryError })
  } else {
    if ($svc.status -eq 'Running' -and $running -notcontains 'SearchIndexer') {
      $findings += New-Finding 'indexer-process-missing' 'warning' 'WSearch is running but the SearchIndexer process is not — the indexer may be crashing.' ([ordered]@{ runningProcesses = $running })
    }
    if ($running -notcontains 'StartMenuExperienceHost') {
      $findings += New-Finding 'startmenu-host-not-running' 'info' 'StartMenuExperienceHost is not currently running (it normally restarts on demand).' ([ordered]@{ runningProcesses = $running })
    }
  }

  # Index catalog size anomaly (Windows.edb, or Windows.db on newer builds).
  # The Search\Data tree is admin-ACLed: Test-Path returns $false on access-denied,
  # so real denial must be told apart from a genuinely missing file.
  $idxDir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
  $idxFile = $null
  $idxDenied = $false
  foreach ($candidate in @('Windows.edb','Windows.db')) {
    $p = Join-Path $idxDir $candidate
    try { $idxFile = Get-Item -Path $p -Force -ErrorAction Stop; break }
    catch {
      # Decided by exception TYPE / category / HRESULT, never by matching the English word
      # 'denied' — see Test-FFAccessDenied in _lib.ps1.
      if (Test-FFAccessDenied -ErrorRecord $_) { $idxDenied = $true }
    }
  }
  if ($idxDenied -and $null -eq $idxFile) {
    if (-not $IsAdmin) { $needsAdmin = $true }
  }
  if ($null -ne $idxFile) {
    $sizeGB = [math]::Round($idxFile.Length / 1GB, 2)
    if ($idxFile.Length -eq 0) {
      $findings += New-Finding 'index-empty' 'warning' "The search index file ($($idxFile.Name)) is 0 bytes — the index is empty or corrupt." ([ordered]@{ path = "$($idxFile.FullName)"; sizeGB = $sizeGB })
    } elseif ($idxFile.Length -gt 10GB) {
      $findings += New-Finding 'index-bloated' 'warning' "The search index file is $sizeGB GB (>10 GB) — a rebuild is indicated." ([ordered]@{ path = "$($idxFile.FullName)"; sizeGB = $sizeGB })
    }
  } elseif ($svc.status -eq 'Running' -and -not $idxDenied) {
    $findings += New-Finding 'index-file-not-found' 'info' 'The search index database file was not found at its default location.' ([ordered]@{ searched = $idxDir })
  }

  # Windows Search provider errors in the Application log (§3.6), last 7 days
  $searchErrs = @(Get-FFEvents -Filter @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Search'; Level = @(1,2); StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20)
  $searchLogUnreadable = $script:FFLastEventUnreadable
  $searchLogError = $script:FFLastEventError
  if ($searchErrs.Count -ge 3) {
    $findings += New-Finding 'search-provider-errors' 'warning' "$($searchErrs.Count) Windows Search provider error(s) in the Application log in the last 7 days." ([ordered]@{ count = $searchErrs.Count; sample = @(ConvertTo-FFEventEvidence -Events $searchErrs -First 3) })
  } elseif ($searchErrs.Count -gt 0) {
    $findings += New-Finding 'search-provider-errors-few' 'info' "$($searchErrs.Count) Windows Search provider error(s) in the last 7 days — occasional entries here are normal." ([ordered]@{ count = $searchErrs.Count; sample = @(ConvertTo-FFEventEvidence -Events $searchErrs -First 3) })
  } elseif ($searchLogUnreadable) {
    # The summary already mentioned this, but with no 'unknown' FINDING the category could still
    # resolve to a green 'ok' off an empty result from a log that was never read.
    $findings += New-Finding 'search-log-unreadable' 'unknown' "The Application log could not be read for Windows Search provider errors, so 'no search provider errors' cannot be claimed: $searchLogError" ([ordered]@{ error = $searchLogError })
  }

  # Shell host crashes (Application log, Event 1000), last 7 days.
  # Capped; when the cap is hit the count is honestly worded as "at least N".
  #
  # Matched on the NAMED EventData fields (AppName / AppPath / ModuleName), not on $_.Message.
  # Message is rendered from the WER provider's MUI resources: it is localized, and it comes back
  # $null whenever those resources cannot be rendered for the current UI culture (partially
  # installed language packs, Server Core, some in-place-upgraded localized installs) — in which
  # case a text match silently counts ZERO crashes on a machine whose Start menu is crash-looping.
  # $_.Message stays as a documented second rung so nothing is lost where EventData is absent.
  $crashCap = 256
  $shellHosts = @('SearchHost','StartMenuExperienceHost','SearchIndexer','ShellExperienceHost')
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddDays(-7) } -MaxEvents $crashCap)
  $crashLogUnreadable = $script:FFLastEventUnreadable
  $crashLogError = $script:FFLastEventError
  $crashes = @(); $matchedByData = 0; $matchedByMessage = 0; $unmatchable = 0
  foreach ($e in $ev) {
    $map = Get-FFEventDataMap -Event $e
    $hit = $false; $viaData = $false
    foreach ($k in @('AppName','param1','ModuleName','param4','AppPath')) {
      if ($map.ContainsKey($k) -and $map[$k]) {
        $viaData = $true
        foreach ($h in $shellHosts) {
          if ("$($map[$k])".IndexOf($h, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
        }
      }
      if ($hit) { break }
    }
    if ($hit) { $crashes += $e; $matchedByData++; continue }
    if ($viaData) { continue }   # EventData was readable and simply did not name a shell host
    # Rung 2: the rendered message, when EventData carried nothing usable.
    if ($e.Message) {
      $mm = $false
      foreach ($h in $shellHosts) { if ("$($e.Message)".IndexOf($h, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $mm = $true; break } }
      if ($mm) { $crashes += $e; $matchedByMessage++ }
    } else {
      $unmatchable++
    }
  }
  $crashEvi = [ordered]@{ count = $crashes.Count; scannedEvents = $ev.Count; scanCap = $crashCap; matchedByEventData = $matchedByData; matchedByMessage = $matchedByMessage; unreadableEvents = $unmatchable; sample = @(ConvertTo-FFEventEvidence -Events $crashes -First 3) }
  if ($crashes.Count -gt 0) {
    $countText = "$($crashes.Count)"
    if ($ev.Count -ge $crashCap) { $countText = "at least $($crashes.Count)" }
    $findings += New-Finding 'shell-host-crashes' 'warning' "$countText crash(es) of search/Start-menu hosts in the last 7 days." $crashEvi
  } elseif ($crashLogUnreadable) {
    $findings += New-Finding 'shell-crash-log-unreadable' 'unknown' "The Application log could not be read, so the shell-host crash count is UNKNOWN rather than zero: $crashLogError" ([ordered]@{ error = $crashLogError })
  } elseif ($ev.Count -gt 0 -and $unmatchable -eq $ev.Count) {
    $findings += New-Finding 'shell-crash-count-undetermined' 'unknown' "$($ev.Count) application-crash event(s) were found in the last 7 days but none of them exposed a readable faulting-application name (no EventData fields and no renderable message), so the shell-host crash count could not be determined." $crashEvi
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    $svcPart = 'the Windows Search service is present'
    if ($svc.measured -eq $false) { $svcPart = 'the Windows Search service could not be queried, so its state is unknown' }
    elseif ($svc.present -eq $false) { $svcPart = 'the Windows Search service is MISSING' }
    elseif ($svc.status -eq 'Running') { $svcPart = 'the search indexer is running' }
    else { $svcPart = "the Windows Search service is $($svc.status)" }
    $crashPart = 'no shell-host crashes were logged in the last 7 days'
    if ($crashLogUnreadable) { $crashPart = 'shell-host crashes could not be counted (the Application log was unreadable)' }
    $summary = "$svcPart and $crashPart."
    if ($searchLogUnreadable) { $summary = $summary + " Search provider errors could not be read ($searchLogError)." }
    if ($needsAdmin) { $summary = $summary + ' The index-size check needs administrator rights.' }
  } else { $summary = "Search/Start menu shows $issues issue(s) — see findings." }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Printing {
  $findings = @(); $needsAdmin = $false

  $svc = @(Get-ServiceInfo @('Spooler'))[0]
  if ($svc.measured -eq $false) {
    # The query never ran; `-not $svc.present` used to be true here and claimed a deleted service.
    $findings += @(New-ServiceQueryFindings -Services @($svc))
  } elseif ($svc.present -eq $false) {
    # Deleted, not disabled. Unlike spooler-disabled (deliberately 'info' — turning the spooler
    # off is a legitimate gaming-rig / PrintNightmare choice reversible from services.msc), a
    # deleted service cannot be brought back with Set-Service, so it is reported as a fault.
    $findings += New-Finding 'Spooler-missing' 'warning' 'The Print Spooler service (Spooler) does not exist on this system — it was deleted, not merely disabled. Printing will not work, and Set-Service cannot recreate it; this usually comes from a debloat/"gaming optimizer" script. If you removed it deliberately, nothing here is broken.' ([ordered]@{ service = 'Spooler'; present = $false })
  } elseif ($svc.present -and $svc.status -ne 'Running' -and $svc.startType -eq 'Automatic') {
    $findings += New-Finding 'spooler-not-running' 'warning' "The Print Spooler service is $($svc.status) but set to start automatically." $svc
  } elseif ($svc.present -and $svc.startType -eq 'Disabled') {
    $findings += New-Finding 'spooler-disabled' 'info' 'The Print Spooler service is disabled (intentional on some gaming rigs; printing will not work).' $svc
  }

  # Stuck spool files (directory is admin-ACLed; degrade gracefully)
  $spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
  $spoolError = $null
  try {
    $files = @(Get-ChildItem -Path $spoolDir -File -ErrorAction Stop)
    if ($files.Count -gt 0) {
      $oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
      $findings += New-Finding 'spool-files-present' 'warning' "$($files.Count) file(s) sitting in the spool folder (oldest: $($oldest.ToString('s'))) — possible stuck print jobs." ([ordered]@{ count = $files.Count; oldest = $oldest.ToString('s') })
    }
  } catch {
    $spoolError = "$($_.Exception.Message)"
    if (Test-FFAccessDenied $_) {
      # Expected unelevated: the folder is admin-ACLed. 'needs-admin' already means "elevate me
      # and I will know", so this does not additionally need an 'unknown'.
      if (-not $IsAdmin) { $needsAdmin = $true } else {
        $findings += New-Finding 'spool-folder-unreadable' 'unknown' "The print spool folder was unreadable EVEN WHEN ELEVATED, so stuck spool files were not checked: $spoolError" ([ordered]@{ path = $spoolDir; error = $spoolError })
      }
    } else {
      # Not a permission problem — e.g. the folder is gone, which is itself a signal.
      $findings += New-Finding 'spool-folder-unreadable' 'unknown' "The print spool folder could not be read, so stuck spool files were not checked: $spoolError" ([ordered]@{ path = $spoolDir; error = $spoolError })
    }
  }

  # Printers in Error/Offline state + stuck jobs via the print-queue API (§3.7).
  # Get-PrintJob works without admin, so the stuck-job signal survives even when
  # the admin-ACLed spool folder above is unreadable.
  #
  # THE BUG THIS REPLACED: the whole enumeration sat inside a bare `catch {}`. Get-Printer
  # throws in exactly the situations this probe exists to detect —
  #   * the Spooler is stopped or disabled (the RPC endpoint is simply not there),
  #   * PrintManagement / the Printing-Client feature has been stripped by a "gaming
  #     debloat" script, so Get-Printer is not even a command,
  #   * printer enumeration is blocked by policy.
  # ...and the swallow produced ZERO findings, so Add-UnknownNote never fired, the summary
  # then asserted "no printers were enumerated; no stuck print jobs" AS FACT, and elevated
  # the whole category resolved to a green 'ok'. A failed measurement rendered as healthy is
  # the worst class of bug in this codebase (docs/GAUNTLET.md rule 2). Both the printer
  # enumeration and the per-printer job query now record whether they actually ran, and the
  # healthy summary below may only speak about what was actually read.
  $printerEvidence = @()
  $stuckJobs = @()
  $printerQueryRan = $false
  $printerQueryError = $null
  $printerQueryKind = $null
  $jobQueryFailures = @()
  try {
    $printerList = @(Get-Printer -ErrorAction Stop)
    $printerQueryRan = $true          # set only AFTER the enumeration itself succeeded
    foreach ($p in $printerList) {
      $st = "$($p.PrinterStatus)"
      $printerEvidence += [ordered]@{ name = "$($p.Name)"; status = $st }
      if ($st -match 'Error|Offline') {
        $findings += New-Finding 'printer-error-state' 'warning' "Printer '$($p.Name)' is in state '$st'." ([ordered]@{ name = "$($p.Name)"; status = $st })
      }
      try {
        foreach ($j in @(Get-PrintJob -PrinterName $p.Name -ErrorAction Stop)) {
          if ("$($j.JobStatus)" -match 'Error|Blocked') {
            $sub = $null
            if ($j.SubmittedTime) { $sub = $j.SubmittedTime.ToString('s') }
            $stuckJobs += [ordered]@{ printer = "$($p.Name)"; jobId = $j.Id; document = "$($j.DocumentName)"; jobStatus = "$($j.JobStatus)"; submitted = $sub }
          }
        }
      } catch {
        # A per-printer job query can fail for virtual/offline queues. That is not fatal, but
        # it does mean this queue was NOT checked for stuck jobs — record it, do not swallow it.
        $jobQueryFailures += [ordered]@{ printer = "$($p.Name)"; error = "$($_.Exception.Message)" }
      }
    }
  } catch {
    $printerQueryError = "$($_.Exception.Message)"
    if ($_.CategoryInfo -and "$($_.CategoryInfo.Category)" -eq 'ObjectNotFound' -and "$($_.FullyQualifiedErrorId)" -like 'CommandNotFoundException*') {
      $printerQueryKind = 'cmdlet-missing'
    } elseif (Test-FFAccessDenied $_) {
      $printerQueryKind = 'access-denied'
    } else {
      $printerQueryKind = 'query-failed'
    }
  }
  if ($stuckJobs.Count -gt 0) {
    $findings += New-Finding 'print-jobs-stuck' 'warning' "$($stuckJobs.Count) print job(s) report an Error/Blocked status — the queue is stuck." ([ordered]@{ count = $stuckJobs.Count; jobs = $stuckJobs })
  }
  if (-not $printerQueryRan) {
    $why = 'Get-Printer failed'
    if ($printerQueryKind -eq 'cmdlet-missing') {
      $why = 'the Get-Printer cmdlet does not exist here — the PrintManagement module / Printing-Client feature has been removed, which is something debloat scripts do'
    } elseif ($printerQueryKind -eq 'access-denied') {
      $why = 'printer enumeration was denied'
    } elseif ($svc.present -and ("$($svc.status)" -ne 'Running')) {
      $why = "printer enumeration failed while the Print Spooler service is $($svc.status) — Get-Printer talks to the spooler, so it cannot answer while the spooler is not running"
    } elseif ($svc.present -eq $false) {
      $why = 'printer enumeration failed and the Print Spooler service does not exist'
    } elseif ($svc.measured -eq $false) {
      $why = 'printer enumeration failed, and the Print Spooler service could not be queried either, so neither signal was measured'
    }
    if ($printerQueryKind -eq 'access-denied' -and -not $IsAdmin) { $needsAdmin = $true }
    $findings += New-Finding 'printer-enumeration-failed' 'unknown' "Installed printers and their print queues could not be enumerated, so neither 'no printers are in an error state' nor 'no stuck print jobs' can be claimed: $why ($printerQueryError)." ([ordered]@{ errorKind = $printerQueryKind; error = $printerQueryError; spoolerPresent = $svc.present; spoolerStatus = "$($svc.status)"; spoolerStartType = "$($svc.startType)" })
  } elseif ($jobQueryFailures.Count -gt 0) {
    $names = @($jobQueryFailures | ForEach-Object { $_.printer }) -join ', '
    $findings += New-Finding 'print-job-query-partial' 'unknown' "$($jobQueryFailures.Count) of $($printerEvidence.Count) print queue(s) could not be read ($names), so 'no stuck print jobs' covers only the queues that answered." ([ordered]@{ failed = $jobQueryFailures; totalPrinters = $printerEvidence.Count })
  }

  # PrintService/Admin errors, last 7 days
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = @(1,2); StartTime = (Get-Date).AddDays(-7) })
  $printLogUnreadable = $script:FFLastEventUnreadable
  $printLogError = $script:FFLastEventError
  if ($ev.Count -gt 0) {
    $findings += New-Finding 'print-error-events' 'warning' "$($ev.Count) print service error(s) in the last 7 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($printLogUnreadable) {
    $findings += New-Finding 'print-log-unreadable' 'unknown' "The print service log could not be read, so 'no recent print errors' cannot be claimed: $printLogError" ([ordered]@{ error = $printLogError })
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    $spoolerPart = 'the Print Spooler service is MISSING'
    if ($svc.measured -eq $false) { $spoolerPart = 'the Print Spooler service could not be queried, so its state is unknown' }
    elseif ($svc.present -eq $true) { $spoolerPart = "the Print Spooler service is $($svc.status) (start type: $($svc.startType))" }
    # Only the branch that actually enumerated may speak about printers or jobs. The old text
    # said "no printers were enumerated; no stuck print jobs" whether the enumeration returned
    # an empty list or never ran at all — two completely different claims sharing one sentence.
    if (-not $printerQueryRan) {
      $summary = "$spoolerPart. Installed printers and print queues could NOT be enumerated, so this probe cannot say whether any printer is in an error state or any print job is stuck."
    } elseif ($printerEvidence.Count -eq 0) {
      $summary = "$spoolerPart; the printer list was read successfully and contains no printers, so there are no queues to be stuck."
    } elseif ($jobQueryFailures.Count -gt 0) {
      $summary = "$spoolerPart; $($printerEvidence.Count) printer(s) enumerated, none in an Error/Offline state; no stuck jobs in the $($printerEvidence.Count - $jobQueryFailures.Count) queue(s) that could be read."
    } else {
      $summary = "$spoolerPart; $($printerEvidence.Count) printer(s) enumerated, none in an Error/Offline state; no stuck print jobs."
    }
    if ($needsAdmin) { $summary = $summary + ' The spool-folder check needs administrator rights.' }
  } else {
    $summary = "Printing shows $issues issue(s) — see findings."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Stability {
  $findings = @(); $needsAdmin = $false
  $since = (Get-Date).AddDays(-30)

  # Bug checks (BSODs): Event 1001, stop code in EventData
  $bug = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -MaxEvents 10)
  $bugLogUnreadable = $script:FFLastEventUnreadable
  $bugLogError = $script:FFLastEventError
  $bugRows = @()
  foreach ($e in $bug) {
    $code = $null
    try { if ($e.Properties.Count -gt 0) { $code = "$($e.Properties[0].Value)" } } catch {}
    if ($code -and $code.Length -gt 120) { $code = $code.Substring(0, 120) }
    $bugRows += [ordered]@{ time = (ConvertTo-FFTime $e.TimeCreated); stopCode = $code }
  }
  if ($bug.Count -gt 0) {
    $recent = @($bug | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) })
    $sev = 'warning'
    if ($recent.Count -gt 0) { $sev = 'critical' }
    $latest = $bugRows[0]
    $findings += New-Finding 'bugcheck-detected' $sev "$($bug.Count) blue screen(s) in the last 30 days; most recent stop code: $($latest.stopCode)." ([ordered]@{ count = $bug.Count; last7Days = $recent.Count; bugchecks = $bugRows })
  }

  # Dirty shutdowns: Kernel-Power 41 (crash OR power loss)
  $kp = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -MaxEvents 10)
  if ($script:FFLastEventUnreadable) { $bugLogUnreadable = $true; if ($null -eq $bugLogError) { $bugLogError = $script:FFLastEventError } }
  if ($bugLogUnreadable) {
    $findings += New-Finding 'stability-log-unreadable' 'unknown' "The System log could not be read for bug checks / unexpected shutdowns, so 'no blue screens' cannot be claimed: $bugLogError" ([ordered]@{ error = $bugLogError })
  }

  # Discriminator: 41 events with no matching 1001 = power loss / hard hang, not a BSOD.
  if ($kp.Count -gt 0 -and $bug.Count -eq 0) {
    $findings += New-Finding 'power-loss-shutdowns' 'warning' "$($kp.Count) unexpected shutdown(s) in the last 30 days with no matching bug check — power loss or hard hang, not a blue screen." ([ordered]@{ kernelPower41 = $kp.Count; bugCheck1001 = 0; sample = @(ConvertTo-FFEventEvidence -Events $kp -First 3) })
  } elseif ($kp.Count -gt $bug.Count -and $bug.Count -gt 0) {
    $findings += New-Finding 'mixed-dirty-shutdowns' 'info' "$($kp.Count) unexpected shutdown(s) vs $($bug.Count) bug check(s) — some dirty shutdowns were not blue screens." ([ordered]@{ kernelPower41 = $kp.Count; bugCheck1001 = $bug.Count })
  }

  # Dump inventory (Minidump folder is admin-ACLed; degrade gracefully)
  $dumps = [ordered]@{ minidumpCount = $null; newestMinidump = $null; liveKernelReports = $null; memoryDmpPresent = $false }
  $miniDir = Join-Path $env:SystemRoot 'Minidump'
  # Test-Path returns $false on access-denied, which would fabricate "0 dumps".
  # Discriminate denied-vs-missing the same way the search-index probe does.
  $miniDirItem = $null; $miniDenied = $false
  try { $miniDirItem = Get-Item -Path $miniDir -Force -ErrorAction Stop }
  catch {
    # Exception TYPE / category / HRESULT, never the English word 'denied' — see Test-FFAccessDenied.
    if (Test-FFAccessDenied -ErrorRecord $_) { $miniDenied = $true }
  }
  if ($null -ne $miniDirItem) {
    try {
      $dmp = @(Get-ChildItem -Path $miniDir -Filter '*.dmp' -Force -ErrorAction Stop)
      $dumps.minidumpCount = $dmp.Count
      if ($dmp.Count -gt 0) { $dumps.newestMinidump = ($dmp | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToString('s') }
    } catch {
      if (-not $IsAdmin) { $needsAdmin = $true }  # listing denied — count stays null (honest unknown)
    }
  } elseif ($miniDenied) {
    if (-not $IsAdmin) { $needsAdmin = $true }    # denied, not missing — never claim 0 dumps
  } else {
    $dumps.minidumpCount = 0                      # folder genuinely absent = no minidumps written
  }
  try {
    $lkr = @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'LiveKernelReports') -Filter '*.dmp' -Recurse -ErrorAction Stop)
    $dumps.liveKernelReports = $lkr.Count
    # Live kernel reports include GPU watchdog (TDR) events — relevant, but non-fatal by definition.
    if ($lkr.Count -gt 0) {
      $newest = ($lkr | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
      if ($newest.LastWriteTime -gt $since) {
        $findings += New-Finding 'live-kernel-events' 'info' "$($lkr.Count) live kernel report(s) on disk (non-fatal hangs/watchdog events; newest: $($newest.LastWriteTime.ToString('s')))." ([ordered]@{ count = $lkr.Count; newest = $newest.LastWriteTime.ToString('s') })
      }
    }
  } catch {
    if (-not $IsAdmin) { $needsAdmin = $true }  # LiveKernelReports is admin-ACLed
  }
  try { $dumps.memoryDmpPresent = Test-Path (Join-Path $env:SystemRoot 'MEMORY.DMP') } catch {}
  if ($null -ne $dumps.minidumpCount -or $null -ne $dumps.liveKernelReports) {
    $findings += New-Finding 'dump-inventory' 'info' 'Crash dump inventory captured for analysis.' $dumps
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    if ($bugLogUnreadable) { $summary = 'Blue screens and unexpected shutdowns could not be counted — the System log was not readable.' }
    elseif ($needsAdmin) { $summary = 'No blue screens and no unexpected shutdowns in the last 30 days; the full dump inventory needs administrator rights.' }
    else { $summary = 'No blue screens and no unexpected shutdowns in the last 30 days.' }
  } else { $summary = "Stability shows $issues issue(s) in the last 30 days — see findings." }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-DiskSpace {
  $findings = @(); $needsAdmin = $false
  $sysLetter = ($env:SystemDrive).TrimEnd(':')
  $volumes = @()
  $ungraded = 0
  $volumeQueryFailed = $false
  try {
    # The DriveLetter requirement is gone: a full volume mounted at a FOLDER PATH (a standard
    # pattern once a machine runs out of letters, and on Storage Spaces) contributed nothing to
    # the old query while the summary still claimed "all fixed volumes have healthy free space".
    # Every fixed volume is now enumerated and labelled by letter, mount path, or volume GUID.
    # Volumes with NO access path at all (the hidden ~900 MB WinRE/recovery partition, verified
    # present on this box) are inventoried but NOT graded: they are meant to be nearly full, and
    # grading them would manufacture a critical finding out of a correct configuration. The
    # count of skipped volumes is stated in the summary so the claim stays bounded.
    foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
      $freePct = [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1)
      $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
      $sizeGB = [math]::Round($v.Size / 1GB, 1)
      $letter = "$($v.DriveLetter)".Trim()
      $isSystem = ($letter -ne '' -and $letter -eq $sysLetter)
      $mountPaths = @()
      try {
        $mountPaths = @($v | Get-Partition -ErrorAction Stop | ForEach-Object { $_.AccessPaths } |
          Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume\{' })
      } catch {}
      $label = $null; $graded = $true; $skipReason = $null
      if ($letter -ne '') { $label = "$letter" }
      elseif ($mountPaths.Count -gt 0) { $label = "$($mountPaths[0])" }
      else {
        $label = "$($v.Path)"
        $graded = $false
        $skipReason = 'no drive letter and no mount point — a hidden system/recovery partition, which is expected to be nearly full'
      }
      $key = ($label -replace '[^A-Za-z0-9]', '')
      if ([string]::IsNullOrWhiteSpace($key)) { $key = "vol$($volumes.Count)" }
      $row = [ordered]@{
        drive = $label; driveLetter = $letter; mountPaths = $mountPaths
        freePct = $freePct; freeGB = $freeGB; sizeGB = $sizeGB
        isSystemDrive = $isSystem; graded = $graded; notGradedReason = $skipReason
        fileSystem = "$($v.FileSystemType)"; volumePath = "$($v.Path)"
      }
      $volumes += $row
      if (-not $graded) { $ungraded++; continue }
      if ($freePct -lt 10 -or ($isSystem -and $freeGB -lt 20)) {
        $findings += New-Finding "space-critical-$key" 'critical' "Volume $label is critically low on space ($freeGB GB free, $freePct%) — Windows updates fail under ~20 GB free on the system drive." $row
      } elseif ($freePct -lt 15) {
        $findings += New-Finding "space-low-$key" 'warning' "Volume $label is low on space ($freeGB GB free, $freePct%)." $row
      }
    }
  } catch {
    $volumeQueryFailed = $true
    $findings += New-Finding 'volume-query-failed' 'unknown' "Volumes could not be enumerated, so free space is UNKNOWN rather than healthy: $($_.Exception.Message)" $null
  }

  # Deep, read-only: component-store bloat analysis (§3.9). DISM's analyze pass only
  # reads the store and prints 'Component Store Cleanup Recommended : Yes/No'.
  if ($Deep) {
    if ($IsAdmin) {
      try {
        # /English is a GLOBAL DISM switch ("displays command line output in English") that
        # applies to every DISM command. Without it this whole block is dead code on the ~70% of
        # Windows installs whose DISM output is MUI-localized: the label never matches, so
        # component-store-cleanup-recommended is never emitted and component-cleanup /
        # component-cleanup-resetbase refuse to run on machines with many GB of reclaimable WinSxS.
        $dism = Invoke-FFNative -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -Arguments @('/English','/Online','/Cleanup-Image','/AnalyzeComponentStore')
        $txt = "$($dism.text)"
        if ($txt -match 'Component Store Cleanup Recommended\s*:\s*(\S+)') {
          $rec = "$($Matches[1])".Trim()
          $evi = [ordered]@{ cleanupRecommended = $rec; dismExitCode = $dism.exitCode; english = $true }
          if ($txt -match '(?m)^\s*Actual Size of Component Store\s*:\s*(.+?)\s*$') { $evi.actualSize = $Matches[1] }
          # Exact -eq, not -match '^Yes': with /English the value is guaranteed English, and an
          # exact test means a value we do NOT recognise falls through to 'unknown' instead of
          # being silently reported as "no cleanup needed".
          if ($rec -eq 'Yes') {
            $findings += New-Finding 'component-store-cleanup-recommended' 'warning' 'DISM reports component-store cleanup is recommended — reclaimable space is available (StartComponentCleanup).' $evi
          } elseif ($rec -eq 'No') {
            $findings += New-Finding 'component-store-cleanup-not-needed' 'info' 'DISM reports no component-store cleanup is needed.' $evi
          } else {
            $findings += New-Finding 'component-store-analyze-indeterminate' 'unknown' "DISM reported an unrecognised cleanup-recommended value ('$rec'), so component-store bloat is UNKNOWN." $evi
          }
        } else {
          $findings += New-Finding 'component-store-analyze-indeterminate' 'unknown' "DISM AnalyzeComponentStore ran (exit code $($dism.exitCode)) but the 'Component Store Cleanup Recommended' line was not present in its output, so component-store bloat is UNKNOWN rather than absent." ([ordered]@{ dismExitCode = $dism.exitCode; outputTail = ("$txt".Trim() -split "`n" | Select-Object -Last 8) })
        }
      } catch {
        $findings += New-Finding 'component-store-analyze-failed' 'unknown' "DISM AnalyzeComponentStore could not run, so component-store bloat was not measured: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    if ($volumeQueryFailed) {
      $summary = 'Free space could not be assessed — the volume list could not be enumerated.'
    } else {
      $graded = @($volumes | Where-Object { $_.graded })
      $sys = @($volumes | Where-Object { $_.isSystemDrive }) | Select-Object -First 1
      if ($graded.Count -eq 0) {
        # "All 0 fixed volume(s) ... have healthy free space" is a claim about nothing at all.
        # The enumeration DID run (the catch above owns the other case), so say what it found.
        if ($volumes.Count -eq 0) { $summary = 'The volume list was read successfully and contained no fixed volumes, so there was no free space to assess.' }
        else { $summary = "The volume list was read successfully; all $($volumes.Count) fixed volume(s) on this machine have no drive letter and no mount point, so none of them could be graded for free space." }
      } else {
        $summary = "All $($graded.Count) fixed volume(s) with a mount point have healthy free space"
        if ($sys) { $summary = $summary + " (system drive: $($sys.freeGB) GB free, $($sys.freePct)%)" }
        if ($ungraded -gt 0) { $summary = $summary + "; $ungraded volume(s) with no mount point were inventoried but not graded" }
        $summary = $summary + '.'
      }
    }
  } else {
    $summary = "$issues volume(s) low on space — see findings."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  # Always attach the per-volume table as informational evidence.
  $findings += New-Finding 'volume-inventory' 'info' 'Per-volume free space captured.' ([ordered]@{ volumes = $volumes })
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Boot {
  $findings = @(); $needsAdmin = $false

  # Boot time trend: Diagnostics-Performance Event 100, BootTime (ms) from named EventData.
  #
  # Microsoft-Windows-Diagnostics-Performance/Operational is an ADMIN-RESTRICTED channel, and
  # FrameForge's default launch is unelevated — so on the default run this reads nothing at all.
  # Worse, the -FilterHashtable form reports that denial as "no events found" (see
  # Test-FFEventLogReadable in _lib.ps1), which is how this category used to paint a green tick
  # and assert "no boot-time degradation signals were found" having measured precisely nothing.
  $boots = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 10)
  $bootLogUnreadable = $script:FFLastEventUnreadable
  $bootEventError = $script:FFLastEventError
  $bootErrorKind = $script:FFLastEventErrorKind
  $bootRows = @()
  foreach ($e in $boots) {
    $ms = $null
    $map = Get-FFEventDataMap -Event $e
    if ($map.ContainsKey('BootTime')) { $ms = [int64]$map['BootTime'] }
    elseif ($e.Properties.Count -gt 5) { try { $ms = [int64]$e.Properties[5].Value } catch {} }
    if ($null -ne $ms) { $bootRows += [ordered]@{ time = (ConvertTo-FFTime $e.TimeCreated); bootMs = $ms } }
  }
  $avgMs = $null
  if ($bootRows.Count -gt 0) {
    $avgMs = [int](( $bootRows | ForEach-Object { $_.bootMs } | Measure-Object -Average ).Average)
    $findings += New-Finding 'boot-time-trend' 'info' "Last $($bootRows.Count) boot(s) averaged $([math]::Round($avgMs/1000,1)) s (Event 100 BootTime)." ([ordered]@{ averageMs = $avgMs; boots = $bootRows })
    # Degradation heuristics — honest and conservative.
    $latest = $bootRows[0].bootMs
    $sorted = @($bootRows | ForEach-Object { $_.bootMs } | Sort-Object)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    if ($bootRows.Count -ge 3 -and $latest -gt (2 * $median) -and $latest -gt 60000) {
      $findings += New-Finding 'boot-slower-than-usual' 'warning' "The most recent boot took $([math]::Round($latest/1000,1)) s — more than double the median of recent boots ($([math]::Round($median/1000,1)) s)." ([ordered]@{ latestMs = $latest; medianMs = $median })
    }
    # Media-appropriate threshold. The old fixed 180 s constant was paired with the sentence
    # "well beyond a healthy range for this class of hardware" — a hardware-relative judgement
    # made by a hardware-blind constant. The system disk's MediaType is read here so the claim
    # is actually derived from the class of hardware, and the media type rides along in the
    # evidence; when it cannot be read the threshold stays at the conservative 180 s and the
    # wording drops the hardware claim entirely.
    $sysMedia = $null; $sysBus = $null
    try {
      $pd = Get-Partition -DriveLetter ($env:SystemDrive).TrimEnd(':') -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop
      if ($pd) { $sysMedia = "$($pd.MediaType)"; $sysBus = "$($pd.BusType)" }
    } catch {}
    $slowMs = 180000; $mediaPhrase = 'which is slow in absolute terms'
    if ($sysMedia -eq 'SSD' -or $sysBus -eq 'NVMe') { $slowMs = 60000; $mediaPhrase = "well beyond a healthy range for $(if ($sysBus -eq 'NVMe') { 'NVMe' } else { 'SSD' }) system storage" }
    elseif ($sysMedia -eq 'HDD') { $slowMs = 180000; $mediaPhrase = 'well beyond a healthy range even for a mechanical hard disk' }
    if ($avgMs -gt $slowMs) {
      $findings += New-Finding 'boot-slow' 'warning' "Boots average $([math]::Round($avgMs/1000,0)) s — $mediaPhrase." ([ordered]@{ averageMs = $avgMs; thresholdMs = $slowMs; systemDiskMediaType = $sysMedia; systemDiskBusType = $sysBus })
    }
  } elseif ($bootLogUnreadable -or $null -ne $bootEventError) {
    # The channel could not be read. Raise needsAdmin when that is the reason, and never let this
    # fall through to a healthy summary.
    if ($bootErrorKind -eq 'access-denied' -and -not $IsAdmin) { $needsAdmin = $true }
    $findings += New-Finding 'boot-log-unreadable' 'unknown' "The boot-performance log (Microsoft-Windows-Diagnostics-Performance/Operational) could not be read, so boot time was NOT measured: $bootEventError" ([ordered]@{ errorKind = $bootErrorKind; error = $bootEventError; needsAdmin = $needsAdmin })
  } else {
    # Readable, but the machine has recorded nothing. That is not "no degradation" either.
    $findings += New-Finding 'boot-no-events' 'info' 'No boot-performance events (Event 100) have been recorded on this machine, so boot time could not be assessed.' $null
  }

  # Degradation causes with named offenders: Events 101-110, last 30 days
  $deg = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = @(101,102,103,104,105,106,107,108,109,110); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 20)
  if ($deg.Count -gt 0) {
    $offenders = @{}
    $degRows = @()
    foreach ($e in $deg) {
      $map = Get-FFEventDataMap -Event $e
      $name = $null
      foreach ($k in @('ApplicationName','Name','ServiceName','DriverFileName','GroupName','FilePath','Path')) {
        if ($map.ContainsKey($k) -and $map[$k]) { $name = $map[$k]; break }
      }
      if (-not $name) { $name = '(unnamed)' }
      if (-not $offenders.ContainsKey($name)) { $offenders[$name] = 0 }
      $offenders[$name] = $offenders[$name] + 1
      if ($degRows.Count -lt 5) { $degRows += [ordered]@{ id = $e.Id; time = (ConvertTo-FFTime $e.TimeCreated); offender = $name } }
    }
    $top = @($offenders.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key) (x$($_.Value))" })
    $sev = 'info'
    if ($deg.Count -ge 5) { $sev = 'warning' }
    $findings += New-Finding 'boot-degradation-events' $sev "$($deg.Count) boot-degradation event(s) in the last 30 days; top offenders: $($top -join ', ')." ([ordered]@{ count = $deg.Count; topOffenders = $top; sample = $degRows })
  }

  # Fast Startup state. powercfg has NO /English switch, and both the section header
  # ('The following sleep states are available on this system:') and the feature label
  # ('Fast Startup') are MUI-localized — so the old prose parse left $fastState permanently
  # 'unknown' on the majority of Windows installs. Read the STATE instead of the prose:
  #   Rung 1: CallNtPowerInformation(SystemPowerCapabilities) -> SystemS4 / HiberFilePresent /
  #           Hiberboot. Structured, locale-free, works unelevated (verified on this box).
  #   Rung 2: HKLM\SYSTEM\CurrentControlSet\Control\Power\HibernateEnabled, corroborated by
  #           hiberfil.sys. NOTE: hiberfil.sys is SYSTEM-ACLed, so Test-Path returning $false
  #           proves nothing — it is used only as POSITIVE corroboration, never as a negative.
  #   Rung 3: the documented English-only powercfg /a parse (kept so nothing is lost on en-US).
  #   Rung 4: 'unknown'.
  # The enabled/disabled toggle is HiberbootEnabled, which this probe already read.
  $fastState = 'unknown'; $fastSource = 'none'
  $powerCaps = Get-FFPowerCapabilities
  if ($powerCaps.available) {
    $fastSource = 'callntpowerinformation'
    if ($powerCaps.systemS4 -and $powerCaps.hiberFilePresent) { $fastState = 'available' } else { $fastState = 'unavailable' }
  }
  $hibernateEnabled = $null
  try { $hibernateEnabled = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch {}
  $hiberfilSeen = $false
  try { $hiberfilSeen = [bool](Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')) } catch {}
  if ($fastState -eq 'unknown') {
    if ($null -ne $hibernateEnabled) {
      $fastSource = 'registry-hibernateenabled'
      if ([int]$hibernateEnabled -eq 1) { $fastState = 'available' } else { $fastState = 'unavailable' }
    } elseif ($hiberfilSeen) {
      $fastSource = 'hiberfil-present'
      $fastState = 'available'
    }
  }
  $powercfgText = $null
  $powercfgParse = $null      # why the English rung did or did not decide; $null = never reached
  if ($fastState -eq 'unknown') {
    try {
      $powercfgParse = 'not-run'
      $pa = Invoke-FFNative -FilePath (Join-Path $env:SystemRoot 'System32\powercfg.exe') -Arguments @('/a')
      $powercfgText = "$($pa.text)"
      # DOCUMENTED ENGLISH-ONLY parse; unreachable on localized Windows, which is why it is last.
      #
      # THE INVERSION THIS REPLACED: the old anchor was the substring 'available on this
      # system:', which also occurs INSIDE the negative header 'The following sleep states are
      # not available on this system:'. On a machine that prints ONLY the negative section
      # (hibernation turned off, Hyper-V Gen2 guests, most cloud VMs) the regex matched at the
      # negative header, captured the entire NOT-available list as if it were the available
      # list, found 'Fast Startup' in it, and reported "Fast Startup is available and enabled"
      # about a machine powercfg had just said it was unavailable on. Reproduced against a
      # negative-only powercfg /a transcript before this change.
      #
      # Anchoring is now positional and explicit: find the two section HEADERS by full line,
      # negative one first (so the positive matcher can never latch onto its tail), split the
      # text between them, and require Fast Startup to appear in a section that was actually
      # identified. If neither header is found, or Fast Startup appears in NEITHER section, the
      # verdict stays 'unknown' — powercfg is not asked to guess.
      $posIdx = -1; $negIdx = -1
      $negRx = [regex]'(?im)^\s*The following sleep states are not available on this system:\s*$'
      $posRx = [regex]'(?im)^\s*The following sleep states are available on this system:\s*$'
      $negM = $negRx.Match($powercfgText); if ($negM.Success) { $negIdx = $negM.Index }
      $posM = $posRx.Match($powercfgText); if ($posM.Success) { $posIdx = $posM.Index }
      $availSection = $null; $unavailSection = $null
      if ($posIdx -ge 0) {
        $posStart = $posM.Index + $posM.Length
        if ($negIdx -gt $posIdx) { $availSection = $powercfgText.Substring($posStart, $negIdx - $posStart) }
        else { $availSection = $powercfgText.Substring($posStart) }
      }
      if ($negIdx -ge 0) {
        $negStart = $negM.Index + $negM.Length
        if ($posIdx -gt $negIdx) { $unavailSection = $powercfgText.Substring($negStart, $posIdx - $negStart) }
        else { $unavailSection = $powercfgText.Substring($negStart) }
      }
      $inAvail   = ($null -ne $availSection   -and $availSection   -match '(?im)^\s*Fast Startup\s*$')
      $inUnavail = ($null -ne $unavailSection -and $unavailSection -match '(?im)^\s*Fast Startup\s*$')
      # `source` names the rung that DECIDED, and stays 'none' when none did — that is the
      # existing contract (engine/test/cases/13-locale-powercfg.ps1 asserts it for localized
      # powercfg output). Why the English rung failed is reported additively in `powercfgParse`.
      if ($inAvail -and -not $inUnavail)      { $fastState = 'available';   $fastSource = 'powercfg-english'; $powercfgParse = 'listed-available' }
      elseif ($inUnavail -and -not $inAvail)  { $fastState = 'unavailable'; $fastSource = 'powercfg-english'; $powercfgParse = 'listed-not-available' }
      elseif ($posIdx -lt 0 -and $negIdx -lt 0) {
        # No English headers at all: this is a localized powercfg. Stay unknown by design.
        $powercfgParse = 'no-english-headers'
      } elseif ($inAvail -and $inUnavail) {
        $powercfgParse = 'ambiguous-both-sections'
      } else {
        # Headers found but Fast Startup was named in neither section — not a verdict either.
        $powercfgParse = 'fast-startup-not-listed'
      }
    } catch {}
  }
  $hiberboot = $null
  try { $hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled } catch {}
  $fastDetail = 'Fast Startup availability could not be determined.'
  if ($fastState -eq 'available' -and $hiberboot -eq 1) { $fastDetail = 'Fast Startup is available and enabled.' }
  elseif ($fastState -eq 'available' -and $hiberboot -eq 0) { $fastDetail = 'Fast Startup is available but turned off.' }
  elseif ($fastState -eq 'available') { $fastDetail = 'Fast Startup is available; its on/off setting could not be read.' }
  elseif ($fastState -eq 'unavailable') { $fastDetail = 'Fast Startup is not available on this system (hibernation off or unsupported).' }
  # 'powercfgState' is kept as the field name the renderer already reads; 'state' is its alias.
  $fastEvi = [ordered]@{
    powercfgState = $fastState; state = $fastState; source = $fastSource
    hiberbootEnabled = $hiberboot; hibernateEnabled = $hibernateEnabled; hiberfilPresent = $hiberfilSeen
    powerCapabilities = $powerCaps
    # Additive: null when the English powercfg rung was never reached; otherwise
    # listed-available | listed-not-available | no-english-headers |
    # ambiguous-both-sections | fast-startup-not-listed | not-run
    powercfgParse = $powercfgParse
  }
  $fastSeverity = 'info'
  if ($fastState -eq 'unknown') { $fastSeverity = 'unknown' }
  $findings += New-Finding 'fast-startup-state' $fastSeverity $fastDetail $fastEvi

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    # The healthy sentence is guarded: it may only be spoken when boot rows were actually read.
    if ($bootRows.Count -gt 0) {
      $summary = "Boot times look normal (average $([math]::Round($avgMs/1000,1)) s over the last $($bootRows.Count) boot(s))."
    } elseif ($bootLogUnreadable -or $null -ne $bootEventError) {
      if ($needsAdmin) { $summary = 'Boot performance could not be measured: the Diagnostics-Performance log needs administrator rights.' }
      else { $summary = "Boot performance could not be measured: the Diagnostics-Performance log could not be read ($bootEventError)." }
    } else {
      $summary = 'No boot-performance events have been recorded on this machine, so boot time could not be assessed.'
    }
  } else {
    $summary = "Boot performance shows $issues issue(s) — see findings."
  }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Audio {
  $findings = @(); $needsAdmin = $false

  # Device inventory FIRST, so the service verdict can be correlated with it. Asserting
  # "audio will not work until it runs" on a headless/RDP box, a VM, or a mini-PC with no audio
  # codec is a user-facing consequence claimed without checking whether audio hardware exists —
  # and it then offers audio-restart as a fix for hardware that is not there.
  $devEvidence = @()
  $pnpError = $null
  $pnpDeviceCount = $null
  try {
    $pnpAll = @(Get-PnpDevice -Class @('AudioEndpoint','MEDIA') -ErrorAction Stop)
    $pnpDeviceCount = $pnpAll.Count
    foreach ($d in $pnpAll) {
      if ("$($d.Status)" -eq 'Error') {
        $row = [ordered]@{ name = "$($d.FriendlyName)"; status = "$($d.Status)"; instanceId = "$($d.InstanceId)" }
        $devEvidence += $row
        $findings += New-Finding 'audio-device-error' 'warning' "Audio device '$($d.FriendlyName)' is in an error state — driver problem." $row
      }
    }
  } catch { $pnpError = "$($_.Exception.Message)" }
  if ($null -ne $pnpError) {
    $findings += New-Finding 'audio-pnp-query-failed' 'unknown' "PnP audio-device state could not be queried, so audio device health is UNKNOWN: $pnpError" $null
  }

  # CIM sound devices (§3.11): Error/Degraded status signals a driver problem
  $sndEvidence = @()
  $cimError = $null
  $cimDeviceCount = $null
  try {
    $sndAll = @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction Stop)
    $cimDeviceCount = $sndAll.Count
    foreach ($sd in $sndAll) {
      $row = [ordered]@{ name = "$($sd.Name)"; status = "$($sd.Status)"; statusInfo = $sd.StatusInfo }
      $sndEvidence += $row
      if ("$($sd.Status)" -match 'Error|Degraded') {
        $findings += New-Finding 'sound-device-error' 'warning' "Sound device '$($sd.Name)' reports status '$($sd.Status)'." $row
      }
    }
    if ($sndEvidence.Count -gt 0) {
      $findings += New-Finding 'sound-device-inventory' 'info' "CIM sound-device state captured for $($sndEvidence.Count) device(s)." ([ordered]@{ devices = $sndEvidence })
    }
  } catch { $cimError = "$($_.Exception.Message)" }
  if ($null -ne $cimError) {
    $findings += New-Finding 'audio-cim-query-failed' 'unknown' "Win32_SoundDevice could not be queried, so sound-device health is UNKNOWN: $cimError" $null
  }

  # $true = at least one query answered AND found no audio hardware at all.
  # $null when neither query answered — absence of evidence, not evidence of absence.
  $noAudioHardware = $null
  if ($null -ne $pnpDeviceCount -or $null -ne $cimDeviceCount) {
    $total = 0
    if ($null -ne $pnpDeviceCount) { $total += $pnpDeviceCount }
    if ($null -ne $cimDeviceCount) { $total += $cimDeviceCount }
    $noAudioHardware = ($total -eq 0)
  }

  $svc = @(Get-ServiceInfo @('Audiosrv','AudioEndpointBuilder'))
  $deviceEvi = [ordered]@{ pnpAudioDevices = $pnpDeviceCount; cimSoundDevices = $cimDeviceCount }
  $findings += @(New-ServiceQueryFindings -Services $svc)
  foreach ($s in $svc) {
    if ($s.measured -eq $false) {
      # Handled by New-ServiceQueryFindings above. `-not $s.present` used to be TRUE here and
      # fired the critical "the service was deleted" claim about a query that never ran.
      continue
    }
    if ($s.present -eq $false) {
      if ($noAudioHardware -eq $true) {
        $findings += New-Finding "$($s.name)-missing" 'info' "The $($s.friendlyName) service ($($s.name)) does not exist on this system, and no audio device is present either — nothing to repair." ($deviceEvi)
      } else {
        $findings += New-Finding "$($s.name)-missing" 'critical' "The $($s.friendlyName) service ($($s.name)) does not exist on this system — it was deleted, not merely disabled. Audio cannot work, and Set-Service cannot recreate it; this usually comes from a debloat/'gaming optimizer' script." ([ordered]@{ service = $s.name; present = $false; devices = $deviceEvi })
      }
    } elseif ($s.status -ne 'Running') {
      if ($noAudioHardware -eq $true) {
        $findings += New-Finding "audio-service-stopped-$($s.name)" 'info' "The $($s.name) service is $($s.status), and no audio endpoint or sound device is present on this machine — nothing to repair." ([ordered]@{ service = $s; devices = $deviceEvi })
      } else {
        $findings += New-Finding "audio-service-stopped-$($s.name)" 'critical' "The $($s.name) service is $($s.status) — audio will not work until it runs." ([ordered]@{ service = $s; devices = $deviceEvi })
      }
    }
  }

  $issues = Get-IssueCount $findings
  $summary = ''
  if ($issues -eq 0) {
    $svcPart = Format-ServicePresence -Services $svc -Label 'audio services'
    # Only claim devices are error-free when at least one device query actually succeeded.
    if ($null -ne $pnpError -and $null -ne $cimError) { $summary = "$svcPart, but device state could not be queried (PnP and CIM both failed)." }
    elseif ($noAudioHardware -eq $true) { $summary = "$svcPart, and no audio endpoint or sound device is present on this machine." }
    else { $summary = "$svcPart; no audio device reports an error." }
  }
  else { $summary = "Audio shows $issues issue(s) — see findings." }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Activation {
  $findings = @(); $needsAdmin = $false
  $statusText = $null
  $rowsDisagree = $false
  $licensedRow = $null
  try {
    # Server-side narrowed WQL: ApplicationID is the Windows-OS licensing GUID; the explicit
    # property list keeps the (notoriously slow) SLP provider cheap.
    #
    # ALL rows are enumerated — no `Select-Object -First 1`. The query has no ORDER BY, so taking
    # the first row means taking whatever the provider happened to return first. A machine can
    # legitimately carry more than one licensed product: Enterprise/Education under Subscription
    # Activation layers an Enterprise licence over a Pro base, a KMS box can retain an OEM/retail
    # key, and add-on SKUs linger. Those rows can disagree (base in Notification while the
    # subscription is Licensed), so picking one silently can report a fully licensed machine as
    # 'windows-not-activated' and then offer slmgr /ato, which is not how subscription
    # activation is repaired. Description carries the channel and is reported for every row.
    $q = "SELECT Name, Description, LicenseStatus, LicenseStatusReason, PartialProductKey FROM SoftwareLicensingProduct " +
         "WHERE ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
    $lics = @(Get-CimInstance -Query $q -ErrorAction Stop)
    if ($lics.Count -eq 0) {
      $findings += New-Finding 'activation-indeterminate' 'unknown' 'No Windows license row with a product key was returned by the licensing provider, so activation state is UNKNOWN.' $null
    } else {
      $map = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Out-of-box grace'; 3 = 'Out-of-tolerance grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }
      $rows = @()
      foreach ($l in $lics) {
        $code = [int]$l.LicenseStatus
        $t = $map[$code]
        if ($null -eq $t) { $t = "Unknown ($code)" }
        $row = [ordered]@{
          product = "$($l.Name)"; description = "$($l.Description)"
          licenseStatus = $code; licenseStatusText = $t
          licenseStatusReason = ('0x{0:X8}' -f ($l.LicenseStatusReason -band 0xFFFFFFFF))
        }
        $rows += $row
        if ($code -eq 1 -and $null -eq $licensedRow) { $licensedRow = $row }
      }
      $codes = @($rows | ForEach-Object { $_.licenseStatus } | Select-Object -Unique)
      $rowsDisagree = ($rows.Count -gt 1 -and $codes.Count -gt 1)
      $evi = [ordered]@{ rowCount = $rows.Count; rows = $rows; rowsDisagree = $rowsDisagree }
      $findings += New-Finding 'activation-license-rows' 'info' "$($rows.Count) Windows licence row(s) carry a product key on this machine." $evi
      if ($null -ne $licensedRow) {
        $statusText = 'Licensed'
      } else {
        # Nothing is licensed — only then is this a real activation problem.
        $worst = $rows[0]
        $statusText = $worst.licenseStatusText
        $findings += New-Finding 'windows-not-activated' 'warning' "No Windows licence row reports 'Licensed' (statuses: $(@($rows | ForEach-Object { $_.licenseStatusText }) -join ', ')) — activation needs attention." $evi
      }
    }
  } catch {
    $findings += New-Finding 'activation-query-failed' 'unknown' "The license state could not be queried, so activation is UNKNOWN rather than fine: $($_.Exception.Message)" $null
  }

  $summary = ''
  if ($statusText -eq 'Licensed') {
    $summary = "Windows is activated (licensed) by: $($licensedRow.product) — $($licensedRow.description)."
    if ($rowsDisagree) { $summary = $summary + ' Other licence rows on this machine report a different status; the licensed row above is the one carrying activation.' }
  }
  elseif ($null -ne $statusText) { $summary = "Windows license status: $statusText (no licence row reports Licensed)." }
  else { $summary = 'Windows activation state could not be determined.' }
  $summary = Add-UnknownNote -Summary $summary -Findings $findings
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

# ---------------- dispatch ----------------

$ProbeMap = [ordered]@{
  'system-files'   = { Probe-SystemFiles }
  'disk'           = { Probe-Disk }
  'windows-update' = { Probe-WindowsUpdate }
  'network'        = { Probe-Network }
  'store'          = { Probe-Store }
  'search'         = { Probe-Search }
  'printing'       = { Probe-Printing }
  'stability'      = { Probe-Stability }
  'disk-space'     = { Probe-DiskSpace }
  'boot'           = { Probe-Boot }
  'audio'          = { Probe-Audio }
  'activation'     = { Probe-Activation }
}

function Invoke-Category {
  param([string]$Name)
  $m = Measure-Probe -Script $ProbeMap[$Name]
  if ($null -ne $m.error) {
    return [ordered]@{ category = $Name; status = 'unknown'; summary = "Probe failed: $($m.error)"; findings = @(); durationMs = $m.durationMs }
  }
  $r = $m.result
  # Defensive: if a probe leaked extra pipeline output, take the intended trailing hashtable.
  if ($r -is [object[]]) { $r = $r[-1] }
  [ordered]@{
    category   = $Name
    status     = (Resolve-Status $r.findings ([bool]$r.needsAdmin))
    summary    = "$($r.summary)"
    findings   = @($r.findings)
    # Published so a consumer can tell "this category had signals it could not read" from a status
    # that Resolve-Status ranked down (a warning outranks needs-admin). repair.ps1's detection uses
    # it to avoid grading a repair 'healthy' off a probe that never measured that repair's signal.
    # Absent on the probe-failure path above, where nothing was measured and status is 'unknown'.
    needsAdmin = [bool]$r.needsAdmin
    durationMs = $m.durationMs
  }
}

# Platform identity attached to EVERY document, so a verdict always says which Windows it was
# reached on. health.ps1 mutates nothing, so an unsupported platform is NOT refused here — it is
# labelled: `supportedOs:false` plus `unvalidatedPlatform:true`, which the Electron host and the
# mutating engines (repair.ps1 -Action run, image.ps1 preflight/launch/acquire-url) use to refuse
# with errorCode 'unsupported-os'.
function Get-FFPlatformBlock {
  $os = Get-FFOsInfo
  $ed = Get-FFEdition
  [ordered]@{
    os                  = $os
    edition             = $ed
    supportedOs         = [bool]$os.supported
    unvalidatedPlatform = (-not $os.supported)
    unsupportedReason   = $os.unsupportedReason
    languageMode        = $script:FFLanguageMode
    # Read-only snapshot of the HKLM\SOFTWARE\Policies keys FrameForge cares about, so a verdict
    # can always be read against "is this machine managed, and by what" instead of guessing.
    # present = $null in an entry means the key could not be READ, which is not the same as absent.
    policies            = (Get-FFPolicySnapshot)
  }
}

$out = $null
$exitCode = 0
$ValidActions = @('scan','probe','list')

# Application control (WDAC / AppLocker) forces ConstrainedLanguage, where the identity casts,
# Add-Type and [xml] this engine relies on all throw. Emit the standard single JSON error
# document instead of dying with no output at all.
if (-not (Test-FFFullLanguage)) {
  Write-FFJson -InputObject (New-FFLanguageModeError) -Depth 6
  exit 3
}

# Action validation in the BODY, so an unknown action still produces one JSON document on stdout
# and a non-zero exit instead of an empty stdout plus a raw binding error on stderr.
if ($ValidActions -notcontains $Action) {
  Write-FFJson -InputObject ([ordered]@{
    ok = $false; action = "$Action"; errorCode = 'unknown-action'
    error = "Unknown action '$Action'."; validActions = $ValidActions
  }) -Depth 6
  exit 2
}

switch ($Action) {
  'scan' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cats = @()
    foreach ($k in @($ProbeMap.Keys)) { $cats += Invoke-Category $k }
    $sw.Stop()
    $totals = [ordered]@{
      ok         = @($cats | Where-Object { $_.status -eq 'ok' }).Count
      warning    = @($cats | Where-Object { $_.status -eq 'warning' }).Count
      critical   = @($cats | Where-Object { $_.status -eq 'critical' }).Count
      needsAdmin = @($cats | Where-Object { $_.status -eq 'needs-admin' }).Count
      unknown    = @($cats | Where-Object { $_.status -eq 'unknown' }).Count
    }
    $platform = Get-FFPlatformBlock
    $out = [ordered]@{
      ok         = $true
      isAdmin    = $IsAdmin
      scannedAt  = (Get-Date).ToString('s')
      deep       = [bool]$Deep
      durationMs = [int]$sw.ElapsedMilliseconds
      categories = $cats
      totals     = $totals
    }
    foreach ($k in $platform.Keys) { $out[$k] = $platform[$k] }
  }
  'probe' {
    if (-not $Category -or -not $ProbeMap.Contains($Category)) {
      $out = [ordered]@{ ok = $false; error = "Unknown or missing category '$Category'."; validCategories = @($ProbeMap.Keys) }
      $exitCode = 2   # invalid input: JSON error doc on stdout AND a non-zero exit
    } else {
      $out = Invoke-Category $Category
      $platform = Get-FFPlatformBlock
      foreach ($k in $platform.Keys) { $out[$k] = $platform[$k] }
    }
  }
  'list' {
    $out = [ordered]@{ ok = $true; categories = @($ProbeMap.Keys) }
    $platform = Get-FFPlatformBlock
    foreach ($k in $platform.Keys) { $out[$k] = $platform[$k] }
  }
}

Write-FFJson -InputObject $out -Depth 12
exit $exitCode
