'use strict';
/* FrameForge renderer — Fluent (Windows 11 Settings-style) shell */

/* ---------- graceful-degradation demo shim ----------
   In the packaged Electron app, the preload bridge provides window.ff and this block is skipped.
   When opened as plain web content (no bridge), we supply representative data for THIS rig so the
   UI still renders and can be previewed. Demo numbers are clearly synthetic. */
if (!window.ff) {
  const sys = {
    isAdmin: true,
    os: { caption: 'Microsoft Windows 11 Pro', build: 26200, ramTotalGB: 31.8 },
    cpu: { name: 'Intel(R) Core(TM) i9-14900KF', cores: 24, threads: 32, hybrid: true, isRaptorLake: true, microcode: '0x133', microcodeOk: true },
    gpus: [{ name: 'NVIDIA GeForce RTX 5080', vendor: 'NVIDIA', driverVersion: '32.0.16.1047' }],
    ram: { modules: [{ capacityGB: 16 }, { capacityGB: 16 }], runningMTs: 4800, ratedMTs: 5600, xmpLikelyOff: true },
    disks: [{ name: 'Samsung 980 PRO', busType: 'NVMe' }, { name: 'Samsung 860 QVO', busType: 'SATA' }],
    display: { currentW: 1920, currentH: 1080, currentHz: 241, maxHzAtCurrentRes: 241, refreshOpportunity: false },
    network: { activeAdapter: 'Intel I225-V', isWired: true, linkSpeedMbps: 2500 },
  };
  let applied = new Set();
  const healthy = new Set(['hags-verify', 'microcode-verify', 'rss-verify']);
  let capN = 0;
  const demoCatalog = async () => { try { return (await (await fetch('../data/tweaks.json')).json()).tweaks || []; } catch (e) { return []; } };
  window.ff = {
    sysInfo: async () => sys,
    isAdmin: async () => true,
    listTweaks: async () => { try { return await (await fetch('../data/tweaks.json')).json(); } catch (e) { return { tweaks: [] }; } },
    detectAll: async () => (await demoCatalog()).map((t) => ({ id: t.id, supported: true, requiresAdmin: t.requiresAdmin, applied: healthy.has(t.id) || applied.has(t.id) })),
    apply: async (id) => { applied.add(id); return { success: true }; },
    revert: async (id) => { applied.delete(id); return { success: true }; },
    revertAll: async () => { const n = applied.size; applied.clear(); return { success: true, count: n }; },
    restorePoint: async () => ({ success: true, message: 'Restore point created (demo).' }),
    capture: async () => { capN++; const base = capN === 1; return { ok: true, frames: base ? 5421 : 5980, durationSec: 20, avgFps: base ? 243.1 : 271.4, low1Fps: base ? 181.2 : 214.6, low01Fps: base ? 142.0 : 173.3, minFps: base ? 121 : 158, maxFps: base ? 301 : 312, stutterMs: base ? 1.9 : 1.3 }; },
    windowedProcs: async () => [{ id: 7400, name: 'cs2', title: 'Counter-Strike 2', ramMB: 1840 }, { id: 2210, name: 'chrome', title: 'Google Chrome', ramMB: 720 }],
    bloatProcs: async () => [{ name: 'Discord', ramMB: 915, ids: [1, 2, 3, 4] }, { name: 'nordvpn-service', ramMB: 273, ids: [5] }, { name: 'SteelSeriesSonar', ramMB: 188, ids: [6] }, { name: 'OneDrive', ramMB: 125, ids: [7] }],
    closeProcs: async (ids) => ({ closed: ids || [] }),
    nvidia: (() => {
      let nvSnaps = 1, nvApplied = null;
      const catalog = async () => { try { return await (await fetch('../data/nvidia-settings.json')).json(); } catch (e) { return { settings: {}, presets: {}, placebo: [], inGame: [] }; } };
      return {
        detect: async () => ({ nvidia: true, tuner: true, driver: '32.0.16.1047', snapshots: nvSnaps, latestSnap: '20260629-230932', applied: nvApplied }),
        snapshot: async () => { nvSnaps++; return { ok: true, snapshot: '20260629-230932', files: ['nvdrsdb0.bin', 'nvdrsdb1.bin', 'nvdrssel.bin', 'nvdrswr.lk'] }; },
        list: async () => ({ ok: true, snapshots: ['20260629-230932'] }),
        restore: async () => ({ ok: true, message: 'NVIDIA settings restored. Reboot to reload the driver database.' }),
        open: async () => ({ ok: true }),
        createCsn: async () => ({ ok: true, settingCount: 125 }),
        games: async () => ({ ok: true, games: [{ name: 'Counter-Strike 2', exe: 'cs2.exe' }, { name: 'Dota 2', exe: 'dota2.exe' }, { name: 'PUBG', exe: 'TslGame.exe' }, { name: 'Dead by Daylight', exe: 'DeadByDaylight-Win64-Shipping.exe' }, { name: 'Squad', exe: 'SquadGame.exe' }, { name: 'League of Legends', exe: 'League of Legends.exe' }] }),
        catalog,
        preview: async (pk, vrr) => { const c = await catalog(); const p = c.presets[pk]; let keys = (p && p.applied) || []; const degraded = p && p.needsVRR && !vrr; if (degraded) keys = keys.filter((x) => !['gsync-global', 'gsync-mode', 'vsync-on'].includes(x)).concat(['vsync-off']); return { ok: true, preset: pk, keys, games: ['Counter-Strike 2', 'Dota 2'], degraded }; },
        applyPreset: async (pk, vrr) => { nvApplied = pk; const c = await catalog(); return { ok: true, preset: pk, degraded: c.presets[pk].needsVRR && !vrr, games: ['Counter-Strike 2', 'Dota 2'] }; },
        previewCustom: async (keys, vrr) => { let k = (keys || []).slice(); const drop = !vrr; if (drop) k = k.filter((x) => !['gsync-global', 'gsync-mode', 'vsync-on'].includes(x)); return { ok: true, keys: k, games: ['Counter-Strike 2', 'Dota 2'], degraded: drop && (keys || []).some((x) => ['gsync-global', 'gsync-mode', 'vsync-on'].includes(x)) }; },
        applyCustom: async (keys, vrr) => { nvApplied = 'custom'; const dropped = !vrr && (keys || []).some((x) => ['gsync-global', 'gsync-mode', 'vsync-on'].includes(x)); return { ok: true, preset: 'custom', keys: keys || [], degraded: dropped }; },
        revertApplied: async () => { nvApplied = null; return { ok: true, message: 'Reverted to your pre-apply NVIDIA settings. Reboot to reload.' }; },
        buildCatalog: async (hz) => ({ ok: true, driver: '32.0.16.1047', resolved: 11, unresolved: [], cap: `${(hz || 240) - 4} FPS` }),
      };
    })(),
    openExternal: async (u) => { window.open(u, '_blank'); return true; },
    win: { minimize: async () => {}, maximize: async () => {}, close: async () => {} },
  };

  /* --- demo health / repair / fresh-image data ---
     Shapes match engine/health.ps1, engine/repair.ps1 and engine/image.ps1 exactly so the
     static preview exercises the same render paths as the packaged app. */
  const demoHealth = {
    ok: true, isAdmin: false, scannedAt: '2026-08-29T01:47:38', deep: false, durationMs: 9868,
    totals: { ok: 5, warning: 3, critical: 0, needsAdmin: 4, unknown: 0 },
    categories: [
      { category: 'system-files', status: 'needs-admin', summary: 'The component-store corruption check needs administrator rights; only the pending-reboot key was checked.', findings: [], durationMs: 36 },
      { category: 'disk', status: 'needs-admin', summary: 'No disk error events and all 2 physical drive(s) report healthy; the NTFS dirty-bit check needs administrator rights.', durationMs: 1904, findings: [{ id: 'physical-disk-inventory', severity: 'info', detail: 'Per-drive health captured for 2 physical drive(s).', evidence: { drives: [{ name: 'Samsung SSD 980 PRO 1TB', healthStatus: 'Healthy' }, { name: 'Samsung SSD 860 QVO 1TB', healthStatus: 'Healthy' }] } }] },
      { category: 'windows-update', status: 'ok', summary: 'Update pipeline services look normal and the last update installed on 2026-08-12.', durationMs: 1005, findings: [{ id: 'pending-file-renames', severity: 'info', detail: 'PendingFileRenameOperations is set — common after app installs, usually harmless on its own.' }] },
      { category: 'network', status: 'ok', summary: 'Healthy network layers: link, gateway, raw-IP internet, DNS resolution, HTTP (NCSI).', findings: [], durationMs: 3106 },
      { category: 'store', status: 'warning', summary: 'Microsoft Store shows 1 issue(s) — see findings.', durationMs: 752, findings: [{ id: 'appx-deploy-errors', severity: 'warning', detail: '20 app deployment error(s) in the last 7 days.' }] },
      { category: 'search', status: 'needs-admin', summary: 'The search indexer is running normally with no recent shell crashes; the index-size check needs administrator rights.', findings: [], durationMs: 112 },
      { category: 'printing', status: 'warning', summary: 'Printing shows 1 issue(s) — see findings.', durationMs: 1133, findings: [{ id: 'printer-error-state', severity: 'warning', detail: "Printer 'NPIDE7158 (HP Color LaserJet MFP M281fdw)' is in state 'Offline'." }] },
      { category: 'stability', status: 'needs-admin', summary: 'No blue screens and no unexpected shutdowns in the last 30 days; the full dump inventory needs administrator rights.', durationMs: 70, findings: [{ id: 'dump-inventory', severity: 'info', detail: 'Crash dump inventory captured for analysis.' }] },
      { category: 'disk-space', status: 'warning', summary: '1 volume(s) low on space — see findings.', durationMs: 110, findings: [{ id: 'space-low-C', severity: 'warning', detail: 'Drive C: is low on space (135.2 GB free, 14.5%).' }, { id: 'volume-inventory', severity: 'info', detail: 'Per-volume free space captured.' }] },
      { category: 'boot', status: 'ok', summary: 'No boot-time degradation signals were found (no recent boot-performance events recorded).', durationMs: 63, findings: [{ id: 'fast-startup-state', severity: 'info', detail: 'Fast Startup is available and enabled.' }] },
      { category: 'audio', status: 'ok', summary: 'Audio services are running and no audio device reports an error.', durationMs: 1002, findings: [{ id: 'sound-device-inventory', severity: 'info', detail: 'CIM sound-device state captured for 5 device(s).' }] },
      { category: 'activation', status: 'ok', summary: 'Windows is activated (licensed).', findings: [], durationMs: 532 },
    ],
  };
  const DEMO_STATE = {
    healthy: ['wu-reset', 'wu-reset-aggressive', 'network-flush', 'winsock-reset', 'audio-restart', 'winget-repair'],
    problem: ['store-cache-reset', 'store-reregister', 'store-reregister-all', 'spooler-clear-queue', 'ntp-resync', 'temp-clean', 'component-cleanup', 'component-cleanup-resetbase'],
  };
  const demoDetail = {
    healthy: 'This subsystem currently reports healthy, so the repair would refuse to run.',
    problem: 'Detection found a problem this repair is meant to address.',
    indeterminate: 'The probe could not fully check this category (status: needs-admin).',
  };
  const demoLedger = [];
  window.ff.health = {
    scan: async () => demoHealth,
    probe: async (c) => (demoHealth.categories.find((x) => x.category === c) || { ok: false, error: 'unknown category' }),
    catalog: async () => { try { return await (await fetch('../data/health-checks.json')).json(); } catch (e) { return { checks: [] }; } },
  };
  const demoRepairCatalog = async () => { try { return await (await fetch('../data/repairs.json')).json(); } catch (e) { return { repairs: [] }; } };
  window.ff.repair = {
    catalog: demoRepairCatalog,
    list: async () => {
      const cat = await demoRepairCatalog();
      const repairs = (cat.repairs || []).map((r) => {
        const state = DEMO_STATE.healthy.includes(r.id) ? 'healthy' : DEMO_STATE.problem.includes(r.id) ? 'problem' : 'indeterminate';
        return { id: r.id, name: r.name, category: r.category, tier: r.tier, reversible: r.reversible, requiresAdmin: r.requiresAdmin, requiresReboot: r.requiresReboot, summary: r.summary, detection: { state, detail: demoDetail[state] } };
      });
      return { ok: true, isAdmin: true, count: repairs.length, repairs };
    },
    preflight: async (id) => {
      const cat = await demoRepairCatalog();
      const r = (cat.repairs || []).find((x) => x.id === id) || {};
      const state = DEMO_STATE.healthy.includes(id) ? 'healthy' : DEMO_STATE.problem.includes(id) ? 'problem' : 'indeterminate';
      return {
        ok: true, id, action: 'preflight', name: r.name, tier: r.tier, isAdmin: true,
        requiresAdmin: !!r.requiresAdmin, wouldNeedElevation: false, requiresReboot: !!r.requiresReboot, reversible: !!r.reversible,
        detection: { method: 'health-probe', category: r.healthCheck || r.category, state, detail: demoDetail[state], relevantFindings: [] },
        wouldRefuse: state === 'healthy',
        whatWouldRun: [{ name: r.id, commands: r.whatItRuns || [] }],
        risks: r.risks, verifyAfter: r.verifyAfter,
        note: 'Preflight is read-only: nothing was changed and no ledger entry was written.',
      };
    },
    run: async (id, opts) => {
      const o = opts || {};
      const pre = await window.ff.repair.preflight(id);
      if (o.dryRun) return { ok: true, id, action: 'run', dryRun: true, mutated: false, wouldRefuse: pre.wouldRefuse, detection: pre.detection, steps: pre.whatWouldRun, reversible: pre.reversible, requiresAdmin: pre.requiresAdmin, requiresReboot: pre.requiresReboot, note: 'Dry run: none of the listed commands were executed and no ledger entry was written.', refusalNote: pre.wouldRefuse ? "Without -DryRun this run would REFUSE: detection reports healthy, and 'nothing is broken here' is a first-class result." : undefined };
      if (pre.wouldRefuse && !o.force) return { ok: true, id, action: 'run', ran: false, refused: true, reason: 'nothing-broken', message: `Detection reports this subsystem is healthy, so “${pre.name}” was NOT run. Nothing is broken here.`, detection: pre.detection };
      const runId = Math.random().toString(16).slice(2, 14);
      const steps = (pre.whatWouldRun[0].commands || []).map((c) => ({ name: pre.name, commands: [c], status: 'done' }));
      demoLedger.push({ runId, id, name: pre.name, ranAt: new Date().toISOString().slice(0, 19), tier: pre.tier, reversible: pre.reversible, forced: !!o.force, steps, mutations: steps.map((s) => s.commands[0]), result: { fixed: true, verified: true, detail: 'All steps completed, and the same probe that detected the problem now reports healthy.' }, undone: false, undoneAt: null });
      return { ok: true, id, action: 'run', dryRun: false, ranAt: new Date().toISOString().slice(0, 19), detection: { pre: pre.detection, post: { state: 'healthy' } }, steps, result: { fixed: true, verified: true, detail: 'All steps completed, and the same probe that detected the problem now reports healthy.' }, reversible: pre.reversible, requiresReboot: pre.requiresReboot, ledgerRunId: runId };
    },
    undo: async (id) => { const e = demoLedger.filter((x) => x.id === id && !x.undone).pop(); if (!e) return { ok: true, id, action: 'undo', noop: true, message: 'No completed run of this repair is on record in the ledger.' }; e.undone = true; e.undoneAt = new Date().toISOString().slice(0, 19); return { ok: true, id, action: 'undo', success: true, restored: e.mutations, ledgerRunId: e.runId }; },
    ledger: async () => ({ ok: true, count: demoLedger.length, ledgerPath: 'data/state/repairs-ledger.json', entries: demoLedger.slice() }),
  };
  const demoImageDetect = {
    ok: true, action: 'detect', isAdmin: false, at: '2026-08-29T01:48:29',
    os: { editionId: 'Professional', productName: 'Windows 11 Pro', displayVersion: '25H2', currentBuild: 26200, ubr: 9168, buildString: '26200.9168', architecture: 'x64', language: { tag: 'en-US', source: 'registry-installlanguage' } },
    mediaMustMatch: { edition: 'Professional', language: 'en-US', build: 'same-or-newer than 26200', arch: 'x64', rule: 'Since Windows 11 22H2 the repair media must exactly match the system default UI language, match the edition, be the same-or-newer build, and match the architecture.' },
    rails: {
      systemDrive: 'C:', freeSystemDriveGB: 135.2, minRequiredGB: 30, diskOk: true,
      power: { lineStatus: 'Online', onAc: true, batteryPresent: false, note: 'Desktop (no system battery) - AC rail passes trivially.' },
      bitlocker: { status: 'needs-admin', note: 'BitLocker state requires administrator rights to read.' },
      bitlockerKnown: false, bitlockerBlocking: false,
      pendingReboot: { cbsRebootPending: false, wuRebootRequired: false, pendingFileRenames: true, any: false },
    },
    componentStore: { status: 'needs-admin', imageHealthState: null },
  };
  window.ff.image = {
    catalog: async () => { try { return await (await fetch('../data/image-repair.json')).json(); } catch (e) { return {}; } },
    detect: async () => demoImageDetect,
    verify: async () => ({ ok: true, action: 'verify', verdict: 'no-ledger', verdictText: 'No launch is recorded in the ledger — either nothing was launched through FrameForge, or the ledger was cleared.', os: demoImageDetect.os, windowsOldPresent: false }),
    acquireUrl: async () => ({ ok: false, action: 'acquire-url', fallback: 'mct', reason: 'Microsoft rejected the scripted request (715-123130). Use the Media Creation Tool instead.' }),
    validate: async (o) => (!o || !o.isoPath) ? { ok: false, action: 'validate', errorCode: 'no-media-param', error: 'No media given: point FrameForge at an ISO file.' } : { ok: true, action: 'validate', isAdmin: false, media: { isoPath: o.isoPath, kind: 'esd' }, verdict: { compatible: true, reasons: [], selectedIndex: 6, imageInfo: { edition: 'Professional', language: 'en-US', build: 26200, ubr: 9168, architecture: 'x64' } } },
    preflight: async (o) => (!o || !o.isoPath) ? { ok: false, action: 'preflight', errorCode: 'no-media-param', error: 'No media given: point FrameForge at an ISO file.' } : { ok: true, action: 'preflight', dryRun: !!o.dryRun, isAdmin: false, media: { root: 'E:\\', kind: 'esd', setupExePresent: true }, verdict: { compatible: true, reasons: [] }, rails: demoImageDetect.rails, railCheck: { green: false, reasons: ['BitLocker state is unknown (needs-admin) - it must be verified before launch.'] }, compatScan: { ran: false, note: 'Skipped (dry run). The scan is non-destructive but writes setup logs.' }, readyToLaunch: false },
    launch: async (o) => {
      if (!o || !o.isoPath) return { ok: false, action: 'launch', errorCode: 'no-media-param', error: 'No media given: point FrameForge at an ISO file.' };
      return {
        ok: true, action: 'launch', mode: 'consent-contract', executed: false,
        command: '"E:\\setup.exe" /auto upgrade /eula accept /compat ignorewarning /migratedrivers all /dynamicupdate NoDrivers /showoobe none /copylogs "data\\state\\setup-logs" /noreboot',
        optionalBitLockerStep: 'Suspend-BitLocker -MountPoint C: -RebootCount 3',
        contract: {
          eulaNote: 'Launching passes /eula accept to Windows Setup: you are accepting the Microsoft Software License Terms for this Windows version. FrameForge will not pass it until you consent here.',
          whatIsPreserved: ['User accounts and profiles', 'Personal files', 'Installed Win32 and Store apps', 'Most settings and drivers (/migratedrivers all)', 'Windows activation'],
          whatIsReset: ['All system binaries and the component store (the point of the repair)', 'Some defaults (default apps can reset)', 'Custom services / patched system files', 'Third-party shell extensions may need repair or reinstall'],
          durationEstimate: '30-90 minutes on modern NVMe hardware; the down-level phase is 10-30 minutes.',
          rebootCount: '2-3 restarts. /noreboot suppresses only the FIRST one — you choose when to restart; later restarts happen automatically.',
          rollbackNote: 'A failed upgrade rolls back automatically. The previous OS is kept in C:\\Windows.old with "Go back" available for ~10 days, then auto-cleaned.',
          bitlockerNote: 'Setup normally keeps or auto-suspends BitLocker, but a recovery-key prompt after reboot is possible. Confirm you can access your recovery key first: https://aka.ms/myrecoverykey',
        },
        verdict: { compatible: true, reasons: [] },
        rails: demoImageDetect.rails,
        railCheck: { green: false, reasons: ['BitLocker state is unknown (needs-admin) - it must be verified before launch.'] },
        blockers: ['BitLocker state is unknown (needs-admin) - it must be verified before launch.', 'Administrator rights are required to launch.'],
      };
    },
  };
}

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const IMPACT_W = { high: 3, medium: 2, low: 1, situational: 1, none: 1 };
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Settings microcopy is sentence case. Catalog data (data/*.json) is rendered through this:
// Title-Case words after the first are lowercased ("Esports / Lowest Latency" →
// "Esports / lowest latency") while acronyms (NVIDIA, VRR, GSYNC) are left alone.
const sentenceCase = (s) => String(s == null ? '' : s).replace(/(?!^)\b([A-Z])(?=[a-z])/g, (c) => c.toLowerCase());

// Expanded/collapsed state for cards that re-render whenever an engine result lands.
const openRows = { repair: new Set(), health: new Set(), img: new Set(), nvadv: new Set() };
const state = {
  sys: null, tweaks: [], detect: {}, detectFailed: false, detectError: null,
  admin: false, busy: false, env: null,
  bench: { baseline: null, after: null, context: null },
  nvidia: { catalog: null, detect: null, games: [], vrr: false, active: null, sel: new Set() },
};

/* ---------- engine result shape ----------
   runPs resolves { ok:false, error, timedOut, … } for a failed engine call. An error
   object is TRUTHY, so `if (!res) return` never caught it and the first property
   dereference threw, blanking the whole app. Every consumer goes through these. */
const isEngineError = (r) => !r || typeof r !== 'object' || r.ok === false;
function engineErrorText(r) {
  if (!r) return 'The engine returned nothing at all.';
  if (typeof r !== 'object') return 'The engine returned a value FrameForge could not read.';
  if (r.timedOut) return r.error || `The engine did not finish within ${Math.round((r.timeoutMs || 0) / 1000)}s and was stopped. Nothing was measured.`;
  return r.error || r.message || 'The engine returned no result and no reason.';
}
// Reduced motion is a Windows accessibility setting (Visual effects > Animation effects),
// not a preference we get to ignore.
const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- glyph helpers (Segoe Fluent Icons) ---------- */
const GLYPH = {
  check: '', dismiss: '', warning: '', info: '', error: '',
  chip: '', monitor: '', game: '', speed: '', bolt: '',
  settings: '', shield: '', repair: '', pc: '', history: '',
  power: '', net: '', storage: '', memory: '', admin: '', close: '',
};
// Health / repair iconography (Segoe Fluent Icons PUA codepoints).
Object.assign(GLYPH, {
  health: '', printer: '', search: '', store: '', update: '',
  clock: '', bug: '', boot: '', key: '', disc: '',
  chevronRight: '', chevronDown: '', back: '', list: '', play: '', undo: '',
  blocked: '', pending: '', bullet: '',
  // 'unknown' is the doctrine's "could not determine". It is NOT information: it is a
  // HOLE where a measurement should be, so it gets its own mark rather than the info dot.
  unknown: '',
});
function statusChip(kind, text) {
  const g = kind === 'good' ? GLYPH.check
    : kind === 'crit' ? GLYPH.dismiss
      : kind === 'admin' ? GLYPH.admin
        : kind === 'unknown' ? GLYPH.unknown
          : kind === 'idle' ? GLYPH.info
            : GLYPH.warning;
  // The glyph is a Private Use Area codepoint: decorative, and announced as junk unless
  // it is hidden. The chip's own text carries the meaning.
  return `<span class="status ${kind}"><span class="glyph" aria-hidden="true">${g}</span>${esc(text)}</span>`;
}

/* ---------- toasts & drawer ---------- */
// Toasts are the app's ONLY channel for operational results ("Applied", "Repair failed",
// "Administrator required"). They are routed to one of two live regions so a screen
// reader is told what happened: errors and warnings assertively, everything else
// politely. Errors also linger, because 4.2s is not enough time to reach and read one.
function toast(type, title, body, ms) {
  const assertive = type === 'err' || type === 'warn';
  if (ms == null) ms = assertive ? 12000 : 4200;
  const t = document.createElement('div');
  t.className = `toast ${type}`;
  const g = type === 'ok' ? GLYPH.check : type === 'err' ? GLYPH.error : type === 'warn' ? GLYPH.warning : GLYPH.info;
  t.innerHTML = `<span class="glyph" aria-hidden="true">${g}</span><div><div class="tt">${esc(title)}</div>${body ? `<div class="tb">${esc(body)}</div>` : ''}</div>`;
  const host = (assertive ? $('#toastsAssertive') : $('#toasts')) || $('#toasts');
  if (host) host.appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; t.style.transform = 'translateX(24px)'; t.style.transition = '0.3s'; setTimeout(() => t.remove(), 320); }, ms);
}

