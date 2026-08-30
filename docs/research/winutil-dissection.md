# WinUtil (Chris Titus Tech) — Complete Feature Inventory & Capability Assessment

Source: shallow clone of `ChrisTitusTech/winutil` at commit `34f7ce5` (current main, Aug 2026 era), read from `C:/Users/Marte/AppData/Local/Temp/claude/C--Users-Marte-Documents-projects-fps-booster/11139f2f-9ca3-42a5-808c-c8636260d278/scratchpad/winutil`. All findings are from actual source (`functions/`, `config/*.json`, `tools/autounattend.xml`), not docs.

**Architecture in one paragraph:** A single-file PowerShell 5/7 WPF app (compiled from `functions/private+public` + `config/*.json` + `xaml/inputXML.xaml` by `Compile.ps1`), launched via `irm https://christitus.com/win | iex`, self-elevates to admin, runs work in background runspaces (`Invoke-WPFRunspace`) with a synchronized `$sync` hashtable. All tweak/feature/app definitions are **data-driven JSON**; a generic engine (`Invoke-WinUtilTweaks` → `Set-WinUtilRegistry` / `Set-WinUtilService` / `Invoke-WinUtilScript`) executes them. Headless mode exists: `start.ps1 -Config <file|url> -Preset Standard|Minimal|Advanced [-Offline]` → `Invoke-WinUtilAutoRun` applies tweaks → features → apps → AppX removal with no UI interaction.

---

## 1. Install Tab

**Catalog:** `config/applications.json` — **232 applications** across 10 categories: Browsers (15), Communications (18), Development (41), Document (17), Games (17), Microsoft Tools (18), Multimedia (21), Pro Tools (19), Selfhosted (10), Utilities (56). Each entry carries `winget` ID, `choco` ID, description, homepage link, and a `foss: true/false` flag (rendered as a FOSS badge).

**Capabilities:**
- **Dual package-manager backend**: user picks WinGet or Chocolatey via radio button. WinGet install: `winget install --id <ID> --accept-package-agreements --accept-source-agreements --source winget --silent` (also supports `msstore:` prefixed IDs → `--source msstore`). Choco path via `Install-WinUtilProgramChoco`.
- **Auto-bootstrap of the package manager itself**: `Install-WinUtilWinget` = `Install-PackageProvider NuGet -Force; Install-Module Microsoft.WinGet.Client -Force; Repair-WinGetPackageManager -AllUsers`. `Install-WinUtilChoco` for Chocolatey.
- **Install / Uninstall selected** (`Invoke-WPFInstall` / `Invoke-WPFUnInstall`), **Get Installed** (`Invoke-WPFGetInstalled` scans system and checks boxes for already-present apps), **Upgrade All** (`Invoke-WPFInstallUpgrade`: `winget upgrade --all --include-unknown --silent ...` or `choco upgrade all -y` in a spawned terminal).
- **Search/filter** (`Find-AppsByNameOrDescription`), category chips, "selected apps" menu, virtualized on-demand rendering of the app list, per-run package log summary (`Get-WinUtilPackageLogSummary`).
- Selections participate in config export/import (section 6).

## 2. Tweaks Tab — every tweak at registry/service level

`config/tweaks.json` — **66 entries** (checkbox tweaks, toggles, comboboxes, buttons). Engine semantics: each registry entry stores `Value` (apply) and `OriginalValue` (undo); `<RemoveEntry>` means delete the value. Services store `StartupType`/`OriginalType` (apply skips services the user already customized away from `OriginalType` — `KeepServiceStartup`). Free-form `InvokeScript`/`UndoScript` blocks for anything else. AppX lists are remove-only (no undo).

