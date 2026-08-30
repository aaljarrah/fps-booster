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
#>
[CmdletBinding()]
param(
  [ValidateSet('scan','probe','list')]
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
    [Parameter(Mandatory)][ValidateSet('info','warning','critical')][string]$Severity,
    [Parameter(Mandatory)][string]$Detail,
    $Evidence = $null
  )
  [ordered]@{ id = $Id; severity = $Severity; detail = $Detail; evidence = $Evidence }
}

function Resolve-Status {
  # info findings never degrade the status; needs-admin only shows when nothing worse was found.
  param($Findings, [bool]$NeedsAdmin)
  $f = @($Findings)
  if (@($f | Where-Object { $_.severity -eq 'critical' }).Count -gt 0) { return 'critical' }
  if (@($f | Where-Object { $_.severity -eq 'warning' }).Count -gt 0)  { return 'warning' }
  if ($NeedsAdmin) { return 'needs-admin' }
  return 'ok'
}

function Get-ServiceInfo {
  param([string[]]$Names)
  $out = @()
  foreach ($n in $Names) {
    try {
      $s = Get-Service -Name $n -ErrorAction Stop
      $st = $null
      try { $st = "$($s.StartType)" } catch {}
      $out += [ordered]@{ name = $n; status = "$($s.Status)"; startType = $st; present = $true }
    } catch {
      $out += [ordered]@{ name = $n; status = 'NotFound'; startType = $null; present = $false }
    }
  }
  # Emitted plainly — collect with @(...) at the call site.
  $out
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
      $findings += New-Finding 'dism-checkhealth-failed' 'info' "DISM CheckHealth could not run: $($_.Exception.Message)" $null
    }
  } else {
    $needsAdmin = $true
  }

  # CBS pending reboot key (readable without admin)
  $cbsPending = $false
  try {
    $cbsPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if ($cbsPending) {
      $findings += New-Finding 'cbs-reboot-pending' 'warning' 'Component servicing has a pending reboot — some system-file repairs only complete after a restart.' ([ordered]@{ registryKey = 'HKLM\...\Component Based Servicing\RebootPending'; present = $true })
    }
  } catch {}

  # Deep, still read-only: sfc /verifyonly + DISM ScanHealth (slow, admin-only)
  if ($Deep) {
    if ($IsAdmin) {
      try {
        $raw = & "$env:SystemRoot\System32\sfc.exe" /verifyonly 2>&1
        # sfc emits UTF-16; strip interleaved NULs so text matching works regardless of console codepage.
        $txt = ((@($raw) | ForEach-Object { "$_" }) -join ' ') -replace "`0", ''
        # Evidence: the [SR] tail of CBS.log (read-only) — what sfc actually just logged.
        $srTail = @()
        try {
          $cbsLog = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
          $srTail = @(Get-Content -Path $cbsLog -Tail 6000 -ErrorAction Stop |
            Where-Object { $_ -match '\[SR\]' } | Select-Object -Last 50 | ForEach-Object { "$_".Trim() })
        } catch {}
        if ($txt -match 'did not find any integrity violations') {
          $findings += New-Finding 'sfc-verify-clean' 'info' 'SFC verification found no integrity violations.' ([ordered]@{ srTail = @($srTail | Select-Object -Last 5) })
        } elseif ($txt -match 'found integrity violations') {
          $findings += New-Finding 'sfc-verify-violations' 'warning' 'SFC verification found integrity violations — run DISM RestoreHealth, then sfc /scannow.' ([ordered]@{ log = 'C:\Windows\Logs\CBS\CBS.log'; srTail = $srTail })
        } else {
          $findings += New-Finding 'sfc-verify-indeterminate' 'info' 'SFC verification produced an unrecognized result; see CBS.log.' ([ordered]@{ tail = $txt.Trim(); srTail = $srTail })
        }
      } catch {
        $findings += New-Finding 'sfc-verify-failed' 'info' "sfc /verifyonly could not run: $($_.Exception.Message)" $null
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
        $findings += New-Finding 'dism-scanhealth-failed' 'info' "DISM ScanHealth could not run: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $summary = ''
  if ($null -ne $healthState -and $healthState -eq 'Healthy') {
    if ($cbsPending) { $summary = 'Component store is healthy, but a servicing reboot is pending.' }
    else { $summary = 'Component store reports healthy and no servicing reboot is pending.' }
  } elseif ($null -ne $healthState) {
    $summary = "Component store reports '$healthState'."
  } elseif ($needsAdmin) {
    $summary = 'The component-store corruption check needs administrator rights; only the pending-reboot key was checked.'
  } else {
    $summary = 'Component-store state could not be determined.'
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Disk {
  $findings = @(); $needsAdmin = $false
  $sysDrive = $env:SystemDrive
  $dirtyKnown = $false

  # NTFS dirty bit (fsutil needs elevation)
  try {
    $raw = & "$env:SystemRoot\System32\fsutil.exe" dirty query $sysDrive 2>&1
    $txt = ((@($raw) | ForEach-Object { "$_" }) -join ' ')
    if ($txt -match 'is NOT Dirty') {
      $dirtyKnown = $true
    } elseif ($txt -match 'is Dirty') {
      $dirtyKnown = $true
      $findings += New-Finding 'ntfs-dirty-bit' 'critical' "The NTFS dirty bit is set on $sysDrive — the file system needs a disk check before anything else." ([ordered]@{ output = $txt.Trim() })
    } elseif (-not $IsAdmin) {
      $needsAdmin = $true
    } else {
      $findings += New-Finding 'dirty-query-indeterminate' 'info' "fsutil dirty query returned an unrecognized result." ([ordered]@{ output = $txt.Trim() })
    }
  } catch {
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
    $findings += New-Finding 'physical-disk-query-failed' 'info' "Physical drive health could not be queried: $diskQueryError" ([ordered]@{ drivesInspected = $diskEvidence.Count })
  }

  # NTFS / disk / storage-controller error events, last 7 days
  # (Ntfs 55/98/130, disk 7/51/153, storahci 129 = controller reset)
  $ev = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = @('Ntfs','disk','storahci'); Id = @(55,98,130,7,51,153,129); StartTime = (Get-Date).AddDays(-7) })
  if ($ev.Count -gt 0) {
    $sev = 'warning'
    if (@($ev | Where-Object { $_.Id -eq 55 -or $_.Id -eq 98 }).Count -gt 0) { $sev = 'critical' }
    $findings += New-Finding 'disk-error-events' $sev "$($ev.Count) NTFS/disk/storage-controller error event(s) in the System log in the last 7 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
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
        $findings += New-Finding 'chkdsk-scan-failed' 'info' "Online chkdsk scan could not run: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $unhealthy = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($unhealthy -eq 0) {
    # Never assert drive health that was not actually inspected.
    $drivePart = "all $($diskEvidence.Count) physical drive(s) report healthy"
    if ($null -ne $diskQueryError) { $drivePart = 'physical drive health could not be inspected (query failed)' }
    elseif ($diskEvidence.Count -eq 0) { $drivePart = 'no physical drives were enumerated' }
    if ($dirtyKnown) { $summary = "No dirty bit, no disk error events, and $drivePart." }
    elseif ($needsAdmin) { $summary = "No disk error events and $drivePart; the NTFS dirty-bit check needs administrator rights." }
    else { $summary = "No recent disk error events and $drivePart." }
  } else {
    $summary = "Disk problems detected — see findings ($unhealthy issue(s))."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-WindowsUpdate {
  $findings = @(); $needsAdmin = $false

  # Service pipeline. Stopped is normal for demand-start services; Disabled start type is the signal.
  $svc = @(Get-ServiceInfo @('wuauserv','bits','cryptsvc','DoSvc','UsoSvc'))
  $disabled = @($svc | Where-Object { $_.present -and $_.startType -eq 'Disabled' })
  if ($disabled.Count -gt 0) {
    $names = @($disabled | ForEach-Object { $_.name }) -join ', '
    $findings += New-Finding 'wu-service-disabled' 'warning' "Update pipeline service(s) disabled: $names — Windows Update cannot work until re-enabled." ([ordered]@{ services = $svc })
  }

  # Failure events, last 30 days (20 = install failure, 31 = scan failure)
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = @(20,31); StartTime = (Get-Date).AddDays(-30) })
  if ($ev.Count -gt 0) {
    $findings += New-Finding 'wu-failure-events' 'warning' "$($ev.Count) Windows Update failure event(s) in the last 30 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  }

  # Staleness: last installed hotfix
  $lastHotfix = $null
  try {
    $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) {
      $lastHotfix = $hf.InstalledOn.ToString('yyyy-MM-dd')
      $ageDays = [int]((Get-Date) - $hf.InstalledOn).TotalDays
      if ($ageDays -gt 60) {
        $findings += New-Finding 'wu-stale' 'warning' "No update has installed in $ageDays days (last: $($hf.HotFixID) on $lastHotfix) — updates may be stuck." ([ordered]@{ lastHotfix = $hf.HotFixID; installedOn = $lastHotfix; ageDays = $ageDays })
      }
    }
  } catch {}

  # Update history via COM (works unelevated) — failure HResults from the last 25 operations
  $historyChecked = $false
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

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($null -ne $lastHotfix) { $summary = "Update pipeline services look normal and the last update installed on $lastHotfix." }
    else { $summary = 'Update pipeline services look normal and no recent failures were found.' }
    if (-not $historyChecked) { $summary = $summary + ' (Update history could not be read.)' }
  } else {
    $summary = "Windows Update shows $issues issue(s) — see findings."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Network {
  $findings = @(); $needsAdmin = $false

  # Link layer
  $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
  $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
  $adapterEvidence = @()
  foreach ($a in $adapters) {
    $adapterEvidence += [ordered]@{ name = "$($a.Name)"; description = "$($a.InterfaceDescription)"; status = "$($a.Status)"; linkSpeed = "$($a.LinkSpeed)" }
  }
  if ($adapters.Count -gt 0 -and $up.Count -eq 0) {
    $findings += New-Finding 'no-link' 'critical' 'No physical network adapter has link — check cable/Wi-Fi before anything else.' ([ordered]@{ adapters = $adapterEvidence })
  }

  # Default gateway reachability
  $gw = $null; $gwOk = $false
  try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    if ($route) { $gw = "$($route.NextHop)" }
  } catch {}
  if ($gw) {
    try { $gwOk = [bool](Test-NetConnection -ComputerName $gw -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $gwOk = $false }
  } elseif ($up.Count -gt 0) {
    $findings += New-Finding 'no-default-route' 'critical' 'A network adapter is up but there is no default route — DHCP/IP configuration problem.' ([ordered]@{ adapters = $adapterEvidence })
  }

  # Raw-IP internet (no DNS involved) and DNS resolution
  $ipOk = $false
  try { $ipOk = [bool](Test-NetConnection -ComputerName '1.1.1.1' -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $ipOk = $false }
  $dnsOk = $false
  try { $null = Resolve-DnsName -Name 'microsoft.com' -ErrorAction Stop; $dnsOk = $true } catch { $dnsOk = $false }

  # NCSI-style captive-portal probe (§3.4): HTTP reachability of the connectivity endpoint
  $ncsiOk = $false
  try { $ncsiOk = [bool](Test-NetConnection -ComputerName 'www.msftconnecttest.com' -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $ncsiOk = $false }

  # Configured DNS servers
  $dnsServers = @()
  try {
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
  } catch {}

  $layers = [ordered]@{ link = ($up.Count -gt 0); gateway = $gwOk; internetByIp = $ipOk; dns = $dnsOk; ncsiHttp = $ncsiOk; gatewayAddress = $gw; dnsServers = $dnsServers }

  # The discriminator: IP works but DNS fails => resolver problem, not connectivity.
  if ($ipOk -and -not $dnsOk) {
    $findings += New-Finding 'dns-broken' 'critical' 'The internet is reachable by raw IP but name resolution fails — this is a DNS problem (flush DNS / change resolver), not a connectivity problem.' $layers
  } elseif (-not $ipOk -and $gwOk) {
    $findings += New-Finding 'wan-down' 'critical' 'The gateway responds but the internet is unreachable — the problem is upstream (modem/ISP), not this PC.' $layers
  } elseif (-not $ipOk -and $gw -and -not $gwOk -and $up.Count -gt 0) {
    $findings += New-Finding 'gateway-unreachable' 'critical' 'Link is up but the default gateway does not respond — local network or router problem.' $layers
  } elseif (-not $dnsOk -and -not $ipOk -and $up.Count -gt 0 -and -not $gw) {
    # already covered by no-default-route
  }

  # IP + DNS work but the NCSI HTTP endpoint does not: captive portal / HTTP filtering.
  if ($ipOk -and $dnsOk -and -not $ncsiOk) {
    $findings += New-Finding 'captive-portal-suspected' 'warning' 'Raw IP and DNS work but the NCSI connectivity endpoint is unreachable over HTTP — possible captive portal or HTTP-level filtering.' $layers
  }

  # Gateway drops ICMP while traffic flows: informational, not a fault.
  if ($gw -and -not $gwOk -and $ipOk -and $dnsOk) {
    $findings += New-Finding 'gateway-icmp-blocked' 'info' 'The default gateway does not answer ICMP ping while internet and DNS both work — the router likely just drops ping; traffic itself is flowing.' $layers
  }

  $summary = ''
  if (@($findings | Where-Object { $_.severity -ne 'info' }).Count -eq 0) {
    # Build the healthy summary from the per-layer results — never assert a layer that did not pass.
    $okLayers = @()
    if ($up.Count -gt 0) { $okLayers += 'link' }
    if ($gwOk) { $okLayers += 'gateway' }
    if ($ipOk) { $okLayers += 'raw-IP internet' }
    if ($dnsOk) { $okLayers += 'DNS resolution' }
    if ($ncsiOk) { $okLayers += 'HTTP (NCSI)' }
    $summary = "Healthy network layers: $($okLayers -join ', ')."
    if ($gw -and -not $gwOk -and $ipOk -and $dnsOk) { $summary = $summary + ' Gateway ICMP is blocked/unreachable while traffic flows normally.' }
  } else {
    $broken = @()
    if ($up.Count -eq 0 -and $adapters.Count -gt 0) { $broken += 'link' }
    if (-not $gwOk) { $broken += 'gateway' }
    if (-not $ipOk) { $broken += 'internet' }
    if (-not $dnsOk) { $broken += 'DNS' }
    if (-not $ncsiOk) { $broken += 'HTTP (NCSI)' }
    $summary = "Network problem at: $($broken -join ', ') — see findings for which layer to fix."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Store {
  $findings = @(); $needsAdmin = $false

  # Store package status (per-user query works unelevated; -AllUsers needs admin)
  $pkgStatus = $null
  try {
    if ($IsAdmin) { $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 }
    else          { $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1 }
    if (-not $pkg) {
      $findings += New-Finding 'store-missing' 'warning' 'The Microsoft Store package is not installed for this user.' $null
    } else {
      $pkgStatus = "$($pkg.Status)"
      if ($pkgStatus -ne 'Ok') {
        $findings += New-Finding 'store-package-broken' 'warning' "The Microsoft Store package reports status '$pkgStatus' — re-registration is indicated." ([ordered]@{ name = "$($pkg.Name)"; version = "$($pkg.Version)"; status = $pkgStatus })
      }
    }
  } catch {
    $findings += New-Finding 'store-query-failed' 'info' "Could not query the Store package: $($_.Exception.Message)" $null
  }

  # Dependency services (demand-start; Disabled is the failure signal)
  $svc = @(Get-ServiceInfo @('AppXSvc','ClipSVC','InstallService','DoSvc'))
  $disabled = @($svc | Where-Object { $_.present -and $_.startType -eq 'Disabled' })
  if ($disabled.Count -gt 0) {
    $names = @($disabled | ForEach-Object { $_.name }) -join ', '
    $findings += New-Finding 'store-service-disabled' 'warning' "Store dependency service(s) disabled: $names — Store installs/licensing will fail." ([ordered]@{ services = $svc })
  }

  # App deployment errors, last 7 days
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-7) })
  if ($ev.Count -ge 5) {
    $findings += New-Finding 'appx-deploy-errors' 'warning' "$($ev.Count) app deployment error(s) in the last 7 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  } elseif ($ev.Count -gt 0) {
    $findings += New-Finding 'appx-deploy-errors-few' 'info' "$($ev.Count) app deployment error(s) in the last 7 days — occasional errors here are normal." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  }

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($pkgStatus -eq 'Ok') { $summary = 'The Store package reports Ok and its dependency services are enabled.' }
    else { $summary = 'No Store problems detected.' }
  } else {
    $summary = "Microsoft Store shows $issues issue(s) — see findings."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Search {
  $findings = @(); $needsAdmin = $false

  # Indexer service
  $svc = @(Get-ServiceInfo @('WSearch'))[0]
  if (-not $svc.present) {
    $findings += New-Finding 'wsearch-missing' 'info' 'The Windows Search service is not present on this system.' $null
  } elseif ($svc.startType -eq 'Disabled') {
    $findings += New-Finding 'wsearch-disabled' 'warning' 'The Windows Search service is disabled — search and Start-menu results will not work.' $svc
  } elseif ($svc.status -ne 'Running') {
    $findings += New-Finding 'wsearch-not-running' 'warning' "The Windows Search service is $($svc.status) (start type: $($svc.startType))." $svc
  }

  # Indexer / shell host processes. SearchHost only lives while the search UI is open,
  # so its absence is NOT flagged; a missing StartMenuExperienceHost is only informational.
  $procNames = @('SearchIndexer','SearchHost','StartMenuExperienceHost')
  $running = @()
  try { $running = @(Get-Process -Name $procNames -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Select-Object -Unique) } catch {}
  if ($svc.status -eq 'Running' -and $running -notcontains 'SearchIndexer') {
    $findings += New-Finding 'indexer-process-missing' 'warning' 'WSearch is running but the SearchIndexer process is not — the indexer may be crashing.' ([ordered]@{ runningProcesses = $running })
  }
  if ($running -notcontains 'StartMenuExperienceHost') {
    $findings += New-Finding 'startmenu-host-not-running' 'info' 'StartMenuExperienceHost is not currently running (it normally restarts on demand).' ([ordered]@{ runningProcesses = $running })
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
      if ("$($_.Exception.Message)" -match 'denied' -or $_.Exception -is [System.UnauthorizedAccessException]) { $idxDenied = $true }
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
  if ($searchErrs.Count -ge 3) {
    $findings += New-Finding 'search-provider-errors' 'warning' "$($searchErrs.Count) Windows Search provider error(s) in the Application log in the last 7 days." ([ordered]@{ count = $searchErrs.Count; sample = @(ConvertTo-FFEventEvidence -Events $searchErrs -First 3) })
  } elseif ($searchErrs.Count -gt 0) {
    $findings += New-Finding 'search-provider-errors-few' 'info' "$($searchErrs.Count) Windows Search provider error(s) in the last 7 days — occasional entries here are normal." ([ordered]@{ count = $searchErrs.Count; sample = @(ConvertTo-FFEventEvidence -Events $searchErrs -First 3) })
  }

  # Shell host crashes (Application log, Event 1000), last 7 days.
  # Capped; when the cap is hit the count is honestly worded as "at least N".
  $crashCap = 256
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddDays(-7) } -MaxEvents $crashCap)
  $crashes = @($ev | Where-Object { $_.Message -match 'SearchHost|StartMenuExperienceHost|SearchIndexer' })
  if ($crashes.Count -gt 0) {
    $countText = "$($crashes.Count)"
    if ($ev.Count -ge $crashCap) { $countText = "at least $($crashes.Count)" }
    $findings += New-Finding 'shell-host-crashes' 'warning' "$countText crash(es) of search/Start-menu hosts in the last 7 days." ([ordered]@{ count = $crashes.Count; scannedEvents = $ev.Count; scanCap = $crashCap; sample = @(ConvertTo-FFEventEvidence -Events $crashes -First 3) })
  }

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($needsAdmin) { $summary = 'The search indexer is running normally with no recent shell crashes; the index-size check needs administrator rights.' }
    else { $summary = 'The search indexer is running normally with no recent shell crashes.' }
  } else { $summary = "Search/Start menu shows $issues issue(s) — see findings." }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Printing {
  $findings = @(); $needsAdmin = $false

  $svc = @(Get-ServiceInfo @('Spooler'))[0]
  if ($svc.present -and $svc.status -ne 'Running' -and $svc.startType -eq 'Automatic') {
    $findings += New-Finding 'spooler-not-running' 'warning' "The Print Spooler service is $($svc.status) but set to start automatically." $svc
  } elseif ($svc.present -and $svc.startType -eq 'Disabled') {
    $findings += New-Finding 'spooler-disabled' 'info' 'The Print Spooler service is disabled (intentional on some gaming rigs; printing will not work).' $svc
  }

  # Stuck spool files (directory is admin-ACLed; degrade gracefully)
  $spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
  try {
    $files = @(Get-ChildItem -Path $spoolDir -File -ErrorAction Stop)
    if ($files.Count -gt 0) {
      $oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
      $findings += New-Finding 'spool-files-present' 'warning' "$($files.Count) file(s) sitting in the spool folder (oldest: $($oldest.ToString('s'))) — possible stuck print jobs." ([ordered]@{ count = $files.Count; oldest = $oldest.ToString('s') })
    }
  } catch {
    if (-not $IsAdmin) { $needsAdmin = $true }
  }

  # Printers in Error/Offline state + stuck jobs via the print-queue API (§3.7).
  # Get-PrintJob works without admin, so the stuck-job signal survives even when
  # the admin-ACLed spool folder above is unreadable.
  $printerEvidence = @()
  $stuckJobs = @()
  try {
    foreach ($p in @(Get-Printer -ErrorAction Stop)) {
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
      } catch {} # per-printer job query can fail for virtual/offline queues — not fatal
    }
  } catch {}
  if ($stuckJobs.Count -gt 0) {
    $findings += New-Finding 'print-jobs-stuck' 'warning' "$($stuckJobs.Count) print job(s) report an Error/Blocked status — the queue is stuck." ([ordered]@{ count = $stuckJobs.Count; jobs = $stuckJobs })
  }

  # PrintService/Admin errors, last 7 days
  $ev = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = @(1,2); StartTime = (Get-Date).AddDays(-7) })
  if ($ev.Count -gt 0) {
    $findings += New-Finding 'print-error-events' 'warning' "$($ev.Count) print service error(s) in the last 7 days." ([ordered]@{ count = $ev.Count; sample = @(ConvertTo-FFEventEvidence -Events $ev -First 3) })
  }

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($needsAdmin) { $summary = 'No printer problems detected; the spool-folder check needs administrator rights.' }
    else { $summary = 'Spooler, print queue, and printers all look normal.' }
  } else {
    $summary = "Printing shows $issues issue(s) — see findings."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Stability {
  $findings = @(); $needsAdmin = $false
  $since = (Get-Date).AddDays(-30)

  # Bug checks (BSODs): Event 1001, stop code in EventData
  $bug = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -MaxEvents 10)
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
    if ("$($_.Exception.Message)" -match 'denied' -or $_.Exception -is [System.UnauthorizedAccessException]) { $miniDenied = $true }
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

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($needsAdmin) { $summary = 'No blue screens and no unexpected shutdowns in the last 30 days; the full dump inventory needs administrator rights.' }
    else { $summary = 'No blue screens and no unexpected shutdowns in the last 30 days.' }
  } else { $summary = "Stability shows $issues issue(s) in the last 30 days — see findings." }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-DiskSpace {
  $findings = @(); $needsAdmin = $false
  $sysLetter = ($env:SystemDrive).TrimEnd(':')
  $volumes = @()
  try {
    foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
      $freePct = [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1)
      $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
      $sizeGB = [math]::Round($v.Size / 1GB, 1)
      $isSystem = ("$($v.DriveLetter)" -eq $sysLetter)
      $row = [ordered]@{ drive = "$($v.DriveLetter)"; freePct = $freePct; freeGB = $freeGB; sizeGB = $sizeGB; isSystemDrive = $isSystem }
      $volumes += $row
      if ($freePct -lt 10 -or ($isSystem -and $freeGB -lt 20)) {
        $findings += New-Finding "space-critical-$($v.DriveLetter)" 'critical' "Drive $($v.DriveLetter): is critically low on space ($freeGB GB free, $freePct%) — Windows updates fail under ~20 GB free on the system drive." $row
      } elseif ($freePct -lt 15) {
        $findings += New-Finding "space-low-$($v.DriveLetter)" 'warning' "Drive $($v.DriveLetter): is low on space ($freeGB GB free, $freePct%)." $row
      }
    }
  } catch {
    $findings += New-Finding 'volume-query-failed' 'info' "Could not enumerate volumes: $($_.Exception.Message)" $null
  }

  # Deep, read-only: component-store bloat analysis (§3.9). DISM's analyze pass only
  # reads the store and prints 'Component Store Cleanup Recommended : Yes/No'.
  if ($Deep) {
    if ($IsAdmin) {
      try {
        $raw = & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
        $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')
        if ($txt -match 'Component Store Cleanup Recommended\s*:\s*(\S+)') {
          $rec = $Matches[1]
          $evi = [ordered]@{ cleanupRecommended = $rec }
          if ($txt -match '(?m)^\s*Actual Size of Component Store\s*:\s*(.+?)\s*$') { $evi.actualSize = $Matches[1] }
          if ($rec -match '^Yes') {
            $findings += New-Finding 'component-store-cleanup-recommended' 'warning' 'DISM reports component-store cleanup is recommended — reclaimable space is available (StartComponentCleanup).' $evi
          } else {
            $findings += New-Finding 'component-store-cleanup-not-needed' 'info' 'DISM reports no component-store cleanup is needed.' $evi
          }
        } else {
          $findings += New-Finding 'component-store-analyze-indeterminate' 'info' 'DISM AnalyzeComponentStore ran but its output could not be parsed.' $null
        }
      } catch {
        $findings += New-Finding 'component-store-analyze-failed' 'info' "DISM AnalyzeComponentStore could not run: $($_.Exception.Message)" $null
      }
    } else {
      $needsAdmin = $true
    }
  }

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    $sys = @($volumes | Where-Object { $_.isSystemDrive }) | Select-Object -First 1
    if ($sys) { $summary = "All fixed volumes have healthy free space (system drive: $($sys.freeGB) GB free, $($sys.freePct)%)." }
    else { $summary = 'All fixed volumes have healthy free space.' }
  } else {
    $summary = "$issues volume(s) low on space — see findings."
  }
  # Always attach the per-volume table as informational evidence.
  $findings += New-Finding 'volume-inventory' 'info' 'Per-volume free space captured.' ([ordered]@{ volumes = $volumes })
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Boot {
  $findings = @(); $needsAdmin = $false

  # Boot time trend: Diagnostics-Performance Event 100, BootTime (ms) from named EventData
  $boots = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 10)
  $bootEventError = $script:FFLastEventError
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
    if ($avgMs -gt 180000) {
      $findings += New-Finding 'boot-slow' 'warning' "Boots average $([math]::Round($avgMs/1000,0)) s — well beyond a healthy range for this class of hardware." ([ordered]@{ averageMs = $avgMs })
    }
  } elseif ($null -ne $bootEventError) {
    $findings += New-Finding 'boot-log-unreadable' 'info' "Boot performance log could not be read: $bootEventError" $null
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

  # Fast Startup state (powercfg /a parse + HiberbootEnabled registry evidence)
  $fastState = 'unknown'
  try {
    $pa = & "$env:SystemRoot\System32\powercfg.exe" /a 2>&1
    $txt = ((@($pa) | ForEach-Object { "$_" }) -join "`n")
    $availSection = $null
    if ($txt -match '(?s)available on this system:\s*(.*?)(The following sleep states are not available|$)') { $availSection = $Matches[1] }
    if ($null -ne $availSection -and $availSection -match 'Fast Startup') { $fastState = 'available' }
    elseif ($txt -match 'Fast Startup') { $fastState = 'unavailable' }
  } catch {}
  $hiberboot = $null
  try { $hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled } catch {}
  $fastDetail = 'Fast Startup state captured.'
  if ($fastState -eq 'available' -and $hiberboot -eq 1) { $fastDetail = 'Fast Startup is available and enabled.' }
  elseif ($fastState -eq 'available' -and $hiberboot -eq 0) { $fastDetail = 'Fast Startup is available but turned off.' }
  elseif ($fastState -eq 'unavailable') { $fastDetail = 'Fast Startup is not available on this system (hibernation off or unsupported).' }
  $findings += New-Finding 'fast-startup-state' 'info' $fastDetail ([ordered]@{ powercfgState = $fastState; hiberbootEnabled = $hiberboot })

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    if ($null -ne $avgMs) { $summary = "Boot times look normal (average $([math]::Round($avgMs/1000,1)) s over the last $($bootRows.Count) boot(s))." }
    else { $summary = 'No boot-time degradation signals were found (no recent boot-performance events recorded).' }
  } else {
    $summary = "Boot performance shows $issues issue(s) — see findings."
  }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Audio {
  $findings = @(); $needsAdmin = $false

  $svc = @(Get-ServiceInfo @('Audiosrv','AudioEndpointBuilder'))
  foreach ($s in $svc) {
    if ($s.present -and $s.status -ne 'Running') {
      $findings += New-Finding "audio-service-stopped-$($s.name)" 'critical' "The $($s.name) service is $($s.status) — audio will not work until it runs." $s
    }
  }

  # PnP audio devices in Error state
  $devEvidence = @()
  $pnpError = $null
  try {
    foreach ($d in @(Get-PnpDevice -Class @('AudioEndpoint','MEDIA') -ErrorAction Stop)) {
      if ("$($d.Status)" -eq 'Error') {
        $row = [ordered]@{ name = "$($d.FriendlyName)"; status = "$($d.Status)"; instanceId = "$($d.InstanceId)" }
        $devEvidence += $row
        $findings += New-Finding 'audio-device-error' 'warning' "Audio device '$($d.FriendlyName)' is in an error state — driver problem." $row
      }
    }
  } catch { $pnpError = "$($_.Exception.Message)" }
  if ($null -ne $pnpError) {
    $findings += New-Finding 'audio-pnp-query-failed' 'info' "PnP audio-device state could not be queried: $pnpError" $null
  }

  # CIM sound devices (§3.11): Error/Degraded status signals a driver problem
  $sndEvidence = @()
  $cimError = $null
  try {
    foreach ($sd in @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction Stop)) {
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
    $findings += New-Finding 'audio-cim-query-failed' 'info' "Win32_SoundDevice could not be queried: $cimError" $null
  }

  $issues = @($findings | Where-Object { $_.severity -ne 'info' }).Count
  $summary = ''
  if ($issues -eq 0) {
    # Only claim devices are error-free when at least one device query actually succeeded.
    if ($null -ne $pnpError -and $null -ne $cimError) { $summary = 'Audio services are running, but device state could not be queried (PnP and CIM both failed).' }
    else { $summary = 'Audio services are running and no audio device reports an error.' }
  }
  else { $summary = "Audio shows $issues issue(s) — see findings." }
  @{ summary = $summary; findings = $findings; needsAdmin = $needsAdmin }
}

