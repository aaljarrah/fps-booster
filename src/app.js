'use strict';
/* FrameForge renderer */

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
      const presetKeys = async (pk) => { const c = await catalog(); return (c.presets[pk] && c.presets[pk].applied) || []; };
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
}

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const IMPACT_W = { high: 3, medium: 2, low: 1, situational: 1, none: 1 };
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const state = { sys: null, tweaks: [], detect: {}, admin: false, busy: false, bench: { baseline: null, after: null, context: null }, nvidia: { catalog: null, detect: null, games: [], vrr: false, active: null, sel: new Set(), advOpen: false } };

/* ---------- toasts & drawer ---------- */
function toast(type, title, body, ms = 4200) {
  const t = document.createElement('div');
  t.className = `toast ${type}`;
  t.innerHTML = `<div class="tt">${esc(title)}</div>${body ? `<div class="tb">${esc(body)}</div>` : ''}`;
  $('#toasts').appendChild(t);
  setTimeout(() => { t.style.opacity = '0'; t.style.transform = 'translateX(30px)'; t.style.transition = '0.3s'; setTimeout(() => t.remove(), 320); }, ms);
}
function openDrawer(html) {
  const d = $('#drawer'); d.innerHTML = html; d.hidden = false; $('#drawerBackdrop').hidden = false;
}
function closeDrawer() { $('#drawer').hidden = true; $('#drawerBackdrop').hidden = true; }

/* ---------- helpers ---------- */
const isApplied = (id) => !!(state.detect[id] && state.detect[id].applied);
const tweaksByKind = (k) => state.tweaks.filter((t) => t.kind === k);
function badge(cls, txt) { return `<span class="badge ${cls}">${esc(txt)}</span>`; }
function metaBadges(t) {
  let b = '';
  if (t.requiresAdmin) b += badge('meta', 'admin');
  if (t.requiresReboot) b += badge('meta', 'reboot');
  return b;
}

/* advisory satisfaction we can actually detect on this machine */
function advisorySatisfied(t) {
  const s = state.sys; if (!s) return null;
  if (t.id === 'enable-xmp') return !(s.ram && s.ram.xmpLikelyOff);
  if (t.id === 'wired-ethernet') return s.network ? s.network.isWired : null;
  if (t.id === 'move-libraries-off-qvo') { if (!s.storage || !s.storage.steamFound) return null; return s.storage.slowGameCount === 0; }
  return null; // not detectable -> recommendation only
}

/* ---------- score ---------- */
function computeScore() {
  let good = 0, total = 0;
  for (const t of tweaksByKind('action')) { const w = IMPACT_W[t.impact] || 1; total += w; if (isApplied(t.id)) good += w; }
  for (const t of tweaksByKind('verify')) { const w = IMPACT_W[t.impact] || 1; total += w; if (isApplied(t.id)) good += w; }
  for (const t of tweaksByKind('advise')) {
    const sat = advisorySatisfied(t); if (sat === null) continue;
    const w = IMPACT_W[t.impact] || 1; total += w; if (sat) good += w;
  }
  return total ? Math.round((good / total) * 100) : 0;
}