### Essential/standard tweaks
| Tweak | What it actually does |
|---|---|
| **Create Restore Point** | `SystemRestorePointCreationFrequency=0` (HKLM SystemRestore), `Enable-ComputerRestore` if none, `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`. **Opt-in, not automatic.** |
| **Telemetry - Disable** | 12 registry values: `AllowTelemetry=0` (HKLM Policies DataCollection), AdvertisingInfo `Enabled=0`, `TailoredExperiences...=0`, OnlineSpeechPrivacy `HasAccepted=0`, TIPC `Enabled=0`, InputPersonalization Restrict*=1, `HarvestContacts=0`, `AcceptedPrivacyPolicy=0`, `Start_TrackProgs=0`, `PublishUserActivities=0`, SIUF `NumberOfSIUFInPeriod=0`; plus script: `Set-MpPreference -SubmitSamplesConsent 2`, `Set-Service diagtrack -StartupType Disabled`, `Set-Service wermgr Disabled`, `POWERSHELL_TELEMETRY_OPTOUT=1` machine env var. Full UndoScript restores each. |
| **Services - Set to Manual** | Now only **5 services** (drastically trimmed from the old ~150-service list): CscService→Disabled, DiagTrack→Disabled, MapsBroker→Manual, StorSvc→Manual, SharedAccess→Disabled; plus sets `SvcHostSplitThresholdInKB` = total RAM (fewer svchost splits). |
| **Activity History - Disable** | `EnableActivityFeed/PublishUserActivities/UploadUserActivities=0` under HKLM Policies\Windows\System. |
| **ConsumerFeatures - Disable** | `DisableWindowsConsumerFeatures=1` (CloudContent policy). |
| **Location Tracking - Disable** | ConsentStore location `Value=Deny`, Sensor override `SensorPermissionState=0`, Maps `AutoUpdateEnabled=0`, service `lfsvc→Disabled`. |
| **Hibernation - Disable** | `HibernateEnabled=0`, `ShowHibernateOption=0`, `powercfg /hibernate off` (undo: on). |
| **Delivery Optimization - Disable** | `DODownloadMode=0` (policy). |
| **Storage Sense - Disable** | StoragePolicy `01=0` (HKCU). |
| **Windows AI - Disable And Remove** | `SettingsPageVisibility=hide:aicomponents`, Notepad `DisableAIFeatures=1`; script marks `MicrosoftWindows.Client.CoreAI` EndOfLife in AppxAllUserStore, removes all `*Copilot*` AppX (all users), `winget uninstall Copilot`, removes MicrosoftOfficeHub. |
| **Widgets - Remove** | Kills `*Widget*` processes, removes `Microsoft.WidgetsPlatformRuntime` + `MicrosoftWindows.Client.WebExperience` AppX all-users, restarts Explorer. |
| **Edge - Debloat** | 18 HKLM Edge policy values (disable shopping assistant, rewards, collections, sidebar promos, diagnostic data, desktop shortcut, first-run experience, extension blocklist entry, etc.). |
| **Edge - Remove** | Runs Edge's own installer `setup.exe --uninstall --system-level --force-uninstall --delete-profile` (after creating dummy `MicrosoftEdge.exe` SystemApps path to unlock removal). Undo: `winget install Microsoft.Edge`. |
| **OneDrive - Remove** | `icacls` deny-delete on OneDrive folder, `OneDriveSetup.exe /uninstall`, kills FileCoAuth/Explorer, deletes LocalAppData/ProgramData leftovers. Undo: `winget install Microsoft.Onedrive`, re-enable OneSyncSvc. |
| **Brave - Debloat** | 12 HKLM Brave policies (Rewards, Wallet, VPN, AI Chat, News, Talk, Tor, P3A, metrics all off). |
| **BitLocker - Disable** | `Disable-BitLocker -MountPoint $Env:SystemDrive` (undo: Enable-BitLocker). |
| **Visual Effects → Best Performance** | 12 HKCU values (`VisualFXSetting=3`, DragFullWindows=0, MenuShowDelay=200, MinAnimate=0, KeyboardDelay=0, ListviewAlphaSelect/Shadow=0, TaskbarAnimations=0, EnableAeroPeek=0, TaskbarMn=0, ShowTaskViewButton=0, SearchboxTaskbarMode=0) + binary `UserPreferencesMask`. |
| **Disk Cleanup - Run** | `cleanmgr.exe /d C: /VERYLOWDISK` + `Dism /online /Cleanup-Image /StartComponentCleanup /ResetBase`. |
| **Temp Files - Remove** | `Remove-Item $Env:Temp\* ; $Env:SystemRoot\Temp\*` recursive-force. |
| **Reserved Storage - Disable** | `DISM /Online /Set-ReservedStorageState /State:Disabled`. |
| **End Task on Taskbar right-click** | `TaskbarDeveloperSettings\TaskbarEndTask=1`. |
| **Classic right-click menu** | Creates HKCU CLSID `{86ca1aa0-...}\InprocServer32` empty value, restarts Explorer. |
| **Start Menu previous layout** | FeatureManagement override `8\3036241548 EnabledState=1`. |
| **Explorer Home/Gallery - Disable** | Unpin CLSIDs `{f874310e...}`/`{e88865ea...}`, `LaunchTo=1` (This PC). |
| **Explorer auto folder-discovery - Disable** | Deletes Shell `Bags`/`BagMRU` and forces `FolderType=NotSpecified` via script. |
| **Store recommended search results - Disable** | `icacls ...store.db /deny Everyone:F` (undo: /grant). |
| **WPBT - Disable** | `Session Manager\DisableWpbtExecution=1` (anti-vendor-firmware-injected software, e.g. Lenovo/ASUS). |
| **Razer auto-install block** | `SearchOrderConfig=0`, `DisableCoInstallers=1`, empties + write-denies `C:\Windows\Installer\Razer` via icacls. |
| **Adobe URL block list** | Downloads community hosts list from GitHub → appends to `drivers\etc\hosts`, `ipconfig /flushdns`. |
| **Notifications/Calendar - Disable** | `DisableNotificationCenter=1`, `ToastEnabled=0`. |
| **Background Apps - Disable** | `GlobalUserDisabled=1`. |
| **Device metadata / companion apps - Prevent** | `PreventDeviceMetadataFromNetwork=1`. |
| **UTC time** | `RealTimeIsUniversal=1` (dual-boot fix). |
| **IPv4 preferred / Teredo off / IPv6 off** | Tcpip6 `DisabledComponents` = 32 / 1 / 255 respectively; Teredo also `netsh interface teredo set state disabled`; IPv6 also `Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6`. |
| **RDP unsigned-file warnings off** | Terminal Services Client policy + `RdpLaunchConsentAccepted=1`. |

