<#
  FrameForge VM test harness :: guest\setup\Initialize-Guest.ps1
  Runs ONCE inside a freshly installed cell, before the 'clean' checkpoint is taken.
  Everything it does is part of the cell's baseline, so it must be the minimum that makes the
  matrix runnable - anything more starts changing the thing under test.

  THE BOOTSTRAP ORDER, AND THE CIRCULARITY THAT USED TO BE IN IT
  --------------------------------------------------------------
  This script used to set LocalAccountTokenFilterPolicy=1 as its step 4, AFTER two steps that
  need an elevated token (Set-ExecutionPolicy -Scope LocalMachine and Enable-ComputerRestore are
  both HKLM writes) - while Invoke-VmMatrix.ps1 documents that value as the very thing that makes
  the PowerShell Direct token unfiltered. On the harness's own stated premise that was not merely
  out of order, it was impossible: writing the policy value is ITSELF an HKLM write, so the script
  could never have granted itself the privilege it needed in order to grant itself that privilege.
  Either it had never completed a first run, or the premise was wrong.

  RESOLVED, in the direction that holds under EITHER reading: the policy is now set in the
  unattend, by a RunSynchronousCommand in the specialize pass, which runs as LOCAL SYSTEM before
  any user logs on and long before PowerShell Direct is used. See the comment in
  tools/vmtest/unattend/Win11-x64-en-US.xml. This script no longer sets it. It MEASURES its own
  token first and refuses if that token is filtered, and it VERIFIES the policy value rather than
  assuming a write took effect - so a base image built from an older template fails loudly here
  instead of producing cells whose every elevated row looks like an engine failure.

  WHAT IT DOES, AND WHY EACH ONE IS JUSTIFIED
    0. MEASURES its own token. Every step below needs elevation, so an unelevated session must
       stop and say so once, rather than report several separate mysterious failures.
    1. Working directories. Trivial.
    2. Execution policy RemoteSigned (LocalMachine). The copied-in engine and fault scripts are
       unsigned files on a local disk; without this nothing runs.
    3. ENABLES SYSTEM PROTECTION on C: and sets a restore-point size cap. This one is not
       cosmetic: repairs whose catalog entry says restorePoint:"enforced" (wu-reset-aggressive,
       store-reregister-all, chkdsk-full-repair, component-cleanup-resetbase, winsock-reset)
       create a System Restore checkpoint as their FIRST step and ABORT if they cannot. System
       Protection is OFF on a fresh Windows 11 image, so without this every aggressive row would
       abort - and the abort would be a harness artefact being scored as an engine failure.
       It also matches what a real user machine looks like.
    4. VERIFIES LocalAccountTokenFilterPolicy (see above). Reported as measured, never assumed,
       and never set from here on the token it would itself have needed.
    5. Records an ENVIRONMENT FINGERPRINT: build, UBR, edition, system UI language, user locale,
       console code pages, PowerShell version, whether the machine is domain-joined, and whether
       an update policy is present. The orchestrator stores this next to the results so every
       verdict says which Windows it was reached on - and so the locale cells can be diffed
       against the control cell.

  WHAT IT DELIBERATELY DOES NOT DO
    * `powercfg /h off` - Fast Startup availability is a signal health.ps1 measures.
    * Disable Windows Update, Defender, or any service - the cells have no network adapter
      attached, which is how determinism is achieved without changing configuration.
    * Install anything.

  Emits ONE JSON document. PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
  [string]$GuestRoot = 'C:\ffvmtest',
  [switch]$SkipSystemProtection
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$steps = @()
$ok = $true

function Add-Step { param([string]$Name, [bool]$Success, [string]$Detail) $script:steps += [ordered]@{ step = $Name; ok = $Success; detail = $Detail }; if (-not $Success) { $script:ok = $false } }

# 0) elevation - MEASURED, not assumed, and measured FIRST
# Every step below writes to HKLM or drives a system service. A filtered token makes all of them
# fail for one reason, and reporting that reason once is the difference between "the harness is
# misconfigured" and four unrelated-looking errors. The value that prevents the filtering is set
# by the unattend's specialize pass, as LOCAL SYSTEM, before any logon - see the file header.
$isElevated = $null
try {
  $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isElevated = $null }
