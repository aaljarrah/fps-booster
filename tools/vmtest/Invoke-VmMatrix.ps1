<#
  FrameForge VM test harness :: Invoke-VmMatrix.ps1
  Runs the cell x repair matrix and emits a machine-readable results matrix plus a readable
  summary.

  WHY EVERYTHING GOES THROUGH POWERSHELL DIRECT
  =============================================
  Every command this script sends to a guest travels over the VMBus with Invoke-Command -VMName /
  New-PSSession -VMName, and files travel with Copy-Item -ToSession over that same session. There
  is no WinRM, no SSH, no SMB share and, on most cells, no virtual network adapter at all. That is
  not a preference, it is a requirement of what is being tested:

    * winsock-reset runs `netsh winsock reset` and `netsh int ip reset`. It tears down the winsock
      catalog and rebuilds the IP stack. Any network-based control channel dies in the middle of
      the command whose result the harness is trying to measure - and a harness that loses the
      connection at exactly that moment cannot tell "the repair worked" from "the repair killed
      networking permanently", which is the single most important thing to know about it.
    * network-flush and dns-change-resolver rewrite the resolver configuration the control channel
      would depend on to find the guest.
    * The cells have no adapter at all by default, precisely so a VM cannot quietly download
      updates between the checkpoint and the assertion. PowerShell Direct does not need one.

  PowerShell Direct requires: a Windows 10+/Server 2016+ host and guest, the guest running on THIS
  host, an elevated host session, and local administrator credentials for the guest. It does not
  require any guest networking.

  Copy-VMFile is the documented alternative for pushing files in (it needs the Guest Service
  Interface integration service, which New-TestVm.ps1 enables). This script uses Copy-Item
  -ToSession instead because it copies whole trees over the session that is already open; the
  fallback matters only when the guest's PowerShell is too broken to host a session.

  THE ASSERTION THAT MATTERS
  ==========================
  For every row: restore the clean checkpoint, prove the category is healthy, BREAK it, prove with
  an independent oracle that it is broken, and only then ask FrameForge's own read-only probe what
  it sees. If FrameForge says "ok" over a fault the harness knows it injected, the row fails with
  code 'false-pass'. That is how a localized-Windows text-parse bug is caught mechanically instead
  of by inspection. A probe that says "unknown" also fails, with code 'detect-unknown' - honest,
  but a hole in the measurement.

  Output: <OutRoot>\<runId>\results.json, summary.md, locale-divergence.json, and per-row evidence
  directories holding every JSON document either side produced. One JSON document on stdout.
  PowerShell 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [string]$MatrixPath,
  [string[]]$Cells,
  [string[]]$Repairs,
  [string]$RepairSet,
  [string]$OutRoot,
  [securestring]$AdminPassword,
  [string]$SwitchName,
  [string]$RepoRoot,
  [int]$RestoreTimeoutMinutes = 10,
  [int]$RebootTimeoutMinutes = 25,
  [int]$StepTimeoutMinutes = 45,
  [switch]$SkipUndo,
  [switch]$Plan,
  [switch]$StopOnFalsePass
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $MatrixPath) { $MatrixPath = Join-Path $PSScriptRoot 'matrix.json' }
if (-not $RepoRoot)   { $RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

$script:Log = @()
function Add-Log { param([string]$Text) $line = "$((Get-Date).ToString('HH:mm:ss')) $Text"; $script:Log += $line; Write-Verbose $line }

# =====================================================================================
# matrix / catalog
# =====================================================================================

function Get-Json {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
  Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
}

function Get-PlanFor {
  param($Matrix, [string]$RepairId)
  @($Matrix.repairPlan) | Where-Object { $_.repair -eq $RepairId } | Select-Object -First 1
}

function Get-CatalogFor {
  param($Catalog, [string]$RepairId)
  @($Catalog.repairs) | Where-Object { $_.id -eq $RepairId } | Select-Object -First 1
}

function Resolve-RepairList {
  param($Matrix, $Catalog, $CellDef)
  $all = @($Catalog.repairs | ForEach-Object { "$($_.id)" })
  $setName = $RepairSet
  if (-not $setName) { $setName = "$($CellDef.repairSet)" }
  if (-not $setName) { $setName = 'full' }
  $set = $null
  try { $set = $Matrix.repairSets.$setName } catch {}
  $list = $all
  if ($set -and "$set" -ne 'all') { $list = @($set) }
  if ($Repairs) { $list = @($list | Where-Object { $Repairs -contains $_ }) }
  # Keep catalog order so a run reads the same way every time.
  @($all | Where-Object { $list -contains $_ })
}

# =====================================================================================
# evidence
# =====================================================================================

function New-EvidenceDir {
  param([string]$Root, [string]$Cell, [string]$Repair)
  $d = Join-Path (Join-Path $Root $Cell) $Repair
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $d
}

function Save-Evidence {
  <# Writes one evidence document. A failure here is FATAL to the row: a result nobody can read
     later is not a result. The caller turns a throw into outcome fail / code evidence-lost. #>
  param([string]$Dir, [string]$Name, $Object, [string]$RawText)
  $p = Join-Path $Dir $Name
  if ($null -ne $Object) {
    ConvertTo-Json -InputObject $Object -Depth 20 | Set-Content -LiteralPath $p -Encoding UTF8 -ErrorAction Stop
  } else {
    Set-Content -LiteralPath $p -Value "$RawText" -Encoding UTF8 -ErrorAction Stop
  }
  $p
}

function New-Assertion {
  param([string]$Name, [string]$Expected, [string]$Actual, [bool]$Ok, [string]$Detail = '')
  [ordered]@{ name = $Name; expected = $Expected; actual = $Actual; ok = $Ok; detail = $Detail }
}

# =====================================================================================
# guest plumbing (PowerShell Direct only)
# =====================================================================================

function New-GuestCredential {
  param($CellDef, $Defaults, [securestring]$Secure)
  New-Object System.Management.Automation.PSCredential("$($CellDef.computerName)\$($Defaults.adminUser)", $Secure)
}

function Wait-GuestSession {
  <# Returns an open PSSession or $null. Never fabricates one. #>
  param([string]$VmName, [pscredential]$Credential, [int]$TimeoutMinutes, [string]$What)
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  while ((Get-Date) -lt $deadline) {
    try {
      $s = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
      Add-Log "PowerShell Direct session open on '$VmName' [$What]."
      return $s
    } catch { Start-Sleep -Seconds 10 }
  }
  Add-Log "PowerShell Direct did NOT come back on '$VmName' within $TimeoutMinutes minute(s) [$What]."
  $null
}

function Invoke-GuestJson {
  <#
    Runs a script in the guest and extracts EXACTLY ONE JSON document from its stdout.
    Strategy, in order: parse the whole output; else parse the last non-empty line. Anything else
    is reported as parsed:$false WITH the raw text kept - the caller then fails the row with
    'engine-error' rather than treating unparseable output as any kind of verdict.

    The call runs as a JOB against the session so it can be BOUNDED. sfc /scannow, DISM
    /RestoreHealth and a boot-time chkdsk are all capable of hanging; without a timeout one stuck
    guest stalls the entire matrix and the run ends with no results at all. A timeout returns
    timedOut:$true and no verdict - never a guess about what the command would have said.
  #>
  param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$File, [string[]]$Arguments = @(), [int]$TimeoutMinutes = 45)
  $job = Invoke-Command -Session $Session -AsJob -ScriptBlock {
    param($f, $a)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f @a 2>&1
    [ordered]@{ text = ((@($out) | ForEach-Object { "$_" }) -join "`n"); exit = $LASTEXITCODE }
  } -ArgumentList $File, $Arguments -ErrorAction Stop

  $done = Wait-Job -Job $job -Timeout ($TimeoutMinutes * 60)
  if ($null -eq $done) {
    try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    Add-Log "TIMEOUT after $TimeoutMinutes minute(s): $File $($Arguments -join ' ')"
    return [ordered]@{ file = $File; arguments = @($Arguments); exitCode = $null; parsed = $false; json = $null
                       raw = "The guest command did not return within $TimeoutMinutes minute(s) and was stopped. No result was produced, so no verdict is recorded."
                       timedOut = $true }
  }
  $r = $null
  try { $r = Receive-Job -Job $job -ErrorAction Stop } catch { $r = [ordered]@{ text = "$($_.Exception.Message)"; exit = $null } }
  try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}

  $text = "$($r.text)"
  $json = $null
  try { $json = $text | ConvertFrom-Json } catch {}
  if ($null -eq $json) {
    $lines = @($text -split "`n" | Where-Object { "$_".Trim() -match '\S' })
    if ($lines.Count -gt 0) { try { $json = $lines[-1] | ConvertFrom-Json } catch {} }
  }
  [ordered]@{ file = $File; arguments = @($Arguments); exitCode = $r.exit; parsed = ($null -ne $json); json = $json; raw = $text; timedOut = $false }
}