/* ---------- DASHBOARD ---------- */
function renderDashboard() {
  const s = state.sys; if (!s) return;
  $('#greeting').textContent = `${s.cpu.name.split('Core')[0] ? 'Your' : 'Your'} ${s.gpus[0] ? s.gpus[0].name : 'rig'}`;
  $('#rigSub').textContent = `${s.os.caption} · build ${s.os.build} · ${s.cpu.cores}C/${s.cpu.threads}T · ${s.ram.runningMTs} MT/s · ${s.disks.length} drives`;

  // score ring
  const score = computeScore();
  $('#scoreVal').textContent = score;
  const ring = $('#scoreRing'); const circ = 327;
  // inject gradient def once
  if (!$('#scoreGrad')) {
    const svg = ring.closest('svg');
    svg.insertAdjacentHTML('afterbegin', `<defs><linearGradient id="scoreGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#41d6ff"/><stop offset="1" stop-color="#7c5cff"/></linearGradient></defs>`);
  }
  setTimeout(() => { ring.style.strokeDashoffset = String(circ - (circ * score) / 100); }, 80);

  // spec cards
  const gpu = s.gpus[0] || {};
  const ramChip = s.ram.xmpLikelyOff
    ? `<span class="chip warn">▲ XMP off — rated ${s.ram.ratedMTs}</span>`
    : `<span class="chip good">✓ XMP on</span>`;
  const mcChip = s.cpu.microcodeOk === true ? `<span class="chip good">✓ microcode ${esc(s.cpu.microcode)}</span>`
    : s.cpu.microcodeOk === false ? `<span class="chip warn">▲ update BIOS microcode</span>` : '';
  const netChip = s.network && s.network.isWired ? `<span class="chip good">✓ wired ${s.network.linkSpeedMbps}Mbps</span>`
    : s.network && s.network.isWired === false ? `<span class="chip warn">▲ on Wi-Fi</span>` : '';
  const cards = [
    { k: 'Processor', v: s.cpu.name.replace('(R)', '').replace('(TM)', ''), d: `${s.cpu.cores} cores · ${s.cpu.threads} threads${s.cpu.hybrid ? ' · hybrid P+E' : ''}`, chip: mcChip },
    { k: 'Graphics', v: gpu.name || '—', d: `driver ${gpu.driverVersion || '—'}`, chip: '' },
    { k: 'Memory', v: `${s.ram.modules.reduce((a, m) => a + m.capacityGB, 0)} GB DDR5`, d: `${s.ram.runningMTs} MT/s${s.ram.ratedMTs ? ` of ${s.ram.ratedMTs} rated` : ''}`, chip: ramChip },
    { k: 'Display', v: `${s.display.currentW}×${s.display.currentH}`, d: `${s.display.currentHz} Hz${s.display.refreshOpportunity ? '' : ' · max'}`, chip: s.display.refreshOpportunity ? `<span class="chip warn">▲ ${s.display.maxHzAtCurrentRes}Hz available</span>` : `<span class="chip good">✓ optimal</span>` },
  ];
  $('#specGrid').innerHTML = cards.map((c) => `
    <div class="spec"><div class="k">${esc(c.k)}</div><div class="v">${esc(c.v)}</div><div class="d">${esc(c.d)}</div>${c.chip || ''}</div>`).join('');

  // opportunities = unapplied actions + outstanding detectable advisories + unhealthy verifies
  const opps = [];
  for (const t of tweaksByKind('action')) if (!isApplied(t.id)) opps.push(t);
  for (const t of tweaksByKind('verify')) if (!isApplied(t.id)) opps.push(t);
  for (const t of tweaksByKind('advise')) { const sat = advisorySatisfied(t); if (sat === false) opps.push(t); }
  opps.sort((a, b) => (IMPACT_W[b.impact] || 1) - (IMPACT_W[a.impact] || 1));

  $('#oppHint').textContent = opps.length ? `${opps.length} found` : 'all clear';
  if (!opps.length) { $('#oppList').innerHTML = `<div class="empty">No outstanding opportunities — your system is well tuned. 🎯</div>`; }
  else {
    $('#oppList').innerHTML = opps.map((t) => {
      const w = IMPACT_W[t.impact] || 1; const pct = (w / 3) * 100;
      const actLabel = t.kind === 'advise' ? 'How' : (t.requiresAdmin && !state.admin ? 'Needs admin' : 'Apply');
      return `<div class="opp" data-id="${t.id}">
        <div class="impact"><div class="bar" style="width:${pct}%"></div><span>${esc(t.impact)}</span></div>
        <div class="body"><h4>${esc(t.name)}</h4><p>${esc(t.summary)}</p></div>
        <div class="act"><button class="btn ${t.kind === 'advise' ? 'ghost' : 'primary'} sm" data-act="opp" data-id="${t.id}">${actLabel}</button></div>
      </div>`;
    }).join('');
  }
}

/* ---------- BOOST / PROFILES ---------- */
const PROFILES = [
  { id: 'safe', name: 'Safe Boost', feature: true, icon: 'M13 2L3 14h7l-1 8 10-12h-7l1-8z', desc: 'Conservative, reversible wins. Nothing risky, all measured.', tiers: ['safe'], kinds: ['action'] },
  { id: 'comp', name: 'Competitive', icon: 'M12 2a10 10 0 100 20 10 10 0 000-20zm0 4a6 6 0 110 12 6 6 0 010-12zm0 3a3 3 0 100 6 3 3 0 000-6z', desc: 'Lowest-latency setup for esports. Adds balanced network/power tuning.', tiers: ['safe', 'balanced'], kinds: ['action'] },
  { id: 'max', name: 'Maximum', icon: 'M3 13h2l2-5 3 9 3-13 3 9 2-5h3', desc: 'Every safe + balanced action, plus the BIOS guidance to go all-in.', tiers: ['safe', 'balanced', 'aggressive'], kinds: ['action'] },
];
function profileTweaks(p) { return state.tweaks.filter((t) => p.kinds.includes(t.kind) && p.tiers.includes(t.tier)); }

