# Architecture: how the kit works

> **Owns:** how the loader, menus, engine, publish and CI work now (present tense). **Does not cover:** counts,
> dates or open bugs (→ [STATUS](STATUS.md)), history (→ [CHANGELOG](CHANGELOG.md)), usage (→ [README](../README.md)).

## Ownership map

| Doc / file | Single source of truth for… | Does **not** cover |
|---|---|---|
| [README.md](../README.md) | What the kit is, how to run it, how to add a package. | Internals, counts. |
| [CLAUDE.md](../CLAUDE.md) | Constraints, drift rules, continuity protocol, lint exclusions. | Current state. |
| [STATUS.md](STATUS.md) | Every volatile fact: counts, last publish, open bugs, next step. | How it works. |
| [CHANGELOG.md](CHANGELOG.md) | Dated history, append-only. | Current state. |
| architecture.md (this) | How the loader, menus, engine, publish and CI work. | Counts, history. |
| [src/catalog.psd1](../src/catalog.psd1) | The app catalogue (names, methods, IDs/URLs, groups, defaults, detection) and the direct-download rules. | Never copy it into docs. |
| `$script:Fixes` in [win11-tweaks.ps1](../win11-tweaks.ps1#L87) | The tweak catalogue (registry keys, apply/check/revert). | |

## Repo layout and delivery

```
install.cmd  install.ps1           # launcher + loader (Windows PowerShell 5.1, zero deps)
src/catalog.psd1                   # the app list (data only)
src/core.psm1                      # install engine, shared by both menus (5.1-compatible)
src/tui-spectre.ps1                # modern menu (PowerShell 7.4+ + PwshSpectreConsole)
src/tui-classic.ps1                # fallback menu (Windows PowerShell 5.1)
win11-tweaks.ps1                   # registry tweaks menu (launched from both menus or on its own)
tools/publish.ps1                  # repo → OneDrive copy (one way)
tools/lint.ps1  tools/test-core.ps1  tools/smoke-tui.ps1  tools/smoke-loader.ps1
PSScriptAnalyzerSettings.psd1
.githooks/post-commit  post-merge  publish-on-main
.github/workflows/lint.yml         # quality gate only
docs/
```

`install.cmd` launches `%~dpn0.ps1` (its own name with `.ps1`), so it sits beside `install.ps1`. The published
folder mirrors the repo: kit files at the top, `src/` beside them.

| Channel | What | How | Trigger |
|---|---|---|---|
| OneDrive publish | `src/*`, `win11-tweaks.ps1`, `install.cmd`, `install.ps1` | `tools/publish.ps1` → `$env:OneDrive\[98] Shortcuts`, then OneDrive syncs every PC | git hook on commit/merge on `main` |
| CI | lint + dry-run tests | GitHub Actions, `windows-latest` | push to `main`, PRs |
| GitHub | source of truth + backup | `git push` | by hand |

## Start-up: install.ps1 (the loader)

Runs on stock Windows PowerShell 5.1 with nothing installed.

1. **Bootstrap:** TLS 1.2, `Unblock-File` on every kit file (mark-of-the-web), recreate `install.cmd` if missing.
2. **Find PowerShell 7** (`Find-Pwsh`): checks `pwsh` on PATH plus the known install paths (PATH is stale right
   after an install) and asks each candidate for its version. The best one wins.
3. **Decide:**
   - pwsh **7.4+** → `pwsh -NoProfile -ExecutionPolicy Bypass -File src\tui-spectre.ps1 -KitRoot <folder>`.
     If that exits **3** (Spectre module unavailable) → classic menu.
   - missing or older → asks "Install PowerShell 7 now? [Y/n]" (Enter = yes). `Install-Pwsh` tries
     `winget install Microsoft.PowerShell`, then the official MSI from the latest GitHub release (its
     Authenticode signer must be Microsoft Corporation; installs elevated). Then it re-finds pwsh by path and
     starts the modern menu.
   - declined or failed → `src\tui-classic.ps1` in the same 5.1 process.
4. Test switches (no effect on normal use): `-NoPwsh` / env `MYWINKIT_SIMULATE_NO_PWSH=1` pretend pwsh is
   absent, `-WhatIfLoader` prints the decision, `-Answer` answers the question, `-ClassicTestInput` feeds the
   classic menu, `-Classic` forces it, `-DryRun` passes through to either menu.

## The engine: src/core.psm1

No UI. Both menus call the same functions, so behaviour is identical in both.

- **`Initialize-Kit -KitRoot`** loads `catalog.psd1` (`Import-PowerShellDataFile`, data only), turns each entry
  into an object with a mutable `On`, and applies learned heals from `winget-id-overrides.json` beside
  `install.ps1` (old→new chains up to 5 hops; `msstore:` prefix switches channel).
- **`Get-KitInstalled`** returns `Id → version` for everything installed: one `winget export --include-versions`
  for all winget/Store IDs, plus per-package checks: `Appx` name (MSIX apps such as Claude Desktop), `Uninstall`
  DisplayName regex (direct installers), `Exe` path + `Version` command (script installs such as `claude`,
  `agy`). Odd winget version strings (`> 280.4`, `ad 9.8.0`) are reduced to the dotted number.
- **`Invoke-KitPackage -Package -Installed -Mode install|update -DryRun -OnStatus`** is the single entry point.
  It returns a result object (`Status` = installed | updated | current | done | failed | dryrun, `From`, `To`,
  `Detail`, `Healed`, `Seconds`) and writes everything to a log in `%TEMP%\my-win-kit\`. By method:
  - **winget / msstore:** `winget install --exact --silent`. A non-zero exit on an installed app = up to date.
    Self-healing: ID vanished (`0x8A150014`) → `Find-KitReplacementId` scores search hits (prefix/version
    split +6, same tail +4, exact name +3, pre-release −3; ≥ 3 wins) and retries; download dead (404, hash
    mismatch, nothing installed) → two previous versions, then the Store channel. Heals are saved to
    `winget-id-overrides.json`.
  - **script:** the vendor's official `irm <url> | iex`, always in a **child** `powershell.exe`, so a vendor
    `exit`/`throw` can't close the menu. When the tool is already installed and has an `Update` command
    (`claude update`, `agy update`), that runs instead. `Interactive` scripts (MAS, WinUtil) share the console.
  - **direct:** `Resolve-KitDirect` fetches the vendor's download page and pulls the current installer link with
    the catalogue regex (per CPU arch), so every run gets the vendor's latest release. If the installed version
    is already ≥ that, it reports up to date and downloads nothing. Otherwise it downloads to `%TEMP%`, requires
    a **valid Authenticode signature from the catalogue's signer** (Google LLC), runs it silently and waits for
    that process only. If the page no longer matches, it falls back to the `Fallback` winget ID for that run.
  - **npm:** `npm install -g` (needs Node). **builtin:** `enable-rdp` (registry + NLA + firewall group,
    elevated via UAC when needed; prints the Tailscale IP if present).
  - `Requires` (git, npm) is checked after reloading PATH from the registry, so a tool installed earlier in the
    same run is found.
- **`Get-KitRunOrder`** sorts by catalogue group order, then Id, with POST always last.
- **`Get-KitLatestVersion`** (direct = vendor page, winget = `winget show`) feeds the "Update AI tools" table.
- **State** (`%LOCALAPPDATA%\my-win-kit\state.json`, per PC, never synced): last selection, last failures,
  the desktop-shortcut setting. `MYWINKIT_STATE_DIR` overrides the folder (tests).
- **Desktop shortcuts:** snapshot before a run, delete new `.lnk` files after (setting, on by default).

## Modern menu: src/tui-spectre.ps1

PowerShell 7.4+ with **PwshSpectreConsole** (installed on first run with `Install-PSResource -Scope CurrentUser
-TrustRepository`, falling back to `Install-Module`; exit 3 if neither works, and the reason goes to the screen
and the run log). Spectre.Console .NET types draw everything (`Table`, `Rule`, `Panel`, `Status`, `Progress`,
`FigletText`). **Input never uses Spectre prompts** (they have no Esc/back key): it comes from the kit's own
picker, `Show-Picker`, built on `[Console]::ReadKey`.

- **Console set-up (order matters):** the script switches the console to UTF-8 *before* importing the module,
  because Spectre decides Unicode support once, when its console is created (a fresh console is code page 437:
  too late = every glyph prints as `?`). It then creates Spectre's console explicitly with TrueColor + ANSI +
  Unicode. Spectre's own detection turns colour off whenever `NO_COLOR` is set, and dev tools/agent shells export
  `NO_COLOR=1` to every window they start, so the kit ignores `NO_COLOR` (logged) and only drops colour for its
  own `MYWINKIT_NO_COLOR=1`. Window title: `my-win-kit · modern (PowerShell 7)`; the banner subtitle names the
  engine (`modern · PowerShell 7.x · Spectre 2.x`).
- **The picker (`Show-Picker`):** single- or multi-select. Keys: ↑↓ PgUp PgDn Home End move; Enter selects
  (multi: continue); **Esc, Backspace or ← = back** on every screen (with a filter active, the first press clears
  it); `/` = type-to-filter (multi-selects and search lists); multi: Space toggles (on a group header: the whole
  group), `a`/`n` = whole group on/off; main menu: `q` quits (Esc does nothing there). **Pinned rows** (« Back,
  and ► Continue on multi-selects) sit above the list and are never filtered or paged out. A footer always shows
  the keys, including `esc back`. **Sizing:** the list height = window height − rows already used on the screen
  − title/pinned/footer rows, so the whole picker always fits. In a real console it reserves its rows (printing
  newlines scrolls the window if needed) and then redraws in place (`SetCursorPosition` + `ESC[J`). Each row is
  cut to the window width with `Limit-Markup` (markup-aware, never wraps), because Spectre grids still wrap.
- **Tall tables are trimmed** so the action list stays on screen: the review table keeps window − 20 rows (new
  and updates first), the results table window − 21 rows (failures, heals and changes first), each with a
  "N more not shown" caption; the full list is in the log. Results get their own screen after the progress view.

- **Look:** truecolor gruvbox (hex styles, never the 16 console colours). The main menu opens with a "MY WIN KIT"
  Figlet banner (Spectre's built-in font, rendered once into a capture console, ~11 ms, then coloured column by
  column along an orange → yellow → green → aqua gradient), a subtitle (kit version, PC, PowerShell, admin) and,
  in dry run, a purple **DRY RUN** badge plus a full-width purple rule on every screen. Sub-screens use one
  gradient title rule. Tables and panels are rounded with coloured borders; each catalogue group has its own
  accent colour + icon (`$script:GroupStyle`). Quitting prints a gradient goodbye bar.
- **Glyphs:** only characters present in **both Consolas and Cascadia Mono** (verified with WPF `GlyphTypeface`),
  so classic conhost renders them without font fallback. Badges, used the same way in picker, review, progress
  and results: `√` installed (green), `↑` update available / updated (yellow / green), `·` not installed (grey),
  `×` failed (red), `↔` healed (aqua), `○` dry run (purple), `=` up to date (aqua). ✓ ✗ ↻ are missing from Consolas
  (and ✗ ↻ from Cascadia Mono), so they are not used. The spinner is Spectre's `Point` (`∙●∙`); the default
  `Dots` spinner uses Braille, which Consolas lacks.

- **Update badges:** `Get-KitUpdates` (one `winget upgrade`, ~2-3 s, plus the vendor page for direct apps) runs
  with the installed scan when the install screen opens, so the picker can show `↑ old → new`.
- **Main menu:** Install or update apps · Update AI tools · Windows tweaks · Settings · Quit, each with an icon
  and a one-line description.
- **Install flow:**
  1. scan installed apps (spinner);
  2. "Start from": recommended set / recommended but only what's missing / everything with an update / retry
     last failures / last selection / empty;
  3. grouped multi-select (a group header toggles the whole group), preselected, with each app's badge,
     installed version (→ available) and non-winget method;
  4. review table (App · Group · How · On this PC · Will) with actions: install now / search to add or remove
     (the picker opened in filter mode) / change the full list / main menu. Esc goes back one level each time:
     review → app list → start from → main menu;
  5. run: a Spectre `Progress` view (coloured `Point` spinner, description with live step text from `OnStatus`,
     gruvbox progress bar, percentage, elapsed time): an overall task plus the current app (completed tasks
     hide). Each finished app prints a badge line above the live view. Interactive items run after it, outside
     the progress view. Then a rounded results table (badge, app, result, version from → to, time, note) and a
     summary panel (`√ ok · ↔ healed · × failed · total time`, log path, removed shortcuts; purple in dry run,
     red with failures, green otherwise).
- **Update AI tools:** table of every `AI = $true` app (installed, latest, how it updates), then update all
  installed or pick (missing ones get installed). Runs with `-Mode update`.
- **Windows tweaks:** describes the 4 fixes and runs `win11-tweaks.ps1` here or elevated in a new window.
- **Settings:** desktop-shortcut cleanup, session dry-run toggle, open the log folder.
- **Smoke-test hook:** `-TestKeys` swaps `AnsiConsole.Console` for Spectre's `TestConsole` (120 × 30) and feeds
  the keys to the picker; it forces dry run and locks it on, and prints `SCREEN-HEIGHTS: name=rows; ...` on exit
  so tests can prove every screen fits 30 rows.

## Run log (which front-end ran)

One file per run in `%LOCALAPPDATA%\my-win-kit\logs\run-<date>-<pid>.log` (newest 30 kept; `MYWINKIT_STATE_DIR`
moves it). The loader creates it and passes the path in `MYWINKIT_RUNLOG`; both menus append through
`Write-KitRunLog`. It records the loader's PowerShell, the pwsh it found (path, version), the decision
(modern / offer install / classic + reason), the front-end that actually started (with PwshSpectreConsole
version, console colour system, Unicode, encoding, `NO_COLOR`), each main-menu choice, run summaries, the exit
code, and any fallback reason. The loader also prints "Starting modern menu · PowerShell 7.x · Spectre" (or
"Starting classic menu · …") before it hands off.

## Classic menu: src/tui-classic.ps1

Windows PowerShell 5.1, deliberately simple, fits 120 × 30. A 2-row block-letter banner (█ ▀ ▄) in the gradient,
then one row block per group: `letter icon GROUP` and up to 4 cells `[x] 12 Name √` (badges as in the modern
menu; updates come from `Get-KitUpdates`). Colour is 24-bit through VT escape codes when the host supports VT
(`$Host.UI.SupportsVirtualTerminal` or Windows Terminal), otherwise the 16 console colours
(`MYWINKIT_FORCE_VT=1` forces VT for captures). One prompt line takes tokens: numbers, ranges `a-b`, group letters, `*` (all
except POST), `0` (none). Commands use letters that aren't group letters: `Z` recommended, `N` only missing,
`I` install, `L` latest AI tools, `W` Windows tweaks, `Q` quit. Runs print one line per app using the same
engine; failures stay selected for a retry. `-TestInput "a;b;c"` feeds answers (tests).

## win11-tweaks.ps1

- StrictMode + `$ErrorActionPreference = 'Stop'`, 76-column layout, its own palette. UTF-8 with BOM (it
  contains box-drawing characters, and 5.1 needs the BOM to read them).
- `$script:Fixes` (L87) is a list of hashtables `Id, Name, Description, Scope (HKCU|HKLM), Reboot, Apply,
  Check, Revert`. The menu's `'1','2','3','4'` switch case is hard-coded.
- `Show-Menu` runs each fix's `Check` live to show ON/OFF. `Invoke-Toggle` runs `Apply` or `Revert`, and
  refuses HKLM fixes when not elevated. `A`/`R` = all on/off. `Q` offers a reboot if needed.

## publish.ps1

- Copies only the kit file set: `src/*.ps1|psm1|psd1` first, then `win11-tweaks.ps1`, `install.cmd`, and
  `install.ps1` **last**, so a PC that syncs mid-publish never gets a loader whose `src/` is missing. It creates
  `src\` in the target when needed. It never deletes anything or touches other files there, in particular
  `winget-id-overrides.json`, which installs write there on purpose so heals sync to every PC.
- Skips files with identical SHA-256 (computed through .NET: `Get-FileHash` fails to load in 5.1 when a git hook
  inherits a PowerShell 7 `PSModulePath`) and files with uncommitted changes.
- **Drift guard:** a target file that differs and is newer than the repo copy was edited on another PC: not
  overwritten, named, exit 2. `-Force` overrides. Time-based: a later repo edit wins without a warning.
- Every path call uses `-LiteralPath` (`[98]` contains wildcard characters). Exit codes: 0 done, 1 error,
  2 drift blocked.

The hooks are POSIX `sh` (Git for Windows). `publish-on-main` exits early off `main`, runs `publish.ps1` with
`powershell.exe` (5.1, the engine a fresh PC has) and always exits 0, so a publish problem never blocks a
commit. Turn them on per clone with `git config core.hooksPath .githooks`.

## Tests and CI

All tests run the kit in dry-run mode; nothing installs.

| Script | Engine | Covers |
|---|---|---|
| `tools/lint.ps1` | 5.1 (`-ParseOnly`) + pwsh | parser check of every `.ps1/.psm1/.psd1`; PSScriptAnalyzer (pwsh) |
| `tools/test-core.ps1` | 5.1 + pwsh | catalogue sanity (unique Ids/names, groups, methods, DEV/POST off, POST interactive), dry run of every package, version compare; `-Online` adds the installed scan and vendor-page resolution |
| `tools/smoke-tui.ps1` | pwsh | the Spectre menu driven by scripted keys: install flow, search, AI table, settings + tweaks (+ "update all" when an AI tool is installed, local only) |
| `tools/smoke-loader.ps1` | 5.1 | loader decisions (pwsh present / absent / forced classic), declining and dry-run accepting the PowerShell 7 install, a classic-menu run |
| `tools/render-screens.ps1 -OutDir <dir>` | pwsh (+5.1 for classic) | not a test: captures every screen as `.txt` (layout) and truecolor `.ans` (view with `Get-Content x.ans -Raw` in Windows Terminal) at 120 × 30, and prints the main-menu height |

`.github/workflows/lint.yml` runs two jobs on `windows-latest`: **ps51** (parse, test-core, smoke-loader) and
**pwsh** (lint, test-core -Online, install PwshSpectreConsole, smoke-tui). `$KnownIssues` in `lint.ps1`
downgrades listed findings to warnings; it is empty.
