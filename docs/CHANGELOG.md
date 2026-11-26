# Changelog

> Append-only. New entries on top. Don't edit old ones except to fix an error.

## 2026-11-26: catalogue changes, Chris Titus prompt, dev folder, WSL + Ubuntu, auto PowerShell 7 + Terminal (kit v2.5.0, branch `catalog-ps7-wsl`)

- Daniel: "lets remove perplexyty and samsung qick share also lets add titus script for terminal prompt, also add
  setup of d:\dev\git folder if d: does not exist then root c: also script to setup latest wsl and latest ubuntu,
  obsidian untick as default install i section to update ai tools if installed update other ones aswell like codex
  cursor ect. ps7 and latest terminal should be installed as without asking as soon as ps5 manage to run then
  restart in ps7 add toggle to tun it off in settings but set as default on". Follow-up via the coordinator: Codex
  CLI and Cursor must stay off by default; the AI flag must not tick them anywhere, and Update AI tools only
  updates them when they are already installed, never installs them.
- **Catalogue (`config/catalog.json`, canonical form):** Perplexity (8) and Samsung Quick Share (33) moved to
  `Removed` (Google Quick Share 32 stays). Obsidian (4) off by default. `AI: true` on Cursor (53), Codex CLI (54),
  KiloCode CLI (47) and Hermes Agent (56; `Exe` = its install folder, `Update` = `hermes update`); Cursor and Codex
  stay `On: false`. New: **Chris Titus prompt (59)**, script
  `https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1` (the one-liner in that repo's README,
  checked 2026-11-26), DEV, off, `Interactive`, new fields `Elevated` + `Shell: pwsh` (the setup returns without
  doing anything when not elevated, and installs into the running shell's profile, so it must run as admin under
  PowerShell 7), `Requires: pwsh`, `Detect: ctt-profile`. **Dev folder (60)**, builtin, UTIL, on: `D:\dev\git`
  when D: is a ready fixed disk, else `C:\dev\git`. **WSL + Ubuntu (61)**, builtin, DEV, off, `Interactive`.
  Windows Terminal (34) / PowerShell 7 (35) descriptions say the loader installs them. Next free Id 62.
