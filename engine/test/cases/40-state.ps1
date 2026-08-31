<#
  STATE :: broken machines that are not "unhealthy machines"

  Services deleted outright rather than disabled, event channels that deny the read while
  reporting "no events found", empty logs, enormous logs, no network at all, and CIM /
  registry access denials. In each case there is a right answer and a wrong-but-comfortable
  answer, and the wrong one is always some flavour of "looks fine to me".
#>

# ---------------- event-log error classification ----------------

Register-FFTest -Area 'STATE' -Name 'events: failures are classified by error IDENTITY, not by message text' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Test {
    $TestCtx.kinds = [ordered]@{}
    foreach ($k in @('no-events', 'log-missing', 'provider-missing', 'access-denied', 'not-found', 'other')) {
      # The message is deliberately German, to prove nothing keys on English prose.
      $TestCtx.kinds[$k] = Get-FFEventErrorKind -ErrorRecord (New-FFErrorRecord -Kind $k -Message 'Zugriff verweigert.')
    }
    $TestCtx.nullRec = Get-FFEventErrorKind -ErrorRecord $null
  }
  Assert-Eq 'no-events'        $r.kinds['no-events']        'NoMatchingEventsFound is recognised'
  Assert-Eq 'log-missing'      $r.kinds['log-missing']      'NoMatchingLogsFound is recognised'
  Assert-Eq 'provider-missing' $r.kinds['provider-missing']'NoMatchingProvidersFound is recognised'
  Assert-Eq 'access-denied'    $r.kinds['access-denied']    'an UnauthorizedAccessException is recognised'
  Assert-Eq 'other'            $r.kinds['not-found']        'an unrelated failure is not mislabelled as a denial'
  Assert-Eq 'other'            $r.kinds['other']            'anything else falls into other'
  Assert-Eq 'other'            $r.nullRec                   'a null record does not throw'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'events: an access denial reported as "no events found" is NOT read as empty' -Body {
  # Verified real behaviour: Get-WinEvent -FilterHashtable answers an access DENIAL with
  # NoMatchingEventsFound, while -LogName throws UnauthorizedAccessException for the same
  # channel. Taking the first at face value is how a probe grades an unreadable subsystem green.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    $script:FFLogReadable = @{}
    function Get-WinEvent { param($FilterHashtable, $LogName, $MaxEvents, $ListProvider, $ErrorAction)
      if ($FilterHashtable) { throw (New-FFErrorRecord -Kind 'no-events') }   # the lie
      throw (New-FFErrorRecord -Kind 'access-denied')                          # the truth
    }
  } -Test {
    $TestCtx.events = @(Get-FFEvents -Filter @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 })
    $TestCtx.unreadable = $script:FFLastEventUnreadable
    $TestCtx.kind = $script:FFLastEventErrorKind
  }
  Assert-Eq 0 @($r.events).Count 'no events come back'
  Assert-True $r.unreadable 'but the emptiness must be flagged as proving NOTHING'
  Assert-Eq 'access-denied' $r.kind 'and the real reason must be recorded after the re-probe'
}

Register-FFTest -Area 'STATE' -Name 'events: a genuinely empty but readable channel is reported as empty, not unreadable' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    $script:FFLogReadable = @{}
    function Get-WinEvent { param($FilterHashtable, $LogName, $MaxEvents, $ListProvider, $ErrorAction)
      throw (New-FFErrorRecord -Kind 'no-events') }
  } -Test {
    $TestCtx.events = @(Get-FFEvents -Filter @{ LogName = 'System'; Id = 41 })
    $TestCtx.unreadable = $script:FFLastEventUnreadable
  }
  Assert-Eq 0 @($r.events).Count 'no events come back'
  Assert-False $r.unreadable 'and an empty-but-openable channel is honestly empty'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'events: a missing log channel is flagged unreadable, not empty' -Body {
  foreach ($kind in @('log-missing', 'provider-missing', 'other')) {
    $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{ kind = $kind } -Mocks {
      $script:FFLogReadable = @{}
      function Get-WinEvent { param($FilterHashtable, $LogName, $MaxEvents, $ListProvider, $ErrorAction)
        throw (New-FFErrorRecord -Kind $TestCtx.kind -Message 'stub') }
    } -Test {
      $TestCtx.events = @(Get-FFEvents -Filter @{ LogName = 'System'; ProviderName = 'Nope'; Id = 1 })
      $TestCtx.unreadable = $script:FFLastEventUnreadable
      $TestCtx.k = $script:FFLastEventErrorKind
    }
    Assert-True $r.unreadable "a '$kind' failure means the query never ran over the intended set"
    Assert-Eq $kind $r.k "and the kind is recorded as '$kind'"
  }
}

