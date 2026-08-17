<#
  FrameForge :: sysinfo.ps1
  Read-only hardware + optimization-state detection. Emits a single JSON object on stdout.
  Safe to run without elevation (some fields degrade gracefully when not admin).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Get-RatedDdrSpeed {
  param([string]$PartNumber, [int]$Configured)
  # Kingston Fury: KF5<two-digit speed/100>... e.g. KF556 => DDR5-5600, KF548 => DDR5-4800
  if ($PartNumber -match 'KF5(\d{2})') { return [int]$Matches[1] * 100 }
  # Generic: look for a 4-digit speed token (e.g. 6000, 5600) in the part number
  if ($PartNumber -match '(\d{4})') {
    $n = [int]$Matches[1]
    if ($n -ge 3200 -and $n -le 9000) { return $n }
  }
  return 0
}

# ---------- OS ----------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$osObj = [ordered]@{
  caption      = $os.Caption
  version      = $os.Version
  build        = [int]$os.BuildNumber
  arch         = $os.OSArchitecture
  ramTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
  ramFreeGB    = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
  uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
  manufacturer = $cs.Manufacturer
  model        = $cs.Model
}

# ---------- CPU ----------
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpuObj = [ordered]@{
  name        = ($cpu.Name).Trim()
  cores       = [int]$cpu.NumberOfCores
  threads     = [int]$cpu.NumberOfLogicalProcessors
  maxClockMHz = [int]$cpu.MaxClockSpeed
  l3CacheKB   = [int]$cpu.L3CacheSize
  hybrid      = $false
  vendor      = $cpu.Manufacturer
}
# Heuristic hybrid (P+E) detection for Intel 12th gen+ : threads != cores*2 with high core count
if ($cpu.NumberOfLogicalProcessors -ne ($cpu.NumberOfCores * 2)) { $cpuObj.hybrid = $true }
# Raptor Lake (13th/14th gen) family for the microcode/stability advisory
$cpuObj.isRaptorLake = ($cpu.Name -match '1[34]\d{3}K?F?') -and ($cpu.Manufacturer -match 'Intel')
# Microcode revision (Vmin-shift mitigation check). Format varies (4- or 8-byte).
$cpuObj.microcode = $null; $cpuObj.microcodeOk = $null
try {
  $mb = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
  if ($mb -and $mb.Length -ge 4) {
    $mrev = if ($mb.Length -ge 8) { [System.BitConverter]::ToUInt32($mb, 4) } else { [System.BitConverter]::ToUInt32($mb, 0) }
    if ($mrev -eq 0) { $mrev = [System.BitConverter]::ToUInt32($mb, 0) }
    $cpuObj.microcode = ('0x{0:X}' -f $mrev)
    if ($cpuObj.isRaptorLake) { $cpuObj.microcodeOk = ($mrev -ge 0x125) }
  }
} catch {}

