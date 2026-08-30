# Windows 11 Repair & Health Landscape (2025–2026)

Research for a measure-first repair tool: the escalation ladder, the top real-world problem categories with canonical fixes, and programmatic detection/verification signals for each. All commands assume an **elevated** PowerShell/cmd unless noted.

---

## 1. The Repair Ladder

The modern (2025-era) consensus ordering, from least to most invasive. Note the order inversion vs. old folk wisdom: **DISM before SFC**, because SFC repairs files *from* the component store (WinSxS) that DISM repairs — if the store is corrupt, SFC has nothing good to copy from.

### Rung 0 — CHKDSK (disk integrity first, if disk is suspect)

File-system corruption undermines everything above it, so if there are disk-level signals (see §3), run this first.

```bat
:: Online, non-invasive scan (no lock, NTFS only) — safe to run anytime
chkdsk C: /scan

:: Fix errors found by /scan without full offline chkdsk
chkdsk C: /spotfix

:: Full offline repair incl. bad-sector scan (schedules for next boot on system volume; /r is slow)
chkdsk C: /f /r
```

PowerShell equivalents (better for scripting — structured output):

```powershell
Repair-Volume -DriveLetter C -Scan        # detect only
Repair-Volume -DriveLetter C -SpotFix     # quick fix
Repair-Volume -DriveLetter C -OfflineScanAndFix
```

### Rung 1 — DISM component-store repair

```bat
:: Fast: just reads the corruption flag set by previous operations (seconds)
DISM /Online /Cleanup-Image /CheckHealth

:: Deep scan, sets the corruption flag, no repair (minutes)
DISM /Online /Cleanup-Image /ScanHealth

:: Repair the store, sourcing files from Windows Update by default
DISM /Online /Cleanup-Image /RestoreHealth
```

PowerShell-native equivalents (structured `ImageHealthState` return — ideal for a detect/verify tool):

```powershell
Repair-WindowsImage -Online -CheckHealth     # returns Healthy / Repairable / NonRepairable
Repair-WindowsImage -Online -ScanHealth
Repair-WindowsImage -Online -RestoreHealth
```

**When Windows Update itself is broken** (RestoreHealth error 0x800f081f "source files could not be found"), point DISM at a mounted ISO of the *same build/edition*:

```bat
:: install.wim source (index = edition; list with: DISM /Get-WimInfo /WimFile:E:\sources\install.wim)
DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:E:\sources\install.wim:1 /LimitAccess

:: install.esd source (most downloaded ISOs ship ESD, not WIM)
DISM /Online /Cleanup-Image /RestoreHealth /Source:ESD:E:\sources\install.esd:1 /LimitAccess
```

Gotchas confirmed in current community/MS Q&A threads: `/LimitAccess` is required to actually stop DISM falling back to (broken) WU; the `WIM:`/`ESD:` prefix is case-sensitive in practice; index mismatch (wrong edition) and build mismatch (ISO older than installed build) are the two most common failure causes. Logs land in `C:\Windows\Logs\DISM\dism.log`.

### Rung 2 — SFC (after DISM)

```bat
sfc /scannow
```

- Outcomes: "did not find any integrity violations" / "found corrupt files and successfully repaired them" / "found corrupt files but was unable to fix some of them" (→ re-run DISM RestoreHealth with a local source, then SFC again).
- Detail log: `C:\Windows\Logs\CBS\CBS.log`, grep lines tagged `[SR]`:

```powershell
Select-String -Path C:\Windows\Logs\CBS\CBS.log -Pattern '\[SR\]' | Select-Object -Last 50
```

- Reboot after DISM+SFC; some repairs only apply at boot.

### Rung 3 — "Fix problems using Windows Update" (repair-version reinstall, 23H2+)

