<#
  FrameForge :: sysinfo.ps1
  Read-only hardware + optimization-state detection. Emits a single JSON object on stdout.
  Safe to run without elevation (some fields degrade gracefully when not admin).

  PORTABILITY DOCTRINE: hardware facts are keyed on IDENTIFIERS (PCI vendor IDs, CPUID
  family/model, SMBIOS enums, numeric CIM properties), never on display names or formatted
  strings, both of which are localized. Anything that could not actually be measured is
  reported as null with a *Determined/*classified flag beside it — never as a confident 0.
#>
[CmdletBinding()]
param(
  # The SID the UNELEVATED FrameForge read from its own token before relaunching itself
  # elevated (see engine/engine.ps1 and electron/main.js). Three fields in the optimization
  # state below come from HKCU, which is the hive of whatever account THIS process runs as —
  # after "Run as administrator" with someone else's credentials that is not the gamer's
  # profile, and reporting those values as this PC's state would be a measurement of the
  # wrong person. Optional; when absent the script probes and says what it found.
  [string]$OriginSid
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# _lib.ps1 sets BOM-free UTF-8 on stdout and provides Write-FFJson (one JSON doc, no PS 5.1
# single-element-array unrolling). Without it this script's JSON leaves PowerShell in the console
# OEM code page and every non-ASCII character (GPU/OS names, accented paths) reaches Node as
# mojibake. Guarded so a missing/edited _lib can never take the whole probe down.
try { . (Join-Path $PSScriptRoot '_lib.ps1') } catch {}
if (-not (Get-Command Write-FFJson -ErrorAction SilentlyContinue)) {
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  function Write-FFJson { param($InputObject, [int]$Depth = 12, [switch]$Pretty)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress))
  }
}

function Get-RatedDdrSpeed {
  param([string]$PartNumber, [int]$Configured, [int]$SpdSpeed)
  # Kingston Fury: KF5<two-digit speed/100>... e.g. KF556 => DDR5-5600, KF548 => DDR5-4800
  if ($PartNumber -match 'KF5(\d{2})') { return [int]$Matches[1] * 100 }
  # Generic: look for a 4-digit speed token (e.g. 6000, 5600) in the part number
  if ($PartNumber -match '(\d{4})') {
    $n = [int]$Matches[1]
    if ($n -ge 3200 -and $n -le 9000) { return $n }
  }
  # SMBIOS "Speed" is the module's configured maximum; only trust it when it is above the
  # speed the module is actually running at, which is exactly the XMP-off signal.
  if ($SpdSpeed -gt 0 -and $SpdSpeed -gt $Configured) { return $SpdSpeed }
  return 0
}

function Get-MemoryTypeName {
  <# SMBIOS Memory Type is a numeric enum (SMBIOS 7.18.2) and is locale-invariant, unlike any
     display string. Returns $null when it cannot be resolved so the UI prints nothing rather
     than the developer's 'DDR5'. #>
  param($SmbiosType)
  if ($null -eq $SmbiosType) { return $null }
  $map = @{
    18='DDR'; 19='DDR2'; 20='DDR2 FB-DIMM'; 24='DDR3'; 26='DDR4'
    27='LPDDR'; 28='LPDDR2'; 29='LPDDR3'; 30='LPDDR4'; 34='DDR5'; 35='LPDDR5'
  }
  $k = [int]$SmbiosType
  if ($map.ContainsKey($k)) { return $map[$k] }
  return $null
}

# ---------- OS ----------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$osObj = [ordered]@{
  caption      = $os.Caption
  version      = $os.Version
  build        = [int]$os.BuildNumber
  arch         = $os.OSArchitecture
  archId       = $env:PROCESSOR_ARCHITECTURE   # AMD64 / ARM64 / x86 — invariant, unlike OSArchitecture
  ramTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
  ramFreeGB    = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
  uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
  manufacturer = $cs.Manufacturer
  model        = $cs.Model
}

# ---------- Form factor (needed to tell a desktop CPU from a mobile one) ----------
function Get-BatteryPowered {
  # $true portable, $false not, $null unknown. Never guess.
  $answered = $false; $result = $null
  try { $b = @(Get-CimInstance Win32_Battery -ErrorAction Stop); $answered = $true; if ($b.Count -gt 0) { $result = $true } } catch {}
  if ($null -eq $result) {
    try {
      $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
      $types = @()
      foreach ($e in @(Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop)) { $types += @($e.ChassisTypes) }
      if ($types.Count -gt 0) { $answered = $true; foreach ($t in $types) { if ($portable -contains [int]$t) { $result = $true; break } } }
    } catch {}
  }
  if ($null -eq $result -and $answered) { $result = $false }
  $result
}
$isPortable = Get-BatteryPowered

# ---------- CPU ----------
# Sum across ALL sockets: Select-Object -First 1 reported one socket's counts as the whole
# machine's on a dual-socket box.
$cpuAll = @(Get-CimInstance Win32_Processor)
$cpu = $cpuAll | Select-Object -First 1
$coresSum = 0; $threadsSum = 0
foreach ($c in $cpuAll) { $coresSum += [int]$c.NumberOfCores; $threadsSum += [int]$c.NumberOfLogicalProcessors }

$cpuObj = [ordered]@{
  name        = "$($cpu.Name)".Trim()
  cores       = $coresSum
  threads     = $threadsSum
  sockets     = $cpuAll.Count
  maxClockMHz = [int]$cpu.MaxClockSpeed
  l3CacheKB   = [int]$cpu.L3CacheSize
  hybrid      = $null
  vendor      = "$($cpu.Manufacturer)".Trim()
}

# CPUID family/model from the HAL-written, ASCII, never-localized registry identifier
# ('Intel64 Family 6 Model 183 Stepping 1'); Win32_Processor.Description is the same string.
$cpuIdent = $null; $cpuVendorId = $null
try {
  $ck = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
  if ($ck.PSObject.Properties.Name -contains 'Identifier')       { $cpuIdent   = "$($ck.Identifier)".Trim() }
  if ($ck.PSObject.Properties.Name -contains 'VendorIdentifier') { $cpuVendorId = "$($ck.VendorIdentifier)".Trim() }
} catch {}
if (-not $cpuIdent)    { $cpuIdent    = "$($cpu.Description)".Trim() }
if (-not $cpuVendorId) { $cpuVendorId = "$($cpu.Manufacturer)".Trim() }
$cpuFamily = $null; $cpuModel = $null
if ($cpuIdent -match 'Family\s+(\d+)\s+Model\s+(\d+)') { $cpuFamily = [int]$Matches[1]; $cpuModel = [int]$Matches[2] }
$cpuObj.vendorId = $cpuVendorId
$cpuObj.family   = $cpuFamily
$cpuObj.model    = $cpuModel

# Hybrid (P+E) is NOT "threads != cores*2": that arithmetic is also true of every CPU without
# SMT — ARM64, Atom/N-series, Celeron/Pentium, or hyper-threading turned off in BIOS. Only
# claim hybrid where it can be established; otherwise leave it null so the UI prints nothing.
# Intel hybrid parts to date: family 6, Alder Lake 0x97/0x9A, Raptor Lake 0xB7/0xBA/0xBF,
# Meteor/Arrow/Lunar Lake 0xAA/0xAC/0xC6/0xBD.
if ($cpuVendorId -eq 'GenuineIntel' -and $null -ne $cpuFamily -and $null -ne $cpuModel) {
  $hybridModels = @(151, 154, 183, 186, 191, 170, 172, 198, 189)
  if ($cpuFamily -eq 6) {
    if ($hybridModels -contains $cpuModel) { $cpuObj.hybrid = $true }
    elseif ($cpuModel -lt 151) { $cpuObj.hybrid = $false }   # pre-Alder Lake: no hybrid parts exist
  }
} elseif ($cpuVendorId -and $cpuVendorId -ne 'GenuineIntel') {
  $cpuObj.hybrid = $false
}

# Raptor Lake S (DESKTOP) only: model 0xB7 (183) / 0xBF (191) covers S and HX, and their
# microcode series are unrelated, so the form factor decides. Unknown stays null.
$cpuObj.isRaptorLake = $null
if ($cpuVendorId -eq 'GenuineIntel' -and $cpuFamily -eq 6 -and (@(183, 191) -contains $cpuModel)) {
  if ($isPortable -eq $true) { $cpuObj.isRaptorLake = $false } elseif ($isPortable -eq $false) { $cpuObj.isRaptorLake = $true }
} elseif ($null -ne $cpuFamily -and $null -ne $cpuModel -and $cpuVendorId) {
  $cpuObj.isRaptorLake = $false
}

# Microcode revision. The number itself is reportable on any CPU, but the 0x125 COMPARISON is
# meaningful only for desktop Raptor Lake — microcode revisions are per-CPUID. microcodeOk stays
# null everywhere else so the UI renders no chip instead of a false pass or a false warning.
$cpuObj.microcode = $null; $cpuObj.microcodeOk = $null
$cpuObj.microcodeCheckApplies = ($cpuObj.isRaptorLake -eq $true)
try {
  $mb = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
  if ($mb -and $mb.Length -ge 4) {
    $mrev = if ($mb.Length -ge 8) { [System.BitConverter]::ToUInt32($mb, 4) } else { [System.BitConverter]::ToUInt32($mb, 0) }
    if ($mrev -eq 0) { $mrev = [System.BitConverter]::ToUInt32($mb, 0) }
    $cpuObj.microcode = ('0x{0:X}' -f $mrev)
    if ($cpuObj.isRaptorLake -eq $true) { $cpuObj.microcodeOk = ($mrev -ge 0x125) }
  }
} catch {}

# ---------- GPU ----------
# Keyed on PNPDeviceID, not on the adapter NAME: inbox adapter names come from localized INF
# strings (the Microsoft Basic Display Adapter is renamed in every language pack), so a name
# filter lets a fallback/virtual adapter become gpus[0] and labels real hardware 'Unknown'.
# PCI vendor IDs are locale-invariant.
$gpus = @()
foreach ($g in (Get-CimInstance Win32_VideoController)) {
  $pnp = "$($g.PNPDeviceID)"
  # ROOT\ and SWD\ enumerators are software/virtual display adapters (RDP, Meta, Parsec,
  # IddCx virtual monitors) — never the physical GPU.
  if ($pnp -match '^(ROOT|SWD)\\') { continue }
  $vendor = 'Unknown'
  if     ($pnp -match '(?i)VEN_10DE') { $vendor = 'NVIDIA' }
  elseif ($pnp -match '(?i)VEN_1002' -or $pnp -match '(?i)VEN_1022') { $vendor = 'AMD' }
  elseif ($pnp -match '(?i)VEN_8086') { $vendor = 'Intel' }
  elseif ($pnp -match '(?i)VEN_1414') { $vendor = 'Microsoft' }   # Hyper-V / Remote Display
  elseif ($pnp -match '(?i)VEN_15AD') { $vendor = 'VMware' }
  elseif ($pnp -match '(?i)VEN_1AB8') { $vendor = 'Parallels' }
  elseif ($pnp -match '(?i)VEN_5333|VEN_80EE') { $vendor = 'VirtualBox' }
  if ($vendor -in @('Microsoft', 'VMware', 'Parallels', 'VirtualBox')) { continue }  # virtual GPU
  $gpus += [ordered]@{
    name          = $g.Name
    vendor        = $vendor
    pnpDeviceId   = $pnp
    driverVersion = $g.DriverVersion
    driverDate    = if ($g.DriverDate) { ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') } else { $null }
    vramBytes     = if ($g.AdapterRAM -and [int64]$g.AdapterRAM -gt 0) { [int64]$g.AdapterRAM } else { $null }
    curResW       = [int]$g.CurrentHorizontalResolution
    curResH       = [int]$g.CurrentVerticalResolution
    curHz         = [int]$g.CurrentRefreshRate
  }
}
# Discrete cards first so gpus[0] is the gaming GPU, not an iGPU or a fallback adapter.
$gpus = @(@($gpus | Where-Object { $_.vendor -in @('NVIDIA', 'AMD') }) + @($gpus | Where-Object { $_.vendor -notin @('NVIDIA', 'AMD') }))

# ---------- RAM (XMP / EXPO detection) ----------
$ramModules = @()
$ramOpportunity = $false
$maxRated = 0; $running = 0; $memType = $null
foreach ($m in (Get-CimInstance Win32_PhysicalMemory)) {
  $rated = Get-RatedDdrSpeed -PartNumber "$($m.PartNumber)" -Configured ([int]$m.ConfiguredClockSpeed) -SpdSpeed ([int]$m.Speed)
  if ($rated -gt $maxRated) { $maxRated = $rated }
  if ([int]$m.ConfiguredClockSpeed -gt $running) { $running = [int]$m.ConfiguredClockSpeed }
  if (-not $memType) { $memType = Get-MemoryTypeName $m.SMBIOSMemoryType }
  $ramModules += [ordered]@{
    capacityGB   = [math]::Round($m.Capacity / 1GB, 0)
    speedRunning = [int]$m.ConfiguredClockSpeed
    speedRated   = $rated
    memoryType   = (Get-MemoryTypeName $m.SMBIOSMemoryType)
    manufacturer = "$($m.Manufacturer)".Trim()
    part         = "$($m.PartNumber)".Trim()
  }
}
if ($maxRated -gt 0 -and $running -gt 0 -and $running -lt ($maxRated - 100)) { $ramOpportunity = $true }
$ramObj = [ordered]@{
  modules        = $ramModules
  runningMTs     = $running
  ratedMTs       = $maxRated
  memoryType     = $memType          # null when SMBIOS did not say — the UI must print nothing
  xmpLikelyOff   = $ramOpportunity
}

# ---------- Disks ----------
# MediaType (HDD / SSD / SCM / Unspecified) is the real signal; BusType is only a tiebreaker.
# A SATA SSD is not a slow disk, and an HDD behind RAID/USB is not a fast one.
function Get-DiskSpeedClass {
  param($MediaType, $BusType)
  $mt = "$MediaType"
  if ($mt -eq 'HDD') { return 'hdd' }
  if ($mt -eq 'SSD' -or $mt -eq 'SCM') {
    if ("$BusType" -match 'NVMe') { return 'nvme' }
    return 'ssd'
  }
  # 'Unspecified' / blank means the driver did not report it: unknown, not a category.
  if ("$BusType" -match 'NVMe') { return 'nvme' }
  return 'unknown'
}
$disks = @()
$diskByNumber = @{}
foreach ($d in (Get-PhysicalDisk)) {
  $cls = Get-DiskSpeedClass $d.MediaType $d.BusType
  $row = [ordered]@{
    name       = $d.FriendlyName
    mediaType  = "$($d.MediaType)"
    busType    = "$($d.BusType)"
    speedClass = $cls                          # nvme | ssd | hdd | unknown
    sizeGB     = [math]::Round($d.Size / 1GB, 0)
    health     = "$($d.HealthStatus)"
  }
  $disks += $row
  if ($null -ne $d.DeviceId) { $diskByNumber["$($d.DeviceId)"] = $row }
}

# ---------- Display modes (every attached display, not just the primary) ----------
$displayInfo = [ordered]@{
  determined = $false
  currentHz = 0; currentW = 0; currentH = 0
  nativeW = 0; nativeH = 0
  maxHzAtCurrentRes = 0; refreshOpportunity = $false
  maxHzAnyDisplay = 0
  runningBelowNative = $false
  availableModes = @()
  displays = @()
  source = $null
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
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public uint StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int EnumDisplaySettingsW(string dn, int iMode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool EnumDisplayDevicesW(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
}
"@

  function Read-FFDisplayMode {
    <# Current mode + every refresh rate available at that resolution, for ONE adapter.
       $DeviceName $null (via [NullString]::Value) means the primary display. #>
    param([string]$DeviceName, [bool]$IsPrimary, [string]$Label)
    $dm = New-Object FFDisplay+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'FFDisplay+DEVMODE')
    $arg = $DeviceName
    if (-not $DeviceName) { $arg = [NullString]::Value }
    if ([FFDisplay]::EnumDisplaySettingsW($arg, -1, [ref]$dm) -eq 0) { return $null }
    $curW = [int]$dm.dmPelsWidth; $curH = [int]$dm.dmPelsHeight; $curHz = [int]$dm.dmDisplayFrequency
    if ($curW -le 0 -or $curH -le 0) { return $null }
    $hzAtCur = @{}; $maxPixels = 0; $natW = 0; $natH = 0; $i = 0
    while ([FFDisplay]::EnumDisplaySettingsW($arg, $i, [ref]$dm) -ne 0) {
      $w = [int]$dm.dmPelsWidth; $h = [int]$dm.dmPelsHeight
      if (($w * $h) -gt $maxPixels) { $maxPixels = $w * $h; $natW = $w; $natH = $h }
      if ($w -eq $curW -and $h -eq $curH) { $hzAtCur[[int]$dm.dmDisplayFrequency] = $true }
      $i++
    }
    $modes = @($hzAtCur.Keys | Sort-Object)
    $maxHz = 0
    if ($modes.Count -gt 0) { $maxHz = ($modes | Measure-Object -Maximum).Maximum }
    [ordered]@{
      device = $DeviceName; label = $Label; isPrimary = $IsPrimary
      currentW = $curW; currentH = $curH; currentHz = $curHz
      nativeW = $natW; nativeH = $natH
      availableModes = $modes
      maxHzAtCurrentRes = $maxHz
      refreshOpportunity = ($maxHz -gt ($curHz + 1))
      runningBelowNative = ($maxPixels -gt ($curW * $curH))
    }
  }

  $found = @()
  $dd = New-Object FFDisplay+DISPLAY_DEVICE
  $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'FFDisplay+DISPLAY_DEVICE')
  $n = 0
  while ([FFDisplay]::EnumDisplayDevicesW([NullString]::Value, $n, [ref]$dd, 0)) {
    $flags = [uint32]$dd.StateFlags
    if (($flags -band 0x1) -ne 0) {           # DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
      $isPrim = (($flags -band 0x4) -ne 0)    # DISPLAY_DEVICE_PRIMARY_DEVICE
      $one = Read-FFDisplayMode "$($dd.DeviceName)" $isPrim "$($dd.DeviceString)"
      if ($one) { $found += $one }
    }
    $n++
    $dd = New-Object FFDisplay+DISPLAY_DEVICE
    $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'FFDisplay+DISPLAY_DEVICE')
  }
  # Session 0 / headless / RDP can enumerate nothing: fall back to the primary-display query.
  if ($found.Count -eq 0) {
    $one = Read-FFDisplayMode $null $true 'Primary display'
    if ($one) { $found += $one }
  }
  if ($found.Count -gt 0) {
    $displayInfo.determined = $true
    $displayInfo.source = 'EnumDisplaySettingsW'
    $displayInfo.displays = @($found)
    $primary = @($found | Where-Object { $_.isPrimary }) | Select-Object -First 1
    if (-not $primary) { $primary = $found[0] }
    $displayInfo.currentW = $primary.currentW
    $displayInfo.currentH = $primary.currentH
    $displayInfo.currentHz = $primary.currentHz
    $displayInfo.nativeW = $primary.nativeW
    $displayInfo.nativeH = $primary.nativeH
    $displayInfo.availableModes = @($primary.availableModes)
    $displayInfo.maxHzAtCurrentRes = $primary.maxHzAtCurrentRes
    $displayInfo.runningBelowNative = $primary.runningBelowNative
    # An opportunity on ANY attached display counts: on a dual-monitor rig the 240 Hz gaming
    # panel is often the secondary one, and measuring only the primary measures the wrong screen.
    $displayInfo.refreshOpportunity = (@($found | Where-Object { $_.refreshOpportunity }).Count -gt 0)
    $displayInfo.maxHzAnyDisplay = (@($found | ForEach-Object { [int]$_.maxHzAtCurrentRes }) | Measure-Object -Maximum).Maximum
  }
} catch {
  $displayInfo.error = "$($_.Exception.Message)"
}
if (-not $displayInfo.determined) {
  # LAST resort: Win32_VideoController's cached mode, which this file has always documented as
  # frequently stale. It is recorded as a DIFFERENT source and does NOT set determined=$true —
  # nothing downstream may treat it as a measurement, least of all by writing an FPS cap from it.
  if ($gpus.Count -gt 0 -and [int]$gpus[0].curHz -gt 0) {
    $displayInfo.currentW = $gpus[0].curResW
    $displayInfo.currentH = $gpus[0].curResH
    $displayInfo.currentHz = $gpus[0].curHz
    $displayInfo.source = 'Win32_VideoController (cached, may be stale)'
  } else {
    $displayInfo.source = 'unavailable'
  }
}

# ---------- Current optimization state ----------
function Get-RegVal { param($Path, $Name) try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null } }

# ---------- Whose HKCU is this? ----------
# Same tri-state contract as engine.ps1's Get-FFIdentity, kept deliberately small here (this
# script cannot dot-source engine.ps1). $false = same account, $true = a different account,
# $null = could not determine. It NEVER defaults to $false.
function Get-FFUserScope {
  $tokenSid = $null; $tokenName = $null
  try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $tokenSid = "$($wi.User.Value)"; $tokenName = "$($wi.Name)"
  } catch {}
  $isAdmin = $false
  try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
  $pattern = '^S-1-[0-9\-]{1,60}$'
  $interactive = $null; $basis = $null; $probeErr = $null
  if ($OriginSid -and ("$OriginSid" -match $pattern)) { $interactive = "$OriginSid"; $basis = 'origin-sid' }
  if (-not $interactive) {
    # Structural rung: the owner of the shell process in our own session (UAC keeps the
    # elevated process in the interactive session, so this is the person at the keyboard).
    try {
      $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
      $sids = @()
      foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Where-Object { $_.SessionId -eq $sessionId })) {
        try {
          $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
          if ($o -and [int]$o.ReturnValue -eq 0 -and $o.Sid) { $sids += "$($o.Sid)" }
        } catch {}
      }
      $distinct = @($sids | Sort-Object -Unique)
      if ($distinct.Count -eq 1) { $interactive = $distinct[0]; $basis = 'shell-owner-sid' }
      elseif ($distinct.Count -gt 1) { $probeErr = 'More than one account owns a shell in this session.' }
      else { $probeErr = 'No shell process owner could be read in this session.' }
    } catch { $probeErr = "$($_.Exception.Message)" }
  }
  if (-not $interactive) {
    try {
      $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
      if ($u) {
        $s = (New-Object System.Security.Principal.NTAccount("$u")).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ("$s" -match $pattern) { $interactive = "$s"; $basis = 'console-username-translated' }
      }
    } catch { if (-not $probeErr) { $probeErr = "$($_.Exception.Message)" } }
  }
  $mismatch = $null; $note = $null
  if (-not $tokenSid) { $note = 'The Windows account this process runs as could not be read.' }
  elseif ($interactive) { $mismatch = -not ($interactive -eq $tokenSid) }
  elseif (-not $isAdmin) { $mismatch = $false; $basis = 'not-elevated'; $note = 'The interactive user could not be identified directly, but this process is not elevated, so it is running as whoever started it.' }
  else { $note = "This process is elevated and the interactive user could not be identified, so the per-user values below cannot be attributed to anyone. $probeErr" }
  [ordered]@{
    tokenSid = $tokenSid; tokenName = $tokenName; interactiveSid = $interactive
    basis = $basis; profileMismatch = $mismatch; note = $note
  }
}
$FFUserScope = Get-FFUserScope
# When the profile cannot be proven to be the signed-in user's, the HKCU reads below are
# suppressed rather than published: a value read from the wrong hive is not "this PC's
# state", and null already means "could not determine" everywhere in this document.
$FFPerUserReadable = ($FFUserScope.profileMismatch -eq $false)

# Power plan: the GUID is invariant, the NAME in powercfg output is localized in every language
# pack. Read the GUID from the registry and only use the printed name as a display label.
$ULTIMATE_GUID = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$SCHEMES_KEY   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$activeGuid = $null
try {
  $v = (Get-ItemProperty -LiteralPath $SCHEMES_KEY -Name 'ActivePowerScheme' -ErrorAction Stop).ActivePowerScheme
  if ("$v" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $activeGuid = $Matches[1].ToLower() }
} catch {}
$activeName = $null
try {
  $line = (powercfg /getactivescheme) -join ' '
  if ($line -match '\((.+)\)') { $activeName = $Matches[1] }   # display only, never compared
} catch {}
$ultimateExists = $null
try {
  $installed = @(Get-ChildItem -LiteralPath $SCHEMES_KEY -ErrorAction Stop | ForEach-Object { "$($_.PSChildName)".ToLower() })
  $ultimateExists = ($installed -contains $ULTIMATE_GUID)
} catch { $ultimateExists = $null }   # null = could not enumerate, NOT "absent"

$state = [ordered]@{
  powerPlanActive       = $activeName
  powerPlanActiveGuid   = $activeGuid
  ultimatePlanInstalled = $ultimateExists
  hags                  = (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode')        # 2 = on
  # HKCU: only reported when the profile is provably the signed-in user's (see $FFUserScope).
  gameModeAuto          = $(if ($FFPerUserReadable) { Get-RegVal 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' } else { $null })
  gameBarEnabled        = $(if ($FFPerUserReadable) { Get-RegVal 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' } else { $null })
  gameDVR               = (Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR')
  win32PrioritySep      = (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation')
  systemResponsiveness  = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness')
  networkThrottling     = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex')
  gamesGpuPriority      = (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority')
  visualFxSetting       = $(if ($FFPerUserReadable) { Get-RegVal 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' } else { $null })
  startupCount          = (Get-CimInstance Win32_StartupCommand | Measure-Object).Count
  # Which Windows profile the three HKCU fields above came from, and whether that profile is
  # the signed-in user's. perUserReadable=$false means those fields are null because they
  # could not be attributed, NOT because the settings are unset.
  perUserReadable       = $FFPerUserReadable
  perUserSource         = $FFUserScope
}

# ---------- Background processes (known game-irrelevant resource users) ----------
$bloatPatterns = 'OneDrive|Discord|Spotify|Slack|Teams|nordvpn|Adobe|GoogleDrive|Dropbox|EpicGames|EpicWeb|Razer|iCUE|SteelSeries|Logitech|GHUB|PulsarFusion|Cortana|YourPhone|PhoneExperience|Tailscale|java'
$procs = @()
foreach ($p in (Get-Process | Where-Object { $_.WorkingSet64 -gt 30MB -and $_.Name -match $bloatPatterns } | Sort-Object WorkingSet64 -Descending | Select-Object -First 20)) {
  $procs += [ordered]@{ name = $p.Name; ramMB = [math]::Round($p.WorkingSet64 / 1MB, 0); id = $p.Id }
}

# ---------- Active network adapter (wired vs Wi-Fi) ----------
# isWired comes from PhysicalMediaType / NdisPhysicalMedium (enumerated values), never from a
# regex over InterfaceDescription, which comes from a localized INF.
# linkSpeedMbps comes from the numeric Speed property (bits/sec, uint64), never from the
# display-formatted LinkSpeed string: '2,5 Gbps' on a comma-decimal locale parsed as digits-only
# becomes 25, i.e. 25000 Mbps — ten times reality.
function Test-AdapterWired {
  param($Adapter)
  $pmt = "$($Adapter.PhysicalMediaType)"
  if ($pmt) {
    if ($pmt -match '802\.11|Native 802\.11|Wireless') { return $false }
    if ($pmt -match '802\.3') { return $true }
  }
  $npm = $Adapter.NdisPhysicalMedium
  if ($null -ne $npm) {
    # NDIS_PHYSICAL_MEDIUM: 1 = WirelessLan, 8 = Native802_11, 9 = Bluetooth, 15 = WirelessWan(?)
    if (@(1, 8, 9) -contains [int]$npm) { return $false }
    if ([int]$npm -eq 14) { return $true }   # NdisPhysicalMedium802_3
  }
  return $null   # could not determine — never guessed from the adapter's display name
}
function Get-AdapterSpeedMbps {
  param($Adapter)
  try { if ($Adapter.Speed -and [uint64]$Adapter.Speed -gt 0) { return [math]::Round([double]$Adapter.Speed / 1000000) } } catch {}
  try {
    $w = Get-CimInstance Win32_NetworkAdapter -Filter "InterfaceIndex=$($Adapter.InterfaceIndex)" -ErrorAction Stop | Select-Object -First 1
    if ($w -and $w.Speed -and [uint64]$w.Speed -gt 0) { return [math]::Round([double]$w.Speed / 1000000) }
  } catch {}
  return $null   # null, not 0: 0 would read as "a measured zero-speed link"
}
$network = [ordered]@{ activeAdapter = $null; isWired = $null; linkSpeedMbps = $null; hasWiredAdapter = $null; physicalMediaType = $null }
try {
  $allAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
  $wiredSeen = @($allAdapters | Where-Object { (Test-AdapterWired $_) -eq $true })
  # $null only if we genuinely could not classify any adapter.
  if ($allAdapters.Count -gt 0) {
    $classified = @($allAdapters | Where-Object { $null -ne (Test-AdapterWired $_) })
    if ($wiredSeen.Count -gt 0) { $network.hasWiredAdapter = $true }
    elseif ($classified.Count -eq $allAdapters.Count) { $network.hasWiredAdapter = $false }
  }
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
  if ($route) {
    $ad = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    if ($ad) {
      $network.activeAdapter = $ad.InterfaceDescription
      $network.physicalMediaType = "$($ad.PhysicalMediaType)"
      $network.isWired = Test-AdapterWired $ad
      $network.linkSpeedMbps = Get-AdapterSpeedMbps $ad
      $network.linkSpeedRaw = "$($ad.LinkSpeed)"   # display string, for the UI only — never parsed
    }
  }
} catch { $network.error = "$($_.Exception.Message)" }

# ---------- Storage intelligence (Steam libraries -> physical disk) ----------
$storage = [ordered]@{
  steamFound = $false; libraries = @(); slowGameCount = 0
  hasFastDisk = $null; fastDiskName = $null; classified = $true
}
try {
  # Volume -> physical disk. Keyed on the volume, not on a drive LETTER: a library on a volume
  # mounted at a folder path has no letter and used to drop out of the analysis silently.
  function Resolve-DiskForPath {
    param([string]$Path)
    $out = [ordered]@{ model = $null; bus = $null; media = $null; speedClass = 'unknown' }
    $diskNumber = $null
    try {
      $part = Get-Partition -ErrorAction Stop | Where-Object {
        ($_.DriveLetter -and $Path -match ('^' + [regex]::Escape("$($_.DriveLetter):"))) -or
        (@($_.AccessPaths) | Where-Object { $_ -and $Path.ToLower().StartsWith($_.ToLower()) })
      } | Sort-Object { if ($_.AccessPaths) { -(@($_.AccessPaths) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum } else { 0 } } | Select-Object -First 1
      if ($part) { $diskNumber = $part.DiskNumber }
    } catch {}
    if ($null -eq $diskNumber) {
      try { $v = Get-Volume -FilePath $Path -ErrorAction Stop
            $p2 = Get-Partition -Volume $v -ErrorAction Stop | Select-Object -First 1
            if ($p2) { $diskNumber = $p2.DiskNumber } } catch {}
    }
    if ($null -eq $diskNumber) { return $out }
    try {
      $pd = Get-PhysicalDisk -DeviceNumber $diskNumber -ErrorAction Stop | Select-Object -First 1
      if ($pd) {
        $out.model = $pd.FriendlyName; $out.bus = "$($pd.BusType)"; $out.media = "$($pd.MediaType)"
        $out.speedClass = Get-DiskSpeedClass $pd.MediaType $pd.BusType
      }
    } catch {}
    return $out
  }

  $fast = @($disks | Where-Object { $_.speedClass -eq 'nvme' })
  $anyUnknownDisk = (@($disks | Where-Object { $_.speedClass -eq 'unknown' }).Count -gt 0)
  if ($disks.Count -gt 0) {
    if ($fast.Count -gt 0) { $storage.hasFastDisk = $true; $storage.fastDiskName = $fast[0].name }
    elseif (-not $anyUnknownDisk) { $storage.hasFastDisk = $false }
  }

  $steamPath = $null
  foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
    $v = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue)
    if ($v.SteamPath) { $steamPath = $v.SteamPath; break }
    if ($v.InstallPath) { $steamPath = $v.InstallPath; break }
  }
  if ($steamPath) {
    $storage.steamFound = $true
    $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    $paths = @()
    if (Test-Path -LiteralPath $vdf) {
      foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $vdf), '"path"\s*"([^"]+)"')) { $paths += ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    if (-not $paths) { $paths = @($steamPath) }
    foreach ($p in ($paths | Select-Object -Unique)) {
      $info = Resolve-DiskForPath $p
      $games = @(Get-ChildItem -LiteralPath (Join-Path $p 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue).Count
      # 'slow' only when the backing disk was positively identified as slower than NVMe.
      # unknown is neither slow nor fast, and it makes the whole storage answer unreliable.
      $slow = $false; $classified = $true
      switch ($info.speedClass) {
        'hdd'  { $slow = $true }
        'ssd'  { $slow = $true }
        'nvme' { $slow = $false }
        default { $classified = $false }
      }
      if (-not $classified) { $storage.classified = $false }
      if ($slow) { $storage.slowGameCount += $games }
      $drive = $null
      if ($p -match '^([A-Za-z]):') { $drive = $Matches[1] }
      $storage.libraries += [ordered]@{
        path = $p; drive = $drive
        disk = $info.model; bus = $info.bus; media = $info.media; speedClass = $info.speedClass
        games = $games; slow = $slow; classified = $classified
      }
    }
  }
} catch { $storage.error = "$($_.Exception.Message)"; $storage.classified = $false }

# ---------- Admin status ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$result = [ordered]@{
  generatedAt = (Get-Date).ToString('s')
  isAdmin     = $isAdmin
  isPortable  = $isPortable
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

Write-FFJson -InputObject $result -Depth 8