function Copy-PayloadToGuest {
  <#
    Copies the engine under test and the harness's guest scripts in, over the SAME PowerShell
    Direct session everything else uses.
    The layout is load-bearing: repair.ps1 computes its catalog paths as <parent of engine>\data,
    so engine\ and data\ must sit side by side under C:\ffvmtest\ff.
    This runs after EVERY checkpoint restore, because the restore also reverts the copy. It costs
    a few seconds and it guarantees each row runs the engine bits that are on disk right now.
  #>
  param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$RepoRoot, [string]$PayloadRoot, [string]$GuestRoot)
  Invoke-Command -Session $Session -ScriptBlock {
    param($p, $g)
    foreach ($d in @($g, $p, (Join-Path $g 'guest'), (Join-Path $g 'state'), (Join-Path $g 'out'))) {
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    foreach ($d in @((Join-Path $p 'engine'), (Join-Path $p 'data'))) {
      if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
  } -ArgumentList $PayloadRoot, $GuestRoot -ErrorAction Stop

  Copy-Item -Path (Join-Path $RepoRoot 'engine') -Destination $PayloadRoot -ToSession $Session -Recurse -Force -ErrorAction Stop
  Copy-Item -Path (Join-Path $RepoRoot 'data')   -Destination $PayloadRoot -ToSession $Session -Recurse -Force -ErrorAction Stop
  Copy-Item -Path (Join-Path $PSScriptRoot 'guest\*') -Destination (Join-Path $GuestRoot 'guest') -ToSession $Session -Recurse -Force -ErrorAction Stop
}

function Restart-GuestAndWait {
  <#
    Reboots from INSIDE the guest (shutdown /r) rather than Restart-VM, so Windows completes its
    servicing/boot-time work - the chkdsk-full-repair row depends on autochk actually running
    during that boot, and a hard reset would skip it.
  #>
  param([string]$VmName, [pscredential]$Credential, [System.Management.Automation.Runspaces.PSSession]$Session, [int]$TimeoutMinutes)
  try {
    Invoke-Command -Session $Session -ScriptBlock { & shutdown.exe /r /t 0 /f } -ErrorAction SilentlyContinue
  } catch {}
  try { Remove-PSSession $Session -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Seconds 20
  Wait-GuestSession -VmName $VmName -Credential $Credential -TimeoutMinutes $TimeoutMinutes -What 'post-repair reboot'
}

function Restore-CleanCheckpoint {
  param([string]$VmName, [string]$CheckpointName, [pscredential]$Credential, [int]$TimeoutMinutes)
  $cp = Get-VMCheckpoint -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
  if ($null -eq $cp) { return $null }
  Restore-VMCheckpoint -VMName $VmName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
  $vm = Get-VM -Name $VmName
  if ($vm.State -ne 'Running') { Start-VM -Name $VmName -ErrorAction Stop }
  Wait-GuestSession -VmName $VmName -Credential $Credential -TimeoutMinutes $TimeoutMinutes -What "restored checkpoint '$CheckpointName'"
}

function Set-RowNetwork {
  param([string]$VmName, [bool]$Wanted, [string]$Switch)
  if ($Wanted) {
    if (-not $Switch) { return [ordered]@{ connected = $false; reason = 'no-switch-configured' } }
    $ad = @(Get-VMNetworkAdapter -VMName $VmName)
    if ($ad.Count -eq 0) { Add-VMNetworkAdapter -VMName $VmName -SwitchName $Switch -ErrorAction Stop }
    else { Connect-VMNetworkAdapter -VMName $VmName -SwitchName $Switch -ErrorAction Stop }
    return [ordered]@{ connected = $true; switch = $Switch }
  }
  foreach ($a in @(Get-VMNetworkAdapter -VMName $VmName)) { Remove-VMNetworkAdapter -VMNetworkAdapter $a -ErrorAction SilentlyContinue }
  [ordered]@{ connected = $false; reason = 'not-required-by-this-row' }
}

function Add-SourceMedia {
  <# Attaches the cell's install ISO so the offline rows (dism-restorehealth, enable-netfx3) have
     a -SourcePath. The cells have no network, so DISM cannot fall back to Windows Update - which
     is realistic for the machines these repairs are aimed at. #>
  param([string]$VmName, [string]$IsoPath)
  if (-not (Test-Path -LiteralPath $IsoPath)) { return [ordered]@{ attached = $false; reason = "iso-not-found: $IsoPath" } }
  $existing = @(Get-VMDvdDrive -VMName $VmName | Where-Object { "$($_.Path)" -eq $IsoPath })
  if ($existing.Count -eq 0) { Add-VMDvdDrive -VMName $VmName -Path $IsoPath -ErrorAction Stop }
  [ordered]@{ attached = $true; iso = $IsoPath }
}
function Remove-SourceMedia {
  param([string]$VmName)
  foreach ($d in @(Get-VMDvdDrive -VMName $VmName)) { Remove-VMDvdDrive -VMDvdDrive $d -ErrorAction SilentlyContinue }
}

function Get-GuestSourcePath {
  <# Resolves the mounted media inside the guest and returns the exact -SourcePath argument the
     repair wants: an install.wim/esd (with the edition index) for dism-restorehealth, the
     sources\sxs FOLDER for the optional-feature repairs. install.esd is handled because plenty of
     consumer ISOs ship one instead of a .wim. #>
  param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$Kind, [int]$EditionIndex)
  Invoke-Command -Session $Session -ScriptBlock {
    param($kind, $idx)
    $res = [ordered]@{ found = $false; path = $null; drive = $null; detail = '' }
    $drives = @()
    try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction Stop | ForEach-Object { "$($_.DeviceID)" }) } catch {}
    foreach ($d in $drives) {
      if ($kind -eq 'sxs') {
        $p = Join-Path "$d\" 'sources\sxs'
        if (Test-Path -LiteralPath $p) { $res.found = $true; $res.path = $p; $res.drive = $d; break }
      } else {
        foreach ($n in @('install.wim','install.esd')) {
          $p = Join-Path "$d\" "sources\$n"
          if (Test-Path -LiteralPath $p) { $res.found = $true; $res.path = "$p`:$idx"; $res.drive = $d; $res.detail = "found $n"; break }
        }
        if ($res.found) { break }
      }
    }
    if (-not $res.found) { $res.detail = "No mounted optical volume carries the requested source ($kind). Drives seen: $($drives -join ', ')" }
    $res
  } -ArgumentList $Kind, $EditionIndex -ErrorAction Stop
}

