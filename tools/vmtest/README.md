# FrameForge VM test harness

Everything FrameForge knows about itself today was measured on **one machine** — a Windows 11 Pro
25H2, en-US, x64, non-domain desktop — **entirely unelevated**, and **no repair has ever actually
been executed anywhere**. This harness closes that gap: it provisions real Windows VMs, breaks them
on purpose, and runs the repairs for real, elevated, with every result written down.

It exists to answer one question mechanically:

> When something is genuinely broken, does FrameForge's read-only probe **say so** — on Windows in a
> language nobody here speaks, on an edition nobody here runs, on a build nobody here has?

A probe that reports `ok` over a fault the harness *knows* it injected fails with code
**`false-pass`**. That is the worst bug class in this codebase (docs/GAUNTLET.md rule 2), and it is
exactly what English text parsing produces on localized Windows. A probe that reports `unknown` over
the same fault also fails — code `detect-unknown` — because "could not determine" is honest but is
still a hole in the measurement.

---

## Contents

| File | What it is |
|---|---|
| `matrix.json` | The cell definitions, the fault catalogue, and the per-repair plan. Read this first — every cell records the assumptions it exists to kill, and `nonVirtualisableCells` records the ones no VM can. |
| `New-TestVm.ps1` | Provisions one cell: Gen 2 VM, vTPM + Secure Boot, dynamic memory, differencing disk off a per-build base VHDX, unattend ISO. |
| `unattend/*.xml` | autounattend templates, one per locale/architecture. Local account in `oobeSystem`, locale/keyboard per cell, OOBE skipped. |
| `guest/_faultlib.ps1` | Shared helpers for the in-guest fault scripts. Deliberately shares **no code** with `engine/_lib.ps1`. |
| `guest/faults/*.ps1` | One fault per fixable condition, each with `inject`, `revert`, `probe`, `describe`. |
| `guest/setup/Initialize-Guest.ps1` | The one-time per-cell baseline (execution policy, System Protection, environment fingerprint). |
| `Invoke-VmMatrix.ps1` | The orchestrator. Runs cell × repair and writes the results matrix. |
| `Test-VmHarness.ps1` | **Static, read-only validation of everything above.** No VM, no ISO, no elevation, nothing created. Run it after touching anything in this directory; `npm run test:engine` runs it too (the `VMTEST` area of `engine/test`). |

---

## Prerequisites

### 1. Enable Hyper-V — and reboot

```powershell
# elevated
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
# then REBOOT. The hypervisor is loaded at boot; nothing here works until you have restarted.
```

Confirm afterwards with `Get-Command New-VM` and `Get-Service vmms`.

Hyper-V requires SLAT and hardware virtualisation enabled in firmware, and it conflicts with other
hypervisors (VirtualBox and VMware run degraded or not at all once Hyper-V owns the CPU).

### 2. Everything else

* **An elevated PowerShell session on the host.** PowerShell Direct, `New-VM`, `Set-VMKeyProtector`
  and `Enable-VMTPM` all require it.
* **Windows PowerShell 5.1** — every script here targets it (the dev box runs 5.1.26100).
* **A guest password.** There is no default, on purpose:

  ```powershell
  $env:FF_VMTEST_PASSWORD = 'choose-something-long-and-throwaway'
  ```

  It is written into `autounattend.xml` in **clear text** (see the template header for why the
  obfuscated form is not worth the risk of a silently unusable VM). The unattend ISO is deleted
  after the base install unless you pass `-KeepUnattendIso`. **Never reuse a password you care
  about, and never give these VMs a routable path to anything you care about.**
* **`oscdimg.exe` — optional.** `New-TestVm.ps1` looks for it in `$env:FF_OSCDIMG`, on `PATH`, in the
  ADK Deployment Tools (resolved from the `KitsRoot10` registry value as well as the usual Program
  Files paths), and in the WinGet links directory. If none resolve it builds the unattend ISO with
  the IMAPI2 COM writer that ships with Windows, and **says which builder it used** in its result.
  To install it: `winget install Microsoft.OSCDIMG`, or the ADK's *Deployment Tools* feature.

  > `engine/image.ps1` has **no** oscdimg locator — it was read for one and does not contain one.
  > The only prior art in the repo is `docs/research/winutil-dissection.md` §Export, describing
  > WinUtil's ladder; `New-TestVm.ps1` implements the same ladder in this codebase's style.

