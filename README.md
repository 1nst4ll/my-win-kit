# my-win-kit

Daniel's Windows workstation kit: one double-click to set up a Windows PC, install or update apps, keep the AI
tools on their latest versions, and apply a few Windows 11 tweaks.

Current state, counts and open items: [docs/STATUS.md](docs/STATUS.md). How it works: [docs/architecture.md](docs/architecture.md).

## Start it

The kit is already in **`OneDrive\[98] Shortcuts`** on every PC signed in to Daniel's OneDrive.

1. Open `OneDrive\[98] Shortcuts`.
2. Double-click `install.cmd`.

What happens next depends on the PC:

- **PowerShell 7.4+ installed** → it prints *"Starting modern menu · PowerShell 7.x · Spectre"* and the modern
  menu opens (window title `my-win-kit · modern (PowerShell 7)`).
- **Not installed** (a fresh PC) → it asks *"Install PowerShell 7 now? [Y/n]"*. Press Enter: it installs
  PowerShell 7, then opens the modern menu. The first run also installs the PwshSpectreConsole module for the
  current user (a few seconds).
- **Answer `n`** → the simpler classic menu opens in Windows PowerShell 5.1. Every install works in both.

By hand: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (add `-Classic` to skip straight
to the classic menu, or `-DryRun` to see what would run without installing anything).

Most installs need winget (App Installer). If it's missing, the menu opens its Microsoft Store page.

**Without OneDrive:** download the repo zip from GitHub (private: sign in first), unzip, double-click `install.cmd`.

## The modern menu

**Keys, on every screen:** ↑↓ move · Enter select · **Esc, Backspace or ← = back** · `/` search (lists of apps) ·
Space tick an app (a group header ticks the whole group) · `a`/`n` whole group on/off · `q` quit (main menu).
The « Back row is always at the top of the list, and the key hints are always at the bottom.

Which menu ran is logged: `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (Settings shows the current file).

A gradient **MY WIN KIT** banner, gruvbox colours, and one set of badges everywhere: √ installed, ↑ update
available, · not installed, × failed, ↔ healed. In dry run every screen carries a purple **DRY RUN** band.

- **Install or update apps:** pick a starting point (recommended set, only what's missing on this PC, retry last
  failures, your last selection, or empty), adjust the grouped list (space ticks an app, ticking a group header
  ticks the whole group), check the review table, then install. Already-installed apps update if a newer version
  exists. **Search to add or remove an app** lets you type a name instead of scrolling.
- **Update AI tools:** a table of Claude Code, Claude Desktop, Antigravity, Antigravity IDE and the `agy` CLI with
  installed vs latest versions, then one key updates them all.
- **Windows tweaks:** opens the tweaks menu (here, or as administrator for all 4 fixes).
- **Settings:** remove desktop shortcuts that installers create (on by default), dry run, open the log folder.

Each run ends with a results table and writes a log to `%TEMP%\my-win-kit\`.

## The classic menu

Type into the prompt and press Enter: numbers (`5`, `1 5 12`), ranges (`20-27`), group letters (`U`, `B`, `D` …),
`*` (all except post-install), `0` (none). Commands: `Z` recommended set, `N` only what's new here, `I` install,
`L` latest AI tools, `W` Windows tweaks, `Q` quit. Failed apps stay selected, so `I` retries them.

## Always-latest AI tools

| Tool | Installed from | Updates with |
|---|---|---|
| Claude Code CLI | official `irm https://claude.ai/install.ps1 \| iex` | `claude update` |
| Antigravity CLI (`agy`) | official `irm https://antigravity.google/cli/install.ps1 \| iex` | `agy update` |
| Antigravity IDE, Antigravity | the latest installer linked on antigravity.google/download (must be signed by Google LLC) | same, skipped when already current |
| Claude Desktop | winget `Anthropic.Claude` | the app updates itself |

Claude Desktop stays on winget because Anthropic's "latest" download link refuses scripted downloads (HTTP 403).
The winget package tracks the current release, and the app updates itself after install.

## win11-tweaks.ps1

Opened from either menu, or on its own:
`powershell -NoProfile -ExecutionPolicy Bypass -File .\win11-tweaks.ps1`. Press `1`–`4` to toggle a tweak, `A`
for all on, `R` for all off, `Q` to quit (it offers a reboot if needed). Tweak 4 (auto-lock) writes to HKLM, so
run it as administrator for that one.

## Managing the package list from the menu

**Settings → Manage packages** (modern menu): tick packages in or out of the recommended set (Space), remove one
(`d`, restorable), add one by searching winget and the Microsoft Store or by its exact winget ID (pick a group, new
or existing, and on/off), and reset. Your changes are saved to `my-packages.json` next to `install.ps1`, which
OneDrive syncs to every PC, so every PC (and both menus) sees the same list. The repo's base list is not changed.
In dry run the changes stay in memory for that session only.

To make your changes the repo default: `powershell -File tools\import-overlay.ps1` (folds the OneDrive
`my-packages.json` into `src/catalog.psd1`), run `tools\test-core.ps1`, commit on `main`, then
`tools\import-overlay.ps1 -ClearOverlay`.

## Adding or changing an app in the repo

1. Edit [src/catalog.psd1](src/catalog.psd1). One line per app: `Id` (permanent, next free one is in STATUS),
   `Name`, `Group`, `On` (in the recommended set), `Method`, `Ref`, `Desc`. The header of that file explains
   every field.
2. For winget, find the ID with `winget search <name>`. For a vendor one-liner use `Method = 'script'` and the
   URL. For a download-page installer add a `Direct` entry (page, link regex, signer, silent args).
3. Run `powershell -File tools\test-core.ps1` (catalogue checks + dry run).
4. Commit on `main`. The commit hook publishes it to OneDrive.

## Self-healing package IDs

When a winget ID stops working, the engine searches for the replacement and retries. It saves each fix to
`winget-id-overrides.json` next to `install.ps1` (in the OneDrive copy, so every PC gets it). To reset them,
delete that file. To keep one for good, put the new ID into `src/catalog.psd1` and delete the file.

## Working on the kit

Edit only in this repo, never the OneDrive copies. Read [CLAUDE.md](CLAUDE.md) first. After cloning, run once:

```powershell
git config core.hooksPath .githooks   # turns on auto-publish to OneDrive
```

Checks (all dry run, nothing installs):

```powershell
pwsh -File tools/lint.ps1                                  # parse + PSScriptAnalyzer
powershell -File tools/test-core.ps1                       # engine + catalogue under 5.1
pwsh -File tools/smoke-tui.ps1                             # modern menu with scripted keys
powershell -ExecutionPolicy Bypass -File tools/smoke-loader.ps1   # loader + classic menu
```