Register-FFTest -Area 'STATE' -Name 'events: unknown providers are filtered out before they poison the whole query' -Body {
  # Get-WinEvent rejects the ENTIRE query with NoMatchingProvidersFound if ONE named provider
  # does not exist here - so adding provider names is not free.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    $script:FFProviderExists = @{}
    function Get-WinEvent { param($FilterHashtable, $LogName, $MaxEvents, $ListProvider, $ErrorAction)
      if ("$ListProvider" -in @('Ntfs', 'disk', 'stornvme')) { return [pscustomobject]@{ Name = $ListProvider } }
      throw (New-FFErrorRecord -Kind 'provider-missing') }
  } -Test {
    $TestCtx.kept = @(Get-FFEventProviders -Candidates @('Ntfs', 'iaStorAC', 'disk', 'NTFS', 'stornvme', 'FakeProvider'))
  }
  Assert-Eq 3 @($r.kept).Count 'only the providers that exist here survive'
  Assert-Eq 'Ntfs disk stornvme' (@($r.kept) -join ' ') 'order is preserved and case-insensitive duplicates are dropped'
  Assert-False (@($r.kept) -contains 'iaStorAC') 'a provider absent on this machine is removed'
}

Register-FFTest -Area 'STATE' -Name 'events: an enormous channel does not stall the probe or the evidence' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    function Get-WinEvent { param($FilterHashtable, $LogName, $MaxEvents, $ListProvider, $ErrorAction)
      $n = 50000
      if ($MaxEvents -and $MaxEvents -gt 0) { $n = $MaxEvents }
      $now = Get-Date
      1..$n | ForEach-Object { New-FFEventRecord -Id 1000 -TimeCreated $now.AddSeconds(-$_) -Message ('x' * 900) } }
  } -Test {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $TestCtx.capped = @(Get-FFEvents -Filter @{ LogName = 'System'; Id = 1000 } -MaxEvents 20)
    $TestCtx.ms = $sw.ElapsedMilliseconds
    $TestCtx.evidence = @(ConvertTo-FFEventEvidence $TestCtx.capped 3)
  }
  Assert-Eq 20 @($r.capped).Count '-MaxEvents must actually bound the read'
  Assert-Eq 3 @($r.evidence).Count 'evidence is capped at the requested number of rows'
  Assert-True (@($r.evidence)[0].message.Length -le 200) 'and each message is truncated to 200 characters'
  Assert-True ($r.ms -lt 20000) 'a large channel must not stall the probe'
}

