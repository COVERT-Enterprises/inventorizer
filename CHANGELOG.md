# Changelog — COVERT PC Inventorizer

Versioning follows the **COVERT scheme: `vYY.MAJOR.PATCH`**

- `YY` — two-digit release year (`26` = 2026). The first release of a new year resets MAJOR to 1 (e.g. first 2027 build = `v27.1.0`).
- `MAJOR` — feature release counter within the year: new categories, new systems, major reworks.
- `PATCH` — small fixes and adjustments within that major release.

Keep this file in sync with the hosted `version.json` (see `update-manifest.sample.json`) —
the in-app updater builds its "what you're missing" list and full changelog from that manifest.

---

## v26.7.2 — 2026-07-22

### Highlights
- THEME STUDIO :: custom themes can now **choose their own backdrop texture** — press **[T]** in the Theme Studio to open the picker. The highlighted texture **animates live behind the list** as you browse (the list *is* the preview), so you see exactly what you'll get. Choose any of the eleven backdrops — none, stardust, code rain, starfield, embers, snowfall, drift, shine, neon grid, blueprint, or deep-water bubbles — and it renders in your own custom palette. Enter keeps it, esc reverts.

### Notes
- new setting `customTexture` (defaults to `stardust`); older configs adopt the default automatically, validated on every load
- completes the Theme Studio work promised in v26.7.1

## v26.7.1 — 2026-07-22

### Highlights
- REINSTALL PLAN :: after a sweep, press **[R]** to build a follow-along **reinstall document** — tick which apps to include and it writes a themed `reinstall_plan.html`: an interactive checklist (progress saved in your browser), a copy-paste **winget batch** for the matched apps, and a separate manual-reinstall list for the ones winget can't find
- THEME :: new **deep water** theme — a dark-ocean palette with **bubbles rising** from the depths
- TEXTURES :: rewritten to paint the whole backdrop in **one write per frame**, so they're smooth at full-screen (fixes the ember stutter and matches the boot rain's feel); the matrix texture now uses the full film-style character set, not just binary
- TEXTURES :: **arctic snow now falls** (was rising); stardust and drift descend too

### Notes
- FIX: resizing the window mid-animation no longer latches all textures off — a resize simply aborts the current frame and the menu redraws (the gold-shine + resize breakage is resolved)
- boot animation `wall` renamed to **`pillar`** (saved configs migrate automatically)
- the pyramid boot animation lingers about a second longer before the console loads
- text prompts already centered; the reinstall picker reuses the scrollable checkbox pattern
- deferred: making the gold shine sweep *over* the menu text (brightening it) needs the full-screen compositor and isn't reliable yet — kept the shine in the backdrop for now
- still to come: a texture picker in the Theme Studio for custom palettes

## v26.7.0 — 2026-07-20

### Highlights
- THEMES :: palette reworks for a truer feel — **black & gold** and **black & green (matrix)** now sit on near-pure black with brighter, more saturated accents; **midnight** is genuinely deep (was too bright to earn the name); **arctic** is now a **frost-white light theme** with a strong arctic-blue accent; **ember** dropped to near-black
- THEMES :: `mono` renamed to **`monochrome`** (saved configs migrate automatically)
- TEXTURES :: every theme now has its own **ambient background texture** that animates behind the main menu while it is idle (only when animations are ON) — matrix **code rain** (digits/letters/symbols like the film), midnight **starry night** (denser up top), ember **rising flames** (hot at the base, cooling as they climb), arctic **falling snow**, gold **occasional shine sweep**, monochrome **minimal drift**, synthwave **neon perspective grid**, void **pastel stardust**, ivory **blueprint grid**. The menu text is never touched — each line records the cells it occupies and the texture animates only around them, with no flicker
- FOCUSED WINDOW :: the texture always leaves a **1-cell clear border** on every side of the menu (plus the readability fade beyond it), so the interface reads as a bordered panel floating in the texture

