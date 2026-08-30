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

  PORTABILITY NOTES (why this file looks the way it does):
   - Every path from $PSScriptRoot/$Root/%TEMP% goes through -LiteralPath: a '[' in the install
     path makes Test-Path return $false and makes `Get-Content -Raw -Path` fail outright.
   - Every JSON/XML read is -Encoding UTF8: these files are BOM-less UTF-8 and PS 5.1 would
     otherwise decode them with the machine's ANSI code page, mangling advisory text differently
     on every locale (and dropping bytes on DBCS code pages).
   - Runtime state lives under %LOCALAPPDATA%, never in the install tree.
   - Start-Process -ArgumentList does NOT quote array elements in PS 5.1 (and .NET Framework has
     no ProcessStartInfo.ArgumentList), so every path argument is quoted by hand.
#>
[CmdletBinding()]
param(
  [string]$Action = 'detect',
  [string]$Snapshot = 'latest',
  [string]$Preset = 'esports',
  [string]$Keys = '',
  [int]$Refresh = 0,
  [switch]$VrrOk,
  [switch]$AllowGlobalFallback
)
$ErrorActionPreference = 'Stop'

try { . (Join-Path $PSScriptRoot '_lib.ps1') } catch {}
if (-not (Get-Command Write-FFJson -ErrorAction SilentlyContinue)) {
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  function Write-FFJson { param($InputObject, [int]$Depth = 12, [switch]$Pretty)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress))
  }
}

$Root = Split-Path -Parent $PSScriptRoot
$Drs = Join-Path $env:ProgramData 'NVIDIA Corporation\Drs'
# State out of the install tree: %ProgramFiles%, a network share, Controlled Folder Access or a
# OneDrive-redirected profile all make <install>\data\state unwritable, and a snapshot that
# cannot be written is a rollback that does not exist.
$StateBase = $env:LOCALAPPDATA
if (-not $StateBase) { $StateBase = $env:TEMP }
$StateRoot = ($StateBase.TrimEnd('\')) + '\FrameForge\state'
$LegacyStateRoot = Join-Path $Root 'data\state'
$SnapRoot = Join-Path $StateRoot 'nvidia-snapshots'
$CsnDir = Join-Path $StateRoot 'csn'
$NpiDir = Join-Path $Root 'resources\npi'
$Npi = Join-Path $NpiDir 'nvidiaProfileInspector.exe'
$NipLedger = Join-Path $StateRoot 'nvidia-applied.json'

function Fail { param($Object) Write-FFJson -InputObject $Object; exit 0 }
try {
  if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null }
  # Carry a v0.1 install's snapshots/ledger forward once so an existing rollback is not orphaned.
  foreach ($pair in @(@{ from = (Join-Path $LegacyStateRoot 'nvidia-snapshots'); to = $SnapRoot },
                      @{ from = (Join-Path $LegacyStateRoot 'csn');              to = $CsnDir })) {
    if ((Test-Path -LiteralPath $pair.from) -and -not (Test-Path -LiteralPath $pair.to)) {
      Copy-Item -LiteralPath $pair.from -Destination $pair.to -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $legacyLedger = Join-Path $LegacyStateRoot 'nvidia-applied.json'
  if ((Test-Path -LiteralPath $legacyLedger) -and -not (Test-Path -LiteralPath $NipLedger)) {
    Copy-Item -LiteralPath $legacyLedger -Destination $NipLedger -Force -ErrorAction SilentlyContinue
  }
} catch {
  Fail @{ ok = $false; reason = "FrameForge could not create its state folder at '$StateRoot': $($_.Exception.Message)" }
}

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Has-Nvidia { Test-Path -LiteralPath $Drs }
function Get-Snapshots { if (Test-Path -LiteralPath $SnapRoot) { @(Get-ChildItem -LiteralPath $SnapRoot -Directory | Sort-Object Name -Descending | ForEach-Object { $_.Name }) } else { @() } }
function Get-NvDriver {
  # PCI vendor ID, not the adapter NAME: inbox/localized adapter names ("Microsoft Basic Display
  # Adapter" is renamed in every language pack) never match 'NVIDIA|GeForce|RTX|GTX'.
  try {
    $c = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { "$($_.PNPDeviceID)" -match '(?i)VEN_10DE' }) | Select-Object -First 1
    if ($c) { return $c.DriverVersion }
  } catch {}
  return $null
}
function Load-Catalog {
  $p = Join-Path $Root 'data\nvidia-settings.json'
  if (-not (Test-Path -LiteralPath $p)) { throw "NVIDIA catalog not found at $p" }
  Get-Content -Raw -Encoding UTF8 -LiteralPath $p | ConvertFrom-Json
}
function HexToDec($h) { [int64]([Convert]::ToUInt32(($h -replace '^0x', ''), 16)) }

function Quote-Arg { param([string]$Value) '"' + ($Value -replace '"', '\"') + '"' }

function Get-DrsFingerprint {
  <# Name/size/mtime of every file in the DRS folder. Comparing before and after an import is the
     only way to tell "nvidiaProfileInspector exited 0 and wrote nothing" from a real apply —
     exit 0 alone is not proof, and the ledger must not record an undo for a change never made. #>
  if (-not (Test-Path -LiteralPath $Drs)) { return $null }
  try {
    $rows = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Drs -File -ErrorAction Stop | Sort-Object Name)) {
      $rows += ("{0}|{1}|{2}" -f $f.Name, $f.Length, $f.LastWriteTimeUtc.Ticks)
    }
    return ($rows -join ';')
  } catch { return $null }
}

