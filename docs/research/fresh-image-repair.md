# Automating a "Fresh Windows Image" Repair/Reinstall Flow on Windows 11 — Research Report

Scope: programmatic ISO acquisition, automated in-place repair upgrade, DISM `/Source` component-store repair, edition/language/build matching, and safety rails. All commands assume an elevated PowerShell session on Windows 11.

---

## 1. Legitimate programmatic ways to obtain an official Windows 11 ISO

All four options below end up delivering **official Microsoft-hosted bits** — none of them redistribute Windows. They differ in automation-friendliness and ToS posture.

### 1.1 Fido (pbatard/Fido) — PowerShell script

- **What it is:** The PowerShell script embedded in Rufus, also usable standalone. GitHub: `https://github.com/pbatard/Fido`.
- **How it works:** It automates exactly what a human does on `microsoft.com/software-download/windows11`: it spoofs a non-Windows **User-Agent** (Microsoft's page redirects Windows visitors to the Media Creation Tool instead of offering ISO links), queries the page's web API for available languages for a chosen version, then requests the signed, time-limited (typically ~24h validity) direct download URLs from Microsoft's own servers. The ISO comes straight from Microsoft CDN — Fido never proxies or hosts anything.
- **License:** **GPLv3 or later.** For an Electron app like FrameForge, invoking `Fido.ps1` as a separate process (downloading it at runtime or instructing the user) does not virally infect your codebase the way linking would; bundling it inside your installer means you must ship it under GPL terms (source availability for the script itself — which is public anyway). Safest pattern: download the script from the official GitHub release at runtime, pin a SHA-256 hash, and run it out-of-process.
- **CLI mode (no GUI when any option is passed):**
  ```powershell
  # Get just the URL (then download with your own downloader / BITS)
  $url = & .\Fido.ps1 -Win 11 -Rel Latest -Ed Pro -Lang English -Arch x64 -GetUrl
  Start-BitsTransfer -Source $url -Destination "$env:TEMP\Win11.iso"

  # Discover valid values
  .\Fido.ps1 -Win List
  .\Fido.ps1 -Win 11 -Rel List
  ```
  Requires Windows 8+ PowerShell; `-Lang` defaults to system locale, `-Arch` to system architecture.
- **Pros:** Fully scriptable; retail ISO identical to the browser download; returns a raw URL so you control the download (BITS, resume, progress UI); actively maintained.
- **Cons / ToS-safety:** Gray-hat by mechanism — it works by evading Microsoft's User-Agent gating. Microsoft has never taken action against Fido/Rufus in ~7 years, but in 2025 Microsoft's "Sentinel" anti-abuse layer began **IP-reputation banning** scripted requests with error **715-123130** ("Sentinel marked this request as rejected" / "Some users, entities and locations are banned"), affecting Insider ISOs and sometimes regular downloads from residential IPs; the ban does not self-clear. Only the *latest* release of each Windows version is available (Microsoft removed older links in 2023). **Your flow must handle Fido failure gracefully and fall back to MCT.**

### 1.2 Microsoft's direct download page (software-download.microsoft.com)

- `https://www.microsoft.com/software-download/windows11` offers the multi-edition consumer ISO ("Windows 11 (multi-edition ISO for x64 devices)") to any browser that doesn't look like Windows.
- **Pros:** 100% first-party, unambiguously ToS-clean.
- **Cons:** Not programmatic — the page requires interactive selection and issues expiring links; scraping it is literally what Fido does. There is **no stable, documented REST endpoint**. For a consumer tool the legitimate "manual fallback" UX is: open this URL in the default browser and let the user hand you the ISO path via a file picker.

### 1.3 Media Creation Tool (MCT) CLI

- Download `MediaCreationTool.exe` (the Win11 one) from the same Microsoft page (its own URL is stable enough to fetch programmatically from `go.microsoft.com` fwlinks, though the fwlink ID changes across versions — treat as semi-stable).
- **Undocumented but widely used switches:**
  ```powershell
  .\MediaCreationTool.exe /Eula Accept /Retail /MediaArch x64 /MediaLangCode en-US /MediaEdition Professional
  ```
  - `/Eula Accept` — suppresses the EULA screen (note: this accepts the MCT's EULA on the user's behalf — your app should surface this to the user first).
  - `/Retail` — retail (non-VLSC) media.
  - `/MediaArch {x64|arm64}`; `/MediaLangCode <ISO 639-1 code like en-US>`; `/MediaEdition {Enterprise|Education|Professional|Home + N variants}`.
  - Even with switches, MCT still shows its wizard UI with choices pre-populated and requires clicks for destination (ISO vs USB) — it is **semi-automated, not headless**. There is no documented fully-silent ISO output switch.
- **Pros:** First-party tool, never IP-banned (it uses the ESD delivery channel, not the ISO page), works when Fido is blocked (Microsoft's own suggested workaround for 715-123130). Produces install media with `install.esd`.
- **Cons:** UI remains; switches are undocumented and have changed between releases; output uses `install.esd` (compressed, not mountable with `Mount-WindowsImage` for file extraction, though fine as a DISM `/Source` and for setup.exe).

### 1.4 UUP dump (uupdump.net)

- **How it works:** Web front-end over Microsoft's **Unified Update Platform**. You pick build/edition/language; it generates a script package (`uup_download_windows.cmd`) that downloads the UUP payload **directly from Microsoft Windows Update servers** and locally converts/assembles it into an ISO (using aria2 + the UUP converter). Fully scriptable once the package is generated; there's also a JSON API (`api.uupdump.net`) for build enumeration.
- **Pros:** Only way to get *any specific build* (including a build matching the user's current one exactly, and Insider builds); can slipstream the latest cumulative update; output is a standard ISO with `install.wim`/`install.esd`.
- **Cons / ToS-safety:** The **grayest option**. Not authorized by Microsoft; it repurposes the update channel and third-party conversion scripts. The ISO assembly step is slow (local DISM work, 20–60 min) and heavy. **Not appropriate as the default path in a consumer product**; at most a power-user opt-in. Legality is "gray" — files come from Microsoft, no license is conveyed, but the access pattern is not sanctioned.

### Recommendation matrix for FrameForge

| Method | Headless? | ToS posture | Failure risk | Recommended role |
|---|---|---|---|---|
| Fido | Yes | Gray (UA spoof), tolerated for years | Sentinel IP ban 715-123130 | Primary automated path, hash-pinned, out-of-process |
| MCT CLI | Partial (UI remains) | Clean (first-party) | Low | Fallback when Fido fails |
| MS download page in browser | No | Clean | None | Manual fallback + "I already have an ISO" picker |
| UUP dump | Yes (after script gen) | Grayest | Moderate; slow | Do not ship as default; optional expert mode at most |

Also always verify the downloaded ISO: `Get-FileHash -Algorithm SHA256` and compare against the SHA-256 list Microsoft publishes on the download page.

---

## 2. From ISO to in-place repair upgrade

### 2.1 Mounting

```powershell
$iso = "C:\ProgramData\FrameForge\Win11_24H2_English_x64.iso"
$mount = Mount-DiskImage -ImagePath $iso -PassThru
$drive = ($mount | Get-Volume).DriveLetter + ":"
# ... later:
Dismount-DiskImage -ImagePath $iso
```
Notes: `Mount-DiskImage` needs an NTFS-local ISO path (not a mapped network drive quirkily), and mounts are lost at reboot — that's fine because setup.exe copies what it needs to `C:\$WINDOWS.~BT` during the down-level phase before the first reboot.

### 2.2 Running the repair upgrade (setup.exe)

Canonical automated repair-install command (Windows 11, per Microsoft's setup command-line reference):

```powershell
& "$drive\setup.exe" /auto upgrade `
    /eula accept `
    /dynamicupdate enable `
    /compat ignorewarning `
    /migratedrivers all `
    /showoobe none `
    /telemetry disable `
    /copylogs "C:\ProgramData\FrameForge\SetupLogs" `
    /noreboot
```

Switch-by-switch (from Microsoft Learn, "Windows Setup Command-Line Options"):

- **`/auto upgrade`** — automated upgrade **keeping apps and data**. If the "keep everything" path is unavailable (edition/language/build mismatch, compat block), setup **exits silently with an exit code** rather than prompting. `/auto clean` and `/auto dataonly` are the destructive siblings — never use them in a repair flow. When `/auto` is used, setup consumes `\sources\install.wim` (or `install.esd` if the wim was replaced).
- **`/eula accept`** — **required on Windows 11**: starting with Win11, `/auto` no longer implies EULA acceptance; without it, `/quiet` runs fail with `MOSETUP_E_EULA_ACCEPT_REQUIRED (0xC190010E)`. Your app must show the user a consent step ("You accept the Microsoft Software License Terms") before passing this.
- **`/quiet`** — fully suppresses setup UX including rollback UI. For a consumer tool, consider *not* using `/quiet` so the user sees the progress screen; use it only if you present your own progress UX.
- **`/dynamicupdate {enable|disable|NoDrivers|NoLCU|NoDriversNoLCU}`** — whether setup fetches latest setup binaries/LCU/drivers first. `enable` improves success rates (fresh servicing stack) but adds download time; `disable` makes duration deterministic and offline-safe.
- **`/compat ignorewarning`** — proceed past *dismissible* warnings. **`/compat scanonly`** is your pre-flight: runs the full compatibility scan and exits — returns `0xC1900210` (no concerns) or `0xC1900208` (compat issues found). Run this first:
  ```powershell
  $p = Start-Process "$drive\setup.exe" -ArgumentList '/auto upgrade /quiet /eula accept /compat scanonly /noreboot' -Wait -PassThru
  '0x{0:X8}' -f $p.ExitCode   # 0xC1900210 = green light
  ```
- **`/migratedrivers all`** — keep existing drivers (right choice for a repair; on an RTX 5080 rig you do not want setup swapping in an older inbox NVIDIA driver — pair with `/dynamicupdate NoDrivers` if you want to be strict).
- **`/showoobe none`** — skip OOBE, take defaults (repair installs normally skip OOBE anyway).
- **`/noreboot`** — suppresses only the **first** reboot so you can finish your own work (save state, notify the user, schedule reboot); subsequent reboots happen normally.
- **`/copylogs <path>`** — copy setup logs on failure.
- **`/bitlocker {AlwaysSuspend|TryKeepActive|ForceKeepActive}`** — default is `TryKeepActive` (tries without suspending, suspends automatically if needed). You generally don't need to pass it.
- **`/uninstall enable`** — keeps the "go back" rollback controls (default; 10-day `Windows.old` window).
- **`/pkey`, `/imageindex`** — only needed for edition changes/multi-image media; a matching repair install needs neither (setup picks the matching index in the multi-edition ISO by the current edition's channel/key).
- **`/priority normal`** — raise setup thread priority (defaults low when initiated as a background feature update).

### 2.3 What is preserved

`/auto upgrade` = "Keep personal files and apps": user accounts and profiles, personal files, installed Win32 and Store apps, most settings, drivers (with `/migratedrivers all`), activation. What gets **reset**: the component store and all system binaries (the point of the exercise), some defaults (default apps can reset), custom services/system-file patches, and third-party shell extensions may need reinstall-repair. Contents of `C:\Windows.old` hold the previous OS for rollback (~10 days, then auto-cleaned).

### 2.4 Duration and failure modes

- **Duration:** down-level phase 10–30 min on NVMe hardware like an i9-14900KF; total including 2–3 reboots typically 30–90 min. Budget "45–90 minutes, several restarts" in user messaging.
- **Key exit/failure codes:**
  - `0xC1900210` — compat scan clean (success signal for `/compat scanonly`).
  - `0xC1900208` — compatibility issues found (hard blocks; parse the compat XML in `C:\$WINDOWS.~BT\Sources\Panther`).
  - `0xC190010E` — EULA not accepted in unattended context.
  - `0xC1900101-0x2000C / 0x20017 / 0x30018 / 0x40017` family — **generic rollback**, almost always a driver/filter-driver crash during a boot phase; the system rolls back automatically to the previous OS. Common culprits: AV filter drivers, storage drivers, old AIB utilities.
  - `0xC1900107` — pending cleanup/reboot from a previous attempt.
  - `0xC190020E / 0x80070070` — insufficient disk space.
  - `MOSETUP_E_COMPAT_INSTALLREQ_BLOCK (0xC1900204)` — install choice unavailable — typical of **edition/language mismatch**, which is why setup "exits silently" if media doesn't match.
- **Safety property:** a failed upgrade **rolls back automatically**; the machine is rarely left unbootable. The worst common outcome is time lost + rollback.

### 2.5 Verifying success afterwards

```powershell
# 1. Build actually changed / matches media build
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.DisplayVersion) build $($cv.CurrentBuildNumber).$($cv.UBR)"

# 2. Setup's own result state
Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name 'SetupPhase','SystemSetupInProgress' -ErrorAction SilentlyContinue
# SetupDiag results written automatically by setup on failure:
#   %WinDir%\Logs\SetupDiag\SetupDiagResults.xml and HKLM\SYSTEM\Setup\SetupDiag\Results

# 3. Component store now healthy
DISM /Online /Cleanup-Image /ScanHealth
sfc /scannow          # should report no integrity violations

# 4. Logs if anything looks off
# C:\Windows\Panther\setupact.log, setuperr.log (down-level)
# C:\$WINDOWS.~BT\Sources\Panther\* (pre-reboot phases)
# C:\Windows\Panther\NewOs\  (post-upgrade)
```
On failure, run **SetupDiag** (`https://go.microsoft.com/fwlink/?linkid=870142`, also auto-run by modern setup): `SetupDiag.exe /Output:C:\ProgramData\FrameForge\SetupDiagResults.log` — it pattern-matches the Panther logs and names the failing driver/operation. Remember: with multiple failures logged, the **last** failure is usually the fatal one.

---

## 3. Using the ISO's install.wim/esd as a DISM /Source (offline component-store repair)

This is the lighter-weight option to try **before** a full repair install — it repairs `C:\Windows\WinSxS` payloads without touching apps or requiring reboots.

```powershell
# Mount ISO (see 2.1), then find the index matching the installed edition:
Get-WindowsImage -ImagePath "$drive\sources\install.wim"    # or install.esd
# → pick the index whose EditionId matches (e.g. 'Professional')

# WIM source:
DISM /Online /Cleanup-Image /RestoreHealth `
     /Source:wim:$drive\sources\install.wim:6 /LimitAccess

# ESD source (MCT media ships install.esd):
DISM /Online /Cleanup-Image /RestoreHealth `
     /Source:esd:$drive\sources\install.esd:6 /LimitAccess
```

- `/LimitAccess` blocks the Windows Update fallback so the repair is deterministic and offline.
- **Index matters**: point at the image whose edition matches the installed one, or DISM reports `0x800f081f "The source files could not be found"`.
- **Build matters even more**: the WIM must be the **same build family with the same or newer LCU** than the running OS, or payload versions won't match and you'll still get `0x800f081f`. If the OS has a newer cumulative update than the ISO, either use an updated ISO (UUP dump can pre-slipstream the LCU) or let plain `/RestoreHealth` (no `/Source`) fetch from Windows Update.
- Alternative PowerShell-native form: `Repair-WindowsImage -Online -RestoreHealth -Source ... -LimitAccess`.
- Follow with `sfc /scannow` (SFC repairs live system files from the now-repaired store; DISM repairs the store itself).

---

## 4. Edition / language / build matching requirements

A `/auto upgrade` repair install requires media that matches the installed OS on:

1. **Edition** — Home→Home, Pro→Pro (the multi-edition consumer ISO covers Home/Pro/Edu variants; Enterprise needs Enterprise media).
2. **Language (System Default UI Language)** — **strict since Windows 11 22H2**: cross-language upgrades (even en-US → en-GB) are no longer allowed; setup exits silently.
3. **Build/version** — media must be the **same or newer build** than the installed OS (you cannot repair-downgrade; going 24H2-media over 23H2 works but is then a feature update, not a pure repair). For a pure repair, "Latest retail ISO" over an up-to-date system is the normal case.
4. **Architecture** — x64 media on x64 (irrelevant edge cases aside).

### Detection commands

```powershell
# Edition
DISM /Online /Get-CurrentEdition          # → "Current edition is: Professional"
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
Get-WindowsEdition -Online                 # PowerShell DISM module

# Version / build (winver equivalent, scriptable)
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[pscustomobject]@{
  Version = $cv.DisplayVersion            # e.g. 24H2
  Build   = "$($cv.CurrentBuildNumber).$($cv.UBR)"   # e.g. 26100.4652
}
[System.Environment]::OSVersion.Version    # quick build check

# System default UI language (the one that must match the media)
DISM /Online /Get-Intl                     # → "Default system UI language : en-US"
(Get-WinSystemLocale).Name                 # system locale (related but not identical)
[System.Globalization.CultureInfo]::InstalledUICulture.Name   # installed UI culture

# Architecture
$env:PROCESSOR_ARCHITECTURE                # AMD64 / ARM64

# What's on the media (compare before launching setup)
Get-WindowsImage -ImagePath "$drive\sources\install.wim" -Index 6 |
  Select ImageName, EditionId, Version, Languages
```

Your flow should compute `(EditionID, DefaultSystemUILanguage, Build, Arch)` for both OS and media and hard-refuse the upgrade path on any mismatch, offering DISM `/Source` repair or manual media instead.

---

## 5. Safety rails before launching

```powershell
# --- Disk space: ISO (~5.5-7 GB) + setup working set. Microsoft floor is 20 GB free
# on the system drive for a feature update; enforce 25-30 GB + ISO size to be safe.
$free = (Get-PSDrive C).Free / 1GB
if ($free -lt 30) { throw "Need >=30 GB free on C:, have $([math]::Round($free,1)) GB" }

# --- AC power / battery (desktops pass trivially; still check)
$onBattery = (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) -and
             ((Get-CimInstance BatteryStatus -Namespace root\wmi -ErrorAction SilentlyContinue).PowerOnline -contains $false)
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus  # 'Online' = AC

# --- BitLocker: setup default (TryKeepActive) handles suspension automatically,
# but surface the recovery-key warning to the user and confirm the key is escrowed.
Get-BitLockerVolume -MountPoint C: | Select VolumeStatus, ProtectionStatus, KeyProtector
# Belt-and-braces: suspend for the upgrade's reboots (auto-resumes after N reboots):
Suspend-BitLocker -MountPoint C: -RebootCount 3
# If the user cannot produce/verify a recovery key, block the flow:
(Get-BitLockerVolume -MountPoint C:).KeyProtector |
  Where-Object KeyProtectorType -eq 'RecoveryPassword'

# --- Pending reboot detection (block until clean; setup returns 0xC1900107 otherwise)
function Test-PendingReboot {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $true } }
  $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
          -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
  [bool]$pfro
}

# --- Misc rails worth adding
# * Windows Update not mid-install:  Get-Service wuauserv, and no TrustedInstaller activity
# * Sleep/hibernate suppressed during the down-level phase (SetThreadExecutionState / powercfg)
# * Warn user to close apps; setup will force-close at first reboot anyway
# * Create a restore point is NOT sufficient protection and setup disables it during upgrade —
#   the real safety net is setup's own automatic rollback + Windows.old
```

**BitLocker specifics:** in-place upgrade normally *keeps or auto-suspends* BitLocker (the `/BitLocker TryKeepActive` default) and does not require the recovery key — but if the machine has TPM+PIN or third-party disk encryption, or firmware changes coincide, a recovery-key prompt after reboot is possible. A consumer tool must (a) detect protection status, (b) tell the user to confirm they can access their recovery key (aka.ms/myrecoverykey), and (c) optionally `Suspend-BitLocker -RebootCount 3` before launching setup.

---

## 6. Suggested end-to-end flow for FrameForge

1. Detect `(edition, sysUILang, build, arch)` → decide target media.
2. Try DISM `/ScanHealth`; if store corruption is the actual problem, offer §3 (offline `/Source` repair) before the heavyweight §2 path.
3. Acquire ISO: Fido (`-GetUrl` + BITS) → on 715-123130/any failure, MCT CLI → else browser + file picker. Verify SHA-256.
4. Validate media matches OS (`Get-WindowsImage` vs detected values).
5. Safety rails (§5) + explicit user consent screen covering EULA acceptance and reboot expectations.
6. `/compat scanonly` pre-flight → expect `0xC1900210`.
7. Launch `/auto upgrade /eula accept /migratedrivers all /dynamicupdate NoDrivers /compat ignorewarning /copylogs ... /noreboot`; prompt user to reboot when ready.
8. Post-reboot (scheduled task / RunOnce): verify build/UBR, `DISM /ScanHealth`, `sfc /scannow`; on failure run SetupDiag and surface its named cause.

---

## Sources

- [pbatard/Fido — GitHub (README: mechanism, CLI options, GPLv3)](https://github.com/pbatard/Fido)
- [Windows Setup Command-Line Options — Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11)
- [SetupDiag — Microsoft Learn](https://learn.microsoft.com/en-us/windows/deployment/upgrade/setupdiag)
- [Repair-WindowsImage (DISM PowerShell) — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/dism/repair-windowsimage?view=windowsserver2025-ps)
- [Repair Install Windows 11 with an In-place Upgrade — ElevenForum tutorial](https://www.elevenforum.com/t/repair-install-windows-11-with-an-in-place-upgrade.418/)
- [Repair Install Windows 11 with an In-place Upgrade — NinjaOne](https://www.ninjaone.com/blog/repair-install-windows-11-with-an-in-place-upgrade/)
- [How to Upgrade Windows Build from an ISO with setup.exe — WOSHub](https://woshub.com/upgrade-windows-10-build-setup-exe-cmd/)
- [Using DISM and SFC to Check and Repair Windows System Files — WOSHub](https://woshub.com/dism-cleanup-image-restorehealth/)
- [Dell KB: DISM fails "source files could not be found" (index/build matching)](https://www.dell.com/support/kbdoc/en-us/000198179/dism-repair-operation-fails-with)
- [MCT CLI switches for Enterprise ISO — WindowsReport](https://windowsreport.com/windows-11-enterprise-iso-media-creation-tool/) and [Kevin's tech blog](https://kevinstreet.co.uk/tag/media-creation-tool/)
- [715-123130 Microsoft IP-bans scripted ISO downloads — winget-cli issue #6257](https://github.com/microsoft/winget-cli/issues/6257) and [WindowsForum coverage](https://windowsforum.com/threads/microsoft-blocks-rufus-from-downloading-windows-11-insider-isos-715-123130.401415/)
- [UUP dump mechanism and legality — XDA](https://www.xda-developers.com/uup-dump-windows-11-10-iso-update/) and [UUP Dump GitHub org](https://github.com/UUP-Dump)
- [Fix 0xC1900101 (driver rollback family) — NinjaOne](https://www.ninjaone.com/blog/fix-windows-setup-error-0xc1900101-in-windows-11/)
- [In-place upgrade guidance / preserved data — PDQ](https://www.pdq.com/blog/how-to-perform-in-place-windows-upgrade/)

## Key findings

- Fido (pbatard/Fido, GPLv3) is the only fully headless path to a retail Windows 11 ISO: it spoofs a non-Windows User-Agent against microsoft.com/software-download's web API and returns ~24h-valid direct Microsoft CDN URLs via '-Win 11 -Rel Latest -Ed Pro -Lang English -Arch x64 -GetUrl' — but since 2025 Microsoft's Sentinel layer IP-bans scripted requests with error 715-123130, so a fallback is mandatory.
- The fallback chain should be: Fido → Media Creation Tool CLI ('MediaCreationTool.exe /Eula Accept /Retail /MediaArch x64 /MediaLangCode en-US /MediaEdition Professional' — first-party and never banned, but undocumented switches and the wizard UI still appears) → open the browser download page with a manual file picker; UUP dump is ToS-grayest and should not ship as a consumer default.
- The automated repair install is: Mount-DiskImage, then 'setup.exe /auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs <dir> /noreboot' — on Windows 11, /eula accept is mandatory (0xC190010E otherwise) because /auto no longer implies EULA acceptance, and /noreboot suppresses only the first reboot so the app can hand control back to the user.
- '/compat scanonly' is a free pre-flight: setup runs the full compatibility scan and exits with 0xC1900210 (clean) or 0xC1900208 (blocked) without changing anything.
- '/auto upgrade' preserves user accounts, files, Win32 and Store apps, drivers and activation while replacing all system binaries and the component store; a failed upgrade auto-rolls-back via Windows.old (10-day window), and the 0xC1900101-0xXXXXX family means a driver-caused rollback diagnosable with SetupDiag (results in %WinDir%\Logs\SetupDiag and HKLM\SYSTEM\Setup\SetupDiag\Results).
- Since Windows 11 22H2 the repair media must exactly match the installed System Default UI Language (even en-US vs en-GB fails silently) plus edition and same-or-newer build; detect with 'DISM /online /Get-CurrentEdition', 'DISM /online /Get-Intl', and CurrentVersion registry (DisplayVersion, CurrentBuildNumber, UBR), and compare against 'Get-WindowsImage -ImagePath <iso>\sources\install.wim'.
- The same ISO doubles as an offline component-store repair source: 'DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:<index> /LimitAccess' (or esd: for MCT media) — the index must match the installed edition and the image build/LCU must be same-or-newer than the OS or DISM fails with 0x800f081f; this lighter repair should be offered before the full in-place upgrade.
- Safety rails to enforce before launching setup: >=25-30 GB free on C: (Microsoft floor is 20 GB), AC power check, BitLocker recovery-key confirmation plus optional 'Suspend-BitLocker -RebootCount 3' (setup's default /BitLocker TryKeepActive auto-suspends anyway), and pending-reboot detection via the CBS RebootPending, WU RebootRequired, and PendingFileRenameOperations registry keys (a pending reboot yields setup error 0xC1900107).
- Verify success post-upgrade by re-reading DisplayVersion/CurrentBuild/UBR from the registry, confirming HKLM\SYSTEM\Setup state, and running 'DISM /Online /Cleanup-Image /ScanHealth' plus 'sfc /scannow'; expect the whole upgrade to take 30-90 minutes with 2-3 reboots on modern NVMe hardware.
- Every download should be integrity-checked with Get-FileHash SHA256 against Microsoft's published hashes, and Fido should be fetched from its official GitHub release at runtime with a pinned hash and run out-of-process to keep GPLv3 obligations away from the Electron app's own license.