function renderBoost() {
  $('#profileGrid').innerHTML = PROFILES.map((p) => {
    const items = profileTweaks(p);
    const appliedN = items.filter((t) => isApplied(t.id)).length;
    const li = items.map((t) => `<li>${esc(t.name)}${isApplied(t.id) ? ' <span class="badge risk-none" style="margin-left:auto">on</span>' : ''}</li>`).join('');
    return `<div class="profile ${p.feature ? 'feature' : ''}">
      <h3><span class="pico"><svg viewBox="0 0 24 24"><path d="${p.icon}"/></svg></span>${esc(p.name)}</h3>
      <p>${esc(p.desc)}</p>
      <ul>${li || '<li>No items</li>'}</ul>
      <button class="btn primary" data-act="apply-profile" data-id="${p.id}">${appliedN === items.length && items.length ? 'Re-apply' : 'Apply'} (${appliedN}/${items.length})</button>
    </div>`;
  }).join('') + `
    <div class="profile" style="border-color:rgba(248,113,113,0.25)">
      <h3><span class="pico" style="background:rgba(248,113,113,0.12)"><svg viewBox="0 0 24 24" style="fill:#f87171"><path d="M12 2a10 10 0 100 20 10 10 0 000-20zm5 13.6L15.6 17 12 13.4 8.4 17 7 15.6 10.6 12 7 8.4 8.4 7 12 10.6 15.6 7 17 8.4 13.4 12z"/></svg></span>Revert Everything</h3>
      <p>Undo every change FrameForge made, restoring each setting to its exact previous value.</p>
      <ul><li>Replays the backup journal in reverse</li><li>Power plan, registry, services — all restored</li></ul>
      <button class="btn danger" data-act="revert-all">Revert all tweaks</button>
    </div>`;
}

/* ---------- TWEAKS ---------- */
let tweakFilter = 'all';
function renderTweaks() {
  const cats = ['all', ...new Set(state.tweaks.map((t) => t.category))];
  $('#tweakFilters').innerHTML = cats.map((c) => `<button class="${c === tweakFilter ? 'active' : ''}" data-cat="${c}">${esc(c)}</button>`).join('');

  const groups = [
    { kind: 'action', title: 'Actions — FrameForge applies & reverts these' },
    { kind: 'verify', title: 'Verified healthy — we check, we don\'t change' },
    { kind: 'advise', title: 'Advisories — BIOS / in-game / manual (we guide you)' },
  ];
  let html = '';
  for (const g of groups) {
    let items = state.tweaks.filter((t) => t.kind === g.kind && (tweakFilter === 'all' || t.category === tweakFilter));
    if (!items.length) continue;
    html += `<div class="section-head" style="margin-top:18px"><h2>${esc(g.title)}</h2></div>`;
    html += items.map((t) => renderTweakRow(t)).join('');
  }
  $('#tweakList').innerHTML = html || `<div class="empty">No tweaks in this category.</div>`;
}
function renderTweakRow(t) {
  const applied = isApplied(t.id);
  let control = '';
  if (t.kind === 'action') {
    const disabled = t.requiresAdmin && !state.admin ? 'disabled' : '';
    control = `<label class="switch" title="${disabled ? 'Requires administrator' : ''}"><input type="checkbox" ${applied ? 'checked' : ''} ${disabled} data-act="toggle" data-id="${t.id}"><span class="slider"></span></label>`;
  } else if (t.kind === 'verify') {
    control = applied ? badge('risk-none', '✓ healthy') : badge('risk-medium', '▲ check');
  } else {
    const sat = advisorySatisfied(t);
    control = sat === true ? badge('risk-none', '✓ done') : `<button class="btn ghost sm" data-act="guide" data-id="${t.id}">Show me</button>`;
  }
  return `<div class="tweak" data-id="${t.id}">
    <div class="tweak-main">
      <div class="tweak-info">
        <h4>${esc(t.name)}</h4>
        <p>${esc(t.summary)}</p>
        <div class="tweak-badges">
          ${badge('tier-' + t.tier, t.tier)}${badge('risk-' + t.risk, 'risk: ' + t.risk)}
          <span class="badge meta">impact: ${esc(t.impact)}</span>${metaBadges(t)}
        </div>
        <span class="tweak-expand" data-act="expand" data-id="${t.id}">Details, evidence &amp; exact change ▾</span>
      </div>
      <div>${control}</div>
    </div>
    <div class="tweak-detail" id="detail-${t.id}">
      <p>${esc(t.details)}</p>
      <p style="margin-top:8px"><b style="color:var(--txt)">Why it helps:</b> ${esc(t.evidence)}</p>
      <div class="mono">${esc(describeOp(t))}</div>
      ${(t.sources || []).map((u) => `<a data-act="src" data-url="${esc(u)}">${esc(u)}</a>`).join('<br>')}
    </div>
  </div>`;
}
function describeOp(t) {
  const op = t.op; if (!op) return '';
  if (op.type === 'advise') return 'Guided steps — FrameForge does not change this automatically.';
  if (op.type === 'verify') return `Read-only health check: ${op.check}`;
  const lines = [];
  const walk = (o) => {
    if (o.type === 'registry') lines.push(`${o.root}\\${o.path}\\${o.name} = ${o.value} (${o.valueType})`);
    else if (o.type === 'multi') o.ops.forEach(walk);
    else if (o.type === 'powercfg-scheme') lines.push(`powercfg → activate "${o.name}"${op.procMinState != null ? `, min processor state = ${op.procMinState}%` : ''}`);
    else if (o.type === 'service') lines.push(`service ${o.name} → ${o.startup}/${o.state}`);
  };
  walk(op);
  return lines.join('\n');
}

