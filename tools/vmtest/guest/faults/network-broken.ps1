<#
  FAULT: network-broken
  Breaks name resolution and the machine-wide HTTP proxy without touching the physical link:
    dns    every up adapter gets a static resolver of 203.0.113.53 (TEST-NET-3, RFC 5737 - it is
           reserved for documentation and can never route anywhere), so raw-IP connectivity keeps
           working while DNS fails. That asymmetry is exactly what health.ps1's network probe is
           supposed to distinguish.
    proxy  WinHTTP is pointed at 127.0.0.1:9 (the discard port), which fails instantly rather
           than hanging.
    full   both.

  GROUND TRUTH:
    * Get-DnsClientServerAddress - a structured object with ServerAddresses per interface index.
    * The RAW BINARY registry blob at
      HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections\WinHttpSettings
      NOT `netsh winhttp show proxy`, whose output is localized. Capturing the blob is also the
      only way to restore the prior proxy EXACTLY (doctrine rule 3): `netsh winhttp reset proxy`
      restores a DEFAULT, not what was there before.

  REVERT restores per-interface DNS to precisely what was captured, including putting an adapter
  back on DHCP-assigned resolvers when that is what it had, and writes the captured WinHttpSettings
  bytes back verbatim.

  This fault is the reason winsock-reset is worth testing: the repair resets the winsock catalog
  and the IP stack out from under whatever is talking to the guest. PowerShell Direct rides the
  VMBus, so the harness keeps its control channel while the data channel is being rebuilt.
#>
[CmdletBinding()]
param(
  [string]$Action = 'probe',
  [ValidateSet('full','dns','proxy')]
  [string]$Preset = 'full',
  [string]$BogusDns = '203.0.113.53',
  [string]$BogusProxy = '127.0.0.1:9',
  [string]$StateRoot = 'C:\ffvmtest\state'
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) '_faultlib.ps1')

$FaultId    = 'network-broken'
$WinHttpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
$WinHttpVal = 'WinHttpSettings'
$netsh      = Join-Path $env:SystemRoot 'System32\netsh.exe'

function Test-Rung { param([string]$Rung) ($Preset -eq 'full' -or $Preset -eq $Rung) }

