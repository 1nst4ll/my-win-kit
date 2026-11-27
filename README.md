# my-win-kit

Daniel's Windows workstation kit: one double-click to set up a Windows PC, install or update apps, keep the AI
tools on their latest versions, and apply a few Windows 11 tweaks.

Current state, counts and open items: [docs/STATUS.md](docs/STATUS.md). How it works: [docs/architecture.md](docs/architecture.md).

## Start it

The kit is already in **`OneDrive\[98] Shortcuts`** on every PC signed in to Daniel's OneDrive.

1. Open `OneDrive\[98] Shortcuts`.
2. Double-click `install.cmd`.

### What every PC gets automatically (the essentials)

At every start the kit checks these and sets up whatever is missing, **without asking**, in this order:

1. **PowerShell 7** (latest, winget; the official signed MSI if winget fails).
2. **Windows Terminal** (latest, winget).
3. **Claude Code CLI** (Anthropic's official installer, into your own profile at your normal user rights).
4. **CaskaydiaCove Nerd Font** (Cascadia Code from the latest Nerd Fonts release on GitHub, checked against its
   published SHA-256; for all users when the kit runs as administrator).
5. **Windows Terminal set up the same way on every PC** ([config/terminal.json](config/terminal.json)): a
   *Claude Code* profile (PowerShell 7 running `claude`) as the default tab, the Nerd Font, the *Dark+* colours at
   90% opacity, Ctrl+C / Ctrl+V copy and paste, Alt+Shift+D duplicate pane, and every tab starting in
   the dev folder (below; the kit's own profiles too), plus a
   *my-win-kit* profile that starts the kit from the OneDrive folder. Your other profiles and settings stay; the
   old file is backed up first as `settings.json.bak-my-win-kit-<date>`.
6. **Windows Terminal as the default terminal app** (console programs open in Terminal).

Anything already there is skipped, so a set-up PC starts as fast as before. A step that fails shows one yellow
line and the kit carries on (a failed download is retried the next day). Then the modern menu opens under
PowerShell 7 (*"Starting modern menu · PowerShell 7.x · Spectre"*; the first run also installs the
PwshSpectreConsole module, a few seconds). If PowerShell 7 can't be installed, the simpler classic menu opens in
Windows PowerShell 5.1; every install works in both.

**Switch the essentials off** per PC in Settings → *Install essentials on start* (classic menu: `K`): then the kit
only asks *"Install PowerShell 7 now? [Y/n]"* when PowerShell 7 is missing, as before. `n` opens the classic menu.

**Administrator rights once:** at start Windows asks once ("Do you want to allow this app to make changes?"); the
kit then runs as administrator in its own window (orange **ADMIN** badge), and no installer asks again. With
Windows Terminal installed that window is a **Windows Terminal** window, not the blue PowerShell console; without
admin rights the kit moves into Terminal as well. The first window waits and closes when the kit finishes. Say **No** and the kit carries on as before (each installer asks for
itself). On a standard account (where Windows would ask for another account's password) the kit doesn't ask up
front, so per-user apps land in the right profile. Switch it off per PC in Settings → *Ask for administrator rights
once at start* (classic menu: `V`), or for one run with `install.cmd /noelevate`. A few apps never install as
administrator (OneDrive, VS Code, GitHub Desktop, Claude Code, Cursor, Antigravity IDE: `NoAdmin` in the
catalogue); the kit runs those at your normal rights.

By hand: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (add `-Classic` to skip straight
to the classic menu, or `-DryRun` to see what would run without installing anything).

## Run it unattended

```
install.cmd /auto
```

One administrator prompt, then no questions at all: it updates the kit itself if GitHub has a newer version,
sets up the essentials (above) if missing, installs every recommended app that is missing, and runs
**Update everything** (below). Items that need a person (post-install tools, WSL + Ubuntu, the Chris Titus prompt)
are skipped and listed as "Skipped (needs you)"; apps that update themselves (Chrome, Office, Teams …) are left
alone. It ends with the results, a "Blocked (needs you)" list (an app was in use, Smart App Control, …), the log
paths and an exit code: `0` all ok (a needed restart or a skipped app counts as ok), `1` something failed, `2`
nothing failed but something is blocked. Add `/dryrun` to see what it would do, `/pause` to keep the window open at the end
(`install.ps1 -Auto -DryRun -Pause` works too).

Most installs need winget (App Installer). If it's missing, the menu opens its Microsoft Store page.

**Without OneDrive:** download the repo zip from GitHub, unzip, double-click `install.cmd`, or use the one-liner
under [Updates and installing on a new PC](#updates-and-installing-on-a-new-pc).

## The modern menu

**Keys, on every screen:** ↑↓ move · Enter select · **Esc, Backspace or ← = back** · `/` search (lists of apps) ·
Space tick an app (a group header ticks the whole group) · `a`/`n` whole group on/off · `q` quit (main menu).
The « Back row is always at the top of the list, and the key hints are always at the bottom.

Which menu ran is logged: `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (Settings shows the current file).

A gradient **MY WIN KIT** banner, gruvbox colours, and one set of badges everywhere: √ installed, ↑ update
available, · not installed, × failed, ↔ healed; after a run also yellow √ restart needed, orange ▲ blocked (needs
you: close the app, Smart App Control, installer type changed) and grey - skipped (pinned, updates itself). In dry run every screen carries a purple **DRY RUN** band.

- **Install apps:** pick a starting point (recommended set, only what's missing on this PC, retry last
  failures, your last selection, or empty), adjust the grouped list (space ticks an app, ticking a group header
  ticks the whole group), check the review table, then install. Already-installed apps update if a newer version
  exists. **Search to add or remove an app** lets you type a name instead of scrolling.
- **Update** → **Update everything:** every app from the catalogue that is installed and has a newer version (AI
  tools too, each through its own updater) **plus everything else winget can upgrade on this PC** (runtimes,
  other apps; pinned ones and ones with an unknown version are left alone). Apps that update themselves (Chrome,
  Office, Teams, OneDrive, Dropbox, Acrobat Reader, AnyDesk, WhatsApp) are listed as *updates itself* and left out;
  *Choose which to update* lets you tick them anyway. A review table shows the groups and their counts first; Esc
  goes back.
- **Update** → **Update AI tools:** a table of every AI tool in the catalogue (Claude, Codex, Cursor, Antigravity,
  KiloCode, Hermes …) with installed vs latest versions, then one key updates **the ones installed on this PC**
  (winget upgrade, npm, or the tool's own updater). It never installs a missing tool: use Install apps for that.
- **Windows tweaks:** opens the tweaks menu (here, or as administrator for all 4 fixes).
- **Settings:** read-only: where the config came from (GitHub, cached copy or bundled copy), the current settings,
  package-ID fixes this PC learned and the file they are in. Changeable on this PC only: installing the essentials
  at start and asking for administrator rights once at start (saved in
  `%LOCALAPPDATA%\my-win-kit\local-settings.json`), the dry-run toggle for this session, and the log folder.

Each run ends with a results table and writes a log to `%TEMP%\my-win-kit\`. When something failed or was blocked,
**Retry the failed / blocked** runs just those again (close the apps that were in use first). The kit never closes
a running app for you.

## The classic menu

Type into the prompt and press Enter: numbers (`5`, `1 5 12`), ranges (`20-27`), group letters (`U`, `B`, `D` …),
`*` (all except post-install), `0` (none). Commands: `Z` recommended set, `N` only what's new here, `I` install,
`L` update (`1` everything, `2` AI tools; Enter = back), `W` Windows tweaks, `K` essentials on start on/off, `V`
administrator rights at start on/off (both per PC), `Q` quit. After a run with failures, `R` retries the failed and
blocked apps at once; they also stay selected, so `I` retries them later.

## Set-up items that aren't apps

- **Dev folder** (recommended set): uses the dev folder the PC already has (`D:\dev\github`, `C:\dev\github`,
  `D:\dev\git` or `C:\dev\git`, in that order); without one it creates `D:\dev\github`, or `C:\dev\github` when the
  PC has no local D: disk. It never moves or renames a folder.
- **WSL + Ubuntu** (Dev tools, off): installs or updates WSL, then the newest Ubuntu LTS. Windows asks for admin,
  may need a restart (run it again afterwards), and Ubuntu asks for a Linux user name and password; type `exit`
  to come back to the kit.
- **Chris Titus prompt** (Dev tools, off): Chris Titus Tech's PowerShell 7 profile (oh-my-posh, Terminal-Icons,
  zoxide, Nerd Font) from its official `setup.ps1`, in its own administrator window. The essentials already set
  the Terminal font to `CaskaydiaCove Nerd Font Mono`.

## Always-latest AI tools

| Tool | Installed from | Updates with |
|---|---|---|
| Claude Code CLI | official `irm https://claude.ai/install.ps1 \| iex` (the loader installs it at start) | `claude update` |
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

`config/catalog.json` (the apps), `config/settings.json` (desktop-shortcut cleanup, start in dry run, essentials
at start, administrator rights at start; a PC can override the last two in Settings), `config/terminal.json` (the
Windows Terminal settings every PC gets) and `config/winget-id-overrides.json` in this repo are the copy that
counts. Every PC reads the latest from GitHub when
the kit starts (falling back to its last cached copy, then to the copy that came with the kit, when offline). No
sign-in is needed: the repo is public.

**The menu never changes config.** To change it, edit `config/*.json` in the repo (see below), commit and push to
`main`; every PC picks it up at its next start. Settings in the menu shows read-only what a PC is using.

## Updates and installing on a new PC

The kit updates itself at every start, without asking: when GitHub has a newer version it
downloads it into `%LOCALAPPDATA%\my-win-kit\app\`, checks it, and runs it. On a PC without the OneDrive folder
(needs the repo to be public):

```powershell
irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex
```

That online install (also handy on a USB stick as a `.cmd` that runs the same line) adds **my-win-kit** to the
Start menu and the Desktop, with its own icon, and an entry in Settings > Apps. Next time, start it from either
shortcut. To remove it: Start menu > my-win-kit > **Uninstall my-win-kit**, or Settings > Apps > my-win-kit >
Uninstall. That removes the shortcuts and the kit's own files; the apps it installed stay installed.
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