- BACKGROUND :: **seamless single black** across every theme — the terminal used to show two shades (the 16-color palette black that `Clear-Host` fills with vs. the theme's true default background). The theme now redefines that exact palette entry (OSC 4) to match, so the fill, the ANSI resets, and the texture all agree on one black. Fixes the "jarring square" behind the boot animation and around the menu on gold/ember/matrix/etc.
- TEXTURE HALO :: the matrix rain now **fades into the background near the menu** and runs at full strength only out where nothing is shown, so it never obscures the interface
- BOOT :: boot animations fill the full width (no centered rectangle against the seamless background)
- WIZARD :: the first-run setup can now step **back** (esc) to revisit a choice, and **[P] previews** the highlighted theme (full mock screen), logo (the art), or boot animation before you commit
- SETTINGS :: the highlighted setting now shows a **live preview** — the logo art, a sample sweep bar in the chosen style, or a palette swatch — and **[P]** plays a full preview (boot animation, logo, theme mock, animated bar)
- INPUT :: text prompts (snapshot note, alias, tagline, output folder, search, hex) are now indented toward center instead of hugging the far-left edge

### Notes
- the texture stops instantly on any keypress and is skipped during input floods; a per-column falling-drop model keeps it cheap
- FAILSAFE: any console fault while animating latches the ambient off for the session and the menu falls back to its plain static wait; the texture never runs headless or in safe mode
- the redefined palette entry is restored on exit (OSC 104) alongside the default-background reset (OSC 111)
- all nine textures share one engine (per-cell function of column/row/frame + the halo); each is a first pass tuned by eye and easy to adjust
- still to come: a texture picker in the Theme Studio so a custom palette can choose any of these backdrops

## v26.6.0 — 2026-07-20

### Highlights
- THEME STUDIO :: the theme screen is now a studio. Seven new curated palettes — **black & gold** (premium), **black & green** (matrix/terminal), ember, synthwave, arctic, monochrome — plus a **custom palette** you design yourself: pick each of the three gradient anchors from a curated color set (or type an exact hex) and the entire console repaints live as you choose
- BOOT ANIMATION :: choose what plays at launch — the gradient wall, a drifting starfield, palette-tinted matrix rain, or a **pyramid that assembles itself** (the animated debut of the product mark) — or `random` for variety each launch, or `none`
- BAR STYLE :: swap the sweep progress bar's fill set — density ramp, solid blocks, dots, or arrows
- DASHBOARD :: new **VAULT DASHBOARD** — lifetime stats (sweeps run, distinct apps tracked, vault size), a sparkline trend of installed apps over time, and your recent sweeps with their notes
- FIRST RUN :: a one-time **setup wizard** greets new users — pick a theme, logo, and boot animation, optionally pin a baseline and schedule sweeps. Fully skippable
- NOTES :: label any snapshot with a note — press `[N]` right after a sweep or anytime from the Snapshot Manager; notes show in the manager and dashboard
- PERSONALIZE :: set a **machine alias** and your own **tagline**
- REPORT :: the HTML report is now **themed to match your palette**, embeds the pyramid mark, and opens with an overview — stat tiles, a category breakdown chart, and a drift panel when a baseline is set
- HELP :: press `?` at the main menu for a keyboard reference

### Notes
- new settings: bootStyle, barStyle, machineAlias, tagline, customTheme (three hex anchors), firstRunDone — all validated and self-repaired on load
- the custom palette keeps text-readability roles neutral by construction, so any gradient you pick stays legible
- the SETTINGS screen is now scrollable (it grew past one screen); per-row hints explain each option
- unicode bar/sparkline/matrix glyphs are built from code points so the script source stays pure ASCII
- the pyramid-build boot animation is the deferred pyramid animation, now shipped
- config JSON depth raised to 5 to serialize the custom palette

## v26.5.0 — 2026-07-20

### Highlights
- MEMORY :: the main menu now shows a **vault status line** — snapshot count, age of the last sweep, and total size on disk — so the console knows the machine at a glance
- MANAGER :: new **SNAPSHOT MANAGER** screen — browse every snapshot with age and size, open one in Explorer, delete with confirmation, pin a **baseline**, and set a **retention policy** (keep newest 5/10/20; the baseline is always exempt, oldest are auto-pruned after each sweep)
- BASELINE :: pin any snapshot as the baseline and every new sweep automatically reports **drift** against it (apps/drivers added, removed, updated) on the summary screen and in a `drift_vs_baseline.txt` report inside the snapshot
- SEARCH :: new **SEARCH SNAPSHOTS** screen (and `-Find "<term>"` CLI) — type an app or publisher and see when it first appeared, whether it's still present or when it was last seen, and its full version history across every snapshot
- SCHEDULE :: new **SCHEDULED SWEEPS** screen under SETTINGS (and `-Schedule daily|weekly` / `-RemoveSchedule` CLI) — register a Windows Task Scheduler job that runs a silent full sweep automatically
- CATEGORIES :: two new collectors bring the sweep to **17 categories**:
  - **SECURITY POSTURE** — Microsoft Defender status and exclusions, firewall profiles, BitLocker/drive encryption, TPM, Secure Boot, and UAC level
  - **BROWSER EXTENSIONS** — installed extensions for Chrome, Edge, Brave, Opera, Opera GX, and Firefox (per user profile, with localized extension names resolved)

### Notes
- retention pruning and the baseline diff run at the end of every sweep; both are recorded in `sweep.log`, and a `[DRIFT]` / `[RETENTION]` line is printed in silent mode
- deleting the pinned baseline is blocked in the manager until you unset it; a baseline whose folder later goes missing simply skips the drift comparison (logged) rather than erroring
- the vault status line is cached and refreshed after each sweep or deletion, so it never slows the menu
- schedule management auto-elevates (creating a Task Scheduler job requires admin); the registered task is the single source of truth — no schedule state is kept in `settings.json`
- new settings: `retentionKeep` (0 = off) and `baselineSnapshot`, both validated and self-repaired on load
- header comment and changelog title updated to COVERT branding

## v26.4.2 — 2026-07-20

### Highlights
- TONE :: interface copy moved from cyberpunk hacker-speak to professional language, keeping the visual identity untouched — headers keep the `::  ::` framing and gradients, the words now say what they mean

### Notes
- "SYSTEM SWEEP ENGAGED" -> "FULL SYSTEM SWEEP IN PROGRESS" (drops "FULL" automatically for partial category sweeps)
- main menu title is now "MAIN MENU" (the brand name stays on the boot screen and in reports)
- "DISENGAGE" -> "EXIT INVENTORIZER"; "OPEN SNAPSHOT VAULT" -> "OPEN SNAPSHOTS FOLDER"; "Q disengage" -> "Q exit"
- "categories armed" -> "categories selected"; "enter engage sweep" -> "enter start sweep"
- "SNAPSHOT SECURED" -> "SNAPSHOT COMPLETE" (with "saved to <path>"); "SNAPSHOT DELTA" -> "SNAPSHOT COMPARISON"
- "target <host>" -> "host <host>" on the sweep screen
- restore wizard: "SELECT WHAT COMES BACK" -> "SELECT PACKAGES TO REINSTALL"; "arm the restore" -> "continue to final confirmation"; "RESTORE ENGAGED" -> "RESTORE IN PROGRESS"; "ABORTED" -> "STOPPED"
- updater: "INCOMING TRANSMISSION" -> "UPDATE AVAILABLE"; "SELF-UPDATE ENGAGED" -> "SELF-UPDATE IN PROGRESS"; "CHECKING UPLINK" -> "CHECKING FOR UPDATES"
- crash screen: "FAULT CONTAINED" -> "UNEXPECTED ERROR"; exit line "channel closed" -> "session ended"

## v26.4.1 — 2026-07-20

### Highlights
- LOGO :: the product mark is now the **Refraction Pyramid** — one huge unified 3D monument (the floating capstone is retired): raw binary arcs down from the sky, steepening as it falls, and pours through the open face into the pyramid's heart; ordered report rays arc out of the shaded density-ramp face into `.txt` files; `I N V E N T O R I Z E R` engraved beneath the ground line

### Notes
- the mark merges the three chosen concepts: the monument and plaque from the capstone design, the falling binary from the refractor scene, the arcing file rays from the pipeline
- geometry is grid-plotted (66x13) - arc physics: horizontal drift shrinks row by row as the fall accelerates

## v26.4.0 — 2026-07-20

### Highlights
- RESTORE :: new **RESTORE FROM SNAPSHOT** wizard in the main menu — auto-loads restore data from every snapshot in the vault and walks through it step by step: pick a snapshot, tick exactly what comes back in a scrollable package picker (`space` toggle, `A` all, `N` none, `I` invert, pgup/pgdn), review the plan, then pass a final Y-gate. Nothing installs until both confirmations
- RESTORE :: the live run drives the sweep screen engine — maturation bar, transient `INSTALLING n/m` status, centered `[ OK ] / [SKIP] / [FAIL]` rows — and `Q` aborts cleanly between packages (the one in flight always finishes)
- RESTORE :: `[D]` dry-run preview from inside the wizard; every run (live or dry) is appended to `restore.log` in the snapshot; the manual-only checklist (programs winget can't match) gets its own pager at the end

### Notes
- winget output is captured during installs so its progress spinner cannot shred the fixed layout; "already installed" resolves to `[SKIP]`, failures keep an output tail in `restore.log`
- the wizard warns when running non-elevated, and refuses politely when winget itself is missing
- `restore.ps1` is still generated in each snapshot — the wizard is the in-app path, the script remains the portable one for machines without the Inventorizer
- main menu quick keys are now `1-6`
- fixed: the animation nap's skip-signal boolean leaked into the restore result object (PS pipeline unrolling strikes again)

## v26.3.0 — 2026-07-19

### Highlights
- RESTORE :: `restore.ps1` is now **selective** — running it plain opens a numbered picker (`A` = all, `1,4,7-10` = only these, `x2,5` = all except, `Q` = quit); `-All` keeps the old install-everything behavior; `-DryRun` previews either mode. Built for the reinstall-Windows-to-debloat workflow: bring back only what you actually want
- RESTORE :: programs the sweep found in the registry that winget could not match are now a first-class `$manual` list — printed at the end of every restore run as your manual-reinstall checklist, not just buried in comments
- LOGO :: the product mark is now **the Pyramid** (default logo) — humanity's oldest surviving vault: a floating solid capstone above an open line-art monument whose shaded face matures through the density ramp, on a thin ground line

### Notes
- prism logo retired (was a mislabeled concept); configs pointing at it self-heal to the default
- logo picker labels: "inventorizer (pyramid)", "inventorizer (wordmark)", "inventorizer (minimal)"
- pyramid animation is planned for a later release; the mark is static for now

## v26.2.3 — 2026-07-19

### Highlights
- LOGO :: the Prism remade as an actual 3D prism — front face wireframe with dotted depth edges, raw bits raining in from above, ordered numbered files raying out of the far face; **now the default logo**
- BOOT :: the prism animates during the boot sequence when animations are ON (bits twinkle in, ray bodies march outward); static image otherwise
- BOOT :: the density wall now tapers non-linearly toward both sides, so the scrolling bands read as a 3D spiral descending a tube

### Notes
- prism frames are generated on a plotted character grid - geometry stays exact
- the broken-logo self-heal now rolls back to the current default logo instead of hardcoded cxt

## v26.2.2 — 2026-07-19

### Highlights
- LOGOS :: new product mark — **the Prism**: loose data motes rain into a crystal that matures through the product's own density ramp (`. : - = + * # % @`) and solidifies — a system sweep, crystallized; select it via SETTINGS > LOGO ("inventorizer (prism)")

### Notes
- logo picker now shows friendly labels: "inventorizer (prism)", "inventorizer (wordmark)"
- prism art is generated at runtime, guaranteeing exact symmetry at any scale change

## v26.2.1 — 2026-07-19

### Highlights
- BOOT :: the density-wall boot animation now fills the entire terminal top to bottom, then keeps printing past the bottom so the console's natural scroll animates the wall
- IDENTITY :: system info redesigned into a clean label/value column block — one fact per line, left-aligned internally, centered on screen as a group
- LOGOS :: new bold `covert` ASCII wordmark (heavy geometric letterforms matching the brand logo); `minimal` now reads INVENTORIZER; `xv` retired

### Notes
- saved configs still pointing at the retired `xv` logo self-repair to `cxt` on load
- a logo wider than the current window now swaps to the one-liner instead of wrapping
- boot wall is skipped entirely when animations are OFF (no more instant flash)

## v26.2.0 — 2026-07-19

### Highlights
- THEMES :: enforced terminal background with three presets — `void` (black, default), `midnight` (dark blue), `ivory` (light) — switchable live in SETTINGS; each preset statically decides every text color so everything stays readable on any background
- BAR :: progress bar redesigned to cell-maturation — 20 cells x 5%, each maturing `. : = # % @` as its slice completes; a full bar is solid `@`
- SWEEP SCREEN :: bar now sits top-center under the target line; category results are centered; post-sweep steps show in a transient status line and vanish when done (full record kept in a new per-snapshot `sweep.log`)
- RESIZE :: menus auto-refresh and re-center when the terminal window is resized
- BRANDING :: company COVERT / product PC Inventorizer / build string `v26.2.0 (Windows) x64` with machine-read architecture (failsafe placeholder `CxT` when unreadable)

### Notes
- fixed the right-click "spazz" — right-click pastes the clipboard in Windows terminals and every pasted character triggered a full menu redraw; redraws now coalesce until the input buffer drains
- fixed duration formatting: `(   1,0s)` -> `873ms` / `4.2s` / `2m 05s` (locale-proof decimal point)
- fixed a float-precision bug where 1% showed an empty cell and 100% showed a not-quite-full bar
- user line now shows the account's full name alongside the login name, e.g. `Richard Brodzinski (ricar)` (failsafe chain: Get-LocalUser -> WMI -> env var)
- manifest now records company, platform, arch and build; OS build number renamed to `osBuild`
- original terminal colors are restored on exit

## v26.1.1 — 2026-07-19

### Highlights
- FAILSAFES :: safe-mode boot window (press `S` within 2s of launch, or run with `-SafeMode`) starts the console with a clean default config without touching the saved one
- FAILSAFES :: crash containment — an unexpected fault in any screen now shows a recovery screen (retry / safe mode / quit) instead of closing the window
- FAILSAFES :: settings are validated and self-repaired on load; corrupt config files are quarantined and the last good backup is restored; saves are verified before they replace the live config
- SETTINGS :: new "RESET CONFIG TO DEFAULTS" action

### Notes
- fixed the softlock when switching the logo to "wordmark" — a PowerShell comma-precedence bug in the art builder crashed every launch once the choice was saved
- fixed the "xv" logo's sigil line rendering as three broken lines (same precedence bug)
- fixed the "minimal" logo rendering as a single dot (single-element array unrolling made the renderer index characters instead of lines)
- a broken configured logo now renders a fallback sigil and rolls the config back to `cxt` automatically

## v26.1.0 — 2026-07-19

### Highlights
- Initial release: 15-category sweep engine (system, installed programs, Store apps, signed drivers, driver store, features, capabilities, updates, services, startup, scheduled tasks, network, storage, dev runtimes, environment)
- Timestamped snapshots: styled TXT reports + `00_FULL_INVENTORY.txt` + JSON mirrors + `manifest.json`
- Snapshot diff engine — compare any two snapshots (apps/drivers installed, removed, updated), in-app or headless via `-Compare`
- Winget restore script generator (`restore.ps1` with `-DryRun`)
- Dark-themed single-file HTML report
- COVERT visual engine: CxT crescent logo + 3 alternates (live-swappable), truecolor pink→violet→cyan gradients, density-ramp fill bars, boot sequence
- Self-update engine: version channel check on launch, "missing out" highlights, full changelog view, one-key update with sha256 + syntax validation and automatic backup

### Notes
- Adopted COVERT `vYY.MAJOR.PATCH` versioning (internal `1.0.0` build was never published)
- Silent/headless mode (`-Full -Silent`) never elevates, never prompts, never checks for updates
- Settings persisted to `config\settings.json`; CLI flags override per-run only