/* The drawer is a modal pane: it needs dialog semantics, a focus move in, a focus trap,
   Escape to close, and focus restored to whatever opened it. */
let drawerReturnFocus = null;
const FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
function openDrawer(html) {
  const d = $('#drawer');
  drawerReturnFocus = document.activeElement;
  d.innerHTML = html;
  d.setAttribute('role', 'dialog');
  d.setAttribute('aria-modal', 'true');
  const h = d.querySelector('h2');
  if (h) { h.id = h.id || 'drawerTitle'; d.setAttribute('aria-labelledby', h.id); }
  else d.removeAttribute('aria-labelledby');
  d.hidden = false; $('#drawerBackdrop').hidden = false;
  const first = d.querySelector('[data-act="close-drawer"]') || d.querySelector(FOCUSABLE) || d;
  if (first === d) d.setAttribute('tabindex', '-1');
  try { first.focus(); } catch (e) { /* nothing focusable */ }
}
function closeDrawer() {
  const d = $('#drawer');
  if (d.hidden) return;
  d.hidden = true; $('#drawerBackdrop').hidden = true;
  const back = drawerReturnFocus; drawerReturnFocus = null;
  if (back && document.contains(back)) { try { back.focus(); } catch (e) {} }
}
const drawerOpen = () => { const d = $('#drawer'); return d && !d.hidden; };

/* ---------- SettingsExpander disclosure ----------
   The header card used to be role="button" with real buttons and checkboxes nested
   inside it — invalid ARIA, which flattens those children into the outer button's
   accessible name — and it never exposed aria-expanded, so a screen reader announced a
   plain button with no hint that it discloses anything. The only open/closed cue was the
   .chev glyph rotation, which is decorative and unlabelled.

   Rather than thread the same attributes through seven separate template literals, every
   render calls wireExpanders(): the card becomes a plain container and the chevron
   becomes the real disclosure control, carrying aria-expanded, aria-controls and a
   label. Called after each render because innerHTML replacement drops the attributes. */
let sexpSeq = 0;
function wireExpanders(root) {
  for (const x of $$('.sexpander', root || document)) {
    const head = x.querySelector(':scope > .sexp-head');
    const content = x.querySelector(':scope > .sexp-content');
    const chev = head && head.querySelector(':scope > .chev');
    if (!head || !content) continue;
    // The card is a container, not a button: it must not swallow its own children.
    head.removeAttribute('role');
    head.removeAttribute('tabindex');
    if (!content.id) content.id = `sexpc${++sexpSeq}`;
    if (!chev) continue;
    chev.setAttribute('role', 'button');
    chev.setAttribute('tabindex', '0');
    chev.setAttribute('data-act', 'expander');
    chev.setAttribute('aria-controls', content.id);
    chev.setAttribute('aria-expanded', x.classList.contains('open') ? 'true' : 'false');
    if (!chev.getAttribute('aria-label')) {
      const title = head.querySelector('.scard-title');
      chev.setAttribute('aria-label', title ? `Show details for ${title.textContent.trim()}` : 'Show details');
    }
  }
}

/* ---------- helpers ---------- */
/* Three states, not two. `null` means "detection did not produce a state for this
   tweak" — turning that into `false` is what let a failed detect-all render every tweak
   in the catalog as a detected opportunity on a perfectly tuned machine. */
const isApplied = (id) => {
  const d = state.detect[id];
  if (!d) return null;
  // engine.ps1's detect is a TRI-STATE. `applied` stays a boolean so old renderers keep
  // working, and `determined` carries the third state: determined === false means the probe
  // could not read this setting at all, so the boolean next to it is not an answer. Reading
  // only `applied` turned every unreadable tweak into "not applied" — which is how a
  // per-user tweak FrameForge could not see (wrong profile) was offered as an opportunity.
  if (d.determined === false) return null;
  if (d.applied === null || d.applied === undefined) return null;
  return !!d.applied;
};
// engine.ps1 reports `supported` per tweak (non-Intel CPU, no NVIDIA, missing scheme…).
// Ignoring it rendered an amber "Check" warning for a probe that could never run here.
const isSupported = (id) => {
  const d = state.detect[id];
  if (!d) return null;
  return d.supported !== false;
};
const tweaksByKind = (k) => state.tweaks.filter((t) => t.kind === k);
function metaLine(t) {
  const bits = [`${esc(t.tier)} tier`, `risk: ${esc(t.risk)}`, `impact: ${esc(t.impact)}`];
  if (t.requiresAdmin) bits.push('needs administrator');
  if (t.requiresReboot) bits.push('needs reboot');
  return bits.join(' · ');
}
function catGlyph(t) {
  const c = (t.category || '').toLowerCase();
  if (c.includes('power')) return GLYPH.power;
  if (c.includes('gpu') || c.includes('graphic') || c.includes('display')) return GLYPH.monitor;
  if (c.includes('net')) return GLYPH.net;
  if (c.includes('cpu') || c.includes('bios') || c.includes('memory') || c.includes('ram')) return GLYPH.chip;
  if (c.includes('storage') || c.includes('disk')) return GLYPH.storage;
  if (c.includes('game') || c.includes('input') || c.includes('latency')) return GLYPH.game;
  if (c.includes('service') || c.includes('background')) return GLYPH.settings;
  return GLYPH.settings;
}

/* ---------- memory: rated speed / XMP ----------
   sysinfo.ps1 can fail to parse a rated speed out of a DIMM part number (it understands
   Kingston Fury and a bare 4-digit token; Corsair/G.Skill/Crucial frequently miss), and
   soldered LPDDRx has no XMP/EXPO concept at all. "Could not determine" therefore has to
   be its own state — rendering it as a green "XMP on" chip is exactly the fabricated
   confident result the product sells against. */
const LPDDR_TYPES = [30, 31, 35]; // SMBIOSMemoryType: LPDDR4, LPDDR4X, LPDDR5
const SMBIOS_TYPE_LABEL = { 26: 'DDR4', 30: 'LPDDR4', 31: 'LPDDR4X', 34: 'DDR5', 35: 'LPDDR5' };
function ramRatedKnown(ram) {
  if (!ram) return false;
  if (ram.ratedKnown !== undefined) return !!ram.ratedKnown;   // engine says so explicitly
  return Number(ram.ratedMTs) > 0;                              // older engine: infer
}
// The engine may report memoryType as the raw SMBIOSMemoryType number or as a decoded
// label ("DDR5", "LPDDR5"); accept either rather than assuming one shape.
function ramTypeLabel(ram) {
  if (!ram) return '';
  if (ram.memoryTypeLabel) return String(ram.memoryTypeLabel);
  const t = ram.memoryType;
  if (t == null || t === '') return '';
  if (typeof t === 'number' || /^\d+$/.test(String(t))) return SMBIOS_TYPE_LABEL[Number(t)] || '';
  return String(t);
}
function ramSoldered(ram) {
  if (!ram) return false;
  if (LPDDR_TYPES.includes(Number(ram.memoryType))) return true;
  if (/^LPDDR/i.test(ramTypeLabel(ram))) return true;
  // SMBIOS FormFactor 12 = SODIMM, 8 = DIMM. Soldered memory is reported as neither on
  // most laptops, so form factor alone is never treated as proof.
  return false;
}
// true = XMP looks off, false = looks on, null = could not determine.
function xmpState(ram) {
  if (!ram) return null;
  if (ramSoldered(ram)) return null;              // no XMP profile exists to be on or off
  if (ram.xmpLikelyOff === null || ram.xmpLikelyOff === undefined) return null;
  if (!ramRatedKnown(ram)) return null;           // "not off" was only ever a failed parse
  return !!ram.xmpLikelyOff;
}

/* advisory satisfaction we can actually detect on this machine */
function advisorySatisfied(t) {
  const s = state.sys; if (isEngineError(s)) return null;
  if (t.id === 'enable-xmp') { const x = xmpState(s.ram); return x === null ? null : !x; }
  if (t.id === 'wired-ethernet') return s.network ? s.network.isWired : null;
  if (t.id === 'move-libraries-off-qvo') { if (!s.storage || !s.storage.steamFound) return null; return s.storage.slowGameCount === 0; }
  return null; // not detectable -> recommendation only
}

/* ---------- score ----------
   Returns null when nothing could be counted, so the caller renders an em-dash rather
   than a confident "0". Anything undetectable drops out instead of scoring zero. */
function computeScore() {
  let good = 0, total = 0;
  for (const t of [...tweaksByKind('action'), ...tweaksByKind('verify')]) {
    if (isSupported(t.id) === false) continue;      // not applicable on this PC
    const ap = isApplied(t.id); if (ap === null) continue;   // not measured
    const w = IMPACT_W[t.impact] || 1; total += w; if (ap) good += w;
  }
  for (const t of tweaksByKind('advise')) {
    const sat = advisorySatisfied(t); if (sat === null) continue;
    const w = IMPACT_W[t.impact] || 1; total += w; if (sat) good += w;
  }
  return total ? Math.round((good / total) * 100) : null;
}

/* ---------- DASHBOARD ---------- */
// The text a "Copy diagnostic" button puts on the clipboard. Set whenever we render a
// failure state, so the user can hand the real reason to someone who can act on it.
let lastDiagnostic = '';
// The text rides on the BUTTON, not in a single module-level slot: two failure infobars can
// be on screen at once (a policy block and a wrong-account warning are independent), and a
// shared slot meant the first button silently copied the second one's text.
function diagButton(text) {
  const t = String(text || '');
  lastDiagnostic = t;   // kept as the fallback for any button rendered without a payload
  return `<button class="fbtn" data-act="copy-diag" data-diag="${esc(t)}">Copy diagnostic</button>`;
}
function infobarHtml(kind, glyph, title, msg, actions) {
  return `<div class="infobar ${kind}"><span class="glyph" aria-hidden="true">${glyph}</span>
    <div class="ib-body"><span class="ib-title">${esc(title)}</span><span class="ib-msg">${esc(msg)}</span></div>
    ${actions ? `<div class="ib-actions">${actions}</div>` : ''}</div>`;
}

/* Hardware could not be read. This is a first-class outcome, not a crash: the app used
   to throw on s.gpus[0] / s.cpu.name.replace and blank every page behind a 4-second
   toast that never named the reason. */
function renderEngineFailure(res) {
  const why = engineErrorText(res);
  const policy = state.env && state.env.psPolicy;
  // engineUsable === false is the measured verdict "PowerShell produces nothing usable
  // here"; it explains the failure better than the predicted policy state, so it wins.
  const extra = policy && (policy.engineUsable === false || policy.blocked) ? ` ${policy.message}` : '';
  const tail = /statement about your PC/i.test(why) ? '' : ' Nothing on this page is a statement about your PC — nothing was measured.';
  $('#navRigName').textContent = 'This PC';
  $('#navRigSub').textContent = 'Hardware could not be read';
  $('#dashTop').innerHTML = infobarHtml('critical', GLYPH.error,
    'Your hardware could not be read',
    `${why}${extra}${tail}`,
    `<button class="fbtn" data-act="retry-sys">Retry</button>${diagButton(`${why}${extra}`)}`);
  $('#specGrid').innerHTML = `<div class="empty">No specifications were read, so none are shown. FrameForge does not guess at hardware it could not detect.</div>`;
  $('#oppList').innerHTML = `<div class="empty">Optimization state is unknown while hardware detection is failing.</div>`;
}

function renderDashboard() {
  const s = state.sys;
  // Guard the SHAPE, not just null: a failed engine call resolves to a truthy error object.
  if (isEngineError(s) || !s.cpu || !Array.isArray(s.gpus) || !s.ram || !s.display) {
    renderEngineFailure(s);
    return;
  }
  const gpu = s.gpus[0] || {};
  const cpu = s.cpu || {};
  const ram = s.ram || {};
  const disp = s.display || {};
  const os = s.os || {};
  const disks = Array.isArray(s.disks) ? s.disks : [];
  const modules = Array.isArray(ram.modules) ? ram.modules : [];
  const cpuName = cpu.name || 'Processor could not be read';
  const clean = (n) => String(n).replace(/\(R\)|\(TM\)/g, '');
  // nav pane "profile" = this rig
  $('#navRigName').textContent = (gpu.name || 'This PC').replace('NVIDIA GeForce ', 'GeForce ');
  $('#navRigSub').textContent = cpuName.replace(/\(R\)|\(TM\)|Intel |CPU /g, '').trim();
  $('#greeting').textContent = 'Home';

  const score = computeScore();
  const actions = [...tweaksByKind('action'), ...tweaksByKind('verify')].filter((t) => isSupported(t.id) !== false);
  const inPlace = actions.filter((t) => isApplied(t.id) === true).length;
  const counted = actions.filter((t) => isApplied(t.id) !== null).length;
  const scoreText = score === null ? '&ndash;' : String(score);
  const scoreDesc = state.detectFailed
    ? 'Optimization state could not be read on this PC, so nothing is scored.'
    : `${inPlace} of ${counted} optimizations in place, counted only from checks we can verify on this PC${counted < actions.length ? ` (${actions.length - counted} could not be checked and are not counted)` : ''}`;
  const specLine = [
    os.caption ? esc(os.caption) : 'Windows edition unknown',
    os.build ? `build ${esc(os.build)}` : null,
    (cpu.cores != null && cpu.threads != null) ? `${cpu.cores} cores / ${cpu.threads} threads` : null,
    ram.runningMTs ? `${esc(ram.runningMTs)} MT/s` : null,
    disks.length ? `${disks.length} drives` : null,
  ].filter(Boolean).join(' · ');

  $('#dashTop').innerHTML = `
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.pc}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(gpu.name || 'This PC')}</div>
        <div class="scard-desc">${specLine}</div>
      </div>
    </div>
    ${state.detectFailed ? '' : `<div class="scard block">
      <div style="display:flex;align-items:center;gap:16px">
        <span class="scard-icon" aria-hidden="true">${GLYPH.speed}</span>
        <div class="scard-body">
          <div class="scard-title">Optimization score</div>
          <div class="scard-desc">${scoreDesc}</div>
        </div>
        <span style="font-family:var(--font-display);font-size:20px;line-height:28px;font-weight:600">${scoreText}</span>
      </div>
      <div class="fprogress" style="margin-top:12px"><i id="scoreBar" style="width:0%"></i></div>
    </div>`}`;
  if (score !== null && !state.detectFailed) {
    setTimeout(() => { const b = $('#scoreBar'); if (b) b.style.width = score + '%'; }, 60);
  }

  // spec cards. Every chip below is a measured claim or an explicit "unknown".
  const xmp = xmpState(ram);
  const ramChip = ramSoldered(ram)
    ? statusChip('idle', 'Soldered memory — no XMP profile')
    : !ramRatedKnown(ram)
      ? statusChip('idle', 'Rated speed unknown')
      : xmp === true ? statusChip('warn', `XMP off — rated ${esc(ram.ratedMTs)}`)
        : xmp === false ? statusChip('good', 'XMP on')
          : statusChip('idle', 'XMP state unknown');
  const mcChip = cpu.microcodeOk === true ? statusChip('good', `Microcode ${esc(cpu.microcode)}`)
    : cpu.microcodeOk === false ? statusChip('warn', 'Update BIOS microcode') : '';
  const dispChip = disp.refreshOpportunity === true ? statusChip('warn', `${esc(disp.maxHzAtCurrentRes)} Hz available`)
    : disp.refreshOpportunity === false ? statusChip('good', 'Optimal')
      : statusChip('idle', 'Refresh rate unknown');
  const totalGB = modules.reduce((a, m) => a + (Number(m && m.capacityGB) || 0), 0);
  const memKind = ramTypeLabel(ram);
  const cards = [
    { g: GLYPH.chip, k: 'Processor', d: `${esc(clean(cpuName))}${(cpu.cores != null) ? ` · ${cpu.cores} cores / ${cpu.threads} threads` : ''}${cpu.hybrid ? ' · hybrid P+E' : ''}`, chip: mcChip },
    { g: GLYPH.monitor, k: 'Graphics', d: `${esc(gpu.name || 'Could not be read')} · driver ${esc(gpu.driverVersion || 'unknown')}`, chip: '' },
    { g: GLYPH.memory, k: 'Memory', d: `${totalGB ? `${totalGB} GB` : 'Capacity unknown'}${memKind ? ` ${esc(memKind)}` : ''}${ram.runningMTs ? ` · ${ram.runningMTs} MT/s` : ''}${ramRatedKnown(ram) ? ` of ${esc(ram.ratedMTs)} rated` : ' · rated speed could not be read'}`, chip: ramChip },
    { g: GLYPH.monitor, k: 'Display', d: `${disp.currentW && disp.currentH ? `${disp.currentW}×${disp.currentH}` : 'Resolution unknown'}${disp.currentHz ? ` · ${disp.currentHz} Hz` : ''}${disp.refreshOpportunity === false ? ' · max' : ''}`, chip: dispChip },
  ];
  $('#specGrid').innerHTML = cards.map((c) => `
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${c.g}</span>
      <div class="scard-body"><div class="scard-title">${esc(c.k)}</div><div class="scard-desc">${c.d}</div></div>
      <div class="scard-control">${c.chip || ''}</div>
    </div>`).join('');

  // Detection failed wholesale → say so. Listing every tweak in the catalog as a
  // "detected opportunity" would be inventing ~20 problems on a machine we never read.
  if (state.detectFailed) {
    $('#oppList').innerHTML = infobarHtml('critical', GLYPH.error,
      'Optimization state could not be read',
      `${state.detectError || 'The detection engine returned no result.'} Nothing is listed here because nothing was checked — this is not a statement that your PC is untuned.`,
      `<button class="fbtn" data-act="retry-detect">Retry</button>${diagButton(state.detectError || '')}`);
    return;
  }

  // opportunities = unapplied actions + outstanding detectable advisories + unhealthy verifies
  const opps = [];
  for (const t of [...tweaksByKind('action'), ...tweaksByKind('verify')]) {
    if (isSupported(t.id) !== true) continue;   // false = N/A here, null = never measured
    if (isApplied(t.id) === false) opps.push(t);
  }
  for (const t of tweaksByKind('advise')) { const sat = advisorySatisfied(t); if (sat === false) opps.push(t); }
  opps.sort((a, b) => (IMPACT_W[b.impact] || 1) - (IMPACT_W[a.impact] || 1));

  const unchecked = [...tweaksByKind('action'), ...tweaksByKind('verify')].filter((t) => isSupported(t.id) !== false && isApplied(t.id) === null).length;
  const uncheckedNote = unchecked
    ? infobarHtml('caution', GLYPH.warning, 'Some checks could not run',
      `${unchecked} tweak${unchecked === 1 ? '' : 's'} could not be checked on this PC. ${unchecked === 1 ? 'It is' : 'They are'} not listed as an opportunity and not reported as healthy.`, '')
    : '';
  if (!opps.length) {
    $('#oppList').innerHTML = uncheckedNote + `<div class="empty">No outstanding opportunities. Every check that could run reports this PC is already tuned.</div>`;
  } else {
    $('#oppList').innerHTML = uncheckedNote + opps.map((t) => {
      const actLabel = t.kind === 'advise' ? 'How' : (t.requiresAdmin && !state.admin ? 'Needs admin' : 'Apply');
      const accent = t.kind !== 'advise' && !(t.requiresAdmin && !state.admin);
      return `<div class="scard" data-id="${t.id}">
        <span class="scard-icon" aria-hidden="true">${catGlyph(t)}</span>
        <div class="scard-body">
          <div class="scard-title">${esc(t.name)}</div>
          <div class="scard-desc">${esc(t.summary)}</div>
        </div>
        <div class="scard-control">
          <span class="list-caption">${esc(t.impact)} impact</span>
          <button class="fbtn ${accent ? 'accent' : ''}" data-act="opp" data-id="${t.id}">${actLabel}</button>
        </div>
      </div>`;
    }).join('');
  }
}

