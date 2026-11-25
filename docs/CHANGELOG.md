# Changelog

> Append-only. New entries on top. Don't edit old ones except to fix an error.

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
