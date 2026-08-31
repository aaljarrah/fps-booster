<#
  FrameForge VM test harness :: New-TestVm.ps1
  Provisions ONE cell from tools/vmtest/matrix.json.

  TWO ROLES
    -Role base   Installs Windows from the cell's ISO onto a fresh dynamic VHDX at
                 <baseRoot>\<baseKey>.vhdx, runs guest\setup\Initialize-Guest.ps1, shuts the guest
                 down and marks the VHDX read-only. That VHDX is then the PARENT for every cell
                 that shares the baseKey. Run this once per build+locale+edition combination; it
                 is the slow step (a full Windows install).
    -Role cell   Creates the actual test VM with a DIFFERENCING disk off that base, applies the
                 cell's conditioning, and takes the 'clean' checkpoint the orchestrator restores
                 before every single row. Cheap and repeatable - blow the cell away and remake it
                 without reinstalling Windows.

  WINDOWS 11 REQUIREMENTS ARE MET, NOT BYPASSED
    Generation 2 + Secure Boot on with the MicrosoftWindows template + a vTPM created with
    Set-VMKeyProtector -NewLocalKeyProtector followed by Enable-VMTPM. Setup's TPM 2.0 and Secure
    Boot checks then PASS on their own terms. This matters more than convenience: the moment a
    harness starts patching LabConfig\BypassTPMCheck into the registry it is testing a Windows
    configuration no user has, and any finding about BitLocker, Device Encryption or measured boot
    from such a VM is worthless.

  NO NETWORK ADAPTER BY DEFAULT
    Cells are built with every virtual network adapter REMOVED unless -SwitchName is given. It
    keeps the guest from downloading cumulative updates between the checkpoint and the assertion
    (which would rewrite SoftwareDistribution and the component store under the test), and it
    proves the control channel really is PowerShell Direct over the VMBus. Invoke-VmMatrix.ps1
    hot-attaches an adapter only for the rows whose plan entry sets requiresNetwork.

  OSCDIMG
    docs/research/winutil-dissection.md records how WinUtil finds oscdimg (Windows Kits, WinGet
    packages, PATH, and a winget install of Microsoft.OSCDIMG when missing). engine/image.ps1 has
    NO oscdimg locator of its own - it was read for one and does not contain one - so this file
    implements the same documented ladder in the house style: explicit override, PATH, the ADK
    Deployment Tools resolved from the KitsRoot10 REGISTRY value (locale-independent) as well as
    the usual Program Files paths, then the WinGet links directory. When none of them resolve,
    the ISO is built with the IMAPI2 COM file-system image writer that ships with Windows instead
    of failing - and the result document says which builder was used, because "the ISO was built"
    and "the ISO was built by the tool I expected" are different claims.

  SAFETY
    -Plan emits the entire plan as JSON and touches NOTHING. It needs no elevation and no Hyper-V.
    Every mutating path is behind ShouldProcess (ConfirmImpact High), so an accidental invocation
    prompts. This script creates VMs, VHDXs and ISOs on the host; it never modifies the host's own
    Windows configuration.

  Output: one JSON document on stdout. PowerShell 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory = $true)][string]$Cell,
  [ValidateSet('base','cell')][string]$Role = 'cell',
  [string]$MatrixPath,
  [string]$IsoPath,
  [securestring]$AdminPassword,
  [string]$VmRoot,
  [string]$SwitchName,
  [int]$InstallTimeoutMinutes = 90,
  [int]$BootTimeoutMinutes = 20,
  [switch]$KeepUnattendIso,
  [switch]$Plan,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# STRICT MODE, and why it is not optional here.
# Both success documents used to reference $planDocDoc - a typo for $planDoc that no version of
# this script has ever survived to notice, because with StrictMode off PowerShell silently
# evaluates an undefined variable to $null. The result was `plan: null` in the ONLY record of
# what was provisioned: the whole preflight / oscdimg / path block, gone, from the document a
# human reads to find out what was built. Version 2.0 turns that class of typo into an error at
# the moment it happens. It also errors on a reference to a property an object does not have,
# which is the second way a provisioning record quietly becomes a lie; every matrix-derived
# property this file reads is asserted present by tools\vmtest\Test-VmHarness.ps1, which the
# engine test suite runs, so that strictness is checked rather than hoped for.
Set-StrictMode -Version 2.0

if (-not $MatrixPath) { $MatrixPath = Join-Path $PSScriptRoot 'matrix.json' }

# ---------------- output helper ----------------

$script:Log = @()
function Add-Log { param([string]$Text) $script:Log += "$((Get-Date).ToString('HH:mm:ss')) $Text"; Write-Verbose $Text }
function Write-Doc {
  param($Doc, [int]$ExitCode = 0)
  $Doc.log = @($script:Log)
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Doc -Depth 12))
  exit $ExitCode
}
function New-ErrorDoc {
  param([string]$Code, [string]$Message, $Extra)
  $d = [ordered]@{ ok = $false; action = "new-test-vm"; cell = $Cell; role = $Role; errorCode = $Code; error = $Message }
  if ($Extra) { foreach ($k in $Extra.Keys) { $d[$k] = $Extra[$k] } }
  $d
}

