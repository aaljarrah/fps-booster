<#
  FrameForge :: nvidia.ps1
  NVIDIA integration. Phase 0/1 foundation per the judged plan (docs/NVIDIA-TAB-PLAN.md):
   - Snapshot/restore the WHOLE DRS folder (incl. nvdrswr.lk) - the authoritative, exact rollback.
   - createcsn: dump the authoritative SettingID->name/value map at the user's exact driver version
     (the bundled nvidiaProfileInspector has NO headless export, so this is how we VERIFY every ID
     before writing it).
   - detect: NVIDIA presence, tuner, driver version, snapshot status.
   - open: launch the GUI tuner.

  Actions: detect | snapshot | list | restore [-Snapshot ts] | createcsn | open
#>
[CmdletBinding()]
param(
  [ValidateSet('detect','snapshot','list','restore','createcsn','open','games','preview','apply-preset','revert','preview-custom','apply-custom','build-catalog')][string]$Action = 'detect',
  [string]$Snapshot = 'latest',
  [string]$Preset = 'esports',
  [string]$Keys = '',
  [int]$Refresh = 240,
  [switch]$VrrOk
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Drs = Join-Path $env:ProgramData 'NVIDIA Corporation\Drs'
$SnapRoot = Join-Path $Root 'data\state\nvidia-snapshots'
$CsnDir = Join-Path $Root 'data\state\csn'
$NpiDir = Join-Path $Root 'resources\npi'
$Npi = Join-Path $NpiDir 'nvidiaProfileInspector.exe'

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Has-Nvidia { Test-Path $Drs }
function Get-Snapshots { if (Test-Path $SnapRoot) { @(Get-ChildItem $SnapRoot -Directory | Sort-Object Name -Descending | ForEach-Object { $_.Name }) } else { @() } }
function Get-NvDriver {
  try { (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' } | Select-Object -First 1).DriverVersion } catch { $null }
}
function Load-Catalog { Get-Content -Raw (Join-Path $Root 'data\nvidia-settings.json') | ConvertFrom-Json }
function HexToDec($h) { [int64]([Convert]::ToUInt32(($h -replace '^0x', ''), 16)) }
$NipLedger = Join-Path $Root 'data\state\nvidia-applied.json'

# Known competitive titles -> canonical exe NVIDIA writes into <Executeables>. (appid for Steam scan.)
$GameMap = @(
  @{ name = 'Counter-Strike 2'; exe = 'cs2.exe'; steam = '730' }
  @{ name = 'Dota 2'; exe = 'dota2.exe'; steam = '570' }
  @{ name = 'PUBG'; exe = 'TslGame.exe'; steam = '578080' }
  @{ name = 'Dead by Daylight'; exe = 'DeadByDaylight-Win64-Shipping.exe'; steam = '381210' }
  @{ name = 'Squad'; exe = 'SquadGame.exe'; steam = '393380' }
  @{ name = 'Apex Legends'; exe = 'r5apex.exe'; steam = '1172470' }
  @{ name = 'Valorant'; exe = 'VALORANT-Win64-Shipping.exe'; riot = $true }
  @{ name = 'League of Legends'; exe = 'League of Legends.exe'; riot = $true }
  @{ name = 'Fortnite'; exe = 'FortniteClient-Win64-Shipping.exe'; epic = $true }
)
function Get-DetectedGames {
  $found = @()
  # Steam libraries
  $steamApps = @()
  try {
    $sp = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') { $v = Get-ItemProperty $k -ErrorAction SilentlyContinue; if ($v.SteamPath) { $sp = $v.SteamPath; break } }
    if ($sp) {
      $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
      $libs = @($sp)
      if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content -Raw $vdf), '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
      foreach ($lib in ($libs | Select-Object -Unique)) {
        foreach ($acf in (Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
          if ($acf.Name -match 'appmanifest_(\d+)\.acf') { $steamApps += $Matches[1] }
        }
      }
    }
  } catch {}
  foreach ($g in $GameMap) {
    $present = $false
    if ($g.steam -and ($steamApps -contains $g.steam)) { $present = $true }
    if ($present) { $found += [ordered]@{ name = $g.name; exe = $g.exe } }
  }
  # Riot/Epic/EA: detect by common install dirs (best-effort)
  if (Test-Path 'C:\Riot Games\VALORANT') { $found += [ordered]@{ name = 'Valorant'; exe = 'VALORANT-Win64-Shipping.exe' } }
  if (Test-Path 'C:\Riot Games\League of Legends') { $found += [ordered]@{ name = 'League of Legends'; exe = 'League of Legends.exe' } }
  @($found)
}

function New-ProfileSetting { param($id, $val, $name)
  "      <ProfileSetting>`r`n        <SettingNameInfo>$name</SettingNameInfo>`r`n        <SettingID>$id</SettingID>`r`n        <SettingValue>$val</SettingValue>`r`n        <ValueType>Dword</ValueType>`r`n      </ProfileSetting>"
}
# Core generator: build a .nip from an explicit list of setting keys.
# Safety gate: if VRR is not confirmed, drop the VRR-only settings (G-SYNC + V-Sync Force On).
# Dedupe by SettingID (keeps the first) so conflicting picks (e.g. both V-Sync rows) can't double-write.
function Build-NipXml { param([string[]]$Keys, [bool]$Vrr)
  $cat = Load-Catalog
  $vrrOnly = @('gsync-global', 'gsync-mode', 'vsync-on')
  $dropped = @($Keys | Where-Object { $_ -in $vrrOnly })
  if (-not $Vrr) { $Keys = @($Keys | Where-Object { $_ -notin $vrrOnly }) } else { $dropped = @() }
  $globalRows = @(); $gameRows = @(); $seenIds = @{}; $finalKeys = @()
  foreach ($k in $Keys) {
    $s = $cat.settings.$k
    if (-not $s) { continue }
    if ($s.idConfidence -eq 'unresolved' -or -not $s.settingId) { continue }  # never write a setting we couldn't verify on this driver
    if ($seenIds.ContainsKey("$($s.settingId)")) { continue }  # dedupe by SettingID
    $seenIds["$($s.settingId)"] = $true; $finalKeys += $k
    $row = New-ProfileSetting $s.settingId $s.recommendedCode $s.name
    if ($s.scope -eq 'global') { $globalRows += $row } else { $gameRows += $row }
  }
  $profiles = @()
  if ($globalRows.Count) {
    $profiles += "  <Profile>`r`n    <ProfileName>_GLOBAL_DRIVER_PROFILE</ProfileName>`r`n    <Executeables />`r`n    <Settings>`r`n$($globalRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
  }
  $games = @(Get-DetectedGames)
  if ($gameRows.Count -and $games.Count) {
    foreach ($g in $games) {
      $profiles += "  <Profile>`r`n    <ProfileName>FrameForge - $($g.name)</ProfileName>`r`n    <Executeables>`r`n      <string>$($g.exe)</string>`r`n    </Executeables>`r`n    <Settings>`r`n$($gameRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
    }
  } elseif ($gameRows.Count) {
    $profiles += "  <Profile>`r`n    <ProfileName>_GLOBAL_DRIVER_PROFILE</ProfileName>`r`n    <Executeables />`r`n    <Settings>`r`n$($gameRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
  }
  $xml = "<?xml version=`"1.0`" encoding=`"utf-16`"?>`r`n<ArrayOfProfile xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`">`r`n$($profiles -join "`r`n")`r`n</ArrayOfProfile>"
  return [pscustomobject]@{ xml = $xml; keys = $finalKeys; games = @($games | ForEach-Object { $_.name }); degraded = ($dropped.Count -gt 0) }
}
# Preset wrapper: resolve the preset's keys, apply its VRR degrade (swap to Force Off), then generate.
function Build-Nip { param($PresetKey, [bool]$Vrr)
  $cat = Load-Catalog
  $preset = $cat.presets.$PresetKey
  if (-not $preset) { throw "Unknown preset: $PresetKey" }
  $keys = @($preset.applied)
  if ($preset.needsVRR -and -not $Vrr -and ($keys -notcontains 'vsync-off')) { $keys += 'vsync-off' }
  $r = Build-NipXml $keys $Vrr
  if ($preset.needsVRR -and -not $Vrr) { $r.degraded = $true }
  return $r
}

switch ($Action) {

  'detect' {
    $snaps = @(Get-Snapshots)
    $latest = if ($snaps.Count) { $snaps[0] } else { $null }
    $drsCount = if (Has-Nvidia) { @(Get-ChildItem $Drs -File -ErrorAction SilentlyContinue).Count } else { 0 }
    $applied = $null
    if (Test-Path $NipLedger) { try { $applied = (Get-Content -Raw $NipLedger | ConvertFrom-Json).preset } catch {} }
    @{
      nvidia       = (Has-Nvidia)
      tuner        = (Test-Path $Npi)
      driver       = (Get-NvDriver)
      snapshots    = $snaps.Count
      latestSnap   = $latest
      drsFileCount = $drsCount
      csnAvailable = (Test-Path (Join-Path $CsnDir 'CustomSettingNames.xml'))
      applied      = $applied
    } | ConvertTo-Json -Compress
  }

  'snapshot' {
    if (-not (Has-Nvidia)) { @{ ok = $false; reason = 'No NVIDIA DRS database found.' } | ConvertTo-Json -Compress; break }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Copy the ENTIRE Drs folder (incl. nvdrswr.lk / nvAppTimestamps / update.bin) so Tier-2 rollback is bit-exact.
    $copied = @()
    foreach ($f in (Get-ChildItem $Drs -File -ErrorAction SilentlyContinue)) {
      try { Copy-Item $f.FullName (Join-Path $dir $f.Name) -Force; $copied += $f.Name } catch {}
    }
    @{ ok = $true; snapshot = $ts; files = $copied; path = $dir } | ConvertTo-Json -Compress
  }

  'list' {
    @{ ok = $true; snapshots = @(Get-Snapshots) } | ConvertTo-Json -Compress
  }

  'restore' {
    if (-not (Test-Admin)) { @{ ok = $false; needsElevation = $true; reason = 'Restoring the driver database requires administrator rights.' } | ConvertTo-Json -Compress; break }
    $snaps = @(Get-Snapshots)
    if ($snaps.Count -eq 0) { @{ ok = $false; reason = 'No snapshot to restore.' } | ConvertTo-Json -Compress; break }
    $ts = if ($Snapshot -eq 'latest') { $snaps[0] } else { $Snapshot }
    $dir = Join-Path $SnapRoot $ts
    if (-not (Test-Path $dir)) { @{ ok = $false; reason = "Snapshot not found: $ts" } | ConvertTo-Json -Compress; break }
    $restored = @(); $failed = @()
    foreach ($f in (Get-ChildItem $dir -File)) {
      try { Copy-Item $f.FullName (Join-Path $Drs $f.Name) -Force; $restored += $f.Name } catch { $failed += $f.Name }
    }
    $msg = if ($failed.Count) { "Partial restore: $($failed.Count) file(s) locked. Reboot and retry, or reset the Drs folder." } else { 'NVIDIA settings restored. Reboot to reload the driver database.' }
    @{ ok = ($failed.Count -eq 0); snapshot = $ts; files = $restored; failed = $failed; needsReboot = $true; message = $msg } | ConvertTo-Json -Compress
  }

  'createcsn' {
    if (-not (Test-Path $Npi)) { @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } | ConvertTo-Json -Compress; break }
    New-Item -ItemType Directory -Force -Path $CsnDir | Out-Null
    $ref = Join-Path $NpiDir 'Reference.xml'
    $refBak = Join-Path $env:TEMP 'ff_ref_backup.xml'
    if (Test-Path $ref) { Copy-Item $ref $refBak -Force }
    $before = @{}
    foreach ($x in (Get-ChildItem $NpiDir -Filter *.xml -ErrorAction SilentlyContinue)) { $before[$x.Name] = $x.LastWriteTimeUtc }
    $errf = Join-Path $env:TEMP 'ff_csn_err.txt'; $outf = Join-Path $env:TEMP 'ff_csn_out.txt'
    $p = Start-Process -FilePath $Npi -ArgumentList @('-createCSN') -WorkingDirectory $NpiDir -NoNewWindow -PassThru -Wait -RedirectStandardError $errf -RedirectStandardOutput $outf
    $emitted = $null
    foreach ($x in (Get-ChildItem $NpiDir -Filter *.xml -ErrorAction SilentlyContinue)) {
      $changed = (-not $before.ContainsKey($x.Name)) -or ($x.LastWriteTimeUtc -gt $before[$x.Name])
      if ($changed -and $x.Name -ne 'Reference.xml') { $emitted = $x.FullName; break }
    }
    $dest = Join-Path $CsnDir 'CustomSettingNames.xml'
    $note = ''
    if ($emitted) {
      Copy-Item $emitted $dest -Force
    } elseif ((Test-Path $ref) -and $before.ContainsKey('Reference.xml') -and ((Get-Item $ref).LastWriteTimeUtc -gt $before['Reference.xml'])) {
      Copy-Item $ref $dest -Force
      if (Test-Path $refBak) { Copy-Item $refBak $ref -Force }
      $note = 'createCSN overwrote Reference.xml; bundled copy restored.'
    }
    $made = Test-Path $dest
    $count = 0
    if ($made) { $count = ([regex]::Matches((Get-Content -Raw $dest), '<CustomSetting>')).Count }
    $stderr = (Get-Content $errf -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
    @{ ok = $made; exit = $p.ExitCode; path = $dest; settingCount = $count; note = $note; stderr = $stderr } | ConvertTo-Json -Compress
  }

  'open' {
    if (-not (Test-Path $Npi)) { @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } | ConvertTo-Json -Compress; break }
    Start-Process -FilePath $Npi | Out-Null
    @{ ok = $true; message = 'Opening NVIDIA tuner...' } | ConvertTo-Json -Compress
  }

  'build-catalog' {
    # Resolve the driver-independent template against THIS driver's CSN map -> data\nvidia-settings.json.
    $tmplPath = Join-Path $Root 'data\nvidia-catalog-template.json'
    $csnPath = Join-Path $CsnDir 'CustomSettingNames.xml'
    if (-not (Test-Path $tmplPath)) { @{ ok = $false; reason = 'Catalog template missing.' } | ConvertTo-Json -Compress; break }
    if (-not (Test-Path $csnPath)) { @{ ok = $false; needsCsn = $true; reason = 'No driver settings map yet — run createcsn first (needs admin).' } | ConvertTo-Json -Compress; break }
    [xml]$csnXml = Get-Content -Raw $csnPath
    $byName = @{}
    foreach ($s in $csnXml.CustomSettingNames.Settings.CustomSetting) {
      $vals = @{}
      foreach ($v in $s.SettingValues.CustomSettingValue) { $vn = "$($v.UserfriendlyName)"; if ($vn) { $vals[$vn] = (HexToDec $v.HexValue) } }
      $byName["$($s.UserfriendlyName)"] = @{ id = (HexToDec $s.HexSettingID); values = $vals }
    }
    $tmpl = Get-Content -Raw $tmplPath | ConvertFrom-Json
    $cap = "$([Math]::Max(30, $Refresh - 4)) FPS"
    $settings = [ordered]@{}; $resolved = 0; $unresolved = @()
    foreach ($key in $tmpl.settings.PSObject.Properties.Name) {
      $t = $tmpl.settings.$key
      $recLabel = $t.recommendedLabel; if ($recLabel -eq 'auto-cap') { $recLabel = $cap }
      $cs = $byName["$($t.csnName)"]
      $id = $null; $rec = $null; $def = $null; $conf = 'unresolved'
      if ($cs) {
        $id = $cs.id
        if ($cs.values.ContainsKey($recLabel)) { $rec = $cs.values[$recLabel] }
        if ($cs.values.ContainsKey($t.defaultLabel)) { $def = $cs.values[$t.defaultLabel] }
      }
      if ($null -ne $id -and $null -ne $rec) { $conf = 'verified'; $resolved++ } else { $unresolved += $key }
      $settings[$key] = [ordered]@{ name = $t.csnName; recommendedLabel = $recLabel; settingId = $id; recommendedCode = $rec; defaultLabel = $t.defaultLabel; defaultCode = $def; category = $t.category; tier = $t.tier; impact = $t.impact; scope = $t.scope; antiCheatSafe = $t.antiCheatSafe; idConfidence = $conf; why = $t.why }
    }
    $placebo = @()
    foreach ($p in $tmpl.placebo) { $cs = $byName["$($p.csnName)"]; $sid = 0; if ($cs) { $sid = $cs.id }; $placebo += [ordered]@{ name = $p.csnName; settingId = $sid; claim = $p.claim; why = $p.why } }
    $out = [ordered]@{ schemaVersion = 2; driverVerifiedOn = (Get-NvDriver); generatedAt = (Get-Date).ToString('s'); refreshHz = $Refresh; settings = $settings; presets = $tmpl.presets; placebo = $placebo; inGame = $tmpl.inGame }
    $json = $out | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText((Join-Path $Root 'data\nvidia-settings.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    @{ ok = $true; driver = (Get-NvDriver); resolved = $resolved; unresolved = $unresolved; cap = $cap } | ConvertTo-Json -Depth 4 -Compress
  }

  'games' {
    @{ ok = $true; games = @(Get-DetectedGames) } | ConvertTo-Json -Depth 4 -Compress
  }

  'preview' {
    # Generate the .nip WITHOUT applying — for validation and the UI diff sheet.
    $b = Build-Nip $Preset ([bool]$VrrOk)
    @{ ok = $true; preset = $Preset; keys = $b.keys; games = $b.games; degraded = $b.degraded; nip = $b.xml } | ConvertTo-Json -Depth 5 -Compress
  }

  'preview-custom' {
    $kl = @($Keys -split '[,\s]+' | Where-Object { $_ })
    $b = Build-NipXml $kl ([bool]$VrrOk)
    @{ ok = $true; keys = $b.keys; games = $b.games; degraded = $b.degraded; nip = $b.xml } | ConvertTo-Json -Depth 5 -Compress
  }

  'apply-preset' {
    if (-not (Test-Admin)) { @{ ok = $false; needsElevation = $true; reason = 'Applying NVIDIA settings requires administrator rights.' } | ConvertTo-Json -Compress; break }
    if (-not (Test-Path $Npi)) { @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } | ConvertTo-Json -Compress; break }
    # 1) Snapshot first (the exact-rollback backbone).
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss'); $snapDir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
    foreach ($f in (Get-ChildItem $Drs -File -ErrorAction SilentlyContinue)) { try { Copy-Item $f.FullName (Join-Path $snapDir $f.Name) -Force } catch {} }
    # 2) Generate the .nip and import it.
    $b = Build-Nip $Preset ([bool]$VrrOk)
    $nipPath = Join-Path $env:TEMP "frameforge-$Preset.nip"
    Set-Content -Path $nipPath -Value $b.xml -Encoding Unicode
    $errf = Join-Path $env:TEMP 'ff_apply_err.txt'
    $p = Start-Process -FilePath $Npi -ArgumentList @('-silentImport', $nipPath) -NoNewWindow -PassThru -Wait -RedirectStandardError $errf -RedirectStandardOutput (Join-Path $env:TEMP 'ff_apply_out.txt')
    $ok = ($p.ExitCode -eq 0)
    if ($ok) { Set-Content $NipLedger -Value (@{ preset = $Preset; snapshot = $ts; appliedAt = (Get-Date).ToString('s'); games = $b.games; degraded = $b.degraded } | ConvertTo-Json -Compress) -Encoding UTF8 }
    $stderr = (Get-Content $errf -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
    $msg = if ($ok) { "Applied '$Preset'. Close and relaunch your game for it to take effect." } else { "Import failed (exit $($p.ExitCode)). Your settings are unchanged; snapshot $ts is available." }
    @{ ok = $ok; preset = $Preset; exit = $p.ExitCode; snapshot = $ts; games = $b.games; degraded = $b.degraded; message = $msg; stderr = $stderr } | ConvertTo-Json -Depth 5 -Compress
  }

  'apply-custom' {
    if (-not (Test-Admin)) { @{ ok = $false; needsElevation = $true; reason = 'Applying NVIDIA settings requires administrator rights.' } | ConvertTo-Json -Compress; break }
    if (-not (Test-Path $Npi)) { @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } | ConvertTo-Json -Compress; break }
    $kl = @($Keys -split '[,\s]+' | Where-Object { $_ })
    if ($kl.Count -eq 0) { @{ ok = $false; reason = 'No settings selected.' } | ConvertTo-Json -Compress; break }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss'); $snapDir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
    foreach ($f in (Get-ChildItem $Drs -File -ErrorAction SilentlyContinue)) { try { Copy-Item $f.FullName (Join-Path $snapDir $f.Name) -Force } catch {} }
    $b = Build-NipXml $kl ([bool]$VrrOk)
    $nipPath = Join-Path $env:TEMP 'frameforge-custom.nip'
    Set-Content -Path $nipPath -Value $b.xml -Encoding Unicode
    $errf = Join-Path $env:TEMP 'ff_applyc_err.txt'
    $p = Start-Process -FilePath $Npi -ArgumentList @('-silentImport', $nipPath) -NoNewWindow -PassThru -Wait -RedirectStandardError $errf -RedirectStandardOutput (Join-Path $env:TEMP 'ff_applyc_out.txt')
    $ok = ($p.ExitCode -eq 0)
    if ($ok) { Set-Content $NipLedger -Value (@{ preset = 'custom'; snapshot = $ts; appliedAt = (Get-Date).ToString('s'); keys = $b.keys; games = $b.games; degraded = $b.degraded } | ConvertTo-Json -Compress) -Encoding UTF8 }
    $msg = if ($ok) { "Applied $($b.keys.Count) custom setting(s). Close and relaunch your game to take effect." } else { "Import failed (exit $($p.ExitCode)). Your settings are unchanged; snapshot $ts is available." }
    @{ ok = $ok; preset = 'custom'; exit = $p.ExitCode; snapshot = $ts; keys = $b.keys; games = $b.games; degraded = $b.degraded; message = $msg } | ConvertTo-Json -Depth 5 -Compress
  }

  'revert' {
    if (-not (Test-Admin)) { @{ ok = $false; needsElevation = $true; reason = 'Reverting NVIDIA settings requires administrator rights.' } | ConvertTo-Json -Compress; break }
    if (-not (Test-Path $NipLedger)) { @{ ok = $false; reason = 'No FrameForge NVIDIA changes on record to revert.' } | ConvertTo-Json -Compress; break }
    $rec = Get-Content -Raw $NipLedger | ConvertFrom-Json
    $dir = Join-Path $SnapRoot $rec.snapshot
    if (-not (Test-Path $dir)) { @{ ok = $false; reason = "Snapshot $($rec.snapshot) not found." } | ConvertTo-Json -Compress; break }
    $restored = @(); $failed = @()
    foreach ($f in (Get-ChildItem $dir -File)) { try { Copy-Item $f.FullName (Join-Path $Drs $f.Name) -Force; $restored += $f.Name } catch { $failed += $f.Name } }
    if ($failed.Count -eq 0) { Remove-Item $NipLedger -Force -ErrorAction SilentlyContinue }
    $msg = if ($failed.Count) { "Partial: $($failed.Count) file(s) locked - reboot and retry." } else { 'Reverted to your pre-apply NVIDIA settings. Reboot to reload the driver database.' }
    @{ ok = ($failed.Count -eq 0); restored = $restored; failed = $failed; needsReboot = $true; message = $msg } | ConvertTo-Json -Compress
  }
}
