<#
  FrameForge :: image.ps1
  Fresh-image repair engine: reinstall a fresh Windows image over a broken one
  without losing files, apps, or settings. Implements the full flow from
  docs/research/fresh-image-repair.md:

    detect              What identity must the media match? (edition/lang/build/arch)
                        plus safety-rail status. Read-only.
    validate            Mount an ISO, inventory install.wim/esd, verdict on whether
                        it can repair THIS machine. Read-only (mount/dismount only).
    acquire-url         Step 1 of the acquisition ladder: fetch Fido.ps1 from the
                        official pbatard/Fido GitHub (SHA-256 recorded, HTTPS only,
                        run out-of-process) and ask Microsoft's own servers for a
                        direct, ~24h-valid ISO URL. Falls back to MCT/manual as a
                        structured result - never crashes. Does NOT download the ISO.
    download            BITS transfer of a given URL to a destination + SHA-256.
    dism-source-repair  The lighter rung: use the ISO's install.wim/esd as an
                        offline DISM /RestoreHealth source (/LimitAccess). Admin.
    consent             Return the consent contract on its own (rails + the exact
                        commands that will pass /eula accept), so the UI can collect
                        acceptance BEFORE anything runs. Read-only.
    preflight           Full safety rails + setup.exe /compat scanonly (exit-code
                        translated). The compat scan is Windows Setup itself and it
                        REQUIRES /eula accept, so it is gated behind -AcceptEula
                        exactly like launch is gated behind -Confirm. Admin.
    launch              Construct the in-place repair command. Without -Confirm it
                        only returns the exact command + a consent contract for the
                        UI. With -Confirm AND admin AND green rails it starts
                        setup.exe (consent-gated handoff - doctrine rule 3).
    verify              Post-repair check against the ledger written at launch. Reads
                        SetupDiag's actual results (XML + HKLM\SYSTEM\Setup\SetupDiag\
                        Results) and names the cause, rather than only noting that a
                        results file exists. NOT scheduled automatically after the
                        upgrade restarts - see the `scheduling` block it returns.

  EULA HONESTY: two commands here pass '/eula accept' to Windows Setup - preflight's
  compat scan and launch's upgrade. BOTH are consent-gated (-AcceptEula and -Confirm
  respectively) and the consent contract says so. The contract used to claim nothing
  passes it until you consent, while preflight passed it unprompted one step earlier;
  that contradiction is gone.

  Output: exactly ONE JSON document on stdout (house style; -Json accepted for
  interface symmetry) - including for invalid input, which is why -Action is validated
  in the body rather than with [ValidateSet] (a parameter-binding failure would exit
  with no JSON at all and break the one-document contract the Electron host relies on).
  The whole action dispatch runs inside a try/catch for the same reason.
  PowerShell 5.1 compatible. UTF-8 with BOM.

  Exit codes:
    0  a valid result document was produced (including honest structured
       fallbacks such as acquire-url's "use MCT instead" and consent-contract mode)
    2  invalid input (unknown action, missing/unknown ISO path, missing required parameter)
    3  refused: an action that was going to DO something declined to. Specifically:
         acquire-url  without -ConsentRunFido, or the pinned -FidoSha256 did not match
         preflight    the compat scan was refused for missing EULA consent, or (with
                      consent given) for want of administrator rights
         launch       -Confirm given but admin / setup.exe / media / rails are not green
       Note preflight still exits 0 when it RAN its scan and merely reports red rails or
       incompatible media: that is a successful pre-flight delivering a "no" answer, and
       readyToLaunch:false is where that lives.
    1  an unexpected error - still emitted as a JSON error document

  Nothing here mutates the system except the explicitly consent-gated actions:
  dism-source-repair (repairs the component store; admin, -DryRun available),
  preflight's compat scan (non-destructive but writes setup logs; -AcceptEula + admin),
  acquire-url's Fido fetch/run (-ConsentRunFido), and launch (only with -Confirm).
  detect/consent/validate/verify are read-only.
#>
[CmdletBinding()]
param(
  # NOTE: deliberately NOT [ValidateSet] - see the EULA/output notes above. Validated in
  # the body so an unknown action still returns exactly one JSON document.
  [Parameter(Position = 0)]
  [string]$Action = 'detect',
  [string]$IsoPath,
  [string]$SourcePath,      # already-extracted media folder (contains sources\install.wim|esd) as an alternative to -IsoPath
  [string]$Url,             # download: source URL (from acquire-url)
  [string]$Dest,            # download: destination file path
  # [string], not [int], for the same reason -Action is not [ValidateSet]: a parameter
  # binding failure ("-Index abc") would exit with no JSON at all. Parsed in the body.
  [string]$Index = '0',     # optional explicit image-index override for validate/dism-source-repair
  [switch]$Json,            # accepted for symmetry; output is always JSON
  [switch]$DryRun,          # heavy actions: report the exact command(s) without running them
  [switch]$AcceptEula,      # preflight: the user has accepted the Microsoft Software License Terms in the UI
  [switch]$Confirm,         # launch: the explicit consent gate - without it nothing starts
  [switch]$ConsentRunFido,  # acquire-url: consent to fetch and run the third-party Fido script
  [string]$FidoSha256,      # acquire-url: pin an expected SHA-256; a mismatch refuses to run the script
  [switch]$SuspendBitLocker # launch: also Suspend-BitLocker -RebootCount 3 before setup
)
$ValidActions = @('detect','consent','validate','acquire-url','download','dism-source-repair','preflight','launch','verify')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot '_lib.ps1')
$IsAdmin = Test-Admin

$DataDir     = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
$StateDir    = Join-Path $DataDir 'state'
$ToolsDir    = Join-Path $StateDir 'tools'
$LedgerPath  = Join-Path $StateDir 'image-repair-ledger.json'
$SetupLogDir = Join-Path $StateDir 'setup-logs'

$MinFreeGB = 30   # research doc: Microsoft floor is 20 GB; enforce 30 to cover ISO + working set

# Official Fido locations (pbatard/Fido, GPLv3; fetched at runtime and run
# out-of-process so the GPL script never links into the app). HTTPS only.
$FidoPrimaryUrl  = 'https://github.com/pbatard/Fido/releases/latest/download/Fido.ps1'
$FidoFallbackUrl = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
$ManualDownloadUrl = 'https://www.microsoft.com/software-download/windows11'

# ---------------- identity detection ----------------

function Get-FFUiLanguage {
  <#
    System DEFAULT UI language - the value the media language must match exactly
    (strict since Win11 22H2). Ladder:
      1. dism /online /Get-Intl (authoritative; needs admin; parse is English-locale
         only, so on localized systems it falls through)
      2. HKLM Nls\Language InstallLanguage (hex LCID -> culture tag)
      3. [CultureInfo]::InstalledUICulture
  #>
  if ($IsAdmin) {
    try {
      $raw = & "$env:SystemRoot\System32\Dism.exe" /Online /Get-Intl 2>&1
      $txt = (((@($raw) | ForEach-Object { "$_" }) -join "`n") -replace "`0", '')
      if ($txt -match 'Default system UI language\s*:\s*([A-Za-z]{2,3}(?:-[A-Za-z0-9]+){0,2})') {
        return [ordered]@{ tag = $Matches[1]; source = 'dism-get-intl' }
      }
    } catch {}
  }
  try {
    $hex = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name InstallLanguage -ErrorAction Stop).InstallLanguage
    $ci = [System.Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($hex, 16))
    return [ordered]@{ tag = $ci.Name; source = 'registry-installlanguage' }
  } catch {}
  try {
    return [ordered]@{ tag = [System.Globalization.CultureInfo]::InstalledUICulture.Name; source = 'installed-ui-culture' }
  } catch {}
  [ordered]@{ tag = $null; source = 'unknown' }
}

function Get-FFOsIdentity {
  $cv = $null
  try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch {}
  $build = $null; $ubr = $null
  if ($cv) {
    try { $build = [int]$cv.CurrentBuildNumber } catch {}
    try { $ubr = [int]$cv.UBR } catch {}
  }
  $arch = 'unknown'
  switch -Regex ("$env:PROCESSOR_ARCHITECTURE") {
    '^AMD64$' { $arch = 'x64' }
    '^ARM64$' { $arch = 'arm64' }
    '^x86$'   { $arch = 'x86' }
  }
  $buildString = $null
  if ($null -ne $build) {
    if ($null -ne $ubr) { $buildString = "$build.$ubr" } else { $buildString = "$build" }
  }
  [ordered]@{
    editionId      = "$(if ($cv) { $cv.EditionID })"
    productName    = "$(if ($cv) { $cv.ProductName })"
    displayVersion = "$(if ($cv) { $cv.DisplayVersion })"
    currentBuild   = $build
    ubr            = $ubr
    buildString    = $buildString
    architecture   = $arch
    language       = (Get-FFUiLanguage)
  }
}

# ---------------- safety rails ----------------