/* ---------- BOOST / PROFILES ---------- */
const PROFILES = [
  { id: 'safe', name: 'Safe boost', feature: true, glyph: GLYPH.bolt, desc: 'Conservative, reversible changes only. Every one is measurable.', tiers: ['safe'], kinds: ['action'] },
  { id: 'comp', name: 'Competitive', glyph: GLYPH.game, desc: 'Lowest-latency setup for esports. Adds balanced network and power tuning.', tiers: ['safe', 'balanced'], kinds: ['action'] },
  { id: 'max', name: 'Maximum', glyph: GLYPH.speed, desc: 'Every safe and balanced action, plus the BIOS guidance.', tiers: ['safe', 'balanced', 'aggressive'], kinds: ['action'] },
];
function profileTweaks(p) { return state.tweaks.filter((t) => p.kinds.includes(t.kind) && p.tiers.includes(t.tier)); }

function renderBoost() {
  $('#profileGrid').innerHTML = PROFILES.map((p) => {
    const items = profileTweaks(p);
    const appliedN = items.filter((t) => isApplied(t.id) === true).length;
    const knownN = items.filter((t) => isApplied(t.id) !== null).length;
    const rows = items.map((t) => {
      const ap = isApplied(t.id);
      // "Off" is a measured claim. An unread tweak says so instead of borrowing it.
      const chip = isSupported(t.id) === false ? statusChip('idle', 'Not applicable on this PC')
        : ap === true ? statusChip('good', 'On')
          : ap === false ? '<span class="list-caption">Off</span>'
            : statusChip('idle', 'Could not check');
      return `
      <div class="sexp-row">
        <div class="scard-body"><div class="scard-title">${esc(t.name)}</div><div class="scard-desc">${esc(t.summary)}</div></div>
        ${chip}
      </div>`;
    }).join('') || '<div class="sexp-row"><div class="scard-desc">No items</div></div>';
    return `<div class="sexpander" id="profile-${p.id}">
      <div class="scard sexp-head" data-act="expander">
        <span class="scard-icon" aria-hidden="true">${p.glyph}</span>
        <div class="scard-body">
          <div class="scard-title">${esc(p.name)}${p.feature ? ' <span class="tag-recommended">· Recommended</span>' : ''}</div>
          <div class="scard-desc">${esc(p.desc)}</div>
        </div>
        <div class="scard-control">
          <span class="scard-value">${appliedN} of ${knownN} on${knownN < items.length ? ` · ${items.length - knownN} unchecked` : ''}</span>
          <button class="fbtn ${p.feature ? 'accent' : ''}" data-act="apply-profile" data-id="${p.id}">${appliedN === items.length && items.length ? 'Reapply' : 'Apply'}</button>
        </div>
        <span class="chev"></span>
      </div>
      <div class="sexp-content">${rows}</div>
    </div>`;
  }).join('') + `
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.history}</span>
      <div class="scard-body">
        <div class="scard-title">Revert everything</div>
        <div class="scard-desc">Replays the backup journal in reverse, restoring every setting to its exact previous value.</div>
      </div>
      <div class="scard-control"><button class="fbtn" data-act="revert-all">Revert all tweaks</button></div>
    </div>`;
  wireExpanders($('#profileGrid'));
}

/* ---------- TWEAKS ---------- */
let tweakFilter = 'all';
function renderTweaks() {
  const cats = ['all', ...new Set(state.tweaks.map((t) => t.category))];
  $('#tweakFilters').innerHTML = `
    <label class="field-label" style="width:240px">Category
      <span class="fcombo"><select id="tweakFilterSel">
        ${cats.map((c) => `<option value="${esc(c)}" ${c === tweakFilter ? 'selected' : ''}>${esc(c === 'all' ? 'All categories' : c.charAt(0).toUpperCase() + c.slice(1))}</option>`).join('')}
      </select></span>
    </label>`;

  const groups = [
    { kind: 'action', title: 'Actions FrameForge applies and reverts' },
    { kind: 'verify', title: 'Verified healthy. We check these; we do not change them' },
    { kind: 'advise', title: 'Advisories. BIOS, in-game, or manual steps we guide you through' },
  ];
  let html = '';
  for (const g of groups) {
    let items = state.tweaks.filter((t) => t.kind === g.kind && (tweakFilter === 'all' || t.category === tweakFilter));
    if (!items.length) continue;
    html += `<div class="section-head"><h2>${esc(g.title)}</h2></div>`;
    html += `<div class="card-list">${items.map((t) => renderTweakRow(t)).join('')}</div>`;
  }
  $('#tweakList').innerHTML = html || `<div class="empty">No tweaks in this category.</div>`;
  wireExpanders($('#tweakList'));
}
function renderTweakRow(t) {
  const applied = isApplied(t.id);
  const supported = isSupported(t.id);
  let control = '';
  if (supported === false) {
    // engine.ps1 said this op does not apply here (wrong CPU vendor, no NVIDIA, missing
    // scheme or service). Not a warning, not an opportunity — just not applicable.
    control = statusChip('idle', 'Not applicable on this PC');
    if (t.kind === 'action') {
      control += `<label class="fswitch" title="Not applicable on this PC">
        <input type="checkbox" disabled data-act="toggle" data-id="${t.id}">
        <span class="switch-state"></span><span class="switch-track"><span class="switch-knob"></span></span>
      </label>`;
    }
  } else if (t.kind === 'action') {
    const needAdmin = t.requiresAdmin && !state.admin;
    const unknown = applied === null;
    const disabled = (needAdmin || unknown) ? 'disabled' : '';
    const why = needAdmin ? 'Requires administrator' : unknown ? 'This tweak’s current state could not be read, so it cannot be toggled safely' : '';
    // 'unknown', not 'idle': "could not check" is a hole in the measurement, and the idle
    // chip renders it in the same quiet grey as a neutral, nothing-to-see-here note.
    control = `${unknown ? statusChip('unknown', 'Could not check') : ''}<label class="fswitch" title="${esc(why)}">
      <input type="checkbox" ${applied === true ? 'checked' : ''} ${disabled} data-act="toggle" data-id="${t.id}">
      <span class="switch-state"></span><span class="switch-track"><span class="switch-knob"></span></span>
    </label>`;
  } else if (t.kind === 'verify') {
    control = applied === true ? statusChip('good', 'Healthy')
      : applied === false ? statusChip('warn', 'Check')
        : statusChip('unknown', 'Could not check');
  } else {
    const sat = advisorySatisfied(t);
    control = sat === true ? statusChip('good', 'Done') : `<button class="fbtn" data-act="guide" data-id="${t.id}">Show me</button>`;
  }
  const opText = describeOp(t);
  return `<div class="sexpander" data-id="${t.id}">
    <div class="scard sexp-head" data-act="expander">
      <span class="scard-icon" aria-hidden="true">${catGlyph(t)}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(t.name)}</div>
        <div class="scard-desc">${esc(t.summary)}</div>
      </div>
      <div class="scard-control">${control}</div>
      <span class="chev"></span>
    </div>
    <div class="sexp-content">
      <div class="tw-detail-block" id="detail-${t.id}">
        <p class="meta-caption" style="margin:0 0 6px">${metaLine(t)}</p>
        <p>${esc(t.details)}</p>
        <p><b style="color:var(--text-primary)">Why it helps:</b> ${esc(t.evidence)}</p>
        ${opText
      ? `<div class="mono">${esc(opText)}</div>`
      : '<p><i>This tweak’s operation could not be described from the catalog, so nothing is shown here rather than an empty box that pretends to be documentation.</i></p>'}
        <div class="src-list" style="margin-top:8px;display:flex;flex-direction:column;gap:2px">
          ${(t.sources || []).map((u) => `<a data-act="src" data-url="${esc(u)}">${esc(u)}</a>`).join('')}
        </div>
      </div>
    </div>
  </div>`;
}
function describeOp(t) {
  const op = t.op; if (!op) return '';
  if (op.type === 'advise') return 'Guided steps. FrameForge does not change this automatically.';
  if (op.type === 'verify') return `Read-only health check: ${op.check}`;
  const lines = [];
  const walk = (o) => {
    if (o.type === 'registry') lines.push(`${o.root}\\${o.path}\\${o.name} = ${o.value} (${o.valueType})`);
    else if (o.type === 'multi') o.ops.forEach(walk);
    else if (o.type === 'powercfg-scheme') lines.push(`powercfg → activate "${o.name}"${op.procMinState != null ? `, min processor state = ${op.procMinState}%` : ''}`);
    else if (o.type === 'service') lines.push(`service ${o.name} → ${o.startup}/${o.state}`);
    // An op type this function does not know about is shown verbatim rather than
    // silently producing an empty block that presents itself as the documentation
    // (doctrine rule 5: the catalog documents exactly what will run).
    else lines.push(JSON.stringify(o));
  };
  walk(op);
  return lines.join('\n');
}

/* ---------- BENCHMARK ---------- */
/* PowerShell 5.1's `@(...) | ConvertTo-Json` unrolls a single-element array, so ONE
   qualifying process serialises as a bare object rather than a one-item list — and one
   qualifying process is the normal case when you have launched exactly one game to
   measure. `Array.isArray(res) ? res : []` turned that shape mismatch into a confident
   "nothing found". This normalises the single-object form and returns null (not an empty
   list) for anything that is actually an error, so the caller can say so. */
function procList(res) {
  if (Array.isArray(res)) return res;
  if (res && typeof res === 'object' && res.ok !== false && (res.name || res.ids)) return [res];
  return null;
}
async function refreshBenchTargets() {
  const sel = $('#benchTarget');
  sel.innerHTML = `<option value="">Loading…</option>`;
  const res = await window.ff.windowedProcs();
  const list = procList(res);
  if (!list) {
    sel.innerHTML = `<option value="">Could not read running processes</option>`;
    const st = $('#benchStatus');
    if (st) st.textContent = `Running processes could not be read: ${engineErrorText(res)}`;
    return;
  }
  sel.innerHTML = `<option value="">Select a running game or app…</option>` +
    list.map((p) => `<option value="${esc(p.name)}.exe">${esc(String(p.title || p.name || '').slice(0, 42))} — ${esc(p.name)} (${esc(p.ramMB)} MB)</option>`).join('');
}
// Each metric is its own SettingsCard: what it means on the left, the reading on the
// right. The legend that used to live in a separate expander is now the description,
// so there is no second place to look up what a number means.
const BENCH_METRICS = [
  { key: 'avgFps', label: 'Average FPS', unit: '', higher: true, desc: 'Overall smoothness across the run. Higher is better.' },
  { key: 'low1Fps', label: '1% low', unit: '', higher: true, desc: 'The average of your slowest 1% of frames — this is what stutter is made of.' },
  { key: 'low01Fps', label: '0.1% low', unit: '', higher: true, desc: 'Worst-case hitching. Big gaps here are the freezes you actually notice.' },
  { key: 'stutterMs', label: 'Stutter (frametime σ)', unit: ' ms', higher: false, desc: 'Frame-to-frame consistency. Lower is smoother.' },
];
function metricCard(m, b, a) {
  const bv = b ? b[m.key] : null, av = a ? a[m.key] : null;
  let read;
  if (bv == null && av == null) read = '<span class="mval">&ndash;</span>';
  else if (av == null) read = `<span class="mval"><span class="mnew">${bv}${m.unit}</span></span>`;
  else read = `<span class="mval">${bv != null ? `${bv}${m.unit} &rarr; ` : ''}<span class="mnew">${av}${m.unit}</span></span>`;
  let delta = '';
  if (bv != null && av != null) {
    const d = av - bv; const up = m.higher ? d > 0 : d < 0;
    const pct = bv ? Math.round((d / bv) * 100) : 0;
    if (Math.abs(d) > 0.05) delta = `<span class="delta ${up ? 'up' : 'down'}">${d > 0 ? '+' : ''}${pct}%</span>`;
  }
  return `<div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.speed}</span>
    <div class="scard-body">
      <div class="scard-title">${m.label}</div>
      <div class="scard-desc">${m.desc}</div>
    </div>
    <div class="scard-control">${read}${delta}</div>
  </div>`;
}
function runCard(title, m, desc) {
  return `<div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.history}</span>
    <div class="scard-body">
      <div class="scard-title">${title}</div>
      <div class="scard-desc">${desc}</div>
    </div>
    <div class="scard-control">${m ? statusChip('good', `${m.frames} frames · ${m.durationSec}s`) : statusChip('idle', 'Not recorded yet')}</div>
  </div>`;
}
// Honest A/B verdict: is the after-vs-baseline change real, or within run-to-run noise?
function benchVerdict(b, a) {
  if (!b || !a) return '';
  const pct = (k) => (b[k] ? ((a[k] - b[k]) / b[k]) * 100 : 0);
  const dAvg = pct('avgFps'), dLow = pct('low1Fps');
  const NOISE = 3; // % — below this on a desktop is run-to-run variance, not a real change
  const real = Math.abs(dAvg) >= NOISE || Math.abs(dLow) >= NOISE;
  const fmt = (v) => `${v >= 0 ? '+' : ''}${v.toFixed(1)}%`;
  if (!real) {
    return `<div class="infobar" style="margin-top:8px"><span class="glyph" aria-hidden="true">${GLYPH.info}</span><div class="ib-body"><span class="ib-title">Within margin of error on this PC</span><span class="ib-msg">No measurable change (average ${fmt(dAvg)}, 1% low ${fmt(dLow)}). Anything under ${NOISE}% is run-to-run variance. That is a result, not a failure.</span></div></div>`;
  }
  const better = dLow > 0 || dAvg > 0;
  return `<div class="infobar ${better ? 'success' : 'critical'}" style="margin-top:8px"><span class="glyph" aria-hidden="true">${better ? GLYPH.check : GLYPH.warning}</span><div class="ib-body"><span class="ib-title">${better ? 'Measurable change' : 'Measurable regression'}</span><span class="ib-msg">Average ${fmt(dAvg)}, 1% low ${fmt(dLow)}.</span></div></div>`;
}
function renderBench() {
  const b = state.bench.baseline, a = state.bench.after;
  const ctx = state.bench.context
    ? `<div class="infobar" style="margin-bottom:8px"><span class="glyph" aria-hidden="true">${GLYPH.info}</span><div class="ib-body"><span class="ib-title">Measuring: ${esc(state.bench.context)}</span><span class="ib-msg">Record baseline, change the setting (NVIDIA settings need a game relaunch), then record after.</span></div></div>`
    : '';
  const runs = `<div class="card-list">
    ${runCard('Baseline', b, 'The reading taken before you changed anything')}
    ${runCard('After', a, 'The reading taken once the change is live in the game')}
  </div>`;
  const metrics = `<div class="card-list" style="margin-top:2px">${BENCH_METRICS.map((m) => metricCard(m, b, a)).join('')}</div>`;
  $('#benchResults').innerHTML = ctx + runs + metrics + benchVerdict(b, a);
}

/* ---------- GAME FOCUS ---------- */
let focusSel = new Set();
async function renderFocus() {
  const res = await window.ff.bloatProcs();
  const list = procList(res);
  if (!list) {
    // Never the "nothing found" copy for a read that failed.
    $('#reclaimMB').textContent = '–';
    $('#focusList').innerHTML = infobarHtml('critical', GLYPH.error, 'Could not read running processes',
      `${engineErrorText(res)} No claim is being made about what is running on this PC.`,
      `<button class="fbtn" data-act="focus-rescan">Rescan</button>${diagButton(engineErrorText(res))}`);
    $('#focusClose').disabled = true;
    return;
  }
  const total = list.reduce((s, p) => s + (Number(p.ramMB) || 0), 0);
  $('#reclaimMB').textContent = `${(total / 1024).toFixed(1)} GB`;
  if (!list.length) { $('#focusList').innerHTML = `<div class="empty">No background apps worth closing.</div>`; $('#focusClose').disabled = true; return; }
  $('#focusList').innerHTML = list.map((p) => {
    const idArr = Array.isArray(p.ids) ? p.ids : (p.ids != null ? [p.ids] : []);
    const ids = idArr.join(',');
    return `<label class="scard clickable" data-ids="${esc(ids)}">
      <input type="checkbox" class="fcheck" ${focusSel.has(ids) ? 'checked' : ''} data-act="focus-sel" data-ids="${esc(ids)}">
      <div class="scard-body">
        <div class="scard-title">${esc(p.name)}</div>
        <div class="scard-desc">${idArr.length} process${idArr.length > 1 ? 'es' : ''}</div>
      </div>
      <span class="scard-value">${esc(p.ramMB)} MB</span>
    </label>`;
  }).join('');
  $('#focusClose').disabled = focusSel.size === 0;
}

/* ---------- admin UI ---------- */
function updateAdminUI() {
  const pill = $('#adminPill');
  pill.classList.remove('ok', 'no');
  if (state.admin) {
    pill.classList.add('ok');
    $('#adminText').textContent = 'Administrator';
    $('#adminCard').hidden = true;
  } else {
    pill.classList.add('no');
    $('#adminText').textContent = 'Limited access — select to elevate';
    $('#adminCard').hidden = false;
  }
}

/* ---------- actions ---------- */
/* Detection has three outcomes, and "did not run" is one of them. Leaving state.detect
   empty made isApplied() answer false for everything, which rendered a score of 0 and a
   fabricated list of ~20 "detected opportunities" on a machine nothing was read from. */
async function refreshDetect() {
  state.detect = {};
  let arr;
  try { arr = await window.ff.detectAll(); }
  catch (e) { arr = { ok: false, error: String((e && e.message) || e) }; }
  if (Array.isArray(arr)) {
    state.detectFailed = false; state.detectError = null;
    for (const d of arr) if (d && d.id) state.detect[d.id] = d;
    return;
  }
  state.detectFailed = true;
  state.detectError = engineErrorText(arr);
}

/* Elevation. relaunchElevated() now resolves only once the elevated instance actually
   started; a declined UAC prompt (or a policy-blocked RunAs) leaves FrameForge running
   and says so, instead of the window silently vanishing 400 ms after the click. */
async function requestElevation() {
  let r;
  try { r = await window.ff.relaunchElevated(); }
  catch (e) { r = { ok: false, error: String((e && e.message) || e) }; }
  if (r && r.ok) return true;   // this instance is about to quit
  if (r && r.cancelled) {
    toast('warn', 'Elevation was cancelled',
      'FrameForge is still running without administrator rights. Admin-only checks report “needs administrator” rather than a result.');
  } else {
    toast('err', 'Could not restart as administrator',
      `${(r && r.error) || 'The elevated instance did not start.'} FrameForge is still running without administrator rights.`);
  }
  return false;
}