Register-FFTest -Area 'STATE' -Name 'events: fields are read from EventData by NAME, not by property index' -Body {
  # $Event.Message is rendered from the provider's MUI resources: localized, and $null when
  # those resources cannot be loaded. EventData VALUES are raw provider data.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {} -Test {
    $e = New-FFEventRecord -Id 100 -ProviderName 'Microsoft-Windows-Diagnostics-Performance' `
           -Message $null -Data @{ BootTime = '41234'; MainPathBootTime = '30000' }
    $TestCtx.map = Get-FFEventDataMap -Event $e
    $TestCtx.evidence = @(ConvertTo-FFEventEvidence @($e) 1)
    $TestCtx.timeNull = ConvertTo-FFTime $null
    $TestCtx.timeReal = ConvertTo-FFTime ([datetime]'2026-08-30T09:12:34')
  }
  Assert-Eq '41234' $r.map['BootTime'] 'the named field is read whatever the property order is'
  Assert-Eq '30000' $r.map['MainPathBootTime'] 'and so is the second one'
  Assert-Match 'no message' @($r.evidence)[0].message 'an event with no renderable message degrades to the provider name'
  Assert-Match 'Microsoft-Windows-Diagnostics-Performance' @($r.evidence)[0].message 'and names the provider'
  Assert-Null $r.timeNull 'a null TimeCreated stays null instead of throwing'
  Assert-Eq '2026-08-30T09:12:34' $r.timeReal 'a real TimeCreated renders as ISO-8601'
}

# ---------------- access-denied classification ----------------

Register-FFTest -Area 'STATE' -Name 'denials are detected structurally, never from the word "denied"' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {} -Test {
    $TestCtx.byType     = Test-FFAccessDenied -ErrorRecord (New-FFErrorRecord -Kind 'access-denied' -Message 'Zugriff verweigert.')
    $TestCtx.byHResult  = Test-FFAccessDenied -ErrorRecord (New-FFErrorRecord -Kind 'hresult-denied' -Message 'Zugriff verweigert.')
    $TestCtx.byNative   = Test-FFAccessDenied -ErrorRecord (New-Object System.Management.Automation.ErrorRecord(
                            (New-FFCimException -Message 'Zugriff verweigert.' -NativeErrorCode 5), 'x', 'NotSpecified', $null))
    $TestCtx.notDenied  = Test-FFAccessDenied -ErrorRecord (New-FFErrorRecord -Kind 'not-found' -Message 'Access is denied.')
    $TestCtx.nullRecord = Test-FFAccessDenied -ErrorRecord $null
  }
  Assert-True  $r.byType    'an UnauthorizedAccessException is a denial'
  Assert-True  $r.byHResult 'HRESULT 0x80070005 is a denial'
  Assert-True  $r.byNative  'CIM NativeErrorCode 5 (ERROR_ACCESS_DENIED) is a denial'
  Assert-False $r.notDenied 'a FileNotFoundException is NOT a denial even though its message says "Access is denied."'
  Assert-False $r.nullRecord 'a null record is not a denial'
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'policy snapshot: a denied key is present=$null, not present=$false' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
      if ("$Path" -match 'Policies|WindowsUpdate') { throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
      Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
  } -Test { $TestCtx.snap = Get-FFPolicySnapshot }
  foreach ($k in @('windowsUpdate', 'windowsUpdateAu', 'systemRestore')) {
    Assert-HonestUnknown $r.snap[$k].present "a denied read of $k"
    Assert-NotNull $r.snap[$k].error "and the error must be kept for $k"
  }
}

Register-FFTest -Area 'STATE' -Name 'policy snapshot: an absent key is present=$false with no error' -Body {
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {
    function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
      if ("$Path" -match 'Policies|WindowsUpdate') { return $false }
      Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
  } -Test { $TestCtx.snap = Get-FFPolicySnapshot }
  Assert-Eq $false $r.snap['windowsUpdate'].present 'an absent policy key is a measured absence'
  Assert-Null $r.snap['windowsUpdate'].error 'and there is no error to report'
}

# ---------------- deleted services ----------------

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'services: a DELETED service is a fault in its own right, not silence' -Body {
  # `sc delete` on exactly these names is what the popular "optimize Windows for gaming"
  # debloat scripts do. A probe that filters on `present` grades that as healthy.
  #
  # The stub raises the ERROR IDENTITY Get-Service really raises for a service that does not
  # exist (FullyQualifiedErrorId NoServiceFoundForGivenName..., category ObjectNotFound), not a
  # bare `throw "Cannot find any service..."`. That is not a detail: health.ps1 classifies this
  # case by identity and never by message text, so a stub that throws a string is testing the
  # OTHER branch - "the query itself failed, nothing was measured" - and would assert a deletion
  # the engine is right not to claim. The companion case below pins that branch deliberately.
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{ deleted = @('wuauserv', 'WSearch', 'Spooler') } -Mocks {
    function Get-Service { param($Name, $ErrorAction)
      if (@($TestCtx.deleted) -contains "$Name") { throw (New-FFErrorRecord -Kind 'service-not-found' -Message "Cannot find any service with service name '$Name'.") }
      [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' } }
  } -Test {
    $TestCtx.svcs = @(Get-ServiceInfo -Names @('wuauserv', 'bits', 'WSearch', 'Spooler', 'SomeThirdPartyThing'))
    $TestCtx.findings = @(New-MissingServiceFindings -Services $TestCtx.svcs -Severity 'warning' -Consequence 'Windows Update cannot run.')
    $TestCtx.presence = Format-ServicePresence -Services $TestCtx.svcs -Label 'services'
  }
  $ids = @(@($r.findings) | ForEach-Object { $_.id })
  Assert-Eq 3 @($r.findings).Count 'one finding per EXPECTED service that no longer exists'
  Assert-True ($ids -contains 'wuauserv-missing') 'a deleted Windows Update service is reported'
  Assert-True ($ids -contains 'WSearch-missing')  'a deleted Windows Search service is reported'
  Assert-True ($ids -contains 'Spooler-missing')  'a deleted Print Spooler is reported'
  Assert-False ($ids -contains 'SomeThirdPartyThing-missing') 'a service Windows never shipped is not invented as a fault'
  Assert-Eq 'warning' @($r.findings)[0].severity 'a deleted service is a real warning'
  Assert-Match 'deleted, not merely disabled' @($r.findings)[0].detail 'the wording must distinguish deletion from disabling'
  Assert-Match 'Set-Service cannot recreate' @($r.findings)[0].detail 'and must say why it is not a simple fix'
  Assert-Eq '2 of 5 services present and enabled' $r.presence 'the presence sentence must be bounded by what was actually checked'
  foreach ($s in @($r.svcs)) {
    if (@('wuauserv', 'WSearch', 'Spooler') -contains "$($s.name)") {
      Assert-Eq $false ([bool]$s.present)  "$($s.name): a service the SCM answered 'no such service' for is a MEASURED absence"
      Assert-Eq $true  ([bool]$s.measured) "$($s.name): and it was measured - the query ran and gave an answer"
      Assert-Eq 'absent' "$($s.queryErrorKind)" "$($s.name): recorded as absent, not as a failed query"
    }
  }
}

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'services: a query that could not RUN is a hole, never a deletion' -Body {
  # The other half of the same distinction, and the direction that fabricates faults: an
  # access-denied, an RPC failure to the Service Control Manager, or a stripped
  # Microsoft.PowerShell.Management module must NOT be reported as "a debloat script deleted
  # your Windows Update service". Nothing was measured, so nothing may be claimed - in either
  # direction. Without this case, "fix" the classification back to a bare catch and only the
  # case above would notice, which is exactly one assertion away from not noticing at all.
  foreach ($kind in @('access-denied', 'other')) {
    $r = Invoke-InEngineScope -Engine 'health' -Ctx @{ kind = $kind } -Mocks {
      function Get-Service { param($Name, $ErrorAction) throw (New-FFErrorRecord -Kind $TestCtx.kind -Message 'The service query could not run.') }
    } -Test {
      $TestCtx.svcs = @(Get-ServiceInfo -Names @('wuauserv', 'bits'))
      $TestCtx.missing = @(New-MissingServiceFindings -Services $TestCtx.svcs -Severity 'warning' -Consequence 'Windows Update cannot run.')
      $TestCtx.holes = @(New-ServiceQueryFindings -Services $TestCtx.svcs)
      $TestCtx.presence = Format-ServicePresence -Services $TestCtx.svcs -Label 'update services'
    }
    Assert-Eq 0 @($r.missing).Count "a '$kind' failure must produce NO '<name>-missing' finding: nothing was measured, so nothing was deleted"
    Assert-Eq 2 @($r.holes).Count "it must instead produce one hole per service whose query never ran ('$kind')"
    foreach ($f in @($r.holes)) {
      Assert-Eq 'unknown' "$($f.severity)" "an unmeasured service is severity 'unknown', never a warning ('$kind')"
    }
    foreach ($s in @($r.svcs)) {
      Assert-Null $s.present "$($s.name): present must be `$null - not `$false, which would read as a measured absence ('$kind')"
      Assert-Eq $false ([bool]$s.measured) "$($s.name): and measured must be false ('$kind')"
      Assert-Ne 'absent' "$($s.queryErrorKind)" "$($s.name): a failed query must not be filed as an absence ('$kind')"
    }
    Assert-NoMatch 'present and enabled' "$($r.presence)" "the presence sentence must not count services it never read ('$kind')"
    Assert-Match '(?i)queried' "$($r.presence)" "and must say the services could not be queried ('$kind')"
    Assert-Match '(?i)unknown' "$($r.presence)" "leaving their presence explicitly unknown ('$kind')"
  }
}

Register-FFTest -Area 'STATE' -Name 'services: a disabled-but-present service is not confused with a deleted one' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    function Get-Service { param($Name, $ErrorAction)
      [pscustomobject]@{ Name = $Name; Status = 'Stopped'; StartType = 'Disabled' } }
  } -Test {
    $TestCtx.svcs = @(Get-ServiceInfo -Names @('wuauserv', 'bits'))
    $TestCtx.findings = @(New-MissingServiceFindings -Services $TestCtx.svcs)
    $TestCtx.presence = Format-ServicePresence -Services $TestCtx.svcs -Label 'update services'
  }
  Assert-Eq 0 @($r.findings).Count 'a disabled service is present, so it raises no missing-service finding'
  Assert-True (@($r.svcs)[0].present) 'and it is reported as present'
  Assert-Eq 'Disabled' @($r.svcs)[0].startType 'with its real start type'
  Assert-Eq '0 of 2 update services present and enabled' $r.presence 'the presence sentence counts enabled, not merely present'
}

# ---------------- no network ----------------

Register-FFTest -Area 'STATE' -Doctrine 'rule 2' -Name 'network: an unplugged machine is critical, and the summary claims no working layer' -Body {
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $false
    function Get-NetAdapter { param([switch]$Physical, $ErrorAction)
      @([pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel I226-V'; Status = 'Disconnected'; LinkSpeed = '0 bps' }) }
    function Get-NetRoute { param($DestinationPrefix, $ErrorAction) throw 'No matching route' }
    function Test-NetConnection { param($ComputerName, $Port, $InformationLevel, $WarningAction, $ErrorAction) throw 'unreachable' }
    function Resolve-DnsName { param($Name, $Type, $Server, $DnsOnly, $NoHostsFile, $ErrorAction) throw 'DNS failure' }
    function Test-Connection { param($ComputerName, $Count, $Quiet, $ErrorAction) $false }
    function Invoke-WebRequest { param($Uri, $UseBasicParsing, $TimeoutSec, $Method, $ErrorAction) throw 'no route to host' }
    function Get-DnsClientServerAddress { param($AddressFamily, $ErrorAction) @() }
  } -Test { $TestCtx.doc = Invoke-Category 'network' }
  Assert-In $r.doc.status @('critical', 'warning', 'unknown') 'a machine with no link must not be graded ok'
  Assert-NotGraded-Ok $r.doc.status 'a completely disconnected machine'
  $noLink = @(@($r.doc.findings) | Where-Object { $_.id -eq 'no-link' }) | Select-Object -First 1
  Assert-NotNull $noLink 'the missing link must be the headline finding'
  Assert-Eq 'critical' $noLink.severity 'no link at all is critical'
  Assert-NoMatch 'Healthy network layers' $r.doc.summary 'the summary must not list healthy layers on a disconnected machine'
}

Register-FFTest -Area 'STATE' -Name 'network: an IPv6-only network is not reported as a missing default route' -Body {
  # A growing share of consumer ISPs, 464XLAT cellular and many campus networks have no
  # 0.0.0.0/0 route at all; treating that as broken invents a DHCP fault.
  $r = Invoke-InEngineScope -Engine 'health' -Ctx @{} -Mocks {
    $IsAdmin = $false
    function Get-NetAdapter { param([switch]$Physical, $ErrorAction)
      @([pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel BE200'; Status = 'Up'; LinkSpeed = '2.4 Gbps' }) }
    function Get-NetRoute { param($DestinationPrefix, $ErrorAction)
      if ("$DestinationPrefix" -eq '::/0') { return [pscustomobject]@{ NextHop = 'fe80::1'; RouteMetric = 0 } }
      throw 'No matching IPv4 route' }
    function Test-NetConnection { param($ComputerName, $Port, $InformationLevel, $WarningAction, $ErrorAction)
      [pscustomobject]@{ TcpTestSucceeded = $true; PingSucceeded = $true } }
    function Resolve-DnsName { param($Name, $Type, $Server, $DnsOnly, $NoHostsFile, $ErrorAction)
      @([pscustomobject]@{ IPAddress = '2606:4700::1111'; Type = 'AAAA' }) }
    function Test-Connection { param($ComputerName, $Count, $Quiet, $ErrorAction) $true }
    function Invoke-WebRequest { param($Uri, $UseBasicParsing, $TimeoutSec, $Method, $ErrorAction)
      [pscustomobject]@{ StatusCode = 200; Content = 'Microsoft NCSI' } }
    function Get-DnsClientServerAddress { param($AddressFamily, $ErrorAction)
      @([pscustomobject]@{ ServerAddresses = @('2606:4700:4700::1111') }) }
  } -Test { $TestCtx.doc = Invoke-Category 'network' }
  Assert-Eq 0 @(@($r.doc.findings) | Where-Object { $_.id -match 'gateway|no-link|default-route' -and $_.severity -in @('warning', 'critical') }).Count `
    'an IPv6-only default route must not raise a gateway or link fault'
}

