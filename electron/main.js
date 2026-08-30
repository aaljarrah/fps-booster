'use strict';
const { app, BrowserWindow, ipcMain, shell, Tray, Menu, nativeImage, nativeTheme, dialog, desktopCapturer } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile, spawn } = require('child_process');

const ROOT = path.join(__dirname, '..');
const ENGINE = path.join(ROOT, 'engine');
const PS = process.env.SystemRoot
  ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  : 'powershell.exe';

// Solid Fluent grounds. These are the SolidBackgroundFillColorBase values the renderer
// paints; the native window uses the same pair so a repaint-before-first-frame, a
// dropped Mica backdrop, or a resize never shows an unpainted (black) window.
const SOLID_DARK = '#202020';
const SOLID_LIGHT = '#F3F3F3';
const solidBase = () => (nativeTheme.shouldUseDarkColors ? SOLID_DARK : SOLID_LIGHT);

let win = null;
let tray = null;

/* ===========================================================================
   PowerShell execution policy — MEASURED, then VERIFIED BY EXECUTION.

   -ExecutionPolicy Bypass sets only the PROCESS scope, and the documented precedence is
   MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine. A Group Policy value
   therefore OVERRIDES our command line: under "Turn on Script Execution = AllSigned" (or
   Restricted) every unsigned FrameForge .ps1 is refused, stdout is empty, and every engine
   call fails with no stated reason. So we measure the policy up front (with -Command, which
   execution policy does not gate) and, when a policy scope blocks -File, invoke the engines
   through a scriptblock built from the file's TEXT instead.

   CORRECTION (this comment used to be wrong, and the code was wrong with it). The previous
   version asserted that a scriptblock "is not a 'script file' as far as execution policy is
   concerned" and stopped there. Half true, wholly wrong: every engine's first executable
   line is `. (Join-Path $PSScriptRoot '_lib.ps1')`, and dot-sourcing a .ps1 FILE is exactly
   what execution policy gates. Reproduced against the shipped psArgsFor, under a policy
   scope our -ExecutionPolicy cannot override: `health.ps1 -Action list` returned 0 bytes on
   stdout, exit 0 and EMPTY stderr — a silently dead app, in the one situation the fallback
   existed for.

   So the fallback now loads _lib.ps1 as a scriptblock too and rewrites the engine's own
   dot-source site to `. $FFLibBlock`. Nothing is dot-sourced from a file; the only thing
   read from disk is text. If a future engine grows a file dot-source this rewrite does not
   recognise, the residual guard below refuses to run it and says so in the standard JSON
   error shape — it never returns empty stdout and lets the UI invent a reason.

   Nothing here is assumed. At startup FrameForge RUNS the cheapest real engine call
   (health.ps1 -Action list) through exactly the argv it intends to use; only a mode that
   actually produced parseable JSON is kept, and if the preferred mode fails the other is
   tried. If neither works, psPolicy.engineUsable is false and the UI carries a blocking
   banner instead of ten pages of unexplained blanks.

   Honest limits, stated in code rather than assumed away:
     * ConstrainedLanguage (WDAC / AppLocker) still blocks the engines outright. They detect
       that themselves and emit errorCode 'constrained-language'; the probe surfaces it.
     * repair.ps1 re-invokes health.ps1 as a CHILD process with -File. That inner call is
       outside this host's control and still fails under a blocking policy scope, so in
       'scriptblock' mode repair DETECTION degrades to "could not determine" — which
       repair.ps1 turns into a refusal with a named reason, not a false "nothing is broken".
     * The only fix that removes all of this is Authenticode-signing the engine .ps1 files
       at build time.
   =========================================================================== */
const ENGINE_SCRIPTS = ['_lib.ps1', 'engine.ps1', 'sysinfo.ps1', 'nvidia.ps1', 'measure.ps1',
  'procs.ps1', 'health.ps1', 'repair.ps1', 'image.ps1'];

// Mark-of-the-Web: a ZIP-extracted copy carries an NTFS Zone.Identifier stream, which a
// GPO-set RemoteSigned policy refuses to run from a file. Detection only — FrameForge
// does not strip the stream by itself (that would modify the user's files without
// asking); the scriptblock path below sidesteps MOTW entirely, and the UI reports it.
function engineHasMotw() {
  for (const s of ENGINE_SCRIPTS) {
    try { fs.readFileSync(`${path.join(ENGINE, s)}:Zone.Identifier`); return true; } catch (_) { /* no stream */ }
  }
  return false;
}

const psPolicy = {
  checked: false,          // false until the policy probe has run — never assume "fine"
  scopes: null,            // { MachinePolicy: 'Undefined', ... }
  blocked: false,          // a policy scope refuses our unsigned script files
  blockingScope: null,
  blockingValue: null,
  motw: false,
  mode: 'file',            // 'file' | 'scriptblock' — the PREFERRED mode until verified
  error: null,
  message: null,
  // --- verification by execution (doctrine rule 2: never report what you did not measure) ---
  probeRan: false,         // false = the engine-invocation probe has not finished yet
  engineUsable: null,      // true / false / null = not measured yet. NEVER defaults to true.
  modeVerified: false,     // true once `mode` is the mode that actually produced JSON
  attempts: null,          // [{ mode, ok, stdoutBytes, exitCode, stderr, errorCode }]
  probeError: null,
};

function detectExecutionPolicy() {
  return new Promise((resolve) => {
    psPolicy.motw = engineHasMotw();
    const cmd = 'Get-ExecutionPolicy -List | ForEach-Object { [pscustomobject]@{ Scope = [string]$_.Scope; Policy = [string]$_.ExecutionPolicy } } | ConvertTo-Json -Compress';
    execFile(PS, ['-NoProfile', '-Command', cmd], { windowsHide: true, timeout: 20000 }, (err, out) => {
      psPolicy.checked = true;
      if (err || !String(out || '').trim()) {
        // Could not determine. Say so — do not silently claim the policy is fine.
        psPolicy.error = (err && err.message) || 'Get-ExecutionPolicy produced no output.';
        psPolicy.message = 'FrameForge could not read this machine\u2019s PowerShell execution policy, so it cannot tell you in advance whether Group Policy will block the engine.';
        resolve(psPolicy); return;
      }
      let rows;
      try { rows = JSON.parse(String(out).trim()); } catch (e) { rows = null; }
      if (!rows) { psPolicy.error = 'Could not parse Get-ExecutionPolicy output.'; resolve(psPolicy); return; }
      if (!Array.isArray(rows)) rows = [rows];
      const scopes = {};
      for (const r of rows) if (r && r.Scope) scopes[String(r.Scope)] = String(r.Policy);
      psPolicy.scopes = scopes;
      for (const scope of ['MachinePolicy', 'UserPolicy']) {
        const v = scopes[scope];
        if (v === 'Restricted' || v === 'AllSigned') {
          psPolicy.blocked = true; psPolicy.blockingScope = scope; psPolicy.blockingValue = v; break;
        }
        // RemoteSigned only blocks files that still carry Mark-of-the-Web.
        if (v === 'RemoteSigned' && psPolicy.motw) {
          psPolicy.blocked = true; psPolicy.blockingScope = scope; psPolicy.blockingValue = v; break;
        }
      }
      if (psPolicy.blocked) {
        psPolicy.mode = 'scriptblock';
        psPolicy.message = `Windows Group Policy (Turn on Script Execution = ${psPolicy.blockingValue}, ${psPolicy.blockingScope} scope) blocks FrameForge's PowerShell engine files. "-ExecutionPolicy Bypass" cannot override a policy scope, so FrameForge is running the engines from memory instead. If an engine still returns nothing, the remaining fix is to Authenticode-sign the engine scripts.`;
      }
      resolve(psPolicy);
    });
  });
}