async function applyTweak(id) {
  const t = state.tweaks.find((x) => x.id === id); if (!t) return;
  if (t.requiresAdmin && !state.admin) { toast('warn', 'Administrator required', `Restart FrameForge as admin to apply “${t.name}”.`); return; }
  const r = await window.ff.apply(id);
  if (r && r.success) { toast('ok', 'Applied', t.name + (t.requiresReboot ? ' · reboot to take full effect' : '')); }
  else if (r && r.needsElevation) { toast('warn', 'Administrator required', t.name); }
  else { toast('err', 'Could not apply', (r && (r.message || r.error)) || t.name); }
  await refreshDetect(); rerenderAll();
}
async function revertTweak(id) {
  const t = state.tweaks.find((x) => x.id === id);
  const r = await window.ff.revert(id);
  if (r && r.success) toast('ok', 'Reverted', t ? t.name : id); else toast('err', 'Could not revert', (r && (r.message || r.error)) || id);
  await refreshDetect(); rerenderAll();
}
async function applyProfile(pid) {
  const p = PROFILES.find((x) => x.id === pid); if (!p) return;
  const items = profileTweaks(p).filter((t) => !isApplied(t.id));
  if (!items.length) { toast('ok', 'Already optimized', `${p.name}: every item is already applied.`); return; }
  const needAdmin = items.some((t) => t.requiresAdmin) && !state.admin;
  if (needAdmin) { toast('warn', 'Some items need admin', 'Restart as administrator to apply the full profile. Applying the rest now.'); }
  let ok = 0, skip = 0;
  // A skipped item used to vanish into a bare count. When the reason is "FrameForge is
  // running as the wrong Windows account" the user cannot act without being told, so the
  // first real refusal reason travels with the summary.
  const reasons = [];
  for (const t of items) {
    if (t.requiresAdmin && !state.admin) { skip++; reasons.push(`${t.name}: needs administrator.`); continue; }
    const r = await window.ff.apply(t.id);
    if (r && r.success) { ok++; }
    else { skip++; reasons.push(`${t.name}: ${(r && (r.message || r.error)) || 'no reason given.'}`); }
  }
  const tail = skip ? ` ${reasons[0]}${reasons.length > 1 ? ` (+${reasons.length - 1} more)` : ''}` : '';
  toast(skip ? 'warn' : 'ok', `${p.name} applied`, `${ok} applied${skip ? `, ${skip} skipped.` : '.'}${tail}`, skip ? 16000 : undefined);
  await refreshDetect(); rerenderAll();
}
async function revertAll() {
  const r = await window.ff.revertAll();
  // This used to toast "Reverted everything" unconditionally. When FrameForge is running as
  // another Windows account the ledger it can read is that account's — usually empty — so the
  // cheerful message was a claim about a profile it never touched. The engine now says
  // success=false with a reason; the UI must not paper over it (doctrine rule 2 and 3).
  if (!r || r.success !== true) {
    toast('err', 'Not everything was undone',
      (r && (r.message || r.error)) || 'FrameForge could not confirm that anything was reverted.', 16000);
  } else {
    toast('ok', 'Reverted everything', r.count != null ? `${r.count} change(s) undone.` : 'Done.');
  }
  await refreshDetect(); rerenderAll();
}
function showGuide(id) {
  const t = state.tweaks.find((x) => x.id === id); if (!t) return;
  const steps = (t.guide || []).map((g) => `<li>${esc(g)}</li>`).join('');
  openDrawer(`
    <div class="drawer-head">
      <h2>${esc(t.name)}</h2>
      <button class="icon-btn" data-act="close-drawer" aria-label="Close">${GLYPH.close}</button>
    </div>
    <div class="meta-line">${metaLine(t)}</div>
    <p>${esc(t.details)}</p>
    <h3>Steps</h3>
    <ol>${steps || '<li>No steps.</li>'}</ol>
    <div class="src-list">${(t.sources || []).map((u) => `<a data-act="src" data-url="${esc(u)}">${esc(u)}</a>`).join('')}</div>
  `);
}

/* ---------- benchmark capture ---------- */
// The "Record a run" card's description doubles as the live capture status, so the
// right slot stays a pair of controls rather than a sentence.
const BENCH_IDLE_TEXT = 'Record a baseline, change one thing, then record after';
async function runCapture(which) {
  const proc = $('#benchTarget').value; const secs = Number($('#benchSeconds').value);
  if (!proc) { toast('warn', 'Pick a target', 'Choose a running game or app to measure.'); return; }
  if (!state.admin) { toast('warn', 'Administrator required', 'PresentMon frametime capture needs admin. Restart as administrator.'); return; }
  const st = $('#benchStatus'); st.textContent = `Capturing ${proc} for ${secs}s…`;
  $('#benchBaseline').disabled = $('#benchAfter').disabled = true;
  const r = await window.ff.capture(proc, secs, which);
  $('#benchBaseline').disabled = false;
  if (r && r.ok) {
    state.bench[which] = r; st.textContent = `${which === 'baseline' ? 'Baseline' : 'After'} recorded: ${r.avgFps} FPS average, ${r.low1Fps} 1% low`;
    renderBench();
  } else {
    st.textContent = BENCH_IDLE_TEXT;
    toast('err', 'Capture failed', (r && (r.reason || r.error)) || 'Make sure the game is running and rendering.');
  }
  // Derive "After" from whether a baseline exists, in BOTH paths. It used to be
  // re-enabled only inside the baseline-success branch, so a second "after" run — or a
  // retry after a failed one — was impossible without re-recording the baseline.
  $('#benchAfter').disabled = !state.bench.baseline;
}

/* ---------- rerender ----------
   Each section renders in its own try/catch: a throw inside renderDashboard used to
   prevent renderBoost and renderTweaks from ever running, so one bad field blanked the
   entire application rather than one card. */
function safely(what, fn) {
  try { fn(); }
  catch (e) {
    console.error(`[FrameForge] ${what} failed to render`, e);
    toast('err', `${what} could not be drawn`, String((e && e.message) || e));
  }
}
function rerenderAll() {
  safely('Home', renderDashboard);
  safely('One-click boost', renderBoost);
  safely('Tweaks', renderTweaks);
  const n = tweaksByKind('action').filter((t) => isApplied(t.id) === true).length;
  $('#tweaksAppliedBadge').textContent = n ? String(n) : '';
}

/* ---------- nav ---------- */
// Sub-pages have no nav entry of their own; they keep their parent's entry selected.
const NAV_FOR = { 'nvidia-advanced': 'nvidia' };
const PAGE_TITLES = {
  dashboard: 'Home', boost: 'One-click boost', tweaks: 'Tweaks', focus: 'Game focus',
  nvidia: 'NVIDIA', 'nvidia-advanced': 'Every NVIDIA setting', benchmark: 'Benchmark',
  health: 'Windows health', repair: 'Repair', safety: 'Safety and recovery',
};
// moveFocus is false when the view changes as a side effect of typing in the search box —
// stealing focus mid-keystroke would be worse than the announcement is worth.
function switchView(v, moveFocus = true) {
  const nav = NAV_FOR[v] || v;
  $$('.nav-item[data-view]').forEach((n) => {
    const on = n.dataset.view === nav;
    n.classList.toggle('active', on);
    // A CSS-only .active class tells a screen-reader user nothing about which page is
    // selected. aria-current does.
    if (on) n.setAttribute('aria-current', 'page'); else n.removeAttribute('aria-current');
  });
  $$('.view').forEach((s) => s.classList.toggle('active', s.id === 'view-' + v));
  $('#content').scrollTop = 0;
  // Move focus to the new page's heading so the page name is announced; without this,
  // focus stays on the nav button and nothing says the content region was replaced.
  const active = $('#view-' + v);
  const h1 = active && active.querySelector('.page-title');
  if (h1 && moveFocus) { h1.setAttribute('tabindex', '-1'); try { h1.focus({ preventScroll: true }); } catch (e) { h1.focus(); } }
  if (v === 'benchmark') { refreshBenchTargets(); renderBench(); }
  if (v === 'focus') renderFocus();
  if (v === 'nvidia' || v === 'nvidia-advanced') loadNvidia();
  if (v === 'health') loadHealth();
  if (v === 'repair') loadRepair();
}

/* ---------- global click handler ---------- */
document.addEventListener('click', async (e) => {
  const navBtn = e.target.closest('.nav-item[data-view]');
  if (navBtn) { $('#navSearch').value = ''; return switchView(navBtn.dataset.view); }
  const t = e.target.closest('[data-act]'); if (!t) return;
  const act = t.dataset.act, id = t.dataset.id;
  switch (act) {
    case 'search-go': { $('#navSearch').value = ''; switchView(t.dataset.view); break; }
    case 'expander': {
      // clicking an interactive control inside the header must not toggle expansion
      if (e.target.closest('.fswitch, .fbtn, .fcheck, a, .linkbtn, select, .status, .ftext')) break;
      const x = t.closest('.sexpander'); if (!x) break;
      x.classList.toggle('open');
      const chev = x.querySelector(':scope > .sexp-head > .chev');
      if (chev) chev.setAttribute('aria-expanded', x.classList.contains('open') ? 'true' : 'false');
      // Health, repair and fresh-image cards re-render on every engine result, so the
      // open/closed state lives in state rather than in the DOM.
      for (const k of ['repair', 'health', 'img', 'nvadv']) {
        if (!x.dataset[k]) continue;
        if (x.classList.contains('open')) openRows[k].add(x.dataset[k]); else openRows[k].delete(x.dataset[k]);
      }
      // Repairs run their read-only preflight the first time they are opened, so the
      // exact command list shown is the live one, not just the catalog's copy.
      if (x.classList.contains('open') && x.dataset.repair) ensureRepairPreflight(x.dataset.repair);
      break;
    }
    // Guard like every sibling handler: a card whose id is no longer in state.tweaks
    // (catalog reload racing a pending render) used to throw inside the delegated
    // handler and silently abort the rest of its work.
    case 'opp': { const tw = state.tweaks.find((x) => x.id === id); if (!tw) break; if (tw.kind === 'advise') showGuide(id); else applyTweak(id); break; }
    case 'copy-diag': {
      const text = (t.dataset.diag != null && t.dataset.diag !== '') ? t.dataset.diag : (lastDiagnostic || '');
      (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject(new Error('no clipboard')))
        .then(() => toast('ok', 'Diagnostic copied', 'The engine’s exact error text is on your clipboard.'))
        .catch(() => toast('warn', 'Could not copy', text.slice(0, 300)));
      break;
    }
    case 'retry-sys': retrySysInfo(); break;
    case 'retry-detect': retryDetect(); break;
    case 'focus-rescan': { focusSel.clear(); renderFocus(); break; }
    case 'toggle': break; // handled by change
    case 'src': window.ff.openExternal(t.dataset.url); break;
    case 'guide': showGuide(id); break;
    case 'apply-profile': applyProfile(id); break;
    case 'revert-all': revertAll(); break;
    case 'close-drawer': closeDrawer(); break;
    case 'focus-sel': break;
    case 'nv-snapshot': nvSnapshot(); break;
    case 'nv-apply': nvApply(t.dataset.preset); break;
    case 'nv-revert': nvRevert(); break;
    case 'nv-open': window.ff.nvidia.open(); toast('ok', 'Opening NVIDIA tuner', 'Accept the UAC prompt.'); break;
    case 'nv-measure': nvMeasure(t.dataset.key); break;
    case 'nv-open-adv': if (t.getAttribute('aria-disabled') === 'true') break; switchView('nvidia-advanced'); break;
    case 'nv-close-adv': switchView('nvidia'); break;
    case 'nv-clearsel': { state.nvidia.sel.clear(); renderNvidia(); break; }
    case 'nv-retry': { nvLoaded = false; loadNvidia(true); break; }
    case 'nv-applycustom': nvApplyCustom(); break;
    case 'nv-reverify': nvReverify(); break;

    /* ---- Windows health ---- */
    case 'health-scan': runHealthScan(!!t.dataset.deep); break;
    case 'health-elevate': requestElevation(); break;
    case 'health-fix': openRepairFor(t.dataset.id); break;

    /* ---- Repair ---- */
    case 'repair-refresh': loadRepair(true); break;
    case 'repair-preview': repairAction(t.dataset.id, { dryRun: true }); break;
    case 'repair-run': repairAction(t.dataset.id, {}); break;
    case 'repair-force': repairAction(t.dataset.id, { force: true }); break;
    case 'repair-undo': repairUndo(t.dataset.id); break;

    /* ---- Fresh-image repair ---- */
    case 'img-detect': imgRun('detect'); break;
    case 'img-validate': imgRun('validate'); break;
    case 'img-preflight': imgRun('preflight', { dryRun: !!t.dataset.dry }); break;
    case 'img-contract': imgRun('launch'); break;
    case 'img-acquire': imgRun('acquireUrl', { dryRun: true }); break;
    case 'img-verify': imgRun('verify'); break;
    case 'img-launch': imgLaunchConfirmed(); break;
  }
});
// keyboard activation for [role=button] controls (expander chevrons, search result cards)
document.addEventListener('keydown', (e) => {
  if ((e.key === 'Enter' || e.key === ' ') && e.target instanceof Element && e.target.matches('[role="button"][data-act]')) {
    e.preventDefault(); e.target.click();
    return;
  }
  if (!drawerOpen()) return;
  // The drawer is modal: Escape closes it and Tab cycles inside it.
  if (e.key === 'Escape') { e.preventDefault(); closeDrawer(); return; }
  if (e.key !== 'Tab') return;
  const d = $('#drawer');
  const items = Array.from(d.querySelectorAll(FOCUSABLE)).filter((n) => n.offsetParent !== null || n === document.activeElement);
  if (!items.length) { e.preventDefault(); try { d.focus(); } catch (_) {} return; }
  const first = items[0], last = items[items.length - 1];
  if (e.shiftKey && (document.activeElement === first || !d.contains(document.activeElement))) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && (document.activeElement === last || !d.contains(document.activeElement))) { e.preventDefault(); first.focus(); }
});
document.addEventListener('change', async (e) => {
  const t = e.target.closest('[data-act]'); if (!t) return;
  if (t.dataset.act === 'toggle') { e.target.checked ? applyTweak(t.dataset.id) : revertTweak(t.dataset.id); }
  if (t.dataset.act === 'focus-sel') {
    const ids = t.dataset.ids; if (e.target.checked) focusSel.add(ids); else focusSel.delete(ids);
    $('#focusClose').disabled = focusSel.size === 0;
  }
  if (t.dataset.act === 'repair-norp') {
    const rid = t.dataset.id;
    if (e.target.checked) repairs.noRestorePoint.add(rid); else repairs.noRestorePoint.delete(rid);
    renderRepair();
  }
  if (t.dataset.act === 'img-consent') {
    if (t.dataset.which === 'eula') img.consentEula = e.target.checked; else img.consentBitlocker = e.target.checked;
    renderImageRepair();
  }
  if (t.dataset.act === 'nv-ig') {} // self-checklist only
  if (t.dataset.act === 'nv-sel') {
    const key = t.dataset.key; const sel = state.nvidia.sel;
    if (e.target.checked) {
      sel.add(key);
      // Vertical Sync is one SettingID — the two modes are mutually exclusive.
      if (key === 'vsync-off') sel.delete('vsync-on');
      if (key === 'vsync-on') sel.delete('vsync-off');
    } else { sel.delete(key); }
    renderNvidia();
  }
});
// ISO path field: keep the value in state without re-rendering (that would steal focus).
document.addEventListener('input', (e) => { if (e.target && e.target.id === 'imgIsoPath') img.isoPath = e.target.value.trim(); });
// VRR toggle in the NVIDIA status cards
document.addEventListener('change', (e) => { if (e.target && e.target.id === 'nvVrr') { state.nvidia.vrr = e.target.checked; renderNvidia(); } });
// tweak category filter (delegated — the select is re-rendered)
$('#tweakFilters').addEventListener('change', (e) => { if (e.target && e.target.id === 'tweakFilterSel') { tweakFilter = e.target.value; renderTweaks(); } });

/* ---------- static wiring ---------- */
$('#drawerBackdrop').onclick = closeDrawer;
function setMode(m) {
  document.body.classList.toggle('advanced', m === 'advanced');
  $('#modeSwitch').setAttribute('aria-checked', m === 'advanced' ? 'true' : 'false');
  // hide the Tweaks nav entry in simple mode
  $('.nav-item[data-view=tweaks]').style.display = m === 'advanced' ? '' : 'none';
  if (m === 'simple' && $('#view-tweaks').classList.contains('active')) switchView('dashboard');
}
$('#modeSwitch').addEventListener('click', (e) => {
  const explicit = e.target.dataset ? e.target.dataset.mode : null;
  const m = explicit || (document.body.classList.contains('advanced') ? 'simple' : 'advanced');
  setMode(m);
});
/* ---------- "Find a setting" — real cross-catalog search ----------
   Searches the actual settings, tweaks, NVIDIA settings, health checks and repairs
   that the app can act on, not the nav labels. Each hit names the page it lives on
   and navigates there. An empty result set gets a real "no results" state, never a
   blank pane. */
function searchIndex() {
  const items = [];
  const push = (o) => items.push(o);
  // Pages themselves stay searchable.
  for (const [view, title] of Object.entries(PAGE_TITLES)) {
    if (view === 'nvidia-advanced') continue;
    push({ kind: 'Page', name: title, desc: 'Open this page', view, glyph: GLYPH.list });
  }
  for (const t of state.tweaks) {
    push({ kind: t.kind === 'advise' ? 'Advisory' : t.kind === 'verify' ? 'Health check' : 'Tweak', name: t.name, desc: t.summary, view: 'tweaks', glyph: catGlyph(t), keywords: `${t.category} ${t.id} ${t.details || ''}` });
  }
  const nv = state.nvidia.catalog;
  if (nv && nv.settings) {
    for (const k of Object.keys(nv.settings)) {
      const s = nv.settings[k];
      push({ kind: 'NVIDIA setting', name: s.name, desc: s.why, view: 'nvidia-advanced', glyph: GLYPH.chip, keywords: `${k} ${s.category || ''} ${s.recommendedLabel || ''}` });
    }
    for (const p of (nv.placebo || [])) push({ kind: 'Not shipped', name: p.name, desc: p.why, view: 'nvidia', glyph: GLYPH.dismiss });
  }
  for (const c of (health.catalog || [])) {
    push({ kind: 'Health check', name: c.name, desc: c.summary, view: 'health', glyph: healthGlyph(c.id), keywords: `${c.id} ${(c.whatWeCheck || []).join(' ')}` });
  }
  // The live list is richer (it carries detection state) but the static catalog is
  // enough to make repairs findable before the engine has been run.
  push({
    kind: 'Repair', name: 'Reinstall Windows over itself', view: 'repair', glyph: GLYPH.disc,
    desc: 'Fresh-image repair: replace every system file while keeping your files, apps, and settings.',
    keywords: 'in-place upgrade repair install fresh image iso bitlocker setup.exe eula consent windows.old rollback media creation tool fido',
  });
  for (const r of (repairs.list || repairs.catalog || [])) {
    push({ kind: 'Repair', name: r.name, desc: r.summary, view: 'repair', glyph: healthGlyph(r.category), keywords: `${r.id} ${r.category} ${r.tier} ${(r.whatItRuns || []).join(' ')}` });
  }
  return items;
}
function runSearch(q) {
  const needle = q.trim().toLowerCase();
  const hits = !needle ? [] : searchIndex()
    .map((it) => {
      const name = it.name.toLowerCase();
      const hay = `${name} ${(it.desc || '').toLowerCase()} ${(it.keywords || '').toLowerCase()}`;
      if (name.startsWith(needle)) return { it, rank: 0 };
      if (name.includes(needle)) return { it, rank: 1 };
      if (hay.includes(needle)) return { it, rank: 2 };
      return null;
    })
    .filter(Boolean)
    .sort((a, b) => a.rank - b.rank)
    .slice(0, 40)
    .map((x) => x.it);

  // The count goes in the page title AND, as a visually-hidden line, at the top of the
  // live region — otherwise a screen-reader user typing a query is never told how many
  // results appeared. (Both branches of the old ternary assigned the same string.)
  $('#searchTitle').textContent = needle
    ? `${hits.length} result${hits.length === 1 ? '' : 's'} for “${q.trim()}”`
    : 'Search results';
  const announce = `<p class="sr-only">${hits.length} result${hits.length === 1 ? '' : 's'} for “${esc(q.trim())}”</p>`;
  if (!hits.length) {
    $('#searchResults').innerHTML = announce + `<div class="empty-state">
      <span class="glyph" aria-hidden="true">${GLYPH.search}</span>
      <h3>No results for “${esc(q.trim())}”</h3>
      <p>Nothing in the tweak, NVIDIA, health-check, or repair catalogs matches that. Try a shorter word, or browse the pages in the list on the left.</p>
    </div>`;
    return;
  }
  $('#searchResults').innerHTML = announce + `<div class="card-list">${hits.map((it) => `
    <div class="scard clickable" data-act="search-go" data-view="${esc(it.view)}" role="button" tabindex="0">
      <span class="scard-icon" aria-hidden="true">${it.glyph || GLYPH.settings}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(it.name)}</div>
        <div class="scard-desc">${esc(it.desc || '')}</div>
      </div>
      <div class="scard-control">
        <span class="list-caption">${esc(it.kind)} <span class="sep-dot">·</span> ${esc(PAGE_TITLES[it.view] || it.view)}</span>
        <span class="chev">${GLYPH.chevronRight}</span>
      </div>
    </div>`).join('')}</div>`;
}
let searchReturnView = 'dashboard';
$('#navSearch').addEventListener('input', (e) => {
  const q = e.target.value;
  const onSearch = $('#view-search').classList.contains('active');
  if (!q.trim()) { if (onSearch) switchView(searchReturnView, false); return; }
  if (!onSearch) {
    const cur = $('.view.active');
    searchReturnView = cur ? cur.id.replace('view-', '') : 'dashboard';
    switchView('search', false);
  }
  runSearch(q);
});
$('#benchRefresh').onclick = refreshBenchTargets;
$('#benchBaseline').onclick = () => runCapture('baseline');
$('#benchAfter').onclick = () => runCapture('after');
$('#focusRefresh').onclick = () => { focusSel.clear(); renderFocus(); };
$('#focusClose').onclick = async () => {
  const ids = Array.from(focusSel).join(',').split(',').filter(Boolean);
  const r = await window.ff.closeProcs(ids);
  toast('ok', 'Closed background apps', r && r.closed ? `${r.closed.length} process(es) closed — RAM freed.` : 'Done.');
  focusSel.clear(); renderFocus();
};
$('#btnRestorePoint').onclick = async () => {
  $('#restoreStatus').textContent = ' — creating restore point…';
  const r = await window.ff.restorePoint();
  $('#restoreStatus').textContent = r && r.success ? ` — ${r.message}` : ` — ${(r && r.message) || 'failed'}`;
};
$('#btnRevertAll').onclick = revertAll;
$('#btnElevate').onclick = () => requestElevation();
$('#adminPill').onclick = () => { if (!state.admin) requestElevation(); };

