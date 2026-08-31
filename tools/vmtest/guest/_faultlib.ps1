<#
  FrameForge VM test harness :: guest\_faultlib.ps1
  Shared helpers for the fault-injection scripts that run INSIDE a test VM.

  THIS FILE DELIBERATELY SHARES NO CODE WITH engine\_lib.ps1.
  ==========================================================
  The fault scripts are the ORACLE. They are what tells the harness "the subsystem really is
  broken now", and the whole matrix hinges on that claim being independent of the code under
  test. If this library dot-sourced engine\_lib.ps1, a locale bug in the engine would be
  reproduced identically in the oracle, the two would agree, and the matrix would report a
  confident green while both halves were wrong. So the duplication below (an admin test, a JSON
  writer) is not an oversight - it is the isolation.

  GROUND TRUTH IS STRUCTURAL, NEVER TEXT.
  Every signal these scripts read is an exit code, a registry DWORD, a file length, a structured
  object property, or a count of files this script itself created. None of them is a phrase
  printed by a Win32 tool. That is the same discipline the engine is supposed to follow, held
  here as an invariant so the oracle stays valid on de-DE and ja-JP.

  CONTRACT every fault script implements:
     <fault>.ps1 -Action inject|revert|probe|describe [-Preset <name>] [-StateRoot <dir>] [...]
  Exactly ONE JSON document on stdout, every time, including on failure. Fields:
     ok          the script itself ran without throwing
     fault       fault id
     action      what was asked for
     injected    $true / $false / $null   ($null = COULD NOT DETERMINE - a first-class result)
     revertible  whether revert can restore the captured prior state at all
     groundTruth { faulted; signals[] }   the oracle's verdict and the raw readings behind it
     capture     the prior state, written to disk at inject time and read back at revert time
     message     one honest sentence
     evidence    anything the host should keep

  'injected' and 'groundTruth.faulted' may be $null. The orchestrator treats $null as
  "the oracle could not measure this" and records fault-injection-failed - it never guesses.
  PowerShell 5.1 compatible.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Registry service start values. Numeric on every language; the human names are for the report.
$script:StartNames = @{ 0 = 'boot'; 1 = 'system'; 2 = 'auto'; 3 = 'manual'; 4 = 'disabled' }

function Write-FaultJson {
  <# One JSON document, BOM-free, on stdout. -InputObject (not the pipeline) so a single-element
     array is not unrolled into a bare object - the classic PS 5.1 ConvertTo-Json pitfall. #>
  param([Parameter(Mandatory)]$InputObject, [int]$Depth = 10)
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress))
}

function Test-FaultAdmin {
  <# Same SID-literal rationale the engine uses: S-1-5-32-544 is identical on every locale,
     the group NAME is not. Duplicated here on purpose (see the header). #>
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {}
  try {
    $g = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
    if ((($g | ForEach-Object { "$_" }) -join "`n") -match 'S-1-5-32-544') { return $true }
  } catch {}
  return $false
}

function New-FaultDoc {
  <# The single result shape. Everything defaults to the honest "not measured" value. #>
  param(
    [Parameter(Mandatory)][string]$Fault,
    [Parameter(Mandatory)][string]$Action,
    [bool]$Ok = $true,
    $Injected = $null,
    [bool]$Revertible = $true,
    $GroundTruth = $null,
    $Capture = $null,
    [string]$Message = '',
    $Evidence = @()
  )
  [ordered]@{
    ok          = $Ok
    fault       = $Fault
    action      = $Action
    ranAt       = (Get-Date).ToString('s')
    isAdmin     = (Test-FaultAdmin)
    computer    = "$env:COMPUTERNAME"
    injected    = $Injected
    revertible  = $Revertible
    groundTruth = $GroundTruth
    capture     = $Capture
    message     = $Message
    evidence    = @($Evidence)
  }
}

function New-GroundTruth {
  <# faulted: $true broken, $false healthy, $null COULD NOT DETERMINE. Never default to $false:
     "I could not read the signal" and "the signal says healthy" are different answers and the
     orchestrator acts on them differently. #>
  param($Faulted, $Signals = @(), [string]$Detail = '')
  [ordered]@{ faulted = $Faulted; detail = $Detail; signals = @($Signals) }
}

# ---------------- state capture / restore (doctrine rule 3: restore CAPTURED state) ----------------