# Known competitive titles -> canonical exe NVIDIA writes into <Executeables>. (appid for Steam scan.)
$GameMap = @(
  @{ name = 'Counter-Strike 2'; exe = 'cs2.exe'; steam = '730' }
  @{ name = 'Dota 2'; exe = 'dota2.exe'; steam = '570' }
  @{ name = 'PUBG'; exe = 'TslGame.exe'; steam = '578080' }
  @{ name = 'Dead by Daylight'; exe = 'DeadByDaylight-Win64-Shipping.exe'; steam = '381210' }
  @{ name = 'Squad'; exe = 'SquadGame.exe'; steam = '393380' }
  @{ name = 'Apex Legends'; exe = 'r5apex.exe'; steam = '1172470' }
  @{ name = 'Valorant'; exe = 'VALORANT-Win64-Shipping.exe'; riot = 'VALORANT' }
  @{ name = 'League of Legends'; exe = 'League of Legends.exe'; riot = 'League of Legends' }
  @{ name = 'Fortnite'; exe = 'FortniteClient-Win64-Shipping.exe'; epic = 'Fortnite' }
)

function Get-RiotInstallRoots {
  <# Where Riot games actually live. The old code hardcoded 'C:\Riot Games\...', which misses a
     D:-drive install, a non-C: system drive and every custom path. Riot's own metadata is
     authoritative; scanning the fixed volumes is the fallback. #>
  $roots = @()
  $meta = Join-Path $env:ProgramData 'Riot Games\Metadata'
  if (Test-Path -LiteralPath $meta) {
    try {
      foreach ($y in (Get-ChildItem -LiteralPath $meta -Recurse -Filter '*.product_settings.yaml' -ErrorAction Stop)) {
        $txt = Get-Content -Raw -Encoding UTF8 -LiteralPath $y.FullName -ErrorAction SilentlyContinue
        # A YAML key, not prose: 'product_install_full_path: D:/Riot Games/VALORANT'
        foreach ($m in [regex]::Matches("$txt", '(?im)^\s*product_install_full_path\s*:\s*"?([^"\r\n]+)"?\s*$')) {
          $p = $m.Groups[1].Value.Trim() -replace '/', '\'
          if ($p) { $roots += $p }
        }
      }
    } catch {}
  }
  if ($roots.Count -eq 0) {
    # Every FIXED volume, not just C:. Get-Volume gives mounted-folder volumes too.
    $drives = @()
    try { $drives = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" }) } catch {}
    if ($drives.Count -eq 0) {
      try { $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | Where-Object { $_.Name.Length -eq 1 } | ForEach-Object { "$($_.Name):" }) } catch {}
    }
    foreach ($d in $drives) { $roots += (Join-Path $d 'Riot Games') }
  }
  @($roots | Select-Object -Unique)
}

function Get-EpicInstalls {
  <# Epic's launcher manifest: %ProgramData%\Epic\UnrealEngineLauncher\LauncherInstalled.dat (JSON).
     Epic titles were previously never detected at all. #>
  $out = @()
  $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
  if (-not (Test-Path -LiteralPath $dat)) { return @() }
  try {
    $j = Get-Content -Raw -Encoding UTF8 -LiteralPath $dat | ConvertFrom-Json
    foreach ($i in @($j.InstallationList)) {
      $out += [ordered]@{ appName = "$($i.AppName)"; location = "$($i.InstallLocation)" }
    }
  } catch {}
  @($out)
}

