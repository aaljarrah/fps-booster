# Building a Windows 11 Settings-grade Fluent UI in Electron

Research report for FrameForge. Quality bar: the Windows 11 Settings app (WinUI 3 + Windows Community Toolkit `SettingsCard`/`SettingsExpander` controls). All token values below are pulled from the `microsoft/microsoft-ui-xaml` repo (`Common_themeresources_any.xaml`) and Microsoft Learn docs — these are the *actual* values WinUI resolves at runtime, not approximations.

---

## 1. Anatomy of the Windows 11 Settings app

### 1.1 Layout skeleton

```
┌────────────────────────────────────────────────────────────┐
│  (titlebar region: drag area + window controls overlay)    │
│ ┌──────────────┬───────────────────────────────────────┐   │
│ │ NavigationView│  Breadcrumb / page title (28px SB)   │   │
│ │ pane (320px) │                                        │   │
│ │  [profile]   │  ┌─ SettingsCard ───────────────────┐  │   │
│ │  [search]    │  │ icon  title/description   toggle │  │   │
│ │  ● System    │  └──────────────────────────────────┘  │   │
│ │    Bluetooth │  ┌─ SettingsExpander ────────────── ⌄┐  │   │
│ │    Network   │  │  (expands to reveal child rows)  │  │   │
│ └──────────────┴───────────────────────────────────────┘   │
│   window bg = MICA          content cards = card layer     │
└────────────────────────────────────────────────────────────┘
```

- **Left NavigationView**: WinUI `NavigationView` in left-expanded mode. Default `OpenPaneLength` is **320epx**. Items are ~**36–40px tall**, 16px Segoe Fluent Icons glyph + 14px label, **4px corner radius** on the item hover/selection background. The selected item gets a **3px-wide, ~16px-tall accent-colored "pill" indicator** on its left edge, and a `SubtleFillColorSecondary` background. Hover = `SubtleFillColorSecondary`, pressed = `SubtleFillColorTertiary`.
- **Page header**: breadcrumb-style title in **Title ramp (28px semibold)**, sitting on the Mica background (not on a card). Content column is padded and max-width-constrained (~1000–1064px in Settings) so cards don't stretch on wide windows.
- **Settings rows**: each row is a card (`SettingsCard`), min-height ~**68px**, **16px internal padding**, 20px leading icon, title in Body (14px), description in Caption (12px) with secondary text color, action control (toggle/combo/button) right-aligned. Cards stack with a **~4px gap**. `SettingsExpander` is the same card with a chevron; expanded child rows render inside the card on the *secondary* card fill with 1px dividers.
- **Radii** (from `themeresources`): `ControlCornerRadius` = **4px** (buttons, inputs, nav items, and the SettingsCard itself), `OverlayCornerRadius` = **8px** (flyouts, dialogs, context menus, the window itself). Note: Settings rows visually use the 4px control radius; 8px is for overlay surfaces.

### 1.2 The layering model (this is the key to "looking native")

Windows 11 Fluent is built on **three stacked layers**:

1. **Mica** — the window background (blurred, desaturated wallpaper tint). In Electron this is the OS-drawn backdrop (see §2).
2. **Layer / content region** — `LayerFillColorDefault` painted *over* Mica for content panes (Settings paints its content area with this; the nav pane sits directly on Mica).
3. **Cards** — `CardBackgroundFillColorDefault` on top, with a 1px `CardStrokeColorDefault` border.

Most WinUI fills are **alpha-composited whites/blacks**, not opaque colors — that's why cards subtly pick up the Mica tint. If you flatten them to opaque hex you lose the native feel. In CSS, keep the alpha values and let them composite.

### 1.3 Color tokens — exact WinUI values (8-digit hex = AARRGGBB)

**Fill / surface tokens** (from `Common_themeresources_any.xaml`):