### Toggles (state read live from registry via `Get-WinUtilToggleStatus`)
Dark theme, file extensions, hidden files, detailed BSoD (`DisplayParameters=1`, `DisableEmoticon=1`), battery %, verbose logon, new Outlook toggle, always-visible scrollbars, **mouse acceleration** (MouseSpeed/Threshold1/Threshold2), NumLock at startup, window snapping, **S0 standby network disconnect** (power policy `f15576e8... ACSettingIndex`), **S3 sleep** (`PlatformAoAcOverride=0` — disables Modern Standby), Settings home page hide, Bing in Start search, logon acrylic blur, lock screen disable, Start recommendations, Sticky Keys, taskbar alignment/search/task-view, **Game Mode** (`AllowAutoGameMode`/`AutoGameModeEnabled`), long paths (`LongPathsEnabled=1`).

### Comboboxes & buttons
- **Multiplane Overlay (MPO)**: 3-state combo — Enabled (remove entries) / Disabled-Compatibility (`Dwm\OverlayTestMode=5`) / Fully Disabled (`OverlayTestMode=5` + `GraphicsDrivers\DisableOverlays=1`). *Directly gaming/frame-pacing relevant.*
- **DNS combo** (`Set-WinUtilDNS`, `config/dns.json`): Default/DHCP plus 14 providers incl. Google, Cloudflare (+malware/adult variants), OpenDNS, Quad9, AdGuard, 5 Mullvad filtering tiers — IPv4+IPv6 primary/secondary each.
- **O&O ShutUp10++ - Run**: downloads `OOSU10.exe` from oo-software.com and launches it (delegates deep privacy work to a third-party GUI).
- **Ultimate Performance power plan**: Enable = `powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61` + `/setactive`; Disable = **`powercfg /restoredefaultschemes`** (nukes all custom plans — blunt undo).

### Preset system (`config/preset.json`)
Standard (12 tweaks), Minimal (4), Advanced (17 + AppX removal list). Selectable in UI or via `-Preset` CLI arg.