function Test-FFPendingReboot {
  <#
    The triple check (same signals health.ps1 uses), reported so the output explains
    itself. The old shape returned pendingFileRenames:true alongside any:false, which
    reads as a flat self-contradiction in any UI that renders it - the reasoning lived
    only in a source comment. There is no 'any' field now: 'blocksSetup' says exactly
    what the rail means, and 'explanation' says why.
  #>
  $pr = [ordered]@{
    cbsRebootPending    = $false
    wuRebootRequired    = $false
    pendingFileRenames  = $false
    anySignalPresent    = $false   # literally "is any of the three set"
    blocksSetup         = $false   # the rail: would Windows Setup refuse with 0xC1900107
    explanation         = $null
  }
  try { $pr.cbsRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' } catch {}
  try { $pr.wuRebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' } catch {}
  try {
    $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    $pr.pendingFileRenames = ($null -ne $v.PendingFileRenameOperations -and @($v.PendingFileRenameOperations).Count -gt 0)
  } catch {}
  $pr.anySignalPresent = ($pr.cbsRebootPending -or $pr.wuRebootRequired -or $pr.pendingFileRenames)
  # Setup 0xC1900107 is triggered by servicing/WU pendings. PendingFileRenameOperations
  # alone is common and benign - ordinary installers and updaters set it constantly - so
  # it is reported but does NOT turn the rail red by itself.
  $pr.blocksSetup = ($pr.cbsRebootPending -or $pr.wuRebootRequired)
  $blockers = @()
  if ($pr.cbsRebootPending) { $blockers += 'component servicing (CBS RebootPending)' }
  if ($pr.wuRebootRequired) { $blockers += 'Windows Update (RebootRequired)' }
  if ($pr.blocksSetup) {
    $pr.explanation = "A restart is pending from $($blockers -join ' and '). Windows Setup refuses to start with 0xC1900107 while that is true - restart the PC first."
  } elseif ($pr.pendingFileRenames) {
    $pr.explanation = 'PendingFileRenameOperations is set, but nothing here blocks Windows Setup. That value is written by ordinary installers to finish moving files at the next boot; only the component-servicing and Windows Update pending-reboot signals cause setup error 0xC1900107. Reported for completeness, deliberately not treated as a blocker.'
  } else {
    $pr.explanation = 'No pending restart of any kind. Windows Setup will not hit 0xC1900107.'
  }
  $pr
}

function Get-FFPowerStatus {
  $out = [ordered]@{ lineStatus = 'unknown'; onAc = $false; batteryPresent = $null; note = $null }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $out.lineStatus = "$($ps.PowerLineStatus)"
    $out.onAc = ($out.lineStatus -eq 'Online')
    $out.batteryPresent = ("$($ps.BatteryChargeStatus)" -notmatch 'NoSystemBattery')
    if (-not $out.batteryPresent) { $out.note = 'Desktop (no system battery) - AC rail passes trivially.' }
  } catch {
    $out.note = "Power status could not be read: $($_.Exception.Message)"
  }
  $out
}

function Get-FFBitLockerStatus {
  <#
    BitLocker on the system drive + whether a numeric RecoveryPassword protector
    exists (the thing the user must be able to produce if a recovery prompt ever
    appears after the upgrade's reboots). Needs admin; degrades honestly.
  #>
  $out = [ordered]@{ status = 'unknown'; volumeStatus = $null; protectionStatus = $null; recoveryPasswordProtector = $null; keyProtectorTypes = @(); note = $null }
  try {
    $bv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $out.status = 'checked'
    $out.volumeStatus = "$($bv.VolumeStatus)"
    $out.protectionStatus = "$($bv.ProtectionStatus)"
    $out.keyProtectorTypes = @($bv.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
    $out.recoveryPasswordProtector = (@($out.keyProtectorTypes | Where-Object { $_ -eq 'RecoveryPassword' }).Count -gt 0)
    if ($out.protectionStatus -eq 'On' -and -not $out.recoveryPasswordProtector) {
      $out.note = 'BitLocker is on but no numeric recovery-password protector exists - the user must confirm access to a recovery key (aka.ms/myrecoverykey) before an in-place repair.'
    }
  } catch {
    if (-not $IsAdmin) {
      $out.status = 'needs-admin'
      $out.note = 'BitLocker state requires administrator rights to read.'
    } else {
      $out.status = 'error'
      $out.note = "BitLocker query failed: $($_.Exception.Message)"
    }
  }
  $out
}

function Get-FFRails {
  $sysDrive = "$env:SystemDrive"
  $freeGB = $null
  try {
    $d = Get-PSDrive -Name ($sysDrive.TrimEnd(':')) -ErrorAction Stop
    $freeGB = [math]::Round($d.Free / 1GB, 1)
  } catch {}
  $power = Get-FFPowerStatus
  $bitlocker = Get-FFBitLockerStatus
  $pending = Test-FFPendingReboot
  $diskOk = ($null -ne $freeGB -and $freeGB -ge $MinFreeGB)
  # BitLocker only blocks when protection is ON and no recovery-password protector
  # exists; 'needs-admin' means the rail is UNKNOWN, not green - callers that
  # execute must treat unknown as red.
  $blBlocking = $false; $blKnown = $true
  if ($bitlocker.status -eq 'checked') {
    if ($bitlocker.protectionStatus -eq 'On' -and -not $bitlocker.recoveryPasswordProtector) { $blBlocking = $true }
  } else {
    $blKnown = $false
  }
  [ordered]@{
    systemDrive           = $sysDrive
    freeSystemDriveGB     = $freeGB
    minRequiredGB         = $MinFreeGB
    diskOk                = $diskOk
    power                 = $power
    bitlocker             = $bitlocker
    bitlockerKnown        = $blKnown
    bitlockerBlocking     = $blBlocking
    pendingReboot         = $pending
  }
}

function Test-FFRailsGreen {
  # Strict: every rail must be affirmatively green (unknown = red) - used only by
  # execute paths. Reporting paths surface the individual rails instead.
  param($Rails)
  $reasons = @()
  if (-not $Rails.diskOk) { $reasons += "Free space on $($Rails.systemDrive) is $($Rails.freeSystemDriveGB) GB; at least $MinFreeGB GB is required." }
  if (-not $Rails.power.onAc) { $reasons += "Not on AC power (line status: $($Rails.power.lineStatus))." }
  if ($Rails.pendingReboot.blocksSetup) { $reasons += "$($Rails.pendingReboot.explanation)" }
  if (-not $Rails.bitlockerKnown) { $reasons += "BitLocker state is unknown ($($Rails.bitlocker.status)) - it must be verified before launch." }
  if ($Rails.bitlockerBlocking) { $reasons += 'BitLocker protection is on with no recovery-password protector - confirm recovery-key access first.' }
  [ordered]@{ green = ($reasons.Count -eq 0); reasons = $reasons }
}

# ---------------- media handling ----------------

function Resolve-FFMedia {
  <#
    Turns -IsoPath (mounted via Mount-DiskImage) or -SourcePath (already-extracted
    folder) into @{ ok; error; errorCode; root; imageFile; kind; mountedByUs; isoPath }.
    kind is 'wim' or 'esd'. Caller MUST pass the result to Complete-FFMedia when done.
  #>
  param([string]$Iso, [string]$Source)
  $out = [ordered]@{ ok = $false; error = $null; errorCode = $null; root = $null; imageFile = $null; kind = $null; mountedByUs = $false; isoPath = $null }
  if (-not $Iso -and -not $Source) {
    $out.error = 'No media given: pass -IsoPath <file.iso> or -SourcePath <extracted media folder>.'
    $out.errorCode = 'no-media-param'
    return $out
  }
  if ($Source) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
      $out.error = "SourcePath not found or not a folder: $Source"
      $out.errorCode = 'source-not-found'
      return $out
    }
    $out.root = (Resolve-Path -LiteralPath $Source).Path
  } else {
    if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
      $out.error = "ISO file not found: $Iso"
      $out.errorCode = 'iso-not-found'
      return $out
    }
    $abs = (Resolve-Path -LiteralPath $Iso).Path
    $out.isoPath = $abs
    $wasAttached = $false
    try {
      $pre = Get-DiskImage -ImagePath $abs -ErrorAction Stop
      $wasAttached = [bool]$pre.Attached
    } catch {}
    try {
      $null = Mount-DiskImage -ImagePath $abs -PassThru -ErrorAction Stop
      $out.mountedByUs = (-not $wasAttached)
    } catch {
      $out.error = "Could not mount the ISO: $($_.Exception.Message)"
      $out.errorCode = 'mount-failed'
      return $out
    }
    # The volume can take a moment to surface after mounting.
    $letter = $null
    for ($i = 0; $i -lt 10 -and -not $letter; $i++) {
      try {
        $vol = Get-DiskImage -ImagePath $abs -ErrorAction Stop | Get-Volume -ErrorAction Stop
        if ($vol -and $vol.DriveLetter) { $letter = "$($vol.DriveLetter)" }
      } catch {}
      if (-not $letter) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $letter) {
      if ($out.mountedByUs) { try { Dismount-DiskImage -ImagePath $abs -ErrorAction Stop | Out-Null } catch {} }
      $out.mountedByUs = $false
      $out.error = 'The ISO mounted but no drive letter appeared for it.'
      $out.errorCode = 'no-drive-letter'
      return $out
    }
    $out.root = "$letter`:"
  }
  foreach ($cand in @('install.wim', 'install.esd')) {
    $p = Join-Path (Join-Path $out.root 'sources') $cand
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $out.imageFile = $p
      $out.kind = [System.IO.Path]::GetExtension($cand).TrimStart('.')
      break
    }
  }
  if (-not $out.imageFile) {
    $out.error = "No sources\install.wim or sources\install.esd under '$($out.root)' - this is not Windows install media."
    $out.errorCode = 'not-windows-media'
    Complete-FFMedia $out
    return $out
  }
  $out.ok = $true
  $out
}

function Complete-FFMedia {
  param($Media)
  if ($Media -and $Media.mountedByUs -and $Media.isoPath) {
    try { Dismount-DiskImage -ImagePath $Media.isoPath -ErrorAction Stop | Out-Null } catch {}
    $Media.mountedByUs = $false
  }
}

function Convert-FFImageArch {
  # Get-WindowsImage Architecture arrives as an int (0/5/9/12) or a display string.
  param($Value)
  $s = "$Value"
  switch -Regex ($s) {
    '^(9|x64|AMD64)$'  { return 'x64' }
    '^(12|ARM64)$'     { return 'arm64' }
    '^(0|x86)$'        { return 'x86' }
    '^(5|ARM)$'        { return 'arm' }
  }
  if ($s) { return $s.ToLowerInvariant() }
  $null
}

function Get-FFMediaInventory {
  <#
    Per-index inventory of an install.wim/esd. The bare listing gives index+name;
    edition/version/languages/arch need a per-index query. One broken index must
    not break the inventory (detailError is recorded instead).
  #>
  param([string]$ImageFile)
  $rows = @()
  $list = @(Get-WindowsImage -ImagePath $ImageFile -ErrorAction Stop)
  foreach ($e in $list) {
    $row = [ordered]@{
      index = [int]$e.ImageIndex; name = "$($e.ImageName)"
      editionId = $null; version = $null; build = $null; ubr = $null
      languages = @(); architecture = $null; detailError = $null
    }
    try {
      $d = Get-WindowsImage -ImagePath $ImageFile -Index $row.index -ErrorAction Stop
      $row.editionId = "$($d.EditionId)"
      $row.version = "$($d.Version)"
      $row.languages = @(@($d.Languages) | ForEach-Object { "$_" })
      $row.architecture = Convert-FFImageArch $d.Architecture
      # Version is 10.0.<build>[.<ubr>]; WIM metadata may carry the UBR in SPBuild.
      $parts = @("$($d.Version)" -split '\.')
      if ($parts.Count -ge 3) { try { $row.build = [int]$parts[2] } catch {} }
      if ($parts.Count -ge 4) { try { $row.ubr = [int]$parts[3] } catch {} }
      if ($null -eq $row.ubr -and $null -ne $d.SPBuild) { try { $row.ubr = [int]$d.SPBuild } catch {} }
    } catch {
      $row.detailError = "$($_.Exception.Message)"
    }
    $rows += $row
  }
  $rows
}

