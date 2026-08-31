<#
  LOCALE :: time synchronization detection (repair.ps1 Get-NtpDetection)

  The deciding evidence is the System log keyed by NUMERIC event id (35 = successful sync;
  36/47/50 = failure signals), because numbers are not localized. `w32tm /query /status` is
  a DOCUMENTED English-only supplement, reached only when the log cannot answer, and its
  date is parsed with an explicit invariant culture through TryParse.

  What this must get right:
    - locale-independent path: event 35 inside the window = healthy, whatever the language
    - an absent event 35 only becomes a PROBLEM once the log is proven to cover the window
    - a localized w32tm status = reason 'unparseable' (a refuse reason), never 'healthy'
    - an en-GB dd/MM date must not be silently day/month-swapped into a wrong verdict
    - a domain member is 'not-applicable', because repointing it at pool.ntp.org breaks
      Kerberos once the clock drifts past the five-minute tolerance
#>

function Get-FFNtpDetection {
  param(
    [string]$ServiceStatus = 'Stopped', [string]$StartType = 'Manual', [bool]$ServiceExists = $true,
    [bool]$PartOfDomain = $false, [string]$Domain = 'WORKGROUP',
    [bool]$ConfigReadable = $true, [string]$W32TimeType = 'NTP',
    [object]$Id35Recent = $null,      # $null = none; a DateTime = one event at that time
    [object]$Id35Ever = $null,
    [bool]$LogCoversWindow = $true,
    [string]$EventError = $null,      # non-null => the channel could not be read at all
    [string]$W32tmText = ''
  )
  $ctx = @{
    svcStatus = $ServiceStatus; startType = $StartType; svcExists = $ServiceExists
    partOfDomain = $PartOfDomain; domain = $Domain; cfgReadable = $ConfigReadable; type = $W32TimeType
    id35Recent = $Id35Recent; id35Ever = $Id35Ever; covers = $LogCoversWindow
    eventError = $EventError; w32tmText = $W32tmText; w32tmCalled = $false
  }
  $r = Invoke-InEngineScope -Engine 'repair' -Ctx $ctx -Mocks {
    function Get-Service { param($Name, $ErrorAction)
      if (-not $TestCtx.svcExists) { throw "Cannot find any service with service name '$Name'." }
      [pscustomobject]@{ Name = $Name; Status = $TestCtx.svcStatus; StartType = $TestCtx.startType } }
    function Get-FFDomainState {
      [ordered]@{ partOfDomain = $TestCtx.partOfDomain; domain = $TestCtx.domain; readable = $true; error = $null } }
    function Get-W32TimeConfig {
      [ordered]@{ readable = $TestCtx.cfgReadable; type = $TestCtx.type; ntpServer = 'time.windows.com,0x9'; error = $null } }
    function Get-FFEvents { param([hashtable]$Filter, [int]$MaxEvents = 0)
      $script:FFLastEventError = $TestCtx.eventError
      $script:FFLastEventErrorKind = $(if ($TestCtx.eventError) { 'access-denied' } else { $null })
      $script:FFLastEventUnreadable = [bool]$TestCtx.eventError
      if ($TestCtx.eventError) { return @() }
      $ids = @($Filter['Id'])
      $hasStart = $Filter.ContainsKey('StartTime')
      $hasProvider = $Filter.ContainsKey('ProviderName')
      if (-not $hasProvider) {
        # The "does the log even cover the window?" probe.
        if ($TestCtx.covers) { return @(New-FFEventRecord -Id 1 -ProviderName 'Microsoft-Windows-Kernel-General') }
        return @()
      }
      if ($ids -contains 35) {
        if ($hasStart) {
          if ($null -ne $TestCtx.id35Recent) { return @(New-FFEventRecord -Id 35 -TimeCreated $TestCtx.id35Recent) }
          return @()
        }
        if ($null -ne $TestCtx.id35Ever) { return @(New-FFEventRecord -Id 35 -TimeCreated $TestCtx.id35Ever) }
        return @()
      }
      if ($ids -contains 36) {
        return @(New-FFEventRecord -Id 36 -TimeCreated (Get-Date) -Message 'The time service has not synchronized the system time for 86400 seconds.')
      }
      @() }
    function cmd { param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
      $TestCtx.w32tmCalled = $true
      @("$($TestCtx.w32tmText)" -split "`r?`n") }
  } -Test { $TestCtx.det = Get-NtpDetection }
  [pscustomobject]@{ Det = $r.det; W32tmCalled = [bool]$r.w32tmCalled }
}

# ---------------- the locale-independent path ----------------