## 3. Fixes section (feature.json panel 1 + panel 2 "legacy" buttons) — exact commands

### 3.1 Windows Update Reset (`Invoke-WPFFixesUpdate`, param `-Aggressive`)
The crown-jewel repair, 226 lines. Sequence:
1. *(Aggressive only)* run full System Corruption Repair (3.3).
2. `Stop-Service BITS, wuauserv, appidsvc, cryptsvc -Force`.
3. Delete BITS queue: `Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat"`.
4. *(Aggressive)* `Rename-Item SoftwareDistribution\DataStore → DataStore.bak`; `Rename-Item System32\Catroot2 → catroot2.bak`.
5. `Rename-Item SoftwareDistribution\Download → Download.bak`; delete `C:\Windows\WindowsUpdate.log`.
6. *(Aggressive)* reset service security descriptors: `sc.exe sdset bits "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)"` and same for `wuauserv`.
7. Re-register **36 DLLs** with `regsvr32 /s` from system32: atl, urlmon, mshtml, shdocvw, browseui, jscript, vbscript, scrrun, msxml/3/6, actxprxy, softpub, wintrust, dssenh, rsaenh, gpkcsp, sccbase, slbcsp, cryptdlg, oleaut32, ole32, shell32, initpki, wuapi, wuaueng(+1), wucltui, wups, wups2, wuweb, qmgr, qmgrprxy, wucltux, muweb, wuwebv.
8. Remove WSUS client identity: delete `AccountDomainSid`, `PingID`, `SusClientId` from `HKLM\...\WindowsUpdate`.
9. **Nuke all WU-related Group Policy**: removes driver-exclusion and auto-restart policy values, then `Remove-Item -Recurse -Force` on HKCU/HKLM `Policies`, `WindowsSelfHost`, `CurrentVersion\Policies`, WindowsStore\WindowsUpdate keys (incl. WOW6432Node); then `secedit /configure /cfg %windir%\inf\defltbase.inf /db defltbase.sdb /verbose`; `RD /S /Q System32\GroupPolicyUsers` and `System32\GroupPolicy`; `gpupdate /force`. *(Aggressively destroys ALL local group policy, not just WU policy — sledgehammer.)*
10. `netsh winsock reset`, `netsh winhttp reset proxy`, `netsh int ip reset`.
11. `Get-BitsTransfer | Remove-BitsTransfer` (delete all BITS jobs).
12. Restore services: BITS→Manual+start, wuauserv→Manual+start, AppIDSvc via registry `Start=3` (protected service) + start, CryptSvc→Manual+start.
13. Force detection: `(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()` and `wuauclt /resetauthorization /detectnow`. MessageBox: reboot required.

### 3.2 Network Reset (`Invoke-WPFFixesNetwork`) — 3 lines
```
netsh winsock reset
netsh int ip reset
# "please restart your computer"
```
(No DNS flush, no adapter reset, no proxy reset in the standalone fix.)

### 3.3 System Corruption Repair (`Invoke-WPFSystemRepair`, button "System Corruption Scan")
```
chkdsk /scan /perf        # online NTFS scan, max CPU
sfc /scannow              # protected-file scan+repair
dism /online /cleanup-image /restorehealth   # component-store repair from WU
```
Run sequentially via `cmd /c`, `-Wait`, output streamed to console. Note ordering: chkdsk → SFC → DISM (canonical best practice is DISM before SFC; WinUtil runs SFC first and does **not** re-run SFC after DISM repairs the store).

### 3.4 WinGet Reinstall (`Invoke-WPFFixesWinget`)
Calls `Install-WinUtilWinget`: if winget broken/absent → `Install-PackageProvider NuGet -Force; Install-Module Microsoft.WinGet.Client -Force; Repair-WinGetPackageManager -AllUsers`. (Modern PSGallery method; the old choco-based reinstall is gone.)

### 3.5 NTP fix (`Invoke-WPFFixesNTPPool`)
```
Start-Service w32time
w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL
Restart-Service w32time
w32tm /resync
```

