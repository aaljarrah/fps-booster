# FrameForge Gauntlet — expansion into a Windows repair & health tool

Goal: FrameForge becomes the go-to Windows repair/health tool while keeping its
measure-first, no-placebo ethos. Nothing ships until a fresh-context harsh critic
picks ours blind over the bar.

## Bars

- **Capability bar:** CTT WinUtil (cloned; dissection in `research/winutil-dissection.md`).
  Match its fixes feature-for-feature; beat it on diagnosis-before-repair, true
  state-capture undo, post-fix verification, and safety rails.
- **UI/UX bar:** Windows 11 Settings app. Exact WinUI tokens/anatomy in
  `research/fluent-ui-anatomy.md`. A blind judge shown our screen next to a real
  Settings screenshot must pick ours or be unable to tell which is native.

## Non-negotiable doctrine (carried over from FrameForge v0.1)

1. Detect before fixing; verify after fixing — the same read-only probe both times.
2. Undo restores *captured* prior state, never an assumed default (WinUtil's flaw).
3. Destructive/irreversible rungs (in-place repair, Reset) are guided, consent-gated
   handoffs — never silent automation.
4. Honest reporting: "nothing was wrong" and "this fixed nothing" are first-class results.
5. Every fix documents the exact commands it runs, with sources.

## Pieces (each gets a builder + separate fresh-context critic; loop until blind win)

| # | Piece | Files | Quality gate |
|---|-------|-------|--------------|
| P1 | Fluent design system + app shell | `src/*`, `electron/main.js` (window opts only) | Blind screenshot A/B vs real Settings; tokens match `fluent-ui-anatomy.md` exactly; light+dark; all 7 existing screens still functional |
| P2 | Engine foundation + health probes | `engine/_lib.ps1`, `engine/health.ps1`, `data/health-checks.json` | Every probe category from `repair-ladder.md` §3 implemented, read-only, structured JSON, runs clean on this machine; critic executes them |
| P3 | Repair engine | `engine/repair.ps1`, `data/repairs.json` | Feature-for-feature vs WinUtil fixes, but scoped (no GP nuke), detect→fix→verify, dry-run, state-capture undo where possible |
| P4 | Fresh-image repair flow | `engine/image.ps1` | Full flow from `fresh-image-repair.md`: detect edition/lang/build, Fido→MCT→picker ladder, media validation, DISM /Source, compat scanonly, safety rails, setup launch, post-verify |
| P5 | Health screen UI | `src/*`, IPC in `electron/` | Settings-grade card UI for scan→issues→fix→verified; blind A/B |
| P6 | Repair Center UI | `src/*`, IPC in `electron/` | Guided repair ladder incl. fresh-image consent flow (EULA, BitLocker, disk space, reboot expectations); blind A/B |

Rounds: R1 = P1+P2 (parallel, disjoint files). R2 = P3+P4. R3 = P5+P6 + whole-app blind pass.

## Outcome

Every piece was picked blind by a fresh-context critic. Seven verdicts across three rounds;
three failures along the way, each of which caught something real.

| Piece | Rounds | Final verdict |
|-------|--------|---------------|
| P2 health probes | 1 | Passed. Found this machine's real problems while WinUtil's model would have "repaired" a healthy update stack by destroying local Group Policy. |
| P3 repair + P4 image | 2 | Passed, "and not close" — judged on whose repair a user would trust with a broken Windows, and who is left better off when the fix does not work. |
| P1 shell + P5/P6 screens | 3 | Passed. Composited against a genuine Settings capture at native scale, every metric matched within 1–2px; the critic could not call which was native. |

What the failures caught, in order: fabricated screenshot evidence (a capture harness that
swallowed exceptions and silently reused frames); a settings page composed as a SaaS pricing
table; a repair that reported success while silently doing nothing about the finding it claimed
to fix; and a catalog that claimed its command list was verified against the engine when the
check only compared counts.

Bugs found in the pre-existing v0.1 while working: `engine.ps1 -Action list` emitted invalid
JSON, because `tweaks.json` has no BOM and PowerShell 5.1 substituted a control character for
an arrow in the tweak copy. Production never hit it only because the Electron main process
reads the catalog directly in Node. Fixed at the root (`-Encoding UTF8` on read, UTF-8
console output encoding), matching the pattern in `engine/_lib.ps1`.

## Critic protocol

- Fresh context, never the builder. Binary verdict: A or B, which is better / which is native.
- Labels stripped. Praise is not useful; every verdict names the single biggest remaining gap.
- UI critics compare real screenshots (`FF_CAPTURE` harness renders ours; Microsoft's
  published Settings screenshots / WinUI Gallery are the reference).
- Engine critics execute read-only probes for real, run apply paths only with `-DryRun`,
  and diff our fix implementations against WinUtil's actual source line-by-line.