# ---------------- matrix ----------------

function Get-Matrix {
  if (-not (Test-Path -LiteralPath $MatrixPath)) { throw "matrix.json not found at $MatrixPath" }
  Get-Content -Raw -Encoding UTF8 -LiteralPath $MatrixPath | ConvertFrom-Json
}
function Get-CellDef {
  param($Matrix, [string]$Id)
  $c = @($Matrix.cells) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if ($null -eq $c) { throw "Unknown cell '$Id'. Known cells: $((@($Matrix.cells) | ForEach-Object { $_.id }) -join ', ')" }
  $c
}

# ---------------- host preflight ----------------

function Test-HostAdmin {
  try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Get-HostPreflight {
  param($CellDef, $Defaults)
  $p = [ordered]@{}
  $p.isAdmin = Test-HostAdmin
  $p.hostArchitecture = "$env:PROCESSOR_ARCHITECTURE"
  $p.hyperVModule = $false
  try { $p.hyperVModule = [bool](Get-Command New-VM -ErrorAction SilentlyContinue) } catch {}
  $p.hyperVFeature = $null
  try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
    $p.hyperVFeature = "$($f.State)"
  } catch { $p.hyperVFeatureReadError = "$($_.Exception.Message)" }
  $p.vmms = $null
  try { $p.vmms = "$((Get-Service -Name vmms -ErrorAction Stop).Status)" } catch {}
  # Architecture gate. Hyper-V does not emulate a foreign CPU, so an ARM64 cell on an x64 host is
  # not slow - it is impossible.
  $need = "$($CellDef.os.architecture)"
  $hostArch = if ("$env:PROCESSOR_ARCHITECTURE" -match 'ARM64') { 'arm64' } else { 'x64' }
  $p.cellArchitecture = $need
  $p.architectureOk = ($need -eq $hostArch)
  # Disk budget
  $root = $VmRoot; if (-not $root) { $root = "$($Defaults.vmRoot)" }
  $p.vmRoot = $root
  $drive = ($root -replace '^([A-Za-z]):.*$', '$1')
  try {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($drive):'" -ErrorAction Stop
    $p.vmRootFreeGB = [math]::Round($d.FreeSpace / 1GB, 1)
  } catch { $p.vmRootFreeGB = $null }
  $p
}

# ---------------- oscdimg / ISO building ----------------

function Resolve-Oscdimg {
  <#
    Documented ladder, most authoritative first. Every rung reports WHICH rung answered, so a
    result can never be read as "found in the ADK" when it actually came off PATH.
      1. $env:FF_OSCDIMG              explicit override
      2. PATH                          Get-Command
      3. Windows Kits, via the KitsRoot10 REGISTRY value - a locale-independent read that also
         survives a non-default ADK install location. Every architecture sub-folder is tried.
      4. Windows Kits, via the conventional Program Files paths (in case the registry root is
         missing but the files are there)
      5. WinGet links / package directory (Microsoft.OSCDIMG)
    Returns $null when nothing resolves. The caller then falls back to the IMAPI2 builder rather
    than failing - and says so in its result.
  #>
  $tried = @()
  if ($env:FF_OSCDIMG) {
    $tried += "env:FF_OSCDIMG=$env:FF_OSCDIMG"
    if (Test-Path -LiteralPath $env:FF_OSCDIMG) { return [ordered]@{ path = $env:FF_OSCDIMG; source = 'env-override'; tried = $tried } }
  }
  try {
    $c = Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue
    $tried += 'PATH'
    if ($c) { return [ordered]@{ path = "$($c.Source)"; source = 'path'; tried = $tried } }
  } catch {}

  $kitRoots = @()
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots','HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')) {
    try {
      $v = (Get-ItemProperty -LiteralPath $k -Name 'KitsRoot10' -ErrorAction Stop).KitsRoot10
      if ($v) { $kitRoots += "$v" }
    } catch {}
  }
  foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if ($pf) { $kitRoots += (Join-Path $pf 'Windows Kits\10\') }
  }
  foreach ($root in ($kitRoots | Select-Object -Unique)) {
    foreach ($arch in @('amd64','arm64','x86')) {
      $p = Join-Path $root "Assessment and Deployment Kit\Deployment Tools\$arch\Oscdimg\oscdimg.exe"
      $tried += $p
      if (Test-Path -LiteralPath $p) { return [ordered]@{ path = $p; source = 'windows-kits'; tried = $tried } }
    }
  }

  $wingetCandidates = @()
  if ($env:LOCALAPPDATA) {
    $wingetCandidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\oscdimg.exe')
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $pkgRoot) {
      try {
        foreach ($hit in @(Get-ChildItem -LiteralPath $pkgRoot -Filter 'oscdimg.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 3)) {
          $wingetCandidates += $hit.FullName
        }
      } catch {}
    }
  }
  foreach ($p in $wingetCandidates) {
    $tried += $p
    if (Test-Path -LiteralPath $p) { return [ordered]@{ path = $p; source = 'winget'; tried = $tried } }
  }

  [ordered]@{ path = $null; source = 'not-found'; tried = $tried }
}

