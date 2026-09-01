'use strict';
/* electron-builder afterPack hook: Authenticode-sign the PowerShell engines inside the
 * packed app directory, with the same certificate that signs the exes.
 *
 * Runs after the app directory is assembled and before NSIS wraps it, so the installer
 * carries already-signed engines. Signing resolution mirrors build/dist.ps1:
 *   FF_CSC_LINK / FF_CSC_PASSWORD  → a real purchased certificate
 *   otherwise                      → the local dev certificate from build/ensure-dev-cert.ps1
 * The hook FAILS THE BUILD if signing fails — an unsigned engine is a silently dead app on
 * AllSigned-policy machines (see electron/main.js), which is a ship blocker, not a warning.
 */
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');

module.exports = async function afterPack(context) {
  if (context.electronPlatformName !== 'win32') return;

  // electron-builder signs every exe it finds — including Intel's PresentMon.exe, whose
  // VALID Intel signature it replaces with ours. That is a strict trust downgrade (and
  // with the dev cert, Valid → untrusted). Restore the vendor-signed original byte for
  // byte; it is verified below like everything else. nvidiaProfileInspector.exe ships
  // unsigned upstream, so OUR signature on it is an upgrade and is kept.
  const presentMonSrc = path.join(__dirname, '..', 'resources', 'PresentMon.exe');
  const presentMonPacked = path.join(context.appOutDir, 'resources', 'app', 'resources', 'PresentMon.exe');
  if (fs.existsSync(presentMonSrc) && fs.existsSync(presentMonPacked)) {
    fs.copyFileSync(presentMonSrc, presentMonPacked);
    console.log('  • restored vendor-signed PresentMon.exe (Intel signature kept, not replaced)');
  }

  const engineDir = path.join(context.appOutDir, 'resources', 'app', 'engine');
  if (!fs.existsSync(engineDir)) {
    throw new Error(`afterPack: packed engine dir missing at ${engineDir} — files config changed?`);
  }

  const buildDir = __dirname;
  let pfx = process.env.FF_CSC_LINK || '';
  let passwordFile;
  if (pfx) {
    // Real certificate: password comes via env; hand it to the signer through a temp file
    // so it never appears on a command line.
    passwordFile = path.join(context.outDir, '.ff-csc-password.tmp');
    fs.writeFileSync(passwordFile, process.env.FF_CSC_PASSWORD || '', { encoding: 'ascii' });
  } else {
    pfx = path.join(buildDir, 'certs', 'frameforge-dev.pfx');
    passwordFile = path.join(buildDir, 'certs', 'frameforge-dev.pfx.password');
    if (!fs.existsSync(pfx) || !fs.existsSync(passwordFile)) {
      throw new Error('afterPack: no signing certificate. Run build/ensure-dev-cert.ps1 (or set FF_CSC_LINK / FF_CSC_PASSWORD).');
    }
  }

  try {
    const out = execFileSync('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(buildDir, 'sign-engine.ps1'),
      '-PfxPath', pfx,
      '-PasswordFile', passwordFile,
      '-EngineDir', engineDir,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    console.log(`  • ${out.trim().split(/\r?\n/).join('\n  • ')}`);

    // Electron's runtime DLLs (ffmpeg, libEGL, libGLESv2, vk_swiftshader, vulkan-1) ship
    // unsigned and electron-builder only signs .exe files. Discord signs every PE it
    // ships; so do we. Vendor-signed DLLs are left untouched.
    const dllOut = execFileSync('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(buildDir, 'sign-unsigned-dlls.ps1'),
      '-PfxPath', pfx,
      '-PasswordFile', passwordFile,
      '-AppDir', context.appOutDir,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    console.log(`  • ${dllOut.trim().split(/\r?\n/).join('\n  • ')}`);
  } finally {
    if (process.env.FF_CSC_LINK) { try { fs.unlinkSync(passwordFile); } catch (_) { /* best effort */ } }
  }
};
