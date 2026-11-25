# Changelog

> Append-only. New entries on top. Don't edit old ones except to fix an error.

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