# =====================================================================================
# row execution
# =====================================================================================

function New-Row {
  param([string]$Cell, [string]$Repair, [string]$Outcome, [string]$Code, [string]$Message, $Extra)
  $r = [ordered]@{
    cell = $Cell; repair = $Repair; outcome = $Outcome; code = $Code; message = $Message
    assertions = @(); evidenceDir = $null; startedAt = $null; finishedAt = $null; durationSec = $null
  }
  if ($Extra) { foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] } }
  $r
}

function Test-RowPrecondition {
  <#
    STATIC preconditions - things that can be decided from the plan and the engine's own
    catalog, before a VM is touched. Returns $null when the row can be judged, and a sentence
    naming the gap when it cannot.

    Why this exists: a row whose fault the repair's DETECTION PROBE cannot see does not produce
    a verdict about the engine's locale handling, or about anything else. It produces
    `false-pass` - the release blocker this harness was built to detect - on every cell,
    including the en-US control, for a reason that has nothing to do with the code under test.
    A harness that fires false release blockers on its headline rows destroys trust in every
    other row, so the row is not run.

    It is NOT a skip. That was the previous round's mistake: turning a loud false-pass into a
    quiet skip hid the problem instead of fixing it, and 'skip' is the same word this file uses
    for a cell that is simply absent - something nobody is expected to act on. An unmet
    precondition is a CATALOG DEFECT that someone has to fix before the matrix can make its
    headline claim, so it gets its own outcome, 'not-judged', which is counted separately, is
    never folded into pass, and is printed in the matrix table in capitals. See New-Summary.

    requiresProbeDeep is the only precondition today. See matrix.json planFieldNotes for the
    full reasoning; the short version is that the shallow system-files probe runs
    `Repair-WindowsImage -Online -CheckHealth`, which reads previously RECORDED corruption flags
    rather than scanning, so a renamed WinSxS payload file is invisible to it.
  #>
  param($Plan_, $CatEntry, [string]$RepairId)

  $wantsDeep = $false
  try { $wantsDeep = [bool]$Plan_.requiresProbeDeep } catch {}
  if ($wantsDeep) {
    $hasDeep = $false
    try { $hasDeep = [bool]$CatEntry.probeDeep } catch {}
    if (-not $hasDeep) {
      return ("This row's fault is invisible to the SHALLOW detection probe, and '$RepairId' does not carry probeDeep:true in data\repairs.json - so repair.ps1 -Action preflight would run the shallow pass, report 'healthy' over a fault the harness's own oracle confirms is present, and this row would be scored 'false-pass'. That verdict would be about the catalog, not about the engine's behaviour on this cell, so NOTHING is concluded here. Fix: add probeDeep:true to the '$RepairId' entry in data\repairs.json - its relevantFindings already name 'component-store-scanhealth' and 'sfc-verify-violations', which only the DEEP pass can produce, so the catalog already depends on a probe depth it does not request.")
    }
  }
  return $null
}