/* ---------- NVIDIA page ---------- */
const NV_PRESET_CHIPS = {
  esports: [['Latency', 'best'], ['Tearing', 'yes'], ['Average FPS', 'unchanged']],
  balanced: [['Latency', '~1 ms above floor'], ['Tearing', 'none (needs VRR)'], ['Consistency', 'best']],
  quality: [['Focus', 'visual stability'], ['At 1080p', '≈ Balanced'], ['Image knobs', 'untouched']],
};
function nvBadge(s) {
  if (s.impact === 'placebo') return 'placebo';
  switch (s.category) {
    case 'latency': return s.impact === 'low' ? 'insurance' : 'real latency';
    case 'sync': return 'latency / sync';
    case 'power': return 'consistency';
    case 'framecap': return 'consistency';
    case 'shader': return 'anti-stutter';
    default: return 'insurance';
  }
}
let nvLoaded = false;
async function loadNvidia(force) {
  if (nvLoaded && !force) { renderNvidia(); return; }
  try {
    const [cat, det, games] = await Promise.all([window.ff.nvidia.catalog(), window.ff.nvidia.detect(), window.ff.nvidia.games()]);
    state.nvidia.catalog = cat; state.nvidia.detect = det || {}; state.nvidia.games = (games && games.games) || [];
    state.nvidia.active = (det && det.applied) || null;
    state.nvidia.error = isEngineError(cat) ? engineErrorText(cat) : null;
  } catch (e) {
    state.nvidia.catalog = null;
    state.nvidia.error = String((e && e.message) || e);
  } finally {
    nvLoaded = true;
    renderNvidia();
  }
}
function nvHasSnapshot() { return !!(state.nvidia.detect && state.nvidia.detect.snapshots > 0); }
/* Every region this function owns is written on EVERY path. The early return used to
   write "NVIDIA data unavailable." into #nvStrip alone and leave four section headings
   standing over empty space, which reads as "there is nothing here" rather than "this
   could not be loaded" — and the sub-page could still be entered with no data at all. */
function nvUnavailable(why) {
  const msg = `The NVIDIA settings catalog could not be read${why ? ` — ${why}` : '.'}`;
  const box = `<div class="empty">${esc(msg)}</div>`;
  for (const sel of ['#nvStrip', '#nvPresets', '#nvInGame', '#nvAdvBar', '#nvAdvanced', '#nvPlacebo']) {
    const el = $(sel); if (el) el.innerHTML = box;
  }
  const honesty = $('#nvHonesty');
  if (honesty) {
    honesty.innerHTML = infobarHtml('critical', GLYPH.error, 'NVIDIA settings could not be loaded',
      `${msg} Nothing on this page is a statement about your driver configuration.`,
      `<button class="fbtn" data-act="nv-retry">Retry</button>${diagButton(msg)}`);
  }
  const rv = $('#nvReverify'); if (rv) rv.hidden = true;
  // Do not let the "every setting" sub-page be opened onto a blank view.
  const adv = $('#nvAdvToggle');
  if (adv) { adv.setAttribute('aria-disabled', 'true'); adv.classList.add('is-disabled'); adv.removeAttribute('tabindex'); }
}
function renderNvidia() {
  const cat = state.nvidia.catalog; const det = state.nvidia.detect || {};
  // `presets` was the one key not guarded: a catalog missing it threw mid-render, after
  // #nvStrip had already been written, leaving the rest of the page stale/empty and the
  // exception escaping loadNvidia() unhandled.
  if (isEngineError(cat) || !cat.settings || !cat.presets) {
    nvUnavailable(state.nvidia.error || (cat && cat.error) || (cat && !cat.presets ? 'the catalog has no presets section.' : 'the catalog could not be parsed.'));
    return;
  }
  const adv = $('#nvAdvToggle');
  if (adv) { adv.removeAttribute('aria-disabled'); adv.classList.remove('is-disabled'); adv.setAttribute('tabindex', '0'); }
  const snapOk = nvHasSnapshot();
  $('#nvStrip').innerHTML = `
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.chip}</span>
      <div class="scard-body">
        <div class="scard-title">GeForce driver</div>
        <div class="scard-desc">Driver configuration only. No injection and no overlays, so it is safe under anti-cheat.</div>
      </div>
      <div class="scard-control">
        <span class="scard-value">${esc(det.driver || '—')}</span>
        <button class="fbtn" data-act="nv-open">Open tuner</button>
      </div>
    </div>
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.history}</span>
      <div class="scard-body">
        <div class="scard-title">Driver settings restore point</div>
        <div class="scard-desc">A full snapshot of the driver profile database, taken before anything is applied</div>
      </div>
      <div class="scard-control">
        ${snapOk
      ? statusChip('good', esc(det.latestSnap || 'saved'))
      : `${statusChip('warn', 'Required before applying')}<button class="fbtn accent" data-act="nv-snapshot">Create restore point</button>`}
      </div>
    </div>
    <div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.monitor}</span>
      <div class="scard-body">
        <div class="scard-title">G-SYNC / VRR display</div>
        <div class="scard-desc">Sync settings are only written when this is on. Confirm your display supports variable refresh first.</div>
      </div>
      <div class="scard-control">
        <label class="fswitch"><input type="checkbox" id="nvVrr" ${state.nvidia.vrr ? 'checked' : ''}><span class="switch-state"></span><span class="switch-track"><span class="switch-knob"></span></span></label>
      </div>
    </div>`;
  // Per-machine catalog freshness: the catalog's IDs are driver-specific. Offer re-verify on mismatch.
  const rv = $('#nvReverify');
  const catDrv = cat.driverVerifiedOn, curDrv = det.driver;
  const unresolved = Object.keys(cat.settings).filter((k) => cat.settings[k].idConfidence === 'unresolved');
  if (rv) {
    if (curDrv && catDrv && curDrv !== catDrv) {
      rv.hidden = false;
      rv.innerHTML = `<div class="infobar caution"><span class="glyph" aria-hidden="true">${GLYPH.warning}</span><div class="ib-body"><span class="ib-title">Catalog verified on a different driver</span><span class="ib-msg">This settings catalog was verified on driver ${esc(catDrv)}, but yours is ${esc(curDrv)}. Re-verify the setting IDs against your driver before applying.</span></div><div class="ib-actions"><button class="fbtn" data-act="nv-reverify">Re-verify (admin)</button></div></div>`;
    } else if (unresolved.length) {
      rv.hidden = false;
      rv.innerHTML = `<div class="infobar caution"><span class="glyph" aria-hidden="true">${GLYPH.warning}</span><div class="ib-body"><span class="ib-msg">${unresolved.length} setting(s) couldn't be resolved on your driver and are disabled.</span></div><div class="ib-actions"><button class="fbtn" data-act="nv-reverify">Re-verify (admin)</button></div></div>`;
    } else { rv.hidden = true; }
  }
  // Settings rows, not a comparison grid: each profile is a SettingsExpander whose
  // child rows are the exact driver settings it writes.
  const presets = cat.presets || {};   // belt and braces; the guard above already covers it
  const vrrKeys = ['gsync-global', 'gsync-mode', 'vsync-on'];
  $('#nvPresets').innerHTML = Object.keys(presets).map((k) => {
    const p = presets[k]; const feat = k === 'balanced'; const active = state.nvidia.active === k;
    const dis = (!state.admin || !snapOk) ? 'disabled' : '';
    const nm = sentenceCase(String(p.name).replace(/\s*\(recommended\)/i, ''));
    const rows = (p.applied || []).map((key) => {
      const s = cat.settings[key]; if (!s) return '';
      const skipped = !state.nvidia.vrr && vrrKeys.includes(key);
      return `<div class="sexp-row">
        <div class="scard-body">
          <div class="scard-title">${esc(s.name)}</div>
          <div class="scard-desc">NVIDIA default: ${esc(s.defaultLabel)}</div>
        </div>
        <div class="scard-control">${skipped
        ? statusChip('warn', 'Skipped without VRR')
        : `<span class="scard-value" style="color:var(--text-primary)">${esc(s.recommendedLabel)}</span>`}</div>
      </div>`;
    }).join('') || '<div class="sexp-row"><div class="scard-body"><div class="scard-desc">This profile writes nothing.</div></div></div>';
    const factRows = (NV_PRESET_CHIPS[k] || []).map((c) => `<div class="sexp-row">
      <div class="scard-body"><div class="scard-title">${esc(c[0])}</div></div>
      <div class="scard-control"><span class="scard-value">${esc(c[1])}</span></div>
    </div>`).join('');
    return `<div class="sexpander" id="nvprofile-${k}">
      <div class="scard sexp-head" data-act="expander">
        <span class="scard-icon" aria-hidden="true">${feat ? GLYPH.speed : GLYPH.game}</span>
        <div class="scard-body">
          <div class="scard-title">${esc(nm)}${feat ? ' <span class="tag-recommended">· Recommended</span>' : ''}${active ? ' <span class="tag-active">· Active</span>' : ''}</div>
          <div class="scard-desc">${esc(p.description)}</div>
        </div>
        <div class="scard-control">
          <span class="list-caption">${(p.applied || []).length} settings</span>
          ${active ? '<button class="fbtn" data-act="nv-revert">Revert</button>' : ''}
          <button class="fbtn ${feat ? 'accent' : ''}" data-act="nv-apply" data-preset="${k}" ${dis} title="${!snapOk ? 'Create the driver settings restore point first' : !state.admin ? 'Requires administrator' : ''}">${active ? 'Reapply' : 'Apply'}</button>
        </div>
        <span class="chev">${GLYPH.chevronDown}</span>
      </div>
      <div class="sexp-content">${factRows}${rows}</div>
    </div>`;
  }).join('');
  $('#nvHonesty').innerHTML = `<div class="infobar"><span class="glyph" aria-hidden="true">${GLYPH.info}</span><div class="ib-body"><span class="ib-title">What to expect on this PC</span><span class="ib-msg">At 1080p a 14900KF is CPU-bound, so the average FPS number will not move. What these settings buy is frametime consistency and correct sync behaviour; the latency win comes from in-game Reflex. Measure it before and after rather than taking our word for it.</span></div><div class="ib-actions"><button class="fbtn" data-act="nv-measure">Measure it</button></div></div>`;
  $('#nvInGame').innerHTML = (cat.inGame || []).map((g) => `
    <label class="scard clickable">
      <input type="checkbox" class="fcheck" data-act="nv-ig">
      <div class="scard-body">
        <div class="scard-title">${esc(g.name)}${g.warn ? ` <span class="status crit" style="margin-left:6px"><span class="glyph" aria-hidden="true">${GLYPH.warning}</span></span>` : ''}</div>
        <div class="scard-desc">${esc(g.games)} — ${esc(g.note)}</div>
      </div>
    </label>`).join('');
  const vrrOnly = ['gsync-global', 'gsync-mode', 'vsync-on'];
  const selN = state.nvidia.sel.size;
  const applyDis = (!state.admin || !snapOk || selN === 0) ? 'disabled' : '';
  const nSettings = Object.keys(cat.settings).length;
  const bar = `<div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.chip}</span>
    <div class="scard-body">
      <div class="scard-title">Driver settings catalog</div>
      <div class="scard-desc">${nSettings} settings FrameForge can write, each verified against a driver setting ID</div>
    </div>
    <div class="scard-control"><span class="scard-value">Driver ${esc(det.driver || 'unknown')}</span></div>
  </div>
  <div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.settings}</span>
    <div class="scard-body">
      <div class="scard-title">Custom profile</div>
      <div class="scard-desc">${selN} setting${selN === 1 ? '' : 's'} selected${snapOk ? '' : ' · a driver restore point is required first'}${state.admin ? '' : ' · applying needs administrator rights'}</div>
    </div>
    <div class="scard-control">
      <button class="fbtn" data-act="nv-clearsel" ${selN === 0 ? 'disabled' : ''}>Clear</button>
      <button class="fbtn accent" data-act="nv-applycustom" ${applyDis}>Apply selected</button>
    </div>
  </div>`;
  // One SettingsExpander per driver setting. The card face carries only what Settings
  // would show — name, one-line description, and the recommended value. The driver
  // setting ID, tier, scope and NVIDIA default live in the expanded detail, where they
  // are still verifiable but no longer a third metadata line on the card.
  const rows = Object.keys(cat.settings).map((key) => {
    const s = cat.settings[key];
    const gated = !state.nvidia.vrr && vrrOnly.includes(key);
    const checked = state.nvidia.sel.has(key) ? 'checked' : '';
    const detail = [
      ['Recommended value', esc(s.recommendedLabel)],
      ['NVIDIA default', esc(s.defaultLabel)],
      ['Driver setting ID', String(s.settingId)],
      ['Tier and scope', `${esc(s.tier)} tier · ${esc(s.scope)} · ${esc(nvBadge(s))}`],
    ].map(([k, v]) => `<div class="sexp-row">
      <div class="scard-body"><div class="scard-title">${k}</div></div>
      <div class="scard-control"><span class="scard-value">${v}</span></div>
    </div>`).join('');
    return `<div class="sexpander${openRows.nvadv.has(key) ? ' open' : ''}" data-nvadv="${esc(key)}">
      <div class="scard sexp-head" data-act="expander">
        <input type="checkbox" class="fcheck" data-act="nv-sel" data-key="${key}" ${checked} ${gated ? 'disabled' : ''} aria-label="Add ${esc(s.name)} to the custom profile" title="${gated ? 'Confirm a G-SYNC/VRR display first' : 'Add to the custom profile'}">
        <div class="scard-body">
          <div class="scard-title">${esc(s.name)}</div>
          <div class="scard-desc">${esc(s.why)}</div>
        </div>
        <div class="scard-control"><span class="scard-value" style="color:var(--text-primary)">${esc(s.recommendedLabel)}</span></div>
        <span class="chev">${GLYPH.chevronDown}</span>
      </div>
      <div class="sexp-content">${detail}
        <div class="sexp-row">
          <div class="scard-body"><div class="scard-title">Measure the effect of this setting</div><div class="scard-desc">Records a before-and-after capture on the Benchmark page</div></div>
          <div class="scard-control"><button class="fbtn" data-act="nv-measure" data-key="${key}">Measure it</button></div>
        </div>
      </div>
    </div>`;
  }).join('');
  $('#nvAdvBar').innerHTML = bar;
  $('#nvAdvanced').innerHTML = rows;
  $('#nvPlacebo').innerHTML = (cat.placebo || []).map((p) => `
    <div class="scard" style="opacity:0.85">
      <span class="scard-icon" aria-hidden="true" style="color:var(--critical)">${GLYPH.dismiss}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(p.name)}</div>
        <div class="scard-desc">${esc(p.why)}</div>
      </div>
      <div class="scard-control">${statusChip('crit', 'Not shipped')}</div>
    </div>`).join('');
  wireExpanders($('#nvPresets'));
  wireExpanders($('#nvAdvanced'));
}
async function nvSnapshot() {
  const r = await window.ff.nvidia.snapshot();
  if (r && r.ok) toast('ok', 'NVIDIA snapshot saved', 'Full driver-profile restore point created.'); else toast('err', 'Snapshot failed', r && r.reason);
  await loadNvidia(true);
}
async function nvApply(presetKey) {
  if (!state.admin) { toast('warn', 'Administrator required', 'Restart FrameForge as admin to apply NVIDIA settings.'); return; }
  if (!nvHasSnapshot()) { toast('warn', 'Create a restore point first', 'Take a one-click NVIDIA snapshot before applying.'); return; }
  toast('ok', 'Applying…', presetKey);
  const r = await window.ff.nvidia.applyPreset(presetKey, state.nvidia.vrr);
  if (r && r.ok) toast('ok', `Applied “${presetKey}”`, (r.degraded ? 'Tear-tolerant sync (no VRR confirmed). ' : '') + 'Relaunch your game to take effect.');
  else if (r && r.needsElevation) toast('warn', 'Administrator required');
  else toast('err', 'Apply failed', r && (r.message || r.error));
  await loadNvidia(true);
}
async function nvRevert() {
  const r = await window.ff.nvidia.revertApplied();
  if (r && r.ok) toast('ok', 'NVIDIA reverted', r.message); else toast('err', 'Revert', r && (r.reason || r.message));
  await loadNvidia(true);
}
async function nvApplyCustom() {
  if (!state.admin) { toast('warn', 'Administrator required', 'Restart FrameForge as admin to apply NVIDIA settings.'); return; }
  if (!nvHasSnapshot()) { toast('warn', 'Create a restore point first', 'Take a one-click NVIDIA snapshot before applying.'); return; }
  const keys = Array.from(state.nvidia.sel);
  if (!keys.length) { toast('warn', 'Nothing selected', 'Tick the settings you want to apply.'); return; }
  toast('ok', 'Applying custom profile…', `${keys.length} setting(s)`);
  const r = await window.ff.nvidia.applyCustom(keys, state.nvidia.vrr);
  if (r && r.ok) toast('ok', 'Custom profile applied', (r.degraded ? 'Some VRR-only settings were skipped (no VRR confirmed). ' : '') + 'Relaunch your game to take effect.');
  else if (r && r.needsElevation) toast('warn', 'Administrator required');
  else toast('err', 'Apply failed', r && (r.message || r.error));
  await loadNvidia(true);
}
async function nvReverify() {
  if (!state.admin) { toast('warn', 'Administrator required', 'Reading your driver settings map needs admin. Restart as administrator.'); return; }
  toast('ok', 'Verifying against your driver…', 'Reading the NVIDIA settings map.');
  const csn = await window.ff.nvidia.createCsn();
  if (!csn || !csn.ok) { toast('err', 'Could not read driver map', (csn && csn.reason) || 'createCSN failed.'); return; }
  const hz = (state.sys && state.sys.display && (state.sys.display.maxHzAtCurrentRes || state.sys.display.currentHz)) || 240;
  const b = await window.ff.nvidia.buildCatalog(hz);
  if (b && b.ok) toast('ok', 'Catalog re-verified', `${b.resolved} settings resolved on driver ${b.driver}${(b.unresolved && b.unresolved.length) ? `, ${b.unresolved.length} unavailable` : ''}. Cap ${b.cap}.`);
  else toast('err', 'Re-verify failed', b && (b.reason || b.error));
  nvLoaded = false; await loadNvidia(true);
}
function nvMeasure(key) {
  const cat = state.nvidia.catalog;
  const label = key && cat && cat.settings[key] ? cat.settings[key].name : (state.nvidia.active ? `profile: ${state.nvidia.active}` : 'current NVIDIA settings');
  state.bench.context = label; state.bench.baseline = null; state.bench.after = null;
  switchView('benchmark');
  $('#benchAfter').disabled = true;
  renderBench();
}
/* =====================================================================
   WINDOWS HEALTH
   Read-only probes from engine/health.ps1. Every status the engine reports is
   rendered as itself — "needs-admin" is its own state with an elevate affordance
   and is never folded into "ok".
   ===================================================================== */
const health = { catalog: null, scan: null, scanning: false, loaded: false };
const HEALTH_GLYPH = {
  'system-files': GLYPH.settings, disk: GLYPH.storage, 'windows-update': GLYPH.update,
  network: GLYPH.net, store: GLYPH.store, search: GLYPH.search, printing: GLYPH.printer,
  stability: GLYPH.bug, 'disk-space': GLYPH.storage, boot: GLYPH.boot, audio: GLYPH.speed,
  activation: GLYPH.key, time: GLYPH.clock, apps: GLYPH.list,
};
const healthGlyph = (id) => HEALTH_GLYPH[id] || GLYPH.health;
// Order mirrors engine/health.ps1's Resolve-Status rank: critical > warning > unknown >
// needs-admin > ok. 'unknown' used to sit BELOW 'Healthy', so a category nobody could
// measure was filed under the good news; it ranks above both 'ok' and 'needs-admin'
// because needs-admin means "elevate me and I will know" while unknown means "this was
// not measured at all".
const HEALTH_GROUPS = [
  { status: 'critical', title: 'Critical', chip: 'crit' },
  { status: 'warning', title: 'Needs attention', chip: 'warn' },
  { status: 'unknown', title: 'Could not be determined', chip: 'unknown' },
  { status: 'needs-admin', title: 'Could not be fully checked', chip: 'admin' },
  { status: 'ok', title: 'Healthy', chip: 'good' },
];
const HEALTH_CHIP = { critical: ['crit', 'Critical'], warning: ['warn', 'Needs attention'], 'needs-admin': ['admin', 'Needs administrator'], ok: ['good', 'Healthy'], unknown: ['unknown', 'Could not be determined'] };
const healthCheckById = (id) => (health.catalog || []).find((c) => c.id === id) || null;
// Repair categories that have no health-checks.json entry still need a real heading.
const CATEGORY_NAMES = { time: 'Clock and time sync', apps: 'Apps and package manager', shell: 'Shell and Explorer', drivers: 'Devices and drivers' };
const categoryName = (id) => {
  const c = healthCheckById(id);
  if (c) return c.name;
  if (CATEGORY_NAMES[id]) return CATEGORY_NAMES[id];
  return String(id || '').replace(/-/g, ' ').replace(/^./, (m) => m.toUpperCase());
};