function Probe-Activation {
  $findings = @(); $needsAdmin = $false
  $statusText = $null
  try {
    # Server-side narrowed WQL: ApplicationID is the Windows-OS licensing GUID; with the
    # explicit property list it keeps the (notoriously slow) SLP provider to one row.
    $q = "SELECT Name, LicenseStatus, LicenseStatusReason FROM SoftwareLicensingProduct " +
         "WHERE ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
    $lic = Get-CimInstance -Query $q -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $lic) {
      $findings += New-Finding 'activation-indeterminate' 'info' 'No Windows license with a product key was found via CIM.' $null
    } else {
      $map = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Out-of-box grace'; 3 = 'Out-of-tolerance grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }
      $code = [int]$lic.LicenseStatus
      $statusText = $map[$code]
      if ($null -eq $statusText) { $statusText = "Unknown ($code)" }
      $evi = [ordered]@{ product = "$($lic.Name)"; licenseStatus = $code; licenseStatusText = $statusText; licenseStatusReason = ('0x{0:X8}' -f ($lic.LicenseStatusReason -band 0xFFFFFFFF)) }
      if ($code -ne 1) {
        $findings += New-Finding 'windows-not-activated' 'warning' "Windows license status is '$statusText' — activation needs attention." $evi
      }
    }
  } catch {
    $findings += New-Finding 'activation-query-failed' 'info' "Could not query license state: $($_.Exception.Message)" $null
  }

  $summary = ''
  if ($statusText -eq 'Licensed') { $summary = 'Windows is activated (licensed).' }
  elseif ($null -ne $statusText) { $summary = "Windows license status: $statusText." }
  else { $summary = 'Windows activation state could not be determined.' }
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
    durationMs = $m.durationMs
  }
}

$out = $null
$exitCode = 0
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
    $out = [ordered]@{
      ok         = $true
      isAdmin    = $IsAdmin
      scannedAt  = (Get-Date).ToString('s')
      deep       = [bool]$Deep
      durationMs = [int]$sw.ElapsedMilliseconds
      categories = $cats
      totals     = $totals
    }
  }
  'probe' {
    if (-not $Category -or -not $ProbeMap.Contains($Category)) {
      $out = [ordered]@{ ok = $false; error = "Unknown or missing category '$Category'."; validCategories = @($ProbeMap.Keys) }
      $exitCode = 2   # invalid input: JSON error doc on stdout AND a non-zero exit
    } else {
      $out = Invoke-Category $Category
    }
  }
  'list' {
    $out = [ordered]@{ ok = $true; categories = @($ProbeMap.Keys) }
  }
}

Write-FFJson -InputObject $out -Depth 12
exit $exitCode