function Compare-FFMediaToOs {
  <#
    The matching rules from the research doc (§4), in order of how a human would
    reason about them:
      1. edition   - exact EditionID match against an image index
      2. language  - STRICT since 22H2: the system default UI language must be in
                     the image's language list (even en-US vs en-GB fails)
      3. arch      - x64 media on x64
      4. build     - same-or-newer than the installed build; older is refused for
                     repair-upgrade AND useless as a DISM source (0x800f081f)
    Returns @{ compatible; reasons[]; checks[]; selectedIndex; imageInfo; notes[] }.
  #>
  param($Os, $Rows, [int]$ForceIndex = 0)
  $reasons = @(); $checks = @(); $notes = @()
  $selected = $null

  if ($ForceIndex -gt 0) {
    $selected = @($Rows | Where-Object { $_.index -eq $ForceIndex }) | Select-Object -First 1
    if ($null -eq $selected) {
      $reasons += "Requested index $ForceIndex does not exist on the media (indices: $(@($Rows | ForEach-Object { $_.index }) -join ', '))."
    } else {
      $notes += "Index $ForceIndex was explicitly requested; edition auto-matching was bypassed."
    }
  } else {
    $selected = @($Rows | Where-Object { $_.editionId -and $Os.editionId -and ($_.editionId -ieq $Os.editionId) }) | Select-Object -First 1
  }

  # 1. Edition
  $mediaEditions = @($Rows | ForEach-Object { $_.editionId } | Where-Object { $_ } | Select-Object -Unique)
  if ($null -eq $selected) {
    $checks += [ordered]@{ check = 'edition'; pass = $false; detail = "No image on the media matches installed edition '$($Os.editionId)' (media editions: $(if ($mediaEditions.Count) { $mediaEditions -join ', ' } else { 'unreadable' }))." }
    $reasons += "Edition mismatch: the installed edition is '$($Os.editionId)' but the media has no matching image. A repair install requires matching media (Home->Home, Pro->Pro; Enterprise needs Enterprise media)."
  } else {
    $editionPass = ($ForceIndex -gt 0) -or ($selected.editionId -ieq $Os.editionId)
    $checks += [ordered]@{ check = 'edition'; pass = $editionPass; detail = "Installed: '$($Os.editionId)'; selected index $($selected.index) ('$($selected.name)') is '$($selected.editionId)'." }
    if (-not $editionPass) { $reasons += "Edition mismatch on forced index $($selected.index): media '$($selected.editionId)' vs installed '$($Os.editionId)'." }
  }

  if ($null -ne $selected -and $null -eq $selected.detailError) {
    # 2. Language (strict 22H2 rule)
    $osLang = "$($Os.language.tag)"
    $langPass = $false
    if ($osLang) { $langPass = (@($selected.languages | Where-Object { $_ -ieq $osLang }).Count -gt 0) }
    $checks += [ordered]@{ check = 'language'; pass = $langPass; detail = "System default UI language: '$osLang'; media languages: $(if ($selected.languages.Count) { $selected.languages -join ', ' } else { '(none listed)' })." }
    if (-not $langPass) {
      $reasons += "Language mismatch: since Windows 11 22H2 a repair install strictly requires media in the system default UI language ('$osLang'). Even en-US vs en-GB fails - setup exits silently (0xC1900204). Get media in '$osLang'."
    }

    # 3. Architecture
    $archPass = ($null -ne $selected.architecture -and $selected.architecture -eq $Os.architecture)
    $checks += [ordered]@{ check = 'architecture'; pass = $archPass; detail = "OS: $($Os.architecture); media: $($selected.architecture)." }
    if (-not $archPass) { $reasons += "Architecture mismatch: $($Os.architecture) OS vs $($selected.architecture) media." }

    # 4. Build: same-or-newer
    if ($null -ne $selected.build -and $null -ne $Os.currentBuild) {
      if ($selected.build -lt $Os.currentBuild) {
        $checks += [ordered]@{ check = 'build'; pass = $false; detail = "Media build $($selected.build) is OLDER than installed build $($Os.currentBuild)." }
        $reasons += "Build too old: media is build $($selected.build), the OS is $($Os.currentBuild). You cannot repair-downgrade, and an older image is also useless as a DISM /Source (payload mismatch, 0x800f081f). Honestly: this ISO cannot help this machine - get current media."
      } elseif ($selected.build -gt $Os.currentBuild) {
        $checks += [ordered]@{ check = 'build'; pass = $true; detail = "Media build $($selected.build) is newer than installed $($Os.currentBuild)." }
        $notes += "The media is a newer build ($($selected.build) vs $($Os.currentBuild)): setup will run it as a feature update rather than a pure same-build repair. Apps and files are still kept."
      } else {
        $checks += [ordered]@{ check = 'build'; pass = $true; detail = "Media and OS are both build $($selected.build)." }
        if ($null -ne $selected.ubr -and $null -ne $Os.ubr -and $selected.ubr -lt $Os.ubr) {
          $notes += "The OS has a newer cumulative update ($($Os.currentBuild).$($Os.ubr)) than the media ($($selected.build).$($selected.ubr)). Fine for the in-place repair, but as a DISM /Source it may fail with 0x800f081f - if that happens, use plain /RestoreHealth (Windows Update source) instead."
        }
      }
    } else {
      $checks += [ordered]@{ check = 'build'; pass = $false; detail = 'Media build could not be read from the image metadata.' }
      $reasons += 'The media build could not be determined, so the same-or-newer rule cannot be verified.'
    }
  } elseif ($null -ne $selected -and $null -ne $selected.detailError) {
    $reasons += "The matching image's metadata could not be read: $($selected.detailError)"
  }

  $compatible = ($reasons.Count -eq 0)
  $selIdx = $null; if ($null -ne $selected) { $selIdx = $selected.index }
  [ordered]@{
    determined    = $true   # the rules were actually evaluated (see New-FFUndeterminedVerdict)
    compatible    = $compatible
    reasons       = $reasons
    checks        = $checks
    notes         = $notes
    selectedIndex = $selIdx
    imageInfo     = $selected
  }
}

# ---------------- Fido helpers (acquire-url) ----------------

# Fido's -Lang wants Microsoft's display names, not BCP-47 tags. Full map of the
# languages Microsoft offers the consumer Win11 ISO in.
$FidoLangMap = @{
  'ar-SA' = 'Arabic';        'pt-BR' = 'Brazilian Portuguese'; 'bg-BG' = 'Bulgarian'
  'zh-CN' = 'Chinese Simplified'; 'zh-TW' = 'Chinese Traditional'; 'hr-HR' = 'Croatian'
  'cs-CZ' = 'Czech';         'da-DK' = 'Danish';          'nl-NL' = 'Dutch'
  'en-US' = 'English';       'en-GB' = 'English International'; 'et-EE' = 'Estonian'
  'fi-FI' = 'Finnish';       'fr-FR' = 'French';          'fr-CA' = 'French Canadian'
  'de-DE' = 'German';        'el-GR' = 'Greek';           'he-IL' = 'Hebrew'
  'hu-HU' = 'Hungarian';     'it-IT' = 'Italian';         'ja-JP' = 'Japanese'
  'ko-KR' = 'Korean';        'lv-LV' = 'Latvian';         'lt-LT' = 'Lithuanian'
  'nb-NO' = 'Norwegian';     'pl-PL' = 'Polish';          'pt-PT' = 'Portuguese'
  'ro-RO' = 'Romanian';      'ru-RU' = 'Russian';         'sr-Latn-RS' = 'Serbian Latin'
  'sk-SK' = 'Slovak';        'sl-SI' = 'Slovenian';       'es-ES' = 'Spanish'
  'es-MX' = 'Spanish (Mexico)'; 'sv-SE' = 'Swedish';      'th-TH' = 'Thai'
  'tr-TR' = 'Turkish';       'uk-UA' = 'Ukrainian'
}

function Get-FFFidoEdition {
  <#
    Maps the installed EditionID onto Fido's -Ed. The consumer multi-edition ISO
    ("Pro") covers Home/Pro/Education variants; Enterprise media is not offered
    through this channel at all -> manual fallback.
  #>
  param([string]$EditionId)
  switch -Regex ($EditionId) {
    '^(Core|CoreN|CoreSingleLanguage|CoreCountrySpecific)$' { return 'Pro' }  # consumer multi-edition ISO; setup picks Home by channel/key
    '^(Professional|ProfessionalN|ProfessionalWorkstation|ProfessionalEducation)$' { return 'Pro' }
    '^(Education|EducationN)$' { return 'Pro' }
    default { return $null }
  }
}

function Get-FFFallbackLadder {
  # The remaining rungs, spelled out for the UI whenever Fido cannot deliver.
  param([string]$LangCode, [string]$Edition)
  $mediaEdition = 'Professional'
  if ($Edition -match '^Core') { $mediaEdition = 'Home' }
  [ordered]@{
    mct = [ordered]@{
      what    = 'Microsoft Media Creation Tool (first-party; uses the ESD delivery channel, never IP-banned).'
      command = "MediaCreationTool.exe /Eula Accept /Retail /MediaArch x64 /MediaLangCode $LangCode /MediaEdition $mediaEdition"
      note    = 'Semi-automated: the wizard UI still appears with choices pre-populated; /Eula Accept accepts the MCT EULA on the user''s behalf - surface that first. Output media carries install.esd.'
    }
    manual = [ordered]@{
      what = 'Official Microsoft download page in the default browser + "I already have an ISO" file picker.'
      url  = $ManualDownloadUrl
      note = 'Choose the multi-edition ISO for x64 devices in the SYSTEM DEFAULT UI LANGUAGE, then verify SHA-256 against the hash list published on that page.'
    }
  }
}

function Invoke-FFProcess {
  <#
    Runs a command out-of-process with redirected stdout/stderr and a hard
    timeout. Async reads avoid the classic redirected-pipe deadlock.
    Returns @{ exitCode; stdout; stderr; timedOut }.
  #>
  param([string]$FilePath, [string]$Arguments, [int]$TimeoutSec = 300)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { $p.Kill() } catch {}
    try { $null = $p.WaitForExit(5000) } catch {}
  }
  $stdout = ''; $stderr = ''
  try { $stdout = $outTask.Result } catch {}
  try { $stderr = $errTask.Result } catch {}
  $code = $null
  try { $code = $p.ExitCode } catch {}
  [ordered]@{ exitCode = $code; stdout = $stdout; stderr = $stderr; timedOut = $timedOut }
}

# ---------------- setup.exe exit-code translation ----------------

function Convert-FFSetupExitCode {
  param($Code)
  $hex = $null
  # NB: the literal 0xFFFFFFFF parses as int32 -1 in PowerShell, which would make
  # the mask a no-op and print negative codes as 16 hex digits - use the decimal
  # int64 literal instead.
  try { $hex = '0x{0:X8}' -f ([int64]$Code -band [int64]4294967295) } catch { $hex = "$Code" }
  $known = @{
    '0xC1900210' = @('clean',    'Compatibility scan found no issues - green light for the in-place repair.')
    '0xC1900208' = @('blocked',  'Compatibility issues found (hard block). Parse the compat XML in C:\$WINDOWS.~BT\Sources\Panther for the named blocker.')
    '0xC190010E' = @('error',    'EULA was not accepted in unattended context (MOSETUP_E_EULA_ACCEPT_REQUIRED).')
    '0xC1900107' = @('blocked',  'A previous setup attempt is pending cleanup/reboot - restart the PC, then retry.')
    '0xC190020E' = @('blocked',  'Insufficient disk space on the system drive.')
    '0x80070070' = @('blocked',  'Insufficient disk space (ERROR_DISK_FULL).')
    '0xC1900204' = @('blocked',  'Install choice unavailable (MOSETUP_E_COMPAT_INSTALLREQ_BLOCK) - typically an edition or language mismatch between media and OS.')
    '0xC1900101' = @('rollback', 'Generic rollback - almost always a driver/filter-driver crash during a boot phase. Run SetupDiag against the Panther logs; common culprits are AV filter drivers, storage drivers, old AIB utilities.')
    '0x00000000' = @('success',  'Setup reported success.')
  }
  if ($known.ContainsKey($hex)) {
    return [ordered]@{ exitCode = $Code; hex = $hex; verdict = $known[$hex][0]; meaning = $known[$hex][1] }
  }
  [ordered]@{ exitCode = $Code; hex = $hex; verdict = 'unknown'; meaning = "Unrecognized setup exit code $hex - check C:\`$WINDOWS.~BT\Sources\Panther\setupact.log / setuperr.log and run SetupDiag." }
}

# ---------------- ledger ----------------

function Read-FFLedger {
  if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { return @() }
  try {
    $raw = Get-Content -LiteralPath $LedgerPath -Raw -ErrorAction Stop
    $doc = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    return @($doc)
  } catch { return @() }
}

function Write-FFLedger {
  param($Entries)
  try {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop | Out-Null }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 8
    [System.IO.File]::WriteAllText($LedgerPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $true
  } catch { return $false }
}

# ---------------- shared assembly for media-based actions ----------------

function Get-FFMediaVerdict {
  <#
    Resolve media -> inventory -> verdict, with every failure mode structured.
    Returns @{ ok; errorCode; error; media; inventory; verdict; needsAdmin }.
    Caller must Complete-FFMedia on .media when non-null.
  #>
  param([string]$Iso, [string]$Source, [int]$ForceIndex, $Os)
  $res = [ordered]@{ ok = $false; errorCode = $null; error = $null; media = $null; inventory = @(); verdict = $null; needsAdmin = $false }
  $media = Resolve-FFMedia -Iso $Iso -Source $Source
  $res.media = $media
  if (-not $media.ok) {
    $res.errorCode = $media.errorCode
    $res.error = $media.error
    return $res
  }
  try {
    $res.inventory = @(Get-FFMediaInventory -ImageFile $media.imageFile)
  } catch {
    $msg = "$($_.Exception.Message)"
    if (-not $IsAdmin -and $msg -match 'elevat|denied|access') {
      $res.needsAdmin = $true
      $res.errorCode = 'inventory-needs-admin'
      $res.error = "Reading the image inventory requires administrator rights: $msg"
    } else {
      $res.errorCode = 'inventory-failed'
      $res.error = "Could not read the install image inventory: $msg"
    }
    return $res
  }
  if (@($res.inventory).Count -eq 0) {
    $res.errorCode = 'inventory-empty'
    $res.error = 'The install image contains no images.'
    return $res
  }
  $res.verdict = Compare-FFMediaToOs -Os $Os -Rows $res.inventory -ForceIndex $ForceIndex
  $res.ok = $true
  $res
}