function Get-UpAdapters {
  try { return @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { return $null }
}

function Get-DnsRows {
  # ipv4 only (AddressFamily 2). The DHCP flag comes from the interface's IPv4 configuration, so
  # revert can tell "had no explicit servers" from "had these servers".
  $rows = @()
  try {
    foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
      $servers = @()
      try { $servers = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch {}
      # $null (not $false) when it cannot be read: revert branches on this, and "I could not tell
      # whether this adapter was on DHCP" must not silently become "it was not".
      $dhcp = $null
      try { $dhcp = ("$((Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp)" -eq 'Enabled') } catch {}
      $rows += [ordered]@{ ifIndex = [int]$a.ifIndex; alias = "$($a.Name)"; status = "$($a.Status)"; dhcp = $dhcp; servers = @($servers) }
    }
  } catch { return $null }
  ,$rows
}

function Get-NetworkGroundTruth {
  $sigs = @(); $verdicts = @()

  if (Test-Rung 'dns') {
    $rows = Get-DnsRows
    $sigs += [ordered]@{ signal = 'dns-client-server-address'; rows = @($rows) }
    if ($null -eq $rows) { $verdicts += $null }
    else {
      $up = @($rows | Where-Object { $_.status -eq 'Up' })
      if ($up.Count -eq 0) { $verdicts += $null }
      else { $verdicts += ((@($up | Where-Object { @($_.servers) -contains $BogusDns })).Count -eq $up.Count) }
    }
  }

  if (Test-Rung 'proxy') {
    $snap = Get-RegValueSnapshot -Path $WinHttpKey -Name $WinHttpVal
    $bytes = $null; $len = $null
    if ($snap.present -eq $true) { try { $bytes = [byte[]]$snap.value; $len = $bytes.Length } catch {} }
    # The blob is a length-prefixed structure; the proxy string is embedded as ASCII. Reading the
    # ASCII back out of OUR OWN blob is not a localized text parse - it is our marker.
    $hasMarker = $null
    if ($null -ne $bytes) {
      try { $hasMarker = ([System.Text.Encoding]::ASCII.GetString($bytes)).Contains($BogusProxy) } catch { $hasMarker = $null }
    }
    $sigs += [ordered]@{ signal = 'winhttp-settings-blob'; present = $snap.present; bytes = $len; containsInjectedProxy = $hasMarker }
    if ($null -eq $snap.present -or ($snap.present -eq $true -and $null -eq $hasMarker)) { $verdicts += $null }
    else { $verdicts += [bool]$hasMarker }
  }

  if (@($verdicts | Where-Object { $null -eq $_ }).Count -gt 0) {
    return (New-GroundTruth -Faulted $null -Detail 'At least one network rung could not be read; UNDETERMINED.' -Signals $sigs)
  }
  $all = (@($verdicts | Where-Object { $_ -eq $true }).Count -eq @($verdicts).Count)
  New-GroundTruth -Faulted $all -Detail "Preset '$Preset': $(@($verdicts | Where-Object { $_ -eq $true }).Count) of $(@($verdicts).Count) rung(s) faulted." -Signals $sigs
}

$doc = $null
try {
  switch ($Action) {

    'describe' {
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Message 'Sets an unroutable static DNS server on every up adapter and points WinHTTP at a dead proxy.'
      $doc.presets = @('full','dns','proxy')
      $doc.targets = [ordered]@{ bogusDns = $BogusDns; bogusProxy = $BogusProxy; winHttpValue = "$WinHttpKey\$WinHttpVal" }
      $doc.fixes = @('network-flush','dns-change-resolver','winsock-reset')
    }

    'probe' {
      $gt = Get-NetworkGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Message $gt.detail
    }

    'inject' {
      if (-not (Test-FaultAdmin)) { throw 'Changing DNS and the WinHTTP proxy requires elevation.' }
      $capture = [ordered]@{ preset = $Preset; dns = $null; winHttp = $null }
      $actions = @()

      if (Test-Rung 'dns') {
        $capture.dns = @(Get-DnsRows)
        if ($null -eq $capture.dns) { throw 'The adapter DNS configuration could not be captured, so the fault was NOT injected - injecting without a capture would make revert impossible.' }
        foreach ($r in @($capture.dns | Where-Object { $_.status -eq 'Up' })) {
          try { Set-DnsClientServerAddress -InterfaceIndex ([int]$r.ifIndex) -ServerAddresses @($BogusDns) -ErrorAction Stop
                $actions += "$($r.alias) (ifIndex $($r.ifIndex)): resolver set to $BogusDns." }
          catch { $actions += "$($r.alias): could not set resolver - $($_.Exception.Message)" }
        }
        try { $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns; $actions += 'Resolver cache flushed.' } catch {}
      }

      if (Test-Rung 'proxy') {
        $capture.winHttp = Get-RegValueSnapshot -Path $WinHttpKey -Name $WinHttpVal
        if ($null -eq $capture.winHttp.present) { throw 'The WinHttpSettings blob could not be read, so the proxy rung was NOT injected (revert would have nothing to restore).' }
        $r = Invoke-NativeCapture -FilePath $netsh -Arguments @('winhttp','set','proxy',"proxy-server=$BogusProxy")
        $actions += "netsh winhttp set proxy exited $($r.exitCode)."
      }

      $null = Save-FaultState -Fault $FaultId -State $capture -StateRoot $StateRoot
      $gt = Get-NetworkGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $capture -Message $gt.detail -Evidence $actions
    }

    'revert' {
      $state = Read-FaultState -Fault $FaultId -StateRoot $StateRoot
      if ($null -eq $state) { throw "No captured state for '$FaultId' at $StateRoot." }
      $actions = @()
      foreach ($r in @($state.dns)) {
        if ("$($r.status)" -ne 'Up') { continue }
        $prior = @($r.servers | Where-Object { "$_" -match '\S' })
        try {
          if ($r.dhcp -eq $true -or $prior.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex ([int]$r.ifIndex) -ResetServerAddresses -ErrorAction Stop
            $actions += "$($r.alias): restored to DHCP-assigned resolvers (that is what was captured)."
          } else {
            Set-DnsClientServerAddress -InterfaceIndex ([int]$r.ifIndex) -ServerAddresses $prior -ErrorAction Stop
            $actions += "$($r.alias): restored captured resolvers $($prior -join ', ')."
          }
        } catch { $actions += "$($r.alias): could NOT restore - $($_.Exception.Message)" }
      }
      if ($state.winHttp) {
        # Byte-for-byte restore of the captured blob. `netsh winhttp reset proxy` would install a
        # default instead, which is not the same thing as the prior state.
        $snap = $state.winHttp
        if ($snap.present -eq $true) {
          try {
            $bytes = [byte[]]@($snap.value | ForEach-Object { [byte]$_ })
            Set-ItemProperty -LiteralPath $WinHttpKey -Name $WinHttpVal -Value $bytes -Type Binary -ErrorAction Stop
            $actions += 'WinHttpSettings restored byte for byte from capture.'
          } catch { $actions += "WinHttpSettings could NOT be restored: $($_.Exception.Message)" }
        } elseif ($snap.present -eq $false) {
          try { Remove-ItemProperty -LiteralPath $WinHttpKey -Name $WinHttpVal -ErrorAction SilentlyContinue; $actions += 'WinHttpSettings removed (it did not exist before injection).' } catch {}
        } else {
          $actions += 'WinHttpSettings prior state was never readable; nothing was written back.'
        }
      }
      try { $null = & (Join-Path $env:SystemRoot 'System32\ipconfig.exe') /flushdns } catch {}
      $gt = Get-NetworkGroundTruth
      $doc = New-FaultDoc -Fault $FaultId -Action $Action -Injected $gt.faulted -GroundTruth $gt -Capture $state -Message 'Captured network configuration restored.' -Evidence $actions
    }

    default { throw "Unknown -Action '$Action'. Valid: inject, revert, probe, describe." }
  }
} catch {
  $doc = New-FaultDoc -Fault $FaultId -Action $Action -Ok $false -Injected $null -Message "$($_.Exception.Message)"
}

Write-FaultJson -InputObject $doc -Depth 12
if ($doc.ok) { exit 0 } else { exit 1 }