# ---------- GPU ----------
$gpus = @()
foreach ($g in (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Meta|Parsec|Virtual' })) {
  $vendor = if ($g.Name -match 'NVIDIA|GeForce|RTX|GTX') { 'NVIDIA' } elseif ($g.Name -match 'AMD|Radeon|RX ') { 'AMD' } elseif ($g.Name -match 'Intel|Arc|UHD|Iris') { 'Intel' } else { 'Unknown' }
  $gpus += [ordered]@{
    name          = $g.Name
    vendor        = $vendor
    driverVersion = $g.DriverVersion
    driverDate    = if ($g.DriverDate) { ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') } else { $null }
    curResW       = [int]$g.CurrentHorizontalResolution
    curResH       = [int]$g.CurrentVerticalResolution
    curHz         = [int]$g.CurrentRefreshRate
  }
}

# ---------- RAM (XMP / EXPO detection) ----------
$ramModules = @()
$ramOpportunity = $false
$maxRated = 0; $running = 0
foreach ($m in (Get-CimInstance Win32_PhysicalMemory)) {
  $rated = Get-RatedDdrSpeed -PartNumber $m.PartNumber -Configured ([int]$m.ConfiguredClockSpeed)
  if ($rated -gt $maxRated) { $maxRated = $rated }
  if ([int]$m.ConfiguredClockSpeed -gt $running) { $running = [int]$m.ConfiguredClockSpeed }
  $ramModules += [ordered]@{
    capacityGB   = [math]::Round($m.Capacity / 1GB, 0)
    speedRunning = [int]$m.ConfiguredClockSpeed
    speedRated   = $rated
    manufacturer = ($m.Manufacturer).Trim()
    part         = ($m.PartNumber).Trim()
  }
}
if ($maxRated -gt 0 -and $running -gt 0 -and $running -lt ($maxRated - 100)) { $ramOpportunity = $true }
$ramObj = [ordered]@{
  modules        = $ramModules
  runningMTs     = $running
  ratedMTs       = $maxRated
  xmpLikelyOff   = $ramOpportunity
}

# ---------- Disks ----------
$disks = @()
foreach ($d in (Get-PhysicalDisk)) {
  $disks += [ordered]@{
    name      = $d.FriendlyName
    mediaType = "$($d.MediaType)"
    busType   = "$($d.BusType)"
    sizeGB    = [math]::Round($d.Size / 1GB, 0)
    health    = "$($d.HealthStatus)"
  }
}

# ---------- Display modes (authoritative current mode + available refresh rates) ----------
# NOTE: Win32_VideoController CIM data is frequently stale/wrong for the live mode.
# EnumDisplaySettingsW(ENUM_CURRENT_SETTINGS) is authoritative. PowerShell marshals $null as
# an empty string, so a true NULL device name must be passed via [NullString]::Value.
$displayInfo = [ordered]@{
  currentHz = 0; currentW = 0; currentH = 0
  nativeW = 0; nativeH = 0
  maxHzAtCurrentRes = 0; refreshOpportunity = $false
  runningBelowNative = $false
  availableModes = @()
}
try {
  Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;
public class FFDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra;
    public uint dmFields; public int dmPositionX; public int dmPositionY; public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public ushort dmLogPixels; public uint dmBitsPerPel; public uint dmPelsWidth; public uint dmPelsHeight;
    public uint dmDisplayFlags; public uint dmDisplayFrequency;
    public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType; public uint dmDitherType; public uint dmReserved1; public uint dmReserved2;
    public uint dmPanningWidth; public uint dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int EnumDisplaySettingsW(string dn, int iMode, ref DEVMODE dm);
}
"@
  $dm = New-Object FFDisplay+DEVMODE
  $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'FFDisplay+DEVMODE')
  # ENUM_CURRENT_SETTINGS = -1 (authoritative live mode)
  if ([FFDisplay]::EnumDisplaySettingsW([NullString]::Value, -1, [ref]$dm) -ne 0) {
    $displayInfo.currentW = [int]$dm.dmPelsWidth
    $displayInfo.currentH = [int]$dm.dmPelsHeight
    $displayInfo.currentHz = [int]$dm.dmDisplayFrequency
  }
  $hzAtCur = @{}
  $maxPixels = 0
  $i = 0
  while ([FFDisplay]::EnumDisplaySettingsW([NullString]::Value, $i, [ref]$dm) -ne 0) {
    $w = [int]$dm.dmPelsWidth; $h = [int]$dm.dmPelsHeight
    if ($w * $h -gt $maxPixels) { $maxPixels = $w * $h; $displayInfo.nativeW = $w; $displayInfo.nativeH = $h }
    if ($w -eq $displayInfo.currentW -and $h -eq $displayInfo.currentH) { $hzAtCur[[int]$dm.dmDisplayFrequency] = $true }
    $i++
  }
  $displayInfo.availableModes = @($hzAtCur.Keys | Sort-Object)
  if ($displayInfo.availableModes.Count -gt 0) {
    $displayInfo.maxHzAtCurrentRes = ($displayInfo.availableModes | Measure-Object -Maximum).Maximum
    if ($displayInfo.maxHzAtCurrentRes -gt ($displayInfo.currentHz + 1)) { $displayInfo.refreshOpportunity = $true }
  }
  if ($maxPixels -gt ($displayInfo.currentW * $displayInfo.currentH)) { $displayInfo.runningBelowNative = $true }
} catch {
  # Fall back to CIM values from the primary GPU if the API path fails
  if ($gpus.Count -gt 0) {
    $displayInfo.currentW = $gpus[0].curResW
    $displayInfo.currentH = $gpus[0].curResH
    $displayInfo.currentHz = $gpus[0].curHz
  }
  $displayInfo.error = "$($_.Exception.Message)"
}

# ---------- Current optimization state ----------
function Get-RegVal { param($Path, $Name) try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null } }

$activeScheme = (powercfg /getactivescheme)
$activeName = if ($activeScheme -match '\((.+)\)') { $Matches[1] } else { 'Unknown' }
$ultimateExists = ((powercfg /list) -match 'Ultimate Performance').Count -gt 0