- **Engine (`src/core.psm1`):** builtins `dev-folder` (`Get-KitDevFolderPath` with an injectable D: check,
  `Invoke-KitDevFolder`) and `wsl-ubuntu` (`Invoke-KitWslUbuntu`: `wsl --install --no-distribution` or
  `wsl --update` through the new `Invoke-KitElevatedCapture`, restart detection, newest Ubuntu LTS from
  `wsl --list --online` via `Select-KitUbuntuDistro` / `ConvertFrom-KitWslText` (UTF-16 safe, `WSL_UTF8=1`), then
  `wsl --install -d <name>` on the console for Ubuntu's user set-up). New catalogue key `Detect` (`Get-KitDetect`:
  dev folder exists, PowerShell 7 profile is the CTT one, an Ubuntu distro is registered, read from the registry).
  Scripts: `Shell: pwsh` and `Elevated` (own administrator window with `-EncodedCommand`; declined UAC = "administrator
  prompt declined"). npm globals are detected (`npm ls -g`) and their latest version read (`npm view`), so KiloCode
  shows up and updates. An `Exe` folder proves an install; its command comes from PATH. `Get-KitAiUpdateSet`
  (installed AI tools only) feeds both menus. Per-PC preferences: `local-settings.json`
  (`Get-KitLocalPrefs` / `Set-KitLocalPref`), `Get-KitAutoInstallPwsh` (this PC > settings.json > on).
- **Loader (`install.ps1`, 5.1):** with `autoInstallPwsh` on (new in `config/settings.json`, default true) it
  installs PowerShell 7 and the latest Windows Terminal (winget) without asking, then starts the modern menu under
  pwsh; failures end in the classic menu as before; a failed Terminal install isn't retried the same day. Off
  (this PC's override) → the old "Install PowerShell 7 now?" question. New test hooks: `-NoTerminal`,
  `MYWINKIT_SIMULATE_WT`, `MYWINKIT_SIMULATE_INSTALL=ok|fail`.
- **Menus:** Update AI tools lists every AI tool but updates only installed ones (the "Pick tools (also installs
  missing ones)" option is gone; "Pick which installed tools to update" lists installed tools only), trims its table
  to the window, and the main-menu line no longer names four tools. Settings gets the row "Auto-install PowerShell
  7 + Terminal on start: on/off (this PC)" (local file, never GitHub) and shows `autoInstallPwsh` read-only. Classic
  menu: `K` toggles the same override and the command line shows it; `L` uses `Get-KitAiUpdateSet`. Interactive
  items print their status steps (e.g. "type exit to come back here").
- **Tests:** test-core: catalogue changes, Cursor/Codex AI-flagged and off, AI update set (installed only, empty
  when none), dev-folder path for Fixed / none / CDRom / Removable / Network, WSL picker (24.04 over interim 25.10,
  26.04 when listed, UTF-16 text, fallback), restart detection, preference precedence. smoke-loader: auto mode
  installs without the question (dry run, simulated ok/fail), Terminal-only, not retried the same day, local
  override off → ask first, classic `K`. smoke-tui: AI table, installed-only pick, Settings toggle; "n clears
  Utilities" now leaves 29 apps. test-core, smoke-tui, smoke-loader and render-screens now read this copy's
  `config/` (`MYWINKIT_CONFIG_URL` = `file:///`), so a PR's catalogue is what gets tested (they read GitHub `main`
  before). test-config counts `Removed` lines in the one-package-per-line check.
- Kit version 2.5.0. Not merged or published: waits for Daniel's go.

## 2026-11-25: rebuild merged to `main` and published (kit v2.4.2)

- Daniel: "fix both and merge comit push to mainn". PR #1 (`rebuild-tui`) merged into `main` after review of
  v2.4.2; CI green on both jobs. The post-merge publish copied 8 files to OneDrive (`src/*`, `config/*`,
  `win11-tweaks.ps1`, `install.ps1`; `install.cmd` unchanged). `config/catalog.json` on `main` answers HTTP 200
  from raw.githubusercontent.com, so every PC now reads the committed list at start-up.

## 2026-11-25: failed winget upgrades are reported as failed, key-sending rule, kit v2.4.2 (branch `rebuild-tui`)

- Daniel: "fix both and merge comit push to mainn".
- **Bug (from Daniel's real run, `%TEMP%\my-win-kit\install-20261125-225808.log`):** Git 2.55.0.5 was
  installed; `winget install --id Git.Git` found 2.56.1, the installer asked for admin and failed ("Installer
  failed with exit code: 1"), winget exited `-1978335226` (`0x8A150006` SHELLEXEC_INSTALL_FAILED). The kit
  counted it as ok/current because any non-zero exit on an installed app meant "up to date". Git stayed on
  2.55.0.5.
- **Fix (`src/core.psm1`):** new `Get-KitWingetOutcome` / `Get-KitWingetFailReason`. Only winget's "nothing to
  do" codes count as current (named constants, codes from winget-cli `doc/windows/package-manager/winget/returnCodes.md`):
  `0x8A15002B` UPDATE_NOT_APPLICABLE, `0x8A15004F` UPGRADE_VERSION_NOT_NEWER, `0x8A150061`
  PACKAGE_ALREADY_INSTALLED, `0x8A15010E` INSTALL_DOWNGRADE. Every other non-zero exit is failed, with the output
  line that names the problem plus the code ("Installer failed with exit code: 1 (winget 0x8A150006)").
  Measured on this PC: `winget install` on an up-to-date app (GitHub CLI 2.106.0) exits `-1978335189`
  (`0x8A15002B`), matching the "No available upgrade found" runs in earlier logs. An unknown ID on an installed
  app (`0x8A150014` with no successor found) is now failed too, not current. A winget exit 0 whose version did
  not move stays current but says so in `Detail` and the log.
- Checked the other paths: script, direct (its winget fallback goes through the same code), npm and builtin
  already report any non-zero exit as failed; the menus only display `Status`.
- **Tests:** `test-core.ps1` unit-tests the classification without running winget (ok, the four current codes,
  the Git failure output, ID not found, no output).
- **CLAUDE.md:** a key-sending helper now targets only the window of the process it started itself (PID →
  window handle, foreground check before every key), never a title match. A test driver had matched Daniel's own
  kit window by title and sent it Esc/q. No helper exists under `tools/`.
- Docs: architecture (winget exit classification), STATUS.

## 2026-11-25: child processes no longer garble the progress view, kit v2.4.1 (branch `rebuild-tui`)

- Daniel, from a real run of the modern menu: "it display sone gibrish when downloading or checking sometimes does
  very preaty progress bars". The progress view and the scan spinner printed raw escape text
  (`[38;2;254;128;25m...`, `[2A`/`[3A`) frame after frame while winget, `claude update` or `agy update` ran, and
  drew cleanly during direct downloads.
- **Root cause (measured in a real console):** PowerShell 7 in a **conhost** window switches the console's
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING` off (mode 0x7 → 0x3) for as long as any `&`-started native program runs,
  even `cmd /c ver`, and switches it back on when the program exits. Spectre draws on a background thread, so
  every frame during a child run printed literally. Windows PowerShell 5.1 and Windows Terminal keep the mode;
  `Start-Process`, `Invoke-WebRequest` and `ProcessStartInfo` children don't touch it. That's why direct
  downloads looked fine.
- **Fix (`src/core.psm1`):** new `Invoke-KitProcess` starts non-interactive programs with `ProcessStartInfo`
  (own hidden console, redirected stdin/stdout/stderr read together, UTF-8, `.cmd` via `cmd.exe`) and returns
  `Ec`/`Out`/`Err`/`Started`. winget (install, list, show, upgrade, export, search), tool `--version` checks,
  `claude update`/`agy update`, npm, the non-interactive `irm | iex` child and the RDP helper all use it. Scan and
  update results are identical to before (compared under pwsh and 5.1). `Interactive` scripts still share the
  console.
- **Guard:** `Enable-KitConsoleVt` (best effort, no-op when output is not a console) switches VT back on. The modern
  menu calls it before each scan spinner and the progress view, on every status change and after each package.
  The classic menu calls it after the scan and after each package.
- **Tests:** `test-core.ps1` checks `Invoke-KitProcess` output, exit code, argument quoting, `.cmd` files and a
  missing program. In a console window it also checks that a child which clears VT on its console leaves the
  kit's console on, and that `Enable-KitConsoleVt` restores it (skipped when output is redirected, as in CI).
- Real-console check: conhost + pwsh, "Update AI tools → Update all installed" (winget, `claude update`,
  `agy update` on current tools) and the Install scan both draw clean bars and spinners. The previous commit
  printed raw escapes under the same scan.
- Docs: architecture (child processes), CLAUDE.md constraint, STATUS.

## 2026-11-25: read-only config, menu no longer writes to GitHub, kit v2.4.0 (branch `rebuild-tui`)

- Daniel: "we cannot guarantee this can we at least do github download for deployed version and i will change
  settings from repo when needed". In-menu saving needed gh installed and signed in plus real keyboard entry on
  every PC, none of it tested outside this one.
- **Kept:** deployed copies read `config/*.json` from GitHub (raw URL → cache → bundled copy) and self-update from
  GitHub (version check, zip download, `irm | iex` bootstrap).
- **Removed from `src/core.psm1`:** `Save-KitConfigChange`, `Add-KitPackage`, `Set-KitPackageDefault`,
  `Remove-KitPackage`, `Restore-KitPackage`, `Set-KitSetting`, `Push-KitPendingOverrides`, `Set-KitConfigMemoryOnly`,
  `Get-KitNextId`, `Get-KitRemovedPackages`, `Find-KitWingetPackages`, `Test-KitWingetId`, and every gh helper
  (`Get-KitGh`, `Invoke-KitGh`, `Test-KitGhLogin`, `Get-KitGhUser`, `Get-KitGhFile`). The `gh api` read fallback
  for a private repo went too: the repo is public, so reads never need gh.
- **Learned heals** stay on the PC that found them (`cache\local-overrides.json`, was `pending-overrides.json`) and
  are never pushed; Settings shows the count and the file so Daniel can copy them into the repo.
- **Modern menu:** Manage packages (list, search/add, add by Id, removed list), the editable Settings toggles, the
  GitHub account row and `Confirm-GitHubWrite` (gh install + `gh auth login`) are gone, with `Read-KitText`.
  Settings is now one read-only panel: config source, `removeShortcuts` / `dryRunByDefault`, package-ID fixes in
  use and learned on this PC, and "To change config, edit config/*.json in the my-win-kit repo on GitHub." It keeps
  the session dry-run toggle and the log folder. Classic menu: only the memory-only call and the `gh` source label.
- **Tests:** `test-config.ps1` loses the dry-run edit, pending-push and `-Write` (throwaway-branch commits)
  sections; adds canonical-form checks for all three config files, catalogue Id checks (unique across Packages +
  Removed, no `RetiredIds` reuse), local-heal checks and "no config-write functions exported". `smoke-tui.ps1`
  drops the two Manage scenarios and the winget add scenario and gets one read-only Settings scenario with an
  `Absent` list. `render-screens.ps1` drops the two Manage captures.
- Docs: README, architecture (Configuration on GitHub is now read-only), CLAUDE.md config rules, STATUS.

## 2026-11-25: repo public, history cleaned

- Daniel chose "rewrite, then go public" and "delete + recreate". All 12 commits rewritten to the GitHub noreply
  address; the personal email and Windows user path removed from doc history (`git filter-branch`).
- Deleting needs the `delete_repo` scope the CLI login lacks, so the old repo was renamed `my-win-kit-old`
  (private), and a new **public** `1nst4ll/my-win-kit` was created with the clean `main` + `rebuild-tui`.
  PR #1 was reopened there with the same body. Repo-local `user.email` is now the noreply address.

- Later the same day: `my-win-kit-old` deleted in the browser (Daniel approved, passkey by Daniel). GitHub
  "Block command line pushes that expose my email" switched on. Session paused; PR #1 still open.

## 2026-11-25: config on GitHub + self-update, kit v2.3.0 (branch `rebuild-tui`, not merged yet)

- Daniel: "system that will allow changing settings from any computer while you're outside the repo, just on an
  actually deployed version... Possibly we should use GitHub for that. By the way, this repo can be a public repo."
- **Decision (coordinator, matching Daniel's lean):** GitHub is the single home for config. `src/catalog.psd1` is
  migrated to `config/catalog.json` (same fields + `Removed`), new `config/settings.json` (`removeShortcuts`,
  `dryRunByDefault`) and `config/winget-id-overrides.json`. The `my-packages.json` overlay and
  `tools/import-overlay.ps1` (added earlier today) are removed.
- **Read:** every start fetches the latest config (raw GitHub URL, 4 s; `gh api` when the repo is private) and
  caches it; offline → cache → bundled copy. The banner shows the source.
- **Write:** Manage packages and Settings commit to `main` through `gh api` (contents API, sha; on a conflict
  re-fetch, re-apply, retry once). Plain user commit messages ("config: add 7-Zip (from ATHENA)"). Offers to
  install gh and runs `gh auth login --web`; no tokens stored by the kit. Dry run previews the commit.
- **Learned heals** are committed when signed in, else held per PC and pushed from Settings.
- **Self-update:** the loader compares `KitVersion` with GitHub `main`, asks once per version, downloads the repo
  zip into `%LOCALAPPDATA%\my-win-kit\app\<version>`, verifies it and runs it; any failure keeps the local copy.
  **`irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`** bootstraps a fresh PC.
- **Public repo: not flipped.** The history scan found no secrets, tokens or keys, but all 10 commits carry
  a personal email as author/committer, and `docs/STATUS.md` had the Windows user path in 2 commits
  (removed from the current files now). The coordinator's rule was to stop and report, so the decision is with
  Daniel.
- Fixes found on the way: `.ContainsKey` on ordered dictionaries (`.Contains`); `"$rv?"` parsed as a variable
  named `rv?` in the update prompt; `Get-Content -Raw` on `[98]` paths in 5.1 needs `-LiteralPath`; publish's
  protected-file check compared leaf names (would have blocked `config/winget-id-overrides.json`).
- Tests: new `tools/test-config.ps1` (offline read chain, JSON writer, dry-run edits, pending heals, publish,
  self-update accept/reuse/decline/broken, `irm | iex`; `-Write` = real commits on a throwaway branch incl. a
  forced conflict). `test-overlay.ps1` removed. smoke scenarios now check the dry-run commit previews.

## 2026-11-25: Manage packages, kit v2.2.0 (branch `rebuild-tui`, not merged yet)

- Daniel's request: "add setting section where we can manage lists of packages (remove or search for and add
  packages) and mark defaults as on/off".
- **Decision (coordinator):** the menu never edits `src/catalog.psd1` (the kit runs from OneDrive and publish is
  one-way). Edits go to a user overlay, `my-packages.json` next to install.ps1: synced to every PC by OneDrive,
  gitignored, protected in publish.ps1. core.psm1 merges base + overlay, so both menus see the same list.
- **Settings → Manage packages:** package list with default on/off (Space), remove with confirm (`d`/Del),
  `/` filter; add by `winget search` (winget + Store) or by exact winget ID, into an existing or new group, on/off;
  removed packages (restore); reset my changes. Header shows where changes are saved; dry run keeps them in
  memory and says so. Esc back everywhere; every screen fits 120 x 30.
- **Overlay:** schema 1, atomic writes (`.bak` kept), corrupt file -> warning + base list + `.bak`, newer schema ->
  ignored and untouched, Ids never reused (`lastId`, `RetiredIds`).
- **tools/import-overlay.ps1** folds the overlay into the catalogue (defaults, removals -> `RetiredIds`, new
  groups, added packages), validates, optional `-ClearOverlay`.
- **Fixed (latent):** `Get-KitWingetRaw` results are now always arrays; a one-line winget reply threw under
  StrictMode (`.Count` on a string).
- Tests: `tools/test-overlay.ps1` (29 checks + 3 online winget checks; 5.1 and pwsh, scratch kit), 3 new smoke scenarios
  incl. a real winget search/add saved into a scratch kit, CI runs both.
## 2026-11-25: universal back + visible modern mode (branch `rebuild-tui`, not merged yet)

- Daniel's test feedback: "There's no way how to go back. When you get to updates, you can't go back to main
  menu. Also, it looks like it starts only the regular clean PowerShell version, not the Spectre one."
- **Cause of "no way back":** Spectre prompts ignore Esc/Backspace/←; the two multi-selects ("Choose apps",
  "Pick tools") had no back path at all, and the only exit after a run was one menu item. (Reproduced at
  120 × 30: the Update screen's « Back item itself was visible.)
- **Cause of "looks like plain PowerShell":** confirmed in a real console: no colour and every glyph printed as
  `?`. (1) UTF-8 was switched on after Spectre had already created its console on code page 437 → no Unicode.
  (2) Spectre disables all colour when `NO_COLOR` is set, and agent/dev shells export `NO_COLOR=1` to the
  windows they start. The run log proved the modern front-end did run.
- **Fix:** all Spectre prompts replaced by the kit's own picker (`Show-Picker`, `[Console]::ReadKey` + Spectre
  rendering): Esc/Backspace/← = back on every screen, pinned « Back row, persistent key footer with `esc back`,
  `/` type-to-filter, Space/`a`/`n` toggles, `q` quits from the main menu. Pickers size themselves to the window;
  review and results tables are trimmed; results get their own screen.
- **Fix:** UTF-8 before Spectre loads + an explicit TrueColor console (`NO_COLOR` logged and ignored;
  `MYWINKIT_NO_COLOR=1` is the kit's off switch).
- **Visible mode:** loader prints "Starting modern menu · PowerShell 7.x · Spectre" / "Starting classic menu ·
  …"; window titles `my-win-kit · modern (PowerShell 7)` / `… · classic (PowerShell 5.1)`; banner subtitle and
  every header name the engine.
- **Run log** per run in `%LOCALAPPDATA%\my-win-kit\logs\`: loader decision, pwsh path/version, module version,
  console colour/Unicode, front-end started, menu choices, fallback reasons, exit code.
- **Tests:** smoke-tui drives Esc/Backspace/← from every level, search, group toggles, and fails any screen
  taller than 30 rows (the menu reports `SCREEN-HEIGHTS`); smoke-loader checks the run log. Checked by hand in a
  real 120 × 30 conhost window launched through the loader (screenshots).
## 2026-11-25: visual polish, kit v2.1.0 (branch `rebuild-tui`, not merged yet)

- Daniel's dry-run feedback: "add some colors and more ascii art and modern ui".
- **Modern menu:** gradient "MY WIN KIT" Figlet banner (orange → yellow → green → aqua) with a version / PC /
  PowerShell / admin subtitle; truecolor gruvbox everywhere; rounded tables and panels with coloured borders;
  per-group accent colour + icon; main menu items with icons and one-line descriptions; key-hint bar (footer
  on multi-selects, title line on single selects); live `Progress` view during runs; results table with a badge
  column + summary panel; AI table with badges; goodbye bar on quit.
- **Badges everywhere:** √ installed, ↑ update available (new `Get-KitUpdates`: one `winget upgrade` + vendor
  pages), · not installed, × failed, ↔ healed, ○ dry run. New start-from preset "Everything with an update".
- **DRY RUN can't be missed:** purple badge in the subtitle/header plus a full-width purple rule on every screen,
  and a dry-run line in the summary panel.
- **Glyph audit:** ✓ ✗ ↻ (used until now) and Braille spinners are missing from Consolas, so they showed as boxes in
  classic conhost. Every glyph now exists in both Consolas and Cascadia Mono; spinner is `Point`.
- **Classic menu:** 2-row block-letter banner in the gradient, truecolor through VT with a 16-colour fallback,
  compact 4-column layout that fits 120 × 30 (was taller), same badges.
- New `tools/render-screens.ps1` captures every screen (.txt + .ans). Startup measured at ~750 ms from launch
  to quit with the banner (Figlet render 11 ms).

## 2026-11-25 (branch `rebuild-tui`, not merged yet)

- **Rebuilt the installer** into a loader + two menus + one engine. `install.ps1` is now a 5.1 loader: with
  PowerShell 7.4+ it opens the new Spectre menu, without it it offers to install PowerShell 7 (winget, then the
  signed MSI), and if declined it opens a classic 5.1 menu. The old 1,098-line `install.ps1` is in git history
  (`46dc3b1`).
- **App list moved to `src/catalog.psd1`** (data only), install logic to `src/core.psm1` (shared, 5.1
  compatible). All 57 old apps kept with the same Ids, groups and defaults; self-healing IDs and
  `winget-id-overrides.json` kept.
- **New modern menu** (`src/tui-spectre.ps1`): start-from presets (incl. only-missing and retry-failures),
  grouped multi-select with installed versions, type-to-search, review table, live per-app status, results
  table. New **Update AI tools** screen with installed vs latest versions.
- **Always-latest AI tools:** Antigravity IDE now installs from the latest signed installer on
  antigravity.google/download (was winget, 2 versions behind). Claude Code and `agy` update through
  `claude update` / `agy update` when installed. Claude Desktop stays on winget (Anthropic's latest link returns
  HTTP 403 to scripts; the app updates itself).
- **Fixed:** catalogue Id 55 "Antigravity IDE" pointed at `Google.Antigravity`, which is now Google's separate
  Antigravity 2.0 agent app. Id 55 is the IDE again, and the agent app is new **Id 58 "Antigravity"** (DEV,
  off by default).
- **Fixed:** vendor scripts now run in a child process, so a vendor `exit` can't close the menu.
- **Fixed:** `win11-tweaks.ps1` saved with a UTF-8 BOM. It parses under Windows PowerShell 5.1 now;
  `$KnownIssues` in `tools/lint.ps1` is empty.
- PATH is reloaded before apps that need Git/npm, so tools installed earlier in the same run are found.
- **Tests:** `tools/test-core.ps1`, `tools/smoke-tui.ps1` (Spectre TestConsole with scripted keys),
  `tools/smoke-loader.ps1`; CI runs them (dry run only). Lint covers `.psm1`/`.psd1`; PSScriptAnalyzer also
  excludes `PSUseShouldProcessForStateChangingFunctions`.
- **Publish** now ships `src/` too, with `install.ps1` copied last.

## 2026-11-24

- **Repo created:** github.com/1nst4ll/my-win-kit (private). The three scripts were imported byte-identical
  to the copies already in `OneDrive\[98] Shortcuts`. `.gitattributes` pins LF so checkouts never rewrite the
  bytes, and `.gitignore` excludes per-machine `winget-id-overrides.json`.
- **Docs system:** README, CLAUDE.md (continuity + drift rules + constraints), docs/STATUS.md,
  docs/CHANGELOG.md, docs/architecture.md (with the ownership map).
- **Lint CI:** `tools/lint.ps1` + `PSScriptAnalyzerSettings.psd1` + `.github/workflows/lint.yml`. Parse runs
  under 5.1 and pwsh, and PSScriptAnalyzer runs under pwsh. The first run found that win11-tweaks.ps1 fails to
  parse under 5.1 (missing BOM). It's tracked as a known issue in STATUS.
- **One-way publish to OneDrive:** `tools/publish.ps1` + `.githooks/post-commit` / `post-merge`. The
  drift-guard behaviour was tested against a scratch folder: copy, no-op, drift block (exit 2), `-Force`,
  repo-newer overwrite, skipping uncommitted files, and leaving other files alone.

## Before git (from file timestamps)

- **2026-07-07:** `install.ps1` / `install.cmd` last modified before the repo existed.
- **2026-04-14:** `win11-tweaks.ps1` v1.0 written.
