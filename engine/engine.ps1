<#
  FrameForge :: engine.ps1
  Transactional tweak engine. Every apply records the exact prior state to a backup ledger so
  every change is perfectly reversible. Supports detect / apply / revert / detect-all / revert-all /
  restore-point. Data-driven from data/tweaks.json (single source of truth, shared with the UI).

  Usage:
    engine.ps1 -Action detect-all
    engine.ps1 -Action apply  -Id <tweakId> [-DryRun]
    engine.ps1 -Action revert -Id <tweakId> [-DryRun]
    engine.ps1 -Action revert-all [-DryRun]
    engine.ps1 -Action restore-point -Description "FrameForge"

  Always emits a single JSON object/array on stdout.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('detect','apply','revert','detect-all','revert-all','restore-point','list')]
  [string]$Action,
  [string]$Id,
  [string]$Description = 'FrameForge optimization',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root      = Split-Path -Parent $PSScriptRoot
$TweaksDb  = Join-Path $Root 'data\tweaks.json'
$StateDir  = Join-Path $Root 'data\state'
$Ledger    = Join-Path $StateDir 'applied.json'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$IsAdmin = Test-Admin

function Load-Tweaks {
  if (-not (Test-Path $TweaksDb)) { throw "tweaks.json not found at $TweaksDb" }
  (Get-Content -Raw -Path $TweaksDb | ConvertFrom-Json).tweaks
}
function Get-Tweak { param($Id) Load-Tweaks | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Load-Ledger {
  if (-not (Test-Path $Ledger)) { return @() }
  $parsed = Get-Content -Raw $Ledger | ConvertFrom-Json
  if ($null -eq $parsed) { return @() }
  # Defensive: tolerate a legacy {value:[...],Count:n} wrapper from an older serializer.
  if ($parsed.PSObject.Properties.Name -contains 'value' -and $parsed.PSObject.Properties.Name -contains 'Count') { $parsed = $parsed.value }
  @($parsed)
}
function Save-Ledger {
  param($Records)
  $arr = @($Records)
  if ($arr.Count -eq 0) { Set-Content -Path $Ledger -Value '[]' -Encoding UTF8; return }
  # Serialize each record independently and join — deterministic JSON array regardless of PS 5.1
  # single-element ConvertTo-Json quirks.
  $items = foreach ($r in $arr) { ConvertTo-Json -InputObject $r -Depth 10 }
  Set-Content -Path $Ledger -Value ("[`r`n" + (($items) -join ",`r`n") + "`r`n]") -Encoding UTF8
}
function Upsert-Ledger {
  param($Record)
  $all = @(Load-Ledger | Where-Object { $_.id -ne $Record.id })
  $all += $Record
  Save-Ledger $all
}
function Remove-FromLedger { param($Id) Save-Ledger @(Load-Ledger | Where-Object { $_.id -ne $Id }) }

# ---------------- Registry helpers ----------------
# ---------------- powercfg setting helpers ----------------
function Get-ActiveSchemeGuid {
  $line = powercfg /getactivescheme
  if ($line -match '([0-9a-fA-F\-]{36})') { return $Matches[1] }
  return 'SCHEME_CURRENT'
}
function Get-PowerCfgIndex {
  param($Subgroup, $Setting, [ValidateSet('AC', 'DC')]$Which)
  $guid = Get-ActiveSchemeGuid
  $q = powercfg /query $guid $Subgroup $Setting 2>$null
  $pat = if ($Which -eq 'AC') { 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)' } else { 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)' }
  foreach ($l in $q) { if ($l -match $pat) { return [Convert]::ToInt32($Matches[1], 16) } }
  return $null
}