function Invoke-Row {
  param(
    $Matrix, $Catalog, $CellDef, [string]$RepairId, $Plan_, $CatEntry,
    [pscredential]$Credential, [string]$RunRoot, [string]$SwitchName
  )
  $defaults   = $Matrix.defaults
  $vmName     = "$($CellDef.vmName)"
  $guestRoot  = "$($defaults.guestRoot)"
  $payload    = "$($defaults.guestPayloadRoot)"
  $enginePath = "$payload\engine"
  $evDir      = New-EvidenceDir -Root $RunRoot -Cell "$($CellDef.id)" -Repair $RepairId
  $started    = Get-Date
  $assertions = @()
  $session    = $null
  # SCRIPT-scoped on purpose: the nested Keep function below would otherwise create its own local
  # copy on every `+=` (PowerShell reads a parent scope's variable but writes a new one), and the
  # evidence list would silently come back empty.
  $script:RowFiles = @()

  $row = New-Row -Cell "$($CellDef.id)" -Repair $RepairId -Outcome 'fail' -Code 'engine-error' -Message 'The row did not complete.' -Extra @{
    fault = "$($Plan_.fault)"; expect = "$($Plan_.expect)"; evidenceDir = $evDir; startedAt = $started.ToString('s')
  }

  function Finish {
    param([string]$Outcome, [string]$Code, [string]$Message)
    $row.outcome = $Outcome; $row.code = $Code; $row.message = $Message
    $row.assertions = @($assertions); $row.files = @($script:RowFiles)
    $row.finishedAt = (Get-Date).ToString('s')
    $row.durationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    $row
  }
  function Keep {
    <# Writing the evidence is part of the assertion, not bookkeeping: a result that cannot be
       read back later is not a result, so a write failure aborts the row with 'evidence-lost'. #>
    param([string]$Name, $Doc, [string]$Raw)
    try {
      $p = Save-Evidence -Dir $evDir -Name $Name -Object $Doc -RawText $Raw
      $script:RowFiles += $p
    } catch { throw "EVIDENCE-LOST: $($_.Exception.Message)" }
  }

  try {
    # ---- 0) static preconditions, BEFORE a VM is touched -----------------------------------
    # A row that cannot possibly produce a verdict about the engine must not spend a checkpoint
    # restore proving it, and must never be scored as a failure of the thing it did not measure.
    $precondition = Test-RowPrecondition -Plan_ $Plan_ -CatEntry $CatEntry -RepairId $RepairId
    if ($null -ne $precondition) { return (Finish 'not-judged' 'harness-precondition-unmet' $precondition) }

    # ---- 0b) restore the clean checkpoint ---------------------------------------------------
    $session = Restore-CleanCheckpoint -VmName $vmName -CheckpointName "$($defaults.checkpointName)" -Credential $Credential -TimeoutMinutes $RestoreTimeoutMinutes
    if ($null -eq $session) { return (Finish 'skip' 'cell-unavailable' "The '$($defaults.checkpointName)' checkpoint could not be restored, or PowerShell Direct did not answer afterwards.") }

    $netState = Set-RowNetwork -VmName $vmName -Wanted ([bool]$Plan_.requiresNetwork) -Switch $SwitchName
    Keep '00-network.json' $netState $null
    if ($Plan_.requiresNetwork -and -not $netState.connected) {
      return (Finish 'skip' 'cell-unavailable' "This repair needs a working network (the plan says requiresNetwork), and no external switch was configured. Pass -SwitchName, or accept that this row cannot be judged: without a network the repair would fail for a reason that has nothing to do with the code.")
    }

    Copy-PayloadToGuest -Session $session -RepoRoot $RepoRoot -PayloadRoot $payload -GuestRoot $guestRoot

    # Prove the guest session is ELEVATED before anything is concluded. A filtered token makes
    # every probe report needs-admin and every repair refuse, which would look exactly like an
    # engine failure and is not one.
    $adminCheck = Invoke-Command -Session $session -ScriptBlock {
      ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    Keep '01-guest-elevation.json' ([ordered]@{ elevated = [bool]$adminCheck; note = 'PowerShell Direct authenticates a LOCAL account; without LocalAccountTokenFilterPolicy=1 (set by the unattend''s specialize pass, as LOCAL SYSTEM, before first logon - Initialize-Guest.ps1 only verifies it) the token is filtered and nothing elevated runs.' }) $null
    if (-not $adminCheck) { return (Finish 'skip' 'cell-unavailable' 'The PowerShell Direct session is not elevated, so LocalAccountTokenFilterPolicy is not 1 on this image. That value is set by the unattend''s specialize pass before first logon, so this base VHDX predates the current template: rebuild the base and the cell. No verdict about the engine can be drawn from an unelevated run.') }

    # ---- 1) baseline ----------------------------------------------------------------------
    $pre = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments @('-Action','preflight','-Id',$RepairId) -TimeoutMinutes $StepTimeoutMinutes
    Keep '02-baseline-preflight.json' $pre.json $pre.raw
    if ($pre.timedOut) { return (Finish 'fail' 'step-timeout' 'The baseline preflight did not return within the step timeout. No verdict is recorded.') }
    if (-not $pre.parsed) { return (Finish 'fail' 'engine-error' "repair.ps1 -Action preflight did not emit parseable JSON (exit $($pre.exitCode)). The raw output is in the evidence directory.") }

    $appl = $null; try { $appl = $pre.json.applicability } catch {}
    if ($appl -and $appl.applicable -eq $false) {
      $assertions += New-Assertion 'build-gate' 'applicable on this cell' "not applicable: $($appl.notApplicableReason)" $true 'Recorded as a skip, and as evidence that the catalog build gate fired where it should.'
      return (Finish 'skip' 'not-applicable-on-this-build' "$($appl.notApplicableReason)")
    }

    $baseState = "$($pre.json.detection.state)"
    $baselineShouldBeFaulted = [bool]$Plan_.baselineExpectedFaulted
    if ($baselineShouldBeFaulted) {
      $okB = ($baseState -eq 'problem')
      $assertions += New-Assertion 'baseline-clean' "detection 'problem' (this row's baseline is legitimately faulted: $($Plan_.notes))" $baseState $okB
      if (-not $okB) { return (Finish 'skip' 'baseline-not-clean' "This row expects the clean checkpoint to already show the condition (an unactivated VM, or a feature that ships disabled), and detection reported '$baseState' instead. Nothing downstream can be concluded.") }
    } else {
      $okB = ($baseState -eq 'healthy')
      $assertions += New-Assertion 'baseline-clean' "detection 'healthy'" $baseState $okB
      if (-not $okB) { return (Finish 'skip' 'baseline-not-clean' "The clean checkpoint does not start healthy for this repair (detection '$baseState': $($pre.json.detection.detail)). The checkpoint is dirty; fix the cell, do not read anything into the engine from this row.") }
    }

    # ---- 2) inject the fault ---------------------------------------------------------------
    $faultId = "$($Plan_.fault)"
    $faultScript = $null
    if ($faultId) {
      $faultScript = "$guestRoot\guest\faults\$faultId.ps1"
      $fargs = @('-Action','inject')
      if ($Plan_.faultArgs) {
        foreach ($p in $Plan_.faultArgs.PSObject.Properties) { $fargs += "-$($p.Name)"; $fargs += "$($p.Value)" }
      }
      $inj = Invoke-GuestJson -Session $session -File $faultScript -Arguments $fargs
      Keep '03-fault-inject.json' $inj.json $inj.raw
      if ($inj.timedOut) { return (Finish 'fail' 'step-timeout' "Fault '$faultId' did not return within the step timeout; the guest may be half-broken. Restore the checkpoint and re-run this row alone.") }
      if (-not $inj.parsed) { return (Finish 'fail' 'fault-injection-failed' "The fault script '$faultId' did not emit parseable JSON.") }
      $injected = $inj.json.injected
      $okI = ($injected -eq $true)
      $assertions += New-Assertion 'fault-injected' 'the oracle confirms the subsystem is broken' "injected=$injected" $okI "$($inj.json.message)"
      if (-not $okI) {
        $why = 'the oracle reports the fault is NOT present'
        if ($null -eq $injected) { $why = 'the oracle COULD NOT DETERMINE whether the fault is present' }
        return (Finish 'fail' 'fault-injection-failed' "Fault '$faultId' was not established - $why. Nothing is concluded about the engine from this row.")
      }
    } else {
      $assertions += New-Assertion 'fault-injected' 'no injection needed (the condition is native to this cell)' 'skipped' $true "$($Plan_.notes)"
    }

    # ---- 3) THE assertion: does FrameForge see it? -----------------------------------------
    $det = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments @('-Action','preflight','-Id',$RepairId) -TimeoutMinutes $StepTimeoutMinutes
    Keep '04-detect-preflight.json' $det.json $det.raw
    if ($det.timedOut) { return (Finish 'fail' 'step-timeout' 'The detection preflight did not return within the step timeout. This is the decisive assertion, so the row records no verdict at all rather than a partial one.') }
    if (-not $det.parsed) { return (Finish 'fail' 'engine-error' 'repair.ps1 -Action preflight did not emit parseable JSON after injection.') }
    $dState  = "$($det.json.detection.state)"
    $dReason = "$($det.json.detection.reason)"
    $dCatSt  = "$($det.json.detection.categoryStatus)"
    $relCount = 0; try { $relCount = @($det.json.detection.relevantFindings).Count } catch {}
    $okD = ($dState -eq 'problem' -and $relCount -gt 0)
    $assertions += New-Assertion 'fault-detected' "detection 'problem' with at least one matching finding" "state=$dState reason=$dReason categoryStatus=$dCatSt matchingFindings=$relCount" $okD "$($det.json.detection.detail)"
    if (-not $okD) {
      if ($dState -eq 'healthy' -and ($dCatSt -eq 'warning' -or $dCatSt -eq 'critical')) {
        return (Finish 'fail' 'wrong-finding' "The '$dCatSt' category noticed something, but none of this repair's relevantFindings matched the fault the harness injected. The probe is not blind here - it is pointed at the wrong signal.")
      }
      if ($dState -eq 'healthy') {
        $msg = "FALSE PASS. The harness injected fault '$faultId', its own oracle confirmed the subsystem is broken, and FrameForge's read-only probe reports HEALTHY. This is doctrine rule 2's worst case: a green tick over a measurement that failed."
        if ("$($CellDef.role)" -like 'locale*') { $msg += " This cell is $($CellDef.os.product) $($CellDef.iso.language) - the first thing to check is whether the verdict is being reached from English console text." }
        return (Finish 'fail' 'false-pass' $msg)
      }
      return (Finish 'fail' 'detect-unknown' "The probe could not determine the state (state=$dState, reason=$dReason) over a fault the oracle confirmed. Honest - 'could not determine' is a first-class result - but the signal could not be read, which is a real gap on this cell.")
    }

    # ---- 4) run the repair for real ---------------------------------------------------------
    $runArgs = @('-Action','run','-Id',$RepairId)
    if ($Plan_.requiresSource) {
      $kind = 'wim'; if ("$($Plan_.repair)" -like 'enable-*') { $kind = 'sxs' }
      $media = Add-SourceMedia -VmName $vmName -IsoPath (Join-Path "$($defaults.isoRoot)" "$($CellDef.iso.fileName)")
      Keep '05-source-media.json' $media $null
      if (-not $media.attached) { return (Finish 'skip' 'cell-unavailable' "This repair needs installation media as a -SourcePath and the cell's ISO could not be attached: $($media.reason)") }
      Start-Sleep -Seconds 5
      $src = Get-GuestSourcePath -Session $session -Kind $kind -EditionIndex ([int]$CellDef.iso.editionIndex)
      Keep '06-source-path.json' $src $null
      if (-not $src.found) { return (Finish 'skip' 'cell-unavailable' "The mounted media does not carry the required source: $($src.detail)") }
      $runArgs += '-SourcePath'; $runArgs += "$($src.path)"
    }

    $run = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments $runArgs -TimeoutMinutes $StepTimeoutMinutes
    Keep '07-repair-run.json' $run.json $run.raw
    if ($run.timedOut) { return (Finish 'fail' 'step-timeout' "The repair did not return within $StepTimeoutMinutes minute(s). It may still be running inside the guest; the checkpoint restore in this row's cleanup discards it. Raise -StepTimeoutMinutes for sfc/DISM-heavy rows.") }
    if (-not $run.parsed) { return (Finish 'fail' 'engine-error' "repair.ps1 -Action run did not emit parseable JSON (exit $($run.exitCode)).") }
    if ($run.json.refused -eq $true) {
      $assertions += New-Assertion 'repair-ran' 'the repair runs' "refused: $($run.json.refusalKind)" $false "$($run.json.message)"
      return (Finish 'fail' 'repair-refused' "The repair REFUSED after the harness had already established that the fault is real and detected: $($run.json.message)")
    }
    $stepsCompleted = $false; try { $stepsCompleted = [bool]$run.json.result.stepsCompleted } catch {}
    $assertions += New-Assertion 'repair-ran' 'ok:true and not refused' "ok=$($run.json.ok) stepsCompleted=$stepsCompleted" ([bool]$run.json.ok) "$($run.json.result.detail)"

    # ---- 5) reboot when the catalog says so --------------------------------------------------
    $needsReboot = $false
    try { $needsReboot = [bool]$CatEntry.requiresReboot } catch {}
    if ($needsReboot) {
      $session = Restart-GuestAndWait -VmName $vmName -Credential $Credential -Session $session -TimeoutMinutes $RebootTimeoutMinutes
      if ($null -eq $session) {
        $assertions += New-Assertion 'reboot' 'PowerShell Direct returns after the restart' 'timeout' $false
        return (Finish 'fail' 'reboot-timeout' "The guest did not come back on PowerShell Direct within $RebootTimeoutMinutes minutes after the repair's restart. No verdict about the repair is recorded, because none was measured.")
      }
      $assertions += New-Assertion 'reboot' 'PowerShell Direct returns after the restart' 'returned' $true
      Copy-PayloadToGuest -Session $session -RepoRoot $RepoRoot -PayloadRoot $payload -GuestRoot $guestRoot
    }

    # ---- 6) verify with the same probe -------------------------------------------------------
    $ver = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments @('-Action','preflight','-Id',$RepairId) -TimeoutMinutes $StepTimeoutMinutes
    Keep '08-verify-preflight.json' $ver.json $ver.raw
    if ($ver.timedOut) { return (Finish 'fail' 'step-timeout' 'The verify preflight did not return within the step timeout, so the repair is recorded as UNVERIFIED rather than as anything else.') }
    if (-not $ver.parsed) { return (Finish 'fail' 'engine-error' 'repair.ps1 -Action preflight did not emit parseable JSON at verify time.') }
    $vState = "$($ver.json.detection.state)"
    $runVerified = $false; try { $runVerified = [bool]$run.json.result.verified } catch {}

    if ("$($Plan_.expect)" -eq 'detected-not-verified') {
      # The inverted row. The honest answer here is "I ran and it did not fix it, and here is why".
      $okV = (-not $runVerified)
      $assertions += New-Assertion 'verify-honest-failure' 'the run reports NOT verified, with a reason' "verified=$runVerified detection=$vState" $okV "$($run.json.result.detail)"
      if (-not $okV) { return (Finish 'fail' 'false-success' "The run claims the problem is fixed, but on this cell it cannot be: $($Plan_.notes) A repair that reports success for a fix it could not have made is the second kind of false pass.") }
      $hasReason = ("$($run.json.result.detail)".Trim().Length -gt 0)
      $assertions += New-Assertion 'verify-explains-itself' 'a non-empty explanation accompanies the unverified result' "detailLength=$("$($run.json.result.detail)".Length)" $hasReason
    } else {
      $okV = ($vState -eq 'healthy' -and $runVerified -and $stepsCompleted)
      $assertions += New-Assertion 'verify-healthy' "the same probe reports healthy AND the run reports verified" "detection=$vState verified=$runVerified stepsCompleted=$stepsCompleted" $okV "$($run.json.result.detail)"
      if (-not $stepsCompleted) { return (Finish 'fail' 'repair-failed' "A step that counts failed: $($run.json.result.detail)") }
      if (-not $okV) { return (Finish 'fail' 'verify-not-healthy' "Steps completed but the fault is not gone (detection '$vState'): $($ver.json.detection.detail)") }
    }

    # ---- 7) undo ------------------------------------------------------------------------------
    $reversible = $false; try { $reversible = [bool]$CatEntry.reversible } catch {}
    if ($reversible -and $Plan_.undo -and -not $SkipUndo) {
      $undo = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments @('-Action','undo','-Id',$RepairId)
      Keep '09-repair-undo.json' $undo.json $undo.raw
      if ($undo.timedOut) { return (Finish 'fail' 'step-timeout' 'Undo did not return within the step timeout.') }
      if (-not $undo.parsed) { return (Finish 'fail' 'engine-error' 'repair.ps1 -Action undo did not emit parseable JSON.') }
      $undoOk = $false; try { $undoOk = [bool]$undo.json.ok } catch {}

      if ("$($Plan_.undoAssertion)" -eq 'documented-noop') {
        $restored = @(); try { $restored = @($undo.json.restored) } catch {}
        $saysSo = ((@($restored) -join ' ') -match '(?i)nothing to restore|stateless')
        $assertions += New-Assertion 'undo-restored' 'undo succeeds and states explicitly that there was nothing to restore' "ok=$undoOk restored=$((@($restored) -join ' | '))" ($undoOk -and $saysSo) 'This repair is reversible but leaves no state behind; the assertion is that undo says so rather than inventing a restore.'
        if (-not ($undoOk -and $saysSo)) { return (Finish 'fail' 'undo-not-restored' 'Undo did not return the documented no-op result.') }
      } else {
        # The state the repair captured and must restore IS the faulted state the harness injected,
        # so after a correct undo the oracle must read FAULTED again. That is a much stronger check
        # than "undo returned ok".
        $fargs2 = @('-Action','probe')
        if ($Plan_.faultArgs) { foreach ($p in $Plan_.faultArgs.PSObject.Properties) { $fargs2 += "-$($p.Name)"; $fargs2 += "$($p.Value)" } }
        $post = Invoke-GuestJson -Session $session -File "$guestRoot\guest\faults\$faultId.ps1" -Arguments $fargs2
        Keep '10-undo-groundtruth.json' $post.json $post.raw
        $postFaulted = $null; if ($post.parsed) { $postFaulted = $post.json.groundTruth.faulted }
        $okU = ($undoOk -and $postFaulted -eq $true)
        $assertions += New-Assertion 'undo-restored' 'the oracle reads the pre-repair state again' "undo.ok=$undoOk groundTruth.faulted=$postFaulted" $okU "$($post.json.groundTruth.detail)"
        if (-not $okU) {
          $d = 'the oracle does not read the captured prior state after undo'
          if ($null -eq $postFaulted) { $d = 'the oracle could not determine the state after undo' }
          return (Finish 'fail' 'undo-not-restored' "Undo did not put the machine back: $d. Doctrine rule 3 says undo restores CAPTURED prior state, never an assumed default.")
        }
      }
    } else {
      $assertions += New-Assertion 'undo-restored' 'not applicable' "reversible=$reversible planUndo=$($Plan_.undo) skipUndo=$([bool]$SkipUndo)" $true
    }

    # ---- 8) collect the ledger ----------------------------------------------------------------
    $ledger = Invoke-GuestJson -Session $session -File "$enginePath\repair.ps1" -Arguments @('-Action','ledger')
    Keep '11-ledger.json' $ledger.json $ledger.raw

    return (Finish 'pass' 'ok' 'Detected the injected fault, ran, verified, and (where reversible) restored the captured prior state.')

  } catch {
    $m = "$($_.Exception.Message)"
    if ($m -like 'EVIDENCE-LOST:*') { return (Finish 'fail' 'evidence-lost' $m) }
    return (Finish 'fail' 'engine-error' "The row threw: $m")
  } finally {
    if ($session) { try { Remove-PSSession $session -ErrorAction SilentlyContinue } catch {} }
    try { Remove-SourceMedia -VmName $vmName } catch {}
    # Always return the cell to its clean checkpoint, whatever happened. A row that leaves a
    # broken VM behind poisons every row after it.
    try {
      if (Get-VMCheckpoint -VMName $vmName -Name "$($defaults.checkpointName)" -ErrorAction SilentlyContinue) {
        Restore-VMCheckpoint -VMName $vmName -Name "$($defaults.checkpointName)" -Confirm:$false -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}

# =====================================================================================
# reporting
# =====================================================================================

function New-Summary {
  param($Results, $Matrix, [string]$RunRoot, $CellScans)
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine('# FrameForge VM matrix results')
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine("Run: $RunRoot")
  $null = $sb.AppendLine("Finished: $((Get-Date).ToString('s'))")
  $null = $sb.AppendLine('')
  $pass = @($Results | Where-Object { $_.outcome -eq 'pass' }).Count
  $fail = @($Results | Where-Object { $_.outcome -eq 'fail' }).Count
  $skip = @($Results | Where-Object { $_.outcome -eq 'skip' }).Count
  $njd  = @($Results | Where-Object { $_.outcome -eq 'not-judged' }).Count
  $null = $sb.AppendLine("**$pass pass / $fail fail / $njd NOT JUDGED / $skip skip** out of $(@($Results).Count) rows.")
  $null = $sb.AppendLine('')
  $fp = @($Results | Where-Object { $_.code -eq 'false-pass' })
  $du = @($Results | Where-Object { $_.code -eq 'detect-unknown' })
  $null = $sb.AppendLine('## Read this first')
  $null = $sb.AppendLine('')
  if ($fp.Count -gt 0) {
    $null = $sb.AppendLine("**$($fp.Count) FALSE PASS row(s).** A fault was injected, an independent oracle confirmed the subsystem was broken, and FrameForge's probe reported healthy anyway. This is the worst bug class in the codebase and every one of these is a release blocker:")
    foreach ($r in $fp) { $null = $sb.AppendLine("  * ``$($r.cell)`` / ``$($r.repair)`` - $($r.message)") }
  } else {
    $null = $sb.AppendLine('No false passes: no probe reported healthy over a fault the harness had confirmed. That is the one claim this harness exists to make.')
  }
  $null = $sb.AppendLine('')
  # "No false passes" is only worth reading next to the rows that were never judged. A matrix that
  # skipped a headline row for a harness reason and then reported a clean bill of health would be
  # doing exactly what this project accuses the snake-oil tools of doing.
  $pc = @($Results | Where-Object { $_.outcome -eq 'not-judged' })
  if ($pc.Count -gt 0) {
    $null = $sb.AppendLine("**$($pc.Count) row(s) were NOT JUDGED** because a static precondition they declare is not satisfied by the engine's catalogs. This is a distinct outcome, not a skip and certainly not a pass: it means somebody has to change a catalog before this matrix can say anything at all about these cells. Nothing above - including the absence of false passes - is a claim about them:")
    foreach ($r in $pc) { $null = $sb.AppendLine("  * ``$($r.cell)`` / ``$($r.repair)`` - $($r.message)") }
    $null = $sb.AppendLine('')
  }
  if ($du.Count -gt 0) {
    $null = $sb.AppendLine("$($du.Count) row(s) reported ``unknown`` over a confirmed fault. Honest, but the signal could not be read - usually a text parse with no structural rung beneath it:")
    foreach ($r in $du) { $null = $sb.AppendLine("  * ``$($r.cell)`` / ``$($r.repair)``") }
    $null = $sb.AppendLine('')
  }

  $null = $sb.AppendLine('## Matrix')
  $null = $sb.AppendLine('')
  $cells = @($Results | ForEach-Object { $_.cell } | Select-Object -Unique)
  $reps  = @($Results | ForEach-Object { $_.repair } | Select-Object -Unique)
  $null = $sb.AppendLine('| repair | ' + (($cells | ForEach-Object { $_ }) -join ' | ') + ' |')
  $null = $sb.AppendLine('|---|' + (($cells | ForEach-Object { '---' }) -join '|') + '|')
  foreach ($rep in $reps) {
    $line = "| $rep |"
    foreach ($c in $cells) {
      $row = @($Results | Where-Object { $_.cell -eq $c -and $_.repair -eq $rep }) | Select-Object -First 1
      if ($null -eq $row) { $line += ' - |'; continue }
      # 'PASS' is the DEFAULT here, so every outcome that is not a pass must be named above it.
      # A new outcome added below without a branch here would render as PASS, which is the one
      # thing this table may never do.
      $mark = switch ("$($row.outcome)") {
        'pass'       { 'PASS' }
        'fail'       { "FAIL ($($row.code))" }
        'not-judged' { "NOT JUDGED ($($row.code))" }
        'skip'       { "skip ($($row.code))" }
        default      { "?? unknown outcome '$($row.outcome)' ($($row.code))" }
      }
      $line += " $mark |"
    }
    $null = $sb.AppendLine($line)
  }
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine('## How to read a row')
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine('Each row has an evidence directory under this run holding every JSON document either side produced, in order: the baseline preflight, the fault injection and its ground truth, the detection preflight (the decisive one), the repair run, the verify preflight, the undo, and the ledger. A verdict you cannot trace to those files is not a verdict.')
  $null = $sb.AppendLine('')
  $null = $sb.AppendLine('* **NOT JUDGED / harness-precondition-unmet** - the row declares a static precondition (today: requiresProbeDeep) that the engine''s own catalog does not satisfy, so the row was not run and NOTHING is concluded from it. It is neither a pass nor a skip: fix the catalog entry the message names, then re-run.')
  $null = $sb.AppendLine('* **skip / baseline-not-clean** - the cell''s clean checkpoint was already unhealthy for that category. Nothing about the engine can be read from it; rebuild the cell.')
  $null = $sb.AppendLine('* **skip / no-synthetic-fault** - the condition cannot be created honestly in a VM (component-cleanup needs the residue of real cumulative updates). Not a pass.')
  $null = $sb.AppendLine('* **skip / not-virtualisable** - see matrix.json / nonVirtualisableCells. The laptop-battery gap is the important one: Hyper-V has no battery device at all, so a power check gets a FALSE PASS from absence and no VM can catch it.')
  $null = $sb.AppendLine('* **fail / false-pass** - stop and fix.')
  $null = $sb.AppendLine('')
  if ($CellScans -and @($CellScans.Keys).Count -gt 1) {
    $null = $sb.AppendLine('## Locale divergence')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('locale-divergence.json compares each cell''s clean-baseline deep scan against the control cell''s, category by category. A category that reads ``ok`` on the control and ``unknown`` on a localized cell is a locale bug found without running a single repair.')
    $null = $sb.AppendLine('')
  }
  $sb.ToString()
}

function New-LocaleDivergence {
  param($CellScans, [string]$ControlCell)
  $out = [ordered]@{
    control = $ControlCell
    note = 'Category status of each cell''s clean-baseline deep scan, compared against the control cell. Divergence is not automatically a bug - a Home cell legitimately differs - but a category that is ok on the control and unknown/needs-admin on a localized cell of the same edition is a measurement that stopped working when the language changed.'
    cells = [ordered]@{}
    divergences = @()
  }
  if (-not $CellScans.ContainsKey($ControlCell)) { $out.note = 'The control cell did not run, so there is no reference scan to compare against. Statuses are recorded without a comparison.' }
  foreach ($k in @($CellScans.Keys)) {
    $map = [ordered]@{}
    foreach ($c in @($CellScans[$k].categories)) { $map["$($c.category)"] = "$($c.status)" }
    $out.cells[$k] = $map
  }
  if ($CellScans.ContainsKey($ControlCell)) {
    $ref = $out.cells[$ControlCell]
    foreach ($k in @($out.cells.Keys)) {
      if ($k -eq $ControlCell) { continue }
      foreach ($cat in @($ref.Keys)) {
        $a = "$($ref[$cat])"; $b = "$($out.cells[$k][$cat])"
        if ($a -ne $b) {
          $out.divergences += [ordered]@{ cell = $k; category = $cat; control = $a; cell_status = $b
            severity = $(if ($a -eq 'ok' -and $b -eq 'unknown') { 'suspect-locale-bug' } else { 'informational' }) }
        }
      }
    }
  }
  $out
}

# =====================================================================================
# main
# =====================================================================================

$doc = $null
try {
  $matrix  = Get-Json -Path $MatrixPath
  $catalog = Get-Json -Path (Join-Path $RepoRoot 'data\repairs.json')
  $defaults = $matrix.defaults
  if (-not $OutRoot) { $OutRoot = "$($defaults.resultsRoot)" }
  if (-not $SwitchName) { $SwitchName = "$($defaults.externalSwitchName)" }

  $cellDefs = @($matrix.cells | Where-Object { $_.enabled -eq $true })
  if ($Cells) { $cellDefs = @($matrix.cells | Where-Object { $Cells -contains $_.id }) }
  if (@($cellDefs).Count -eq 0) { throw 'No cells selected. Use -Cells, or enable cells in matrix.json.' }

  $runId = "run-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
  $runRoot = Join-Path $OutRoot $runId

  # ---- plan ----
  $planned = @()
  foreach ($cd in $cellDefs) {
    foreach ($rid in (Resolve-RepairList -Matrix $matrix -Catalog $catalog -CellDef $cd)) {
      $p = Get-PlanFor -Matrix $matrix -RepairId $rid
      $skipReason = $null
      if ($null -eq $p) { $skipReason = 'no-plan-entry' }
      elseif ($p.skip -eq $true) { $skipReason = "$($p.skipReason)" }
      elseif ($p.runOnCells -and -not (@($p.runOnCells) -contains $cd.id)) { $skipReason = 'user-filtered' }
      $planned += [ordered]@{ cell = "$($cd.id)"; repair = $rid; skipReason = $skipReason; fault = $(if ($p) { "$($p.fault)" } else { $null }); expect = $(if ($p) { "$($p.expect)" } else { $null }) }
    }
  }

  if ($Plan) {
    $doc = [ordered]@{ ok = $true; action = 'invoke-vm-matrix'; mode = 'plan'; mutated = $false
                       runRoot = $runRoot; cells = @($cellDefs | ForEach-Object { $_.id }); rows = @($planned)
                       rowCount = @($planned).Count
                       note = 'Plan only: no VM was touched, no checkpoint restored, no repair run.' }
    $doc.log = @($script:Log)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 12))
    exit 0
  }

  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PowerShell Direct and the Hyper-V cmdlets require an elevated host session.'
  }
  if (-not $AdminPassword) {
    if ($env:FF_VMTEST_PASSWORD) { $AdminPassword = ConvertTo-SecureString $env:FF_VMTEST_PASSWORD -AsPlainText -Force }
    else { throw 'Pass -AdminPassword (a SecureString) or set $env:FF_VMTEST_PASSWORD to the guest local-administrator password New-TestVm.ps1 provisioned.' }
  }
  if (-not $PSCmdlet.ShouldProcess("$(@($cellDefs).Count) cell(s), $(@($planned).Count) row(s)", 'Run repairs FOR REAL inside the test VMs (each row restores the clean checkpoint first)')) {
    throw 'Cancelled at the confirmation prompt.'
  }

  New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
  Add-Log "Run root: $runRoot"

  $results = @()
  $cellScans = @{}
  $stopped = $false

  foreach ($cd in $cellDefs) {
    $vmName = "$($cd.vmName)"
    $cred = New-GuestCredential -CellDef $cd -Defaults $defaults -Secure $AdminPassword
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    $repairList = Resolve-RepairList -Matrix $matrix -Catalog $catalog -CellDef $cd

    if ($null -eq $vm) {
      foreach ($rid in $repairList) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code 'cell-unavailable' -Message "No VM named '$vmName' on this host. Provision it: New-TestVm.ps1 -Cell $($cd.id) -Role cell" }
      Add-Log "Cell '$($cd.id)': VM '$vmName' not present - every row skipped."
      continue
    }
    if ($null -eq (Get-VMCheckpoint -VMName $vmName -Name "$($defaults.checkpointName)" -ErrorAction SilentlyContinue)) {
      foreach ($rid in $repairList) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code 'cell-unavailable' -Message "VM '$vmName' has no '$($defaults.checkpointName)' checkpoint. Rebuild the cell." }
      Add-Log "Cell '$($cd.id)': no clean checkpoint - every row skipped."
      continue
    }

    # Per-cell baseline deep scan: the document every locale comparison is made against.
    try {
      $s = Restore-CleanCheckpoint -VmName $vmName -CheckpointName "$($defaults.checkpointName)" -Credential $cred -TimeoutMinutes $RestoreTimeoutMinutes
      if ($s) {
        Copy-PayloadToGuest -Session $s -RepoRoot $RepoRoot -PayloadRoot "$($defaults.guestPayloadRoot)" -GuestRoot "$($defaults.guestRoot)"
        $scan = Invoke-GuestJson -Session $s -File "$($defaults.guestPayloadRoot)\engine\health.ps1" -Arguments @('-Action','scan','-Deep') -TimeoutMinutes $StepTimeoutMinutes
        $cellDir = Join-Path $runRoot "$($cd.id)"
        if (-not (Test-Path -LiteralPath $cellDir)) { New-Item -ItemType Directory -Force -Path $cellDir | Out-Null }
        $null = Save-Evidence -Dir $cellDir -Name 'baseline-deep-scan.json' -Object $scan.json -RawText $scan.raw
        if ($scan.parsed) { $cellScans["$($cd.id)"] = $scan.json }
        Remove-PSSession $s -ErrorAction SilentlyContinue
      }
    } catch { Add-Log "Cell '$($cd.id)': baseline deep scan failed - $($_.Exception.Message)" }

    foreach ($rid in $repairList) {
      if ($stopped) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code 'user-filtered' -Message 'Run stopped early by -StopOnFalsePass.'; continue }
      $p = Get-PlanFor -Matrix $matrix -RepairId $rid
      $ce = Get-CatalogFor -Catalog $catalog -RepairId $rid
      if ($null -eq $p) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code 'no-plan-entry' -Message 'This repair has no entry in matrix.json repairPlan. Add one - a repair with no plan is a repair with no coverage, and silence is not a pass.'; continue }
      if ($p.skip -eq $true) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code "$($p.skipReason)" -Message "$($p.notes)"; continue }
      if ($p.runOnCells -and -not (@($p.runOnCells) -contains $cd.id)) { $results += New-Row -Cell "$($cd.id)" -Repair $rid -Outcome 'skip' -Code 'user-filtered' -Message "This row runs only on: $((@($p.runOnCells)) -join ', ') - $($p.notes)"; continue }

      Add-Log "=== $($cd.id) / $rid ==="
      $row = Invoke-Row -Matrix $matrix -Catalog $catalog -CellDef $cd -RepairId $rid -Plan_ $p -CatEntry $ce -Credential $cred -RunRoot $runRoot -SwitchName $SwitchName
      $results += $row
      Add-Log "    -> $($row.outcome) / $($row.code)"
      if ($StopOnFalsePass -and $row.code -eq 'false-pass') { $stopped = $true; Add-Log 'Stopping early: -StopOnFalsePass and a false pass was recorded.' }
    }
  }

  $controlCell = "$((@($matrix.cells | Where-Object { $_.role -eq 'control' }) | Select-Object -First 1).id)"
  $divergence = New-LocaleDivergence -CellScans $cellScans -ControlCell $controlCell
  $null = Save-Evidence -Dir $runRoot -Name 'locale-divergence.json' -Object $divergence -RawText $null

  $resultsDoc = [ordered]@{
    schemaVersion = 1
    ok = $true
    action = 'invoke-vm-matrix'
    runId = $runId
    runRoot = $runRoot
    startedAt = $(if (@($script:Log).Count -gt 0) { $script:Log[0] } else { $null })
    finishedAt = (Get-Date).ToString('s')
    host = [ordered]@{ computer = "$env:COMPUTERNAME"; architecture = "$env:PROCESSOR_ARCHITECTURE"; psVersion = "$($PSVersionTable.PSVersion)" }
    matrixPath = $MatrixPath
    repoRoot = $RepoRoot
    cells = @($cellDefs | ForEach-Object { [ordered]@{ id = "$($_.id)"; vmName = "$($_.vmName)"; role = "$($_.role)"; language = "$($_.iso.language)"; product = "$($_.os.product)"; release = "$($_.os.release)" } })
    totals = [ordered]@{
      rows = @($results).Count
      pass = @($results | Where-Object { $_.outcome -eq 'pass' }).Count
      fail = @($results | Where-Object { $_.outcome -eq 'fail' }).Count
      skip = @($results | Where-Object { $_.outcome -eq 'skip' }).Count
      notJudged = @($results | Where-Object { $_.outcome -eq 'not-judged' }).Count
      falsePasses = @($results | Where-Object { $_.code -eq 'false-pass' }).Count
      detectUnknown = @($results | Where-Object { $_.code -eq 'detect-unknown' }).Count
    }
    results = @($results)
    localeDivergenceFile = 'locale-divergence.json'
    honestyNote = 'Every row is present, including skips and not-judged rows. Neither is ever rendered as a pass, and a row whose evidence could not be written fails with code evidence-lost rather than reporting the in-guest answer nobody could read back. `not-judged` is its own outcome on purpose: a static precondition the engine catalogs do not satisfy is a defect someone has to fix, and burying it in the skip count is how the previous round turned a loud false-pass into a silence.'
  }
  $null = Save-Evidence -Dir $runRoot -Name 'results.json' -Object $resultsDoc -RawText $null
  $summary = New-Summary -Results $results -Matrix $matrix -RunRoot $runRoot -CellScans $cellScans
  $null = Save-Evidence -Dir $runRoot -Name 'summary.md' -Object $null -RawText $summary

  $doc = [ordered]@{
    ok = ($resultsDoc.totals.fail -eq 0)
    action = 'invoke-vm-matrix'
    runId = $runId
    runRoot = $runRoot
    totals = $resultsDoc.totals
    resultsFile = (Join-Path $runRoot 'results.json')
    summaryFile = (Join-Path $runRoot 'summary.md')
    falsePasses = @($results | Where-Object { $_.code -eq 'false-pass' } | ForEach-Object { "$($_.cell)/$($_.repair)" })
    # ok:true says "no assertion failed". It does NOT say the matrix covered what it set out to
    # cover, so the rows it could not judge travel next to it rather than behind a count nobody
    # reads. A consumer that treats ok:true as a clean bill of health while complete:false has
    # been told, in the document, that it is wrong.
    complete = ($resultsDoc.totals.notJudged -eq 0)
    notJudged = @($results | Where-Object { $_.outcome -eq 'not-judged' } | ForEach-Object { "$($_.cell)/$($_.repair) ($($_.code))" })
    log = @($script:Log)
  }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 12))
  if ($resultsDoc.totals.fail -gt 0) { exit 1 } else { exit 0 }

} catch {
  $doc = [ordered]@{ ok = $false; action = 'invoke-vm-matrix'; error = "$($_.Exception.Message)"; scriptStackTrace = "$($_.ScriptStackTrace)"; log = @($script:Log) }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 12))
  exit 1
}