if ($isElevated -eq $true) {
  Add-Step 'elevation' $true 'This session holds an elevated token, so the baseline steps below can be applied.'
} elseif ($isElevated -eq $false) {
  Add-Step 'elevation' $false 'This session is NOT elevated. Over PowerShell Direct that means the local account''s token was UAC-filtered: LocalAccountTokenFilterPolicy is not 1 on this image. It is set by the unattend''s specialize pass (as LOCAL SYSTEM, before first logon) - a base VHDX built from an older unattend template does not have it, and must be rebuilt. Nothing below was attempted, because all of it would fail for this one reason.'
} else {
  Add-Step 'elevation' $false 'Whether this session is elevated could NOT be determined, so no baseline step is attempted. An unknown token is not an acceptable basis for a cell every later verdict is read from.'
}

if ($isElevated -ne $true) {
  # Refuse. New-TestVm.ps1 treats ok:false as a hard stop and will not freeze the base VHDX or
  # take the 'clean' checkpoint, which is exactly right: a cell whose baseline did not apply turns
  # harness failures into engine verdicts.
  $doc = [ordered]@{
    ok = $false
    action = 'initialize-guest'
    ranAt = (Get-Date).ToString('s')
    computer = "$env:COMPUTERNAME"
    guestRoot = $GuestRoot
    steps = @($steps)
    environment = $null
    note = 'Refused before making any change. The guest baseline requires an elevated PowerShell Direct session; see the step detail.'
  }
  [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 8 -Compress))
  exit 1
}