function New-FFUndeterminedVerdict {
  <#
    A verdict object for the case where the media inventory could not be read at all.
    Previously the callers emitted verdict:null while still reporting ok:true, so any
    consumer reading verdict.compatible null-referenced. The shape is now always the
    same shape; 'determined' says whether the rules were actually evaluated.
  #>
  param([string]$Reason)
  [ordered]@{
    determined    = $false
    compatible    = $false
    reasons       = @($Reason)
    checks        = @()
    notes         = @('The media could not be inventoried, so the edition/language/architecture/build rules were never evaluated. compatible:false here means "not proven compatible", not "proven incompatible".')
    selectedIndex = $null
    imageInfo     = $null
  }
}

function New-FFConsentContract {
  <#
    The honest consent copy the UI must show BEFORE anything passes /eula accept.
    Two commands do: preflight's '/compat scanonly' dress rehearsal and launch's
    '/auto upgrade'. Both are gated (-AcceptEula, -Confirm). The previous wording
    promised nothing would pass /eula accept until this checkbox, while preflight - the
    step BEFORE this one in the documented flow - passed it with no gate at all.
  #>
  [ordered]@{
    eulaConsentCoversTwoCommands = @(
      'Pre-flight compatibility scan:  setup.exe /auto upgrade /quiet /eula accept /compat scanonly /noreboot',
      'The repair itself:              setup.exe /auto upgrade /eula accept ... /noreboot'
    )
    eulaNote         = 'BOTH the pre-flight compatibility scan and the repair itself pass /eula accept to Windows Setup, because the scan IS Windows Setup running its own dress rehearsal and it will not run unattended without that switch. Accepting here means accepting the Microsoft Software License Terms for this Windows version. FrameForge does not accept them for you: the scan runs only with -AcceptEula and the repair only with -Confirm, and neither switch is passed unless you consent in the UI first.'
    whenAcceptanceHappens = 'At the pre-flight step - one step earlier than the launch button. That is why consent is collected before pre-flight, not after it.'
    whatIsPreserved  = @(
      'User accounts and profiles',
      'Personal files',
      'Installed Win32 and Store apps',
      'Most settings and drivers (/migratedrivers all)',
      'Windows activation'
    )
    whatIsReset      = @(
      'All system binaries and the component store (the point of the repair)',
      'Some defaults (default apps can reset)',
      'Custom services / patched system files',
      'Third-party shell extensions may need repair or reinstall'
    )
    durationEstimate = '30-90 minutes on modern NVMe hardware; the down-level phase is 10-30 minutes.'
    rebootCount      = '2-3 restarts. /noreboot suppresses only the FIRST one - you choose when to restart; later restarts happen automatically.'
    rollbackNote     = 'A failed upgrade rolls back automatically. The previous OS is kept in C:\Windows.old with "Go back" available for ~10 days, then auto-cleaned.'
    bitlockerNote    = 'Setup normally keeps or auto-suspends BitLocker, but a recovery-key prompt after reboot is possible (TPM+PIN, firmware changes). Confirm you can access your recovery key first: https://aka.ms/myrecoverykey'
  }
}

# ---------------- SetupDiag results (verify) ----------------