/* ---------- BENCHMARK ---------- */
async function refreshBenchTargets() {
  const sel = $('#benchTarget');
  sel.innerHTML = `<option value="">Loading…</option>`;
  const res = await window.ff.windowedProcs();
  const list = Array.isArray(res) ? res : [];
  sel.innerHTML = `<option value="">Select a running game / app…</option>` +
    list.map((p) => `<option value="${p.name}.exe">${esc(p.title.slice(0, 42))} — ${esc(p.name)} (${p.ramMB}MB)</option>`).join('');
}
function metricRow(label, key, unit, b, a, higher = true) {
  let delta = '';
  if (b && a && b[key] != null && a[key] != null) {
    const d = a[key] - b[key]; const up = higher ? d > 0 : d < 0;
    const pct = b[key] ? Math.round((d / b[key]) * 100) : 0;
    if (Math.abs(d) > 0.05) delta = `<span class="delta ${up ? 'up' : 'down'}">${d > 0 ? '+' : ''}${pct}%</span>`;
  }
  const val = a ? a[key] : (b ? b[key] : '–');
  return `<div class="metric-row"><span class="ml">${label}</span><span><span class="mv">${val ?? '–'}</span>${unit}${delta}</span></div>`;
}
// Honest A/B verdict: is the after-vs-baseline change real, or within run-to-run noise?
function benchVerdict(b, a) {
  if (!b || !a) return '';
  const pct = (k) => (b[k] ? ((a[k] - b[k]) / b[k]) * 100 : 0);
  const dAvg = pct('avgFps'), dLow = pct('low1Fps');
  const NOISE = 3; // % — below this on a desktop is run-to-run variance, not a real change
  const real = Math.abs(dAvg) >= NOISE || Math.abs(dLow) >= NOISE;
  if (!real) {
    return `<div class="bench-verdict moe">⚖ Within margin of error on your rig — no measurable change (avg ${dAvg >= 0 ? '+' : ''}${dAvg.toFixed(1)}%, 1% low ${dLow >= 0 ? '+' : ''}${dLow.toFixed(1)}%). That's an honest result, not a failure.</div>`;
  }
  const better = dLow > 0 || dAvg > 0;
  return `<div class="bench-verdict ${better ? 'good' : 'bad'}">${better ? '✓ Measurable change' : '▼ Measurable regression'}: average ${dAvg >= 0 ? '+' : ''}${dAvg.toFixed(1)}%, 1% low ${dLow >= 0 ? '+' : ''}${dLow.toFixed(1)}%.</div>`;
}
function renderBench() {
  const b = state.bench.baseline, a = state.bench.after;
  const ctx = state.bench.context
    ? `<div class="bench-ctx">Measuring: <b>${esc(state.bench.context)}</b><span>Record Baseline → change the setting (NVIDIA settings need a game relaunch) → Record After.</span></div>`
    : '';
  if (!b && !a) { $('#benchResults').innerHTML = ctx; return; }
  const mk = (title, m, base) => !m
    ? `<div class="bench-card"><h3><span>${title}</span></h3><div class="empty" style="padding:14px">Not recorded yet</div></div>`
    : `<div class="bench-card">
        <h3><span>${title}</span><span style="color:var(--txt-faint)">${m.frames} frames · ${m.durationSec}s</span></h3>
        ${metricRow('Average FPS', 'avgFps', '', base, m, true)}
        ${metricRow('1% Low', 'low1Fps', '', base, m, true)}
        ${metricRow('0.1% Low', 'low01Fps', '', base, m, true)}
        ${metricRow('Stutter (frametime σ)', 'stutterMs', ' ms', base, m, false)}
      </div>`;
  $('#benchResults').innerHTML = ctx + mk('Baseline', b, null) + mk('After', a, b) + benchVerdict(b, a);
}

/* ---------- GAME FOCUS ---------- */
let focusSel = new Set();
async function renderFocus() {
  const res = await window.ff.bloatProcs();
  const list = Array.isArray(res) ? res : [];
  const total = list.reduce((s, p) => s + p.ramMB, 0);
  $('#reclaimMB').textContent = `${(total / 1024).toFixed(1)} GB`;
  if (!list.length) { $('#focusList').innerHTML = `<div class="empty">No background bloat detected — nice and lean. 🧹</div>`; $('#focusClose').disabled = true; return; }
  $('#focusList').innerHTML = list.map((p) => {
    const ids = p.ids.join(',');
    return `<label class="focus-app ${focusSel.has(ids) ? 'sel' : ''}" data-ids="${ids}">
      <input type="checkbox" ${focusSel.has(ids) ? 'checked' : ''} data-act="focus-sel" data-ids="${ids}">
      <div class="fa-body"><div class="n">${esc(p.name)}</div><div class="r">${p.ramMB} MB · ${p.ids.length} process${p.ids.length > 1 ? 'es' : ''}</div></div>
    </label>`;
  }).join('');
  $('#focusClose').disabled = focusSel.size === 0;
}