function Get-DetectedGames {
  $found = @()
  # ---- Steam (path independent: the library list comes from Steam itself) ----
  $steamApps = @()
  try {
    $sp = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
      $v = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
      if ($v.SteamPath) { $sp = $v.SteamPath; break }
      if ($v.InstallPath) { $sp = $v.InstallPath; break }
    }
    if ($sp) {
      $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
      $libs = @($sp)
      if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -Encoding UTF8 -LiteralPath $vdf), '"path"\s*"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
      }
      foreach ($lib in ($libs | Select-Object -Unique)) {
        foreach ($acf in (Get-ChildItem -LiteralPath (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
          if ($acf.Name -match 'appmanifest_(\d+)\.acf') { $steamApps += $Matches[1] }
        }
      }
    }
  } catch {}

  $riotRoots = @(Get-RiotInstallRoots)
  $epic = @(Get-EpicInstalls)

  foreach ($g in $GameMap) {
    $how = $null
    if ($g.steam -and ($steamApps -contains $g.steam)) { $how = 'steam' }
    if (-not $how -and $g.riot) {
      foreach ($r in $riotRoots) {
        # Riot metadata gives the game folder directly; the volume scan gives 'X:\Riot Games'.
        foreach ($cand in @($r, (Join-Path $r $g.riot))) {
          if ($cand -and (Test-Path -LiteralPath $cand) -and ("$cand" -like "*$($g.riot)*")) { $how = 'riot'; break }
        }
        if ($how) { break }
      }
    }
    if (-not $how -and $g.epic) {
      foreach ($e in $epic) {
        if ($e.appName -eq $g.epic -or ("$($e.location)" -like "*$($g.epic)*")) { $how = 'epic'; break }
      }
    }
    if ($how) { $found += [ordered]@{ name = $g.name; exe = $g.exe; detectedVia = $how } }
  }
  @($found)
}

function New-ProfileSetting { param($id, $val, $name)
  "      <ProfileSetting>`r`n        <SettingNameInfo>$name</SettingNameInfo>`r`n        <SettingID>$id</SettingID>`r`n        <SettingValue>$val</SettingValue>`r`n        <ValueType>Dword</ValueType>`r`n      </ProfileSetting>"
}
# Core generator: build a .nip from an explicit list of setting keys.
# Safety gate: if VRR is not confirmed, drop the VRR-only settings (G-SYNC + V-Sync Force On).
# Dedupe by SettingID (keeps the first) so conflicting picks (e.g. both V-Sync rows) can't double-write.
function Build-NipXml { param([string[]]$Keys, [bool]$Vrr, [bool]$AllowGlobal = $false)
  $cat = Load-Catalog
  $vrrOnly = @('gsync-global', 'gsync-mode', 'vsync-on')
  $dropped = @($Keys | Where-Object { $_ -in $vrrOnly })
  if (-not $Vrr) { $Keys = @($Keys | Where-Object { $_ -notin $vrrOnly }) } else { $dropped = @() }
  $globalRows = @(); $gameRows = @(); $seenIds = @{}; $finalKeys = @(); $gameKeys = @(); $skipped = @()
  foreach ($k in $Keys) {
    $s = $cat.settings.$k
    if (-not $s) { continue }
    if ($s.idConfidence -eq 'unresolved' -or -not $s.settingId) { $skipped += $k; continue }  # never write a setting we couldn't verify on this driver
    if ($seenIds.ContainsKey("$($s.settingId)")) { continue }  # dedupe by SettingID
    $seenIds["$($s.settingId)"] = $true; $finalKeys += $k
    $row = New-ProfileSetting $s.settingId $s.recommendedCode $s.name
    if ($s.scope -eq 'global') { $globalRows += $row } else { $gameRows += $row; $gameKeys += $k }
  }
  $profiles = @()
  if ($globalRows.Count) {
    $profiles += "  <Profile>`r`n    <ProfileName>_GLOBAL_DRIVER_PROFILE</ProfileName>`r`n    <Executeables />`r`n    <Settings>`r`n$($globalRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
  }
  $games = @(Get-DetectedGames)
  $scopeFallback = $false
  $scopeMessage = $null
  if ($gameRows.Count -and $games.Count) {
    foreach ($g in $games) {
      $profiles += "  <Profile>`r`n    <ProfileName>FrameForge - $($g.name)</ProfileName>`r`n    <Executeables>`r`n      <string>$($g.exe)</string>`r`n    </Executeables>`r`n    <Settings>`r`n$($gameRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
    }
  } elseif ($gameRows.Count) {
    # NO detected game. The old code quietly wrote these per-game rows into
    # _GLOBAL_DRIVER_PROFILE, widening a per-game change to every Direct3D/Vulkan app on the
    # machine without asking. Consent (rule 4) and catalog-accuracy (rule 5) both forbid that:
    # omit them and say which settings were skipped, unless the caller explicitly opts in.
    $scopeFallback = $true
    if ($AllowGlobal) {
      $profiles += "  <Profile>`r`n    <ProfileName>_GLOBAL_DRIVER_PROFILE</ProfileName>`r`n    <Executeables />`r`n    <Settings>`r`n$($gameRows -join "`r`n")`r`n    </Settings>`r`n  </Profile>"
      $scopeMessage = "No supported game was detected, so these per-game settings were applied to the GLOBAL driver profile at your request (they affect every Direct3D/Vulkan application): $($gameKeys -join ', ')."
    } else {
      $finalKeys = @($finalKeys | Where-Object { $gameKeys -notcontains $_ })
      $scopeMessage = "No supported game was detected, so these per-game settings were SKIPPED rather than silently applied to every application on the machine: $($gameKeys -join ', '). Re-run with -AllowGlobalFallback to apply them globally on purpose."
    }
  }
  $xml = "<?xml version=`"1.0`" encoding=`"utf-16`"?>`r`n<ArrayOfProfile xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xmlns:xsd=`"http://www.w3.org/2001/XMLSchema`">`r`n$($profiles -join "`r`n")`r`n</ArrayOfProfile>"
  return [pscustomobject]@{
    xml = $xml; keys = $finalKeys
    games = @($games | ForEach-Object { $_.name })
    gameDetail = @($games)
    degraded = ($dropped.Count -gt 0)
    droppedVrrKeys = $dropped
    unresolvedKeys = $skipped
    scopeFallback = $scopeFallback
    scopeMessage = $scopeMessage
    profileCount = $profiles.Count
  }
}
# Preset wrapper: resolve the preset's keys, apply its VRR degrade (swap to Force Off), then generate.
function Build-Nip { param($PresetKey, [bool]$Vrr, [bool]$AllowGlobal = $false)
  $cat = Load-Catalog
  $preset = $cat.presets.$PresetKey
  if (-not $preset) { throw "Unknown preset: $PresetKey" }
  $keys = @($preset.applied)
  if ($preset.needsVRR -and -not $Vrr -and ($keys -notcontains 'vsync-off')) { $keys += 'vsync-off' }
  $r = Build-NipXml $keys $Vrr $AllowGlobal
  if ($preset.needsVRR -and -not $Vrr) { $r.degraded = $true }
  return $r
}