New in the 2024+ era: **Settings > System > Recovery > Fix problems using Windows Update > Reinstall now**. Downloads a repair copy of the currently installed build from WU and reinstalls it in place. Preserves apps, files, and settings; one reboot; essentially an automated in-place repair without an ISO. Requires WU to be functional and the feature can be greyed out on managed/Insider devices. Scriptable trigger is not officially documented (it's a Settings flow), so for automation the ISO route below remains the canonical rung.

### Rung 4 — In-place repair install from ISO (`setup.exe`)

The classic "repair install": run setup from a mounted ISO of the same-or-newer build/edition, choose Upgrade. Preserves **apps, user files, settings, and most drivers**; rebuilds the OS binaries, component store, boot config, and registry-of-OS. Scriptable:

```bat
:: E:\ = mounted ISO. Fully quiet in-place repair keeping everything:
E:\setup.exe /auto upgrade /quiet /eula accept /noreboot /copylogs C:\Logs\Setup

:: Useful extra switches:
::   /dynamicupdate disable   - don't pull fresh setup files/drivers from WU during setup
::   /compat ignorewarning    - proceed past dismissible compat warnings
::   /showoobe none           - skip OOBE questions
::   /migratedrivers all      - keep existing drivers
```

Key 2024+ change verified against Microsoft Learn: **starting with Windows 11, `/auto` no longer implies EULA acceptance — `/eula accept` is mandatory** or silent setup exits without doing anything. `/auto upgrade` = keep files+apps+settings; `/auto data` = keep files only; `/auto clean` = keep nothing. Setup logs: `C:\$WINDOWS.~BT\Sources\Panther\setupact.log`; compat scan result can be pre-checked with `setup.exe /auto upgrade /quiet /noreboot /compat scanonly` (exit code encodes the compat verdict, e.g. `0xC1900210` = no issues).

### Rung 5 — Reset This PC

Reinstalls Windows (cloud download or local rebuild). "Keep my files" removes all apps and settings but keeps user profiles/files; "Remove everything" is factory reset.

- **Important 2024+ change:** `systemreset.exe` (old switches `-factoryreset`, `-cleanpc`) was **removed in 24H2 and remains absent in 25H2**. The Settings flow now launches via an unofficial equivalent:

```bat
:: 23H2 and earlier:
systemreset -factoryreset

:: 24H2/25H2 (unofficial, launches the same wizard):
"C:\Windows\System32\SystemSettingsAdminFlows.exe" FeaturedResetPC

:: Version-agnostic: deep-link the Settings recovery page
start ms-settings:recovery
```

For a tool: treat Reset as a *guided handoff*, not something to automate silently.

### Rung 5.5 — Quick Machine Recovery (new, 24H2/25H2 era)

Worth knowing for the landscape: QMR auto-detects repeated boot failures, boots WinRE, connects to the network, and pulls Microsoft-published remediations from WU (default scan every 30 min, reboot every 180 min). **Enabled by default on Home; configurable on Pro** via Settings > System > Recovery, `reagentc.exe` or the `RemoteRemediation` CSP. It only fixes *known, Microsoft-published* boot issues — not general corruption.

### When each rung applies

| Rung | Use when |
|---|---|
| CHKDSK | NTFS/disk events, dirty bit set, I/O errors |
| DISM → SFC | App crashes, servicing failures, WU error 0x800f-series, missing system files |
| WU repair reinstall | DISM/SFC fail or loop; WU still functional; user-friendly path |
| In-place from ISO | WU itself broken, deep servicing corruption, upgrade stuck — the "fixes almost everything short of hardware" rung |
| Reset | OS unbootable-into-repair, malware, handing off machine, all else failed |

---

## 2. Top Real-World Problems and Canonical Fixes

### 2.1 Windows Update stuck / failing

Canonical fix = **reset the WU stack** (Microsoft-documented sequence):

```bat
net stop wuauserv & net stop cryptSvc & net stop bits & net stop msiserver
ren C:\Windows\SoftwareDistribution SoftwareDistribution.old
ren C:\Windows\System32\catroot2 catroot2.old
net start wuauserv & net start cryptSvc & net start bits & net start msiserver
```

Escalations, in order: DISM/SFC (§1), the sdset security-descriptor reset (`sc.exe sdset bits ...` / `sc.exe sdset wuauserv ...` — last resort only, overwrites ACLs), then in-place repair. Trigger a scan afterwards: `UsoClient StartInteractiveScan` (or `Start-Process ms-settings:windowsupdate`). The old `wuauclt` switches are dead; USOClient is the current client.

### 2.2 Network / DNS issues

```bat
ipconfig /flushdns
ipconfig /release & ipconfig /renew
netsh winsock reset
netsh int ip reset
:: then reboot
```

Full nuke (removes/reinstalls all adapters, resets to defaults): Settings > Network > Advanced network settings > **Network reset**. DNS-specific: switch resolver as a test — `Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 1.1.1.1,8.8.8.8`.

### 2.3 Microsoft Store broken

```bat
wsreset.exe        :: clears Store cache
```

```powershell
# Re-register the Store itself
Get-AppxPackage -AllUsers Microsoft.WindowsStore |
  ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" }

# Nuclear: re-register every Appx for all users (red errors on protected packages are ignorable)
Get-AppxPackage -AllUsers |
  ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" -ErrorAction SilentlyContinue }
```

Also: Settings > Apps > Microsoft Store > Advanced options > Repair, then Reset. Store depends on WU/BITS/Delivery Optimization services being enabled — check those first.

### 2.4 Search / Start menu broken

```powershell
# Restart the shell surfaces (self-healing; they relaunch automatically)
Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
Stop-Process -Name SearchHost -Force -ErrorAction SilentlyContinue
Stop-Process -Name explorer -Force

# Rebuild the search index (canonical for broken search results)
Stop-Service WSearch -Force
Remove-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force
Start-Service WSearch   # index rebuilds on start
```

Registry rebuild switch (same as Settings > Searching Windows > Advanced > Rebuild): set `HKLM:\SOFTWARE\Microsoft\Windows Search\SetupCompletedSuccessfully` = 0 and restart WSearch. If Start menu tiles/apps are broken, the Appx re-register from §2.3 is the follow-up.

### 2.5 Printer issues

```powershell
# Canonical: clear the spooler queue
Stop-Service Spooler -Force
Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force
Start-Service Spooler
```

Then: remove and re-add the printer (`Remove-Printer`, `Add-Printer`), update the driver (`Get-PrinterDriver`), and note the 2025+ direction: Microsoft is phasing toward IPP/Mopria class drivers over vendor driver packages.

### 2.6 BSOD analysis

Fix depends on the bug check — the canonical *workflow* is: identify stop code + faulting module from dumps, then act (driver rollback/update, `verifier.exe` to flush out a bad driver, memtest for RAM codes, disk ladder for storage codes).

```bat
:: WinDbg CLI analysis of the latest minidump (WinDbg ships via Store / windbg.exe cli = kd)
kd -z C:\Windows\Minidump\<latest>.dmp -c "!analyze -v; q"
```

Dumps: `C:\Windows\Minidump\*.dmp` (mini), `C:\Windows\MEMORY.DMP` (kernel). `LiveKernelReports\` holds non-fatal live kernel events (watchdog TDRs, etc. — relevant to an FPS/gaming audience).

### 2.7 Disk space

```bat
:: Component-store cleanup (safe; /ResetBase additionally blocks update uninstall — use deliberately)
DISM /Online /Cleanup-Image /StartComponentCleanup
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase

:: Classic cleaner, scriptable via saved profile
cleanmgr /sageset:1     :: interactive: pick categories once
cleanmgr /sagerun:1     :: run silently with that profile
```

Plus Storage Sense (`ms-settings:storagesense`), deleting `C:\Windows\SoftwareDistribution\Download`, and `$Windows.~BT`/`Windows.old` after upgrades (removed by Disk Cleanup's "Previous Windows installations").

### 2.8 Slow boot

Canonical fixes: disable heavy startup apps (Task Manager > Startup, measured impact), toggle Fast Startup (`powercfg /h on|off` controls hiberboot), update storage/chipset drivers, and check for boot-time disk faults. Diagnosis is event-log-driven (see §3.8) — fix the *named* offender, don't shotgun.

### 2.9 Audio issues

```powershell
# Canonical: restart the audio service pair (order matters: endpoint builder first)
Restart-Service AudioEndpointBuilder -Force
Restart-Service Audiosrv -Force
```

Then: check default endpoint, driver rollback (`pnputil /enum-drivers`, Device Manager), and disable audio enhancements. Note: legacy `msdt.exe`-based troubleshooters are retired in the 2025 era; the Get Help app supersedes them — a scriptable tool should implement the fix itself rather than shelling to msdt.

### 2.10 Activation

```bat
slmgr /ato          :: force online activation attempt
slmgr /xpr          :: is it permanently activated?
slmgr /dlv          :: detailed license status
licensingdiag.exe -report C:\Logs\lic.xml -log C:\Logs\lic.cab
```

Post-hardware-change: Settings > Activation > Troubleshoot ("I changed hardware on this device", requires MS-account-linked digital license). Common error taxonomy: 0xC004F213 (no key/license found), 0xC004C003 (blocked/hw change).

---

## 3. Detection Signals (measure-first: detect → fix → verify)

The same probe run before and after a fix gives you the verify step for free.

### 3.1 System-file / component-store corruption

```powershell
# Structured, fast (reads flag): .ImageHealthState -> Healthy/Repairable/NonRepairable
(Repair-WindowsImage -Online -CheckHealth).ImageHealthState

# SFC result without running a repair: parse CBS.log [SR] tail after a scan
sfc /verifyonly   # detect-only variant of scannow
```

### 3.2 Disk / file-system health

```powershell
fsutil dirty query C:                       # NTFS dirty bit
Repair-Volume -DriveLetter C -Scan          # returns NoErrorsFound / ErrorsFound...
Get-PhysicalDisk | Select FriendlyName, HealthStatus, OperationalStatus
Get-PhysicalDisk | Get-StorageReliabilityCounter |
  Select Wear, ReadErrorsTotal, WriteErrorsTotal, Temperature
# Event signals: NTFS corruption 55/98/130 (Ntfs), disk 7/51/153 (disk/storahci)
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Ntfs','disk'; Level=1,2,3; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue
```

### 3.3 Windows Update health

```powershell
# Service state of the pipeline
Get-Service wuauserv,bits,cryptsvc,DoSvc,UsoSvc | Select Name,Status,StartType

# Failure events: Microsoft-Windows-WindowsUpdateClient/Operational
#   19 install success | 20 install FAILURE | 21 completed w/ errors | 25 restart pending | 31 scan failure
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; Id=20,31; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue

# Last successful update (staleness signal)
(Get-HotFix | Sort InstalledOn -Descending | Select -First 1).InstalledOn

# History incl. HRESULTs via COM
$s = New-Object -ComObject Microsoft.Update.Session
$s.CreateUpdateSearcher().QueryHistory(0,25) | Select Date,ResultCode,HResult,Title

# Pending reboot (three canonical keys)
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) -ne $null
```

Verify after fix: `UsoClient StartScan`, wait, re-query event 19 vs 20.

### 3.4 Network / DNS

```powershell
Get-NetAdapter | Where Status -ne 'Up'                     # link layer
Test-NetConnection -ComputerName (Get-NetRoute 0.0.0.0/0 | Select -First 1 -Expand NextHop)  # gateway
Test-NetConnection 1.1.1.1 -InformationLevel Quiet          # raw IP internet (isolates DNS)
Resolve-DnsName microsoft.com -ErrorAction SilentlyContinue # DNS layer
Test-NetConnection www.msftconnecttest.com -Port 80         # captive-portal/NCSI style probe
Get-DnsClientServerAddress -AddressFamily IPv4
```

The IP-works-but-DNS-fails pattern is the discriminator that picks `flushdns`/resolver-change over winsock/IP reset.

### 3.5 Microsoft Store

```powershell
Get-AppxPackage -AllUsers Microsoft.WindowsStore | Select Name,Status,Version   # Status should be Ok
Get-Service AppXSvc,ClipSVC,InstallService,DoSvc | Select Name,Status
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-AppXDeploymentServer/Operational'; Level=2; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue
```

### 3.6 Search / Start menu

```powershell
Get-Service WSearch | Select Status,StartType                      # should be Running/Automatic (Delayed)
Get-Process SearchIndexer,SearchHost,StartMenuExperienceHost -ErrorAction SilentlyContinue
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Search'; Level=1,2} -MaxEvents 20 -ErrorAction SilentlyContinue
# Index catalog corruption signal: Windows.edb size 0 or gigantic (>10 GB)
Get-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -ErrorAction SilentlyContinue | Select Length
# App-crash signal for shell hosts: Application log, Event 1000, faulting module
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 50 | Where Message -match 'StartMenuExperienceHost|SearchHost'
```

### 3.7 Printing

```powershell
Get-Service Spooler | Select Status
(Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS").Count    # stuck spool files
Get-Printer | Select Name,PrinterStatus                             # Error/Offline states
Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue | Where JobStatus -match 'Error|Blocked'
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-PrintService/Admin'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue
```

### 3.8 BSOD / crash history

```powershell
# Bug checks: System log, Event 1001 (BugCheck) carries stop code + parameters + dump path
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001} -MaxEvents 10 |
  Select TimeCreated, @{n='BugCheck';e={$_.Properties[0].Value}}