Register-FFTest -Area 'LOCALE' -Name 'ntp: a recent event 35 is healthy on any UI language' -Body {
  foreach ($fx in @('w32tm/status-de-DE.txt', 'w32tm/status-ja-JP.txt', 'w32tm/status-en-US-unspecified.txt')) {
    $r = Get-FFNtpDetection -Id35Recent (Get-Date).AddHours(-4) -W32tmText (Get-FFFixture -Path $fx)
    Assert-Eq 'healthy' $r.Det.state "event 35 inside the window is proof of sync, whatever w32tm prints ($fx)"
    Assert-False $r.W32tmCalled 'the localized text rung must not even be reached'
  }
}

Register-FFTest -Area 'STATE' -Name 'ntp: a stopped demand-start service with a recent sync is NORMAL, not a fault' -Body {
  # w32time is Manual/demand-start on stock Windows 11 and is stopped between syncs. Treating
  # "not Running" as a problem reported a fault on every healthy machine.
  $r = Get-FFNtpDetection -ServiceStatus 'Stopped' -StartType 'Manual' -Id35Recent (Get-Date).AddHours(-4)
  Assert-Eq 'healthy' $r.Det.state 'a stopped demand-start service with a recent sync is healthy'
  Assert-Match 'NORMAL' $r.Det.detail 'and the wording must explain why it is normal'
}