function Invoke-NpiImport {
  <# Runs nvidiaProfileInspector's silent import with a PROPERLY QUOTED path (PS 5.1 joins
     -ArgumentList elements with spaces and quotes nothing, so 'C:\Users\John Smith\x.nip'
     arrived as two arguments and the tool imported nothing while exiting 0), then checks
     whether the driver store actually changed. #>
  param([string]$NipPath, [string]$Tag)
  $errf = Join-Path $env:TEMP "ff_${Tag}_err.txt"
  $outf = Join-Path $env:TEMP "ff_${Tag}_out.txt"
  $fpBefore = Get-DrsFingerprint
  $argLine = '-silentImport ' + (Quote-Arg $NipPath)
  $p = Start-Process -FilePath $Npi -ArgumentList $argLine -NoNewWindow -PassThru -Wait -RedirectStandardError $errf -RedirectStandardOutput $outf
  $stderr = ''
  try { $stderr = ((Get-Content -Raw -LiteralPath $errf -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim() } catch {}
  $stdout = ''
  try { $stdout = ((Get-Content -Raw -LiteralPath $outf -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim() } catch {}
  # The driver can flush the store a moment after the tool exits; give it a few tries before
  # concluding nothing moved.
  $changed = $null
  if ($null -ne $fpBefore) {
    for ($i = 0; $i -lt 6; $i++) {
      $fpAfter = Get-DrsFingerprint
      if ($null -eq $fpAfter) { $changed = $null; break }
      if ($fpAfter -ne $fpBefore) { $changed = $true; break }
      $changed = $false
      Start-Sleep -Milliseconds 400
    }
  }
  [pscustomobject]@{ exit = $p.ExitCode; stderr = $stderr; stdout = $stdout; storeChanged = $changed }
}

# Action validation in the BODY, not via [ValidateSet] on the parameter: a binding failure
# happens BEFORE the script runs, producing empty stdout plus a raw error on stderr, which
# the Electron host can only report as "the engine returned no output". Matches health.ps1.
$ValidActions = @('detect','snapshot','list','restore','createcsn','open','games','preview','apply-preset','revert','preview-custom','apply-custom','build-catalog')
if ($ValidActions -notcontains $Action) {
  $err = [ordered]@{
    ok = $false; action = "$Action"; errorCode = 'unknown-action'
    error = "Unknown action '$Action'."; validActions = $ValidActions
  }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $err -Depth 6 -Compress))
  exit 2
}

switch ($Action) {

  'detect' {
    $snaps = @(Get-Snapshots)
    $latest = if ($snaps.Count) { $snaps[0] } else { $null }
    $drsCount = if (Has-Nvidia) { @(Get-ChildItem -LiteralPath $Drs -File -ErrorAction SilentlyContinue).Count } else { 0 }
    $applied = $null
    if (Test-Path -LiteralPath $NipLedger) { try { $applied = (Get-Content -Raw -Encoding UTF8 -LiteralPath $NipLedger | ConvertFrom-Json).preset } catch {} }
    Write-FFJson @{
      nvidia       = (Has-Nvidia)
      tuner        = (Test-Path -LiteralPath $Npi)
      driver       = (Get-NvDriver)
      snapshots    = $snaps.Count
      latestSnap   = $latest
      drsFileCount = $drsCount
      csnAvailable = (Test-Path -LiteralPath (Join-Path $CsnDir 'CustomSettingNames.xml'))
      applied      = $applied
      stateRoot    = $StateRoot
    }
  }

  'snapshot' {
    if (-not (Has-Nvidia)) { Fail @{ ok = $false; reason = 'No NVIDIA DRS database found.' } }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # Copy the ENTIRE Drs folder (incl. nvdrswr.lk / nvAppTimestamps / update.bin) so Tier-2 rollback is bit-exact.
    $copied = @(); $failed = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Drs -File -ErrorAction SilentlyContinue)) {
      try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $f.Name) -Force; $copied += $f.Name } catch { $failed += $f.Name }
    }
    Write-FFJson @{ ok = ($failed.Count -eq 0); snapshot = $ts; files = $copied; failed = $failed; path = $dir }
  }

  'list' {
    Write-FFJson @{ ok = $true; snapshots = @(Get-Snapshots) }
  }

  'restore' {
    if (-not (Test-Admin)) { Fail @{ ok = $false; needsElevation = $true; reason = 'Restoring the driver database requires administrator rights.' } }
    $snaps = @(Get-Snapshots)
    if ($snaps.Count -eq 0) { Fail @{ ok = $false; reason = 'No snapshot to restore.' } }
    $ts = if ($Snapshot -eq 'latest') { $snaps[0] } else { $Snapshot }
    $dir = Join-Path $SnapRoot $ts
    if (-not (Test-Path -LiteralPath $dir)) { Fail @{ ok = $false; reason = "Snapshot not found: $ts" } }
    $restored = @(); $failed = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File)) {
      try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Drs $f.Name) -Force; $restored += $f.Name } catch { $failed += $f.Name }
    }
    $msg = if ($failed.Count) { "Partial restore: $($failed.Count) file(s) locked. Reboot and retry, or reset the Drs folder." } else { 'NVIDIA settings restored. Reboot to reload the driver database.' }
    Write-FFJson @{ ok = ($failed.Count -eq 0); snapshot = $ts; files = $restored; failed = $failed; needsReboot = $true; message = $msg }
  }

  'createcsn' {
    if (-not (Test-Path -LiteralPath $Npi)) { Fail @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } }
    New-Item -ItemType Directory -Force -Path $CsnDir | Out-Null
    $ref = Join-Path $NpiDir 'Reference.xml'
    $refBak = Join-Path $env:TEMP 'ff_ref_backup.xml'
    if (Test-Path -LiteralPath $ref) { Copy-Item -LiteralPath $ref -Destination $refBak -Force }
    $before = @{}
    foreach ($x in (Get-ChildItem -LiteralPath $NpiDir -Filter *.xml -ErrorAction SilentlyContinue)) { $before[$x.Name] = $x.LastWriteTimeUtc }
    $errf = Join-Path $env:TEMP 'ff_csn_err.txt'; $outf = Join-Path $env:TEMP 'ff_csn_out.txt'
    $p = Start-Process -FilePath $Npi -ArgumentList '-createCSN' -WorkingDirectory $NpiDir -NoNewWindow -PassThru -Wait -RedirectStandardError $errf -RedirectStandardOutput $outf
    $emitted = $null
    foreach ($x in (Get-ChildItem -LiteralPath $NpiDir -Filter *.xml -ErrorAction SilentlyContinue)) {
      $changed = (-not $before.ContainsKey($x.Name)) -or ($x.LastWriteTimeUtc -gt $before[$x.Name])
      if ($changed -and $x.Name -ne 'Reference.xml') { $emitted = $x.FullName; break }
    }
    $dest = Join-Path $CsnDir 'CustomSettingNames.xml'
    $note = ''
    if ($emitted) {
      Copy-Item -LiteralPath $emitted -Destination $dest -Force
    } elseif ((Test-Path -LiteralPath $ref) -and $before.ContainsKey('Reference.xml') -and ((Get-Item -LiteralPath $ref).LastWriteTimeUtc -gt $before['Reference.xml'])) {
      Copy-Item -LiteralPath $ref -Destination $dest -Force
      if (Test-Path -LiteralPath $refBak) { Copy-Item -LiteralPath $refBak -Destination $ref -Force }
      $note = 'createCSN overwrote Reference.xml; bundled copy restored.'
    }
    $made = Test-Path -LiteralPath $dest
    $count = 0
    if ($made) { $count = ([regex]::Matches((Get-Content -Raw -Encoding UTF8 -LiteralPath $dest), '<CustomSetting>')).Count }
    $stderr = ''
    try { $stderr = ((Get-Content -Raw -LiteralPath $errf -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim() } catch {}
    Write-FFJson @{ ok = $made; exit = $p.ExitCode; path = $dest; settingCount = $count; note = $note; stderr = $stderr }
  }

  'open' {
    if (-not (Test-Path -LiteralPath $Npi)) { Fail @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } }
    Start-Process -FilePath $Npi | Out-Null
    Write-FFJson @{ ok = $true; message = 'Opening NVIDIA tuner...' }
  }

  'build-catalog' {
    # Resolve the driver-independent template against THIS driver's CSN map -> data\nvidia-settings.json.
    $tmplPath = Join-Path $Root 'data\nvidia-catalog-template.json'
    $csnPath = Join-Path $CsnDir 'CustomSettingNames.xml'
    if (-not (Test-Path -LiteralPath $tmplPath)) { Fail @{ ok = $false; reason = 'Catalog template missing.' } }
    if (-not (Test-Path -LiteralPath $csnPath)) { Fail @{ ok = $false; needsCsn = $true; reason = 'No driver settings map yet - run createcsn first (needs admin).' } }
    [xml]$csnXml = Get-Content -Raw -Encoding UTF8 -LiteralPath $csnPath
    $byName = @{}
    foreach ($s in $csnXml.CustomSettingNames.Settings.CustomSetting) {
      $vals = @{}
      foreach ($v in $s.SettingValues.CustomSettingValue) { $vn = "$($v.UserfriendlyName)"; if ($vn) { $vals[$vn] = (HexToDec $v.HexValue) } }
      $byName["$($s.UserfriendlyName)"] = @{ id = (HexToDec $s.HexSettingID); values = $vals }
    }
    $tmpl = Get-Content -Raw -Encoding UTF8 -LiteralPath $tmplPath | ConvertFrom-Json
    # The frame-limiter cap is derived from a MEASURED refresh rate or it is not written at all.
    # -Refresh used to default to 240, so a machine whose refresh rate was never read got a
    # 236 FPS cap invented out of a hardcoded number and baked into the catalog.
    $capKnown = ($Refresh -gt 0)
    $cap = $null
    if ($capKnown) { $cap = "$([Math]::Max(30, $Refresh - 4)) FPS" }
    $settings = [ordered]@{}; $resolved = 0; $unresolved = @(); $capSkipped = @()
    foreach ($key in $tmpl.settings.PSObject.Properties.Name) {
      $t = $tmpl.settings.$key
      $recLabel = $t.recommendedLabel
      $needsCap = ($recLabel -eq 'auto-cap')
      if ($needsCap) { $recLabel = $cap }
      $cs = $byName["$($t.csnName)"]
      $id = $null; $rec = $null; $def = $null; $conf = 'unresolved'; $why = $t.why
      if ($needsCap -and -not $capKnown) {
        # Honest unresolved, with the reason, instead of a cap nobody measured.
        $unresolved += $key; $capSkipped += $key
        $settings[$key] = [ordered]@{ name = $t.csnName; recommendedLabel = $null; settingId = $null; recommendedCode = $null; defaultLabel = $t.defaultLabel; defaultCode = $null; category = $t.category; tier = $t.tier; impact = $t.impact; scope = $t.scope; antiCheatSafe = $t.antiCheatSafe; idConfidence = 'unresolved'; unresolvedReason = 'FrameForge could not measure your display refresh rate, so it will not invent a frame-rate cap. Re-run after the display mode is readable, or set the cap yourself in the tuner.'; why = $why }
        continue
      }
      if ($cs) {
        $id = $cs.id
        if ($cs.values.ContainsKey($recLabel)) { $rec = $cs.values[$recLabel] }
        if ($cs.values.ContainsKey($t.defaultLabel)) { $def = $cs.values[$t.defaultLabel] }
      }
      if ($null -ne $id -and $null -ne $rec) { $conf = 'verified'; $resolved++ } else { $unresolved += $key }
      $settings[$key] = [ordered]@{ name = $t.csnName; recommendedLabel = $recLabel; settingId = $id; recommendedCode = $rec; defaultLabel = $t.defaultLabel; defaultCode = $def; category = $t.category; tier = $t.tier; impact = $t.impact; scope = $t.scope; antiCheatSafe = $t.antiCheatSafe; idConfidence = $conf; why = $why }
    }
    $placebo = @()
    foreach ($p in $tmpl.placebo) { $cs = $byName["$($p.csnName)"]; $sid = 0; if ($cs) { $sid = $cs.id }; $placebo += [ordered]@{ name = $p.csnName; settingId = $sid; claim = $p.claim; why = $p.why } }
    $out = [ordered]@{ schemaVersion = 2; driverVerifiedOn = (Get-NvDriver); generatedAt = (Get-Date).ToString('s'); refreshHz = $(if ($capKnown) { $Refresh } else { $null }); refreshMeasured = $capKnown; settings = $settings; presets = $tmpl.presets; placebo = $placebo; inGame = $tmpl.inGame }
    $json = ConvertTo-Json -InputObject $out -Depth 8
    [System.IO.File]::WriteAllText((Join-Path $Root 'data\nvidia-settings.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    Write-FFJson @{ ok = $true; driver = (Get-NvDriver); resolved = $resolved; unresolved = $unresolved; cap = $cap; refreshMeasured = $capKnown; capSkipped = $capSkipped } -Depth 4
  }

  'games' {
    Write-FFJson @{ ok = $true; games = @(Get-DetectedGames) } -Depth 4
  }

  'preview' {
    # Generate the .nip WITHOUT applying — for validation and the UI diff sheet.
    $b = Build-Nip $Preset ([bool]$VrrOk) ([bool]$AllowGlobalFallback)
    Write-FFJson @{ ok = $true; preset = $Preset; keys = $b.keys; games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys; nip = $b.xml } -Depth 5
  }

  'preview-custom' {
    $kl = @($Keys -split '[,\s]+' | Where-Object { $_ })
    $b = Build-NipXml $kl ([bool]$VrrOk) ([bool]$AllowGlobalFallback)
    Write-FFJson @{ ok = $true; keys = $b.keys; games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys; nip = $b.xml } -Depth 5
  }

  'apply-preset' {
    if (-not (Test-Admin)) { Fail @{ ok = $false; needsElevation = $true; reason = 'Applying NVIDIA settings requires administrator rights.' } }
    if (-not (Test-Path -LiteralPath $Npi)) { Fail @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } }
    # 1) Snapshot first (the exact-rollback backbone).
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss'); $snapDir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
    $snapFailed = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Drs -File -ErrorAction SilentlyContinue)) {
      try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $snapDir $f.Name) -Force } catch { $snapFailed += $f.Name }
    }
    if ($snapFailed.Count) { Fail @{ ok = $false; reason = "Could not snapshot the driver database before applying ($($snapFailed.Count) file(s) locked), so there would be nothing to roll back to. Nothing was changed."; failed = $snapFailed } }
    # 2) Generate the .nip and import it.
    $b = Build-Nip $Preset ([bool]$VrrOk) ([bool]$AllowGlobalFallback)
    if ($b.profileCount -eq 0) {
      Fail @{ ok = $false; reason = 'Nothing to apply: every setting in this preset was either unverified on your driver or skipped for scope reasons.'; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys }
    }
    $nipPath = Join-Path $env:TEMP "frameforge-$Preset.nip"
    Set-Content -LiteralPath $nipPath -Value $b.xml -Encoding Unicode
    $imp = Invoke-NpiImport $nipPath 'apply'
    # Exit 0 is NOT proof: verify the driver store actually moved.
    $ok = ($imp.exit -eq 0) -and ($imp.storeChanged -ne $false)
    if ($ok) {
      Set-Content -LiteralPath $NipLedger -Value (ConvertTo-Json -InputObject @{ preset = $Preset; snapshot = $ts; appliedAt = (Get-Date).ToString('s'); games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback } -Compress) -Encoding UTF8
    }
    $msg = if ($ok -and $imp.storeChanged -eq $true) { "Applied '$Preset'. Close and relaunch your game for it to take effect." }
           elseif ($ok) { "Applied '$Preset' (exit 0), but FrameForge could not read the driver database to confirm the change. Close and relaunch your game, then re-check." }
           elseif ($imp.exit -eq 0) { "The tuner exited 0 but no driver setting changed, so FrameForge is NOT recording this as applied. Your settings are unchanged; snapshot $ts is available." }
           else { "Import failed (exit $($imp.exit)). Your settings are unchanged; snapshot $ts is available." }
    if ($b.scopeMessage) { $msg = $msg + ' ' + $b.scopeMessage }
    Write-FFJson @{ ok = $ok; verified = ($imp.storeChanged -eq $true); preset = $Preset; exit = $imp.exit; snapshot = $ts; games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys; message = $msg; stderr = $imp.stderr } -Depth 5
  }

  'apply-custom' {
    if (-not (Test-Admin)) { Fail @{ ok = $false; needsElevation = $true; reason = 'Applying NVIDIA settings requires administrator rights.' } }
    if (-not (Test-Path -LiteralPath $Npi)) { Fail @{ ok = $false; reason = 'nvidiaProfileInspector not found.' } }
    $kl = @($Keys -split '[,\s]+' | Where-Object { $_ })
    if ($kl.Count -eq 0) { Fail @{ ok = $false; reason = 'No settings selected.' } }
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss'); $snapDir = Join-Path $SnapRoot $ts
    New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
    $snapFailed = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Drs -File -ErrorAction SilentlyContinue)) {
      try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $snapDir $f.Name) -Force } catch { $snapFailed += $f.Name }
    }
    if ($snapFailed.Count) { Fail @{ ok = $false; reason = "Could not snapshot the driver database before applying ($($snapFailed.Count) file(s) locked). Nothing was changed."; failed = $snapFailed } }
    $b = Build-NipXml $kl ([bool]$VrrOk) ([bool]$AllowGlobalFallback)
    if ($b.profileCount -eq 0) {
      Fail @{ ok = $false; reason = 'Nothing to apply: every selected setting was either unverified on your driver or skipped for scope reasons.'; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys }
    }
    $nipPath = Join-Path $env:TEMP 'frameforge-custom.nip'
    Set-Content -LiteralPath $nipPath -Value $b.xml -Encoding Unicode
    $imp = Invoke-NpiImport $nipPath 'applyc'
    $ok = ($imp.exit -eq 0) -and ($imp.storeChanged -ne $false)
    if ($ok) {
      Set-Content -LiteralPath $NipLedger -Value (ConvertTo-Json -InputObject @{ preset = 'custom'; snapshot = $ts; appliedAt = (Get-Date).ToString('s'); keys = $b.keys; games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback } -Compress) -Encoding UTF8
    }
    $msg = if ($ok -and $imp.storeChanged -eq $true) { "Applied $($b.keys.Count) custom setting(s). Close and relaunch your game to take effect." }
           elseif ($ok) { "Applied $($b.keys.Count) custom setting(s) (exit 0), but FrameForge could not read the driver database to confirm the change." }
           elseif ($imp.exit -eq 0) { "The tuner exited 0 but no driver setting changed, so FrameForge is NOT recording this as applied. Your settings are unchanged; snapshot $ts is available." }
           else { "Import failed (exit $($imp.exit)). Your settings are unchanged; snapshot $ts is available." }
    if ($b.scopeMessage) { $msg = $msg + ' ' + $b.scopeMessage }
    Write-FFJson @{ ok = $ok; verified = ($imp.storeChanged -eq $true); preset = 'custom'; exit = $imp.exit; snapshot = $ts; keys = $b.keys; games = $b.games; degraded = $b.degraded; scopeFallback = $b.scopeFallback; scopeMessage = $b.scopeMessage; unresolvedKeys = $b.unresolvedKeys; message = $msg; stderr = $imp.stderr } -Depth 5
  }

  'revert' {
    if (-not (Test-Admin)) { Fail @{ ok = $false; needsElevation = $true; reason = 'Reverting NVIDIA settings requires administrator rights.' } }
    if (-not (Test-Path -LiteralPath $NipLedger)) { Fail @{ ok = $false; reason = 'No FrameForge NVIDIA changes on record to revert.' } }
    $rec = Get-Content -Raw -Encoding UTF8 -LiteralPath $NipLedger | ConvertFrom-Json
    $dir = Join-Path $SnapRoot $rec.snapshot
    if (-not (Test-Path -LiteralPath $dir)) { Fail @{ ok = $false; reason = "Snapshot $($rec.snapshot) not found." } }
    $restored = @(); $failed = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File)) {
      try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Drs $f.Name) -Force; $restored += $f.Name } catch { $failed += $f.Name }
    }
    if ($failed.Count -eq 0) { Remove-Item -LiteralPath $NipLedger -Force -ErrorAction SilentlyContinue }
    $msg = if ($failed.Count) { "Partial: $($failed.Count) file(s) locked - reboot and retry." } else { 'Reverted to your pre-apply NVIDIA settings. Reboot to reload the driver database.' }
    Write-FFJson @{ ok = ($failed.Count -eq 0); restored = $restored; failed = $failed; needsReboot = $true; message = $msg }
  }
}