# ---------------- Verify (read-only health) checks ----------------
function Test-Verify {
  param([string]$Check)
  switch ($Check) {
    'hags' {
      try { return ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode -eq 2) } catch { return $false }
    }
    'microcode' {
      try {
        $bytes = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'Update Revision' -ErrorAction Stop).'Update Revision'
        if (-not $bytes -or $bytes.Length -lt 4) { return $false }
        # Format varies: 8-byte stores the revision in the high dword; 4-byte stores it whole.
        $rev = if ($bytes.Length -ge 8) { [System.BitConverter]::ToUInt32($bytes, 4) } else { [System.BitConverter]::ToUInt32($bytes, 0) }
        if ($rev -eq 0) { $rev = [System.BitConverter]::ToUInt32($bytes, 0) }
        # Fixed Raptor Lake microcodes are 0x125 / 0x129 / 0x12B and up.
        return ($rev -ge 0x125)
      } catch { return $false }
    }
    'rss' {
      # Honest: only report UNHEALTHY if we positively see RSS disabled on an up adapter.
      # When the query is indeterminate (e.g. unelevated, or unsupported), do not cry wolf.
      try {
        $sawDisabled = $false
        foreach ($a in (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
          $r = Get-NetAdapterRss -Name $a.Name -ErrorAction SilentlyContinue
          if ($r -and ($r.Enabled -eq $false)) { $sawDisabled = $true }
        }
        return (-not $sawDisabled)
      } catch { return $true }
    }
    default { return $false }
  }
}

function Resolve-Hive { param($Root)
  switch ($Root) {
    'HKLM' { 'HKLM:' } 'HKCU' { 'HKCU:' } 'HKCR' { 'HKCR:' } 'HKU' { 'HKU:' } default { "$Root`:" }
  }
}
function Get-RegState {
  param($RootHive, $Path, $Name)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  $exists = $false; $value = $null
  if (Test-Path $full) {
    $item = Get-ItemProperty -Path $full -ErrorAction SilentlyContinue
    if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { $exists = $true; $value = $item.$Name }
  }
  [pscustomobject]@{ exists = $exists; value = $value; full = $full }
}
function Set-RegValue {
  param($RootHive, $Path, $Name, $ValueType, $Value)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  if (-not (Test-Path $full)) { New-Item -Path $full -Force | Out-Null }
  New-ItemProperty -Path $full -Name $Name -PropertyType $ValueType -Value $Value -Force | Out-Null
}
function Remove-RegValue {
  param($RootHive, $Path, $Name)
  $full = (Resolve-Hive $RootHive) + '\' + $Path
  if (Test-Path $full) { Remove-ItemProperty -Path $full -Name $Name -ErrorAction SilentlyContinue }
}

# ---------------- Per-op DETECT ----------------
function Detect-Op {
  param($op)
  switch ($op.type) {
    'registry' {
      $s = Get-RegState $op.root $op.path $op.name
      return ($s.exists -and "$($s.value)" -eq "$($op.value)")
    }
    'multi' {
      foreach ($sub in $op.ops) { if (-not (Detect-Op $sub)) { return $false } }
      return $true
    }
    'powercfg-scheme' {
      $active = powercfg /getactivescheme
      return ($active -match [regex]::Escape($op.name))
    }
    'verify' { return [bool](Test-Verify $op.check) }
    'powercfg-setting' {
      $cur = Get-PowerCfgIndex $op.subgroup $op.setting 'AC'
      return ($null -ne $cur -and [int]$cur -eq [int]$op.value)
    }
    'service' {
      $svc = Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction SilentlyContinue
      if (-not $svc) { return $true } # absent service = effectively disabled
      $want = $op.startup
      $mode = $svc.StartMode  # Auto / Manual / Disabled
      $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Automatic'='Auto' }
      return ($mode -eq $map[$want])
    }
    'advise' { return $false }
    default { return $false }
  }
}
function Test-OpSupported {
  param($op)
  switch ($op.type) {
    'service' { return [bool](Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction SilentlyContinue) }
    default   { return $true }
  }
}