function New-IsoFromFolder {
  <#
    Builds a DATA ISO (no boot sector - this disc only carries autounattend.xml; the Windows ISO
    is the bootable one). oscdimg when available, IMAPI2 otherwise.
      oscdimg -m -o -u2 -udfver102 -l<label>
        -m         no size limit
        -o         de-duplicate identical files
        -u2/-udfver102  UDF 1.02, which Windows Setup reads reliably
    The IMAPI2 fallback uses the Windows-native file-system image writer (ISO9660 + Joliet) and a
    small C# shim to copy the resulting IStream to disk, because IStream cannot be written from
    PowerShell directly.
  #>
  param([Parameter(Mandatory)][string]$SourceFolder, [Parameter(Mandatory)][string]$IsoPath, [string]$Label = 'FFUNATTEND')
  $osc = Resolve-Oscdimg
  $outDir = Split-Path -Parent $IsoPath
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  if (Test-Path -LiteralPath $IsoPath) { Remove-Item -LiteralPath $IsoPath -Force }

  if ($osc.path) {
    # NOT named $args: that is an automatic variable, and shadowing it inside a function is the
    # kind of thing that works until someone adds a nested call.
    $oscArgs = @('-m','-o','-u2','-udfver102',"-l$Label", $SourceFolder, $IsoPath)
    Add-Log "oscdimg ($($osc.source)): $($osc.path) $($oscArgs -join ' ')"
    $out = & $osc.path @oscArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $IsoPath)) {
      throw "oscdimg exited $code and produced no ISO at $IsoPath. Output: $((@($out) | ForEach-Object { "$_" }) -join ' | ')"
    }
    return [ordered]@{ path = $IsoPath; builder = 'oscdimg'; builderPath = "$($osc.path)"; builderSource = "$($osc.source)"; bytes = (Get-Item -LiteralPath $IsoPath).Length }
  }

  Add-Log 'oscdimg not found on this host; falling back to the IMAPI2 COM image writer.'
  Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class FFIsoStreamWriter {
    // Copies an IMAPI2 result IStream to a file. No /unsafe: the byte count comes back through
    // an unmanaged int allocated here rather than through a pinned stack pointer.
    public static void Write(object comStream, string path, int blockSize, int totalBlocks) {
        IStream stream = comStream as IStream;
        if (stream == null) throw new ArgumentException("The COM object is not an IStream.");
        IntPtr counter = Marshal.AllocHGlobal(4);
        try {
            using (FileStream fs = File.Open(path, FileMode.Create, FileAccess.Write)) {
                byte[] buffer = new byte[blockSize];
                int remaining = totalBlocks;
                while (remaining-- > 0) {
                    stream.Read(buffer, blockSize, counter);
                    int read = Marshal.ReadInt32(counter);
                    if (read <= 0) break;
                    fs.Write(buffer, 0, read);
                }
                fs.Flush();
            }
        } finally { Marshal.FreeHGlobal(counter); }
    }
}
'@
  $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
  $fsi.FileSystemsToCreate = 3   # ISO9660 | Joliet
  $fsi.VolumeName = $Label
  $fsi.Root.AddTree($SourceFolder, $false)
  $result = $fsi.CreateResultImage()
  [FFIsoStreamWriter]::Write($result.ImageStream, $IsoPath, [int]$result.BlockSize, [int]$result.TotalBlocks)
  if (-not (Test-Path -LiteralPath $IsoPath)) { throw "The IMAPI2 fallback produced no ISO at $IsoPath." }
  [ordered]@{ path = $IsoPath; builder = 'imapi2'; builderPath = 'IMAPI2FS.MsftFileSystemImage'; builderSource = 'windows-builtin'; bytes = (Get-Item -LiteralPath $IsoPath).Length
              note = 'oscdimg was not found on this host. The ISO was built with the Windows COM image writer instead. Install the ADK Deployment Tools (or winget install Microsoft.OSCDIMG) if Setup rejects this disc.' }
}

