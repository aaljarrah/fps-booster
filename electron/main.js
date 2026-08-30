'use strict';
const { app, BrowserWindow, ipcMain, shell, Tray, Menu, nativeImage, nativeTheme } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile, spawn } = require('child_process');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, 'engine');
const PS = process.env.SystemRoot
  ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';

let win = null;
let tray = null;

/** Run a FrameForge PowerShell engine script and parse its JSON stdout. */
function runPs(scriptName, args = [], { timeout = 60000 } = {}) {
  return new Promise((resolve) => {
    const script = path.join(ENGINE, scriptName);
    const full = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
    execFile(PS, full, { timeout, maxBuffer: 1024 * 1024 * 16, windowsHide: true }, (err, stdout, stderr) => {
      const raw = (stdout || '').trim();
      if (!raw) {
        resolve({ ok: false, error: (stderr || (err && err.message) || 'No output from engine.').toString().trim() });
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        resolve({ ok: false, error: 'Could not parse engine output.', raw: raw.slice(0, 4000), stderr: (stderr || '').trim() });
      }
    });
  });
}

function isElevated() {
  return new Promise((resolve) => {
    execFile(PS, ['-NoProfile', '-Command',
      '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'],
      { windowsHide: true }, (e, out) => resolve(/True/i.test(out || '')));
  });
}