Register-FFTest -Area 'STATE' -Name 'ntp: no recent sync on a log that DOES cover the window is a problem' -Body {
  $stopped = Get-FFNtpDetection -ServiceStatus 'Stopped' -LogCoversWindow $true -Id35Recent $null
  Assert-Eq 'problem' $stopped.Det.state 'a proven-empty window plus a stopped service is a real fault'
  Assert-Eq 'w32time-not-running' @($stopped.Det.relevantFindings)[0].id 'the more specific finding is raised'

  $running = Get-FFNtpDetection -ServiceStatus 'Running' -LogCoversWindow $true -Id35Recent $null
  Assert-Eq 'problem' $running.Det.state 'a running service with no sync in the window is still a fault'
  Assert-Eq 'ntp-sync-stale' @($running.Det.relevantFindings)[0].id 'the stale-sync finding is raised'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'ntp: a log that does NOT reach back far enough proves nothing' -Body {
  # Absence of event 35 in a log that rolled over is not evidence the clock is unsynced.
  $r = Get-FFNtpDetection -ServiceStatus 'Stopped' -LogCoversWindow $false -Id35Recent $null -W32tmText ''
  Assert-Ne 'healthy' $r.Det.state 'a rolled-over log must not be read as healthy'
  Assert-Ne 'problem' $r.Det.state 'nor as a problem'
  Assert-Eq 'indeterminate' $r.Det.state 'the only honest answer is indeterminate'
  Assert-Eq 'unparseable' $r.Det.reason 'and the reason must be a refuse reason so the repair declines'
  Assert-Match 'rolled over' $r.Det.detail 'the wording must name the rollover as the reason'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'ntp: an unreadable System log refuses rather than guesses' -Body {
  $r = Get-FFNtpDetection -EventError 'Attempted to perform an unauthorized operation.' -W32tmText ''
  Assert-Eq 'indeterminate' $r.Det.state 'a denied channel is indeterminate'
  Assert-Eq 'unparseable' $r.Det.reason 'unparseable is a refuse reason'
  Assert-Match 'refuses rather than guessing' $r.Det.detail 'the wording must say the repair refuses'
}

# ---------------- rung 2: the documented English-only w32tm parse ----------------

Register-FFTest -Area 'LOCALE' -Name 'ntp: English w32tm text is read only when the event log could not answer' -Body {
  $stamp = (Get-Date).AddHours(-2).ToString('M/d/yyyy h:mm:ss tt', [System.Globalization.CultureInfo]::InvariantCulture)
  $text = (Get-FFFixture -Path 'w32tm/status-en-US-recent.txt') -replace '@@STAMP@@', $stamp
  $r = Get-FFNtpDetection -EventError 'denied' -W32tmText $text
  Assert-True $r.W32tmCalled 'the English rung must be reached when the log is unreadable'
  Assert-Eq 'healthy' $r.Det.state 'a recent English sync time reads as healthy'
  Assert-Match "English status text" $r.Det.detail 'and the sentence must declare which rung answered'
}

Register-FFTest -Area 'LOCALE' -Name 'ntp: English "unspecified" means never synced' -Body {
  $r = Get-FFNtpDetection -EventError 'denied' -W32tmText (Get-FFFixture -Path 'w32tm/status-en-US-unspecified.txt')
  Assert-Eq 'problem' $r.Det.state 'a never-synced clock is a real problem'
  Assert-Eq 'ntp-never-synced' @($r.Det.relevantFindings)[0].id 'and it has its own finding id'
}

foreach ($row in @(
  @{ Lang = 'de-DE'; File = 'w32tm/status-de-DE.txt' }
  @{ Lang = 'ja-JP'; File = 'w32tm/status-ja-JP.txt' }
  @{ Lang = 'stopped-service'; File = 'w32tm/status-service-not-running.txt' }
)) {
  Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Data $row -Name "ntp: $($row.Lang) w32tm text refuses, never reports healthy" -Body {
    $d = $FFTestData
    $r = Get-FFNtpDetection -EventError 'denied' -W32tmText (Get-FFFixture -Path $d.File)
    Assert-True $r.W32tmCalled 'the last rung is attempted'
    Assert-Eq 'indeterminate' $r.Det.state "a $($d.Lang) w32tm status cannot decide anything"
    Assert-Eq 'unparseable' $r.Det.reason 'the reason must be a refuse reason'
    Assert-Ne 'healthy' $r.Det.state 'a localized machine must never be graded healthy from prose that did not match'
    Assert-Match 'localized on this machine' $r.Det.detail 'the wording must name localization as the reason'
  }
}

Register-FFTest -Area 'LOCALE' -Doctrine 'rule 2' -Name 'ntp: an en-GB dd/MM date is never day/month-swapped into a verdict' -Body {
  # 30/08/2026 is unparseable as M/d/yyyy under the invariant culture. TryParse returns false,
  # so the code must fall through to the honest unknown rather than inventing a date.
  $r = Get-FFNtpDetection -EventError 'denied' -W32tmText (Get-FFFixture -Path 'w32tm/status-en-GB-daymonth.txt')
  Assert-Eq 'indeterminate' $r.Det.state 'a date the invariant parse cannot read must not become a verdict'
  Assert-Eq 'unparseable' $r.Det.reason 'and the repair must refuse'
}

Register-FFTest -Area 'LOCALE' -Name 'ntp: a stale English sync time is a problem, not healthy' -Body {
  $stamp = (Get-Date).AddDays(-30).ToString('M/d/yyyy h:mm:ss tt', [System.Globalization.CultureInfo]::InvariantCulture)
  $text = (Get-FFFixture -Path 'w32tm/status-en-US-recent.txt') -replace '@@STAMP@@', $stamp
  $r = Get-FFNtpDetection -EventError 'denied' -W32tmText $text
  Assert-Eq 'problem' $r.Det.state 'a 30-day-old sync is stale'
  Assert-Eq 'ntp-sync-stale' @($r.Det.relevantFindings)[0].id 'the stale finding is raised'
}

# ---------------- environment gates ----------------

Register-FFTest -Area 'STATE' -Doctrine 'rule 4' -Name 'ntp: a domain member is not-applicable (Kerberos skew safety)' -Body {
  $r = Get-FFNtpDetection -PartOfDomain $true -Domain 'corp.example.com' -W32TimeType 'NT5DS' -Id35Recent (Get-Date).AddHours(-1)
  Assert-Eq 'indeterminate' $r.Det.state 'a domain member must not be treated as a repair target'
  Assert-Eq 'not-applicable' $r.Det.reason 'not-applicable is the refuse reason the renderer already knows'
  Assert-Match 'Kerberos' $r.Det.detail 'the consequence must be spelled out'
  Assert-Match 'PDC emulator' $r.Det.detail 'and the correct remedy must be named'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'ntp: a domain member whose W32Time type cannot be read still refuses' -Body {
  # "I could not read whether this is safe" must take the cautious branch, not the optimistic one.
  $r = Get-FFNtpDetection -PartOfDomain $true -Domain 'corp.example.com' -ConfigReadable $false -W32TimeType ''
  Assert-Eq 'not-applicable' $r.Det.reason 'an unreadable source type on a domain member refuses'
  Assert-Match 'could not be read' $r.Det.detail 'and says so'
}

Register-FFTest -Area 'SKU' -Doctrine 'rule 2' -Name 'ntp: a machine with no w32time service at all is not-applicable' -Body {
  $r = Get-FFNtpDetection -ServiceExists $false
  Assert-Eq 'indeterminate' $r.Det.state 'a missing subsystem is not a fault to fix'
  Assert-Eq 'not-applicable' $r.Det.reason 'and it is reported as not-applicable'
  Assert-Match 'not present on this system' $r.Det.detail 'the wording must say the service is absent'
}