| Token | Light | Dark | Used for |
|---|---|---|---|
| `SolidBackgroundFillColorBase` | `#F3F3F3` | `#202020` | Mica fallback window bg |
| `SolidBackgroundFillColorSecondary` | `#EEEEEE` | `#1C1C1C` | — |
| `SolidBackgroundFillColorTertiary` | `#F9F9F9` | `#282828` | solid flyout bg |
| `SolidBackgroundFillColorQuarternary` | `#FFFFFF` | `#2C2C2C` | solid card-on-solid bg |
| `LayerFillColorDefault` | `#80FFFFFF` | `#4C3A3A3A` | content region over Mica |
| `LayerFillColorAlt` | `#FFFFFF` | `#0DFFFFFF` | — |
| `LayerOnMicaBaseAltFillColorDefault` | `#B3FFFFFF` | `#733A3A3A` | tab/titlebar layer on Mica |
| `CardBackgroundFillColorDefault` | `#B3FFFFFF` | `#0DFFFFFF` | **settings card bg** |
| `CardBackgroundFillColorSecondary` | `#80F6F6F6` | `#08FFFFFF` | expander child-row bg |
| `ControlFillColorDefault` | `#B3FFFFFF` | `#0FFFFFFF` | button/input rest bg |
| `ControlFillColorSecondary` | `#80F9F9F9` | `#15FFFFFF` | control hover bg |
| `ControlFillColorTertiary` | `#4DF9F9F9` | `#08FFFFFF` | control pressed bg |
| `ControlFillColorDisabled` | `#4DF9F9F9` | `#0BFFFFFF` | disabled control bg |
| `SubtleFillColorSecondary` | `#09000000` | `#0FFFFFFF` | list/nav item hover |
| `SubtleFillColorTertiary` | `#06000000` | `#0AFFFFFF` | list/nav item pressed |
| `ControlAltFillColorSecondary` | `#06000000` | `#19000000` | toggle-off track |

*(Your "#FBFBFB-ish / #2B2B2B-ish" observations are these alpha whites composited over Mica: `#B3FFFFFF` over `#F3F3F3` ≈ `#FBFBFB`; dark card `#0DFFFFFF` over `#202020` ≈ `#2C2C2C`.)*

**Stroke tokens:**

| Token | Light | Dark | Used for |
|---|---|---|---|
| `CardStrokeColorDefault` | `#0F000000` | `#19000000` | 1px card border |
| `CardStrokeColorDefaultSolid` | `#EBEBEB` | `#1C1C1C` | opaque variant |
| `ControlStrokeColorDefault` | `#0F000000` | `#12FFFFFF` | control border |
| `ControlStrokeColorSecondary` | `#29000000` | `#18FFFFFF` | control border bottom edge |
| `DividerStrokeColorDefault` | `#0F000000` | `#15FFFFFF` | expander row dividers |
| `SurfaceStrokeColorDefault` | `#66757575` | `#66757575` | window/surface border |

WinUI buttons use an "elevation border": `ControlStrokeColorDefault` on top/sides and the darker `ControlStrokeColorSecondary` on the bottom edge — in CSS, a `linear-gradient` border-image or a `box-shadow: inset 0 -1px` trick reproduces the subtle bottom-heavy stroke.

**Text tokens:**

| Token | Light | Dark |
|---|---|---|
| `TextFillColorPrimary` | `#E4000000` | `#FFFFFF` |
| `TextFillColorSecondary` | `#9E000000` | `#C5FFFFFF` |
| `TextFillColorTertiary` | `#72000000` | `#87FFFFFF` |
| `TextFillColorDisabled` | `#5C000000` | `#5DFFFFFF` |

**Accent tokens.** Windows generates a 7-stop ramp from the user's accent. Default blue ramp: `Light3 #99EBFF`, `Light2 #4CC2FF`, `Light1 #0091F8`, base `#0078D4`, `Dark1 #0067C0`, `Dark2 #003E92`, `Dark3 #001A68`. WinUI maps:

| Token | Light theme | Dark theme |
|---|---|---|
| `AccentFillColorDefault` | SystemAccentColor**Dark1** (`#0067C0`) | SystemAccentColor**Light2** (`#4CC2FF`) |
| `AccentFillColorSecondary` (hover) | Dark1 @ 90% alpha | Light2 @ 90% alpha |
| `AccentFillColorTertiary` (pressed) | Dark1 @ 80% alpha | Light2 @ 80% alpha |
| `TextOnAccentFillColorPrimary` | `#FFFFFF` | `#000000` (yes — black text on the light-blue dark-mode accent) |
| `AccentTextFillColorPrimary` (links/accent text) | Dark2 | Light3 |