### 3. Media

**Get it from Microsoft. Nowhere else.** An ISO from a "download site" is not a Windows install, it
is somebody's modified image, and a matrix run against one measures that person's edits.

| Cell | Where the ISO comes from |
|---|---|
| Pro 25H2 en-US, Pro 23H2 en-US, Pro 24H2 de-DE / ja-JP | **Consumer multi-edition ISO** — [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11) → *Download Windows 11 Disk Image*. Pick the language there; the same ISO carries Home and Pro. `data/state/tools/Fido.ps1` (already in this repo, used by `image.ps1`) fetches the same files and can enumerate **prior releases** such as 23H2. |
| Home 24H2 en-US | The consumer multi-edition ISO — the **only** legitimate source of Home. |
| ARM64 24H2 | The ARM64 consumer ISO on the same page. Boots only on an ARM64 host. |
| Anything you cannot get above | **Evaluation Center** 90-day ISOs: [microsoft.com/evalcenter](https://www.microsoft.com/evalcenter) → Windows 11 Enterprise. |

Two honest warnings about the Evaluation Center:

* It publishes **Enterprise**, never Home and never Pro. If you build the "Pro 23H2" cell from an
  Enterprise eval ISO, you are testing Enterprise 23H2 — set `imageName` to
  `Windows 11 Enterprise Evaluation` and **say so in the results** rather than labelling it Pro.
* Eval images expire after 90 days and behave differently once they do. Rebuild the base rather than
  running a matrix on an expired image.

**Localized cells need localized ISOs.** An en-US install with a German language pack bolted on
afterwards leaves English MUI resources in place; half the text parses still match, and the cell
reports a false pass. Download *Deutsch* / *日本語* from the disk-image page.

Before the first base build, confirm the edition name the unattend asks for actually exists in the
media:

```powershell
Mount-DiskImage -ImagePath D:\ffvm\iso\Win11_24H2_German_x64.iso
dism /Get-WimInfo /WimFile:E:\sources\install.wim   # or install.esd on some ISOs
```

Put the ISOs in `D:\ffvm\iso\` under the `iso.fileName` each cell declares.

---

## Disk budget

VMs live on **`D:`** because `C:` on this box is tight. Measured at the time of writing:
**`D:` ≈ 231 GB free, `C:` ≈ 147 GB free.**

| Item | Each | Count | Total |
|---|---|---|---|
| Base VHDX (dynamic, 64 GB max, ~22–26 GB used after install + Initialize-Guest) | ~25 GB | 6 base keys | **~150 GB** |
| ISOs (25H2 en-US, 24H2 en-US, 23H2 en-US, 24H2 de-DE, 24H2 ja-JP) | ~6 GB | 5 | **~30 GB** |
| Differencing disk + `clean` checkpoint per cell, steady state | 5–15 GB | 6 cells | **~50 GB** |
| Results and evidence | tiny | | < 1 GB |

That is **~230 GB against ~231 GB free**. It does not fit with any margin, so plan for it:

* **Build bases one at a time**, in waves. Six base VHDXs is the expensive half.
* **Keep the ISOs you still need.** `dism-restorehealth` and `enable-netfx3` need the cell's ISO
  attached at run time (the cells have no network, so DISM cannot fall back to Windows Update). If
  you skip those rows on a cell you can delete that cell's ISO.
* Park ISOs on another volume and point `-IsoPath` at them, or edit `defaults.isoRoot`.
* A finished cell can be deleted (`Remove-VM` + delete its differencing VHDX) and recreated from its
  base in about five minutes; only the base is expensive.

---

## Quick start

```powershell
# 0) Check the harness itself. Static and read-only: parses every script, resolves every variable
#    a success path reads, validates every unattend template, and checks matrix.json against the
#    engine's real catalogs. Do this before you spend 40 minutes on a Windows install.
.\Test-VmHarness.ps1

# 0b) See what would happen. Touches nothing, needs no elevation, needs no Hyper-V.
.\New-TestVm.ps1 -Cell pro-25h2-en-us-x64 -Plan
.\Invoke-VmMatrix.ps1 -Plan

# 1) Build the base image for a cell (slow: a full Windows install, 20-40 min).
$env:FF_VMTEST_PASSWORD = 'choose-something-long-and-throwaway'
.\New-TestVm.ps1 -Cell pro-25h2-en-us-x64 -Role base

# 2) Build the cell itself off that base and checkpoint it as 'clean' (~5 min).
.\New-TestVm.ps1 -Cell pro-25h2-en-us-x64 -Role cell

# 3) Run something small first.
.\Invoke-VmMatrix.ps1 -Cells pro-25h2-en-us-x64 -RepairSet smoke

# 4) The rows that matter most on a localized cell.
.\Invoke-VmMatrix.ps1 -Cells pro-24h2-de-de-x64 -RepairSet locale-critical

# 5) Everything, with a switch attached for the rows that genuinely need a network.
.\Invoke-VmMatrix.ps1 -SwitchName 'Default Switch' -StopOnFalsePass
```

Useful switches: `-Repairs sfc-scannow,chkdsk-scan` to narrow, `-SkipUndo` to shorten,
`-StepTimeoutMinutes` for the sfc/DISM-heavy rows, `-StopOnFalsePass` to halt the moment the thing
this harness is looking for appears.

---

## How it works, and why

### PowerShell Direct, not the network

Every command to a guest goes over the **VMBus** (`Invoke-Command -VMName`, `New-PSSession -VMName`,
`Copy-Item -ToSession`). No WinRM, no SSH, no share — and, on most cells, **no virtual network
adapter at all**. This is a requirement, not a preference:

* `winsock-reset` runs `netsh winsock reset` and `netsh int ip reset`. It tears down the winsock
  catalogue and rebuilds the IP stack. A network-based control channel dies *in the middle of the
  command whose result is being measured*, and the harness could then no longer tell "the repair
  worked" from "the repair killed networking permanently" — the single most important thing to know
  about that repair.
* `network-flush` and `dns-change-resolver` rewrite the resolver configuration a network channel
  would need to find the guest.
* No adapter also means no cumulative updates arriving between the checkpoint and the assertion,
  which is how the cells stay deterministic without changing any configuration.

`Copy-VMFile` is the documented alternative for pushing files in (it needs the *Guest Service
Interface* integration service, which `New-TestVm.ps1` enables). The harness uses `Copy-Item
-ToSession` instead because it copies whole trees over the session that is already open; `Copy-VMFile`
matters only if a guest's PowerShell is too broken to host a session.

### Windows 11 requirements are met, not bypassed

Generation 2 + Secure Boot on (`MicrosoftWindows` template) + a vTPM created with
`Set-VMKeyProtector -NewLocalKeyProtector` followed by `Enable-VMTPM`. Setup's TPM 2.0 and Secure
Boot checks pass on their own terms. The moment a harness starts writing `LabConfig\BypassTPMCheck`
it is testing a Windows configuration no user has, and every BitLocker / Device Encryption /
measured-boot finding from it is worthless.

### The local account is the OOBE story

`oobe\bypassnro.cmd` was **removed** in recent 24H2/25H2 builds, so any harness built on it stops
working on exactly the newest cells it most needs. Defining `<LocalAccounts>` in the `oobeSystem`
pass with `HideOnlineAccountScreens` is not a bypass at all — it is the supported unattended path,
and it behaves identically on 23H2, 24H2 and 25H2.

### Standard checkpoints

`clean` is a **Standard** checkpoint, so it captures guest memory and `Restore-VMCheckpoint` returns
a *running* guest in seconds. A Production checkpoint would be application-consistent but would
restore to a powered-off VM, adding a full boot to every one of ~150 rows.

### One setting the harness changes in the guest

The **unattend** sets `LocalAccountTokenFilterPolicy=1`, in the `specialize` pass, via a
`RunSynchronousCommand` that runs as **LOCAL SYSTEM before first logon**. PowerShell Direct
authenticates a *local* account, and a non-RID-500 local admin reaching a machine
non-interactively gets a **UAC-filtered token** — every elevated probe would degrade to
`needs-admin` and every repair would refuse, which looks exactly like an engine failure and is not
one. The orchestrator asserts elevation at the start of every row and skips with a named reason
rather than producing verdicts from an unelevated run.

It used to be `Initialize-Guest.ps1` that set it, as its step 4 — **after** two steps that need
the elevated token (`Set-ExecutionPolicy -Scope LocalMachine` and `Enable-ComputerRestore` are
both HKLM writes), and the policy write is an HKLM write too. On the harness's own premise that
could never have completed a first run: the script cannot grant itself the privilege it needs in
order to grant itself that privilege. Moving it into the unattend resolves the circularity in the
direction that is true whichever way the premise falls, because `specialize` runs as SYSTEM before
any logon exists to be filtered. `Initialize-Guest.ps1` now **measures its own token first and
refuses if it is filtered**, and **reads the policy value back** instead of assuming a write took
effect — so a base VHDX built from an older unattend template fails loudly at provisioning time
instead of producing cells whose every elevated row looks like an engine defect.

### The oracle is independent

The fault scripts share **no code** with the engine. They read exit codes, registry DWORDs, file
lengths, and structured objects (`Get-AppxPackage`, `Get-WindowsOptionalFeature`) — never a phrase
printed by a Win32 tool. If they dot-sourced `engine/_lib.ps1`, a locale bug in the engine would be
reproduced identically in the oracle, the two would agree, and the matrix would report a confident
green while both halves were wrong.

### One row, end to end

1. Restore `clean`; wait for PowerShell Direct.
2. Attach a NIC only if the plan says `requiresNetwork`.
3. Copy the engine (`engine/` + `data/`, side by side — `repair.ps1` resolves its catalogue as
   `<parent of engine>\data`) and the fault scripts in.
4. Assert the session is elevated.
5. **baseline-clean** — `repair.ps1 -Action preflight` must report `healthy`. If not, the checkpoint
   is dirty: the row is `skip / baseline-not-clean` and nothing is concluded.
6. **fault-injected** — run the fault; its own oracle must confirm the break.
7. **fault-detected** — preflight again. `problem` + a matching finding, or the row fails:
   `false-pass` / `detect-unknown` / `wrong-finding`.
8. **repair-ran** — `repair.ps1 -Action run` for real (with `-SourcePath` off the attached ISO where
   the plan says so).
9. **reboot** — from inside the guest (`shutdown /r`, so autochk actually runs), then wait for
   PowerShell Direct to come back.
10. **verify-healthy** — the same probe must now report healthy *and* the run must report
    `verified`. On `detected-not-verified` rows the assertion is inverted: the run must report it
    did **not** fix it, with a reason.
11. **undo-restored** — for reversible repairs, undo, then re-read the oracle. The state the repair
    captured and must restore **is** the faulted state the harness injected, so a correct undo makes
    the oracle read *faulted* again. (`shell-restart` is the documented no-op: the assertion is that
    undo says so rather than inventing a restore.)
12. Collect the ledger, write the evidence, restore `clean` — always, even on failure.

---

## Reading the results

Each run writes `D:\ffvm\results\run-<timestamp>\`:

```
results.json            every row, machine-readable, including skips
summary.md              the human version: false passes first, then the matrix
locale-divergence.json  each cell's clean-baseline deep scan vs the control cell's
<cell>/baseline-deep-scan.json
<cell>/<repair>/00-network.json
                  01-guest-elevation.json
                  02-baseline-preflight.json
                  03-fault-inject.json         <- the oracle's confirmation
                  04-detect-preflight.json     <- THE decisive document
                  05/06-source-media.json
                  07-repair-run.json
                  08-verify-preflight.json
                  09-repair-undo.json
                  10-undo-groundtruth.json
                  11-ledger.json
```

A verdict you cannot trace to those files is not a verdict — which is why a row whose evidence could
not be written fails with `evidence-lost` regardless of what the guest said.

### Outcomes

`pass` · `fail` · `skip`. **A skip is never rendered as a pass and never omitted.**

| fail code | Meaning |
|---|---|
| **`false-pass`** | Fault confirmed present, probe said healthy. **Stop and fix.** On a locale cell, look first for a verdict reached from English console text. |
| `detect-unknown` | Probe said `unknown` over a confirmed fault. Honest, but the signal could not be read — usually a text parse with no structural rung beneath it. |
| `wrong-finding` | The category noticed *something*, but nothing matching this repair's `relevantFindings`. The probe is pointed at the wrong signal. |
| `fault-injection-failed` | The harness could not break it, or could not confirm the break. **Nothing is concluded about the engine.** |
| `repair-refused` / `repair-failed` | The repair refused despite a detected fault, or a step that counts failed. |
| `verify-not-healthy` | Steps completed, fault still there. |
| `false-success` | The run claimed success where the honest answer was "could not fix" (the `activation-retry` and `winget-repair` rows exist to catch this). |
| `undo-not-restored` | Undo ran but the oracle does not read the captured prior state. Doctrine rule 3. |
| `reboot-timeout` / `step-timeout` | The guest never came back, or a command was stopped at the timeout. No verdict is recorded either way. |
| `evidence-lost` / `engine-error` | Evidence could not be written; or the engine emitted something unparseable. |

| skip code | Meaning |
|---|---|
| `cell-unavailable` | No VM, no checkpoint, no elevation, no switch for a network row, or an ARM64 cell on an x64 host. |
| `baseline-not-clean` | The `clean` checkpoint was already unhealthy for that category. Rebuild the cell; read nothing into the engine. |
| `no-synthetic-fault` | The condition cannot be created honestly in a VM. |
| `no-automatable-outcome` | A consent-gated guided handoff with nothing to assert. |
| `not-applicable-on-this-build` | The catalogue's build gate fired — itself a result worth having. |
| `needs-domain-controller` | The branch needs real domain membership, which this harness does not build. |

### locale-divergence.json

Compares each cell's clean-baseline **deep** scan against the control cell's, category by category.
A category that reads `ok` on the control and `unknown` on a localized cell of the same edition is a
locale bug found without running a single repair. Divergence is not automatically a bug — a Home
cell legitimately differs — which is why the file marks only the `ok → unknown` case as
`suspect-locale-bug` and everything else as `informational`.

---

## Expected runtime

| Phase | Time |
|---|---|
| `-Role base` (full Windows install + Initialize-Guest) | 20–40 min per base key; **2–4 h for all six** |
| `-Role cell` (differencing disk, conditioning, checkpoint) | ~5 min per cell |
| One fast row (checkpoint restore, copy, probe, inject, probe, run, verify) | 2–4 min |
| One reboot row (`chkdsk-*`, `sfc`, `dism`, `winsock-reset`) | 6–20 min |
| `-RepairSet smoke` (5 rows) | ~20–30 min per cell |
| `-RepairSet locale-critical` (13 rows) | ~1.5–2.5 h per cell |
| `-RepairSet full` (~24 executable rows) | ~3–5 h per cell |
| The whole matrix, six cells | **most of a day** — run it overnight, or by cell |

Dominated by `sfc /scannow`, `DISM /RestoreHealth`, `store-reregister-all` and the boot-time chkdsk.

---

## What this harness cannot cover

Being explicit about this matters more than the green rows. Full detail lives in
`matrix.json` → `nonVirtualisableCells`.

* **A laptop on battery — and this is the important one.** Hyper-V **emulates no battery**. There is
  no ACPI battery device in a Gen 2 VM, so `Win32_Battery` returns *nothing* and the power source
  always reads as AC. That is the worst possible shape for this codebase: a check written as "if a
  battery exists and is discharging, warn" evaluates to *no battery → not discharging → fine* and
  emits a confident **PASS on a machine it never measured**. It is a false pass produced by absence,
  and no VM configuration fixes it. `image.ps1`'s AC-rail gate — the one that stops a Windows
  reinstall starting on battery — is permanently green in a VM, so its refusal path has never
  executed. Cover it on **real hardware, unplugged**, or by putting the CIM query behind a seam and
  unit-testing three fixtures (no battery / on AC / discharging) with the assertion that *no battery*
  produces "could not determine". The mock proves the branch; only hardware proves the measurement.
* **A real GPU.** No NVAPI, no PresentMon capture. `nvidia.ps1` and `measure.ps1` stay
  single-machine.
* **Real disk failure.** A VHDX always reports healthy; SMART and media-error findings can never
  fire. The dirty bit and file-system corruption *are* injectable, and are.
* **Real domain membership.** The WSUS cell is policy pinning without a domain controller.
  `ntp-resync`'s domain refusal stays untested.
* **Audio devices.** The service half of `audio-restart` is covered; there is no device to be in an
  error state.
* **`component-cleanup` / `component-cleanup-resetbase`.** The finding needs genuinely superseded
  components — the residue of real cumulative updates — which cannot be synthesized on a fresh image
  without letting the VM take updates from the internet and destroying determinism. Both are
  `skip / no-synthetic-fault`. Note that this gap sits directly on top of a known English-text parse
  site (`health.ps1` ~736).
* **Attribution on the `chkdsk-spotfix` row.** The catalogue marks it `requiresReboot`, and *any*
  boot of a volume with the dirty bit set runs `autochk`, which repairs and clears it. So the
  post-reboot healthy verdict on that row is not attributable to the repair alone - the reboot alone
  would have produced it. The trustworthy assertion there is **fault detection**, which happens
  before anything restarts. `matrix.json` marks rows like this with a `confound` field; read it
  before citing a pass. (`chkdsk-full-repair` is the opposite case: there the boot-time check *is*
  the repair.)
* **The real world.** These cells are clean Microsoft media: no OEM bloat, no third-party AV holding
  `SoftwareDistribution` open, no printers, no VPN filter driver in the winsock catalogue. Every
  repair is being measured in its **best case**. A fully green matrix means "correct on clean
  Windows in six configurations", never "validated on real machines".

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `-Role base` ends with `install-timeout` | Connect with `vmconnect` and look at where Setup stopped. Usually: the `imageName` is not in that ISO (check `dism /Get-WimInfo`), a malformed `autounattend.xml`, or an ISO whose `install.wim` is really `install.esd`. |
| `provisioning-marker-missing` | PowerShell Direct answered but the FirstLogonCommands did not all run. The install is rejected on purpose — a half-provisioned base would poison every cell built from it. |
| Every row is `skip / cell-unavailable` with "not elevated" | `LocalAccountTokenFilterPolicy` is not 1 on this image. It is set by the unattend's `specialize` pass, so this means the base VHDX predates that template: rebuild the base (`-Role base`) and then the cell. `Initialize-Guest.ps1` refuses in this situation, so `New-TestVm.ps1` should have stopped with `guest-initialization-failed` rather than producing the cell. |
| A row is `skip / harness-precondition-unmet` | The row declares `requiresProbeDeep` and the repair's `data/repairs.json` entry does not carry `probeDeep: true`, so detection would run the shallow probe and report healthy over a confirmed fault. The message names the entry to fix. This is a skip, never a fail: the gap is in the catalog, not in the behaviour under test. |
| Every row is `skip / baseline-not-clean` | The `clean` checkpoint is dirty. Rebuild the cell (`-Role cell -Force`) — do not read anything into the engine from those rows. |
| `hyperv-not-available` | The feature is on but you have not rebooted. |
| `host-architecture-mismatch` | The ARM64 cell on an x64 host. Hyper-V does not emulate a foreign CPU: not slow, impossible. |
| Network rows skip with "no external switch" | Pass `-SwitchName 'Default Switch'` (or your own external switch). Without a network those repairs would fail for reasons unrelated to the code, so they are skipped rather than scored. |
| A row hangs | It cannot: every guest command runs as a bounded job. Raise `-StepTimeoutMinutes` for the sfc/DISM rows. |

---

## Safety notes

* `New-TestVm.ps1` and `Invoke-VmMatrix.ps1` both support `-Plan`, which emits the complete plan as
  JSON and **touches nothing** — no elevation, no Hyper-V, no VM.
* Every mutating path is behind `ShouldProcess` with `ConfirmImpact = 'High'`.
* Nothing here modifies the **host's** Windows configuration. It creates VMs, VHDXs and ISOs under
  `D:\ffvm` and writes results; that is all.
* `guest/faults/component-store-broken.ps1` does **real damage to a Windows image**. It is VM-only,
  it picks its target from a documented candidate list, and it refuses rather than improvising when
  no candidate resolves.
* This harness has been written and syntax-checked but **has never been run** — Hyper-V is not
  enabled on the dev box, and enabling it needs elevation and a reboot. Treat the first run as
  commissioning: start with `-Plan`, then one base, then `-RepairSet smoke` on the control cell.
  The control cell exists precisely so that a failure there is read as "the harness or the engine is
  broken", never as "the platform is different".
