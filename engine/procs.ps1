<#
  FrameForge :: procs.ps1
  Process helpers: list candidate game windows (benchmark targets), list background
  resource-users (the "Game Focus" closer), and close processes by id.
#>
[CmdletBinding()]
param(
  [ValidateSet('windowed','bloat','close')][string]$Action = 'windowed',
  [string]$Ids = ''
)
$ErrorActionPreference = 'SilentlyContinue'

# Background apps that are safe-to-close for a gaming session (none are critical to Windows).
$BloatPatterns = 'OneDrive|Discord|Spotify|Slack|Teams|nordvpn|Adobe|GoogleDrive|Dropbox|Epic|Razer|iCUE|SteelSeries|Logitech|GHUB|PulsarFusion|YourPhone|PhoneExperience|Tailscale|Cortana|Skype|WhatsApp|Telegram|chrome|msedge|firefox|Spotify'
# Never offer to close these — system / safety / the app itself.
$Protect = 'System|Idle|csrss|wininit|services|lsass|smss|winlogon|dwm|explorer|MsMpEng|SecurityHealth|fontdrvhost|sihost|ctfmon|RuntimeBroker|ShellExperienceHost|FrameForge|electron|powershell|conhost|svchost|audiodg|WUDFHost|NVDisplay|nvcontainer'

switch ($Action) {
  'windowed' {
    $out = @()
    foreach ($p in (Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowHandle -ne 0 })) {
      if ($p.Name -match $Protect) { continue }
      $out += [ordered]@{
        id    = $p.Id
        name  = $p.Name
        title = $p.MainWindowTitle
        ramMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
      }
    }
    @($out | Sort-Object { $_.ramMB } -Descending) | ConvertTo-Json -Depth 4
  }

  'bloat' {
    # Aggregate multi-process apps (Discord, browsers) into one entry with total RAM + all pids.
    $groups = @{}
    foreach ($p in (Get-Process | Where-Object { $_.Name -match $BloatPatterns -and $_.Name -notmatch $Protect })) {
      $key = $p.Name
      if (-not $groups.ContainsKey($key)) { $groups[$key] = [ordered]@{ name = $key; ramMB = 0; ids = @() } }
      $groups[$key].ramMB += [math]::Round($p.WorkingSet64 / 1MB, 0)
      $groups[$key].ids += $p.Id
    }
    @($groups.Values | Where-Object { $_.ramMB -ge 15 } | Sort-Object { $_.ramMB } -Descending) | ConvertTo-Json -Depth 4
  }

  'close' {
    $closed = @(); $failed = @()
    foreach ($idStr in ($Ids -split '[,\s]+' | Where-Object { $_ })) {
      $procId = 0
      if ([int]::TryParse($idStr, [ref]$procId)) {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p -and $p.Name -notmatch $Protect) {
          try { Stop-Process -Id $procId -Force -ErrorAction Stop; $closed += $procId } catch { $failed += $procId }
        }
      }
    }
    @{ closed = $closed; failed = $failed; freedHint = $true } | ConvertTo-Json -Depth 3
  }
}