# ---------------- console output decoding ----------------

Register-FFTest -Area 'STATE' -Name 'native capture: interleaved NULs from UTF-16 tools are stripped uniformly' -Body {
  # sfc.exe writes UTF-16; through a redirected pipe that surfaces as text with a NUL between
  # every character. A missing NUL-strip silently breaks every parse of that tool's output.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {} -Test {
    $utf16ish = "W`0i`0n`0d`0o`0w`0s`0 `0R`0e`0s`0o`0u`0r`0c`0e`0"
    $TestCtx.clean = ConvertTo-FFNativeText @($utf16ish)
    $TestCtx.joined = ConvertTo-FFNativeText @('line one', 'line two')
    $TestCtx.empty = ConvertTo-FFNativeText @()
  }
  Assert-Eq 'Windows Resource' $r.clean 'every NUL must be removed'
  Assert-Match 'line one' $r.joined 'multiple lines are joined'
  Assert-Match 'line two' $r.joined 'and none are lost'
  Assert-Eq '' $r.empty 'no output produces an empty string, not $null'
}

Register-FFTest -Area 'STATE' -Name 'JSON writer: a single-element array is not unrolled into a bare object' -Body {
  # The classic PS 5.1 ConvertTo-Json pitfall: piping a one-element array emits the object,
  # and the Electron host then reads `categories` as an object instead of a list.
  $r = Invoke-InEngineScope -Engine '_lib' -Ctx @{} -Mocks {} -Test {
    $doc = [ordered]@{ ok = $true; rows = @([ordered]@{ id = 'only' }) }
    $TestCtx.json = ConvertTo-Json -InputObject $doc -Depth 6 -Compress
  }
  $back = $r.json | ConvertFrom-Json
  Assert-True ($back.rows -is [System.Array]) 'a one-element list must round-trip as a list'
  Assert-Eq 'only' @($back.rows)[0].id 'and its single row must survive'
}