function ConvertFrom-SecureStringPlain {
  param([securestring]$Secure)
  if ($null -eq $Secure) { return $null }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-UnattendIso {
  param($CellDef, $Defaults, [string]$PlainPassword, [string]$OutIso)
  $tpl = Join-Path $PSScriptRoot "$($CellDef.unattend)"
  if (-not (Test-Path -LiteralPath $tpl)) { throw "Unattend template not found: $tpl" }
  $xml = Get-Content -Raw -Encoding UTF8 -LiteralPath $tpl
  $xml = $xml.Replace('{{COMPUTERNAME}}', "$($CellDef.computerName)")
  $xml = $xml.Replace('{{USERNAME}}',     "$($Defaults.adminUser)")
  $xml = $xml.Replace('{{PASSWORD}}',     $PlainPassword)
  $xml = $xml.Replace('{{IMAGE_NAME}}',   "$($CellDef.iso.imageName)")
  if ($xml -match '\{\{') { throw "The unattend template still contains an unreplaced token after substitution: $tpl" }
  # Well-formedness is checked before anything is burned: a malformed autounattend.xml makes
  # Setup fall back to interactive OOBE, and the cell then hangs for the full install timeout
  # with no explanation.
  $null = [xml]$xml

  $stage = Join-Path ([IO.Path]::GetTempPath()) ("ffvmtest-unattend-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  try {
    # UTF-8 WITHOUT a BOM: Windows Setup's XML reader chokes on a BOM in autounattend.xml.
    [IO.File]::WriteAllText((Join-Path $stage 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))
    return (New-IsoFromFolder -SourceFolder $stage -IsoPath $OutIso -Label 'FFUNATTEND')
  } finally {
    try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# ---------------- PowerShell Direct ----------------

function New-GuestCredential {
  param($CellDef, $Defaults, [securestring]$Secure)
  $user = "$($CellDef.computerName)\$($Defaults.adminUser)"
  New-Object System.Management.Automation.PSCredential($user, $Secure)
}

function Wait-PSDirect {
  <#
    Polls PowerShell Direct until the guest answers or the timeout expires. This is the ONLY
    channel this harness uses - see the README - and it works with no virtual switch attached,
    which is what makes the network repairs testable at all.
    Returns the guest's answer or $null on timeout. NEVER returns a fabricated success.
  #>
  param([string]$VmName, [pscredential]$Credential, [int]$TimeoutMinutes = 20, [string]$What = 'guest')
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $attempt = 0
  while ((Get-Date) -lt $deadline) {
    $attempt++
    try {
      $r = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        [ordered]@{ computer = $env:COMPUTERNAME; provisioned = (Test-Path -LiteralPath 'C:\ffvmtest\provisioned.txt')
                    marker = $(try { Get-Content -Raw -LiteralPath 'C:\ffvmtest\provisioned.txt' -ErrorAction Stop } catch { $null }) }
      }
      Add-Log "PowerShell Direct answered from '$($r.computer)' after $attempt attempt(s) [$What]."
      return $r
    } catch {
      Start-Sleep -Seconds 15
    }
  }
  Add-Log "PowerShell Direct did NOT answer within $TimeoutMinutes minute(s) [$What] after $attempt attempt(s)."
  $null
}

function Copy-HarnessToGuest {
  param([string]$VmName, [pscredential]$Credential, [string]$GuestRoot)
  <# Copy-Item -ToSession over a PowerShell Direct session, NOT Copy-VMFile. Copy-VMFile needs the
     Guest Service Interface integration service and copies one file per call; -ToSession rides the
     same VMBus session everything else uses and copies trees. Copy-VMFile stays documented in the
     README as the fallback when a guest's PowerShell is too broken to host a session. #>
  $s = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
  try {
    Invoke-Command -Session $s -ScriptBlock {
      param($root)
      foreach ($d in @($root, (Join-Path $root 'guest'), (Join-Path $root 'state'), (Join-Path $root 'out'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
      }
    } -ArgumentList $GuestRoot
    Copy-Item -Path (Join-Path $PSScriptRoot 'guest\*') -Destination (Join-Path $GuestRoot 'guest') -ToSession $s -Recurse -Force -ErrorAction Stop
    Add-Log "Harness guest scripts copied to $GuestRoot\guest."
  } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Invoke-GuestScript {
  param([string]$VmName, [pscredential]$Credential, [string]$ScriptPath, [hashtable]$Parameters = @{})
  $s = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
  try {
    $raw = Invoke-Command -Session $s -ScriptBlock {
      param($p, $args_)
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p @args_ 2>&1
    } -ArgumentList $ScriptPath, (@($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key)"; "$($_.Value)" }))
    $text = ((@($raw) | ForEach-Object { "$_" }) -join "`n")
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch {}
    return [ordered]@{ raw = $text; json = $json; parsed = ($null -ne $json) }
  } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Get-GuestProp {
  <# One property read that StrictMode 2.0 cannot turn into a crash, and that returns $null
     rather than a guess when the guest's document simply does not carry the field. #>
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $p = $null
  try { $p = $Object.PSObject.Properties[$Name] } catch { return $null }
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Get-InitializeGuestFailure {
  <#
    Returns $null when guest\setup\Initialize-Guest.ps1 genuinely SUCCEEDED, and a sentence
    naming what went wrong otherwise.

    "Genuinely" is the load-bearing word. Three outcomes are all failures, and only one of them
    used to be even logged:
      * the script's output did not parse             -> we do not know what it did
      * it parsed but carries no ok field             -> we do not know what it did
      * it parsed and ok is false                     -> at least one baseline step failed
    A baseline step that failed is not cosmetic: if 'system-protection' did not apply, every
    restorePoint:"enforced" row on every cell built from this image aborts, and the orchestrator
    would record that abort as an ENGINE failure. Refusing here is the only place that
    misattribution can be prevented.
  #>
  param($Result)
  if ($null -eq $Result -or -not $Result.parsed) {
    return 'Initialize-Guest.ps1 did not return parseable JSON, so whether the guest baseline was applied is UNKNOWN. An unknown baseline is not an acceptable one: its raw output is in this document.'
  }
  $ok = Get-GuestProp -Object $Result.json -Name 'ok'
  if ($null -eq $ok) {
    return "Initialize-Guest.ps1 returned JSON with no 'ok' field, so whether the guest baseline was applied is UNKNOWN."
  }
  if ($ok -eq $true) { return $null }
  $failed = @()
  foreach ($s in @(Get-GuestProp -Object $Result.json -Name 'steps')) {
    if ($null -eq $s) { continue }
    if ((Get-GuestProp -Object $s -Name 'ok') -eq $true) { continue }
    $failed += "$(Get-GuestProp -Object $s -Name 'step'): $(Get-GuestProp -Object $s -Name 'detail')"
  }
  $detail = 'no step detail was returned'
  if ($failed.Count -gt 0) { $detail = ($failed -join ' | ') }
  return "Initialize-Guest.ps1 reported ok:false - the guest baseline did NOT fully apply ($detail). Provisioning stops here rather than producing an image whose failures would be scored against the engine."
}

# ---------------- VM construction ----------------

function New-CellVmObject {
  param([string]$VmName, [string]$VhdPath, [int64]$Startup, [int64]$Min, [int64]$Max, [int]$Cpu, $Defaults, [string]$VmPath)
  $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $Startup -VHDPath $VhdPath -Path $VmPath -ErrorAction Stop
  Set-VMProcessor -VMName $VmName -Count $Cpu -ErrorAction Stop
  Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes $Min -StartupBytes $Startup -MaximumBytes $Max -ErrorAction Stop
  # Standard checkpoints: they capture guest MEMORY, so Restore-VMCheckpoint returns a RUNNING
  # guest in seconds. Production checkpoints would restore to a powered-off VM and add a full
  # boot to every one of the matrix's rows. Automatic checkpoints off - they would silently
  # create a second checkpoint tree under the harness.
  Set-VM -Name $VmName -CheckpointType Standard -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -ErrorAction Stop
  Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate "$($Defaults.secureBootTemplate)" -ErrorAction Stop
  if ($Defaults.vTpm) {
    # Order matters: a key protector must exist before the vTPM can be enabled. -NewLocalKeyProtector
    # keeps the key on this host, which needs no Host Guardian Service.
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector -ErrorAction Stop
    Enable-VMTPM -VMName $VmName -ErrorAction Stop
  }
  try { Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction Stop } catch { Add-Log "Guest Service Interface could not be enabled: $($_.Exception.Message) (Copy-VMFile fallback will be unavailable; Copy-Item -ToSession is unaffected)." }
  $vm
}

function Set-CellNetwork {
  param([string]$VmName, [string]$Switch)
  if ($Switch) {
    $ad = @(Get-VMNetworkAdapter -VMName $VmName)
    if ($ad.Count -eq 0) { Add-VMNetworkAdapter -VMName $VmName -SwitchName $Switch -ErrorAction Stop }
    else { Connect-VMNetworkAdapter -VMName $VmName -SwitchName $Switch -ErrorAction Stop }
    Add-Log "Network adapter connected to switch '$Switch'."
  } else {
    foreach ($a in @(Get-VMNetworkAdapter -VMName $VmName)) { Remove-VMNetworkAdapter -VMNetworkAdapter $a -ErrorAction SilentlyContinue }
    Add-Log 'All virtual network adapters removed (deliberate - see the header).'
  }
}

# ---------------- main ----------------

$doc = $null
try {
  $matrix   = Get-Matrix
  $defaults = $matrix.defaults
  $cellDef  = Get-CellDef -Matrix $matrix -Id $Cell
  if (-not $VmRoot) { $VmRoot = "$($defaults.vmRoot)" }
  $baseRoot     = "$($defaults.baseRoot)"
  $diffRoot     = "$($defaults.diffRoot)"
  $isoRoot      = "$($defaults.isoRoot)"
  $unattendRoot = "$($defaults.unattendRoot)"
  $guestRoot    = "$($defaults.guestRoot)"

  $baseVhd = Join-Path $baseRoot ("$($cellDef.baseKey).vhdx")
  $cellVhd = Join-Path $diffRoot ("$($cellDef.id).vhdx")
  $vmName  = "$($cellDef.vmName)"
  if ($Role -eq 'base') { $vmName = "ffbase-$($cellDef.baseKey)" }
  if (-not $IsoPath) { $IsoPath = Join-Path $isoRoot "$($cellDef.iso.fileName)" }
  $unattendIso = Join-Path $unattendRoot ("$($cellDef.id)-unattend.iso")

  $pre = Get-HostPreflight -CellDef $cellDef -Defaults $defaults
  $osc = Resolve-Oscdimg

  $planDoc = [ordered]@{
    cell = "$($cellDef.id)"
    role = $Role
    vmName = $vmName
    vmPath = $VmRoot
    baseVhdx = $baseVhd
    cellVhdx = $cellVhd
    installIso = $IsoPath
    unattendIso = $unattendIso
    unattendTemplate = (Join-Path $PSScriptRoot "$($cellDef.unattend)")
    imageName = "$($cellDef.iso.imageName)"
    guestRoot = $guestRoot
    conditioning = @($cellDef.conditioning)
    checkpoint = "$($defaults.checkpointName)"
    generation = 2
    secureBoot = "$($defaults.secureBootTemplate)"
    vTpm = [bool]$defaults.vTpm
    processorCount = [int]$defaults.processorCount
    memory = [ordered]@{ startup = [int64]$defaults.memoryStartupBytes; minimum = [int64]$defaults.memoryMinimumBytes; maximum = [int64]$defaults.memoryMaximumBytes }
    osDiskBytes = [int64]$defaults.osDiskBytes
    network = $(if ($SwitchName) { "switch:$SwitchName" } else { 'none (deliberate)' })
    oscdimg = $osc
    preflight = $pre
  }

  if ($Plan) {
    $doc = [ordered]@{ ok = $true; action = 'new-test-vm'; mode = 'plan'; mutated = $false; plan = $planDoc
                       note = 'Plan only: nothing was created, no ISO was built, and Hyper-V was not touched. Re-run without -Plan to provision.' }
    Write-Doc $doc 0
  }

  # ---- gates (each refuses with a NAMED code; none of them guesses) ----
  if (-not $pre.isAdmin)        { Write-Doc (New-ErrorDoc 'needs-admin' 'Creating VMs, VHDXs and vTPM key protectors requires an elevated session.' @{ plan = $planDoc }) 2 }
  if (-not $pre.hyperVModule)   { Write-Doc (New-ErrorDoc 'hyperv-not-available' "The Hyper-V PowerShell module is not present (New-VM did not resolve). Enable the Hyper-V feature and REBOOT: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All" @{ plan = $planDoc }) 2 }
  if (-not $pre.architectureOk) { Write-Doc (New-ErrorDoc 'host-architecture-mismatch' "Cell '$($cellDef.id)' is $($cellDef.os.architecture) and this host is $($pre.hostArchitecture). Hyper-V does not emulate a foreign CPU architecture, so this cell cannot run here at all - it is skipped, never faked." @{ plan = $planDoc }) 3 }
  if (-not (Test-Path -LiteralPath $IsoPath) -and $Role -eq 'base') { Write-Doc (New-ErrorDoc 'iso-not-found' "The install ISO for this cell is not at $IsoPath. See tools/vmtest/README.md for where to get legitimate media." @{ plan = $planDoc }) 2 }

  if (-not $AdminPassword) {
    if ($env:FF_VMTEST_PASSWORD) { $AdminPassword = ConvertTo-SecureString $env:FF_VMTEST_PASSWORD -AsPlainText -Force; Add-Log 'Guest password taken from $env:FF_VMTEST_PASSWORD.' }
    else { Write-Doc (New-ErrorDoc 'no-password' 'Pass -AdminPassword (a SecureString) or set $env:FF_VMTEST_PASSWORD. There is deliberately no default: the harness will not invent a credential for a machine you then have to trust.' @{ plan = $planDoc }) 2 }
  }
  $cred = New-GuestCredential -CellDef $cellDef -Defaults $defaults -Secure $AdminPassword

  if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    if (-not $Force) { Write-Doc (New-ErrorDoc 'vm-exists' "A VM named '$vmName' already exists. Pass -Force to delete and rebuild it (its disks and checkpoints are destroyed)." @{ plan = $planDoc }) 2 }
    if ($PSCmdlet.ShouldProcess($vmName, 'Remove the existing VM and its differencing disk')) {
      Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
      Remove-VM -Name $vmName -Force -ErrorAction Stop
      Add-Log "Removed the pre-existing VM '$vmName'."
    }
  }

  $created = [ordered]@{}

  if ($Role -eq 'base') {
    if (-not $PSCmdlet.ShouldProcess($vmName, "Install Windows from $IsoPath onto a new base VHDX at $baseVhd")) { Write-Doc (New-ErrorDoc 'cancelled' 'Cancelled at the confirmation prompt.' @{ plan = $planDoc }) 4 }

    foreach ($d in @($VmRoot, $baseRoot, $isoRoot, $unattendRoot)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    if ((Test-Path -LiteralPath $baseVhd) -and -not $Force) { Write-Doc (New-ErrorDoc 'base-exists' "A base VHDX already exists at $baseVhd. Pass -Force to rebuild it - every differencing disk that points at it will be invalidated." @{ plan = $planDoc }) 2 }
    if (Test-Path -LiteralPath $baseVhd) { Set-ItemProperty -LiteralPath $baseVhd -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $baseVhd -Force }

    $plain = ConvertFrom-SecureStringPlain -Secure $AdminPassword
    $iso = New-UnattendIso -CellDef $cellDef -Defaults $defaults -PlainPassword $plain -OutIso $unattendIso
    $plain = $null
    $created.unattendIso = $iso
    Add-Log "Unattend ISO built by $($iso.builder) at $($iso.path)."

    $null = New-VHD -Path $baseVhd -SizeBytes ([int64]$defaults.osDiskBytes) -Dynamic -ErrorAction Stop
    Add-Log "Base VHDX created at $baseVhd."
    $null = New-CellVmObject -VmName $vmName -VhdPath $baseVhd -Startup ([int64]$defaults.memoryStartupBytes) -Min ([int64]$defaults.memoryMinimumBytes) -Max ([int64]$defaults.memoryMaximumBytes) -Cpu ([int]$defaults.processorCount) -Defaults $defaults -VmPath $VmRoot
    Set-CellNetwork -VmName $vmName -Switch $SwitchName

    Add-VMDvdDrive -VMName $vmName -Path $IsoPath -ErrorAction Stop
    Add-VMDvdDrive -VMName $vmName -Path $iso.path -ErrorAction Stop
    $installDvd = @(Get-VMDvdDrive -VMName $vmName | Where-Object { $_.Path -eq $IsoPath })[0]
    Set-VMFirmware -VMName $vmName -FirstBootDevice $installDvd -ErrorAction Stop
    Add-Log 'Install ISO and unattend ISO attached; the install ISO is first in the boot order.'

    Start-VM -Name $vmName -ErrorAction Stop
    Add-Log "VM started; waiting up to $InstallTimeoutMinutes minute(s) for Windows Setup to finish and PowerShell Direct to answer."
    $answer = Wait-PSDirect -VmName $vmName -Credential $cred -TimeoutMinutes $InstallTimeoutMinutes -What 'unattended install'
    if ($null -eq $answer) {
      Write-Doc (New-ErrorDoc 'install-timeout' "PowerShell Direct never answered within $InstallTimeoutMinutes minutes. Connect with VMConnect and look at where Setup stopped - the usual causes are a wrong /IMAGE/NAME (the edition is not in this ISO), a malformed autounattend.xml, or an ISO whose install.wim is actually install.esd." @{ plan = $planDoc; created = $created }) 5
    }
    if (-not $answer.provisioned) {
      Write-Doc (New-ErrorDoc 'provisioning-marker-missing' 'PowerShell Direct answered but C:\ffvmtest\provisioned.txt is absent, so the FirstLogonCommands did not all run. The install is NOT accepted as complete - a half-provisioned base would poison every cell built from it.' @{ plan = $planDoc; created = $created; guest = $answer }) 5
    }
    $created.guestMarker = "$($answer.marker)".Trim()
    Add-Log "Guest provisioned: $($created.guestMarker)"

    Copy-HarnessToGuest -VmName $vmName -Credential $cred -GuestRoot $guestRoot
    $init = Invoke-GuestScript -VmName $vmName -Credential $cred -ScriptPath (Join-Path $guestRoot 'guest\setup\Initialize-Guest.ps1')
    $created.initializeGuest = $init.json
    if (-not $init.parsed) { $created.initializeGuestRaw = $init.raw }
    # REFUSE, do not log-and-continue. The base VHDX is about to be frozen read-only and every
    # cell in this baseKey will be a differencing child of it, so a half-initialized base is
    # baked into every row that ever runs against it. In particular, if System Protection did
    # not come on, every restorePoint:"enforced" repair ABORTS - and Invoke-VmMatrix.ps1 would
    # score that abort against the ENGINE, which is exactly the misattribution matrix.json says
    # must never happen. An unusable base is a harness failure and is reported as one.
    $initFailure = Get-InitializeGuestFailure -Result $init
    if ($null -ne $initFailure) {
      Write-Doc (New-ErrorDoc 'guest-initialization-failed' $initFailure `
        @{ plan = $planDoc; created = $created; initializeGuest = $init.json; initializeGuestRaw = $init.raw }) 5
    }
    Add-Log 'Initialize-Guest.ps1 reported every baseline step succeeded.'

    # Eject the media before the base is frozen, or every differencing child inherits a DVD path
    # that may not exist later.
    foreach ($d in @(Get-VMDvdDrive -VMName $vmName)) { Remove-VMDvdDrive -VMDvdDrive $d -ErrorAction SilentlyContinue }
    Stop-VM -Name $vmName -Force -ErrorAction Stop
    Add-Log 'Guest shut down.'
    Remove-VM -Name $vmName -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $baseVhd -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
    Add-Log "Base VHDX frozen read-only at $baseVhd."

    if (-not $KeepUnattendIso) {
      try { Remove-Item -LiteralPath $iso.path -Force -ErrorAction Stop; Add-Log 'Unattend ISO deleted (it contained the guest password in clear text). Pass -KeepUnattendIso to keep it.' } catch {}
    }

    $doc = [ordered]@{ ok = $true; action = 'new-test-vm'; role = 'base'; cell = "$($cellDef.id)"; baseKey = "$($cellDef.baseKey)"
                       baseVhdx = $baseVhd; mutated = $true; created = $created; plan = $planDoc
                       next = "Now run: New-TestVm.ps1 -Cell $($cellDef.id) -Role cell" }
    Write-Doc $doc 0
  }

  # ---- Role: cell ----
  if (-not (Test-Path -LiteralPath $baseVhd)) {
    Write-Doc (New-ErrorDoc 'base-missing' "No base VHDX at $baseVhd. Build it first: New-TestVm.ps1 -Cell $($cellDef.id) -Role base" @{ plan = $planDoc }) 2
  }
  if (-not $PSCmdlet.ShouldProcess($vmName, "Create the cell VM with a differencing disk off $baseVhd and checkpoint it as '$($defaults.checkpointName)'")) {
    Write-Doc (New-ErrorDoc 'cancelled' 'Cancelled at the confirmation prompt.' @{ plan = $planDoc }) 4
  }

  foreach ($d in @($VmRoot, $diffRoot)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
  if (Test-Path -LiteralPath $cellVhd) {
    if (-not $Force) { Write-Doc (New-ErrorDoc 'cell-vhd-exists' "A differencing disk already exists at $cellVhd. Pass -Force to replace it." @{ plan = $planDoc }) 2 }
    Remove-Item -LiteralPath $cellVhd -Force
  }
  $null = New-VHD -Path $cellVhd -ParentPath $baseVhd -Differencing -ErrorAction Stop
  Add-Log "Differencing disk created at $cellVhd (parent $baseVhd)."
  $created.cellVhdx = $cellVhd

  $null = New-CellVmObject -VmName $vmName -VhdPath $cellVhd -Startup ([int64]$defaults.memoryStartupBytes) -Min ([int64]$defaults.memoryMinimumBytes) -Max ([int64]$defaults.memoryMaximumBytes) -Cpu ([int]$defaults.processorCount) -Defaults $defaults -VmPath $VmRoot
  Set-CellNetwork -VmName $vmName -Switch $SwitchName
  Start-VM -Name $vmName -ErrorAction Stop

  $answer = Wait-PSDirect -VmName $vmName -Credential $cred -TimeoutMinutes $BootTimeoutMinutes -What 'first boot of the cell'
  if ($null -eq $answer) {
    Write-Doc (New-ErrorDoc 'boot-timeout' "The cell booted from the base but PowerShell Direct never answered within $BootTimeoutMinutes minutes." @{ plan = $planDoc; created = $created }) 5
  }

  Copy-HarnessToGuest -VmName $vmName -Credential $cred -GuestRoot $guestRoot
  $conditioningResults = @()
  foreach ($c in @($cellDef.conditioning)) {
    $script = Join-Path $guestRoot "guest\faults\$c.ps1"
    Add-Log "Applying conditioning '$c'."
    $r = Invoke-GuestScript -VmName $vmName -Credential $cred -ScriptPath $script -Parameters @{ Action = 'inject' }
    $conditioningResults += [ordered]@{ id = $c; parsed = $r.parsed; result = $r.json; raw = $(if ($r.parsed) { $null } else { $r.raw }) }
    if (-not $r.parsed -or $r.json.injected -ne $true) {
      Write-Doc (New-ErrorDoc 'conditioning-failed' "Conditioning '$c' did not confirm itself as applied. The clean checkpoint was NOT taken - a cell whose baseline is not what the matrix says it is would make every row it runs meaningless." @{ plan = $planDoc; created = $created; conditioning = $conditioningResults }) 5
    }
  }
  $created.conditioning = $conditioningResults

  $baseline = Invoke-GuestScript -VmName $vmName -Credential $cred -ScriptPath (Join-Path $guestRoot 'guest\setup\Initialize-Guest.ps1')
  $created.initializeGuest = $baseline.json
  if (-not $baseline.parsed) { $created.initializeGuestRaw = $baseline.raw }
  # Same refusal as the base role, and for the same reason: the 'clean' checkpoint is what every
  # row restores, so a baseline that did not fully apply is not a checkpoint - it is a trap that
  # turns harness failures into engine verdicts. The checkpoint is NOT taken.
  $baselineFailure = Get-InitializeGuestFailure -Result $baseline
  if ($null -ne $baselineFailure) {
    Write-Doc (New-ErrorDoc 'guest-initialization-failed' "$baselineFailure The '$($defaults.checkpointName)' checkpoint was NOT taken." `
      @{ plan = $planDoc; created = $created; initializeGuest = $baseline.json; initializeGuestRaw = $baseline.raw }) 5
  }
  $created.environment = $baseline.json.environment
  Add-Log 'Initialize-Guest.ps1 reported every baseline step succeeded.'

  Checkpoint-VM -Name $vmName -SnapshotName "$($defaults.checkpointName)" -ErrorAction Stop
  Add-Log "Checkpoint '$($defaults.checkpointName)' taken. The orchestrator restores this before every row."

  $doc = [ordered]@{
    ok = $true; action = 'new-test-vm'; role = 'cell'; cell = "$($cellDef.id)"; vmName = $vmName
    mutated = $true; created = $created; plan = $planDoc
    guest = $answer
    next = "Now run: Invoke-VmMatrix.ps1 -Cells $($cellDef.id)"
    reminder = 'The VM is left RUNNING at the clean checkpoint. Invoke-VmMatrix.ps1 restores that checkpoint before every row, so nothing you do to the guest by hand survives a run.'
  }
  Write-Doc $doc 0

} catch {
  $doc = New-ErrorDoc 'unhandled' "$($_.Exception.Message)" @{ scriptStackTrace = "$($_.ScriptStackTrace)" }
  Write-Doc $doc 1
}