/* ---------- admin UI ---------- */
function updateAdminUI() {
  const pill = $('#adminPill');
  if (state.admin) { pill.className = 'admin-pill ok'; $('#adminText').textContent = 'Administrator'; $('#adminCard').hidden = true; }
  else { pill.className = 'admin-pill no'; $('#adminText').textContent = 'Limited — click to elevate'; $('#adminCard').hidden = false; }
}

/* ---------- actions ---------- */
async function refreshDetect() { state.detect = {}; const arr = await window.ff.detectAll(); if (Array.isArray(arr)) for (const d of arr) state.detect[d.id] = d; }

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
  for (const t of items) {
    if (t.requiresAdmin && !state.admin) { skip++; continue; }
    const r = await window.ff.apply(t.id); if (r && r.success) ok++; else skip++;
  }
  toast(ok ? 'ok' : 'warn', `${p.name} applied`, `${ok} applied${skip ? `, ${skip} skipped` : ''}.`);
  await refreshDetect(); rerenderAll();
}
async function revertAll() {
  const r = await window.ff.revertAll();
  toast('ok', 'Reverted everything', r && r.count != null ? `${r.count} change(s) undone.` : 'Done.');
  await refreshDetect(); rerenderAll();
}
function showGuide(id) {
  const t = state.tweaks.find((x) => x.id === id); if (!t) return;
  const steps = (t.guide || []).map((g, i) => `<li><b style="color:var(--cyan)">${i + 1}.</b> ${esc(g)}</li>`).join('');
  openDrawer(`
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
      <h2 style="font-size:18px">${esc(t.name)}</h2>
      <button class="btn ghost sm" data-act="close-drawer">✕</button>
    </div>
    ${badge('tier-' + t.tier, t.tier)} ${badge('meta', 'impact: ' + t.impact)} ${badge('risk-' + t.risk, 'risk: ' + t.risk)}
    <p style="color:var(--txt-dim);margin:14px 0;line-height:1.6">${esc(t.details)}</p>
    <h3 style="font-size:14px;margin-bottom:10px">Steps</h3>
    <ul style="list-style:none;display:flex;flex-direction:column;gap:11px;line-height:1.5">${steps || '<li>No steps.</li>'}</ul>
    <div style="margin-top:18px">${(t.sources || []).map((u) => `<a data-act="src" data-url="${esc(u)}" style="color:var(--cyan);font-size:12px;cursor:pointer">${esc(u)}</a>`).join('<br>')}</div>
  `);
}

/* ---------- benchmark capture ---------- */
async function runCapture(which) {
  const proc = $('#benchTarget').value; const secs = Number($('#benchSeconds').value);
  if (!proc) { toast('warn', 'Pick a target', 'Choose a running game/app to measure.'); return; }
  if (!state.admin) { toast('warn', 'Administrator required', 'PresentMon frametime capture needs admin. Restart as administrator.'); return; }
  const st = $('#benchStatus'); st.className = 'bench-status live'; st.textContent = `● Capturing ${proc} for ${secs}s…`;
  $('#benchBaseline').disabled = $('#benchAfter').disabled = true;
  const r = await window.ff.capture(proc, secs, which);
  $('#benchBaseline').disabled = false;
  if (r && r.ok) {
    state.bench[which] = r; st.className = 'bench-status'; st.textContent = `✓ ${which} recorded: ${r.avgFps} FPS avg, ${r.low1Fps} 1% low`;
    if (which === 'baseline') $('#benchAfter').disabled = false;
    renderBench();
  } else {
    st.className = 'bench-status'; st.textContent = '';
    toast('err', 'Capture failed', (r && (r.reason || r.error)) || 'Make sure the game is running and rendering.');
  }
}

/* ---------- rerender ---------- */
function rerenderAll() {
  renderDashboard(); renderBoost(); renderTweaks();
  const badge = tweaksByKind('action').filter((t) => isApplied(t.id)).length;
  $('#tweaksAppliedBadge').textContent = badge ? String(badge) : '';
}

/* ---------- nav ---------- */
function switchView(v) {
  $$('.nav-item').forEach((n) => n.classList.toggle('active', n.dataset.view === v));
  $$('.view').forEach((s) => s.classList.toggle('active', s.id === 'view-' + v));
  if (v === 'benchmark') refreshBenchTargets();
  if (v === 'focus') renderFocus();
  if (v === 'nvidia') loadNvidia();
}

