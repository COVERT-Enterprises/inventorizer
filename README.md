# COVERT PC Inventorizer

A self-contained PowerShell inventory console for Windows by **COVERT**. One
script, zero dependencies. Sweeps installed software, drivers and system state
into timestamped **snapshots** (styled TXT reports + JSON mirrors + HTML
report), diffs snapshots over time, and generates a winget **restore script**
that can rebuild a fresh PC. Build strings follow
`v<version> (<platform>) <arch>`, e.g. `v26.2.0 (Windows) x64`.

*🤖 [Claude](https://claude.com/claude-code) by Anthropic helped with the port to GitHub.*

## Quick start

> **Download:** grab the latest build from the [Releases](../../releases) page and unzip it (or clone the repo), then:

Double-click **`Inventorizer.cmd`** (or run `.\Inventorizer.ps1` in PowerShell).
The console boots, asks for elevation (richer data), and drops you into the menu:

| Menu | What it does |
|---|---|
| FULL SYSTEM SWEEP | Inventories all 17 categories into a new snapshot |
| SELECT CATEGORIES | Checkbox picker — sweep only what you want |
| COMPARE SNAPSHOTS | Diffs two snapshots: apps/drivers installed, removed, updated |
| RESTORE FROM SNAPSHOT | Step-by-step wizard: pick a snapshot, tick exactly which packages come back, review, confirm — then winget reinstalls them |
| SEARCH SNAPSHOTS | Find an app or publisher across every snapshot: first seen, still-present-or-last-seen, full version history |
| VAULT DASHBOARD | Lifetime stats and a trend of apps tracked over time |
| SNAPSHOT MANAGER | Browse snapshots (age + size), open, delete, pin a baseline, add notes, set a retention policy |
| SETTINGS | Logo, Theme Studio, boot animation, bar style, alias/tagline, animations, JSON/HTML/restore toggles, scheduled sweeps, output folder |

Press `?` at the main menu for a keyboard reference. First launch runs a quick,
skippable setup wizard.

## Automation / CLI

```powershell
.\Inventorizer.ps1 -Full                 # immediate full sweep (with visuals)
.\Inventorizer.ps1 -Full -Silent         # headless - for Task Scheduler (no UAC prompt; schedule the task elevated for full data)
.\Inventorizer.ps1 -Categories SYSTEM,SERVICES,DRIVERS_SIGNED
.\Inventorizer.ps1 -OutputPath "D:\Snapshots" -NoElevate
.\Inventorizer.ps1 -NoLogo               # skip the boot sequence once
.\Inventorizer.ps1 -Silent -Compare "LEGION_2026-07-19_0445,LEGION_2026-08-01_0900"
                                         # headless diff: baseline,comparison (snapshot folder names or full paths)
.\Inventorizer.ps1 -Find "steam"         # search every snapshot for an app; prints its timeline
.\Inventorizer.ps1 -Schedule weekly      # register a weekly silent full sweep (auto-elevates)
.\Inventorizer.ps1 -Schedule daily -ScheduleTime 07:30
.\Inventorizer.ps1 -RemoveSchedule       # remove the scheduled sweep task
```

Category ids: `SYSTEM, APPS_INSTALLED, APPS_STORE, DRIVERS_SIGNED, DRIVER_STORE,
WINDOWS_FEATURES, WINDOWS_CAPABILITIES, UPDATES, SERVICES, STARTUP,
SCHEDULED_TASKS, NETWORK, STORAGE, DEV_RUNTIMES, ENVIRONMENT, SECURITY,
BROWSER_EXTENSIONS`

## What a snapshot contains

```
snapshots\<HOST>_<date>_<time>\
├── 00_FULL_INVENTORY.txt     everything combined, with table of contents
├── 01_SYSTEM.txt ... 17_BROWSER_EXTENSIONS.txt
├── json\<category>.json      machine-readable mirrors
├── manifest.json             normalized app/driver lists (feeds the diff engine)
├── report.html               dark-themed single-file report        [toggleable]
├── restore.ps1               selective winget reinstall script     [toggleable]
│                             (interactive picker; -All for everything; -DryRun to preview;
│                              ends with the manual-reinstall list winget couldn't match)
├── restore.log               appended by every restore run (wizard live/dry runs)
├── reinstall_plan.html       follow-along reinstall checklist       [built on demand]
├── drift_vs_baseline.txt     drift report vs the pinned baseline    [when a baseline is set]
├── sweep.log                 timestamped record of the sweep
└── winget_export.json        raw winget export                     [toggleable]
```

## Restoring a machine

Three paths, same data:

- **In-app wizard** — RESTORE FROM SNAPSHOT in the main menu. Auto-loads every
  snapshot in the snapshots folder, then walks you through it: pick the snapshot, tick
  exactly which packages come back (`space` toggle, `A` all, `N` none, `I`
  invert), review the plan, dry-run it if you like, and pass a final
  confirmation before winget touches anything. `Q` aborts between packages.
  Programs winget couldn't match are shown as a manual-reinstall checklist.
- **`restore.ps1`** — the standalone script inside each snapshot, for rebuilding
  a fresh Windows install where only the snapshot folder exists. Same selective
  picker, `-All` and `-DryRun` switches, same manual list at the end.
- **Reinstall plan** (`reinstall_plan.html`) — for rebuilding *by hand* at your
  own pace. Right after a sweep press **[R]**, tick which apps you want, and it
  writes a themed HTML checklist: an interactive tick-off list (progress saved in
  your browser), a copy-paste winget batch for the matched apps, and a separate
  manual list for the rest. Open it on any device and follow along.

## Tracking a machine over time

The Inventorizer is built to be run repeatedly — the value compounds as snapshots
accumulate. The main menu shows a **vault status line** (snapshot count, age of the
last sweep, total size) so you always know where you stand.

- **Baseline & drift** — in the SNAPSHOT MANAGER, pin any snapshot as the
  **baseline** (e.g. a freshly-imaged, debloated machine). Every sweep afterward
  automatically diffs against it and reports **drift** — what's been added,
  removed, or updated since — on the summary screen and in a
  `drift_vs_baseline.txt` report inside the new snapshot.
- **Snapshot manager** — browse every snapshot with its age and size on disk,
  open one in Explorer, or delete ones you don't need (the baseline is protected
  until you unpin it). Set a **retention policy** (keep the newest 5 / 10 / 20)
  and older snapshots are pruned automatically after each sweep — the baseline is
  always kept.