# Dirty shutdowns (crash OR power loss): Kernel-Power Event 41
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41} -MaxEvents 10

# Dump inventory
Get-ChildItem C:\Windows\Minidump, C:\Windows\LiveKernelReports -Recurse -ErrorAction SilentlyContinue | Select FullName,LastWriteTime
```

Event 41 without a matching 1001 = power loss/hard hang, not a bug check — a useful discriminator.

### 3.9 Disk space

```powershell
Get-Volume | Select DriveLetter, @{n='FreePct';e={[math]::Round($_.SizeRemaining/$_.Size*100,1)}}, SizeRemaining, Size
# Component store bloat: parse 'Component Store Cleanup Recommended : Yes'
DISM /Online /Cleanup-Image /AnalyzeComponentStore
```

Threshold heuristics: warn <15% free, critical <200 GB-drive-relative ~10%; Windows itself degrades (updates fail) under ~20 GB free.

### 3.10 Slow boot

```powershell
# The gold signal: Microsoft-Windows-Diagnostics-Performance/Operational
#   100 = boot completed (BootTime ms in properties), 101-110 = named degradation causes (app/driver/service)
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 10 |
  ForEach-Object { [pscustomobject]@{ Time=$_.TimeCreated; BootMs=$_.Properties[0].Value } }
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=101,102,103,106,108,109} -MaxEvents 20   # names the offending app/driver/service
powercfg /a    # hiberboot (Fast Startup) availability
```

This gives longitudinal boot-time in milliseconds — perfect for a measure-first before/after story.

### 3.11 Audio

```powershell
Get-Service Audiosrv,AudioEndpointBuilder | Select Name,Status
Get-PnpDevice -Class AudioEndpoint,MEDIA -ErrorAction SilentlyContinue | Select FriendlyName,Status   # 'Error' = driver problem
Get-CimInstance Win32_SoundDevice | Select Name,Status,StatusInfo
```

### 3.12 Activation

```powershell
# LicenseStatus: 1 = Licensed; 0 Unlicensed; 2 OOB grace; 3 OOT grace; 5 Notification
Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" |
  Select Name, LicenseStatus, LicenseStatusReason