function Get-FaultStatePath {
  <# PATH ONLY - this function creates nothing. It used to `New-Item` the state directory, which
     meant that `-Action probe`, documented as read-only, silently created C:\ffvmtest\state on
     whatever machine it ran on. A read-only action that writes is exactly the kind of quiet lie
     this whole harness exists to catch, so directory creation now lives in Save-FaultState, the
     only function that actually writes. #>
  param([Parameter(Mandatory)][string]$Fault, [string]$StateRoot = 'C:\ffvmtest\state')
  Join-Path $StateRoot ("$Fault.json")
}

function Save-FaultState {
  param([Parameter(Mandatory)][string]$Fault, [Parameter(Mandatory)]$State, [string]$StateRoot = 'C:\ffvmtest\state')
  if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null }
  $p = Get-FaultStatePath -Fault $Fault -StateRoot $StateRoot
  # -Encoding UTF8 writes a BOM on PS 5.1; this file is only ever read back by ConvertFrom-Json
  # in this same process family, and Get-Content -Raw handles the BOM. Keeping it simple beats
  # a clever writer here.
  ConvertTo-Json -InputObject $State -Depth 10 | Set-Content -LiteralPath $p -Encoding UTF8
  $p
}

function Read-FaultState {
  param([Parameter(Mandatory)][string]$Fault, [string]$StateRoot = 'C:\ffvmtest\state')
  $p = Get-FaultStatePath -Fault $Fault -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $p | ConvertFrom-Json) } catch { return $null }
}

# ---------------- services (registry Start value, not Set-Service) ----------------

function Get-ServiceStartRows {
  <#
    Reads the START TYPE from HKLM\SYSTEM\CurrentControlSet\Services\<name>\Start rather than
    from Get-Service.StartType. Two reasons:
      1. Several of the services these faults touch (AppXSvc, ClipSVC, StateRepository) reject
         Set-Service and Get-Service.StartType writes/reads through the SCM security descriptor,
         which denies even an elevated admin. The registry value is readable and writable.
      2. It is a DWORD. Get-Service's StartType is an enum whose ToString() is English, and rows
         from it end up in reports as text.
    present:$false means the service key does not exist - which is NOT the same as disabled, and
    is reported as its own state so a deleted service is never graded as healthy.
  #>
  param([Parameter(Mandatory)][string[]]$Names)
  $rows = @()
  foreach ($n in $Names) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$n"
    $row = [ordered]@{ name = $n; present = $false; start = $null; startName = $null; delayedAutostart = $null; status = $null }
    if (Test-Path -LiteralPath $key) {
      $row.present = $true
      try {
        $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if ($null -ne $p.Start) { $row.start = [int]$p.Start; $row.startName = $script:StartNames[[int]$p.Start] }
        if ($null -ne $p.DelayedAutostart) { $row.delayedAutostart = [int]$p.DelayedAutostart }
      } catch {}
      try { $row.status = "$((Get-Service -Name $n -ErrorAction Stop).Status)" } catch { $row.status = $null }
    }
    $rows += $row
  }
  ,$rows
}

function Set-ServiceStartValue {
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Start)
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
  if (-not (Test-Path -LiteralPath $key)) { return $false }
  Set-ItemProperty -LiteralPath $key -Name 'Start' -Value $Start -Type DWord -ErrorAction Stop
  $true
}

function Restore-ServiceStartRows {
  <# Puts each service back to the EXACT captured Start value - including back to 'disabled' if
     that is what was captured. Never assumes a default. #>
  param([Parameter(Mandatory)]$Rows)
  $actions = @()
  foreach ($r in @($Rows)) {
    $name = "$($r.name)"
    if (-not $r.present) { $actions += "$name was ABSENT before injection; nothing restored (a missing service key is not something this harness recreates)."; continue }
    if ($null -eq $r.start) { $actions += "$name had no readable Start value at capture time; NOT restored (guessing one would be inventing prior state)."; continue }
    try {
      $null = Set-ServiceStartValue -Name $name -Start ([int]$r.start)
      $actions += "$name Start restored to $($r.start) ($($script:StartNames[[int]$r.start]))."
    } catch { $actions += "$name Start could NOT be restored: $($_.Exception.Message)" }
    # Running state: only start it back up if it was running when captured.
    if ("$($r.status)" -eq 'Running') {
      try { Start-Service -Name $name -ErrorAction Stop; $actions += "$name started (it was Running at capture time)." }
      catch { $actions += "$name could not be started again: $($_.Exception.Message)" }
    }
  }
  ,$actions
}