$state = [ordered]@{
  powerPlanActive       = $activeName
  ultimatePlanInstalled = $ultimateExists
  hags                  = (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode')        # 2 = on
  gameModeAuto          = (Get-RegVal 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled')
  gameBarEnabled        = (Get-RegVal 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled')
  gameDVR               = (Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR')
  win32PrioritySep      = (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation')
  systemResponsiveness  = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness')
  networkThrottling     = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex')
  gamesGpuPriority      = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority')
  visualFxSetting       = (Get-RegVal 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting')
  startupCount          = (Get-CimInstance Win32_StartupCommand | Measure-Object).Count
}

# ---------- Background processes (known game-irrelevant resource users) ----------
$bloatPatterns = 'OneDrive|Discord|Spotify|Slack|Teams|nordvpn|Adobe|GoogleDrive|Dropbox|EpicGames|EpicWeb|Razer|iCUE|SteelSeries|Logitech|GHUB|PulsarFusion|Cortana|YourPhone|PhoneExperience|Tailscale|java'
$procs = @()
foreach ($p in (Get-Process | Where-Object { $_.WorkingSet64 -gt 30MB -and $_.Name -match $bloatPatterns } | Sort-Object WorkingSet64 -Descending | Select-Object -First 20)) {
  $procs += [ordered]@{ name = $p.Name; ramMB = [math]::Round($p.WorkingSet64 / 1MB, 0); id = $p.Id }
}

# ---------- Active network adapter (wired vs Wi-Fi) ----------
$network = [ordered]@{ activeAdapter = $null; isWired = $null; linkSpeedMbps = 0 }
try {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
  if ($route) {
    $ad = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    if ($ad) {
      $network.activeAdapter = $ad.InterfaceDescription
      $network.isWired = -not ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')
      $mult = if ($ad.LinkSpeed -match 'Gbps') { 1000 } else { 1 }
      $num = [double]($ad.LinkSpeed -replace '[^\d.]', '')
      $network.linkSpeedMbps = [math]::Round($num * $mult, 0)
    }
  }
} catch {}

# ---------- Storage intelligence (Steam libraries -> physical disk) ----------
$storage = [ordered]@{ steamFound = $false; libraries = @(); slowGameCount = 0; hasFastDisk = $false }
try {
  # Map drive letters -> physical disk model + bus type.
  $driveMap = @{}
  foreach ($pt in (Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
    $dsk = Get-Disk -Number $pt.DiskNumber -ErrorAction SilentlyContinue
    if ($dsk) { $driveMap["$($pt.DriveLetter)"] = @{ model = $dsk.FriendlyName; bus = "$($dsk.BusType)" } }
  }
  $storage.hasFastDisk = (@($driveMap.Values | Where-Object { $_.bus -match 'NVMe' }).Count -gt 0)

  $steamPath = $null
  foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
    $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue)
    if ($v.SteamPath) { $steamPath = $v.SteamPath; break }
    if ($v.InstallPath) { $steamPath = $v.InstallPath; break }
  }
  if ($steamPath) {
    $storage.steamFound = $true
    $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    $paths = @()
    if (Test-Path $vdf) {
      foreach ($m in [regex]::Matches((Get-Content -Raw $vdf), '"path"\s*"([^"]+)"')) { $paths += ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    if (-not $paths) { $paths = @($steamPath) }
    foreach ($p in ($paths | Select-Object -Unique)) {
      $drive = if ($p -match '^([A-Za-z]):') { $Matches[1] } else { $null }
      $info = if ($drive -and $driveMap.ContainsKey($drive)) { $driveMap[$drive] } else { @{ model = 'unknown'; bus = 'unknown' } }
      $games = @(Get-ChildItem (Join-Path $p 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue).Count
      $slow = ($info.bus -match 'SATA')
      if ($slow) { $storage.slowGameCount += $games }
      $storage.libraries += [ordered]@{ path = $p; drive = $drive; disk = $info.model; bus = $info.bus; games = $games; slow = $slow }
    }
  }
} catch { $storage.error = "$($_.Exception.Message)" }

# ---------- Admin status ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$result = [ordered]@{
  generatedAt = (Get-Date).ToString('s')
  isAdmin     = $isAdmin
  os          = $osObj
  cpu         = $cpuObj
  gpus        = $gpus
  ram         = $ramObj
  disks       = $disks
  display     = $displayInfo
  network     = $network
  storage     = $storage
  state       = $state
  background  = $procs
}

$result | ConvertTo-Json -Depth 6 -Compress