cscript //nologo C:\Windows\System32\slmgr.vbs /xpr
```

---

## 4. Implications for a measure-first tool

1. Every problem above has a **cheap read-only probe** (service state, event query, registry key, flag check) — a full "health scan" is feasible in seconds with zero side effects; only `/ScanHealth`, `sfc /verifyonly`, and `chkdsk /scan` are the slow probes.
2. Every canonical fix has a **verify probe = the same detection probe re-run**, plus fix-specific confirmations (SFC exit text, `ImageHealthState`, event 19 after a WU scan, boot-ms trend from Event 100).
3. Rungs 3–5 (repair reinstall, in-place ISO, Reset) are **guided handoffs**, not silent automations — but `setup.exe /auto upgrade /quiet /eula accept` is genuinely scriptable for consenting users, and `/compat scanonly` gives a pre-flight check.
4. 2025–2026 landscape shifts to encode: DISM-before-SFC ordering; `/eula accept` mandatory; `systemreset.exe` gone in 24H2+ (`SystemSettingsAdminFlows.exe FeaturedResetPC` unofficial replacement, or `ms-settings:recovery`); msdt troubleshooters retired; QMR exists but only covers Microsoft-published boot remediations; USOClient replaced wuauclt.

Sources: [Microsoft Learn — Windows Setup Command-Line Options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11), [Microsoft Support — Fix issues by reinstalling the current version of Windows](https://support.microsoft.com/en-us/windows/deployment/install-upgrade/fix-issues-by-reinstalling-the-current-version-of-windows), [Microsoft Learn — Additional resources for Windows Update (component reset)](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update), [Windows Central — Use DISM to repair a local image](https://www.windowscentral.com/software-apps/windows-11/how-to-use-dism-to-repair-local-image-on-windows-11), [memstechtips — SFC/DISM correct order](https://memstechtips.com/sfc-scannow-dism-repair-order-windows-11/), [inventivehq — SFC, DISM and chkdsk (2026)](https://inventivehq.com/blog/repair-windows-sfc-dism-chkdsk-commands), [Microsoft Q&A — DISM local source](https://learn.microsoft.com/en-us/answers/questions/5592194/how-do-i-make-a-local-source-for-dism-online-clean), [H2S Media — systemreset in 24H2/25H2](https://www.how2shout.com/how-to/factory-reset-windows-11-using-cmd-truth.html), [Windows Forum — Reset without systemreset.exe](https://windowsforum.com/threads/windows-11-24h2-25h2-reset-without-systemreset-exe-correct-steps.418474/), [Thurrott — Quick Machine Recovery (25H2)](https://www.thurrott.com/books/windows-11-field-guide/help-and-recovery/326454/quick-machine-recovery-25h2), [Windows Latest — Enable QMR](https://www.windowslatest.com/2025/08/05/use-enable-quick-machine-recovery-in-windows-11/), [inventivehq — USOClient/WU commands](https://inventivehq.com/blog/windows-update-commands-powershell-usoclient-amp-wuauclt), [Automox — WU event audit](https://www.automox.com/worklets/windows-update-events), [NinjaOne — Re-register Microsoft Store](https://www.ninjaone.com/blog/how-to-re-register-microsoft-store-in-windows-11/), [How-To Geek — netsh winsock reset](https://www.howtogeek.com/785351/how-and-why-to-perform-a-netsh-winsock-reset-on-windows/), [IT trip — WU event IDs + PowerShell](https://en.ittrip.xyz/windows/track-windows-update-log), [Microsoft Q&A — Event 41/1001 BSOD triage](https://learn.microsoft.com/en-us/answers/questions/3899257/event-41-kernel-power-and-event-1001-bugcheck), [pureinfotech — Repair Windows 11 via DISM or Windows Update](https://pureinfotech.com/repair-windows-11/)

## Key findings

- Repair ladder order (2025 consensus): CHKDSK if disk is suspect, then DISM /RestoreHealth BEFORE sfc /scannow (SFC copies repairs from the component store DISM fixes), then WU repair-reinstall, then in-place ISO repair, then Reset This PC.
- When Windows Update is broken, DISM repairs from a mounted ISO: DISM /Online /Cleanup-Image /RestoreHealth /Source:WIM:E:\sources\install.wim:1 /LimitAccess (or ESD: prefix); build/edition/index mismatch is the top failure cause and /LimitAccess is required to stop WU fallback.
- Scriptable in-place repair: setup.exe /auto upgrade /quiet /eula accept /noreboot preserves apps, files, settings, and drivers; starting with Windows 11 the /eula accept switch is MANDATORY (silent setup exits without it), and /compat scanonly gives a pre-flight check via exit code.
- systemreset.exe was silently removed in Windows 11 24H2/25H2; the unofficial replacement is SystemSettingsAdminFlows.exe FeaturedResetPC, or version-agnostic ms-settings:recovery deep link — Reset should be a guided handoff, not automated.
- Two new-era platform features matter: 'Fix problems using Windows Update' (Settings-based repair reinstall of the current build, preserves everything, 23H2+) and Quick Machine Recovery (25H2, auto-fixes known boot failures via WinRE+WU, on by default on Home).
- Canonical Windows Update fix is the documented component reset: stop wuauserv/cryptSvc/bits/msiserver, rename SoftwareDistribution and catroot2, restart; wuauclt is dead, use UsoClient StartScan/StartInteractiveScan.
- Every major problem class has a cheap read-only detection probe: Repair-WindowsImage -Online -CheckHealth (ImageHealthState), fsutil dirty query, Get-Service on pipeline services, three pending-reboot registry keys, and targeted Get-WinEvent queries.
- Highest-value event-log signals: WindowsUpdateClient/Operational IDs 19/20/21/25/31, System Event 1001 BugCheck (stop code + dump path) vs Event 41 Kernel-Power (41-without-1001 = power loss not BSOD), Diagnostics-Performance/Operational Event 100 (boot time in ms — perfect for measure-first before/after) and 101-110 (names the boot-degrading app/driver/service), Ntfs events 55/98/130.
- Canonical per-problem fixes verified: wsreset + Appx re-register (Store), WSearch stop + delete Windows.edb (search index), Spooler stop + clear spool\PRINTERS (printing), AudioEndpointBuilder+Audiosrv restart (audio), winsock/ip reset + flushdns sequence (network), DISM StartComponentCleanup + cleanmgr /sagerun (disk space), slmgr /ato + licensingdiag (activation).
- msdt.exe legacy troubleshooters are retired in the 2025 era (Get Help app replaced them), so a scriptable tool must implement fixes natively; verification = re-running the same detection probe post-fix.