# 1) directories
try {
  foreach ($d in @($GuestRoot, (Join-Path $GuestRoot 'ff'), (Join-Path $GuestRoot 'guest'), (Join-Path $GuestRoot 'guest\faults'), (Join-Path $GuestRoot 'state'), (Join-Path $GuestRoot 'out'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
  Add-Step 'directories' $true "Created under $GuestRoot."
} catch { Add-Step 'directories' $false "$($_.Exception.Message)" }

# 2) execution policy
try {
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
  Add-Step 'execution-policy' $true "LocalMachine = $(Get-ExecutionPolicy -Scope LocalMachine)."
} catch { Add-Step 'execution-policy' $false "$($_.Exception.Message)" }

# 3) System Protection
if ($SkipSystemProtection) {
  Add-Step 'system-protection' $true 'Skipped by -SkipSystemProtection. Every restorePoint:"enforced" repair will ABORT on this cell; that is a harness choice, not an engine failure, and the results must say so.'
} else {
  try {
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
    # 5% cap: enough for the checkpoints the aggressive repairs create, small enough not to eat
    # the differencing disk.
    $null = & "$env:SystemRoot\System32\vssadmin.exe" resize shadowstorage /for=C: /on=C: /maxsize=5%
    $enabled = $null
    try { $enabled = [bool](Get-CimInstance -Namespace 'root\default' -ClassName SystemRestore -ErrorAction Stop) } catch {}
    Add-Step 'system-protection' $true "Enabled on C: (shadow storage capped at 5%). SystemRestore class readable: $enabled."
  } catch { Add-Step 'system-protection' $false "System Protection could NOT be enabled: $($_.Exception.Message). Every restorePoint:'enforced' repair will abort on this cell." }
}

# 4) LocalAccountTokenFilterPolicy - VERIFIED, NOT SET
# PowerShell Direct authenticates a LOCAL account, and a non-RID-500 local admin reaching a machine
# non-interactively gets a UAC-FILTERED token. Without this value the harness's session is a member
# of Administrators but holds no elevated token, so every elevated probe in health.ps1 degrades to
# status 'needs-admin' and every mutating repair refuses - and the whole matrix would look like an
# engine failure when it is really a logon-token artefact of the harness.
#
# It is set by the unattend's specialize pass, as LOCAL SYSTEM, before first logon. Setting it HERE
# was circular: this script only runs over the very session the value exists to unfilter, and the
# write itself needs the token it would have been granting. Step 0 above has already proved the
# token is unfiltered, so this step's job is to say WHY - by reading the value back rather than
# inferring it from the fact that things worked.
#
# This is the ONE security-relevant setting the harness changes. It is documented here, in the
# unattend templates and in the README, and it applies only to throwaway VMs built with no network
# adapter attached.
try {
  $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  $value = $null
  try { $value = (Get-ItemProperty -LiteralPath $polKey -Name 'LocalAccountTokenFilterPolicy' -ErrorAction Stop).LocalAccountTokenFilterPolicy } catch { $value = $null }
  if ($null -eq $value) {
    # The token IS unfiltered (step 0 measured that), yet the value is absent. Both facts are
    # reported; neither is explained away. Whatever grants the elevation here, it is not the
    # documented mechanism, and a harness that quietly accepts that has stopped measuring.
    Add-Step 'local-account-token-filter-policy' $false 'The session is elevated, but LocalAccountTokenFilterPolicy is ABSENT from HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System. The unattend''s specialize pass is supposed to set it to 1 before first logon. Either this base VHDX predates that template, or the RunSynchronousCommand did not run - and in either case the elevation this cell depends on is not resting on the documented mechanism. Rebuild the base from the current unattend rather than trusting this one.'
  } elseif ([int]$value -eq 1) {
    Add-Step 'local-account-token-filter-policy' $true 'Read back as 1, set by the unattend''s specialize pass before first logon. That is what makes this PowerShell Direct session hold an unfiltered token.'
  } else {
    Add-Step 'local-account-token-filter-policy' $false "LocalAccountTokenFilterPolicy is $value, not 1. PowerShell Direct sessions on this image get a filtered token, so every elevated probe would report needs-admin and every mutating repair would refuse. Rebuild the base from the current unattend."
  }
} catch { Add-Step 'local-account-token-filter-policy' $false "The policy value could not be READ, so whether this cell's elevation rests on the documented mechanism is unknown: $($_.Exception.Message)" }

# 5) environment fingerprint - structural reads only
$env_ = [ordered]@{}
try {
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
  $env_.build = "$($cv.CurrentBuildNumber)"
  $env_.ubr = "$($cv.UBR)"
  $env_.displayVersion = "$($cv.DisplayVersion)"
  $env_.editionId = "$($cv.EditionID)"
  $env_.productName = "$($cv.ProductName)"
  $env_.productNameNote = 'ProductName famously still reads "Windows 10 Pro" on Windows 11; CurrentBuildNumber is the authority.'
} catch { $env_.buildReadError = "$($_.Exception.Message)" }
try {
  $env_.installLanguageHex = "$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name InstallLanguage -ErrorAction Stop).InstallLanguage)"
} catch {}
try { $env_.installedUICulture = [System.Globalization.CultureInfo]::InstalledUICulture.Name } catch {}
try { $env_.currentCulture     = [System.Globalization.CultureInfo]::CurrentCulture.Name } catch {}
try { $env_.consoleOutputCodePage = [Console]::OutputEncoding.CodePage } catch {}
try { $env_.oemCodePage = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP -ErrorAction Stop).OEMCP } catch {}
try { $env_.acp         = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name ACP   -ErrorAction Stop).ACP } catch {}
try {
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $env_.partOfDomain = [bool]$cs.PartOfDomain
  $env_.domain = "$($cs.Domain)"
  $env_.systemType = "$($cs.SystemType)"
} catch {}
try { $env_.osArchitecture = "$env:PROCESSOR_ARCHITECTURE" } catch {}
try { $env_.psVersion = "$($PSVersionTable.PSVersion)" } catch {}
try { $env_.wuPolicyPresent = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate') } catch { $env_.wuPolicyPresent = $null }
try { $env_.licenseStatus = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop | ForEach-Object { [int]$_.LicenseStatus }) } catch { $env_.licenseStatus = $null }
try { $env_.batteryCount = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count } catch { $env_.batteryCount = $null }
$env_.batteryNote = 'Expected 0 in Hyper-V: there is no emulated battery. Any check that reads "no battery therefore not on battery therefore fine" produces a FALSE PASS here and cannot be covered by this harness. See matrix.json / nonVirtualisableCells / laptop-battery.'

$doc = [ordered]@{
  ok = $ok
  action = 'initialize-guest'
  ranAt = (Get-Date).ToString('s')
  computer = "$env:COMPUTERNAME"
  guestRoot = $GuestRoot
  steps = @($steps)
  environment = $env_
  note = 'This runs once per cell before the clean checkpoint. Everything it changes is part of the cell baseline and is documented in the script header.'
}
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 8 -Compress))
if ($ok) { exit 0 } else { exit 1 }