function Stop-ServiceHard {
  <# Stop with dependents; a service that will not stop is reported, never ignored. #>
  param([Parameter(Mandatory)][string]$Name)
  try {
    $s = Get-Service -Name $Name -ErrorAction Stop
    if ($s.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction Stop }
    return "$Name stopped."
  } catch { return "$Name could not be stopped: $($_.Exception.Message)" }
}

# ---------------- registry values ----------------

function Get-RegValueSnapshot {
  <# present:$false = the value is absent. present:$null = the KEY could not be read at all,
     which is a measurement failure and must not be restored as "absent". #>
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
  $snap = [ordered]@{ path = $Path; name = $Name; present = $null; value = $null; kind = $null }
  try {
    if (-not (Test-Path -LiteralPath $Path)) { $snap.present = $false; $snap.keyMissing = $true; return $snap }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $names = @($item.GetValueNames())
    if ($names -notcontains $Name) { $snap.present = $false; return $snap }
    $snap.present = $true
    $snap.value   = $item.GetValue($Name)
    $snap.kind    = "$($item.GetValueKind($Name))"
  } catch { $snap.present = $null; $snap.error = "$($_.Exception.Message)" }
  $snap
}

function Restore-RegValueSnapshot {
  param([Parameter(Mandatory)]$Snapshot)
  $p = "$($Snapshot.path)"; $n = "$($Snapshot.name)"
  if ($null -eq $Snapshot.present) { return "$p\$n : prior state was never readable, so nothing was restored (restoring an assumed default is exactly what doctrine rule 3 forbids)." }
  try {
    if ($Snapshot.present -eq $false) {
      if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue }
      return "$p\$n : removed (it did not exist before injection)."
    }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    $kind = "$($Snapshot.kind)"; if (-not $kind) { $kind = 'String' }
    Set-ItemProperty -LiteralPath $p -Name $n -Value $Snapshot.value -Type $kind -ErrorAction Stop
    return "$p\$n : restored to the captured value."
  } catch { return "$p\$n : could NOT be restored - $($_.Exception.Message)" }
}

function Remove-RegKeyIfCreated {
  param([Parameter(Mandatory)][string]$Path, [bool]$WasPresent)
  if ($WasPresent) { return "$Path : left in place (it existed before injection)." }
  try { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }; return "$Path : removed (this script created it)." }
  catch { return "$Path : could not be removed - $($_.Exception.Message)" }
}

# ---------------- native processes ----------------

function Invoke-NativeCapture {
  <#
    Runs a native tool and returns its EXIT CODE plus its output. The output is captured for the
    evidence file ONLY - no fault script may branch on it. Every decision in this harness is made
    on the exit code or on a structural read, because the text is localized.
  #>
  param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
  $out = ''
  $code = $null
  try {
    $raw = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    $out = ((@($raw) | ForEach-Object { "$_" }) -join "`n")
  } catch {
    $out = "$($_.Exception.Message)"
  }
  [ordered]@{ file = $FilePath; args = @($Arguments); exitCode = $code; output = $out
              outputNote = 'Captured as evidence only. No verdict in this harness is reached from this text.' }
}

# ---------------- files ----------------

function New-JunkFile {
  <# Real bytes, deterministic content, recorded so revert deletes exactly what it created. #>
  param([Parameter(Mandatory)][string]$Path, [int]$Bytes = 65536)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $buf = New-Object byte[] $Bytes
  (New-Object Random 1337).NextBytes($buf)
  [System.IO.File]::WriteAllBytes($Path, $buf)
  $Path
}

function Remove-ManifestFiles {
  <# Deletes ONLY the paths in the manifest this fault wrote. Never a wildcard sweep of a temp
     folder - that would delete things the harness did not create and could not restore. #>
  param($Paths)
  $actions = @()
  foreach ($p in @($Paths)) {
    try {
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop; $actions += "deleted $p" }
      else { $actions += "already gone: $p" }
    } catch { $actions += "could NOT delete $p - $($_.Exception.Message)" }
  }
  ,$actions
}

function Get-VolumeFreeBytes {
  param([string]$DriveLetter = 'C')
  try { return [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($DriveLetter):'" -ErrorAction Stop).FreeSpace } catch { return $null }
}