async function loadHealth(force) {
  if (health.loaded && !force) { renderHealth(); return; }
  health.loaded = true;
  if (!health.catalog) {
    try {
      const cat = await window.ff.health.catalog();
      health.catalog = (cat && cat.checks) || [];
    } catch (e) { health.catalog = []; }
  }
  renderHealth();
  if (!repairs.list) loadRepair();          // fix ids are resolved against the live list
  if (!health.scan && !health.scanning) runHealthScan(false);
}

async function runHealthScan(deep) {
  if (health.scanning) return;
  health.scanning = true; renderHealth();
  // try/catch/finally: an IPC rejection used to leave scanning=true forever, so the guard
  // above turned every later attempt into a no-op and the page said "Running read-only
  // probes…" permanently, with no error and no way back short of restarting the app.
  try {
    health.scan = await window.ff.health.scan(!!deep);
  } catch (e) {
    health.scan = { ok: false, error: String((e && e.message) || e) };
  } finally {
    health.scanning = false;
    renderHealth();
  }
  const res = health.scan;
  const t = (res && res.totals) || {};
  // Unmeasured categories count toward the badge. A scan in which every probe crashed
  // used to show no badge at all — indistinguishable from a clean machine.
  const bad = (t.critical || 0) + (t.warning || 0) + (t.unknown || 0);
  const badge = $('#healthBadge'); if (badge) badge.textContent = bad ? String(bad) : '';
  if (res && res.ok === false) {
    toast(res.timedOut ? 'warn' : 'err',
      res.timedOut ? 'Health scan did not finish' : 'Health scan failed',
      engineErrorText(res));
  }
}

function evidenceBlock(f) {
  if (f.evidence == null) return '';
  let text;
  try { text = typeof f.evidence === 'string' ? f.evidence : JSON.stringify(f.evidence, null, 2); }
  catch (e) { return ''; }
  if (!text || text === '{}' || text === '[]' || text === 'null') return '';
  if (text.length > 1600) text = text.slice(0, 1600) + '\n…';
  return `<div class="mono">${esc(text)}</div>`;
}

/* Finding severities, matching engine/health.ps1's vocabulary exactly:
   info | unknown | warning | critical.

   'unknown' is a FIRST-CLASS severity, not a flavour of 'info'. It means the engine could
   not read that signal at all, and the whole point of it existing is that a hole in the
   measurement must not look like a tidy note (docs/GAUNTLET.md rule 2). It therefore has
   its own glyph, its own colour and its own words. The previous ternary chain sent it —
   and any severity the engine may add later — to the info dot, which said the opposite.
   Anything unrecognised now falls to 'unknown' rather than to 'info': the safe default is
   "we do not know what this is", never "this is fine". */
const SEV = {
  critical: { glyph: GLYPH.dismiss, label: 'critical' },
  warning: { glyph: GLYPH.warning, label: 'warning' },
  unknown: { glyph: GLYPH.unknown, label: 'could not be determined' },
  info: { glyph: GLYPH.info, label: 'information' },
};
function sevOf(severity) {
  const k = String(severity == null ? '' : severity);
  return Object.prototype.hasOwnProperty.call(SEV, k) ? SEV[k] : SEV.unknown;
}
function sevClass(severity) {
  const k = String(severity == null ? '' : severity);
  return Object.prototype.hasOwnProperty.call(SEV, k) ? k : 'unknown';
}

function findingRow(f) {
  // The severity mark is a glyph whose only differentiator is colour — it collapses into
  // one identical mark under forced-colors, and says nothing to a screen reader. The
  // severity word travels with it.
  const sv = sevOf(f.severity);
  return `<div class="sexp-row">
    <span class="sev ${esc(sevClass(f.severity))}"><span aria-hidden="true">${sv.glyph}</span><span class="sr-only">${esc(sv.label)}</span></span>
    <div class="scard-body">
      <div class="scard-title">${esc(f.detail)}</div>
      <div class="scard-desc">${esc(sv.label)} <span class="sep-dot">·</span> ${esc(f.id)}</div>
      ${evidenceBlock(f)}
    </div>
  </div>`;
}

// `repair.ps1 -Action selftest` enforces that every fixesAvailable id resolves, but that is a
// build-time check. Resolving against the live list keeps a stale catalog from rendering a
// button that maps to no repair, and gives each fix its real detection state.
function resolvedFixes(check) {
  const live = repairs.list || [];
  const byId = (id) => live.find((r) => r.id === id);
  const direct = (check && check.fixesAvailable || []).map(byId).filter(Boolean);
  if (direct.length) return direct;
  return live.filter((r) => r.category === (check && check.id));
}

function renderHealth() {
  const scan = health.scan;
  const scanning = health.scanning;
  const totals = (scan && scan.totals) || null;
  const scanBtn = scanning
    ? `<span class="working">Running read-only probes…</span>`
    : `<button class="fbtn" data-act="health-scan" data-deep="1">Deep scan</button>
       <button class="fbtn accent" data-act="health-scan">${scan ? 'Scan again' : 'Scan now'}</button>`;
  let top = `<div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.health}</span>
    <div class="scard-body">
      <div class="scard-title">Read-only health scan</div>
      <div class="scard-desc">Runs every check and changes nothing. Deep adds DISM ScanHealth, SFC verify-only, and online chkdsk.</div>
    </div>
    <div class="scard-control">${scanBtn}</div>
  </div>`;
  if (totals) {
    const when = scan.scannedAt ? String(scan.scannedAt).replace('T', ' ') : '';
    top += `<div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.list}</span>
      <div class="scard-body">
        <div class="scard-title">${(scan.categories || []).length} categories checked${scan.deep ? ' (deep scan)' : ''}</div>
        <div class="scard-desc">${totals.ok} healthy <span class="sep-dot">·</span> ${totals.warning} need attention <span class="sep-dot">·</span> ${totals.critical} critical <span class="sep-dot">·</span> ${totals.needsAdmin} need administrator${totals.unknown ? ` <span class="sep-dot">·</span> ${totals.unknown} unknown` : ''}</div>
      </div>
      <div class="scard-control"><span class="list-caption">${esc(when)}${scan.durationMs ? ` <span class="sep-dot">·</span> ${(scan.durationMs / 1000).toFixed(1)}s` : ''}</span></div>
    </div>`;
  }
  if (scan && !scan.isAdmin) {
    top += `<div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.admin}</span>
      <div class="scard-body">
        <div class="scard-title">Some checks need administrator rights</div>
        <div class="scard-desc">The component store, NTFS dirty bit, index size, and dump inventory cannot be read. Those report "needs administrator", never healthy.</div>
      </div>
      <div class="scard-control"><button class="fbtn" data-act="health-elevate">Restart as administrator</button></div>
    </div>`;
  }
  $('#healthTop').innerHTML = top;

  const body = $('#healthBody');
  if (!scan) {
    body.innerHTML = scanning
      ? `<div class="section-head"><h2>Results</h2></div><div class="empty">Scanning. This takes about ten seconds; a deep scan takes several minutes.</div>`
      : `<div class="section-head"><h2>Results</h2></div><div class="empty">No scan yet. Select <b>Scan now</b> to run the read-only checks.</div>`;
    return;
  }
  if (scan.ok === false) {
    // A scan that was stopped on the clock is "could not determine", not a hard failure —
    // and it is never a clean result. Both say plainly that nothing was measured.
    const timed = !!scan.timedOut;
    const why = engineErrorText(scan);
    body.innerHTML = `<div class="section-head"><h2>Results</h2></div>` +
      infobarHtml(timed ? 'caution' : 'critical', timed ? GLYPH.warning : GLYPH.error,
        timed ? 'Could not determine — the scan did not finish' : 'The scan could not run',
        /statement about your PC/i.test(why) ? why : `${why} Nothing here is a statement about your PC.`,
        `<button class="fbtn" data-act="health-scan">Retry</button>${diagButton(why)}`);
    return;
  }
  const cats = scan.categories || [];
  const bad = cats.filter((c) => c.status === 'critical' || c.status === 'warning');
  const unknownN = cats.filter((c) => c.status === 'unknown').length || ((scan.totals && scan.totals.unknown) || 0);
  const needsAdminN = (scan.totals && scan.totals.needsAdmin) || cats.filter((c) => c.status === 'needs-admin').length;
  let html = '';
  if (!bad.length && unknownN) {
    // The headline verdict must not be derived from probes that crashed. "Nothing is
    // broken here" is only honest when every category actually reported.
    html += `<div class="section-head"><h2>Verdict</h2></div>` +
      infobarHtml('caution', GLYPH.warning, 'Some checks could not run',
        `No category reported a warning or a critical fault, but ${unknownN} could not be measured at all${needsAdminN ? `, and ${needsAdminN} could not be fully checked without administrator rights` : ''}. Those categories are not reported as healthy — nothing is known about them.`, '');
  } else if (!bad.length) {
    html += `<div class="section-head"><h2>Verdict</h2></div>` +
      infobarHtml('success', GLYPH.check, 'Nothing is broken here',
        `No category reported a warning or a critical fault.${needsAdminN ? ` ${needsAdminN} could not be fully checked without administrator rights, and are listed as such rather than as healthy.` : ''}`, '');
  }
  const grouped = new Set();
  for (const g of HEALTH_GROUPS) {
    const inGroup = cats.filter((c) => c.status === g.status);
    if (!inGroup.length) continue;
    inGroup.forEach((c) => grouped.add(c));
    html += `<div class="section-head"><h2>${g.title}</h2></div>`;
    html += `<div class="card-list">${inGroup.map((c) => healthCard(c, g)).join('')}</div>`;
  }
  // A category whose status matches no known group is shown, not dropped: a silently
  // missing category is indistinguishable from a healthy one.
  const ungrouped = cats.filter((c) => !grouped.has(c));
  if (ungrouped.length) {
    html += `<div class="section-head"><h2>Unreported status</h2></div>`;
    html += `<div class="card-list">${ungrouped.map((c) => healthCard(c, { status: c.status, title: 'Unreported status', chip: 'idle' })).join('')}</div>`;
  }
  body.innerHTML = html;
  wireExpanders(body);
}

function healthCard(c, g) {
  const check = healthCheckById(c.category);
  const name = categoryName(c.category);
  const chip = HEALTH_CHIP[c.status] || ['idle', c.status];
  const findings = (c.findings || []);
  let rows = findings.map(findingRow).join('');
  if (!findings.length) {
    rows += `<div class="sexp-row"><div class="scard-body"><div class="scard-title">No findings</div><div class="scard-desc">Every signal in this category came back clean.</div></div></div>`;
  }
  if (check && (check.whatWeCheck || []).length) {
    rows += `<div class="sexp-row stack">
      <div class="row-label">What this check reads</div>
      <ul class="row-list plain">${check.whatWeCheck.map((w) => `<li>${esc(w)}</li>`).join('')}</ul>
    </div>`;
  }
  if (c.status === 'needs-admin') {
    rows += `<div class="sexp-row">
      <div class="scard-body">
        <div class="scard-title">This category needs administrator rights</div>
        <div class="scard-desc">FrameForge will not guess at the missing signals, so this is reported as unchecked rather than healthy.</div>
      </div>
      <div class="scard-control"><button class="fbtn" data-act="health-elevate">Restart as administrator</button></div>
    </div>`;
  }
  if (c.status === 'unknown') {
    rows += `<div class="sexp-row stack">
      <div class="row-label">This category was not measured</div>
      <div class="row-note">The probe did not complete, so nothing is known about this part of Windows. It is deliberately not reported as healthy.</div>
    </div>`;
  }
  const fixes = resolvedFixes(check || { id: c.category });
  if (fixes.length && c.status !== 'ok') {
    rows += fixes.map((r) => `<div class="sexp-row">
      <div class="scard-body">
        <div class="scard-title">${esc(r.name)}</div>
        <div class="scard-desc">${esc(r.summary || '')}</div>
      </div>
      <div class="scard-control">
        ${repairStateChip(r)}
        <button class="fbtn" data-act="health-fix" data-id="${esc(r.id)}">Open in Repair</button>
      </div>
    </div>`).join('');
  }
  if ((check && (check.sources || []).length)) {
    rows += `<div class="sexp-row stack">
      <div class="row-label">Sources</div>
      <div class="src-list" style="display:flex;flex-direction:column;gap:2px">${check.sources.map((u) => `<a data-act="src" data-url="${esc(u)}">${esc(u)}</a>`).join('')}</div>
    </div>`;
  }
  return `<div class="sexpander${openRows.health.has(c.category) ? ' open' : ''}" data-health="${esc(c.category)}">
    <div class="scard sexp-head" data-act="expander">
      <span class="scard-icon" aria-hidden="true">${healthGlyph(c.category)}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(name)}</div>
        <div class="scard-desc">${esc(c.summary || '')}</div>
      </div>
      <div class="scard-control">${statusChip(chip[0], chip[1])}</div>
      <span class="chev">${GLYPH.chevronDown}</span>
    </div>
    <div class="sexp-content">${rows}</div>
  </div>`;
}

/* =====================================================================
   REPAIR
   The repair ladder from engine/repair.ps1: detect → preflight → (preview) → run
   → verify with the same probe, plus the ledger and its undo path.
   ===================================================================== */
const repairs = {
  list: null, catalog: null, ledger: [], loaded: false, loading: false,
  preflight: {}, results: {}, busy: null, error: null,
  // Repair ids the user has explicitly opted out of a System Restore checkpoint for.
  noRestorePoint: new Set(),
};
const repairById = (id) => (repairs.list || []).find((r) => r.id === id) || null;
const repairCatalogById = (id) => ((repairs.catalog || []).find((r) => r.id === id)) || null;
const REPAIR_STATE_CHIP = {
  problem: ['warn', 'Problem detected'],
  healthy: ['good', 'Nothing broken'],
  indeterminate: ['admin', 'Could not check'],
};
function repairStateChip(r) {
  const st = (r && r.detection && r.detection.state) || 'indeterminate';
  const c = REPAIR_STATE_CHIP[st] || ['idle', st];
  return statusChip(c[0], c[1]);
}

async function loadRepair(force) {
  if (repairs.loading) return;
  if (repairs.loaded && !force) { renderRepair(); return; }
  repairs.loading = true; repairs.loaded = true;
  // try/catch/finally: without it, a rejected IPC call left loading=true forever, the
  // guard above made "Re-detect" inert, and the page said "Detecting…" until restart.
  try {
    await loadImageCatalog();
    if (!health.catalog) { const hc = await window.ff.health.catalog(); health.catalog = (hc && hc.checks) || []; }
    renderRepair();
    const [list, cat, led] = await Promise.all([
      window.ff.repair.list(), window.ff.repair.catalog(), window.ff.repair.ledger(),
    ]);
    // An empty repairs array is a real answer shape but not a real answer: keep it as []
    // so renderRepair can say "the engine returned no repairs" instead of showing a
    // green chip over a void.
    repairs.list = Array.isArray(list && list.repairs) ? list.repairs : null;
    repairs.error = isEngineError(list) ? engineErrorText(list) : null;
    repairs.timedOut = !!(list && list.timedOut);
    repairs.catalog = (cat && cat.repairs) || [];
    repairs.ledger = (led && led.entries) || [];
  } catch (e) {
    repairs.error = String((e && e.message) || e);
  } finally {
    repairs.loading = false;
    renderRepair();
  }
  if ($('#view-health').classList.contains('active')) renderHealth();
}

async function ensureRepairPreflight(id) {
  if (repairs.preflight[id] || repairs.busy) return;
  repairs.preflight[id] = { pending: true };
  const el = $(`.sexpander[data-repair="${CSS.escape(id)}"] .repair-detail`);
  if (el) el.innerHTML = `<span class="working">Running preflight (read-only)…</span>`;
  const res = await window.ff.repair.preflight(id);
  repairs.preflight[id] = res;
  renderRepair();
  const re = $(`.sexpander[data-repair="${CSS.escape(id)}"]`); if (re) re.classList.add('open');
}

async function repairAction(id, opts) {
  const r = repairById(id); if (!r) return;
  const o = opts || {};
  if (!o.dryRun && r.requiresAdmin && !state.admin) {
    toast('warn', 'Administrator required', `“${r.name}” changes system state and needs elevation.`);
    return;
  }
  repairs.busy = id; renderRepair();
  // The opt-out is only ever passed when the user ticked it on this repair's card.
  if (repairs.noRestorePoint.has(id)) o.noRestorePoint = true;
  let res;
  try { res = await window.ff.repair.run(id, o); }
  catch (e) { res = { ok: false, error: String((e && e.message) || e) }; }
  repairs.busy = null;
  repairs.results[id] = res;
  if (res && res.refused) toast('ok', 'Nothing to repair', res.message || 'Detection reports this subsystem is healthy.');
  else if (res && res.timedOut) {
    // An interrupted mutation is an unknown, in-progress state — not an engine error.
    toast('warn', 'The repair was stopped on the clock',
      'It exceeded its time budget and FrameForge stopped it and everything it had started. The change ledger shows which step was in progress — check that before running this again.');
  } else if (res && res.ok === false) toast('err', 'Repair failed', engineErrorText(res) || r.name);
  else if (o.dryRun) toast('ok', 'Preview only', `Nothing was executed. ${(res.steps || []).length} step(s) listed.`);
  else if (res && res.result) {
    // stepsCompleted means every step ran; addressed additionally means the probe re-run agrees
    // the problem is gone. Only the latter earns "fixed" in the headline.
    const rr = res.result;
    const ran = rr.stepsCompleted !== undefined ? rr.stepsCompleted : rr.fixed;
    const title = rr.addressed ? 'Repaired and verified'
      : ran ? 'Ran, but the problem is still detected'
      : 'Repair did not complete';
    toast(rr.addressed ? 'ok' : 'warn', title, rr.detail);
  }
  if (!o.dryRun && res && !res.refused && res.ok !== false) { repairs.preflight = {}; await loadRepair(true); }
  else renderRepair();
}

async function repairUndo(id) {
  const r = repairById(id);
  repairs.busy = id; renderRepair();
  const res = await window.ff.repair.undo(id, {});
  repairs.busy = null;
  if (res && res.noop) toast('warn', 'Nothing to undo', res.message);
  else if (res && res.success) toast('ok', 'Undone', `${(r && r.name) || id} restored from the captured state.`);
  else toast('err', 'Undo failed', (res && (res.message || res.error)) || id);
  repairs.preflight = {}; await loadRepair(true);
}

function openRepairFor(id) {
  switchView('repair');
  setTimeout(() => {
    const el = $(`.sexpander[data-repair="${CSS.escape(id)}"]`);
    if (el) {
      el.classList.add('open');
      const chev = el.querySelector(':scope > .sexp-head > .chev');
      if (chev) chev.setAttribute('aria-expanded', 'true');
      el.scrollIntoView({ block: 'center', behavior: reducedMotion() ? 'auto' : 'smooth' });
      ensureRepairPreflight(id);
    }
  }, 60);
}

function commandBlock(groups) {
  const lines = [];
  for (const g of (groups || [])) for (const c of (g.commands || [])) lines.push(c);
  return lines.length ? `<div class="mono">${esc(lines.join('\n'))}</div>` : '';
}

/* ---------- the enforced System Restore checkpoint ----------
   Five repairs carry restorePoint:"enforced": a checkpoint is created as their FIRST
   step, and if it cannot be created the repair aborts. System Protection is OFF by
   default on clean Windows 11 and on most OEM images, and is commonly disabled outright
   by policy on managed fleets or collaterally by the "debloat" scripts this product's own
   audience runs — so on a large share of machines those repairs abort at step 1. The
   engine documents -NoRestorePoint as the opt-out; it was never plumbed through the GUI,
   which meant a user with a set NTFS dirty bit could not run chkdsk-full-repair at all.

   The checkbox is enabled only while a checkpoint is NOT known to be creatable, which is
   also the honest default before the engine reports on it: "we could not confirm" is not
   "we confirmed it works". */