### 3.6 AutoLogon (`Invoke-WPFPanelAutologin`)
Downloads Sysinternals `Autologon.exe` from live.sysinternals.com and runs it `/accepteula` (delegates; credentials never touch WinUtil).

### 3.7 Legacy panel shortcuts (panel 2)
One-click launchers: `compmgmt.msc`, `control`, `main.cpl`, `ncpa.cpl`, `powercfg.cpl`, printer shell CLSID, `appwiz.cpl`, `intl.cpl`, `wscui.cpl`, `mmsys.cpl`, `sysdm.cpl`, `timedate.cpl`, `firewall.cpl`, `rstrui.exe` (System Restore UI). Plus CTT PowerShell profile install/remove and **OpenSSH Server enable** (`Add-WindowsCapability OpenSSH.Server`, sshd+ssh-agent → Automatic+started, firewall rule TCP 22, administrators_authorized_keys setup with correct ACLs).

### 3.8 Features installer (same tab)
Windows optional features via DISM/`Enable-WindowsOptionalFeature`: .NET 2/3/4 (`NetFx3`,`NetFx4-AdvSrvs`), Hyper-V (`Microsoft-Hyper-V-All`), Legacy media (WMP, MediaPlayback, DirectPlay, LegacyComponents), WSL (`VirtualMachinePlatform`+`Microsoft-Windows-Subsystem-Linux`), NFS client (+ AnonymousUID/GID=0 registry + `nfsadmin` mount defaults), Windows Sandbox (`Containers-DisposableClientVM`), **daily registry backup task** (`EnablePeriodicBackup=1`, `BackupCount=2`, scheduled task triggering `RegIdleBackup` at 00:30), legacy F8 boot menu (`bcdedit /set bootmenupolicy legacy|standard`).

## 4. Updates Tab
Three modes (buttons), all logged via `Write-WinUtilLog`:
- **Default Settings** (`Invoke-WPFUpdatesdefault`): removes every WinUtil-managed WU policy value (NoAutoUpdate, AUOptions, defer values, driver-exclusion values, DODownloadMode, legacy UX\Settings values, legacy `hide:windowsupdate` page restriction), restores BITS→Manual, wuauserv→Manual, UsoSvc→Automatic+start, re-enables scheduled task trees `InstallService/UpdateOrchestrator/UpdateAssistant/WaaSMedic/WindowsUpdate/*`.
- **Security (Recommended) Settings** (`Invoke-WPFUpdatessecurity`): first restores availability (undoes disable mode), then: exclude drivers from WU (`ExcludeWUDriversInQualityUpdate=1`, `PreventDeviceMetadataFromNetwork=1`, DriverSearching Dont* values), **defer feature updates 365 days / quality updates 4 days** (`DeferFeatureUpdates=1/365`, `DeferQualityUpdates=1/4`), scheduled-install without reboot while logged in (`AUOptions=4`, `NoAutoRebootWithLoggedOnUsers=1`, `AUPowerManagement=0`).
- **Disable All Updates** (`Invoke-WPFUpdatesdisable`, with a Yes/No warning dialog): `NoAutoUpdate=1`, `AUOptions=1`, `DODownloadMode=0`; stop+disable BITS, wuauserv, UsoSvc; wipe `C:\Windows\SoftwareDistribution\*`; `Disable-ScheduledTask` on the six WU task trees.

## 5. MicroWin → now the "Win11 Creator" ISO tab (functions renamed `Invoke-WinUtilISO*`)
Important: **the classic MicroWin (offline WIM stripping + hive editing) has been replaced.** The current design deliberately does *not* modify the install image (except optional driver injection) — it stages everything through `autounattend.xml` + first-logon scripts. Flow (`Invoke-WinUtilISO.ps1`, 705 lines; `Invoke-WinUtilISOScript.ps1`, 540; `Invoke-WinUtilISOUSB.ps1`, 287):

