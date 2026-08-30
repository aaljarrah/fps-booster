'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// Secure, minimal API surface exposed to the renderer. No Node, no ipcRenderer leakage.
contextBridge.exposeInMainWorld('ff', {
  // UI environment (Mica availability, theme at startup)
  env: () => ipcRenderer.invoke('ui:env'),

  // System
  sysInfo: () => ipcRenderer.invoke('sys:info'),
  isAdmin: () => ipcRenderer.invoke('sys:isAdmin'),
  relaunchElevated: () => ipcRenderer.invoke('sys:relaunchElevated'),

  // Tweaks
  listTweaks: () => ipcRenderer.invoke('tweaks:list'),
  detectAll: () => ipcRenderer.invoke('tweaks:detectAll'),
  apply: (id, dryRun = false) => ipcRenderer.invoke('tweaks:apply', id, dryRun),
  revert: (id) => ipcRenderer.invoke('tweaks:revert', id),
  revertAll: () => ipcRenderer.invoke('tweaks:revertAll'),
  restorePoint: () => ipcRenderer.invoke('tweaks:restorePoint'),

  // Benchmark
  capture: (proc, seconds, label) => ipcRenderer.invoke('bench:capture', proc, seconds, label),
  analyze: (csv) => ipcRenderer.invoke('bench:analyze', csv),

  // Processes
  windowedProcs: () => ipcRenderer.invoke('procs:windowed'),
  bloatProcs: () => ipcRenderer.invoke('procs:bloat'),
  closeProcs: (ids) => ipcRenderer.invoke('procs:close', ids),

  // NVIDIA (snapshot/restore the driver settings DB + launch the tuner)
  nvidia: {
    detect: () => ipcRenderer.invoke('nvidia:detect'),
    snapshot: () => ipcRenderer.invoke('nvidia:snapshot'),
    list: () => ipcRenderer.invoke('nvidia:list'),
    restore: () => ipcRenderer.invoke('nvidia:restore'),
    open: () => ipcRenderer.invoke('nvidia:open'),
    createCsn: () => ipcRenderer.invoke('nvidia:createcsn'),
    games: () => ipcRenderer.invoke('nvidia:games'),
    catalog: () => ipcRenderer.invoke('nvidia:catalog'),
    preview: (preset, vrrOk) => ipcRenderer.invoke('nvidia:preview', preset, vrrOk),
    applyPreset: (preset, vrrOk) => ipcRenderer.invoke('nvidia:applyPreset', preset, vrrOk),
    previewCustom: (keys, vrrOk) => ipcRenderer.invoke('nvidia:previewCustom', keys, vrrOk),
    applyCustom: (keys, vrrOk) => ipcRenderer.invoke('nvidia:applyCustom', keys, vrrOk),
    revertApplied: () => ipcRenderer.invoke('nvidia:revertApplied'),
    buildCatalog: (refresh) => ipcRenderer.invoke('nvidia:buildCatalog', refresh),
  },

  // Windows health — read-only probes (the same probe verifies after a repair)
  health: {
    scan: (deep = false) => ipcRenderer.invoke('health:scan', !!deep),
    probe: (category, deep = false) => ipcRenderer.invoke('health:probe', category, !!deep),
    catalog: () => ipcRenderer.invoke('health:catalog'),
  },

  // Repair ladder
  repair: {
    list: () => ipcRenderer.invoke('repair:list'),
    preflight: (id) => ipcRenderer.invoke('repair:preflight', id),
    run: (id, opts) => ipcRenderer.invoke('repair:run', id, opts || {}),
    undo: (id, opts) => ipcRenderer.invoke('repair:undo', id, opts || {}),
    ledger: () => ipcRenderer.invoke('repair:ledger'),
    catalog: () => ipcRenderer.invoke('repair:catalog'),
  },

  // Fresh-image repair — launch() is consent-contract mode unless { confirm: true }
  image: {
    detect: () => ipcRenderer.invoke('image:detect'),
    validate: (opts) => ipcRenderer.invoke('image:validate', opts || {}),
    preflight: (opts) => ipcRenderer.invoke('image:preflight', opts || {}),
    launch: (opts) => ipcRenderer.invoke('image:launch', opts || {}),
    verify: () => ipcRenderer.invoke('image:verify'),
    acquireUrl: (opts) => ipcRenderer.invoke('image:acquireUrl', opts || {}),
    catalog: () => ipcRenderer.invoke('image:catalog'),
  },

  // Misc
  openExternal: (url) => ipcRenderer.invoke('app:openExternal', url),
  win: {
    minimize: () => ipcRenderer.invoke('win:minimize'),
    maximize: () => ipcRenderer.invoke('win:maximize'),
    close: () => ipcRenderer.invoke('win:close'),
  },
});