function Get-FFSetupDiagNames {
  <#
    Pull the concrete nouns out of SetupDiag's free-text failure data: driver binaries,
    device instance paths, and the setup error codes. This is the bit the user actually
    acts on - "0xC1900101 during SYSPREP" is not a fix, "iaStorAC.sys" is.
  #>
  param([string]$Text)
  $out = [ordered]@{ drivers = @(); devices = @(); errorCodes = @(); extendedCodes = @() }
  if (-not $Text) { return $out }
  $drv = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b([A-Za-z0-9_\-\.]{1,64}\.(?:sys|dll|exe))\b')) { $drv += $m.Groups[1].Value }
  # setup's own binaries are noise, not the culprit
  $noise = @('setup.exe','setuphost.exe','setupplatform.exe','setupplatform.dll','windows.exe','poqexec.exe')
  $out.drivers = @($drv | Where-Object { $noise -notcontains "$_".ToLowerInvariant() } | Select-Object -Unique | Select-Object -First 10)
  $dev = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b((?:PCI|USB|HDAUDIO|ACPI|SCSI|ROOT|SWD|HID)\\[^\s,;"'')]{4,120})')) { $dev += $m.Groups[1].Value }
  $out.devices = @($dev | Select-Object -Unique | Select-Object -First 10)
  $codes = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b(0x[0-9A-F]{4,8})\b')) { $codes += ('0x' + $m.Groups[1].Value.Substring(2).ToUpperInvariant()) }
  $out.errorCodes = @($codes | Select-Object -Unique | Select-Object -First 10)
  # The 0xC1900101 family is only actionable WITH its extended code (0xC1900101 - 0x4000D
  # says which setup phase died), and the extended half is often shorter than 8 digits.
  $ext = @()
  foreach ($m in [regex]::Matches($Text, '(?i)\b(0x[0-9A-F]{8})\s*-\s*(0x[0-9A-F]{4,8})\b')) {
    $ext += ('0x' + $m.Groups[1].Value.Substring(2).ToUpperInvariant() + ' - 0x' + $m.Groups[2].Value.Substring(2).ToUpperInvariant())
  }
  $out.extendedCodes = @($ext | Select-Object -Unique | Select-Object -First 10)
  $out
}

function Get-FFSetupDiagResults {
  <#
    Parse what SetupDiag actually wrote, instead of only noting that a file exists.

    verify used to do nothing but Test-Path on SetupDiagResults.xml while the verdict text
    told the user "SetupDiag names the cause" - it did not, and the user was left to open
    the XML themselves. fresh-image-repair.md line 156 and section 6 step 8 both require
    the named cause to be surfaced, so it is read from BOTH places modern setup writes it:
      %WinDir%\Logs\SetupDiag\SetupDiagResults.xml
      HKLM\SYSTEM\Setup\SetupDiag\Results
    The XML schema has changed across SetupDiag versions (a single <SetupDiag> element in
    1.x, a <Results>/<Failure> collection later), so the parse is deliberately
    schema-agnostic: it walks for ProfileName/ProfileGuid/Remediation/FailureData nodes
    wherever they sit. And per the research doc, when several failures are logged the LAST
    one is usually the fatal one - so entries are kept IN ORDER and the last is reported
    as likelyFatal rather than silently averaging them together.
  #>
  param([string]$XmlPath, [string]$RegistryPath = 'HKLM:\SYSTEM\Setup\SetupDiag\Results')
  $res = [ordered]@{
    parsed = $false; source = $null; parseError = $null
    entryCount = 0; entries = @(); likelyFatal = $null
    namedCause = $null; message = $null; remediation = $null
    namedDrivers = @(); namedDevices = @(); errorCodes = @(); extendedCodes = @()
    multipleFailuresNote = $null
    registryValues = $null
  }
  $sources = @()

  # --- XML ---
  $entries = @()
  if ($XmlPath -and (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
    try {
      $doc = New-Object System.Xml.XmlDocument
      $doc.PreserveWhitespace = $false
      $doc.Load($XmlPath)
      # Each element that carries a ProfileName is one logged failure, whatever it is called.
      $hosts = @()
      foreach ($n in @($doc.SelectNodes('//*[local-name()="ProfileName"]'))) {
        if ($null -ne $n.ParentNode) { $hosts += $n.ParentNode }
      }
      if ($hosts.Count -eq 0 -and $null -ne $doc.DocumentElement) { $hosts = @($doc.DocumentElement) }
      foreach ($h in $hosts) {
        $e = [ordered]@{ profileName=$null; profileGuid=$null; remediation=$null; dateTime=$null; version=$null; failureData=@() }
        foreach ($pair in @(
            @{ k='profileName'; x='ProfileName' }, @{ k='profileGuid'; x='ProfileGuid' },
            @{ k='remediation'; x='Remediation' }, @{ k='dateTime'; x='DateTime' },
            @{ k='version';     x='Version' })) {
          $v = $h.SelectSingleNode('.//*[local-name()="' + $pair.x + '"]')
          if ($null -ne $v) { $e[$pair.k] = "$($v.InnerText)".Trim() }
        }
        $fd = @()
        foreach ($s in @($h.SelectNodes('.//*[local-name()="FailureData"]//*[local-name()="string"]'))) { $fd += "$($s.InnerText)".Trim() }
        if ($fd.Count -eq 0) {
          foreach ($s in @($h.SelectNodes('.//*[local-name()="FailureData"]'))) {
            $t = "$($s.InnerText)".Trim()
            if ($t) { $fd += $t }
          }
        }
        $e.failureData = @($fd | Where-Object { "$_" -match '\S' })
        if ($e.profileName -or $e.failureData.Count -gt 0) { $entries += $e }
      }
      if ($entries.Count -gt 0) { $sources += 'xml' }
    } catch { $res.parseError = "SetupDiagResults.xml could not be parsed: $($_.Exception.Message)" }
  }

  # --- registry (setup writes the same verdict here; it survives the XML being cleaned up) ---
  try {
    if (Test-Path -LiteralPath $RegistryPath) {
      $p = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
      $vals = [ordered]@{}
      foreach ($prop in @($p.PSObject.Properties)) {
        if ("$($prop.Name)" -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
        $vals["$($prop.Name)"] = "$($prop.Value)"
      }
      if ($vals.Keys.Count -gt 0) {
        $res.registryValues = $vals
        $sources += 'registry'
        if ($entries.Count -eq 0) {
          $e = [ordered]@{ profileName=$null; profileGuid=$null; remediation=$null; dateTime=$null; version=$null; failureData=@() }
          foreach ($k in @($vals.Keys)) {
            switch -Regex ($k) {
              '^ProfileName$'  { $e.profileName = $vals[$k] }
              '^ProfileGuid$'  { $e.profileGuid = $vals[$k] }
              '^Remediation$'  { $e.remediation = $vals[$k] }
              '^DateTime$'     { $e.dateTime = $vals[$k] }
              '^(SetupDiag)?Version$' { $e.version = $vals[$k] }
              '^FailureData'   { $e.failureData += $vals[$k] }
              default { }
            }
          }
          if ($e.profileName -or $e.failureData.Count -gt 0) { $entries += $e }
        }
      }
    }
  } catch {}

  if ($entries.Count -eq 0) {
    if (-not $res.parseError -and $XmlPath -and (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
      $res.parseError = 'SetupDiagResults.xml exists but contained no recognisable failure entry (no ProfileName and no FailureData). Read the file directly.'
    }
    return $res
  }

  # In-order; the LAST logged failure is usually the fatal one (fresh-image-repair.md:156).
  for ($i = 0; $i -lt $entries.Count; $i++) { $entries[$i]['index'] = $i }
  $res.parsed = $true
  $res.source = ($sources | Select-Object -Unique) -join '+'
  $res.entryCount = $entries.Count
  $res.entries = @($entries)
  $fatal = $entries[$entries.Count - 1]
  $res.likelyFatal = $fatal
  $res.namedCause = $fatal.profileName
  $res.message = (@($fatal.failureData) -join ' ')
  $res.remediation = $fatal.remediation
  $named = Get-FFSetupDiagNames -Text ("$($fatal.profileName) $($res.message) $($fatal.remediation)")
  $res.namedDrivers = @($named.drivers)
  $res.namedDevices = @($named.devices)
  $res.errorCodes = @($named.errorCodes)
  $res.extendedCodes = @($named.extendedCodes)
  if ($entries.Count -gt 1) {
    $res.multipleFailuresNote = "SetupDiag logged $($entries.Count) failures. They are listed in order in entries[]; the LAST one is reported as likelyFatal because with multiple failures logged the last is usually the one that actually stopped setup. The earlier ones are often consequences of it, so read them as context, not as separate problems to chase."
  }
  $res
}

function Get-FFSetupDiagSentence {
  <# One human sentence naming the cause, for appending to the verdict text. #>
  param($Parsed)
  if ($null -eq $Parsed) { return $null }
  if (-not $Parsed.parsed) {
    if ($Parsed.parseError) { return "SetupDiag results are present but could not be read: $($Parsed.parseError)" }
    return $null
  }
  $bits = @()
  if ($Parsed.namedCause) { $bits += "SetupDiag names the cause as '$($Parsed.namedCause)'" } else { $bits += 'SetupDiag logged a failure' }
  if (@($Parsed.namedDrivers).Count -gt 0) { $bits += "and points at: $((@($Parsed.namedDrivers)) -join ', ')" }
  elseif (@($Parsed.namedDevices).Count -gt 0) { $bits += "and points at device: $((@($Parsed.namedDevices))[0])" }
  if (@($Parsed.extendedCodes).Count -gt 0) { $bits += "(codes: $((@($Parsed.extendedCodes)) -join ', '))" }
  elseif (@($Parsed.errorCodes).Count -gt 0) { $bits += "(codes: $((@($Parsed.errorCodes)) -join ', '))" }
  $s = ($bits -join ' ') + '.'
  if ($Parsed.remediation) { $s = "$s SetupDiag's suggested remediation: $($Parsed.remediation)" }
  if ($Parsed.entryCount -gt 1) { $s = "$s $($Parsed.multipleFailuresNote)" }
  if (-not $Parsed.namedCause -and $Parsed.message) { $s = "$s Failure data: $($Parsed.message)" }
  $s
}

# ---------------- actions ----------------

$out = $null
$exitCode = 0
$Os = $null

# The whole dispatch is guarded: $ErrorActionPreference is SilentlyContinue here, but a
# TERMINATING error (a bad cast, a missing type, a null method call) still unwinds the
# script - and without this guard it would exit with no JSON at all, breaking the
# one-document contract the Electron host depends on. Every exit path below emits
# exactly one document.
try {
$Os = Get-FFOsIdentity   # every action reasons against the machine identity

$IndexValue = 0
$IndexValid = [int]::TryParse("$Index", [ref]$IndexValue)
if (-not $IndexValid -or $IndexValue -lt 0) { $IndexValid = $false }

if ($ValidActions -notcontains $Action) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'unknown-action'; error = "Unknown action '$Action'."; validActions = $ValidActions }
  $exitCode = 2
} elseif (-not $IndexValid) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'bad-index'; error = "-Index must be a non-negative whole number (0 = auto-select by edition) - got '$Index'." }
  $exitCode = 2
} else {
switch ($Action) {

  'consent' {
    # Consent BEFORE pre-flight: the UI shows this, the user accepts, and only then may
    # -AcceptEula (pre-flight) and -Confirm (launch) be passed. Read-only - it reports
    # the rails and the exact commands, and starts nothing.
    $rails = Get-FFRails
    $railCheck = Test-FFRailsGreen -Rails $rails
    $setupExe = $null
    if ($IsoPath) { $setupExe = '<mounted ISO>\setup.exe' } elseif ($SourcePath) { $setupExe = (Join-Path $SourcePath 'setup.exe') } else { $setupExe = '<media root>\setup.exe' }
    $out = [ordered]@{
      ok = $true; action = 'consent'; mode = 'consent-contract'; executed = $false
      isAdmin = $IsAdmin
      contract = (New-FFConsentContract)
      commandsThatRequireThisConsent = [ordered]@{
        preflightCompatScan = "`"$setupExe`" /auto upgrade /quiet /eula accept /compat scanonly /noreboot"
        repairInstall       = "`"$setupExe`" /auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs `"$SetupLogDir`" /noreboot"
      }
      rails = $rails
      railCheck = $railCheck
      howToProceed = 'After the user accepts: image.ps1 -Action preflight -IsoPath <iso> -AcceptEula (elevated). Then, only if pre-flight is green: image.ps1 -Action launch -IsoPath <iso> -Confirm (elevated).'
      note = 'Read-only: nothing was mounted, nothing was started, and no EULA was passed to Windows Setup by this action.'
    }
  }

  'detect' {
    $rails = Get-FFRails
    $componentStore = [ordered]@{ status = 'needs-admin'; imageHealthState = $null }
    if ($IsAdmin) {
      try {
        $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
        $componentStore.status = 'checked'
        $componentStore.imageHealthState = "$($r.ImageHealthState)"
      } catch {
        $componentStore.status = 'error'
        $componentStore.imageHealthState = $null
        $componentStore.error = "$($_.Exception.Message)"
      }
    }
    $out = [ordered]@{
      ok             = $true
      action         = 'detect'
      isAdmin        = $IsAdmin
      at             = (Get-Date).ToString('s')
      os             = $Os
      mediaMustMatch = [ordered]@{
        edition  = $Os.editionId
        language = $Os.language.tag
        build    = "same-or-newer than $($Os.currentBuild)"
        arch     = $Os.architecture
        rule     = 'Since Windows 11 22H2 the repair media must exactly match the system default UI language, match the edition, be the same-or-newer build, and match the architecture. Any mismatch and setup exits silently.'
      }
      rails          = $rails
      componentStore = $componentStore
    }
  }

  'validate' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os
    try {
      if (-not $mv.ok) {
        $out = [ordered]@{
          ok = $false; action = 'validate'; errorCode = $mv.errorCode; error = $mv.error
          isAdmin = $IsAdmin; needsAdmin = [bool]$mv.needsAdmin
          os = $Os
        }
        if ($mv.errorCode -eq 'inventory-failed' -or $mv.errorCode -eq 'inventory-needs-admin' -or $mv.errorCode -eq 'inventory-empty' -or $mv.errorCode -eq 'not-windows-media') {
          # A real answer about the media, not bad input: exit 0 with ok=false. The
          # verdict is always the same shape so a consumer reading verdict.compatible
          # never null-references, with determined:false saying the rules never ran.
          $out.verdict = New-FFUndeterminedVerdict -Reason "$($mv.error)"
        } else {
          $exitCode = 2
        }
      } else {
        $out = [ordered]@{
          ok        = $true
          action    = 'validate'
          isAdmin   = $IsAdmin
          os        = $Os
          media     = [ordered]@{ root = $mv.media.root; imageFile = $mv.media.imageFile; kind = $mv.media.kind; isoPath = $mv.media.isoPath }
          inventory = $mv.inventory
          verdict   = $mv.verdict
        }
        if ($mv.media.kind -eq 'esd') {
          $out.verdict.notes = @($out.verdict.notes) + @('Media carries install.esd (MCT-style): fine for setup.exe and as a DISM esd: source; not mountable for file extraction.')
        }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'acquire-url' {
    $ed = Get-FFFidoEdition -EditionId $Os.editionId
    $lang = $null
    if ($Os.language.tag -and $FidoLangMap.ContainsKey($Os.language.tag)) { $lang = $FidoLangMap[$Os.language.tag] }
    $arch = $Os.architecture
    $ladder = Get-FFFallbackLadder -LangCode "$($Os.language.tag)" -Edition $Os.editionId

    if ($null -eq $ed) {
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "Installed edition '$($Os.editionId)' is not covered by the consumer multi-edition ISO Fido can fetch (Enterprise/LTSC need their own media from your license channel)."
        fallbackDetail = $ladder; os = $Os
      }
      break
    }
    if ($null -eq $lang) {
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "System UI language '$($Os.language.tag)' could not be mapped to a Microsoft ISO language name - pick the language manually on the download page (it must exactly match '$($Os.language.tag)')."
        fallbackDetail = $ladder; os = $Os
      }
      break
    }
    if ($arch -ne 'x64' -and $arch -ne 'arm64') {
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "Architecture '$arch' has no Windows 11 consumer ISO channel."
        fallbackDetail = $ladder; os = $Os
      }
      break
    }

    $fidoPath = Join-Path $ToolsDir 'Fido.ps1'
    $fidoArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fidoPath`" -Win 11 -Rel Latest -Ed $ed -Lang `"$lang`" -Arch $arch -GetUrl"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # What is and is NOT verified about the third-party script. Stating this plainly is
    # the point: the SHA-256 used to be advertised as a safety property while it was in
    # fact computed AFTER download and never compared to anything.
    $fidoTrust = [ordered]@{
      verified = @(
        'Transport: HTTPS only. A non-https:// URL is skipped outright.',
        "Origin: the official pbatard/Fido repository's latest release asset ($FidoPrimaryUrl).",
        'Shape: the first 80 lines must look like the Fido script (a CDN error page or an HTML redirect is refused, not executed).',
        'Isolation: it runs out-of-process under powershell.exe with a 300 s timeout, so it cannot touch this engine''s state and its GPLv3 code never links into the app.',
        'Result: the returned URL must be https:// on a microsoft.com host, or it is refused.'
      )
      notVerified = @(
        'The SHA-256 is COMPUTED AND REPORTED, not checked against a pinned known-good value. Fido publishes a new script with every release, so a hard-coded hash would break the feature on the next release instead of protecting anyone.',
        "The fallback URL $FidoFallbackUrl is a moving target: it is the tip of the master branch, not a signed release asset. It is used only if the release asset cannot be fetched, and the source actually used is reported in fido.source.",
        'The script is not code-signed and FrameForge does not audit its contents.'
      )
      howToPin = 'Pass -FidoSha256 <hash> to require an exact script. The hash of the script that was fetched is always in fido.sha256, so a first run can be used to pin later runs. On a mismatch the script is NOT executed AND the rejected download is deleted - it never reaches data\state\tools\Fido.ps1 at all, because the download lands on a temp name and is only renamed into place after the hash and shape checks pass. A previously-good copy is therefore never overwritten by a bad one.'
      pinnedHash = $(if ($FidoSha256) { "$FidoSha256" } else { $null })
    }

    if ($DryRun) {
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'; dryRun = $true
        wouldDownload = [ordered]@{ primary = $FidoPrimaryUrl; fallback = $FidoFallbackUrl; to = $fidoPath }
        wouldRun = "powershell.exe $fidoArgs"
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch }
        trust = $fidoTrust
        consentRequired = $true
        fallbackDetail = $ladder
        note = 'Nothing was downloaded or executed (-DryRun). Outside -DryRun this action needs -ConsentRunFido: it fetches and runs a third-party GPLv3 script that works by presenting a non-Windows browser identity to Microsoft''s download page. Show trust.verified / trust.notVerified to the user and let them decide.'
      }
      break
    }

    if (-not $ConsentRunFido) {
      # Same shape as launch's consent-contract mode: report exactly what would happen,
      # do none of it. Downloading and executing third-party code on the user's machine
      # is a decision the user makes, not a side effect of clicking "get media".
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'; mode = 'consent-contract'; executed = $false
        wouldDownload = [ordered]@{ primary = $FidoPrimaryUrl; fallback = $FidoFallbackUrl; to = $fidoPath }
        wouldRun = "powershell.exe $fidoArgs"
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch }
        trust = $fidoTrust
        needsConsent = $true
        howToExecute = 'Re-run with -ConsentRunFido after the user has accepted, optionally with -FidoSha256 <hash> to pin the script. Or skip this rung entirely and use fallbackDetail.mct / fallbackDetail.manual, which download nothing but Microsoft''s own bits.'
        fallbackDetail = $ladder
      }
      $exitCode = 3
      break
    }

    # 1. Fetch Fido.ps1 (HTTPS, official repo only), record SHA-256 of what we got.
    #
    # DOWNLOAD-TO-QUARANTINE, then promote. The download lands on a temp name and is only
    # renamed onto Fido.ps1 after BOTH gates pass (pinned hash, then shape). Previously a
    # tampered or wrong file was written straight to data\state\tools\Fido.ps1, and the
    # mismatch path then refused to RUN it while leaving it sitting on disk - and it had
    # already overwritten a previously-good copy on the way in. Now a rejected file is
    # deleted and any existing good copy is untouched.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $fetchedFrom = $null; $fetchError = $null
    $fidoTempPath = Join-Path $ToolsDir ("Fido.download-" + [guid]::NewGuid().ToString('N') + ".tmp")
    $priorCopyExisted = $false
    try { $priorCopyExisted = Test-Path -LiteralPath $fidoPath -PathType Leaf } catch {}
    function Remove-FFRejectedDownload {
      param([string]$Path)
      $r = [ordered]@{ deleted = $false; error = $null }
      try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        $r.deleted = $true
      } catch { $r.error = "$($_.Exception.Message)" }
      $r
    }
    try {
      if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
      foreach ($u in @($FidoPrimaryUrl, $FidoFallbackUrl)) {
        if ($u -notmatch '^https://') { continue }  # HTTPS is non-negotiable
        try {
          Invoke-WebRequest -Uri $u -OutFile $fidoTempPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
          $fetchedFrom = $u
          break
        } catch { $fetchError = "$($_.Exception.Message)" }
      }
    } catch { $fetchError = "$($_.Exception.Message)" }
    if ($null -eq $fetchedFrom) {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "Fido.ps1 could not be fetched from GitHub: $fetchError"
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; existingCopyPreserved = $priorCopyExisted }
        fallbackDetail = $ladder
      }
      break
    }
    $fidoSha256 = $null
    try { $fidoSha256 = (Get-FileHash -LiteralPath $fidoTempPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
    # Hash pinning, when the caller asked for it: checked BEFORE the file is promoted and
    # long before anything is executed.
    if ($FidoSha256) {
      $want = "$FidoSha256".Trim().Replace('-','').ToUpperInvariant()
      $got = "$fidoSha256".Trim().ToUpperInvariant()
      if ($want -ne $got) {
        $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
        $out = [ordered]@{
          ok = $false; action = 'acquire-url'; fallback = 'manual'
          reason = "SHA-256 mismatch: -FidoSha256 pinned $want but the script fetched from $fetchedFrom hashes to $got. Refusing to run it, and the rejected download has been DELETED rather than left on disk. Either the upstream released a new version (check the repository and re-pin) or the download was tampered with."
          fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; expectedSha256 = $want; path = $null; executed = $false }
          quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted
                                   note = 'The download never reached data\state\tools\Fido.ps1: it is written to a temp name and only renamed into place after the hash and shape checks pass, so a rejected file cannot overwrite a previously-good copy.' }
          trust = $fidoTrust
          fallbackDetail = $ladder
        }
        $exitCode = 3
        break
      }
    }
    $looksLikeFido = $false
    try {
      $head = Get-Content -LiteralPath $fidoTempPath -TotalCount 80 -ErrorAction Stop
      $headTxt = ($head -join "`n")
      $looksLikeFido = ($headTxt -match 'Fido' -and $headTxt -match 'param')
    } catch {}
    if (-not $looksLikeFido) {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = 'The fetched file does not look like the Fido PowerShell script (possible CDN error page) - refusing to run it, and the rejected download has been deleted rather than left on disk.'
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $null; executed = $false }
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
      break
    }
    # Both gates passed - promote the quarantined file into place.
    try {
      Move-Item -LiteralPath $fidoTempPath -Destination $fidoPath -Force -ErrorAction Stop
    } catch {
      $cleanup = Remove-FFRejectedDownload -Path $fidoTempPath
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = 'manual'
        reason = "The fetched script passed its checks but could not be moved into place at '$fidoPath': $($_.Exception.Message)"
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $null; executed = $false }
        quarantine = [ordered]@{ tempFile = $fidoTempPath; deleted = $cleanup.deleted; deleteError = $cleanup.error; promoted = $false; existingCopyPreserved = $priorCopyExisted }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
      break
    }

    # 2. Run it OUT-of-process (GPLv3 isolation + crash isolation) and parse the URL.
    $run = Invoke-FFProcess -FilePath $psExe -Arguments $fidoArgs -TimeoutSec 300
    $stdoutLines = @()
    if ($run.stdout) { $stdoutLines = @($run.stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() }) }
    $urlLine = $null
    foreach ($l in $stdoutLines) {
      $t = $l.Trim()
      if ($t -match '^https://\S+$') { $urlLine = $t }
    }
    $allText = "$($run.stdout)`n$($run.stderr)"
    $isMsUrl = $false
    if ($urlLine) {
      try {
        $u = [Uri]$urlLine
        $isMsUrl = ($u.Scheme -eq 'https' -and $u.Host -match '(^|\.)microsoft\.com$')
      } catch {}
    }
    if ($isMsUrl) {
      $out = [ordered]@{
        ok = $true; action = 'acquire-url'
        url = $urlLine
        expiresNote = 'Microsoft direct-download URLs are time-limited (typically ~24 hours). Download promptly, then verify the ISO SHA-256 against the hash list on the Microsoft download page - that comparison is the one that matters, and it is one FrameForge cannot make for you because Microsoft publishes those hashes only on the page itself.'
        mapped = [ordered]@{ edition = $ed; language = $lang; arch = $arch }
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; pinnedSha256 = $(if ($FidoSha256) { "$FidoSha256" } else { $null }); path = $fidoPath; ranOutOfProcess = $true; executed = $true; exitCode = $run.exitCode }
        trust = $fidoTrust
        nextStep = "image.ps1 -Action download -Url <url> -Dest <path.iso>"
      }
    } else {
      # Structured failure - classify, never crash.
      $fallback = 'mct'; $reason = $null
      if ($run.timedOut) {
        $reason = 'Fido timed out after 300 s querying Microsoft''s servers.'
      } elseif ($allText -match '715-123130|Sentinel|banned') {
        $reason = 'Microsoft''s Sentinel anti-abuse layer rejected the scripted request (error 715-123130, IP-reputation ban; it does not self-clear). Use the Media Creation Tool - Microsoft''s own suggested workaround.'
      } elseif ($urlLine) {
        $fallback = 'manual'
        $reason = "Fido returned a URL outside microsoft.com ('$urlLine') - refusing it."
      } else {
        $reason = 'Fido did not return a download URL (its output could not be parsed).'
      }
      $excerpt = $allText.Trim()
      if ($excerpt.Length -gt 800) { $excerpt = $excerpt.Substring(0, 800) + ' ...' }
      $out = [ordered]@{
        ok = $false; action = 'acquire-url'; fallback = $fallback; reason = $reason
        fido = [ordered]@{ source = $fetchedFrom; sha256 = $fidoSha256; path = $fidoPath; executed = $true; exitCode = $run.exitCode; timedOut = $run.timedOut; outputExcerpt = $excerpt }
        trust = $fidoTrust
        fallbackDetail = $ladder
      }
    }
  }

  'download' {
    if (-not $Url -or -not $Dest) {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'missing-param'; error = 'download requires -Url <https url> and -Dest <destination file path>.' }
      $exitCode = 2
      break
    }
    $uriOk = $false
    try { $u = [Uri]$Url; $uriOk = ($u.Scheme -eq 'https') } catch {}
    if (-not $uriOk) {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'not-https'; error = 'Refusing a non-HTTPS download URL.' }
      $exitCode = 2
      break
    }
    if ($DryRun) {
      $out = [ordered]@{ ok = $true; action = 'download'; dryRun = $true; wouldRun = "Start-BitsTransfer -Source '$Url' -Destination '$Dest'"; then = 'Get-FileHash -Algorithm SHA256 on the result.' }
      break
    }
    try {
      $destDir = Split-Path -Path $Dest -Parent
      if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null }
      Import-Module BitsTransfer -ErrorAction Stop
      Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName 'FrameForge Windows ISO' -Description 'Official Microsoft ISO download' -ErrorAction Stop
      $fi = Get-Item -LiteralPath $Dest -ErrorAction Stop
      $hash = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256 -ErrorAction Stop).Hash
      $out = [ordered]@{
        ok = $true; action = 'download'
        dest = $fi.FullName
        sizeBytes = [int64]$fi.Length
        sizeGB = [math]::Round($fi.Length / 1GB, 2)
        sha256 = $hash
        verifyNote = 'Compare this SHA-256 against the hash list Microsoft publishes on the download page before using the ISO.'
      }
    } catch {
      $out = [ordered]@{ ok = $false; action = 'download'; errorCode = 'transfer-failed'; error = "BITS transfer failed: $($_.Exception.Message)" }
    }
  }

  'dism-source-repair' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os
    try {
      if (-not $mv.ok) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      $idx = $mv.verdict.selectedIndex
      if ($null -eq $idx) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'no-matching-index'; error = 'No image index on this media matches the installed edition - see verdict.'; verdict = $mv.verdict }
        break
      }
      $srcSpec = "$($mv.media.kind):$($mv.media.imageFile):$idx"
      $dismCmd = "DISM /Online /Cleanup-Image /RestoreHealth /Source:$srcSpec /LimitAccess"
      $psCmd   = "Repair-WindowsImage -Online -RestoreHealth -Source '$srcSpec' -LimitAccess"
      $followUp = [ordered]@{
        engine    = 'repair.ps1'
        catalogId = 'sfc-scannow'
        why       = 'DISM repairs the component store; SFC then repairs live system files FROM the repaired store. Always run SFC after.'
      }
      if ($DryRun) {
        $out = [ordered]@{
          ok = $true; action = 'dism-source-repair'; dryRun = $true
          selectedIndex = $idx
          sourceSpec = $srcSpec
          wouldRun = $dismCmd
          powershellForm = $psCmd
          verdict = $mv.verdict
          followUp = $followUp
          note = 'Nothing was executed (-DryRun). The command repairs C:\Windows\WinSxS payloads offline; /LimitAccess blocks the Windows Update fallback so the repair is deterministic.'
        }
        break
      }
      if (-not $IsAdmin) {
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'needs-admin'; error = 'RestoreHealth requires administrator rights. Re-run elevated, or use -DryRun to preview the exact command.'; wouldRun = $dismCmd }
        $exitCode = 3
        break
      }
      if (-not $mv.verdict.compatible) {
        # Honest refusal: a wrong-build/edition source yields 0x800f081f, not a repair.
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'media-incompatible'; error = 'This media does not match the installed OS - as a DISM source it would fail with 0x800f081f. See verdict.reasons.'; verdict = $mv.verdict }
        $exitCode = 3
        break
      }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $r = Repair-WindowsImage -Online -RestoreHealth -Source $srcSpec -LimitAccess -ErrorAction Stop
        $sw.Stop()
        $out = [ordered]@{
          ok = $true; action = 'dism-source-repair'
          ran = $dismCmd
          selectedIndex = $idx
          imageHealthState = "$($r.ImageHealthState)"
          restartNeeded = [bool]$r.RestartNeeded
          durationMs = [int]$sw.ElapsedMilliseconds
          verdict = $mv.verdict
          followUp = $followUp
          log = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
        }
      } catch {
        $sw.Stop()
        $msg = "$($_.Exception.Message)"
        $hint = $null
        if ($msg -match '0x800f081f') { $hint = 'Source files not found: the image build/LCU is older than the running OS or the index edition is wrong. Use newer media, or run plain RestoreHealth (Windows Update source).' }
        $out = [ordered]@{ ok = $false; action = 'dism-source-repair'; errorCode = 'restorehealth-failed'; error = $msg; hint = $hint; ran = $dismCmd; durationMs = [int]$sw.ElapsedMilliseconds; log = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log') }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'preflight' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os
    try {
      if (-not $mv.media.ok) {
        $out = [ordered]@{ ok = $false; action = 'preflight'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      $mediaVerified = ($mv.ok -and $mv.verdict.compatible)
      $rails = Get-FFRails
      $railCheck = Test-FFRailsGreen -Rails $rails
      # Never emit verdict:null alongside ok:true - a consumer reading verdict.compatible
      # would null-reference. An unreadable inventory gets a real, honest verdict object.
      $verdict = $mv.verdict
      if (-not $mv.ok) {
        $verdict = New-FFUndeterminedVerdict -Reason "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
        $railCheck.reasons = @($railCheck.reasons) + @("Media inventory could not be read ($($mv.errorCode)): $($mv.error)")
        $railCheck.green = $false
      }
      $setupExe = Join-Path $mv.media.root 'setup.exe'
      $setupPresent = (Test-Path -LiteralPath $setupExe -PathType Leaf)
      $scanArgs = '/auto upgrade /quiet /eula accept /compat scanonly /noreboot'
      $scanCmd = "`"$setupExe`" $scanArgs"
      $contract = New-FFConsentContract

      # --- EULA gate. The compat scan passes /eula accept: it IS Windows Setup running
      # its own dress rehearsal, and it will not run unattended without that switch.
      # Passing it silently while a later screen promised "FrameForge will not pass it
      # until you consent here" was a documented lie. Consent is collected first
      # (-Action consent), then represented to this action as -AcceptEula.
      $compatScan = $null
      $needsEulaConsent = $false
      $needsAdminRefusal = $false
      if ($DryRun) {
        $compatScan = [ordered]@{ ran = $false; wouldRun = $scanCmd; note = 'Skipped (-DryRun). The scan is non-destructive - setup runs the full compatibility check and exits with a translated code (0xC1900210 clean / 0xC1900208 blocked) - but it DOES pass /eula accept, so outside -DryRun it needs -AcceptEula. It also writes setup logs and briefly consumes CPU/disk.' }
      } elseif (-not $AcceptEula) {
        $needsEulaConsent = $true
        $compatScan = [ordered]@{
          ran = $false
          wouldRun = $scanCmd
          skippedBecause = 'eula-consent-required'
          detail = 'The compatibility scan passes /eula accept to Windows Setup - it is Windows Setup, and it refuses to run unattended without that switch. FrameForge will not accept the Microsoft Software License Terms on your behalf, so this scan does not run until you have consented. Show the contract (image.ps1 -Action consent), then re-run pre-flight with -AcceptEula.'
          contract = $contract
        }
      } elseif (-not $IsAdmin) {
        # Exit 3, per the documented contract at the top of this file: this is a REFUSAL
        # for want of administrator rights, on the execute path (consent has been given,
        # the scan was going to run, and it did not). Exiting 0 here reported the same
        # code as a pre-flight that actually ran its dress rehearsal, which made the
        # documented meaning of exit 3 untrue.
        $needsAdminRefusal = $true
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'needs-admin'; wouldRun = $scanCmd; detail = 'Windows Setup requires administrator rights even for /compat scanonly. The EULA consent was accepted, so the only thing missing is elevation: re-run pre-flight elevated. Exit code 3 (refused: needs administrator rights).' }
      } elseif (-not $setupPresent) {
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'setup-missing'; error = "setup.exe not found at '$setupExe'." }
      } elseif (-not $mediaVerified) {
        $compatScan = [ordered]@{ ran = $false; skippedBecause = 'media-not-verified'; detail = 'Media is not verified compatible (unreadable inventory or failed matching rules) - a compat scan against wrong media proves nothing. Fix the media first.' }
      } else {
        try {
          $p = Start-Process -FilePath $setupExe -ArgumentList $scanArgs -Wait -PassThru -ErrorAction Stop
          $translated = Convert-FFSetupExitCode -Code $p.ExitCode
          $compatScan = [ordered]@{ ran = $true; command = $scanCmd; eulaAccepted = $true; result = $translated; compatXmlHint = 'On 0xC1900208, the blockers are named in C:\$WINDOWS.~BT\Sources\Panther\CompatData*.xml.' }
        } catch {
          $compatScan = [ordered]@{ ran = $false; skippedBecause = 'start-failed'; error = "Could not start the compatibility scan: $($_.Exception.Message)" }
        }
      }

      $green = ($railCheck.green -and $mediaVerified)
      $scanVerdict = $null
      if ($compatScan -and $compatScan.Contains('result')) { $scanVerdict = $compatScan.result.verdict }
      if ($null -ne $scanVerdict -and $scanVerdict -ne 'clean') { $green = $false }
      # A pre-flight whose dress rehearsal never ran has not proven anything.
      if (-not $compatScan.ran) { $green = $false }
      if (($needsEulaConsent -or $needsAdminRefusal) -and -not $DryRun) { $exitCode = 3 }
      $out = [ordered]@{
        ok = $true; action = 'preflight'; dryRun = [bool]$DryRun
        isAdmin = $IsAdmin
        eulaAccepted = [bool]$AcceptEula
        needsEulaConsent = $needsEulaConsent
        needsAdmin = $needsAdminRefusal
        contract = $contract
        media = [ordered]@{ root = $mv.media.root; imageFile = $mv.media.imageFile; kind = $mv.media.kind; setupExePresent = $setupPresent }
        verdict = $verdict
        rails = $rails
        railCheck = $railCheck
        compatScan = $compatScan
        readyToLaunch = $green
        nextStep = $(if ($needsEulaConsent) { 'Show contract (image.ps1 -Action consent). After the user accepts: re-run pre-flight with -AcceptEula, elevated.' }
                     elseif ($needsAdminRefusal) { 'Re-run pre-flight elevated (with -AcceptEula) so Windows Setup can run its compatibility scan. Everything else above was checked.' }
                     elseif ($green -and -not $DryRun) { 'image.ps1 -Action launch -IsoPath <iso> (returns the consent contract again; add -Confirm only after the user consents in the UI)' }
                     else { 'Resolve the red items above, then re-run preflight.' })
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'launch' {
    $mv = Get-FFMediaVerdict -Iso $IsoPath -Source $SourcePath -ForceIndex $IndexValue -Os $Os
    try {
      if (-not $mv.media.ok) {
        # Media itself could not be resolved (no file / not Windows media) - no
        # command can even be constructed. Structured error.
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        if ($mv.errorCode -eq 'no-media-param' -or $mv.errorCode -eq 'iso-not-found' -or $mv.errorCode -eq 'source-not-found') { $exitCode = 2 }
        break
      }
      if (-not $mv.ok -and $Confirm -and -not $DryRun) {
        # Executing requires a readable, verified inventory - refuse.
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = $mv.errorCode; error = $mv.error; needsAdmin = [bool]$mv.needsAdmin }
        $exitCode = 3
        break
      }
      $rails = Get-FFRails
      $railCheck = Test-FFRailsGreen -Rails $rails
      $setupExe = Join-Path $mv.media.root 'setup.exe'
      $setupPresent = (Test-Path -LiteralPath $setupExe -PathType Leaf)
      $launchArgs = "/auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs `"$SetupLogDir`" /noreboot"
      $launchCmd = "`"$setupExe`" $launchArgs"
      $contract = New-FFConsentContract

      if (-not $Confirm -or $DryRun) {
        # Consent-contract mode: the exact command and the honest terms, nothing runs.
        $blockers = @()
        $lVerdict = $mv.verdict
        if (-not $setupPresent) { $blockers += "setup.exe not found at '$setupExe'." }
        if ($null -eq $lVerdict) {
          $lVerdict = New-FFUndeterminedVerdict -Reason "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
          $blockers += "Media inventory could not be read ($($mv.errorCode)): $($mv.error)"
        }
        elseif (-not $lVerdict.compatible) { $blockers += 'Media failed the matching rules (see verdict.reasons).' }
        $blockers += @($railCheck.reasons)
        if (-not $IsAdmin) { $blockers += 'Administrator rights are required to launch.' }
        $out = [ordered]@{
          ok = $true; action = 'launch'; mode = 'consent-contract'
          executed = $false
          command = $launchCmd
          optionalBitLockerStep = 'Suspend-BitLocker -MountPoint C: -RebootCount 3   (pass -SuspendBitLocker to include it)'
          contract = $contract
          verdict = $lVerdict
          rails = $rails
          railCheck = $railCheck
          blockers = $blockers
          howToExecute = 'Re-run with -Confirm (elevated) AFTER the user has accepted the contract in the UI. FrameForge never launches this silently (doctrine rule 3).'
        }
        break
      }

      # -Confirm path: every gate must be green.
      if (-not $IsAdmin) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'needs-admin'; error = 'Launching the in-place repair requires administrator rights.' }
        $exitCode = 3
        break
      }
      if (-not $setupPresent) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'setup-missing'; error = "setup.exe not found at '$setupExe'." }
        $exitCode = 3
        break
      }
      if (-not $mv.verdict.compatible) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'media-incompatible'; error = 'Refusing to launch: the media does not match this machine.'; verdict = $mv.verdict }
        $exitCode = 3
        break
      }
      if (-not $railCheck.green) {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'rails-red'; error = 'Refusing to launch: safety rails are not green.'; railCheck = $railCheck; rails = $rails }
        $exitCode = 3
        break
      }

      # Ledger BEFORE launch: verify() diffs against this.
      $entry = [ordered]@{
        launchedAt    = (Get-Date).ToString('s')
        isoPath       = $mv.media.isoPath
        sourceRoot    = $mv.media.root
        imageKind     = $mv.media.kind
        selectedIndex = $mv.verdict.selectedIndex
        mediaBuild    = $mv.verdict.imageInfo.build
        mediaUbr      = $mv.verdict.imageInfo.ubr
        preOs         = [ordered]@{ editionId = $Os.editionId; displayVersion = $Os.displayVersion; build = $Os.currentBuild; ubr = $Os.ubr; language = $Os.language.tag }
        command       = $launchCmd
        bitLockerSuspended = $false
      }
      $bl = $null
      if ($SuspendBitLocker) {
        try {
          $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
          if ("$($blv.ProtectionStatus)" -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 3 -ErrorAction Stop | Out-Null
            $entry.bitLockerSuspended = $true
            $bl = 'BitLocker suspended for 3 reboots (auto-resumes).'
          } else {
            $bl = 'BitLocker protection is not on - nothing to suspend.'
          }
        } catch { $bl = "Suspend-BitLocker failed (setup's TryKeepActive default still applies): $($_.Exception.Message)" }
      }
      $ledger = @(Read-FFLedger) + @($entry)
      $ledgerWritten = Write-FFLedger -Entries $ledger
      try {
        if (-not (Test-Path -LiteralPath $SetupLogDir)) { New-Item -ItemType Directory -Path $SetupLogDir -Force -ErrorAction Stop | Out-Null }
      } catch {}
      try {
        $p = Start-Process -FilePath $setupExe -ArgumentList $launchArgs -PassThru -ErrorAction Stop
        $out = [ordered]@{
          ok = $true; action = 'launch'; mode = 'executed'; executed = $true
          command = $launchCmd
          setupPid = $p.Id
          bitLockerNote = $bl
          ledgerWritten = $ledgerWritten
          ledgerPath = $LedgerPath
          note = 'Setup is running its down-level phase (10-30 min). /noreboot means YOU choose when to restart; do not dismount the ISO - setup copies what it needs to C:\$WINDOWS.~BT first, and the mount clears at reboot anyway. Run image.ps1 -Action verify after the final restart.'
        }
        # Deliberately NOT dismounting: setup reads from the mounted media.
        $mv.media.mountedByUs = $false
      } catch {
        $out = [ordered]@{ ok = $false; action = 'launch'; errorCode = 'start-failed'; error = "setup.exe could not start: $($_.Exception.Message)"; ledgerWritten = $ledgerWritten }
      }
    } finally {
      Complete-FFMedia $mv.media
    }
  }

  'verify' {
    $ledger = @(Read-FFLedger)
    $last = $null
    if ($ledger.Count -gt 0) { $last = $ledger[$ledger.Count - 1] }

    $setupState = [ordered]@{ systemSetupInProgress = $null; setupPhase = $null; setupType = $null }
    try {
      $ss = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
      $setupState.systemSetupInProgress = $ss.SystemSetupInProgress
      $setupState.setupPhase = $ss.SetupPhase
      $setupState.setupType = $ss.SetupType
    } catch {}

    $setupDiag = [ordered]@{ resultsXml = $null; resultsXmlPresent = $false; registryResults = $false }
    $sdPath = Join-Path $env:SystemRoot 'Logs\SetupDiag\SetupDiagResults.xml'
    $sdRegPath = 'HKLM:\SYSTEM\Setup\SetupDiag\Results'
    try { $setupDiag.resultsXmlPresent = Test-Path -LiteralPath $sdPath -PathType Leaf } catch {}
    if ($setupDiag.resultsXmlPresent) { $setupDiag.resultsXml = $sdPath }
    try { $setupDiag.registryResults = Test-Path $sdRegPath } catch {}
    # Actually READ them. Presence alone told the user nothing while the verdict text
    # claimed "SetupDiag names the cause"; now the named cause is in the document.
    $setupDiag.parsed = Get-FFSetupDiagResults -XmlPath $sdPath -RegistryPath $sdRegPath
    $setupDiag.namedCause = $setupDiag.parsed.namedCause
    $setupDiag.summary = Get-FFSetupDiagSentence -Parsed $setupDiag.parsed
    if (-not $setupDiag.resultsXmlPresent -and -not $setupDiag.registryResults) {
      $setupDiag.absentNote = "No SetupDiag results exist on this machine ($sdPath is absent and $sdRegPath does not exist). Modern Windows Setup runs SetupDiag itself on failure, so their absence is normal on a machine that has not had a failed upgrade. If setup failed and left nothing, run SetupDiag by hand against the Panther logs: https://go.microsoft.com/fwlink/?linkid=870142 (FrameForge does not download it for you)."
    }

    # --- Evidence gathering. The build/UBR delta alone is NOT a sufficient verdict: the
    # primary scenario for this whole flow is a SAME-BUILD repair install (media UBR ==
    # OS UBR), where a completely successful repair changes neither number. Keying only
    # on the delta reported that success as "unchanged ... or it rolled back", which is
    # the exact opposite of what happened. Windows.old, the post-upgrade Panther folder,
    # and setup's own registry state are the signals that actually distinguish
    # "ran and succeeded", "ran and rolled back", and "never ran".
    $launchedAt = $null
    if ($null -ne $last) { try { $launchedAt = [datetime]::Parse("$($last.launchedAt)") } catch {} }
    function Test-FFNewerThanLaunch { param([string]$Path, [switch]$UseCreation)
      $r = [ordered]@{ present = $false; timestamp = $null; afterLaunch = $null }
      try {
        $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $r.present = $true
        $t = $(if ($UseCreation) { $it.CreationTime } else { $it.LastWriteTime })
        $r.timestamp = $t.ToString('s')
        if ($null -ne $script:FFLaunchedAt) { $r.afterLaunch = ($t -ge $script:FFLaunchedAt.AddMinutes(-5)) }
      } catch {}
      $r
    }
    $script:FFLaunchedAt = $launchedAt

    $windowsOldPath = Join-Path $env:SystemDrive 'Windows.old'
    $windowsOld     = Test-FFNewerThanLaunch -Path $windowsOldPath -UseCreation
    $newOsPanther   = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemRoot 'Panther\NewOs')
    $setupAct       = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemRoot 'Panther\setupact.log')
    $btFolder       = Test-FFNewerThanLaunch -Path (Join-Path $env:SystemDrive '$WINDOWS.~BT')
    $setupDiagFresh = $null
    if ($setupDiag.resultsXmlPresent) {
      $sdInfo = Test-FFNewerThanLaunch -Path $sdPath
      $setupDiag.resultsXmlWritten = $sdInfo.timestamp
      $setupDiagFresh = $sdInfo.afterLaunch
      $setupDiag.writtenAfterLaunch = $setupDiagFresh
    }

    $evidence = [ordered]@{
      windowsOld     = $windowsOld
      pantherNewOs   = $newOsPanther
      pantherSetupAct= $setupAct
      windowsBT      = $btFolder
      setupDiagAfterLaunch = $setupDiagFresh
      note = 'afterLaunch is computed against the ledger''s launchedAt with a 5-minute tolerance; it is null when there is no launch on record.'
    }

    $comparison = $null; $verdict = 'no-ledger'
    if ($null -ne $last) {
      $pre = $last.preOs
      $buildChanged = $false; $ubrChanged = $false
      try { $buildChanged = ([int]$Os.currentBuild -ne [int]$pre.build) } catch {}
      try { $ubrChanged = ([int]$Os.ubr -ne [int]$pre.ubr) } catch {}
      $sameBuildMedia = $false
      try { $sameBuildMedia = ([int]$last.mediaBuild -eq [int]$pre.build -and [int]$last.mediaUbr -eq [int]$pre.ubr) } catch {}
      $comparison = [ordered]@{
        launchedAt = $last.launchedAt
        preBuild   = "$($pre.build).$($pre.ubr)"
        nowBuild   = $Os.buildString
        mediaBuild = "$($last.mediaBuild)$(if ($null -ne $last.mediaUbr) { '.' + $last.mediaUbr })"
        buildChanged = $buildChanged
        ubrChanged  = $ubrChanged
        sameBuildRepairExpected = $sameBuildMedia
        note = 'A same-build repair install (media UBR == OS UBR) is EXPECTED to leave build and UBR identical. buildChanged:false is therefore not evidence of failure on this path - see evidence.'
      }
      $ranEvidence = ([bool]$windowsOld.afterLaunch -or [bool]$newOsPanther.afterLaunch)
      if ($setupState.systemSetupInProgress -eq 1) { $verdict = 'in-progress' }
      elseif ($buildChanged -or $ubrChanged)       { $verdict = 'os-binaries-replaced' }
      elseif ($windowsOld.afterLaunch -and $newOsPanther.afterLaunch) { $verdict = 'repaired-same-build' }
      elseif ($ranEvidence -and $setupDiagFresh)   { $verdict = 'rolled-back' }
      elseif ($ranEvidence)                        { $verdict = 'ran-outcome-unclear' }
      elseif ($setupDiagFresh)                     { $verdict = 'failed-before-completion' }
      elseif ($setupAct.afterLaunch -or $btFolder.afterLaunch) { $verdict = 'started-not-completed' }
      else                                         { $verdict = 'not-run' }
    } elseif ($setupState.systemSetupInProgress -eq 1) {
      $verdict = 'in-progress'
    }

    $verdictText = @{
      'no-ledger'                = 'No launch is recorded in the ledger - either nothing was launched through FrameForge, or the ledger was cleared. Current OS state is reported anyway.'
      'in-progress'              = 'Windows Setup reports it is still in progress - verify again after the remaining restarts.'
      'os-binaries-replaced'     = 'The OS build/UBR changed since launch - the image was reinstalled. Now confirm health with the read-only probes below.'
      'repaired-same-build'      = 'The repair install completed on the SAME build - which is exactly what a same-build repair does, and why the build number is unchanged. The evidence is a C:\Windows.old created at/after launch plus a post-upgrade C:\Windows\Panther\NewOs written at/after launch: setup ran to completion and did not roll back. Now confirm health with the read-only probes below.'
      'rolled-back'              = 'Setup ran but did NOT complete: there is fresh setup activity and a SetupDiag result written after launch, with no post-upgrade Panther\NewOs. This is the rollback path - read SetupDiag''s named cause (it is almost always a driver, often an AV filter driver) before retrying.'
      'ran-outcome-unclear'      = 'Setup left fresh traces since launch, but the completion evidence is mixed. Do not assume either way: read C:\Windows\Panther\setupact.log and SetupDiag, and re-run verify after any remaining restarts.'
      'failed-before-completion' = 'A SetupDiag result was written after launch and there is no sign the upgrade completed - setup failed early. SetupDiag names the cause.'
      'started-not-completed'    = 'Setup wrote logs (or staged C:\$WINDOWS.~BT) after launch, but the machine has not been through the upgrade restarts yet. Restart to let setup finish, then verify again.'
      'not-run'                  = 'Nothing indicates Windows Setup ran at all since the recorded launch: no fresh Windows.old, no post-upgrade Panther folder, no setup logs newer than launch. Most likely setup exited immediately - check the media matching rules (edition/language mismatch makes setup exit silently) and the launch exit code.'
    }[$verdict]

    # The rollback/failure verdicts promise a named cause. Deliver it in the same sentence
    # rather than telling the user to go and read an XML file themselves.
    $sdSentence = $setupDiag.summary
    if ($sdSentence -and @('rolled-back','failed-before-completion','ran-outcome-unclear','started-not-completed') -contains $verdict) {
      $verdictText = "$verdictText $sdSentence"
    } elseif (@('rolled-back','failed-before-completion') -contains $verdict -and -not $sdSentence) {
      $verdictText = "$verdictText A SetupDiag result was detected but nothing could be read out of it, so the cause is NOT named here - open $sdPath yourself."
    }

    $out = [ordered]@{
      ok = $true; action = 'verify'
      verdict = $verdict
      verdictText = $verdictText
      namedCause = $setupDiag.namedCause
      os = $Os
      comparison = $comparison
      evidence = $evidence
      setupState = $setupState
      setupDiag = $setupDiag
      windowsOldPresent = [bool]$windowsOld.present
      rollbackNote = $(if ($windowsOld.present) { "C:\Windows.old exists (created $($windowsOld.timestamp)) - the previous OS is preserved for rollback (~10 days)." } else { 'C:\Windows.old was not found. After a completed repair install that means either the 10-day window has passed and Windows cleaned it up, or the upgrade never completed.' })
      logs = [ordered]@{
        downLevel  = (Join-Path $env:SystemRoot 'Panther')
        preReboot  = 'C:\$WINDOWS.~BT\Sources\Panther'
        postUpgrade = (Join-Path $env:SystemRoot 'Panther\NewOs')
        copyLogs   = $SetupLogDir
      }
      scheduling = [ordered]@{
        automatic = $false
        detail = 'FrameForge does NOT schedule this check to run itself after the upgrade restarts. fresh-image-repair.md section 6 step 8 describes a post-reboot RunOnce or scheduled task; FrameForge deliberately does not register one, because that means writing a persistent HKLM RunOnce entry or a scheduled task onto the machine as a side effect of pressing "repair" - a standing change that outlives the repair and survives if setup never completes, installed by a tool whose whole argument is that it does not leave things behind. So this is a manual step, and saying so plainly is the honest version.'
        whatYouDo = 'After the FINAL restart (setup does 2-3; verify again if the verdict below says in-progress), run this check again: the Verify step in the Repair Center, or "image.ps1 -Action verify" from the engine folder.'
        ifYouWantItAutomatic = 'Add it yourself, and it is yours to remove: reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v FrameForgeVerify /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path>\engine\image.ps1 -Action verify"  (RunOnce deletes its own entry when it fires).'
      }
      postChecks = @(
        [ordered]@{ engine = 'health.ps1'; invocation = 'health.ps1 -Action probe -Category system-files -Deep'; why = 'DISM CheckHealth/ScanHealth + sfc /verifyonly - the same read-only probe that diagnosed the problem must confirm the repair (doctrine rule 1).' },
        [ordered]@{ engine = 'repair.ps1'; catalogId = 'sfc-scannow'; why = 'sfc /scannow should now report no integrity violations against the fresh store.' },
        [ordered]@{ engine = 'repair.ps1'; catalogId = 'dism-restorehealth'; why = 'Only if system-files still reports corruption after the reinstall.' }
      )
    }
  }
}
}
} catch {
  # An unexpected TERMINATING error. Without this the script would exit with no JSON at
  # all, and the Electron host - which parses exactly one document per run - would see a
  # silent failure. Exit 1 WITH a document instead.
  $out = [ordered]@{
    ok        = $false
    action    = "$Action"
    errorCode = 'unhandled-exception'
    error     = "$($_.Exception.Message)"
    where     = "$($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)"
    type      = "$($_.Exception.GetType().FullName)"
  }
  $exitCode = 1
}

if ($null -eq $out) {
  $out = [ordered]@{ ok = $false; action = "$Action"; errorCode = 'no-result'; error = "Action '$Action' produced no result document." }
  $exitCode = 1
}
Write-FFJson -InputObject $out -Depth 12
exit $exitCode