Pull the live accent in Electron with `systemPreferences.getAccentColor()` (returns `RRGGBBAA`) and derive the ramp, or just use the default-blue values.

### 1.4 Type ramp (Segoe UI Variable) — official values

| Style | Size / line-height (epx) | Weight | Optical subfamily |
|---|---|---|---|
| Caption | 12 / 16 | Regular (400) | Small |
| Body | 14 / 20 | Regular (400) | Text |
| Body Strong | 14 / 20 | Semibold (600) | Text |
| Body Large | 18 / 24 | Regular (400) | Text |
| Subtitle | 20 / 28 | Semibold (600) | Display |
| Title | 28 / 36 | Semibold (600) | Display |
| Title Large | 40 / 52 | Semibold (600) | Display |
| Display | 68 / 92 | Semibold (600) | Display |

Rules Microsoft itself follows: only Regular and Semibold (never Bold, never Italic); sentence case everywhere including titles; minimums of 12px Regular / 14px Semibold. Settings page titles = Title (28/36 SB); card titles = Body (14); card descriptions = Caption (12) in `TextFillColorSecondary`.

### 1.5 Spacing rhythm and control metrics

- Base unit **4px**; common paddings are 8/12/16/24/32/40.
- SettingsCard: min-height ~68px, padding 16px, ~16px gap icon→text, ~4px gap between stacked cards.
- Standard button: 32px tall, ~11px horizontal padding, 4px radius, `ControlFillColorDefault` + elevation stroke. Accent button: `AccentFillColorDefault` bg, no visible border, white (light) / black (dark) text.
- **ToggleSwitch**: 40×20px track, 4px-from-edge 12px round knob. Off: `ControlAltFillColorSecondary` track + 1px `TextFillColorSecondary`-ish strong stroke, knob in secondary text color. On: `AccentFillColorDefault` track, knob = `TextOnAccentFillColorPrimary`. Native micro-interactions: knob grows to ~14px on hover, stretches horizontally on press, and *slides* (~150ms ease) between states — these motions are most of the perceived quality.
- Focus visuals: 2px outer black/white `FocusStrokeColorOuter`/`Inner` double-ring, offset outside the control (`outline: 2px solid; outline-offset: 1px` + inner ring via box-shadow).

---

## 2. Electron specifics

### 2.1 Mica

```js
new BrowserWindow({
  backgroundMaterial: 'mica',        // 'auto' | 'none' | 'mica' | 'acrylic' | 'tabbed'
  titleBarStyle: 'hidden',
  titleBarOverlay: { color: '#00000000'-ish per theme, symbolColor: '#e4000000'/'#ffffff', height: 48 },
  // do NOT set transparent: true — background materials are incompatible with transparent windows
})
```

