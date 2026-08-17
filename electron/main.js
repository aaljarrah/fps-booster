'use strict';
const { app, BrowserWindow, ipcMain, shell, Tray, Menu, nativeImage } = require('electron');
const path = require('path');
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

function createWindow() {
  win = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 960,
    minHeight: 640,
    frame: false,
    backgroundColor: '#0b0f17',
    show: false,
    title: 'FrameForge',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  win.loadFile(path.join(ROOT, 'src', 'index.html'));
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });

  // Dev-only: capture each view to PNG for verification (FF_CAPTURE=<dir>), then quit.
  if (process.env.FF_CAPTURE) {
    const dir = process.env.FF_CAPTURE;
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const js = (s) => win.webContents.executeJavaScript(s).catch(() => {});
    win.webContents.once('did-finish-load', async () => {
      try { fs.mkdirSync(dir, { recursive: true }); } catch (_) {}
      const cap = async (name) => { try { const img = await win.webContents.capturePage(); fs.writeFileSync(path.join(dir, name), img.toPNG()); } catch (_) {} };
      await wait(9000); // let the parallel sysinfo + detect-all PowerShell calls finish + render
      await cap('01-dashboard.png');
      await js("document.querySelector('.nav-item[data-view=boost]').click()"); await wait(700); await cap('02-boost.png');
      await js("document.querySelector('#modeSwitch span[data-mode=advanced]').click(); document.querySelector('.nav-item[data-view=tweaks]').click()"); await wait(800); await cap('03-tweaks.png');
      await js("document.querySelector('.nav-item[data-view=benchmark]').click()"); await wait(2500); await cap('04-benchmark.png');
      await js("document.querySelector('.nav-item[data-view=focus]').click()"); await wait(3000); await cap('05-focus.png');
      await js("document.querySelector('.nav-item[data-view=safety]').click()"); await wait(700); await cap('06-safety.png');
      await js("var n=document.querySelector('.nav-item[data-view=nvidia]'); if(n){n.hidden=false; n.click();}"); await wait(4500); await cap('07-nvidia.png');
      await js("var a=document.querySelector('#nvAdvanced'); if(a){a.hidden=false;} var c=document.querySelector('.content'); if(c){c.scrollTop=720;}"); await wait(500); await cap('08-nvidia-advanced.png');
      app.quit();
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

ipcMain.handle('app:openExternal', (_e, url) => { if (/^https?:\/\//i.test(url)) shell.openExternal(url); return true; });
ipcMain.handle('win:minimize', () => win && win.minimize());
ipcMain.handle('win:maximize', () => { if (!win) return; win.isMaximized() ? win.unmaximize() : win.maximize(); });
ipcMain.handle('win:close', () => win && win.close());

app.whenReady().then(() => { createWindow(); createTray(); });
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