function restorePointRow(r, pf) {
  const rp = pf && pf.restorePoint;
  if (!rp || !rp.wouldCreate) return '';
  const can = rp.canCreateCheckpoint;                 // true | false | 'unknown' | undefined
  const optedOut = repairs.noRestorePoint.has(r.id);
  const chip = can === true ? statusChip('good', 'A checkpoint can be created')
    : can === false ? statusChip('crit', 'A checkpoint cannot be created')
      : statusChip('idle', 'Checkpoint availability unknown');
  const why = rp.canCreateCheckpointReason
    || (can === false ? 'System Protection is off or blocked for this drive, so this repair will abort at step 1 unless you run it without a checkpoint.'
      : can === true ? ''
        : 'FrameForge could not confirm whether a System Restore checkpoint can be created on this PC. If it cannot, this repair aborts at its first step.');
  return `<div class="sexp-row stack">
    <div class="row-label">System Restore checkpoint</div>
    <div class="row-note">${esc(rp.detail || '')}</div>
    ${why ? `<div class="row-note">${esc(why)}</div>` : ''}
    <div style="margin-top:8px;display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      ${chip}
      <label class="consent-check" style="padding:0">
        <input type="checkbox" class="fcheck" data-act="repair-norp" data-id="${esc(r.id)}" ${optedOut ? 'checked' : ''} ${can === true ? 'disabled' : ''}>
        <span>Run without a restore point${can === true ? ' (not needed: a checkpoint can be created here)' : ''}</span>
      </label>
    </div>
    ${optedOut ? '<div class="row-note">This run will pass -NoRestorePoint. Windows will not take a checkpoint first, so System Restore will not be able to roll this back.</div>' : ''}
  </div>`;
}

function repairCard(r) {
  const cat = repairCatalogById(r.id) || {};
  const pf = repairs.preflight[r.id];
  const res = repairs.results[r.id];
  const busy = repairs.busy === r.id;
  const needsAdmin = r.requiresAdmin && !state.admin;
  const meta = [
    `${esc(r.tier)} tier`,
    r.reversible ? 'reversible from captured state' : 'not reversible',
    r.requiresAdmin ? 'needs administrator' : 'no elevation needed',
    r.requiresReboot ? 'needs a reboot' : 'no reboot',
  ].join(' · ');

  const steps = (pf && pf.whatWouldRun) || (cat.whatItRuns ? [{ name: r.id, commands: cat.whatItRuns }] : []);
  let rows = `<div class="sexp-row stack">
    <div class="row-label">Detection said</div>
    <div class="row-note">${esc((r.detection && r.detection.detail) || 'No detection detail.')}</div>
    <div class="row-note">${esc(meta)}</div>
  </div>`;
  rows += restorePointRow(r, pf);
  rows += `<div class="sexp-row stack">
    <div class="row-label">Exactly what runs</div>
    <div class="repair-detail">${busy && !res ? '<span class="working">Working…</span>' : commandBlock(steps) || '<span class="row-note">No commands recorded for this repair.</span>'}</div>
    ${pf && pf.currentState ? `<div class="row-label" style="margin-top:8px">Current state captured before the run</div><div class="mono">${esc(JSON.stringify(pf.currentState, null, 2))}</div>` : ''}
  </div>`;
  if (cat.details) rows += `<div class="sexp-row stack"><div class="row-label">What this does</div><div class="row-note">${esc(cat.details)}</div></div>`;
  const risks = (pf && pf.risks) || cat.risks;
  if (risks) rows += `<div class="sexp-row stack"><div class="row-label">Risks</div><div class="row-note">${esc(risks)}</div></div>`;
  const verifyAfter = (pf && pf.verifyAfter) || cat.verifyAfter;
  if (verifyAfter) rows += `<div class="sexp-row stack"><div class="row-label">How the result is verified</div><div class="row-note">${esc(verifyAfter)}</div></div>`;
  if (res) rows += repairResultRow(r, res);
  if ((cat.sources || []).length) {
    rows += `<div class="sexp-row stack"><div class="row-label">Sources</div>
      <div class="src-list" style="display:flex;flex-direction:column;gap:2px">${cat.sources.map((u) => /^https?:/i.test(u) ? `<a data-act="src" data-url="${esc(u)}">${esc(u)}</a>` : `<span class="row-note">${esc(u)}</span>`).join('')}</div></div>`;
  }

  return `<div class="sexpander${openRows.repair.has(r.id) ? ' open' : ''}" data-repair="${esc(r.id)}">
    <div class="scard sexp-head" data-act="expander">
      <span class="scard-icon" aria-hidden="true">${healthGlyph(r.category)}</span>
      <div class="scard-body">
        <div class="scard-title">${esc(r.name)}${r.tier === 'aggressive' ? ' <span class="tag-recommended" style="color:var(--caution)">· Aggressive</span>' : ''}</div>
        <div class="scard-desc">${esc(r.summary || '')}</div>
      </div>
      <div class="scard-control">
        ${repairStateChip(r)}
        <button class="fbtn" data-act="repair-preview" data-id="${esc(r.id)}" ${busy ? 'disabled' : ''}>Preview</button>
        <button class="fbtn ${r.detection && r.detection.state === 'problem' ? 'accent' : ''}" data-act="repair-run" data-id="${esc(r.id)}" ${busy || needsAdmin ? 'disabled' : ''} title="${needsAdmin ? 'Requires administrator' : ''}">${busy ? 'Working…' : needsAdmin ? 'Needs admin' : 'Repair'}</button>
      </div>
      <span class="chev">${GLYPH.chevronDown}</span>
    </div>
    <div class="sexp-content">${rows}</div>
  </div>`;
}

function repairResultRow(r, res) {
  if (res.refused) {
    return `<div class="sexp-row stack">
      <div class="row-label">Result</div>
      <div class="row-note">${esc(res.message || 'Detection reports this subsystem is healthy, so nothing was run.')}</div>
      <div style="margin-top:8px"><button class="fbtn" data-act="repair-force" data-id="${esc(r.id)}">Run anyway</button></div>
    </div>`;
  }
  if (res.dryRun) {
    return `<div class="sexp-row stack">
      <div class="row-label">Preview result — nothing was executed</div>
      <div class="row-note">${esc(res.note || '')}</div>
      ${res.refusalNote ? `<div class="row-note">${esc(res.refusalNote)}</div>` : ''}
    </div>`;
  }
  if (res.timedOut) {
    return `<div class="sexp-row stack">
      <div class="row-label">Result — unknown</div>
      <div class="row-note">${esc(engineErrorText(res))}</div>
      <div class="row-note">This repair may have been part-way through a change when it was stopped. Check the change ledger below for the step that was in progress before running it again — do not simply re-run it.</div>
    </div>`;
  }
  if (res.ok === false) {
    return `<div class="sexp-row stack"><div class="row-label">Result</div><div class="row-note">${esc(res.message || engineErrorText(res))}</div></div>`;
  }
  const rr = res.result || {};
  const stepList = (res.steps || []).map((s) => `<li>${esc(s.name)}: ${esc(s.status || 'done')}${s.detail ? ` — ${esc(s.detail)}` : ''}</li>`).join('');
  return `<div class="sexp-row stack">
    <div class="row-label">Result${res.ranAt ? ` · ${esc(String(res.ranAt).replace('T', ' '))}` : ''}</div>
    <div class="row-note">${esc(rr.detail || '')}</div>
    ${stepList ? `<ul class="row-list ${(rr.stepsCompleted !== undefined ? rr.stepsCompleted : rr.fixed) ? 'yes' : 'no'}" style="margin-top:6px">${stepList}</ul>` : ''}
    ${res.requiresReboot ? '<div class="row-note">A reboot is required before this takes full effect.</div>' : ''}
  </div>`;
}

function renderRepair() {
  const list = repairs.list;
  const loading = repairs.loading;
  let top = `<div class="scard">
    <span class="scard-icon" aria-hidden="true">${GLYPH.repair}</span>
    <div class="scard-body">
      <div class="scard-title">Repair ladder</div>
      <div class="scard-desc">Detect first, name every command, then re-verify with the same probe. A repair refuses to run when nothing is broken.</div>
    </div>
    <div class="scard-control">${loading ? '<span class="working">Detecting…</span>' : `<button class="fbtn" data-act="repair-refresh">Re-detect</button>`}</div>
  </div>`;
  if (list && list.length) {
    // Buckets computed exhaustively. "report nothing broken" used to be
    // length - problems - indeterminate, so a repair with NO detection object at all, or
    // an unrecognised state string, was silently counted as healthy — and the green
    // "Nothing broken" chip appeared whenever problems === 0, even on a page where every
    // single card said "Could not check".
    const problems = list.filter((r) => r.detection && r.detection.state === 'problem').length;
    const healthy = list.filter((r) => r.detection && r.detection.state === 'healthy').length;
    const unknown = list.length - problems - healthy;
    top += `<div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.list}</span>
      <div class="scard-body">
        <div class="scard-title">${list.length} repairs available</div>
        <div class="scard-desc">${problems} match a detected problem <span class="sep-dot">·</span> ${healthy} report nothing broken <span class="sep-dot">·</span> ${unknown} could not be checked</div>
      </div>
      <div class="scard-control">${problems
      ? statusChip('warn', `${problems} to look at`)
      : unknown
        ? statusChip('admin', `${unknown} could not be checked`)
        : statusChip('good', 'Nothing broken')}</div>
    </div>`;
  }
  if (!state.admin) {
    top += `<div class="scard">
      <span class="scard-icon" aria-hidden="true">${GLYPH.admin}</span>
      <div class="scard-body">
        <div class="scard-title">Most repairs need administrator rights</div>
        <div class="scard-desc">Preview and preflight stay available without elevation; they are read-only.</div>
      </div>
      <div class="scard-control"><button class="fbtn" data-act="health-elevate">Restart as administrator</button></div>
    </div>`;
  }
  $('#repairTop').innerHTML = top;

  const body = $('#repairBody');
  if (repairs.error) {
    // A detection pass stopped on the clock is "could not determine", not a hard failure.
    body.innerHTML = `<div class="section-head"><h2>Repairs</h2></div>` +
      infobarHtml(repairs.timedOut ? 'caution' : 'critical', repairs.timedOut ? GLYPH.warning : GLYPH.error,
        repairs.timedOut ? 'Could not determine — detection did not finish' : 'The repair engine could not be reached',
        /statement about your PC/i.test(repairs.error) ? repairs.error : `${repairs.error} Nothing was checked, so nothing here is a statement about your PC.`,
        `<button class="fbtn" data-act="repair-refresh">Retry</button>${diagButton(repairs.error)}`);
  } else if (!list) {
    body.innerHTML = `<div class="section-head"><h2>Repairs</h2></div><div class="empty">${loading ? 'Detecting the state of each subsystem…' : 'No repair data.'}</div>`;
  } else if (!list.length) {
    // An empty array is not "your PC is fine": it means the catalog produced no repairs.
    body.innerHTML = `<div class="section-head"><h2>Repairs</h2></div>
      <div class="empty">The repair engine returned no repairs. This is not a statement about your PC — nothing was checked.</div>`;
  } else {
    const cats = [];
    for (const r of list) if (!cats.includes(r.category)) cats.push(r.category);
    cats.sort((a, b) => {
      const bad = (c) => list.some((r) => r.category === c && r.detection && r.detection.state === 'problem') ? 0 : 1;
      return bad(a) - bad(b);
    });
    body.innerHTML = cats.map((c) => {
      const items = list.filter((r) => r.category === c);
      // The per-category count used to hang off the header; each card already carries its
      // own detection chip, and the summary card above totals them.
      return `<div class="section-head"><h2>${esc(categoryName(c))}</h2></div>
        <div class="card-list">${items.map(repairCard).join('')}</div>`;
    }).join('');
  }
  wireExpanders(body);

  // ---- ledger ----
  const led = repairs.ledger || [];
  if (!led.length) {
    $('#repairLedger').innerHTML = `<div class="empty">Nothing has been changed yet. Every repair FrameForge runs is recorded here with the state it captured beforehand.</div>`;
  } else {
    $('#repairLedger').innerHTML = led.slice().reverse().map((e) => {
      const r = repairById(e.id);
      const undoable = e.reversible && !e.undone;
      const ctrl = e.undone
        ? statusChip('idle', `Undone ${String(e.undoneAt || '').replace('T', ' ')}`)
        : undoable
          ? `<button class="fbtn" data-act="repair-undo" data-id="${esc(e.id)}" ${repairs.busy ? 'disabled' : ''}>Undo</button>`
          : `<span class="list-caption">Not reversible</span>`;
      const rr = e.result || {};
      return `<div class="scard">
        <span class="scard-icon" aria-hidden="true">${healthGlyph((r && r.category) || '')}</span>
        <div class="scard-body">
          <div class="scard-title">${esc(e.name || e.id)}</div>
          <div class="scard-desc">${esc(String(e.ranAt || '').replace('T', ' '))} <span class="sep-dot">·</span> ${(e.steps || []).length} step(s)${e.forced ? ' <span class="sep-dot">·</span> forced past a healthy detection' : ''}${rr.detail ? ` <span class="sep-dot">·</span> ${esc(rr.detail)}` : ''}</div>
        </div>
        <div class="scard-control">${ctrl}</div>
      </div>`;
    }).join('');
  }

  renderImageRepair();
}

/* =====================================================================
   FRESH-IMAGE REPAIR
   A guided, consent-gated handoff to Microsoft's own setup.exe. The launch button
   stays disabled until the engine reports zero blockers AND the user has ticked
   both consent boxes. Nothing here ever passes -Confirm on its own.
   ===================================================================== */
const img = {
  catalog: null, detect: null, validate: null, preflight: null, launch: null, verify: null, acquire: null,
  isoPath: '', consentEula: false, consentBitlocker: false, busy: null, launched: null,
};

async function loadImageCatalog() {
  if (img.catalog) return img.catalog;
  try { img.catalog = await window.ff.image.catalog(); }
  catch (e) { img.catalog = { ok: false, error: String((e && e.message) || e) }; }
  return img.catalog;
}

async function imgRun(action, opts) {
  const o = Object.assign({}, opts || {});
  if (['validate', 'preflight', 'launch'].includes(action)) {
    if (!img.isoPath) { toast('warn', 'No media selected', 'Enter the full path to a Windows ISO first.'); return; }
    o.isoPath = img.isoPath;
  }
  img.busy = action; renderImageRepair();
  let res;
  try { res = await window.ff.image[action](o); }
  catch (e) { res = { ok: false, error: String((e && e.message) || e) }; }
  img.busy = null;
  const key = action === 'acquireUrl' ? 'acquire' : action;
  img[key] = res;
  // Reveal the card whose result just arrived.
  openRows.img.add({ detect: 'detect', acquire: 'media', validate: 'media', preflight: 'preflight', launch: 'consent', verify: 'verify' }[key] || key);
  if (res && res.ok === false && res.error) toast('warn', 'Fresh-image step returned an error', res.error);
  renderImageRepair();
}

/* Readiness requires POSITIVE evidence of zero blockers. `(l.blockers || []).length === 0`
   collapsed a MISSING blocker list into "no blockers", which enabled the single most
   destructive button in the product on the strength of a field that was never there. */
function launchBlockers(l) {
  return Array.isArray(l && l.blockers) ? l.blockers : null;   // null = not reported
}

// The only path that passes confirm:true — and only from this explicit click.
async function imgLaunchConfirmed() {
  const l = img.launch;
  if (!l || l.mode !== 'consent-contract') { toast('warn', 'Read the contract first', 'Load the consent contract before launching.'); return; }
  const bl = launchBlockers(l);
  if (bl === null) {
    toast('warn', 'Readiness could not be confirmed', 'The engine did not report a blocker list, so FrameForge cannot confirm this machine is ready. Nothing was started.');
    return;
  }
  if (bl.length) { toast('warn', 'Blocked', 'Every blocker must be cleared before setup can start.'); return; }
  if (!img.consentEula || !img.consentBitlocker) { toast('warn', 'Consent required', 'Both statements must be accepted before setup can start.'); return; }
  img.busy = 'launch'; renderImageRepair();
  const res = await window.ff.image.launch({ isoPath: img.isoPath, confirm: true });
  img.busy = null; img.launched = res;
  if (res && res.ok) toast('ok', 'Windows Setup started', 'Setup was launched with /noreboot; you choose when the first restart happens.');
  else toast('err', 'Setup did not start', (res && (res.error || res.errorCode)) || 'Unknown error.');
  renderImageRepair();
}

const railRow = (title, ok, desc) => `<div class="sexp-row">
  <div class="scard-body"><div class="scard-title">${esc(title)}</div><div class="scard-desc">${esc(desc)}</div></div>
  <div class="scard-control">${ok === true ? statusChip('good', 'Green') : ok === false ? statusChip('crit', 'Red') : statusChip('admin', 'Unknown')}</div>
</div>`;

function imgExpander(id, glyph, title, desc, control, rows, open) {
  const isOpen = openRows.img.has(id) || (open && !openRows.img.size);
  return `<div class="sexpander${isOpen ? ' open' : ''}" data-img="${esc(id)}">
    <div class="scard sexp-head" data-act="expander">
      <span class="scard-icon" aria-hidden="true">${glyph}</span>
      <div class="scard-body"><div class="scard-title">${esc(title)}</div><div class="scard-desc">${esc(desc)}</div></div>
      <div class="scard-control">${control}</div>
      <span class="chev">${GLYPH.chevronDown}</span>
    </div>
    <div class="sexp-content">${rows}</div>
  </div>`;
}

