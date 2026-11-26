# my-win-kit

Daniel's Windows workstation kit: one double-click to set up a Windows PC, install or update apps, keep the AI
tools on their latest versions, and apply a few Windows 11 tweaks.

Current state, counts and open items: [docs/STATUS.md](docs/STATUS.md). How it works: [docs/architecture.md](docs/architecture.md).

## Start it

The kit is already in **`OneDrive\[98] Shortcuts`** on every PC signed in to Daniel's OneDrive.

1. Open `OneDrive\[98] Shortcuts`.
2. Double-click `install.cmd`.

What happens next depends on the PC:

- **PowerShell 7.4+ and Windows Terminal installed** → it prints *"Starting modern menu · PowerShell 7.x ·
  Spectre"* and the modern menu opens (window title `my-win-kit · modern (PowerShell 7)`).
- **Either one missing** (a fresh PC) → it installs PowerShell 7 and the latest Windows Terminal straight away,
  **without asking**, then opens the modern menu under PowerShell 7. The first run also installs the
  PwshSpectreConsole module for the current user (a few seconds). If an install fails, the simpler classic menu
  opens in Windows PowerShell 5.1; every install works in both.
- **Auto-install switched off** (Settings → *Auto-install PowerShell 7 + Terminal on start*, per PC; classic menu:
  `K`) → it asks *"Install PowerShell 7 now? [Y/n]"* first, as before. `n` opens the classic menu.

By hand: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (add `-Classic` to skip straight
to the classic menu, or `-DryRun` to see what would run without installing anything).

Most installs need winget (App Installer). If it's missing, the menu opens its Microsoft Store page.

**Without OneDrive:** download the repo zip from GitHub, unzip, double-click `install.cmd`, or use the one-liner
under [Updates and installing on a new PC](#updates-and-installing-on-a-new-pc).

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
- **Update AI tools:** a table of every AI tool in the catalogue (Claude, Codex, Cursor, Antigravity, KiloCode,
  Hermes …) with installed vs latest versions, then one key updates **the ones installed on this PC** (winget
  upgrade, npm, or the tool's own updater). It never installs a missing tool: use Install or update apps for that.
- **Windows tweaks:** opens the tweaks menu (here, or as administrator for all 4 fixes).
- **Settings:** read-only: where the config came from (GitHub, cached copy or bundled copy), the current settings,
  package-ID fixes this PC learned and the file they are in. Changeable on this PC only: auto-install of PowerShell 7
  + Windows Terminal at start (saved in `%LOCALAPPDATA%\my-win-kit\local-settings.json`), the dry-run toggle for
  this session, and the log folder.

Each run ends with a results table and writes a log to `%TEMP%\my-win-kit\`.

## The classic menu

Type into the prompt and press Enter: numbers (`5`, `1 5 12`), ranges (`20-27`), group letters (`U`, `B`, `D` …),
`*` (all except post-install), `0` (none). Commands: `Z` recommended set, `N` only what's new here, `I` install,
`L` latest AI tools (installed ones), `W` Windows tweaks, `K` auto-install PowerShell 7 + Terminal on/off (this
PC), `Q` quit. Failed apps stay selected, so `I` retries them.

## Set-up items that aren't apps

- **Dev folder** (recommended set): creates `D:\dev\git`, or `C:\dev\git` when the PC has no local D: disk.
- **WSL + Ubuntu** (Dev tools, off): installs or updates WSL, then the newest Ubuntu LTS. Windows asks for admin,
  may need a restart (run it again afterwards), and Ubuntu asks for a Linux user name and password; type `exit`
  to come back to the kit.
- **Chris Titus prompt** (Dev tools, off): Chris Titus Tech's PowerShell 7 profile (oh-my-posh, Terminal-Icons,
  zoxide, Nerd Font) from its official `setup.ps1`, in its own administrator window. Afterwards set the Terminal
  font to `CaskaydiaCove NF`.

## Always-latest AI tools

| Tool | Installed from | Updates with |
|---|---|---|
| Claude Code CLI | official `irm https://claude.ai/install.ps1 \| iex` | `claude update` |
| Antigravity CLI (`agy`) | official `irm https://antigravity.google/cli/install.ps1 \| iex` | `agy update` |
| Antigravity IDE, Antigravity | the latest installer linked on antigravity.google/download (must be signed by Google LLC) | same, skipped when already current |
| Claude Desktop | winget `Anthropic.Claude` | the app updates itself |
| Cursor, Codex CLI | winget `Anysphere.Cursor`, `OpenAI.Codex` (off by default) | winget upgrade |
| KiloCode CLI | npm `@kilocode/cli` | `npm install -g` (latest) |
| Hermes Agent | official installer | `hermes update` |

Claude Desktop stays on winget because Anthropic's "latest" download link refuses scripted downloads (HTTP 403).
The winget package tracks the current release, and the app updates itself after install.

## win11-tweaks.ps1

Opened from either menu, or on its own:
`powershell -NoProfile -ExecutionPolicy Bypass -File .\win11-tweaks.ps1`. Press `1`–`4` to toggle a tweak, `A`
for all on, `R` for all off, `Q` to quit (it offers a reboot if needed). Tweak 4 (auto-lock) writes to HKLM, so
run it as administrator for that one.

## Settings and the package list live on GitHub

`config/catalog.json` (the apps), `config/settings.json` (desktop-shortcut cleanup, start in dry run, auto-install
PowerShell 7 + Terminal; a PC can override the last one in Settings) and
`config/winget-id-overrides.json` in this repo are the copy that counts. Every PC reads the latest from GitHub when
the kit starts (falling back to its last cached copy, then to the copy that came with the kit, when offline). No
sign-in is needed: the repo is public.

**The menu never changes config.** To change it, edit `config/*.json` in the repo (see below), commit and push to
`main`; every PC picks it up at its next start. Settings in the menu shows read-only what a PC is using.

## Updates and installing on a new PC

The kit updates itself: when GitHub has a newer version it asks once ("Update kit 2.4.0 -> 2.5.0? [Y/n]"),
downloads it into `%LOCALAPPDATA%\my-win-kit\app\`, checks it, and runs it. On a PC without the OneDrive folder
(needs the repo to be public):

```powershell
irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex
```
## Adding or changing an app in the repo

1. Edit [config/catalog.json](config/catalog.json), one line per app: `Id` (permanent, never reused; to drop an
   app, move its line to `Removed`), `Name`, `Group`, `On` (in the recommended set), `Method`, `Ref`, `Desc`.
   Fields: [docs/architecture.md](docs/architecture.md#catalog-fields). Keep one item per line and ASCII only:
   `tools/test-config.ps1` checks the canonical form.
2. For winget, find the ID with `winget search <name>`. For a vendor one-liner use `Method = 'script'` and the
   URL. For a download-page installer add a `Direct` entry (page, link regex, signer, silent args).
3. Run `powershell -File tools\test-core.ps1` (catalogue checks + dry run) and `tools\test-config.ps1`.
4. Commit on `main` and push. PCs read the new config from GitHub at their next start; the commit hook also
   publishes the kit files to OneDrive.

## Self-healing package IDs

When a winget ID stops working, the engine searches for the replacement and retries. It keeps each fix on that PC
(`%LOCALAPPDATA%\my-win-kit\cache\local-overrides.json`; Settings shows the count and the file) and uses it at every
start. To share a fix with every PC, copy it into `config/winget-id-overrides.json` in the repo, or better, put the
new ID straight into `config/catalog.json`.

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
powershell -ExecutionPolicy Bypass -File tools/test-config.ps1    # config read chain, self-update, irm | iex (offline)
```