- **Search** — SEARCH SNAPSHOTS (or `-Find "<term>"`) walks every snapshot and
  answers *"when did this app first appear, is it still here, and how did its
  version change?"* — matching on app name or publisher.
- **Scheduled sweeps** — SETTINGS ▸ SCHEDULED SWEEPS (or `-Schedule daily|weekly`)
  registers a Windows Task Scheduler job that runs a silent full sweep on its own,
  so the history keeps building without you remembering to run it.

## Versioning & updates

Versions follow the COVERT scheme **`vYY.MAJOR.PATCH`** — `26.1.0` = first major
release of 2026; the middle number is a feature release, the last a small fix.
Full history lives in `CHANGELOG.md`.

The script has a built-in update engine. On launch (interactive mode only) it
quietly polls an update channel; when a newer build exists it shows what you're
missing, offers a full in-depth changelog, and can update itself in one key —
downloading the new build, verifying its sha256 and syntax, archiving the old
version to `config\backup\`, and relaunching. You can skip a version, or turn
the check off entirely in SETTINGS.

The channel is **not configured yet**: when you have a repo, host a
`version.json` (format documented in `update-manifest.sample.json`) plus the
raw `Inventorizer.ps1`, and put the manifest URL into `UpdateUrl` in the
`$Brand` block at the top of the script.

## Configuration

Settings persist in `config\settings.json` (auto-created on first run) — logo,
theme (incl. a custom palette), boot animation, bar style, machine alias,
tagline, animations, and the JSON / HTML / restore-script toggles. Edit them in
the SETTINGS screen (scrollable, with per-row hints) or directly in the file.

## Themes & the Theme Studio

The console enforces its own terminal background (and restores yours on exit).
Switch live under SETTINGS > THEME:

- **void** — black, pastel COVERT gradient (default)
- **midnight** — dark blue, brightened dims
- **ivory** — light background, dark text
- **gold** — black & gold (premium)
- **matrix** — black & green (terminal)
- **ember** / **synthwave** / **arctic** / **monochrome** — warm / neon / ice / grayscale
- **deep water** — dark ocean blues, with rising bubbles
- **custom** — your own palette, built in the **Theme Studio**

Every theme has its own **animated background texture** behind the main menu
(when animations are on): matrix code rain, midnight stars, ember flames, arctic
snow, gold shine, monochrome drift, synthwave grid, void stardust, ivory
blueprint, deep-water bubbles. The texture always leaves a clear border around
the menu so the interface stays crisp.

The **Theme Studio** (SETTINGS > THEME STUDIO) lets you design the custom
palette: pick each of the three gradient anchors from a curated color set — or
type an exact `#RRGGBB` — and the whole console repaints live as you go. Text
stays readable on any gradient because the studio keeps the readability roles
neutral by construction.

You can also give a custom theme its own **backdrop texture** — press `T` in the
Theme Studio to open the picker. The highlighted texture animates live behind the
list as you browse (so the list itself is the preview); choose any of the eleven
backdrops — none, stardust, code rain, starfield, embers, snowfall, drift, shine,
neon grid, blueprint, or deep-water bubbles — and it renders in your own palette.

Every preset statically defines *every* color the app uses (including the HTML
report, which renders in your active palette), so text stays readable no matter
which background you pick — all output flows through the theme's color roles.

## Personalization & boot

- **Boot animation** (SETTINGS > BOOT ANIMATION): `pillar`, `starfield`, `matrix`
  (palette-tinted rain), `pyramid` (the mark assembling itself), `random`, or `none`.
- **Bar style** (SETTINGS > BAR STYLE): `density`, `blocks`, `dots`, or `arrows`.
- **Machine alias** and **tagline**: nickname the machine and set your own boot banner.

## Failsafes

The console is designed to be un-brickable by configuration:

- **Safe mode** — press `S` during the 2-second boot window (or launch with
  `-SafeMode`) to start with a clean default config. Your saved config file is
  not touched; persist the rescue with SETTINGS > RESET CONFIG TO DEFAULTS.
- **Crash containment** — an unexpected fault in any screen shows a recovery
  screen (retry / safe mode / quit) instead of closing the window.
- **Config self-repair** — settings are validated on every load; broken values
  roll back to defaults, corrupt files are quarantined to
  `config\settings.corrupt.json`, and the last good `settings.backup.json` is
  restored automatically. Saves are verified before replacing the live file.
- **Logo rollback** — if the configured logo's art ever fails to render, a
  fallback sigil is shown and the config heals itself back to `cxt`.

## Notes

- Windows PowerShell 5.1+ (ships with Windows). Windows Terminal recommended
  for the full truecolor gradient experience; everything degrades gracefully.
- Non-elevated runs still work — admin-flavored categories are marked
  `[ LIMITED ]` in their reports.
- Reports may include hostnames, usernames, MAC/IP addresses and installed
  software lists. Treat snapshots as private before sharing them.

## License

Released under the [MIT License](LICENSE) © 2026 COVERT Enterprises.