function renderImageRepair() {
  const host = $('#imageRepair'); if (!host) return;
  const cat = img.catalog;
  if (!cat) { host.innerHTML = `<div class="empty">Loading the fresh-image repair flow…</div>`; return; }
  if (isEngineError(cat)) {
    host.innerHTML = infobarHtml('critical', GLYPH.error, 'The fresh-image repair flow could not be loaded',
      `${engineErrorText(cat)} None of this flow's safety rails were read, so nothing here can be started.`,
      diagButton(engineErrorText(cat)));
    return;
  }
  const busy = img.busy;
  const cards = [];

  // 1 — identity + rails
  const d = img.detect;
  const dRows = !d ? `<div class="sexp-row"><div class="scard-body"><div class="scard-desc">Not checked yet.</div></div></div>` : (() => {
    const o = d.os || {}, m = d.mediaMustMatch || {}, ra = d.rails || {};
    let r = `<div class="sexp-row stack">
      <div class="row-label">This installation</div>
      <div class="row-note">${esc(o.productName || '')} ${esc(o.editionId || '')} <span class="sep-dot">·</span> ${esc(o.displayVersion || '')} <span class="sep-dot">·</span> build ${esc(o.buildString || o.currentBuild || '')} <span class="sep-dot">·</span> ${esc((o.language && o.language.tag) || '')} <span class="sep-dot">·</span> ${esc(o.architecture || '')}</div>
      <div class="row-label" style="margin-top:8px">The media must match</div>
      <ul class="row-list plain"><li>Edition: ${esc(m.edition || '')}</li><li>Language: ${esc(m.language || '')}</li><li>Build: ${esc(m.build || '')}</li><li>Architecture: ${esc(m.arch || '')}</li></ul>
      <div class="row-note" style="margin-top:6px">${esc(m.rule || '')}</div>
    </div>`;
    // Tri-state, like its three neighbours. `ra.diskOk === true` turned an ABSENT
    // diskOk into a hard red "Red" chip described as "undefined GB free on undefined" —
    // a measured failure reported for a rail that was never measured.
    const diskOk = ra.diskOk === true ? true : ra.diskOk === false ? false : null;
    const diskDesc = (ra.freeSystemDriveGB == null || ra.systemDrive == null)
      ? 'Free space could not be read on this machine.'
      : `${ra.freeSystemDriveGB} GB free on ${ra.systemDrive}${ra.minRequiredGB != null ? `; ${ra.minRequiredGB} GB required.` : '.'}`;
    r += railRow('Free disk space', diskOk, diskDesc);
    r += railRow('AC power', ra.power ? !!ra.power.onAc : null, (ra.power && (ra.power.note || `Line status: ${ra.power.lineStatus}`)) || '');
    r += railRow('BitLocker', ra.bitlockerKnown ? !ra.bitlockerBlocking : null, (ra.bitlocker && ra.bitlocker.note) || `Status: ${(ra.bitlocker && ra.bitlocker.status) || 'unknown'}`);
    r += railRow('No pending reboot', ra.pendingReboot ? !ra.pendingReboot.any : null, ra.pendingReboot && ra.pendingReboot.any ? 'Restart first — setup fails with 0xC1900107 while a servicing reboot is pending.' : 'No servicing reboot is pending.');
    return r;
  })();
  cards.push(imgExpander('detect', GLYPH.pc, 'Read this machine\u2019s identity',
    d ? `${(d.os && d.os.editionId) || ''} · ${(d.os && d.os.language && d.os.language.tag) || ''} · build ${(d.os && d.os.buildString) || ''}` : 'Edition, language, build, and architecture decide which ISO can repair this PC. Read-only.',
    busy === 'detect' ? '<span class="working">Reading…</span>' : `<button class="fbtn" data-act="img-detect">${d ? 'Re-check' : 'Check this PC'}</button>`,
    dRows, !!d));

  // 2 — media
  const ladder = (cat.acquisitionLadder || []).filter((l) => l.rank !== undefined);
  let mediaRows = `<div class="sexp-row stack">
    <div class="row-label">Where the ISO comes from</div>
    ${ladder.map((l) => `<div class="row-note"><b style="color:var(--text-primary)">${esc(l.name)}</b> — ${esc(l.nature)}${l.honestCaveat ? ` <i>${esc(l.honestCaveat)}</i>` : ''}</div>`).join('')}
  </div>`;
  mediaRows += `<div class="sexp-row">
    <div class="scard-body">
      <div class="scard-title">Ask Microsoft for a direct download link</div>
      <div class="scard-desc">Queries Microsoft's own download API through the official Fido script, records its SHA-256, and downloads nothing.</div>
      ${img.acquire ? `<div class="row-note" style="margin-top:6px">${esc(img.acquire.ok ? (img.acquire.url || 'A download URL was returned.') : `${img.acquire.reason || img.acquire.error || 'No URL returned.'} Falling back to: ${img.acquire.fallback || 'manual'}.`)}</div>` : ''}
    </div>
    <div class="scard-control">${busy === 'acquireUrl' ? '<span class="working">Asking…</span>' : '<button class="fbtn" data-act="img-acquire">Try it</button>'}</div>
  </div>`;
  mediaRows += `<div class="sexp-row">
    <div class="scard-body">
      <div class="scard-title">Download it yourself from Microsoft</div>
      <div class="scard-desc">Pick the multi-edition ISO for x64 devices in the exact language above.</div>
    </div>
    <div class="scard-control"><button class="fbtn" data-act="src" data-url="https://www.microsoft.com/software-download/windows11">Open microsoft.com</button></div>
  </div>`;
  const v = img.validate;
  mediaRows += `<div class="sexp-row stack">
    <div class="row-label">Point FrameForge at the ISO</div>
    <label class="field-label" style="max-width:520px">Full path to the ISO file
      <input class="ftext" type="text" id="imgIsoPath" spellcheck="false" autocomplete="off" placeholder="D:\\ISO\\Win11_25H2_English_x64.iso" value="${esc(img.isoPath)}">
    </label>
    <div style="margin-top:10px;display:flex;gap:8px;align-items:center">
      ${busy === 'validate' ? '<span class="working">Mounting and reading the image…</span>' : `<button class="fbtn" data-act="img-validate">Check this media</button>`}
    </div>
    ${v ? `<div class="row-note" style="margin-top:8px">${v.ok && v.verdict
      ? (v.verdict.compatible ? 'This media can repair this PC.' : `This media cannot repair this PC: ${esc((v.verdict.reasons || []).join(' '))}`)
      : esc(v.error || 'The media could not be read.')}</div>` : ''}
  </div>`;
  cards.push(imgExpander('media', GLYPH.disc, 'Get matching install media',
    img.isoPath ? esc(img.isoPath) : 'Three ways, most automatic first. Every path ends at an official Microsoft ISO.',
    v && v.ok && v.verdict ? (v.verdict.compatible ? statusChip('good', 'Compatible') : statusChip('crit', 'Not compatible')) : statusChip('idle', 'Not checked'),
    mediaRows, false));

  // 3 — the lighter rung, honestly presented as "try this before reinstalling"
  const lighter = (cat.steps || []).find((s) => s.id === 'lighter-rung');
  if (lighter) {
    cards.push(imgExpander('lighter', GLYPH.settings, 'Try the lighter repair first', 'Rebuild the component store from the same ISO. No reboot, apps untouched.',
      statusChip('idle', 'Recommended first'),
      `<div class="sexp-row stack"><div class="row-note">${esc(lighter.copy)}</div>
        <div class="row-note" style="margin-top:6px">In FrameForge this is the <b style="color:var(--text-primary)">Repair the component store</b> entry in the repair ladder above; give it the ISO as its source and it runs DISM /RestoreHealth /Source /LimitAccess, then SFC.</div></div>`, false));
  }

  // 4 — preflight
  const pf = img.preflight;
  let pfRows = `<div class="sexp-row stack"><div class="row-note">${esc(((cat.steps || []).find((s) => s.id === 'preflight') || {}).copy || '')}</div></div>`;
  if (pf) {
    if (pf.ok === false) pfRows += `<div class="sexp-row stack"><div class="row-label">Result</div><div class="row-note">${esc(pf.error || pf.errorCode || 'Preflight could not run.')}</div></div>`;
    else {
      const reasons = (pf.railCheck && pf.railCheck.reasons) || [];
      pfRows += `<div class="sexp-row stack">
        <div class="row-label">Result</div>
        <div class="row-note">${pf.readyToLaunch ? 'Every rail is green and the media matches this PC.' : 'Not ready to launch yet.'}${pf.dryRun ? ' The compatibility scan was skipped (dry run).' : ''}</div>
        ${reasons.length ? `<ul class="blocker-list">${reasons.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>` : ''}
        ${pf.compatScan ? `<div class="row-note" style="margin-top:6px">${esc(pf.compatScan.note || pf.compatScan.skippedBecause || pf.compatScan.error || (pf.compatScan.result && pf.compatScan.result.verdict) || '')}</div>` : ''}
      </div>`;
    }
  }
  cards.push(imgExpander('preflight', GLYPH.check, 'Pre-flight check', 'Re-validates the media, checks every safety rail, then asks Windows Setup to run its own compatibility scan.',
    busy === 'preflight' ? '<span class="working">Checking…</span>'
      : `<button class="fbtn" data-act="img-preflight" data-dry="1">Dry run</button><button class="fbtn" data-act="img-preflight">Run pre-flight</button>`,
    pfRows, !!pf));

  // 5 — the consent gate
  cards.push(consentCard());

  // 6 — verify
  const vf = img.verify;
  cards.push(imgExpander('verify', GLYPH.list, 'Prove it worked',
    'Compares the build against the record kept at launch and re-runs the same read-only probes.',
    busy === 'verify' ? '<span class="working">Checking…</span>' : '<button class="fbtn" data-act="img-verify">Check the result</button>',
    vf ? `<div class="sexp-row stack"><div class="row-label">${esc(vf.verdict || 'result')}</div><div class="row-note">${esc(vf.verdictText || vf.error || '')}</div>${vf.windowsOldPresent ? '<div class="row-note">C:\\Windows.old is present, so Windows\u2019 own "Go back" is still available.</div>' : ''}</div>`
      : `<div class="sexp-row"><div class="scard-body"><div class="scard-desc">Nothing checked yet.</div></div></div>`, !!vf));

  let html = `<div class="card-list">${cards.join('')}</div>`;
  if ((cat.risks || []).length) {
    html += `<div class="section-head"><h2>What can go wrong</h2></div>
      <div class="card-list">${cat.risks.map((r) => `<div class="scard"><span class="scard-icon" aria-hidden="true" style="color:var(--caution)">${GLYPH.warning}</span><div class="scard-body"><div class="scard-title">${esc(String(r.id).replace(/-/g, ' '))}</div><div class="scard-desc">${esc(r.copy)}</div></div></div>`).join('')}</div>`;
  }
  host.innerHTML = html;
  wireExpanders(host);
}

function consentCard() {
  const l = img.launch;
  const c = l && l.contract;
  const blockers = launchBlockers(l);              // null = the engine did not report one
  const ready = !!c && blockers !== null && blockers.length === 0;
  const consented = img.consentEula && img.consentBitlocker;
  const launched = img.launched && img.launched.ok;

  let rows = `<div class="sexp-row stack">
    <div class="row-note">${esc(((img.catalog.steps || []).find((s) => s.id === 'consent') || {}).copy || '')}</div>
  </div>`;
  if (!c) {
    rows += `<div class="sexp-row">
      <div class="scard-body"><div class="scard-title">The contract is generated from your actual media</div><div class="scard-desc">Set an ISO above, then load the contract. Loading it starts nothing.</div></div>
      <div class="scard-control">${img.busy === 'launch' ? '<span class="working">Loading…</span>' : '<button class="fbtn" data-act="img-contract">Load the consent contract</button>'}</div>
    </div>`;
    return imgExpander('consent', GLYPH.shield, 'Your decision', 'The heaviest repair FrameForge offers. Nothing starts until you explicitly agree here.', statusChip('idle', 'Not loaded'), rows, false);
  }
  rows += `<div class="sexp-row stack">
    <div class="row-label">The exact command that would run</div>
    <div class="mono">${esc(l.command || '')}</div>
  </div>`;
  rows += `<div class="sexp-row stack">
    <div class="row-label">What is preserved</div>
    <ul class="row-list yes">${(c.whatIsPreserved || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul>
    <div class="row-label" style="margin-top:10px">What is reset</div>
    <ul class="row-list no">${(c.whatIsReset || []).map((x) => `<li>${esc(x)}</li>`).join('')}</ul>
  </div>`;
  rows += `<div class="sexp-row stack">
    <div class="row-label">Time, restarts, and rollback</div>
    <div class="row-note">${esc(c.durationEstimate || '')}</div>
    <div class="row-note">${esc(c.rebootCount || '')}</div>
    <div class="row-note">${esc(c.rollbackNote || '')}</div>
    <div class="row-note">${esc(c.bitlockerNote || '')}</div>
  </div>`;
  if (blockers === null) {
    rows += `<div class="sexp-row stack">
      <div class="row-label">Readiness could not be confirmed</div>
      <div class="row-note">The engine did not report a blocker list for this machine, so FrameForge cannot confirm there is nothing standing in the way. The launch stays disabled: an unread check is not a passed check.</div>
    </div>`;
  } else if (blockers.length) {
    rows += `<div class="sexp-row stack">
      <div class="row-label">Blocked until these are cleared</div>
      <ul class="blocker-list">${blockers.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>
    </div>`;
  }
  rows += `<div class="consent-gate">
    <label class="consent-check"><input type="checkbox" class="fcheck" data-act="img-consent" data-which="eula" ${img.consentEula ? 'checked' : ''}>
      <span>${esc(c.eulaNote || '')}</span></label>
    <label class="consent-check"><input type="checkbox" class="fcheck" data-act="img-consent" data-which="bitlocker" ${img.consentBitlocker ? 'checked' : ''}>
      <span>I have confirmed I can access this drive's BitLocker recovery key, or this drive is not encrypted.</span></label>
    <div class="consent-actions">
      <button class="fbtn accent" data-act="img-launch" ${(!ready || !consented || img.busy === 'launch' || launched) ? 'disabled' : ''}>${launched ? 'Setup started' : img.busy === 'launch' ? 'Starting…' : 'Start the repair install'}</button>
      <span class="list-caption">${launched ? 'Windows Setup is running with /noreboot. You choose when to restart.'
    : blockers === null ? 'Disabled: the engine did not report a blocker list, so readiness could not be confirmed.'
      : !ready ? 'Disabled: the blockers above must be cleared first.'
        : !consented ? 'Disabled: both statements must be accepted.'
          : 'This is the point of no return FrameForge cannot undo. Windows keeps its own rollback.'}</span>
    </div>
  </div>`;
  return imgExpander('consent', GLYPH.shield, 'Your decision', 'The heaviest repair FrameForge offers. Nothing starts until you explicitly agree here.',
    launched ? statusChip('good', 'Setup started') : ready && consented ? statusChip('warn', 'Ready') : statusChip('idle', 'Gated'),
    rows, true);
}

/* ---------- theme sync (prefers-color-scheme follows the Windows app theme) ---------- */
(function themeSync() {
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const apply = () => document.body.classList.toggle('dark', mq.matches);
  if (mq.addEventListener) mq.addEventListener('change', apply); else if (mq.addListener) mq.addListener(apply);
  apply();
})();

/* ---------- init ---------- */
// One wedged IPC channel must not block first paint of everything else. `sys:isAdmin`
// used to have no timeout at all in the main process, so a stalled powershell.exe left
// Promise.all pending forever: a blank window, no toast, no spinner, no recovery.
function withTimeout(p, ms, fallback, what) {
  return Promise.race([
    Promise.resolve(p).catch((e) => (typeof fallback === 'function' ? fallback(e) : fallback)),
    new Promise((res) => setTimeout(() => res(typeof fallback === 'function'
      ? fallback(new Error(`${what} did not answer within ${Math.round(ms / 1000)}s`))
      : fallback), ms)),
  ]);
}

async function retrySysInfo() {
  try { state.sys = await window.ff.sysInfo(); }
  catch (e) { state.sys = { ok: false, error: String((e && e.message) || e) }; }
  revealNvidiaNav();
  rerenderAll();
}
async function retryDetect() { await refreshDetect(); rerenderAll(); }
function revealNvidiaNav() {
  const s = state.sys;
  if (isEngineError(s) || !Array.isArray(s.gpus)) return;
  if (s.gpus.some((g) => g && g.vendor === 'NVIDIA')) { const n = $('#navNvidia'); if (n) n.hidden = false; }
}

// Apply the measured environment: the solid Fluent ground is always painted by the
// native window, and body.mica is strictly additive on top of it.
function applyEnv(env) {
  if (!env) return;
  state.env = env;
  document.body.classList.toggle('mica', !!env.mica);
  if (env.capture) { const cb = $('#captionFallback'); if (cb) cb.hidden = false; }
}

/* App-wide conditions that make everything below either impossible or untrustworthy. Each
   one is a MEASURED state pushed up from the main process, and each renders as its own
   infobar — they can be true at the same time.

   1. The PowerShell engine does not work here at all (verified by running it, not predicted
      from Get-ExecutionPolicy). This is the loud failure that replaced a silently dead app.
   2. It works, but only from memory because a policy scope refuses script files.
   3. The policy could not be read.
   4. FrameForge is running as a DIFFERENT Windows account from the person at the keyboard
      (i.e. it was elevated with someone else's admin credentials). Every per-user tweak is
      refused in that state, so the reason has to be on screen. */
function renderPolicyBanner(env) {
  const host = $('#globalNotice'); if (!host) return;
  const p = (env && env.psPolicy) || null;
  const id = (env && env.identity) || null;
  const bars = [];

  if (p && p.engineUsable === false) {
    bars.push(infobarHtml('critical', GLYPH.error,
      'FrameForge cannot run its engine on this PC',
      `${p.message || 'PowerShell produced no usable output.'} Nothing below has been measured.`,
      diagButton(`${p.message || ''} ${p.probeError || ''}`.trim())));
  } else if (p && p.blocked) {
    // engineUsable is true (verified) or still null (probe not finished) — say which.
    const verified = p.engineUsable === true;
    bars.push(infobarHtml('caution', GLYPH.warning,
      'Group Policy restricts PowerShell scripts on this PC',
      `${p.message || ''}${verified ? '' : ' FrameForge is still checking whether its workaround actually works here; until it reports back, treat anything below as unconfirmed.'}`,
      diagButton(p.message || '')));
  } else if (p && p.mode === 'scriptblock' && p.engineUsable === true) {
    // Nothing predicted this: the normal way of starting the engine produced nothing here and
    // FrameForge fell back to the from-memory path, which it then verified. Unusual enough
    // that the user should know why, even though results below ARE measured.
    bars.push(infobarHtml('caution', GLYPH.warning,
      'FrameForge had to start its engine a different way on this PC',
      p.message || 'The usual way of running the engine produced nothing, so FrameForge switched to running it from memory and verified that path works.',
      diagButton(p.message || '')));
  } else if (p && (p.checked === false || p.error)) {
    bars.push(infobarHtml('caution', GLYPH.warning,
      'PowerShell execution policy could not be read',
      `${p.error || 'The probe returned nothing.'} If engine calls below fail with no output, a policy scope is the first thing to check.`, ''));
  }

  if (id && id.profileMismatch === true) {
    const who = id.interactiveName || id.interactiveSid || 'the signed-in user';
    const me = id.tokenName || id.tokenSid || 'another account';
    bars.push(infobarHtml('critical', GLYPH.admin,
      'FrameForge is running as a different Windows account',
      `It is running as ${me}, but ${who} is signed in at this PC. Per-user settings (Game DVR, Game Mode, visual effects, mouse acceleration) belong to whoever is signed in, so FrameForge will refuse to change them from here rather than write them into the wrong profile. Those tweaks never need administrator rights — close FrameForge and start it normally to use them.`,
      diagButton(`running as ${me} / signed in ${who} (basis: ${id.basis || 'unknown'})`)));
  } else if (id && id.profileMismatch === null) {
    bars.push(infobarHtml('caution', GLYPH.warning,
      'FrameForge cannot tell whose Windows settings it would change',
      `${id.reason || 'The interactive user could not be identified.'} Per-user tweaks are refused until it can. Starting FrameForge without "Run as administrator" resolves this.`,
      diagButton(id.probeError || id.reason || '')));
  }

  if (!bars.length) { host.hidden = true; host.innerHTML = ''; return; }
  host.hidden = false;
  host.innerHTML = bars.join('');
}

/* Segoe Fluent Icons is Windows 11 only, Segoe MDL2 Assets does not share its whole PUA
   map, and a corrupt font cache or a font-substitution policy can lose both. The
   codepoints then render as tofu, and the GLYPH-ONLY affordances (disclosure chevron,
   combobox caret, list bullets, severity marks, drawer close) lose all meaning.

   This is measured, not asserted. document.fonts.check() is NOT usable here: it returns
   true for a font that is not installed at all (verified — it answers "can this text be
   rendered", and the fallback chain always can). Instead each representative codepoint is
   measured against a plain serif baseline: an icon face renders these at the full em
   square, while a missing glyph falls back to the serif tofu box at a different width.
   Any tofu among them switches the stylesheet to text substitutes. */
const ICON_PROBE_CHARS = [
  GLYPH.chevronDown,   // .chev disclosure
  GLYPH.check,         // .row-list bullets
  GLYPH.dismiss,       // .blocker-list / .row-list.no markers
  GLYPH.bullet,        // .row-list.plain bullets
  GLYPH.close,         // drawer close button
];
function probeIconFont() {
  try {
    const ctx = document.createElement('canvas').getContext('2d');
    if (!ctx) return;
    const width = (family, ch) => { ctx.font = `48px ${family}`; return ctx.measureText(ch).width; };
    let anyTofu = false;
    for (const ch of ICON_PROBE_CHARS) {
      if (!ch) continue;
      const base = width('serif', ch);
      const fluent = width('"Segoe Fluent Icons", serif', ch);
      const mdl2 = width('"Segoe MDL2 Assets", serif', ch);
      // A difference from the serif baseline means an icon face actually supplied it.
      if (Math.abs(fluent - base) < 0.5 && Math.abs(mdl2 - base) < 0.5) { anyTofu = true; break; }
    }
    document.body.classList.toggle('no-icons', anyTofu);
  } catch (e) { /* if we cannot tell, leave the glyphs alone rather than guess */ }
}

(async function init() {
  // simple mode by default
  setMode('simple');
  // Mica: main tells us whether the OS is actually DRAWING a backdrop (build +
  // transparency setting + High Contrast), not just whether the build could.
  if (window.ff.env) {
    try {
      const env = await withTimeout(window.ff.env(), 10000, null, 'ui:env');
      applyEnv(env);
      renderPolicyBanner(env);
    } catch (e) { /* solid fallback */ }
    // Transparency effects and High Contrast can be toggled while we are running.
    if (window.ff.onEnvChanged) window.ff.onEnvChanged((env) => { applyEnv(env); renderPolicyBanner(env); });
  }
  if (window.ff.onTrayRevertAll) {
    window.ff.onTrayRevertAll(async (res) => {
      // Same rule as the in-app button: `ok !== false` is not the same as "it worked".
      // revert-all reports success=false when it could not see the right account's ledger,
      // and that has to reach the user instead of a green "Reverted everything".
      if (res && res.ok !== false && res.success === true) {
        toast('ok', 'Reverted everything', res.count != null ? `${res.count} change(s) undone.` : 'Done.');
        await refreshDetect(); rerenderAll();
      } else if (res && res.ok !== false) {
        toast('err', 'Not everything was undone', (res.message || res.error || 'FrameForge could not confirm that anything was reverted.'), 16000);
        await refreshDetect(); rerenderAll();
      } else {
        toast('err', 'Revert all tweaks failed', engineErrorText(res));
      }
    });
  }
  probeIconFont();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(probeIconFont).catch(() => {});

  try {
    // Run the independent detection calls concurrently for a faster first paint. Each is
    // individually bounded and individually degradable: one failure must not blank the app.
    const [admin, tw, sys] = await Promise.all([
      withTimeout(window.ff.isAdmin(), 30000, false, 'administrator check'),
      withTimeout(window.ff.listTweaks(), 30000, (e) => ({ ok: false, error: String((e && e.message) || e), tweaks: [] }), 'tweak catalog'),
      withTimeout(window.ff.sysInfo(), 90000, (e) => ({ ok: false, error: String((e && e.message) || e) }), 'hardware detection'),
    ]);
    state.admin = !!admin;
    state.tweaks = (tw && tw.tweaks) || [];
    state.sys = sys;
    await refreshDetect();
    updateAdminUI();
    rerenderAll();
    // Preload the static catalogs so "Find a setting" can search health checks and
    // repairs before either page has been opened. Both are plain JSON reads.
    Promise.all([window.ff.health.catalog(), window.ff.repair.catalog()])
      .then(([hc, rc]) => {
        if (!health.catalog) health.catalog = (hc && hc.checks) || [];
        if (!repairs.catalog) repairs.catalog = (rc && rc.repairs) || [];
      })
      .catch(() => { /* search degrades to whatever is loaded */ });
    // Reveal the NVIDIA entry only on NVIDIA rigs.
    revealNvidiaNav();
    // Only claim free performance when the rated speed was actually read.
    const ram = !isEngineError(state.sys) ? state.sys.ram : null;
    if (xmpState(ram) === true) {
      setTimeout(() => toast('warn', 'Free performance found', `Your RAM runs ${ram.runningMTs} but is rated ${ram.ratedMTs}. See “Enable XMP”.`, 9000), 900);
    }
  } catch (err) {
    // Last resort. Everything above degrades on its own, so reaching here means a bug —
    // and the app still has to say something more useful than a vanishing toast.
    console.error('[FrameForge] startup', err);
    toast('err', 'Startup error', String(err && err.message || err));
    safely('Home', () => renderEngineFailure({ ok: false, error: String((err && err.message) || err) }));
  }
})();
