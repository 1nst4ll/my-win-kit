# my-win-kit

Daniel's Windows workstation kit: two interactive PowerShell menus for setting up a fresh Windows PC.

| Script | What it does |
|---|---|
| `install.ps1` (+ `install.cmd` launcher) | Pick apps from a menu and install them with winget, plus a few custom installers and optional post-install steps. Fixes broken winget package IDs by itself. |
| `win11-tweaks.ps1` | Turn four Windows 11 settings on or off: Spotlight desktop icon, lock-screen tips, Bing results in Start search, 15-minute auto-lock. |

Current state, counts and open items: [docs/STATUS.md](docs/STATUS.md). How it works: [docs/architecture.md](docs/architecture.md).

## Install on another PC

The kit is already in **`OneDrive\[98] Shortcuts`** on every PC signed in to Daniel's OneDrive.

1. Open `OneDrive\[98] Shortcuts`.
2. Double-click `install.cmd`.

`install.cmd` runs `install.ps1` with the execution policy bypassed for that run only, so it works on a stock
Windows install with Windows PowerShell 5.1. You can also run it by hand:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

You need winget (App Installer). If it's missing, the script opens its Microsoft Store page and exits.

**Without OneDrive:** download the repo zip from GitHub (private: sign in first), unzip, and double-click `install.cmd`.

## Using the installer

Type into the prompt and press Enter:

- `5`, `1 5 12`, `20-27`: toggle packages by number or range
- a group letter (`U`, `B`, `D` …): toggle a whole group
- `*`: everything on except POST-INSTALL. `0`: everything off. `Z`: back to the defaults
- `N`: keep or delete the desktop shortcuts new installs create (delete is the default)
- `I`: install (asks to confirm). `Q`: quit

You can mix them: `3 d 8-11`. Packages that install successfully get deselected, and failed ones stay selected,
so pressing `I` again retries only the failures. Each run writes a full log to `%TEMP%\workstation-install-*.log`.

## win11-tweaks.ps1

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\win11-tweaks.ps1
```

Press `1`–`4` to toggle a tweak, `A` for all on, `R` for all off, `Q` to quit (it offers a reboot if one is
needed). Tweak 4 (auto-lock) writes to HKLM, so **run it as Administrator** for that one. The other three are
per-user.

> Known issue: this script currently runs only under PowerShell 7 (`pwsh`). Windows PowerShell 5.1 can't parse
> it. See [docs/STATUS.md](docs/STATUS.md).

## Adding or changing a package

1. Edit the `$pk` list in [install.ps1](install.ps1#L92) (lines 92–164). One line per package:
   `Id` (unique, never reused), `On` (selected by default), `N` (display name), `W` (winget ID, or Store
   product code), `S` (`''` = winget, `msstore`, or `custom`), `G` (group key).
2. Find the winget ID with `winget search <name>`.
3. For a `custom` package, also add a case to `switch ($P.Id)` in `Inst` ([install.ps1:707](install.ps1#L707)).
4. Check the menu still fits a 120×30 window (see [CLAUDE.md](CLAUDE.md#constraints)).
5. Commit on `main`. The commit hook publishes it to OneDrive.

## Self-healing package IDs

When a winget ID stops working, the installer searches for the replacement and retries. It saves each fix to
`winget-id-overrides.json` next to `install.ps1` (in the OneDrive copy, so every PC gets it). To reset all of
them, delete that file. To keep one for good, put the new ID into `$pk` and delete the file.

## Working on the kit

Edit only in this repo, never the OneDrive copies. Read [CLAUDE.md](CLAUDE.md) first. After cloning, run this
once:

```powershell
git config core.hooksPath .githooks   # turns on auto-publish to OneDrive
```

Lint: `pwsh -File tools/lint.ps1`