/* ---------- global click handler ---------- */
document.addEventListener('click', async (e) => {
  const navBtn = e.target.closest('.nav-item'); if (navBtn) return switchView(navBtn.dataset.view);
  const t = e.target.closest('[data-act]'); if (!t) return;
  const act = t.dataset.act, id = t.dataset.id;
  switch (act) {
    case 'opp': { const tw = state.tweaks.find((x) => x.id === id); if (tw.kind === 'advise') showGuide(id); else applyTweak(id); break; }
    case 'toggle': break; // handled by change
    case 'expand': { const d = $('#detail-' + id); if (d) d.classList.toggle('open'); break; }
    case 'src': window.ff.openExternal(t.dataset.url); break;
    case 'guide': showGuide(id); break;
    case 'apply-profile': applyProfile(id); break;
    case 'revert-all': revertAll(); break;
    case 'close-drawer': closeDrawer(); break;
    case 'focus-sel': break;
    case 'nv-snapshot': nvSnapshot(); break;
    case 'nv-apply': nvApply(t.dataset.preset); break;
    case 'nv-revert': nvRevert(); break;
    case 'nv-diff': nvDiff(t.dataset.preset); break;
    case 'nv-open': window.ff.nvidia.open(); toast('ok', 'Opening NVIDIA tuner', 'Accept the UAC prompt.'); break;
    case 'nv-measure': nvMeasure(t.dataset.key); break;
    case 'nv-toggle-adv': { state.nvidia.advOpen = !state.nvidia.advOpen; renderNvidia(); break; }
    case 'nv-clearsel': { state.nvidia.sel.clear(); renderNvidia(); break; }
    case 'nv-applycustom': nvApplyCustom(); break;
    case 'nv-reverify': nvReverify(); break;
  }
});
document.addEventListener('change', async (e) => {
  const t = e.target.closest('[data-act]'); if (!t) return;
  if (t.dataset.act === 'toggle') { e.target.checked ? applyTweak(t.dataset.id) : revertTweak(t.dataset.id); }
  if (t.dataset.act === 'focus-sel') {
    const ids = t.dataset.ids; if (e.target.checked) focusSel.add(ids); else focusSel.delete(ids);
    $('#focusClose').disabled = focusSel.size === 0;
    t.closest('.focus-app').classList.toggle('sel', e.target.checked);
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
// VRR toggle in the NVIDIA strip
document.addEventListener('change', (e) => { if (e.target && e.target.id === 'nvVrr') { state.nvidia.vrr = e.target.checked; renderNvidia(); } });
// filter buttons (delegated)
$('#tweakFilters').addEventListener('click', (e) => { const b = e.target.closest('[data-cat]'); if (!b) return; tweakFilter = b.dataset.cat; renderTweaks(); });

/* ---------- static wiring ---------- */
$('#winMin').onclick = () => window.ff.win.minimize();
$('#winMax').onclick = () => window.ff.win.maximize();
$('#winClose').onclick = () => window.ff.win.close();
$('#drawerBackdrop').onclick = closeDrawer;
$('#modeSwitch').addEventListener('click', (e) => {
  const m = e.target.dataset.mode; if (!m) return;
  $$('#modeSwitch span').forEach((s) => s.classList.toggle('active', s.dataset.mode === m));
  document.body.classList.toggle('advanced', m === 'advanced');
  // hide Tweaks nav in simple mode
  $('.nav-item[data-view=tweaks]').style.display = m === 'advanced' ? '' : 'none';
  if (m === 'simple' && $('#view-tweaks').classList.contains('active')) switchView('dashboard');
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
  $('#restoreStatus').textContent = 'Creating restore point…';
  const r = await window.ff.restorePoint();
  $('#restoreStatus').textContent = r && r.success ? '✓ ' + r.message : '⚠ ' + ((r && r.message) || 'Failed');
};
$('#btnRevertAll').onclick = revertAll;
$('#btnElevate').onclick = () => window.ff.relaunchElevated();

/* ---------- NVIDIA tab ---------- */
const NV_PRESET_CHIPS = {
  esports: [['Latency', 'best'], ['Tearing', 'yes'], ['Avg FPS', 'unchanged']],
  balanced: [['Latency', '~1ms above floor'], ['Tearing', 'none (needs VRR)'], ['Consistency', 'best']],
  quality: [['Focus', 'visual stability'], ['At 1080p', '≈ Balanced'], ['Image knobs', 'untouched']],
};
function nvBadge(s) {
  if (s.impact === 'placebo') return ['ib-placebo', 'PLACEBO'];
  switch (s.category) {
    case 'latency': return s.impact === 'low' ? ['ib-insurance', 'INSURANCE'] : ['ib-latency', 'REAL LATENCY'];
    case 'sync': return ['ib-latency', 'LATENCY / SYNC'];
    case 'power': return ['ib-consistency', 'CONSISTENCY'];
    case 'framecap': return ['ib-consistency', 'CONSISTENCY'];
    case 'shader': return ['ib-stutter', 'ANTI-STUTTER'];
    default: return ['ib-insurance', 'INSURANCE'];
  }
}
let nvLoaded = false;
async function loadNvidia(force) {
  if (nvLoaded && !force) { renderNvidia(); return; }
  const [cat, det, games] = await Promise.all([window.ff.nvidia.catalog(), window.ff.nvidia.detect(), window.ff.nvidia.games()]);
  state.nvidia.catalog = cat; state.nvidia.detect = det || {}; state.nvidia.games = (games && games.games) || [];
  state.nvidia.active = (det && det.applied) || null;
  nvLoaded = true; renderNvidia();
}
function nvHasSnapshot() { return !!(state.nvidia.detect && state.nvidia.detect.snapshots > 0); }
function renderNvidia() {
  const cat = state.nvidia.catalog; const det = state.nvidia.detect || {};
  if (!cat || !cat.settings) { $('#nvStrip').textContent = 'NVIDIA data unavailable.'; return; }
  const snapOk = nvHasSnapshot();
  $('#nvStrip').innerHTML = `
    <div class="nv-seg">Driver <b>${esc(det.driver || '—')}</b></div><div class="sep"></div>
    <div class="nv-seg">Restore point: ${snapOk ? `<b class="nv-gateok">✓ ${esc(det.latestSnap || 'saved')}</b>` : `<b class="nv-gatewarn">none yet</b>`}</div>
    ${snapOk ? '' : '<button class="btn primary sm" data-act="nv-snapshot">Create restore point</button>'}
    <div class="sep"></div>
    <label class="nv-seg nv-vrr"><input type="checkbox" id="nvVrr" ${state.nvidia.vrr ? 'checked' : ''}> G-SYNC / VRR display</label>
    <button class="btn ghost sm" data-act="nv-open">Open tuner</button>
    <span class="nv-shield">🛡 Driver config — not injection — ban-safe</span>`;
  // Per-machine catalog freshness: the catalog's IDs are driver-specific. Offer re-verify on mismatch.
  const rv = $('#nvReverify');
  const catDrv = cat.driverVerifiedOn, curDrv = det.driver;
  const unresolved = Object.keys(cat.settings).filter((k) => cat.settings[k].idConfidence === 'unresolved');
  if (rv) {
    if (curDrv && catDrv && curDrv !== catDrv) {
      rv.hidden = false;
      rv.innerHTML = `⚠ This settings catalog was verified on driver <b>${esc(catDrv)}</b>, but yours is <b>${esc(curDrv)}</b>. Re-verify the setting IDs against your driver before applying. <button class="btn primary sm" data-act="nv-reverify">Re-verify (admin)</button>`;
    } else if (unresolved.length) {
      rv.hidden = false;
      rv.innerHTML = `⚠ ${unresolved.length} setting(s) couldn't be resolved on your driver and are disabled. <button class="btn ghost sm" data-act="nv-reverify">Re-verify (admin)</button>`;
    } else { rv.hidden = true; }
  }
  $('#nvActive').textContent = state.nvidia.active ? `active: ${state.nvidia.active}` : (snapOk ? 'no profile applied' : 'snapshot required before applying');
  const presets = cat.presets;
  $('#nvPresets').innerHTML = Object.keys(presets).map((k) => {
    const p = presets[k]; const feat = k === 'balanced'; const active = state.nvidia.active === k;
    const chips = (NV_PRESET_CHIPS[k] || []).map((c) => `<div class="row"><span>${esc(c[0])}</span><b>${esc(c[1])}</b></div>`).join('');
    const dis = (!state.admin || !snapOk) ? 'disabled' : '';
    return `<div class="nv-preset ${feat ? 'feature' : ''} ${active ? 'active' : ''}">
      <h3>${esc(p.name)}${feat ? '<span class="ribbon">RECOMMENDED</span>' : ''}</h3>
      <div class="pdesc">${esc(p.description)}</div>
      <div class="nv-chips">${chips}</div>
      <div class="pbtns">
        <button class="btn primary" data-act="nv-apply" data-preset="${k}" ${dis}>${active ? 'Re-apply' : 'Apply'}</button>
        ${active ? '<button class="btn ghost" data-act="nv-revert">Revert</button>' : ''}
      </div>
      <div class="difflink" data-act="nv-diff" data-preset="${k}">See exactly what changes (${p.applied.length}) ▾</div>
    </div>`;
  }).join('');
  $('#nvHonesty').innerHTML = `<b>Honest heads-up for your rig:</b> at 1080p on a 14900KF you're CPU-bound, so the headline FPS number won't move. The real win is in-game <b>Reflex</b> + your sync choice; these driver settings buy frametime <b>consistency</b> and correctness. Prove any of it with <span class="nv-link" data-act="nv-measure">Measure it ↗</span>.`;
  $('#nvInGame').innerHTML = (cat.inGame || []).map((g) => `
    <label class="nv-ig ${g.warn ? 'warn' : ''}"><input type="checkbox" data-act="nv-ig">
      <div class="ig-body"><h4>${esc(g.name)}</h4><div class="games">${esc(g.games)}</div><p>${esc(g.note)}</p></div>
    </label>`).join('');
  const vrrOnly = ['gsync-global', 'gsync-mode', 'vsync-on'];
  const selN = state.nvidia.sel.size;
  const applyDis = (!state.admin || !snapOk || selN === 0) ? 'disabled' : '';
  const bar = `<div class="nv-custombar"><span><b>${selN}</b> setting(s) selected for a custom profile</span>
    <div style="display:flex;gap:8px"><button class="btn ghost sm" data-act="nv-clearsel" ${selN === 0 ? 'disabled' : ''}>Clear</button>
    <button class="btn primary sm" data-act="nv-applycustom" ${applyDis}>Apply selected</button></div></div>`;
  const rows = Object.keys(cat.settings).map((key) => {
    const s = cat.settings[key]; const [cls, label] = nvBadge(s);
    const gated = !state.nvidia.vrr && vrrOnly.includes(key);
    const checked = state.nvidia.sel.has(key) ? 'checked' : '';
    return `<div class="nv-row ${checked ? 'sel' : ''}">
      <input type="checkbox" class="nv-selbox" data-act="nv-sel" data-key="${key}" ${checked} ${gated ? 'disabled' : ''} title="${gated ? 'Confirm a G-SYNC/VRR display first' : ''}">
      <div class="nv-main"><h4>${esc(s.name)} <span class="ib ${cls}">${label}</span> <span class="badge tier-${s.tier}">${esc(s.tier)}</span></h4><p>${esc(s.why)}</p></div>
      <div class="nv-val"><b>${esc(s.recommendedLabel)}</b><br><span class="sid">ID ${s.settingId} · ${esc(s.scope)}</span><br><span class="nv-link" data-act="nv-measure" data-key="${key}" style="font-size:11px">Measure it ↗</span></div></div>`;
  }).join('');
  $('#nvAdvanced').innerHTML = bar + rows;
  $('#nvAdvanced').hidden = !state.nvidia.advOpen;
  $('#nvAdvToggle').textContent = state.nvidia.advOpen ? 'hide ▴' : 'show ▾';
  $('#nvPlacebo').innerHTML = (cat.placebo || []).map((p) => `
    <div class="nv-row placebo"><div class="nv-main"><h4>${esc(p.name)} <span class="ib ib-placebo">NOT SHIPPED</span></h4><p>${esc(p.why)}</p></div>
      <div class="nv-val"><span class="sid">ID ${p.settingId}</span></div></div>`).join('');
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
async function nvDiff(presetKey) {
  const prev = await window.ff.nvidia.preview(presetKey, state.nvidia.vrr);
  const cat = state.nvidia.catalog;
  const rows = (prev.keys || []).map((k) => { const s = cat.settings[k]; if (!s) return ''; return `<tr><td style="padding:6px 0">${esc(s.name)}</td><td><b style="color:var(--cyan)">${esc(s.recommendedLabel)}</b></td><td style="color:var(--txt-faint)">${esc(s.defaultLabel)}</td></tr>`; }).join('');
  openDrawer(`<div style="display:flex;justify-content:space-between;align-items:center"><h2 style="font-size:18px">${esc(cat.presets[presetKey].name)}</h2><button class="btn ghost sm" data-act="close-drawer">✕</button></div>
    <p style="color:var(--txt-dim);margin:12px 0;font-size:12.5px;line-height:1.5">Exact driver settings FrameForge writes${prev.degraded ? ' <b style="color:var(--amber)">(tear-tolerant — no VRR confirmed)</b>' : ''}. Per-game profiles for: ${esc((prev.games || []).join(', ') || 'Base Profile')}.</p>
    <table style="width:100%;font-size:12px;border-collapse:collapse"><thead><tr style="color:var(--txt-faint);text-align:left"><th style="padding:6px 0">Setting</th><th>After</th><th>NVIDIA default</th></tr></thead><tbody>${rows}</tbody></table>
    <p style="color:var(--txt-faint);font-size:11.5px;margin-top:14px;line-height:1.5">Revert restores your full pre-apply snapshot (exact, all settings). Reflex stays an in-game toggle.</p>`);
}
$('#adminPill').onclick = () => { if (!state.admin) window.ff.relaunchElevated(); };

/* ---------- init ---------- */
(async function init() {
  // simple mode by default
  $('.nav-item[data-view=tweaks]').style.display = 'none';
  try {
    // Run the independent detection calls concurrently for a faster first paint.
    const [admin, tw, sys, det] = await Promise.all([
      window.ff.isAdmin(), window.ff.listTweaks(), window.ff.sysInfo(), window.ff.detectAll(),
    ]);
    state.admin = admin;
    state.tweaks = (tw && tw.tweaks) || [];
    state.sys = sys;
    state.detect = {}; if (Array.isArray(det)) for (const d of det) state.detect[d.id] = d;
    updateAdminUI(); rerenderAll();
    // Reveal the NVIDIA card only on NVIDIA rigs.
    if (state.sys && (state.sys.gpus || []).some((g) => g.vendor === 'NVIDIA')) { const n = $('#navNvidia'); if (n) n.hidden = false; }
    if (state.sys && state.sys.ram && state.sys.ram.xmpLikelyOff) {
      setTimeout(() => toast('warn', 'Free performance found', `Your RAM runs ${state.sys.ram.runningMTs} but is rated ${state.sys.ram.ratedMTs}. See “Enable XMP”.`, 7000), 900);
    }
  } catch (err) {
    toast('err', 'Startup error', String(err && err.message || err));
  }
})();
