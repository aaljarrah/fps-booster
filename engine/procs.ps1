<#
  FrameForge :: procs.ps1
  Process helpers: list candidate game windows (benchmark targets), list background
  resource-users (the "Game Focus" closer), and close processes by id.

  Window TITLES are user/app text and are frequently non-ASCII (Cyrillic, CJK, accented names).
  This script therefore emits through _lib.ps1's Write-FFJson: without BOM-free UTF-8 on stdout
  the JSON leaves PowerShell in the console OEM code page, Node decodes it as UTF-8, and the
  Game Focus list becomes mojibake the user cannot read.
#>
[CmdletBinding()]
param(
  [string]$Action = 'windowed',
  [string]$Ids = ''
)
$ErrorActionPreference = 'SilentlyContinue'

try { . (Join-Path $PSScriptRoot '_lib.ps1') } catch {}
if (-not (Get-Command Write-FFJson -ErrorAction SilentlyContinue)) {
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  function Write-FFJson { param($InputObject, [int]$Depth = 12, [switch]$Pretty)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress))
  }
}

# Background apps that are safe-to-close for a gaming session (none are critical to Windows).
$BloatPatterns = 'OneDrive|Discord|Spotify|Slack|Teams|nordvpn|Adobe|GoogleDrive|Dropbox|Epic|Razer|iCUE|SteelSeries|Logitech|GHUB|PulsarFusion|YourPhone|PhoneExperience|Tailscale|Cortana|Skype|WhatsApp|Telegram|chrome|msedge|firefox|Spotify'
# Never offer to close these — system / safety / the app itself.
$Protect = 'System|Idle|csrss|wininit|services|lsass|smss|winlogon|dwm|explorer|MsMpEng|SecurityHealth|fontdrvhost|sihost|ctfmon|RuntimeBroker|ShellExperienceHost|FrameForge|electron|powershell|conhost|svchost|audiodg|WUDFHost|NVDisplay|nvcontainer'

# Action validation in the BODY, not via [ValidateSet] on the parameter: a binding failure
# happens BEFORE the script runs, producing empty stdout plus a raw error on stderr, which
# the Electron host can only report as "the engine returned no output". Matches health.ps1.
$ValidActions = @('windowed','bloat','close')
if ($ValidActions -notcontains $Action) {
  $err = [ordered]@{
    ok = $false; action = "$Action"; errorCode = 'unknown-action'
    error = "Unknown action '$Action'."; validActions = $ValidActions
  }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $err -Depth 6 -Compress))
  exit 2
}

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
    # -InputObject via Write-FFJson: a single windowed app must stay a one-element ARRAY, not be
    # unrolled into a bare object by PS 5.1's ConvertTo-Json.
    Write-FFJson -InputObject (@($out | Sort-Object { $_.ramMB } -Descending)) -Depth 4
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
    Write-FFJson -InputObject (@($groups.Values | Where-Object { $_.ramMB -ge 15 } | Sort-Object { $_.ramMB } -Descending)) -Depth 4
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
    Write-FFJson -InputObject @{ closed = $closed; failed = $failed; freedHint = $true } -Depth 3
  }
}
