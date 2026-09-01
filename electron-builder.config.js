'use strict';
/* FrameForge packaging.
 *
 * Shape of the ship: a one-click, per-user NSIS installer (FrameForgeSetup.exe) that
 * installs to %LOCALAPPDATA%\Programs\FrameForge and launches the app when it finishes —
 * download → run → playing, with no wizard. Machine-wide state the engines write lives in
 * %LOCALAPPDATA%\FrameForge\state (engine.ps1/image.ps1), so replacing the install dir on
 * update never touches a user's rollback ledger.
 *
 * asar is OFF, deliberately: the PowerShell engines are read as TEXT at runtime
 * (electron/main.js scriptblock mode), powershell.exe runs them as FILES in the normal
 * mode, PresentMon.exe / nvidiaProfileInspector.exe must be spawnable, and data/*.json is
 * read with fs off ROOT. Every one of those breaks inside an asar archive. Plain files
 * also keep the Authenticode signatures on the engine .ps1 files verifiable in place.
 *
 * Signing: electron-builder signs every exe (app, uninstaller, installer, elevate helper)
 * via the CSC_LINK / CSC_KEY_PASSWORD env the driver script (build/dist.ps1) sets; the
 * afterPack hook then signs the engine .ps1 files with the same certificate — main.js
 * documents that Authenticode-signed engines are the only full fix for AllSigned policy
 * machines. Swap to a real certificate with FF_CSC_LINK / FF_CSC_PASSWORD (docs/signing.md);
 * nothing else changes.
 */
const path = require('path');

// The publisher name electron-updater expects on a downloaded update's signature. Must
// match the signing certificate's CN — swapped alongside the certificate itself.
const DEV_PUBLISHER = 'FrameForge Development Signing (untrusted test certificate)';
const publisherName = process.env.FF_PUBLISHER_NAME
  || (process.env.FF_CSC_LINK ? null : DEV_PUBLISHER);

/** @type {import('electron-builder').Configuration} */
module.exports = {
  appId: 'dev.frameforge.app',
  productName: 'FrameForge',
  copyright: 'Copyright © 2026 FrameForge',
  directories: { output: 'dist', buildResources: 'build' },
  asar: false,
  compression: 'maximum',
  // The app's UI is English-only (README: targets English-language Windows 11); the other
  // 54 Chromium locale packs were 43 MB unpacked of dead weight in every download.
  electronLanguages: ['en-US'],
  files: [
    'electron/**/*',
    'src/**/*',
    'engine/**/*',
    '!engine/test/**',
    'data/**/*',
    '!data/state/**',
    'resources/**/*',
    'package.json',
    '!**/*.map',        // sourcemaps in the updater's node_modules — ~1 MB a user never needs
  ],
  afterPack: path.join(__dirname, 'build', 'afterPack.js'),
  win: {
    target: [{ target: 'nsis', arch: ['x64'] }],
    icon: 'build/icon.png',
    ...(publisherName ? { signtoolOptions: { publisherName: [publisherName] } } : {}),
  },
  nsis: {
    oneClick: true,
    perMachine: false,
    runAfterFinish: true,
    deleteAppDataOnUninstall: false,
    artifactName: 'FrameForgeSetup.${ext}',
    shortcutName: 'FrameForge',
    uninstallDisplayName: 'FrameForge',
  },
  publish: [{ provider: 'github', owner: 'aaljarrah', repo: 'fps-booster' }],
};