1. **Browse & validate**: OpenFileDialog; `Mount-DiskImage`; verify `sources\install.wim|.esd` exists; `Get-WindowsImage` metadata must contain "Windows 11"; enumerates editions (index+name) into a picker. Rejects non-official/custom ISOs.
2. **Modify** (background runspace): create `~WinUtil_Win11ISO_<timestamp>` workdir; `robocopy <mountedISO> <workdir> /E`; then `Invoke-WinUtilISOScript`:
   - Writes **`autounattend.xml`** (base template `tools/autounattend.xml`, 522 lines, schneegans unattend-generator schema) with the selected image index injected into `ImageInstall/OSImage/InstallFrom/MetaData(/IMAGE/INDEX)`, plus a generated **`WinUtil-PostInstall.ps1`** chained before FirstLogon.ps1. That script (runs at first logon, transcript-logged to `C:\Windows\Setup\Scripts\WinUtil-PostInstall.log`):
     - Removes **19 provisioned AppX packages** (Clipchamp, BingNews/Search/Weather, GetHelp, OfficeHub, Solitaire, StickyNotes, OutlookForWindows, Paint, PowerAutomate, StartExperiencesApp, Todos, DevHome, FeedbackHub, SoundRecorder, ZuneMusic, QuickAssist, MSTeams).
     - Applies ~60 `reg.exe add` tweaks: LabConfig hardware bypasses (TPM/SecureBoot/CPU/RAM/Storage + `AllowUpgradesWithUnsupportedTPMOrCPU`), `OOBE\BypassNRO=1` (local account), telemetry off, Copilot off, Teams/Chat/OneDrive/new-Outlook/DevHome auto-install prevention, BitLocker device-encryption prevention (`PreventDeviceEncryption=1`), reserved storage off, empty Start pins (`ConfigureStartPins {"pinnedList":[{}]}`), Edge sidebar off, MRT via WU off, search-box suggestions off, full ContentDeliveryManager suggestion shutdown for Default-user hive (loads `C:\Users\Default\NTUSER.DAT`) and HKCU, **Windows Update hard-disabled during OOBE** (NoAutoUpdate, AUOptions=1, `UseWUServer=1` pointing WUServer to `http://localhost:8080`, services BITS/wuauserv/UsoSvc/WaaSMedicSvc `Start=4`) — re-enabled by later FirstLogon content.
     - Deletes telemetry/update scheduled-task definition files under `C:\Windows\System32\Tasks\...` (Compatibility Appraiser, CEIP, ProgramDataUpdater, Chkdsk Proxy, QueueReporting, and the WU task trees).
     - Uninstalls OneDrive (`OneDriveSetup.exe /uninstall`).
   - Stages all setup scripts redundantly at `sources\$OEM$\$$\Setup\Scripts` (fallback with `UseConfigurationSet=true`).
   - Writes `sources\ei.cfg` (EditionID/Retail/VL=0) and deletes stale `PID.txt`.
   - **Optional driver injection**: `dism /online /export-driver` from the running system; storage-class drivers (iaahci/iastor/vmd/irst/rst or Class=SCSIAdapter/HDC INFs) also staged to `$WinpeDriver$` for WinPE; mounts install.wim once, single `/Add-Driver /Recurse`, commit, with **before/after WIM metadata validation** (Languages/Edition/ProductType unchanged or it throws) and guaranteed discard/cleanup in `finally`.
3. **Export**: ISO via `oscdimg.exe` (auto-locates in Windows Kits, WinGet packages, PATH; auto-installs `Microsoft.OSCDIMG` via winget if missing) with `-m -o -u2 -udfver102 -bootdata:<BIOS+UEFI dual boot> -l"CTOS_MODIFIED"`; **or USB**: diskpart clean + FAT32 partition, `Format-Volume`, `Split-WindowsImage` into 3800 MB `install.swm` chunks when wim > 4 GB, `robocopy` contents.
4. **Session recovery**: detects an incomplete previous workdir and lets you jump straight to export. **Clean & reset**: unmounts stray WIM mounts (`DISM /Cleanup-Wim` fallback), deletes the 10–15 GB workdir. Everything logged to `WinUtil_Win11ISO.log`.