- `backgroundMaterial` (and `win.setBackgroundMaterial()`) is **Windows 11 22H2+ only**.
- For Mica to show through, the page itself must not paint an opaque background: `html, body { background: transparent }`, and don't set an opaque `backgroundColor` on the window. The Mica pixels are drawn by DWM *behind* the WebContents.
- **Known Electron bugs to design around**: material can disappear after minimize→restore of frameless windows (electron#38743); rounded-corner/material inconsistencies on maximize/restore of frameless windows (electron#46753, #42393); combining with `transparent: true` breaks it and kills Aero Snap. Test on your target Electron version; keep a **solid fallback**: if `backgroundMaterial` is unavailable (Win10, VMs, DWM off), paint `SolidBackgroundFillColorBase` (`#F3F3F3` light / `#202020` dark) — this is exactly what WinUI does when Mica is unavailable, and the UI still looks correct because all the card/control fills are alpha-composited.
- The community `mica-electron` package predates native support; with Electron ≥22 you don't need it.

### 2.2 Titlebar

`titleBarStyle: 'hidden'` + `titleBarOverlay` gives you native Windows caption buttons (min/max/close with correct hover states incl. red close) overlaid on your own HTML titlebar. Set `height: 48` to match Settings' tall header, `color` to transparent-ish/theme color and `symbolColor` per theme (update on theme change via `win.setTitleBarOverlay()`). Make your header a drag region with `-webkit-app-region: drag` (and `no-drag` on interactive children), and use `env(titlebar-area-*)` CSS variables to lay out around the overlay.

### 2.3 Theme + accent sync

- Chromium maps the Windows *app* theme to `prefers-color-scheme` automatically — a plain CSS media query tracks Settings > Personalization > Colors live. Use `nativeTheme.shouldUseDarkColors` + the `'updated'` event in main to swap `titleBarOverlay` symbol colors and the fallback `backgroundColor`.
- Accent: `systemPreferences.getAccentColor()` and the `'accent-color-changed'` event; push into a CSS custom property (`--accent-default`, etc.).

### 2.4 Fonts

- **Segoe UI Variable ships with Windows 11** as three installed families: `"Segoe UI Variable Small"` (captions ≤12px), `"Segoe UI Variable Text"` (body 12–16px), `"Segoe UI Variable Display"` (≥18–20px). Chromium exposes all three as local families — use the right subfamily per ramp step rather than relying on automatic `opsz` (Chromium's handling of the optical axis via the bare `"Segoe UI Variable"` name is unreliable). Stack: `font-family: "Segoe UI Variable Text", "Segoe UI", -apple-system, sans-serif;` and weights 400/600 only.
- **Segoe Fluent Icons also ships with Windows 11** — `font-family: "Segoe Fluent Icons"` and PUA codepoints (e.g. `` Settings, `` Bluetooth, `` chevron-down) gives you pixel-identical Settings iconography for free at 16px. Fallback chain to `"Segoe MDL2 Assets"` for Win10. Don't bundle it (license); for cross-platform builds, `@fluentui/svg-icons` (Fluent System Icons) is the redistributable alternative but the glyph style differs slightly from Settings.

---

## 3. Component-library options

| Option | What it is | Fidelity to Win11 Settings | Weight / risk |
|---|---|---|---|
| **@fluentui/web-components v3** (`web-components.fluentui.dev`) | Microsoft's official Fluent 2 web components (successor to FAST-based v2) | **Medium-low.** Fluent 2 *web* is the Teams/M365 flavor: web brand ramp (Teams-ish blue) not the Windows accent ramp, different tokens, no Mica-aware alpha surfaces, no SettingsCard/Expander/NavigationView equivalents. You'd restyle heavily. | Moderate bundle; v3 still churning; token system fights the WinUI values above |
| **fluent-svelte** (used for the Files-app website) | Community Svelte library explicitly cloning WinUI/Windows 11 controls | **High** — visually the closest off-the-shelf | Svelte-only, effectively unmaintained since ~2022; fine as a *reference implementation* to crib CSS from even if you don't adopt Svelte |
| **Hand-rolled CSS** with the token tables above | ~300–500 lines of custom properties + a dozen components (card, expander, toggle, button, nav item, combo) | **Highest** — you control alpha compositing over Mica, exact radii, toggle micro-animations | Near-zero weight; you own combobox/flyout a11y yourself |

**Recommendation for FrameForge:** hand-roll. The Settings app look is ~90% *tokens + layering + type ramp*, all documented above; no web library ships the Mica-composited alpha surfaces, and restyling Fluent 2 web components costs more than writing the CSS. Define every token in §1.3 as CSS custom properties under `:root` / dark overrides, build `SettingsCard`/`SettingsExpander` as plain components, use native Segoe Fluent Icons, and reserve library adoption only if you later need heavy widgets (data grid, date picker). Use fluent-svelte's source and the WinUI 3 Gallery app (Microsoft Store) as visual truth for states you can't find documented (toggle knob animation timings, focus rings, expander chevron rotation).

---

## Sources

- [XAML theme resources — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/platform/xaml/xaml-theme-resources)
- [`Common_themeresources_any.xaml` — microsoft/microsoft-ui-xaml](https://github.com/microsoft/microsoft-ui-xaml/blob/winui2/main/dev/CommonStyles/Common_themeresources_any.xaml) (source of all fill/stroke/text hex values)
- [Typography in Windows / Windows type ramp — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/design/style/typography)
- [Electron BrowserWindow docs (`backgroundMaterial`, `titleBarOverlay`)](https://www.electronjs.org/docs/latest/api/browser-window)
- Electron issues [#38743](https://github.com/electron/electron/issues/38743), [#46753](https://github.com/electron/electron/issues/46753), [#42393](https://github.com/electron/electron/issues/42393), [#29937](https://github.com/electron/electron/issues/29937)
- [Windows 11 accent palette values (winaccent / elevenforum registry defaults)](https://www.elevenforum.com/t/default-registry-values-for-colors-windows-11.15580/)
- [Fluent UI Web Components](https://web-components.fluentui.dev/) · [microsoft/fluentui](https://github.com/microsoft/fluentui) · [Fluent 2 — Windows](https://fluent2.microsoft.design/components/windows)
- [Segoe Fluent Icons font — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/design/style/segoe-fluent-icons-font)
- [mica-electron (community, pre-native-support)](https://github.com/GregVido/mica-electron)

## Key findings

- The Settings-app look is three composited layers: OS-drawn Mica window background, LayerFillColorDefault content region, and alpha-white cards (CardBackgroundFillColorDefault = #B3FFFFFF light / #0DFFFFFF dark over base #F3F3F3 / #202020) — keeping the alpha values instead of flattening to opaque hex is what makes it read as native.
- Exact WinUI token values were pulled from microsoft-ui-xaml Common_themeresources_any.xaml: e.g. CardStrokeColorDefault #0F000000/#19000000, ControlFillColorDefault #B3FFFFFF/#0FFFFFFF, TextFillColorPrimary #E4000000/#FFFFFF, TextFillColorSecondary #9E000000/#C5FFFFFF, SubtleFillColorSecondary #09000000/#0FFFFFFF.
- Radii are ControlCornerRadius 4px (buttons, inputs, nav items, settings cards) and OverlayCornerRadius 8px (flyouts, dialogs); the settings NavigationView pane defaults to 320epx with a 3px-wide accent selection pill.
- Accent mapping: light theme uses SystemAccentColorDark1 (#0067C0 for default blue) and dark theme uses SystemAccentColorLight2 (#4CC2FF) with BLACK text/knob on accent in dark mode; full default-blue ramp is #99EBFF/#4CC2FF/#0091F8/#0078D4/#0067C0/#003E92/#001A68, readable live via systemPreferences.getAccentColor().
- Type ramp: Caption 12/16 Regular (Segoe UI Variable Small), Body 14/20 and Body Strong 14/20 SB (Text), Subtitle 20/28 SB, Title 28/36 SB, Title Large 40/52 SB (Display); only weights 400/600, sentence case everywhere — Windows 11 ships the three optical subfamilies as separate local font families Chromium can use directly.
- Electron supports native Mica via BrowserWindow backgroundMaterial:'mica' (Windows 11 22H2+ only) with html/body transparent; never combine with transparent:true, and known bugs exist around minimize/restore and maximize with frameless windows (electron#38743, #46753), so ship a solid #F3F3F3/#202020 fallback exactly like WinUI does.
- titleBarStyle:'hidden' + titleBarOverlay {color, symbolColor, height:48} gives native Windows caption buttons over a custom HTML titlebar; prefers-color-scheme tracks the Windows app theme automatically and nativeTheme's 'updated' event should drive titleBarOverlay recoloring.
- Segoe Fluent Icons ships with Windows 11 and can be used straight from CSS (font-family: 'Segoe Fluent Icons' with PUA codepoints) for pixel-identical Settings iconography — no icon bundle needed.
- Library verdict: hand-rolled CSS from the token tables is the recommended path — @fluentui/web-components v3 is the Teams/M365 Fluent-2-web flavor (wrong palette, no SettingsCard/NavigationView, no Mica-aware surfaces), while fluent-svelte is visually closest but Svelte-only and unmaintained, best used as a reference implementation.
- Key control metrics: SettingsCard min-height ~68px with 16px padding and ~4px stack gap; buttons 32px tall with a bottom-heavy 'elevation' border (ControlStrokeColorDefault + darker ControlStrokeColorSecondary bottom edge); ToggleSwitch is a 40x20 track whose 12px knob grows on hover and slides ~150ms — these micro-interactions carry most of the perceived native quality.