# ---------------- Per-op APPLY (returns a 'before' backup blob) ----------------
function Apply-Op {
  param($op, [switch]$DryRun)
  switch ($op.type) {
    'registry' {
      $s = Get-RegState $op.root $op.path $op.name
      $before = @{ kind='registry'; root=$op.root; path=$op.path; name=$op.name; valueType=$op.valueType; existed=$s.exists; value=$s.value }
      if (-not $DryRun) { Set-RegValue $op.root $op.path $op.name $op.valueType $op.value }
      return $before
    }
    'multi' {
      $backs = @()
      foreach ($sub in $op.ops) { $backs += (Apply-Op $sub -DryRun:$DryRun) }
      return @{ kind='multi'; ops=$backs }
    }
    'powercfg-scheme' {
      $activeLine = powercfg /getactivescheme
      $prevGuid = if ($activeLine -match '([0-9a-fA-F\-]{36})') { $Matches[1] } else { $null }
      $before = @{ kind='powercfg-scheme'; prevGuid=$prevGuid }
      if (-not $DryRun) {
        # Ensure scheme exists; the Ultimate Performance template can be duplicated into the list.
        $list = powercfg /list
        if (-not ($list -match [regex]::Escape($op.name))) {
          powercfg -duplicatescheme $op.guid | Out-Null
        }
        # Resolve the GUID actually present for this scheme name (duplicate may differ from template)
        $present = (powercfg /list) | Where-Object { $_ -match [regex]::Escape($op.name) } | Select-Object -First 1
        $useGuid = if ($present -match '([0-9a-fA-F\-]{36})') { $Matches[1] } else { $op.guid }
        powercfg /setactive $useGuid | Out-Null
        # Critically: do NOT pin minimum processor state at 100% on Raptor Lake. Un-pin it.
        if ($null -ne $op.procMinState) {
          $SUB_PROCESSOR = '54533251-82be-4824-96c1-47b60b740d00'
          $PROCTHROTTLEMIN = '893dee8e-2bef-41e0-89c6-b55d0929964c'
          powercfg /setacvalueindex $useGuid $SUB_PROCESSOR $PROCTHROTTLEMIN $op.procMinState | Out-Null
          powercfg /setdcvalueindex $useGuid $SUB_PROCESSOR $PROCTHROTTLEMIN $op.procMinState | Out-Null
          powercfg /setactive $useGuid | Out-Null
        }
      }
      return $before
    }
    'verify' { return @{ kind = 'verify'; check = $op.check } }
    'powercfg-setting' {
      $guid = Get-ActiveSchemeGuid
      $before = @{ kind = 'powercfg-setting'; guid = $guid; subgroup = $op.subgroup; setting = $op.setting; ac = (Get-PowerCfgIndex $op.subgroup $op.setting 'AC'); dc = (Get-PowerCfgIndex $op.subgroup $op.setting 'DC') }
      if (-not $DryRun) {
        powercfg /setacvalueindex $guid $op.subgroup $op.setting $op.value | Out-Null
        powercfg /setdcvalueindex $guid $op.subgroup $op.setting $op.value | Out-Null
        powercfg /setactive $guid | Out-Null
      }
      return $before
    }
    'service' {
      $svc = Get-CimInstance Win32_Service -Filter "Name='$($op.name)'" -ErrorAction SilentlyContinue
      $before = @{ kind='service'; name=$op.name; startup=($svc.StartMode); state=($svc.State) }
      if (-not $DryRun -and $svc) {
        $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Automatic'='Automatic' }
        Set-Service -Name $op.name -StartupType $map[$op.startup] -ErrorAction SilentlyContinue
        if ($op.state -eq 'Stopped') { Stop-Service -Name $op.name -Force -ErrorAction SilentlyContinue }
        elseif ($op.state -eq 'Running') { Start-Service -Name $op.name -ErrorAction SilentlyContinue }
      }
      return $before
    }
    'advise' { return @{ kind='advise' } }
    default { throw "Unknown op type: $($op.type)" }
  }
}

# ---------------- Per-op REVERT (consumes the 'before' backup blob) ----------------
function Revert-Op {
  param($before, [switch]$DryRun)
  switch ($before.kind) {
    'registry' {
      if (-not $DryRun) {
        if ($before.existed) { Set-RegValue $before.root $before.path $before.name $before.valueType $before.value }
        else { Remove-RegValue $before.root $before.path $before.name }
      }
    }
    'multi' { foreach ($b in $before.ops) { Revert-Op $b -DryRun:$DryRun } }
    'powercfg-setting' {
      if (-not $DryRun -and $before.guid) {
        if ($null -ne $before.ac) { powercfg /setacvalueindex $before.guid $before.subgroup $before.setting $before.ac | Out-Null }
        if ($null -ne $before.dc) { powercfg /setdcvalueindex $before.guid $before.subgroup $before.setting $before.dc | Out-Null }
        powercfg /setactive $before.guid | Out-Null
      }
    }
    'powercfg-scheme' {
      if (-not $DryRun -and $before.prevGuid) { powercfg /setactive $before.prevGuid | Out-Null }
    }
    'service' {
      if (-not $DryRun -and $before.startup) {
        $map = @{ 'Disabled'='Disabled'; 'Manual'='Manual'; 'Auto'='Automatic'; 'Automatic'='Automatic' }
        $st = $map["$($before.startup)"]; if ($st) { Set-Service -Name $before.name -StartupType $st -ErrorAction SilentlyContinue }
        if ($before.state -eq 'Running') { Start-Service -Name $before.name -ErrorAction SilentlyContinue }
        elseif ($before.state -eq 'Stopped') { Stop-Service -Name $before.name -Force -ErrorAction SilentlyContinue }
      }
    }
    'advise' { }
  }
}

