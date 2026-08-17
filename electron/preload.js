'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// Secure, minimal API surface exposed to the renderer. No Node, no ipcRenderer leakage.
contextBridge.exposeInMainWorld('ff', {
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

  // Misc
  openExternal: (url) => ipcRenderer.invoke('app:openExternal', url),
  win: {
    minimize: () => ipcRenderer.invoke('win:minimize'),
    maximize: () => ipcRenderer.invoke('win:maximize'),
    close: () => ipcRenderer.invoke('win:close'),
  },
});