## 6. Config import/export (`Invoke-WPFImpex`)
- **Export**: SaveFileDialog → flat JSON array of all selected app/tweak/toggle/feature/appx checkbox IDs; also **puts a ready-made one-liner on the clipboard**: `iex "& { $(irm https://christitus.com/win) } -Config '<path>'"` — i.e., a shareable unattended re-apply command.
- **Import**: from local file **or URL** (`Invoke-WebRequest`); detects and flattens the legacy `{Install:[], WPFInstall:[]}` schema, validates every key against current catalogs before applying (all-or-nothing for modern configs; skip-and-report for retired legacy keys), then checks the UI boxes.
- **Headless**: `-Config` + optional `-Preset` at launch runs `Invoke-WinUtilAutoRun` (tweaks → features → apps → appx removal) unattended. This is WinUtil's "fleet provisioning" story.

## 7. AppX removal tab
`config/appx.json` — 33 curated Microsoft packages (FeedbackHub, GetHelp, new Outlook, Teams, Clipchamp, OfficeHub, ZuneMusic, BingSearch/News/Weather, QuickAssist, DevHome, CrossDevice, Todos, PowerAutomate, YourPhone, StickyNotes, SoundRecorder, Alarms, Paint, Notepad, ScreenSketch, **Copilot**, Calculator, Camera, Photos, GamingApp, Xbox* (4), StartExperiencesApp, Solitaire). Removal = `Remove-AppxPackage -AllUsers` + `Remove-AppxProvisionedPackage` (so new users don't get them back). Reinstall path exists (`Invoke-WPFAppxInstall`).

---

## 8. Assessment — what WinUtil does badly or not at all

**No measurement whatsoever.** This is the decisive gap for FrameForge. WinUtil never benchmarks, never captures FPS/frametime/latency/CPU/GPU counters, never runs a before/after comparison, and makes zero attempt to verify a tweak had any effect beyond "the registry write succeeded". Every tweak is faith-based; the UI cannot tell the user whether "Set Services to Manual" gained them anything. There is no PresentMon-class instrumentation, no A/B methodology, no reporting.

**Undo is shallow and partially fictional.**
- Undo only works on tweaks the user *re-selects* and clicks "Undo Selected" for — there is no change journal, no "restore system to pre-WinUtil state" from an actual snapshot.
- `OriginalValue` is a **hardcoded assumed Windows default in tweaks.json**, not the machine's actual pre-change value. If your system had a non-default value (OEM, GPO, another tool), undo overwrites it with WinUtil's guess.
- Registry entries created with `OriginalValue: "<RemoveEntry>"` do delete cleanly, but script-based tweaks vary: several have **no UndoScript at all** (Widgets removal, Disk Cleanup, Temp files, Restore Point, Explorer discovery partially), AppX removals are explicitly not undone by the engine, and Edge/OneDrive undo is "winget install it again" (profiles/settings lost). Ultimate Performance undo is `powercfg /restoredefaultschemes`, destroying *all* custom power plans.
- **None of the Fixes have any undo**, and the WU Reset's policy nuke (`Remove-Item -Recurse` on entire `Policies` hives + deleting `GroupPolicy` folders + secedit baseline reset) silently destroys unrelated local policy — a real footgun on managed or hand-tuned machines.

**Safety model is thin.** Restore point creation is an opt-in tweak, not an enforced precondition. No dry-run/preview of what will change, no per-change diff, no conflict detection between tweaks (e.g., three different tweaks fight over `Tcpip6\DisabledComponents` = 32/1/255 — last applied wins, undo restores 0 regardless). Errors are logged and swallowed (`SilentlyContinue` everywhere); a partially-applied tweak still reads as done. Runs arbitrary `iex (irm URL)` as admin by design; downloads executables (OOSU, Autologon) over HTTPS with no hash pinning.

**UI/UX**: WPF via hand-assembled XAML + runtime-generated controls; functional, themable (themes.json, dark/auto), searchable, with taskbar progress — but it's a checkbox wall with tooltips, console-window log output, MessageBox interrupts, and no guided flow, no explanation of trade-offs per tweak beyond a sentence, no result summary/report after a run. Windows-only PowerShell 5.1-compatible codebase; the single generated ~1MB script is hard to audit for end users.

**No hardware awareness.** Nothing is conditioned on CPU/GPU/RAM/laptop-vs-desktop (except the svchost RAM threshold). MPO disable, Game Mode, power plans, mouse settings are offered identically to every machine. No per-game or per-process profiles, no GPU driver-level settings (NVIDIA/AMD control panel domains untouched), no overlay/latency features.

**Repairs are canonical but crude.** The command sequences (section 3) are the well-known community recipes — good raw material — but: network reset omits `ipconfig /flushdns`, adapter/proxy cleanup; system repair runs SFC before DISM and never re-runs SFC; WU reset conflates "repair WU" with "wipe all local group policy"; there is no diagnosis step anywhere (nothing checks *what* is broken before firing the full sledgehammer), no post-fix verification, and no log-based success/failure report to the user.

**What a competitor must match to be credible**: the JSON-driven tweak catalog with per-item apply/undo metadata, dual package-manager app install with headless config import/export + shareable one-liner, the WU/network/corruption/winget repair recipes, Updates policy management, and (optionally) the unattend-based clean-ISO builder. **Where it is beatable**: measurement-driven validation, true state-capture undo (journal actual prior values), diagnosis-before-repair, per-fix verification, hardware-aware recommendations, and a safety model with enforced restore points and previews.

## Key findings

- WinUtil is a data-driven PowerShell/WPF app: 232-app installer (winget/choco), 66 tweaks in tweaks.json (registry/service/script triples with hardcoded 'OriginalValue' undo data), 33 AppX removals, 33 features/fixes, plus headless -Config/-Preset automation with a shareable iex one-liner export.
- Classic MicroWin is gone: the current 'Win11 Creator' ISO tab no longer strips the WIM offline — it stages ~60 registry tweaks, 19 AppX removals, hardware-check bypasses, and OneDrive removal through autounattend.xml first-logon scripts, with optional DISM driver injection into install.wim, oscdimg ISO export, and FAT32-split USB writing.
- Windows Update Reset is the flagship fix: stop BITS/wuauserv/appidsvc/cryptsvc, delete qmgr*.dat, rename SoftwareDistribution\Download (+DataStore/catroot2 in Aggressive), regsvr32 36 DLLs, remove WSUS IDs, netsh winsock/winhttp/ip resets, delete BITS jobs, restart services, force detection — but it also recursively deletes ALL local Group Policy hives and GroupPolicy folders, a major footgun.
- Other fixes are short canonical recipes: Network Reset is only 'netsh winsock reset + netsh int ip reset' (no DNS flush); System Repair is chkdsk /scan /perf → sfc /scannow → dism /restorehealth (SFC before DISM, never re-run); WinGet repair uses Repair-WinGetPackageManager; NTP fix points w32tm at pool.ntp.org.
- Updates tab has three policy modes: Default (remove all WinUtil WU policies, restore services/tasks), Security (defer features 365d/quality 4d, exclude drivers, no auto-reboot), and Disable (NoAutoUpdate=1, disable BITS/wuauserv/UsoSvc, wipe SoftwareDistribution, disable six WU task trees).
- WinUtil has zero measurement: no benchmarking, no before/after FPS/frametime/latency capture, no verification a tweak did anything — the single biggest gap FrameForge's measure-first approach exploits.
- Undo is shallow: per-tweak 'OriginalValue' is an assumed Windows default hardcoded in JSON (not the machine's actual prior state), several tweaks and all Fixes have no undo at all, AppX removals are never undone, and restore-point creation is opt-in rather than enforced.
- No diagnosis or verification around repairs: fixes fire the full sledgehammer without checking what is broken first and never confirm success afterward; errors are broadly swallowed with SilentlyContinue.
- Notable gaming-relevant tweaks worth matching: Multiplane Overlay 3-state disable (OverlayTestMode=5 / DisableOverlays=1), Game Mode toggle, mouse acceleration, Ultimate Performance plan (undo nukes all custom plans via /restoredefaultschemes), svchost split threshold, S3 sleep/Modern Standby override, and the trimmed 5-service 'Services to Manual' list.
- Beatable dimensions for a competitor: measurement-driven validation, true state-capture undo journaling, diagnose-before-repair with post-fix verification, hardware-aware recommendations, dry-run previews, and scoping the WU reset so it does not destroy unrelated local policy.