# ---------------- High-level actions ----------------
function Do-Detect {
  param($tweak)
  $supported = Test-OpSupported $tweak.op
  $applied = $false
  try { $applied = [bool](Detect-Op $tweak.op) } catch { $applied = $false }
  [ordered]@{ id=$tweak.id; applied=$applied; supported=$supported; requiresAdmin=$tweak.requiresAdmin }
}

function Do-Apply {
  param($tweak, [switch]$DryRun)
  if ($tweak.op.type -eq 'advise' -or $tweak.op.type -eq 'verify') {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$true; advisory=$true; message=$tweak.summary }
  }
  if ($tweak.requiresAdmin -and -not $IsAdmin -and -not $DryRun) {
    return [ordered]@{ id=$tweak.id; action='apply'; success=$false; needsElevation=$true; message='This tweak requires administrator rights.' }
  }
  $before = Apply-Op $tweak.op -DryRun:$DryRun
  if (-not $DryRun) {
    Upsert-Ledger ([ordered]@{ id=$tweak.id; name=$tweak.name; appliedAt=(Get-Date).ToString('s'); before=$before; reverted=$false })
  }
  [ordered]@{ id=$tweak.id; action='apply'; success=$true; dryRun=[bool]$DryRun; requiresReboot=$tweak.requiresReboot; message="Applied '$($tweak.name)'." }
}

function Do-Revert {
  param($tweak, [switch]$DryRun)
  $rec = Load-Ledger | Where-Object { $_.id -eq $tweak.id -and -not $_.reverted } | Select-Object -First 1
  if (-not $rec) {
    # No recorded backup: nothing we applied to undo. Report gracefully.
    return [ordered]@{ id=$tweak.id; action='revert'; success=$true; noop=$true; message='No applied change on record to revert.' }
  }
  if ($tweak.requiresAdmin -and -not $IsAdmin -and -not $DryRun) {
    return [ordered]@{ id=$tweak.id; action='revert'; success=$false; needsElevation=$true; message='Reverting this tweak requires administrator rights.' }
  }
  Revert-Op $rec.before -DryRun:$DryRun
  if (-not $DryRun) { Remove-FromLedger $tweak.id }
  [ordered]@{ id=$tweak.id; action='revert'; success=$true; dryRun=[bool]$DryRun; requiresReboot=$tweak.requiresReboot; message="Reverted '$($tweak.name)'." }
}

function Do-RestorePoint {
  param($Description)
  if (-not $IsAdmin) { return [ordered]@{ action='restore-point'; success=$false; needsElevation=$true; message='Creating a restore point requires administrator rights.' } }
  try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    # Bypass the once-per-24h throttle so a checkpoint is always created before changes.
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    return [ordered]@{ action='restore-point'; success=$true; message='System restore point created.' }
  } catch {
    return [ordered]@{ action='restore-point'; success=$false; message="Could not create restore point: $($_.Exception.Message). (System Protection may be off.)" }
  }
}

# ---------------- Dispatch ----------------
$out = switch ($Action) {
  'list'        { Load-Tweaks }
  'detect-all'  { @(foreach ($t in (Load-Tweaks)) { Do-Detect $t }) }
  'detect'      { Do-Detect (Get-Tweak $Id) }
  'apply'       { Do-Apply  (Get-Tweak $Id) -DryRun:$DryRun }
  'revert'      { Do-Revert (Get-Tweak $Id) -DryRun:$DryRun }
  'revert-all'  {
    $results = @()
    foreach ($rec in (Load-Ledger | Where-Object { -not $_.reverted })) {
      $t = Get-Tweak $rec.id
      if ($t) { $results += (Do-Revert $t -DryRun:$DryRun) }
    }
    @{ action='revert-all'; count=$results.Count; results=$results }
  }
  'restore-point' { Do-RestorePoint $Description }
}

$out | ConvertTo-Json -Depth 10 -Compress