// Quote a string as a PowerShell single-quoted literal.
const psq = (s) => `'${String(s).replace(/'/g, "''")}'`;

/* Regexes handed to .NET inside the child. Kept as String.raw so the pattern that reaches
   PowerShell is exactly what is written here — a hand-escaped copy of these is precisely
   how a previous harness silently tested the wrong thing.

   RE_LIB       the ONE shape every engine uses to load the shared library.
   RE_RESIDUAL  any dot-source of a .ps1 still left after the rewrite. This is the loud
                failure: it means an engine loads a file we did not neutralise, so under a
                blocking policy scope it would die with empty stdout. We refuse instead. */
const RE_LIB = String.raw`\.\s*\(\s*Join-Path\s+\$\{?PSScriptRoot\}?\s+'_lib\.ps1'\s*\)`;
const RE_RESIDUAL = String.raw`(?m)^\s*(?:try\s*\{\s*)?\.\s+(?!\$FFLibBlock\b)[^\r\n]*\.ps1`;
const RE_PSSCRIPTROOT = String.raw`\$\{?PSScriptRoot\}?\b`;
const RE_PSCOMMANDPATH = String.raw`\$\{?PSCommandPath\}?\b`;

/** argv for one engine call in an explicit mode. `psArgsFor` uses the app's current mode. */
function psArgsForMode(mode, script, args) {
  if (mode !== 'scriptblock') {
    return ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
  }
  // Parameter NAMES pass through bare; everything else is a quoted literal, so a
  // renderer-supplied value can never become a switch.
  const argExpr = args.map((a) => (/^-[A-Za-z][A-Za-z0-9]*$/.test(String(a)) ? String(a) : psq(a))).join(' ');
  const libPath = path.join(ENGINE, '_lib.ps1');
  // The residual-guard document is a fixed JSON literal, not ConvertTo-Json: it has to be
  // writable in ConstrainedLanguage too, where [ordered] and method calls are refused.
  const scriptJs = JSON.stringify(path.basename(script));
  const residualJson = JSON.stringify({
    ok: false,
    errorCode: 'policy-file-dotsource',
    error: `FrameForge is running its engines from memory because a policy scope blocks script FILES, but ${path.basename(script)} still loads another .ps1 from disk, which that same policy would refuse. FrameForge did not run it, and nothing here is a statement about your PC. Fix: Authenticode-sign the engine scripts, or relax "Turn on Script Execution".`,
  }).replace(/'/g, "''");
  // A file we cannot READ is a different failure from a file the policy refuses to RUN, and
  // it has to say so rather than dying with an unexplained PowerShell exception.
  const missingLibJson = JSON.stringify({
    ok: false, errorCode: 'engine-file-unreadable',
    error: `FrameForge could not read its shared engine library at ${libPath}. Nothing was run and nothing here is a statement about your PC. Reinstall FrameForge, or check that this folder is not blocked by security software.`,
  }).replace(/'/g, "''");
  const missingScriptJson = JSON.stringify({
    ok: false, errorCode: 'engine-file-unreadable',
    error: `FrameForge could not read its engine script at ${script}. Nothing was run and nothing here is a statement about your PC. Reinstall FrameForge, or check that this folder is not blocked by security software.`,
  }).replace(/'/g, "''");
  // PowerShell sets $PSScriptRoot/$PSCommandPath for EVERY scriptblock invocation — to
  // the empty string when there is no backing file — so a parent-scope assignment is
  // shadowed and the engines' `. (Join-Path $PSScriptRoot '_lib.ps1')` would break
  // (measured: it does). The variable references are therefore rewritten to
  // $FFPSScriptRoot / $FFPSCommandPath, which ARE inherited by the child scope. This is a
  // rename, not a literal splice, so it stays correct inside "$PSScriptRoot\x" strings.
  //
  // The _lib rewrite happens FIRST, while the dot-source still says $PSScriptRoot.
  const parts = [
    `$FFPSScriptRoot = ${psq(ENGINE)}`,
    `$FFPSCommandPath = ${psq(script)}`,
    // _lib.ps1 becomes a scriptblock as well, so the library is loaded WITHOUT touching a
    // script file. Dot-sourcing the scriptblock at the engine's own former dot-source site
    // keeps the library's `$script:` variables in exactly the scope they had before.
    `$ffLibText = Get-Content -Raw -LiteralPath ${psq(libPath)} -ErrorAction SilentlyContinue`,
    `if (-not $ffLibText) { Write-Output '${missingLibJson}'; exit 5 }`,
    `$FFLibBlock = [scriptblock]::Create($ffLibText)`,
    `$ffSrc = Get-Content -Raw -LiteralPath ${psq(script)} -ErrorAction SilentlyContinue`,
    `if (-not $ffSrc) { Write-Output '${missingScriptJson}'; exit 5 }`,
    `$ffSrc = [regex]::Replace($ffSrc, ${psq(RE_LIB)}, ${psq('. $FFLibBlock')})`,
    `$ffSrc = [regex]::Replace($ffSrc, ${psq(RE_PSSCRIPTROOT)}, ${psq('$FFPSScriptRoot')}, 'IgnoreCase')`,
    `$ffSrc = [regex]::Replace($ffSrc, ${psq(RE_PSCOMMANDPATH)}, ${psq('$FFPSCommandPath')}, 'IgnoreCase')`,
    // Loud failure, never silence: a file dot-source we did not rewrite would be refused by
    // the very policy this mode exists for, and the engine would exit with empty stdout.
    `if ([regex]::IsMatch($ffSrc, ${psq(RE_RESIDUAL)})) { Write-Output '${residualJson}'; ` +
      `[Console]::Error.WriteLine('FrameForge: unrewritten file dot-source in ' + ${scriptJs}); exit 4 }`,
    // DOT-SOURCED, not called with `&`. This is a correctness requirement, not a style
    // choice, and it was measured both ways.
    //
    //   `& ([scriptblock]::Create($text))` runs the engine in a CHILD scope. An unqualified
    //   top-level assignment (`$OsInfoCache = ...`) then lands in that child scope, while
    //   `$script:OsInfoCache` resolves to the scope the scriptblock was *defined* in - and a
    //   dynamically created scriptblock has no backing script file, so `$script:` is the
    //   -Command host's own top-level scope. The two names stop being the same variable.
    //   repair.ps1 alone assigns nine such variables unqualified and reads them back through
    //   `$script:`; under `&` every one of them reads as $null, which is the silent
    //   half-populated document this mode must never produce.
    //
    //   `. ([scriptblock]::Create($text))` runs it in the CALLER's scope, which under
    //   -Command is the top-level scope that `$script:` also resolves to. Measured against
    //   the real engines under a policy that refuses script files: identical JSON to -File,
    //   parameters bind the same way, and `exit <n>` still sets the process exit code.
    //
    // Verified by engine/test/cases/56-policy.ps1, which drives THIS function's output.
    `. ([scriptblock]::Create($ffSrc)) ${argExpr}`,
  ];
  return ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', parts.join('; ')];
}

function psArgsFor(script, args) {
  return psArgsForMode(psPolicy.mode, script, args);
}

/* Offline self-test hook, used by engine/test/cases/56-policy.ps1.

   The suite has to exercise the REAL argv builder. A second copy of psArgsForMode living in
   a test file is precisely the "the catalog says one thing and the engine runs another"
   failure this project treats as a release blocker, so the suite asks this file instead:

     node electron/main.js --ff-print-ps-argv <file|scriptblock> <script.ps1> [engine args...]

   prints {"mode":...,"exe":...,"args":[...]} on stdout and exits, before Electron is touched
   and before any window, tray, IPC handler or engine call exists. Nothing is executed here. */
if (process.argv.indexOf('--ff-print-ps-argv') !== -1) {
  const i = process.argv.indexOf('--ff-print-ps-argv');
  const rest = process.argv.slice(i + 1);
  const mode = rest[0] === 'scriptblock' ? 'scriptblock' : 'file';
  const scriptName = rest[1];
  if (!scriptName) {
    process.stdout.write(JSON.stringify({ ok: false, error: 'usage: --ff-print-ps-argv <file|scriptblock> <script.ps1> [args...]' }));
    process.exit(2);
  }
  process.stdout.write(JSON.stringify({
    ok: true,
    mode,
    exe: PS,
    args: psArgsForMode(mode, path.join(ENGINE, scriptName), rest.slice(2)),
  }));
  process.exit(0);
}

/* ---------------------------------------------------------------------------
   Engine-invocation verification.

   Get-ExecutionPolicy tells us what the policy SAYS. It does not tell us whether our argv
   actually produces a JSON document on this machine — WDAC, AppLocker, a partially
   Mark-of-the-Web'd copy, an AV/EDR script-block hook or a broken PowerShell install all
   answer that question differently. So we ask by running, and we keep only the mode that
   answered. `engineUsable` starts at null and only ever becomes true off a parsed document.
   --------------------------------------------------------------------------- */
let engineReady = null;              // Promise, resolved once the probe has finished
const PROBE_SCRIPT = 'health.ps1';   // the cheapest engine call that still loads _lib.ps1
const PROBE_ARGS = ['-Action', 'list'];

function rawEngineCall(mode, scriptName, args, timeout) {
  return new Promise((resolve) => {
    const script = path.join(ENGINE, scriptName);
    execFile(PS, psArgsForMode(mode, script, args),
      { maxBuffer: 4 * 1024 * 1024, windowsHide: true, timeout }, (err, stdout, stderr) => {
        const raw = String(stdout || '').trim();
        let json = null;
        try { json = JSON.parse(raw); } catch (e) { json = null; }
        resolve({ json, raw, stderr: String(stderr || '').trim(), err });
      });
  });
}

async function verifyEngineInvocation() {
  const preferred = psPolicy.mode;
  const order = preferred === 'scriptblock' ? ['scriptblock', 'file'] : ['file', 'scriptblock'];
  const attempts = [];
  for (const mode of order) {
    let r;
    try { r = await rawEngineCall(mode, PROBE_SCRIPT, PROBE_ARGS, 90000); }
    catch (e) { r = { json: null, raw: '', stderr: (e && e.message) || String(e), err: e }; }
    // What is being tested is "can this argv get a JSON document out of an engine on this
    // machine", so ANY parsed document counts — including an engine's own honest error
    // document, which proves the engine ran. Deliberately NOT keyed on health.ps1's exact
    // `list` fields: this file must not fail the whole app because another engine's catalog
    // changed shape. The two documents that do NOT count are the ones that mean the engine
    // could not run: our own residual-dot-source refusal, and ConstrainedLanguage.
    const doc = r.json;
    const isDoc = doc !== null && typeof doc === 'object';
    const cannotRun = isDoc && !Array.isArray(doc)
      && (doc.errorCode === 'policy-file-dotsource' || doc.errorCode === 'constrained-language');
    const ok = !!(isDoc && !cannotRun
      && (Array.isArray(doc) ? doc.length > 0 : Object.keys(doc).length > 0));
    attempts.push({
      mode, ok,
      stdoutBytes: Buffer.byteLength(r.raw, 'utf8'),
      exitCode: (r.err && r.err.code) != null ? r.err.code : 0,
      errorCode: (r.json && r.json.errorCode) || null,
      stderr: r.stderr.slice(0, 500),
    });
    if (ok) {
      psPolicy.mode = mode;
      psPolicy.modeVerified = true;
      psPolicy.engineUsable = true;
      psPolicy.probeRan = true;
      psPolicy.attempts = attempts;
      if (mode !== preferred) {
        psPolicy.message = `FrameForge's first way of starting its PowerShell engine (${preferred === 'file' ? 'running the script files directly' : 'running them from memory'}) produced nothing on this PC, so it switched to the other one, which was verified to work. Results below were measured through the working path.`;
      } else if (mode === 'scriptblock') {
        psPolicy.message = `${psPolicy.message || ''} FrameForge verified the from-memory path by running a real engine call, and it works. One part still cannot: the repair ladder starts a second PowerShell for its before/after health probe, and that inner call is still refused by the policy — those repairs will say "could not determine" rather than guess.`.trim();
      }
      return psPolicy;
    }
  }
  // Measured, and the answer is no. Say exactly that, and say what would fix it.
  psPolicy.probeRan = true;
  psPolicy.modeVerified = false;
  psPolicy.engineUsable = false;
  psPolicy.attempts = attempts;
  psPolicy.mode = preferred;
  const cl = attempts.find((a) => a.errorCode === 'constrained-language');
  const detail = attempts.map((a) => `${a.mode}: ${a.stdoutBytes} bytes, exit ${a.exitCode}${a.stderr ? ` — ${a.stderr}` : ''}`).join(' | ');
  psPolicy.probeError = detail;
  psPolicy.message = cl
    ? 'Application control (WDAC or AppLocker) is running PowerShell in ConstrainedLanguage on this PC. FrameForge’s engines need FullLanguage, so NOTHING on this PC has been measured and no page below is a statement about it. Ask whoever manages this machine to allow the FrameForge engine folder.'
    : `FrameForge could not get a usable answer out of PowerShell on this PC, in either of the two ways it knows. Nothing has been measured, so nothing shown below is a statement about this PC. What was tried — ${detail}. The usual causes are Group Policy script restrictions, application control (WDAC/AppLocker), or security software blocking PowerShell; Authenticode-signing the engine scripts fixes the policy case.`;
  return psPolicy;
}

/** Run a FrameForge PowerShell engine script and parse its JSON stdout.
 *  Failures are reported as what they actually were — timed out, output overflow,
 *  policy-blocked, unparseable — never as an undifferentiated "No output from engine."
 *  Every call waits for the invocation probe first, so no engine is ever launched through a
 *  mode that has not been shown to work on this machine. */
async function runPs(scriptName, args = [], { timeout = 60000 } = {}) {
  if (engineReady) { try { await engineReady; } catch (_) { /* probe failures are recorded in psPolicy */ } }
  return runPsNow(scriptName, args, { timeout });
}

function runPsNow(scriptName, args, { timeout = 60000 } = {}) {
  return new Promise((resolve) => {
    const script = path.join(ENGINE, scriptName);
    const full = psArgsFor(script, args);
    let timedOut = false;
    let timer = null;
    // We run our own timer instead of execFile's `timeout` so the whole PROCESS TREE
    // can be killed. execFile only signals powershell.exe; a native grandchild
    // (sfc.exe / Dism.exe / cscript.exe) would survive and keep mutating the system
    // unsupervised while the UI reported a plain failure.
    const child = execFile(PS, full, { maxBuffer: 1024 * 1024 * 16, windowsHide: true },
      (err, stdout, stderr) => {
        if (timer) clearTimeout(timer);
        const raw = (stdout || '').trim();
        if (raw) {
          try { resolve(JSON.parse(raw)); return; }
          catch (e) {
            resolve({
              ok: false, script: scriptName,
              error: `The ${scriptName} engine produced output FrameForge could not parse as JSON. Nothing here should be read as a statement about your PC.`,
              parseError: true, raw: raw.slice(0, 4000), stderr: (stderr || '').trim(),
            });
            return;
          }
        }
        const overflow = !!(err && err.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER');
        const secs = Math.round(timeout / 1000);
        let error;
        if (timedOut) {
          error = `The ${scriptName} engine did not finish within ${secs}s and was stopped, along with anything it had started. Nothing was measured, so nothing here is a statement about your PC.`;
        } else if (overflow) {
          error = `The ${scriptName} engine produced more than 16 MB of output and was cut off. This is a size problem, not a result.`;
        } else if (psPolicy.engineUsable === false) {
          // Measured at startup: PowerShell produces nothing usable here. Say that, not
          // "the engine returned no output and no error".
          error = `${psPolicy.message} (${scriptName} returned nothing.)`;
        } else if (psPolicy.blocked) {
          error = `${psPolicy.message} (${scriptName} returned nothing.)`;
        } else {
          error = (stderr || (err && err.message) || `The ${scriptName} engine returned no output and no error.`).toString().trim();
        }
        resolve({
          ok: false, script: scriptName, error,
          timedOut, timeoutMs: timeout, overflow,
          policyBlocked: !!psPolicy.blocked,
          engineUsable: psPolicy.engineUsable,
          code: err && err.code, killed: !!(err && err.killed), signal: (err && err.signal) || null,
          exe: PS,
        });
      });
    timer = setTimeout(() => {
      timedOut = true;
      // /T kills the whole tree, /F forces it. SIGTERM alone leaves native grandchildren.
      try { if (child.pid) execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }, () => {}); } catch (_) {}
      try { child.kill(); } catch (_) {}
    }, timeout);
  });
}

/* ===========================================================================
   WHO ARE WE RUNNING AS, vs. WHO IS AT THE KEYBOARD?

   `Start-Process -Verb RunAs` relaunches the WHOLE app elevated. On a PC whose interactive
   user is not an administrator — school, work and family machines, a large share of the
   population this app is for — UAC asks for a DIFFERENT account, and everything FrameForge
   then does runs as that helper. HKCU is the helper's profile, %LOCALAPPDATA% is the
   helper's folder. Four tweaks (Game DVR, Game Mode, visual effects, mouse acceleration)
   are per-user registry writes with requiresAdmin:false, so nothing blocked them: they were
   written into the ADMINISTRATOR's profile, reported as applied and verified, while the
   gamer's own profile was untouched — and the undo ledger went to the admin's
   %LOCALAPPDATA%, so a later unelevated "Revert all tweaks" found an empty ledger and
   reported success having undone nothing. That is doctrine rule 2 and rule 3 at once.

   The unelevated instance knows its own SID for certain, so it hands that SID to the
   elevated instance on the command line. engine.ps1 compares it with the token it is
   actually running under (and, when it was not passed one, falls back to the SID that owns
   the interactive session's shell) and REFUSES per-user operations on a mismatch rather
   than writing into a profile nobody asked about.
   =========================================================================== */
const SID_RE = /^S-1-[0-9-]{1,60}$/;
const ORIGIN_SID = (() => {
  for (const a of process.argv) {
    const m = /^--ff-origin-sid=(.+)$/.exec(String(a));
    if (m && SID_RE.test(m[1])) return m[1];
  }
  return null;
})();
// Measured, never assumed: null until engine.ps1 has actually answered.
let identity = null;

/** Every engine.ps1 call carries the pre-elevation SID when we have one. */
function engineArgs(args) {
  return ORIGIN_SID ? [...args, '-OriginSid', ORIGIN_SID] : args;
}

function currentUserSid() {
  return new Promise((resolve) => {
    execFile(PS, ['-NoProfile', '-Command',
      '([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value'],
      { windowsHide: true, timeout: 15000 }, (e, out) => {
        const s = String(out || '').trim();
        resolve(!e && SID_RE.test(s) ? s : null);
      });
  });
}

// Uses runPsNow, not runPs: this runs INSIDE the engineReady chain, and awaiting that
// promise from within it would deadlock the whole app.
async function refreshIdentity() {
  const r = await runPsNow('engine.ps1', engineArgs(['-Action', 'identity']), { timeout: 60000 });
  // Only a document that actually carries the fields counts as an answer.
  identity = (r && typeof r === 'object' && Object.prototype.hasOwnProperty.call(r, 'profileMismatch'))
    ? r
    : { measured: false, profileMismatch: null, reason: (r && (r.error || r.message)) || 'engine.ps1 -Action identity returned nothing usable.' };
  return identity;
}

function isElevated() {
  return new Promise((resolve) => {
    // No timeout here used to be able to wedge the whole first paint: aggressive AV/EDR
    // hooking CreateProcess can stall powershell.exe indefinitely. Least privilege is the
    // safe default and the UI has a complete non-admin path.
    execFile(PS, ['-NoProfile', '-Command',
      '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'],
      { windowsHide: true, timeout: 15000 }, (e, out) => {
        if (e) { resolve(false); return; }
        // Exact match. A stray banner line containing the word "true" must not promote
        // the user to administrator in the UI. (Boolean.ToString() is culture-invariant,
        // so this is not a localization dependency.)
        resolve(String(out || '').trim() === 'True');
      });
  });
}

/** Elevate by relaunching. Resolves { ok } / { ok:false, cancelled } — it does NOT quit
 *  optimistically: declining UAC used to close FrameForge 400 ms later with no warning. */
async function relaunchElevated() {
  // Captured BEFORE elevation, so it is certainly the interactive user's SID. The elevated
  // instance passes it to engine.ps1, which refuses per-user work if its own token differs.
  // If we cannot read it we say so and let engine.ps1 fall back to its own probe — we do
  // NOT pass a guess.
  const originSid = ORIGIN_SID || await currentUserSid();
  return new Promise((resolve) => {
    const exeEsc = String(process.execPath).replace(/'/g, "''");
    // Dev mode: process.argv[1] is '.', which does not resolve from the elevated
    // process's default working directory (C:\Windows\System32) — make it absolute.
    const args = process.defaultApp
      ? process.argv.slice(1).filter((a) => !/^--ff-origin-sid=/.test(String(a))).map((a) => path.resolve(a))
      : [];
    if (originSid) args.push(`--ff-origin-sid=${originSid}`);
    const argList = args.map((a) => `'${String(a).replace(/'/g, "''")}'`).join(',');
    const rootEsc = ROOT.replace(/'/g, "''");
    const start = argList
      ? `Start-Process -FilePath '${exeEsc}' -ArgumentList ${argList} -WorkingDirectory '${rootEsc}' -Verb RunAs -ErrorAction Stop`
      : `Start-Process -FilePath '${exeEsc}' -WorkingDirectory '${rootEsc}' -Verb RunAs -ErrorAction Stop`;
    // 1223 = ERROR_CANCELLED: the user dismissed the UAC prompt. That is a normal,
    // expected answer, so it gets its own exit code and its own message.
    const cmd = `try { ${start}; exit 0 } catch { ` +
      `$c = $_.Exception; while ($c -and -not ($c.PSObject.Properties['NativeErrorCode'])) { $c = $c.InnerException }; ` +
      `if ($c -and $c.NativeErrorCode -eq 1223) { exit 1223 }; Write-Error $_.Exception.Message; exit 1 }`;
    execFile(PS, ['-NoProfile', '-Command', cmd], { windowsHide: true, timeout: 120000 }, (err, _o, stderr) => {
      if (!err) {
        // The elevated instance is up; only now is it safe to close this one.
        setTimeout(() => app.quit(), 400);
        resolve({ ok: true });
        return;
      }
      if (err.code === 1223) {
        resolve({ ok: false, cancelled: true, error: 'Elevation was cancelled at the UAC prompt.' });
        return;
      }
      resolve({
        ok: false, cancelled: false,
        error: (String(stderr || '').trim() || err.message || 'The elevated instance could not be started.'),
      });
    });
  });
}

// Mica needs Windows 11 22H2+ (build 22621). Elsewhere we fall back to the solid
// SolidBackgroundFillColorBase the renderer paints by default — exactly what WinUI does.
function micaSupported() {
  if (process.platform !== 'win32') return false;
  const build = Number((os.release().split('.')[2] || 0));
  return build >= 22621;
}

/* Whether DWM will actually DRAW a backdrop is not a build number. Transparency effects
   can be off (the first setting every "speed up Windows" guide turns off — i.e. exactly
   this app's audience), a High Contrast theme can be active, or the session can be
   RDP/VDI with no composition. We read the real setting and re-read it when the theme
   changes; `null` means "could not determine", which is treated as "assume no backdrop"
   for the renderer's transparent-body class while the opaque floor stays painted either
   way. */
let transparencyOn = null;
function readTransparency() {
  return new Promise((resolve) => {
    if (process.platform !== 'win32') { transparencyOn = false; resolve(false); return; }
    execFile('reg.exe', ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize',
      '/v', 'EnableTransparency'], { windowsHide: true, timeout: 10000 }, (err, out) => {
      if (err) { transparencyOn = null; resolve(null); return; }
      // REG_DWORD prints as 0x0 / 0x1 — a number, not localized text.
      const m = /EnableTransparency\s+REG_DWORD\s+0x([0-9a-f]+)/i.exec(String(out || ''));
      transparencyOn = m ? parseInt(m[1], 16) !== 0 : null;
      resolve(transparencyOn);
    });
  });
}
// The composite the renderer needs: a backdrop is only actually drawn when the build
// supports it, transparency is on, and no High Contrast theme is overriding it.
function micaActive() {
  return micaSupported() && transparencyOn === true && !nativeTheme.shouldUseHighContrastColors;
}
function uiEnv() {
  return {
    mica: micaActive(),
    micaSupported: micaSupported(),
    transparency: transparencyOn,          // true / false / null = could not determine
    highContrast: nativeTheme.shouldUseHighContrastColors,
    dark: nativeTheme.shouldUseDarkColors,
    capture: !!process.env.FF_CAPTURE,
    psPolicy: {
      checked: psPolicy.checked, blocked: psPolicy.blocked, mode: psPolicy.mode,
      scope: psPolicy.blockingScope, value: psPolicy.blockingValue,
      motw: psPolicy.motw, message: psPolicy.message, error: psPolicy.error,
      // Measured by running a real engine call, not predicted from Get-ExecutionPolicy.
      // engineUsable === null means the probe has not finished — the UI must not claim
      // either answer while it is null.
      probeRan: psPolicy.probeRan, engineUsable: psPolicy.engineUsable,
      modeVerified: psPolicy.modeVerified, attempts: psPolicy.attempts,
      probeError: psPolicy.probeError,
    },
    // Who FrameForge is running as vs. who is sitting at the keyboard. Null until measured.
    identity: identity,
  };
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
  // capture black), so the default capture run uses the solid fallback — the same thing
  // WinUI paints when Mica is unavailable. FF_CAPTURE_MICA keeps the real Mica path and
  // grabs frames off the composited desktop surface instead (see cap() below), so the
  // branch real users get is not left permanently unphotographed.
  const micaCapture = !!process.env.FF_CAPTURE_MICA;
  const useMica = micaActive() && (!process.env.FF_CAPTURE || micaCapture);

  // Clamp to the display work area. 1280x800 DIP does not fit a 1920x1080 panel at 150%
  // (≈1280x672 work area) and minHeight 640 does not fit 1366x768 at 125% (≈1092x574) —
  // on those machines the bottom strip, where the primary buttons live, was unreachable.
  let wa = { width: 1280, height: 800 };
  try { wa = require('electron').screen.getPrimaryDisplay().workAreaSize; } catch (_) { /* keep defaults */ }
  const width = Math.max(480, Math.min(1280, wa.width - 40));
  const height = Math.max(400, Math.min(800, wa.height - 40));

  const opts = {
    width,
    height,
    minWidth: Math.min(800, wa.width),
    minHeight: Math.min(500, wa.height),
    show: false,
    title: 'FrameForge',
    titleBarStyle: 'hidden',
    titleBarOverlay: overlayColors(),
    // An opaque floor on BOTH branches. Electron's frameless-Mica bugs (electron#38743,
    // #46753) can drop the DWM backdrop on a maximize/restore cycle; with no
    // backgroundColor and a transparent body the window then renders black.
    backgroundColor: solidBase(),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  };
  if (useMica) {
    opts.backgroundMaterial = 'mica';         // never combine with transparent: true
  }
  win = new BrowserWindow(opts);
  win.loadFile(path.join(ROOT, 'src', 'index.html'));
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });

  // Re-assert the backdrop after the window-state transitions the known Electron bugs
  // hang off. Costs nothing on healthy builds; turns a black window into a solid Fluent
  // one on the buggy path.
  for (const ev of ['maximize', 'unmaximize', 'restore', 'minimize']) {
    win.on(ev, () => { try { win.setBackgroundMaterial(useMica ? 'mica' : 'none'); } catch (_) {} });
  }

  // Keep caption symbols, the native window background and the renderer's backdrop
  // assumption in sync with the Windows app theme. The DOM already follows
  // prefers-color-scheme; without this the NATIVE background stayed at its
  // creation-time value and flashed the wrong colour on every resize and restore.
  nativeTheme.on('updated', () => {
    if (!win) return;
    try { win.setTitleBarOverlay(overlayColors()); } catch (_) { /* best effort */ }
    try { win.setBackgroundColor(solidBase()); } catch (_) { /* best effort */ }
    // Transparency effects / High Contrast can change at runtime; re-read and tell the
    // renderer, which adds or removes body.mica over the always-painted solid ground.
    readTransparency().then(() => {
      if (!win || win.isDestroyed()) return;
      try { win.setBackgroundMaterial(micaActive() && (!process.env.FF_CAPTURE || micaCapture) ? 'mica' : 'none'); } catch (_) {}
      try { win.webContents.send('ui:env-changed', uiEnv()); } catch (_) {}
    });
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
    // FF_CAPTURE_MICA: read the COMPOSITED desktop surface, which includes the DWM
    // backdrop capturePage() cannot see. Fails as loudly as the rest of the harness when
    // the window cannot be matched, so a Mica run can never silently degrade to nothing.
    const grabMicaFrame = async () => {
      // desktopCapturer only enumerates windows that are actually on screen, so the
      // window has to be shown and fronted before the composited surface exists at all.
      let seen = 'none';
      for (let attempt = 0; attempt < 4; attempt++) {
        try { if (!win.isVisible()) win.show(); if (win.isMinimized()) win.restore(); win.moveTop(); win.focus(); } catch (_) {}
        await wait(attempt === 0 ? 500 : 800);
        const b = win.getBounds();
        const sources = await desktopCapturer.getSources({
          types: ['window'],
          thumbnailSize: { width: Math.max(1, b.width), height: Math.max(1, b.height) },
          fetchWindowIcons: false,
        });
        seen = sources.map((s) => s.name).join(' | ') || 'none';
        const title = win.getTitle();
        const src = sources.find((s) => s.name === title) || sources.find((s) => (s.name || '').includes('FrameForge'));
        if (src && !src.thumbnail.isEmpty()) return src.thumbnail;
      }
      // Some Windows/Electron combinations do not enumerate a frameless window as a
      // capturable window source at all. The composited DESKTOP still contains it, so
      // fall back to a screen grab cropped to the window rect — same pixels, same
      // backdrop. The window is kept on top for the duration so nothing occludes it.
      try {
        const scr = require('electron').screen;
        const b = win.getBounds();
        const disp = scr.getDisplayMatching(b);
        const sf = disp.scaleFactor || 1;
        const sources = await desktopCapturer.getSources({
          types: ['screen'],
          thumbnailSize: { width: Math.round(disp.size.width * sf), height: Math.round(disp.size.height * sf) },
        });
        const s = sources.find((x) => String(x.display_id) === String(disp.id)) || sources[0];
        if (s && !s.thumbnail.isEmpty()) {
          const cropped = s.thumbnail.crop({
            x: Math.max(0, Math.round((b.x - disp.bounds.x) * sf)),
            y: Math.max(0, Math.round((b.y - disp.bounds.y) * sf)),
            width: Math.max(1, Math.round(b.width * sf)),
            height: Math.max(1, Math.round(b.height * sf)),
          });
          if (!cropped.isEmpty()) return cropped;
        }
        seen += ` ;; screen sources: ${sources.map((x) => x.name).join(' | ') || 'none'}`;
      } catch (e) { seen += ` ;; screen fallback threw: ${(e && e.message) || e}`; }
      // Still loud: a Mica run that cannot photograph the Mica window produces no
      // evidence, and silently substituting the solid path is exactly what this mode exists
      // to stop. (The window must be visible and un-occluded for this mode to work.)
      fail(`FF_CAPTURE_MICA: could not capture the composited FrameForge window after 4 attempts (window sources: ${seen}). The FrameForge window must be visible, un-occluded and not minimised for OS-level capture.`);
      return null;
    };
    const cap = async (name, view) => {
      const active = await js(`(document.querySelector('.view.active') || { id: 'none' }).id`);
      if (active !== `view-${view}`) fail(`capturing ${name}: active view is "${active}", expected "view-${view}"`);
      let png = null, hash = null;
      for (let attempt = 0; attempt < 3; attempt++) {
        await paintBarrier();
        const img = micaCapture ? await grabMicaFrame() : await win.webContents.capturePage();
        if (img.isEmpty()) fail(`${micaCapture ? 'desktopCapturer' : 'capturePage'} returned an empty image for ${name}`);
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
        // OS-level capture photographs the desktop, so the window has to be on it —
        // visible, fronted and un-occluded — for the whole run.
        if (micaCapture) { try { win.show(); win.moveTop(); win.focus(); win.setAlwaysOnTop(true, 'screen-saver'); } catch (_) {} }
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
        await js("(() => { document.querySelectorAll('.toast-host, .toast-stack').forEach((ts) => { ts.style.display = 'none'; }); return true; })()");
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

// The tray icon is embedded here rather than loaded from src/assets/tray.png: that file
// does not ship, so createFromPath returned an empty image and the tray entry was
// invisible on every install — an invisible menu whose entries still worked. This is the
// same rounded-square-plus-bolt mark as the app icon in src/index.html, rasterised to a
// 32x32 white RGBA PNG (nativeImage cannot decode SVG, which is why this is not one).
const TRAY_ICON_DATA_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABBUlEQVR42s2X3Q2EIAzHuwRvbOAEvN0S7OMEvrkES/jmIgxSNVdyyHkXA6W1yT8aP9qfpakFEBEuNCCi389HJnny+RWrvGB2zYi40JELIPdpfgG86KGxfIhJhnwvFOsEYMobHZU+1OQAKd0gpLQskApu6ZT2f8txxByAKnRudOgq3jliesgqtSV4qFyGkQMgUhZVACZ8mwqAx485aQBLqU8G0gABzyYK4IvgQRKgTP1hK0Hlsr0AytRfWewFYAkgV7wA8JJ9ABvqgR0gSjciVwA4zU44abTiqTL1bACh4T/AArBWpp4VADgAakYye7Pb3RrJ1IdS9bH8ERsT9a3ZIzanKtvzDTaBm+yiUb87AAAAAElFTkSuQmCC';

function createTray() {
  try {
    let icon = nativeImage.createFromDataURL(TRAY_ICON_DATA_URL);
    if (icon.isEmpty()) {
      const p = path.join(ROOT, 'src', 'assets', 'tray.png');
      icon = nativeImage.createFromPath(p);
      if (icon.isEmpty()) console.error(`[tray] no usable icon (generated icon empty; ${p} missing or unreadable) — the tray entry will be blank.`);
    }
    tray = new Tray(icon);
    tray.setToolTip('FrameForge — FPS optimizer');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open FrameForge', click: () => { if (win) { win.show(); win.focus(); } else createWindow(); } },
      { type: 'separator' },
      { label: 'Revert all tweaks…', click: () => trayRevertAll() },
      { label: 'Quit', click: () => app.quit() },
    ]));
    tray.on('double-click', () => { if (win) { win.show(); win.focus(); } });
  } catch (e) { console.error(`[tray] could not be created: ${(e && e.message) || e}`); }
}

// Bulk state change → consent-gated (doctrine rule 4) and its outcome reported. It used
// to run straight off a misclick on an invisible icon and say nothing either way.
async function trayRevertAll() {
  const { response } = await dialog.showMessageBox({
    type: 'warning',
    buttons: ['Cancel', 'Revert all tweaks'],
    defaultId: 0,
    cancelId: 0,
    title: 'Revert all tweaks',
    message: 'Undo every tweak FrameForge applied?',
    detail: 'Each setting is restored to the exact value FrameForge captured before it was changed. Repairs and NVIDIA settings are not affected.',
  });
  if (response !== 1) return;
  const r = await runPs('engine.ps1', engineArgs(['-Action', 'revert-all']), { timeout: 300000 });
  const ok = !!(r && r.ok !== false);
  if (win && !win.isDestroyed()) {
    win.show(); win.focus();
    try { win.webContents.send('tray:revert-all-result', r); } catch (_) {}
  } else {
    // No window to toast into — say it in the OS notification instead of nowhere.
    try {
      const { Notification } = require('electron');
      if (Notification.isSupported()) {
        new Notification({
          title: ok ? 'Reverted all tweaks' : 'Revert all tweaks failed',
          body: ok ? (r && r.count != null ? `${r.count} change(s) undone.` : 'Done.') : String((r && (r.message || r.error)) || 'Unknown error.'),
        }).show();
      }
    } catch (_) {}
  }
}

// Read + parse a JSON file, tolerating a UTF-8 BOM (PowerShell-written files have one; Node's
// JSON.parse rejects the leading ﻿).
function readJsonFile(rel) {
  let raw = fs.readFileSync(path.join(ROOT, rel), 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return JSON.parse(raw);
}

// ---------------- IPC ----------------
ipcMain.handle('ui:env', () => uiEnv());
// sysinfo reads three HKCU values; it needs the same pre-elevation SID engine.ps1 gets so it
// can tell whose profile they came from instead of publishing another account's settings.
ipcMain.handle('sys:info', () => runPs('sysinfo.ps1', engineArgs([])));
ipcMain.handle('sys:isAdmin', () => isElevated());
ipcMain.handle('sys:relaunchElevated', () => relaunchElevated());

ipcMain.handle('tweaks:list', () => {
  try { return readJsonFile('data/tweaks.json'); }
  catch (e) { return { ok: false, error: e.message, tweaks: [] }; }
});
ipcMain.handle('tweaks:detectAll', () => runPs('engine.ps1', engineArgs(['-Action', 'detect-all'])));
ipcMain.handle('tweaks:apply', (_e, id, dry) => runPs('engine.ps1', engineArgs(['-Action', 'apply', '-Id', id, ...(dry ? ['-DryRun'] : [])])));
ipcMain.handle('tweaks:revert', (_e, id) => runPs('engine.ps1', engineArgs(['-Action', 'revert', '-Id', id])));
ipcMain.handle('tweaks:revertAll', () => runPs('engine.ps1', engineArgs(['-Action', 'revert-all'])));
ipcMain.handle('tweaks:restorePoint', () => runPs('engine.ps1', engineArgs(['-Action', 'restore-point']), { timeout: 120000 }));
// Who the engine is running as vs. who is at the keyboard. Cached after the first answer;
// the identity of a running process cannot change underneath us.
ipcMain.handle('sys:identity', async () => {
  if (engineReady) { try { await engineReady; } catch (_) {} }
  return identity || await refreshIdentity();
});

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
// 90s was under 10x headroom on a probe set with several known multi-minute worst cases
// (offline Test-NetConnection, a stalled Software Licensing provider, Get-Printer against
// unreachable printers, Get-WinEvent over 30 days on a mechanical drive). Blowing the
// budget threw away every category that HAD completed, so the budget is now generous and
// a timeout is reported as a timeout.
ipcMain.handle('health:scan', (_e, deep) => runPs('health.ps1', ['-Action', 'scan', ...(deep ? ['-Deep'] : [])], { timeout: deep ? 900000 : 300000 }));
ipcMain.handle('health:probe', (_e, category, deep) =>
  runPs('health.ps1', ['-Action', 'probe', '-Category', String(category || ''), ...(deep ? ['-Deep'] : [])], { timeout: deep ? 600000 : 120000 }));
ipcMain.handle('health:catalog', () => {
  try { return readJsonFile('data/health-checks.json'); }
  catch (e) { return { ok: false, error: e.message, checks: [] }; }
});

// ---------------- Repair ladder ----------------
ipcMain.handle('repair:list', () => runPs('repair.ps1', ['-Action', 'list'], { timeout: 300000 }));
ipcMain.handle('repair:preflight', (_e, id) => runPs('repair.ps1', ['-Action', 'preflight', '-Id', String(id || '')], { timeout: 300000 }));
// 2 h, not 30 min: `sfc /scannow` routinely takes 30–60 minutes on a mechanical drive and
// DISM /RestoreHealth over a slow link can exceed an hour. A repair that is honestly slow
// must not be truncated — and when the budget IS hit, runPs kills the whole process tree
// so a native grandchild cannot keep modifying the system unsupervised.
ipcMain.handle('repair:run', (_e, id, opts) => {
  const o = opts || {};
  return runPs('repair.ps1', ['-Action', 'run', '-Id', String(id || ''),
    ...(o.dryRun ? ['-DryRun'] : []), ...(o.force ? ['-Force'] : []),
    // The documented opt-out for the enforced System Restore checkpoint. Without this
    // the five restorePoint:"enforced" repairs were unreachable from the GUI on any
    // machine where System Protection is off or policy-blocked.
    ...(o.noRestorePoint ? ['-NoRestorePoint'] : [])], { timeout: 7200000 });
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
// Media parameters are validated here, not merely stringified. execFile passes argv
// separately rather than through a shell, so switch injection is already impossible —
// but nothing in this function used to ENFORCE that, and the comment claimed it did.
// These checks make the claim true independently of the spawn mechanism, and they turn
// a nonsense path into a named error the UI can explain instead of an engine stack trace.
const MEDIA_EXT = ['.iso', '.esd', '.wim'];
function checkMediaPath(v, { requireFile }) {
  const s = String(v);
  if (!s.trim()) return 'empty';
  if (s.length > 4096) return 'too-long';
  if (/[\r\n\0]/.test(s)) return 'control-characters';
  if (!path.isAbsolute(s)) return 'not-absolute';
  if (requireFile) {
    if (!MEDIA_EXT.includes(path.extname(s).toLowerCase())) return 'bad-extension';
    try { if (!fs.statSync(s).isFile()) return 'not-a-file'; } catch (_) { return 'not-found'; }
  }
  return null;
}
const MEDIA_ERROR_TEXT = {
  empty: 'The media path is empty.',
  'too-long': 'The media path is longer than 4096 characters.',
  'control-characters': 'The media path contains a line break or a null character.',
  'not-absolute': 'The media path must be a full path, for example D:\\ISO\\Win11_25H2_English_x64.iso.',
  'bad-extension': 'The media file must be an .iso, .esd or .wim.',
  'not-a-file': 'That media path is a folder, not a file.',
  'not-found': 'No file exists at that media path.',
};
/** @returns {{args: string[]}|{error: object}} */
function imageMediaArgs(opts) {
  const o = opts || {};
  const args = [];
  if (o.isoPath != null && String(o.isoPath) !== '') {
    const bad = checkMediaPath(o.isoPath, { requireFile: true });
    if (bad) return { error: { ok: false, errorCode: 'bad-media-path', reason: bad, error: `${MEDIA_ERROR_TEXT[bad]} FrameForge did not start anything.` } };
    args.push('-IsoPath', String(o.isoPath));
  }
  if (o.sourcePath != null && String(o.sourcePath) !== '') {
    // A source may be a folder (…\sources\sxs) or a wim/esd, so only the shape is checked.
    const bad = checkMediaPath(o.sourcePath, { requireFile: false });
    if (bad) return { error: { ok: false, errorCode: 'bad-source-path', reason: bad, error: `${MEDIA_ERROR_TEXT[bad]} FrameForge did not start anything.` } };
    args.push('-SourcePath', String(o.sourcePath));
  }
  if (Number.isInteger(o.index) && o.index > 0 && o.index < 100) args.push('-Index', String(o.index));
  return { args };
}
ipcMain.handle('image:detect', () => runPs('image.ps1', ['-Action', 'detect'], { timeout: 120000 }));
ipcMain.handle('image:validate', (_e, opts) => {
  const m = imageMediaArgs(opts); if (m.error) return m.error;
  return runPs('image.ps1', ['-Action', 'validate', ...m.args], { timeout: 600000 });
});
ipcMain.handle('image:preflight', (_e, opts) => {
  const o = opts || {};
  const m = imageMediaArgs(o); if (m.error) return m.error;
  return runPs('image.ps1', ['-Action', 'preflight', ...m.args, ...(o.dryRun ? ['-DryRun'] : [])], { timeout: 1800000 });
});
// Consent contract mode is the DEFAULT: -Confirm is appended only when the renderer
// passes confirm === true, which only happens from an explicit user click on the
// consent gate. Anything else returns the contract and starts nothing (doctrine rule 3).
ipcMain.handle('image:launch', (_e, opts) => {
  const o = opts || {};
  const m = imageMediaArgs(o); if (m.error) return m.error;
  const args = ['-Action', 'launch', ...m.args];
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

app.whenReady().then(async () => {
  // Both probes are read-only and run BEFORE the first window so the renderer's very
  // first ui:env call already carries a measured answer rather than an assumption.
  await Promise.all([detectExecutionPolicy(), readTransparency()]);
  if (psPolicy.blocked) console.error(`[policy] ${psPolicy.message}`);
  // The predicted mode is only a starting point. Verify it by RUNNING an engine, and verify
  // who we are running as, before the renderer is allowed to draw a conclusion from either.
  // runPs() waits on this promise, so no engine call can outrun the verification; the window
  // is created immediately so the app is not a blank rectangle while it happens.
  engineReady = verifyEngineInvocation()
    .then((p) => {
      if (p.engineUsable === false) console.error(`[engine] ${p.message}`);
      else if (p.mode === 'scriptblock') {
        const why = p.blockingScope ? `${p.blockingValue} at ${p.blockingScope} scope` : 'running the script files directly produced nothing';
        console.error(`[engine] verified: running engines from memory (${why}).`);
      }
    })
    .catch((e) => {
      psPolicy.probeRan = true;
      psPolicy.engineUsable = false;
      psPolicy.probeError = (e && e.message) || String(e);
      psPolicy.message = `FrameForge could not test whether PowerShell works on this PC (${psPolicy.probeError}). Nothing below has been measured.`;
    })
    .then(() => refreshIdentity().catch(() => {}))
    .then(() => {
      if (win && !win.isDestroyed()) { try { win.webContents.send('ui:env-changed', uiEnv()); } catch (_) {} }
    });
  createWindow();
  createTray();
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