function relaunchElevated() {
  const exe = process.execPath;
  const args = process.defaultApp ? process.argv.slice(1) : [];
  const argList = args.map((a) => `'${a.replace(/'/g, "''")}'`).join(',');
  const cmd = argList
    ? `Start-Process -FilePath '${exe}' -ArgumentList ${argList} -Verb RunAs`
    : `Start-Process -FilePath '${exe}' -Verb RunAs`;
  spawn(PS, ['-NoProfile', '-Command', cmd], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  setTimeout(() => app.quit(), 400);
}

// Mica needs Windows 11 22H2+ (build 22621). Elsewhere we fall back to the solid
// SolidBackgroundFillColorBase the renderer paints by default — exactly what WinUI does.
function micaSupported() {
  if (process.platform !== 'win32') return false;
  const build = Number((os.release().split('.')[2] || 0));
  return build >= 22621;
}

function overlayColors() {
  const dark = nativeTheme.shouldUseDarkColors;
  return {
    color: '#00000000',                       // transparent — caption area shows Mica/page
    symbolColor: dark ? '#FFFFFF' : '#1A1A1A',
    height: 48,
  };
}

function createWindow() {
  // Dev-only: FF_THEME=dark|light forces the theme for captures.
  if (process.env.FF_THEME) { try { nativeTheme.themeSource = process.env.FF_THEME; } catch (_) {} }
  // capturePage() can't composite the OS-drawn Mica backdrop (transparent pixels would
  // capture black), so captures use the solid fallback — the same thing WinUI paints
  // when Mica is unavailable.
  const useMica = micaSupported() && !process.env.FF_CAPTURE;
  const opts = {
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 640,
    show: false,
    title: 'FrameForge',
    titleBarStyle: 'hidden',
    titleBarOverlay: overlayColors(),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  };
  if (useMica) {
    opts.backgroundMaterial = 'mica';         // never combine with transparent: true
  } else {
    opts.backgroundColor = nativeTheme.shouldUseDarkColors ? '#202020' : '#F3F3F3';
  }
  win = new BrowserWindow(opts);
  win.loadFile(path.join(ROOT, 'src', 'index.html'));
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });

  // Keep caption-button symbols in sync with the Windows app theme.
  nativeTheme.on('updated', () => {
    if (!win) return;
    try { win.setTitleBarOverlay(overlayColors()); } catch (_) { /* best effort */ }
  });

  // Dev-only: capture each view to PNG for verification (FF_CAPTURE=<dir>), then quit.
  // The harness FAILS LOUDLY: a missing click target, a wrong active view at capture
  // time, or a duplicate output hash aborts with exit code 1 — it never silently
  // reuses the previous view. Waits are condition-polls on data-loaded signals, not
  // fixed sleeps.
  if (process.env.FF_CAPTURE) {
    const crypto = require('crypto');
    const dir = process.env.FF_CAPTURE;
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const js = (s) => win.webContents.executeJavaScript(s); // rejects propagate — nothing is swallowed
    const fail = (msg) => {
      console.error(`[FF_CAPTURE] FAILED: ${msg}`);
      try { fs.writeFileSync(path.join(dir, 'FAILED.txt'), `${msg}\n`); } catch (_) {}
      app.exit(1);
      throw new Error(msg);
    };
    const waitFor = async (expr, desc, timeoutMs = 60000) => {
      const t0 = Date.now();
      for (;;) {
        let v = null;
        try { v = await js(expr); } catch (e) { fail(`waitFor(${desc}) threw: ${(e && e.message) || e}`); }
        if (v) return;
        if (Date.now() - t0 > timeoutMs) fail(`timed out after ${timeoutMs}ms waiting for: ${desc}`);
        await wait(150);
      }
    };
    // Error-checked click: a selector that matches nothing aborts the run.
    const clickSel = async (sel) => {
      const found = await js(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return false; el.click(); return true; })()`);
      if (!found) fail(`click target not found: ${sel}`);
    };
    const activeViewIs = (view) => `(() => { const a = document.querySelector('.view.active'); return !!a && a.id === 'view-${view}'; })()`;
    const goto = async (view) => {
      await clickSel(`.nav-item[data-view=${view}]`);
      await waitFor(activeViewIs(view), `active view = ${view}`, 10000);
      await wait(450); // let the 250ms page-in animation settle before pixels are read
    };
    // Two rAF round-trips guarantee the compositor produced a frame containing the
    // latest DOM state before pixels are read (raced against a fallback so a
    // throttled window can't hang the run).
    const paintBarrier = () => js("Promise.race([new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true)))), new Promise(r => setTimeout(() => r(true), 1500))])");
    // Capture re-asserts the expected view is the active one at the moment of capture.
    // An occluded or throttled window can hand capturePage the PREVIOUS view's frame;
    // that is a stale read, not a real duplicate, so re-read a couple of times before
    // writing. The end-of-run evidence check still hashes the files on disk and fails
    // loudly if any pair is identical, so this cannot mask a genuine duplicate.
    const capturedHashes = new Map();
    const cap = async (name, view) => {
      const active = await js(`(document.querySelector('.view.active') || { id: 'none' }).id`);
      if (active !== `view-${view}`) fail(`capturing ${name}: active view is "${active}", expected "view-${view}"`);
      let png = null, hash = null;
      for (let attempt = 0; attempt < 3; attempt++) {
        await paintBarrier();
        const img = await win.webContents.capturePage();
        if (img.isEmpty()) fail(`capturePage returned an empty image for ${name}`);
        png = img.toPNG();
        hash = crypto.createHash('md5').update(png).digest('hex');
        if (!capturedHashes.has(hash)) break;
        console.log(`[FF_CAPTURE] stale frame for ${name} (matches ${capturedHashes.get(hash)}); re-reading`);
        await wait(700);
      }
      capturedHashes.set(hash, name);
      fs.writeFileSync(path.join(dir, name), png);
    };
    win.webContents.once('did-finish-load', async () => {
      try {
        fs.mkdirSync(dir, { recursive: true });
        // 1. Home must be fully loaded before the first capture: hardware detected,
        //    spec cards rendered, opportunity scan done, NVIDIA nav entry revealed.
        await waitFor("document.querySelectorAll('#specGrid .scard').length >= 4", 'dashboard spec cards populated');
        await waitFor("!document.getElementById('navNvidia').hidden", 'NVIDIA nav item revealed');
        await waitFor("!/Scanning/.test(document.getElementById('oppList').textContent)", 'opportunity scan finished');
        await waitFor("!/Detecting/.test(document.getElementById('navRigSub').textContent)", 'nav profile shows detected hardware');
        // 2. Advanced mode so the Tweaks nav entry is present in every shot.
        await clickSel('#modeSwitch span[data-mode=advanced]');
        await waitFor("getComputedStyle(document.querySelector('.nav-item[data-view=tweaks]')).display !== 'none'", 'Tweaks nav item visible');
        // 3. Keep captures clean of transient toasts.
        await js("(() => { const ts = document.getElementById('toasts'); if (ts) ts.style.display = 'none'; return true; })()");
        await wait(450); // settle the mode-switch/toast repaint like every goto() does
        await cap('01-dashboard.png', 'dashboard');
        await goto('boost');
        await waitFor("document.querySelectorAll('#profileGrid .sexpander').length >= 3", 'boost profiles rendered');
        await cap('02-boost.png', 'boost');
        await goto('tweaks');
        await waitFor("document.querySelectorAll('#tweakList .sexpander').length > 0", 'tweak list rendered');
        await cap('03-tweaks.png', 'tweaks');
        await goto('benchmark');
        await waitFor("(() => { const s = document.getElementById('benchTarget'); return !!s && s.options.length > 0 && !/Loading|Refresh to list/.test(s.textContent); })()", 'benchmark target list loaded');
        await cap('04-benchmark.png', 'benchmark');
        await goto('focus');
        await waitFor("!/Scanning/.test(document.getElementById('focusList').textContent)", 'background app scan finished');
        await cap('05-focus.png', 'focus');
        await goto('safety');
        await cap('06-safety.png', 'safety');
        await goto('nvidia');
        await waitFor("document.querySelectorAll('#nvPresets .sexpander').length >= 3 && !/Loading/.test(document.getElementById('nvStrip').textContent)", 'NVIDIA page loaded');
        await cap('07-nvidia.png', 'nvidia');
        // "Every NVIDIA setting" is its own sub-page (Settings-style back navigation),
        // so it is captured as its own view rather than as a scrolled-to region.
        await clickSel('#nvAdvToggle');
        await waitFor(activeViewIs('nvidia-advanced'), 'active view = nvidia-advanced', 10000);
        await waitFor("document.querySelectorAll('#nvAdvanced .scard').length > 1", 'NVIDIA advanced list rendered');
        await wait(450);
        await cap('08-nvidia-advanced.png', 'nvidia-advanced');
        // Health auto-scans on first visit; the scan is read-only and takes ~10s
        // (longer on a slow licensing provider), so wait for real rendered results.
        await goto('health');
        await waitFor("document.querySelectorAll('#healthBody .sexpander').length > 0", 'health scan results rendered', 180000);
        await wait(450);
        await cap('09-health.png', 'health');
        await goto('repair');
        await waitFor("document.querySelectorAll('#repairBody .sexpander').length > 0", 'repair ladder rendered', 180000);
        await waitFor("document.querySelectorAll('#imageRepair .sexpander').length > 0", 'fresh-image flow rendered', 30000);
        await wait(450);
        await cap('10-repair.png', 'repair');
        // 4. Evidence check: all ten files must exist and be pairwise unique.
        const names = ['01-dashboard.png', '02-boost.png', '03-tweaks.png', '04-benchmark.png', '05-focus.png',
          '06-safety.png', '07-nvidia.png', '08-nvidia-advanced.png', '09-health.png', '10-repair.png'];
        const seen = new Map();
        for (const n of names) {
          const p = path.join(dir, n);
          if (!fs.existsSync(p)) fail(`missing capture: ${n}`);
          const h = crypto.createHash('md5').update(fs.readFileSync(p)).digest('hex');
          if (seen.has(h)) fail(`duplicate capture: ${n} is byte-identical to ${seen.get(h)} (md5 ${h})`);
          seen.set(h, n);
        }
        console.log(`[FF_CAPTURE] OK — ${names.length} unique captures written to ${dir}`);
        app.quit();
      } catch (err) {
        // fail() has already logged + set the exit code; this guards everything else.
        console.error(`[FF_CAPTURE] FAILED: ${(err && err.stack) || err}`);
        app.exit(1);
      }
    });
  }
}

function createTray() {
  try {
    const icon = nativeImage.createFromPath(path.join(ROOT, 'src', 'assets', 'tray.png'));
    tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon);
    tray.setToolTip('FrameForge — FPS optimizer');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open FrameForge', click: () => { if (win) { win.show(); win.focus(); } else createWindow(); } },
      { type: 'separator' },
      { label: 'Revert all tweaks', click: async () => { await runPs('engine.ps1', ['-Action', 'revert-all']); } },
      { label: 'Quit', click: () => app.quit() },
    ]));
    tray.on('double-click', () => { if (win) { win.show(); win.focus(); } });
  } catch (_) { /* tray is best-effort */ }
}

// Read + parse a JSON file, tolerating a UTF-8 BOM (PowerShell-written files have one; Node's
// JSON.parse rejects the leading ﻿).
function readJsonFile(rel) {
  let raw = fs.readFileSync(path.join(ROOT, rel), 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return JSON.parse(raw);
}

// ---------------- IPC ----------------
ipcMain.handle('ui:env', () => ({ mica: micaSupported(), dark: nativeTheme.shouldUseDarkColors, capture: !!process.env.FF_CAPTURE }));
ipcMain.handle('sys:info', () => runPs('sysinfo.ps1'));
ipcMain.handle('sys:isAdmin', () => isElevated());
ipcMain.handle('sys:relaunchElevated', () => { relaunchElevated(); return true; });

ipcMain.handle('tweaks:list', () => {
  try { return readJsonFile('data/tweaks.json'); }
  catch (e) { return { ok: false, error: e.message, tweaks: [] }; }
});
ipcMain.handle('tweaks:detectAll', () => runPs('engine.ps1', ['-Action', 'detect-all']));
ipcMain.handle('tweaks:apply', (_e, id, dry) => runPs('engine.ps1', ['-Action', 'apply', '-Id', id, ...(dry ? ['-DryRun'] : [])]));
ipcMain.handle('tweaks:revert', (_e, id) => runPs('engine.ps1', ['-Action', 'revert', '-Id', id]));
ipcMain.handle('tweaks:revertAll', () => runPs('engine.ps1', ['-Action', 'revert-all']));
ipcMain.handle('tweaks:restorePoint', () => runPs('engine.ps1', ['-Action', 'restore-point'], { timeout: 120000 }));

ipcMain.handle('bench:capture', (_e, proc, seconds, label) =>
  runPs('measure.ps1', ['-Action', 'capture', '-Process', String(proc), '-Seconds', String(seconds || 20), '-Label', label || 'run'],
    { timeout: (Number(seconds || 20) + 30) * 1000 }));
ipcMain.handle('bench:analyze', (_e, csv) => runPs('measure.ps1', ['-Action', 'analyze', '-Csv', csv]));

ipcMain.handle('procs:windowed', () => runPs('procs.ps1', ['-Action', 'windowed']));
ipcMain.handle('procs:bloat', () => runPs('procs.ps1', ['-Action', 'bloat']));
ipcMain.handle('procs:close', (_e, ids) => runPs('procs.ps1', ['-Action', 'close', '-Ids', (ids || []).join(',')]));

ipcMain.handle('nvidia:detect', () => runPs('nvidia.ps1', ['-Action', 'detect']));
ipcMain.handle('nvidia:snapshot', () => runPs('nvidia.ps1', ['-Action', 'snapshot']));
ipcMain.handle('nvidia:list', () => runPs('nvidia.ps1', ['-Action', 'list']));
ipcMain.handle('nvidia:restore', () => runPs('nvidia.ps1', ['-Action', 'restore']));
ipcMain.handle('nvidia:open', () => runPs('nvidia.ps1', ['-Action', 'open']));
ipcMain.handle('nvidia:createcsn', () => runPs('nvidia.ps1', ['-Action', 'createcsn'], { timeout: 120000 }));
ipcMain.handle('nvidia:games', () => runPs('nvidia.ps1', ['-Action', 'games']));
ipcMain.handle('nvidia:catalog', () => {
  try { return readJsonFile('data/nvidia-settings.json'); }
  catch (e) { return { ok: false, error: e.message }; }
});
ipcMain.handle('nvidia:preview', (_e, preset, vrrOk) => runPs('nvidia.ps1', ['-Action', 'preview', '-Preset', preset, ...(vrrOk ? ['-VrrOk'] : [])]));
ipcMain.handle('nvidia:applyPreset', (_e, preset, vrrOk) => runPs('nvidia.ps1', ['-Action', 'apply-preset', '-Preset', preset, ...(vrrOk ? ['-VrrOk'] : [])], { timeout: 120000 }));
ipcMain.handle('nvidia:previewCustom', (_e, keys, vrrOk) => runPs('nvidia.ps1', ['-Action', 'preview-custom', '-Keys', (keys || []).join(','), ...(vrrOk ? ['-VrrOk'] : [])]));
ipcMain.handle('nvidia:applyCustom', (_e, keys, vrrOk) => runPs('nvidia.ps1', ['-Action', 'apply-custom', '-Keys', (keys || []).join(','), ...(vrrOk ? ['-VrrOk'] : [])], { timeout: 120000 }));
ipcMain.handle('nvidia:revertApplied', () => runPs('nvidia.ps1', ['-Action', 'revert'], { timeout: 120000 }));
ipcMain.handle('nvidia:buildCatalog', (_e, refresh) => runPs('nvidia.ps1', ['-Action', 'build-catalog', '-Refresh', String(refresh || 240)], { timeout: 120000 }));

// ---------------- Windows health (read-only probes) ----------------
ipcMain.handle('health:scan', (_e, deep) => runPs('health.ps1', ['-Action', 'scan', ...(deep ? ['-Deep'] : [])], { timeout: deep ? 600000 : 90000 }));
ipcMain.handle('health:probe', (_e, category, deep) =>
  runPs('health.ps1', ['-Action', 'probe', '-Category', String(category || ''), ...(deep ? ['-Deep'] : [])], { timeout: deep ? 600000 : 90000 }));
ipcMain.handle('health:catalog', () => {
  try { return readJsonFile('data/health-checks.json'); }
  catch (e) { return { ok: false, error: e.message, checks: [] }; }
});

// ---------------- Repair ladder ----------------
ipcMain.handle('repair:list', () => runPs('repair.ps1', ['-Action', 'list'], { timeout: 120000 }));
ipcMain.handle('repair:preflight', (_e, id) => runPs('repair.ps1', ['-Action', 'preflight', '-Id', String(id || '')], { timeout: 180000 }));
ipcMain.handle('repair:run', (_e, id, opts) => {
  const o = opts || {};
  return runPs('repair.ps1', ['-Action', 'run', '-Id', String(id || ''),
    ...(o.dryRun ? ['-DryRun'] : []), ...(o.force ? ['-Force'] : [])], { timeout: 1800000 });
});
ipcMain.handle('repair:undo', (_e, id, opts) => {
  const o = opts || {};
  return runPs('repair.ps1', ['-Action', 'undo', '-Id', String(id || ''), ...(o.dryRun ? ['-DryRun'] : [])], { timeout: 600000 });
});
ipcMain.handle('repair:ledger', () => runPs('repair.ps1', ['-Action', 'ledger'], { timeout: 60000 }));
ipcMain.handle('repair:catalog', () => {
  try { return readJsonFile('data/repairs.json'); }
  catch (e) { return { ok: false, error: e.message, repairs: [] }; }
});

// ---------------- Fresh-image repair ----------------
// Media parameters are normalised here so a renderer can never smuggle extra switches in.
function imageMediaArgs(opts) {
  const o = opts || {};
  const args = [];
  if (o.isoPath) args.push('-IsoPath', String(o.isoPath));
  if (o.sourcePath) args.push('-SourcePath', String(o.sourcePath));
  if (Number.isInteger(o.index) && o.index > 0) args.push('-Index', String(o.index));
  return args;
}
ipcMain.handle('image:detect', () => runPs('image.ps1', ['-Action', 'detect'], { timeout: 120000 }));
ipcMain.handle('image:validate', (_e, opts) => runPs('image.ps1', ['-Action', 'validate', ...imageMediaArgs(opts)], { timeout: 600000 }));
ipcMain.handle('image:preflight', (_e, opts) => {
  const o = opts || {};
  return runPs('image.ps1', ['-Action', 'preflight', ...imageMediaArgs(o), ...(o.dryRun ? ['-DryRun'] : [])], { timeout: 1800000 });
});
// Consent contract mode is the DEFAULT: -Confirm is appended only when the renderer
// passes confirm === true, which only happens from an explicit user click on the
// consent gate. Anything else returns the contract and starts nothing (doctrine rule 3).
ipcMain.handle('image:launch', (_e, opts) => {
  const o = opts || {};
  const args = ['-Action', 'launch', ...imageMediaArgs(o)];
  if (o.confirm === true) args.push('-Confirm');
  if (o.suspendBitLocker === true) args.push('-SuspendBitLocker');
  if (o.dryRun === true) args.push('-DryRun');
  return runPs('image.ps1', args, { timeout: 600000 });
});
ipcMain.handle('image:verify', () => runPs('image.ps1', ['-Action', 'verify'], { timeout: 180000 }));
ipcMain.handle('image:acquireUrl', (_e, opts) => {
  const o = opts || {};
  return runPs('image.ps1', ['-Action', 'acquire-url', ...(o.dryRun ? ['-DryRun'] : [])], { timeout: 300000 });
});
ipcMain.handle('image:catalog', () => {
  try { return readJsonFile('data/image-repair.json'); }
  catch (e) { return { ok: false, error: e.message }; }
});

ipcMain.handle('app:openExternal', (_e, url) => { if (/^https?:\/\//i.test(url)) shell.openExternal(url); return true; });
ipcMain.handle('win:minimize', () => win && win.minimize());
ipcMain.handle('win:maximize', () => { if (!win) return; win.isMaximized() ? win.unmaximize() : win.maximize(); });
ipcMain.handle('win:close', () => win && win.close());

app.whenReady().then(() => { createWindow(); createTray(); });
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
