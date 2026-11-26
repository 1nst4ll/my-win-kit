# Changelog

> Append-only. New entries on top. Don't edit old ones except to fix an error.

## 2026-11-26: always latest without errors, and the kit inside Windows Terminal (kit v2.8.0, branch `v28-latest`, PR #5)

- Daniel asked to "search web for all packages if they are correct and how we can have always latest version
  without errors", then "do v2.8" (all of the package-check fixes), and added "can app open in terminal instead
  blue ps shell". Every claim used here was re-checked against its primary source (winget returnCodes.md and
  AppInstallerErrors.h for winget 1.29.380, the winget-pkgs manifests, Python's devguide + PEP 719, PowerShell's
  install page + release assets, Microsoft's App Control page for Smart App Control, Hermes' install.ps1, the VS
  Code setup docs, Notepad++'s v8.8.8 note, vendor update pages).
- **Catalogue:** Python 3.13 (41) moved to Removed (security-only, no more Windows installers) and **Python 3.14**
  added as Id 62 (`Python.Python.3.14`); PowerToys (3) `Uninstall ^PowerToys` (winget's manifest has no ProductCode,
  so an installed copy was not detected); Node.js LTS (40) `Uninstall ^Node\.js` (policy: latest LTS); Hermes (56)
  no longer `Requires` git (its installer brings its own pinned PortableGit) and is `Unsigned`; Antigravity IDE (55)
  `/mergetasks=!runcode` (as in its winget manifest: no IDE window after a silent install) and `NoAdmin` (a VS
  Code-style Inno user setup; run as admin it switches its updater off); Adobe Acrobat (13) renamed **Adobe Acrobat
  Reader** ("Free Adobe PDF reader", Id kept); Notepad++ (2) `InstallerType nullsoft` (winget picks the MSI, which
  Notepad++ says is for enterprise IT); **`SelfUpdates`** on Office, Chrome, OneDrive, Dropbox, Acrobat Reader,
  Teams, WhatsApp and AnyDesk (RealVNC left off: its Store copy is an MSI the Store does not update); Office gets a
  `HashNote` ("Microsoft changed setup.exe; try tomorrow") and stays on winget (a fixed setup.exe URL is not resolved
  from a vendor page, which CLAUDE.md requires). Next free Id 63.
- **Outcome buckets** (`Get-KitWingetOutcome`): restart needed (`0x8A150109`, `0x8A15010B`), in use (`0x8A150101`,
  `0x8A150103`, `0x8A150111`), transient with one automatic retry (`0x8A150008`, `0x8A15006D`, `0x8A150102`,
  `0x8A150107`, `0x8A15007F`), installer type changed (`0x8A15008E`, reported, never reinstalled silently), pinned
  (`0x8A150068`), Store policy (`0x8A15001B/1C`), another version installed (`0x8A15010D`), hash mismatch
  (`0x8A150011`), and `0x80073D06` (a higher MSIX version is installed) as up to date (also in the loader's Terminal
  install). New result statuses **restart** (yellow √), **blocked** (orange ▲) and **skipped** (grey -) in both
  menus; `/auto` exits 0 (ok, restart needed and skipped included), 1 (failed) or 2 (blocked) and prints the
  blocked list, the self-updating apps it left alone and the apps that need a restart.
- **SelfUpdates:** installed normally; Update everything and `/auto` list them as "updates itself" and leave them
  out (modern menu: "Choose which to update" ticks them by hand; classic `L` `1`: answer `s`); a hash mismatch or
  "not newer" on them is never "failed".
- **In use:** before an upgrade the kit looks for running programs inside the app's install folder (from Add/Remove
  Programs) and reports "blocked: in use by bash.exe, ssh.exe - close it, then Retry"; it never kills anything.
  After a run with failures or blocks: **Retry the failed / blocked** (modern) or `R` (classic).
- **Installer type / scope / source:** `--source winget` on every winget item (Store items `--source msstore`);
  catalogue `InstallerType` / `Scope` only on a fresh install.
- **Hash mismatch:** `winget source update` once per run, one retry, then "winget's catalogue is behind the vendor,
  try later"; the "previous versions" heal is skipped when the newest two versions share one installer URL. Never
  `--ignore-security-hash`, `--force`, `--include-unknown` or `--all`.
- **PowerShell 7 fallback** (loader): the MSI search (7.7 ships no MSI) became the release's signed `.msixbundle`
  (`Add-AppxPackage`, signer Microsoft Corporation), then the Store package `9MZ1SNWT0N5D`.
- **Enable RDP:** `Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'` (works on Polish Windows).
- **Smart App Control:** with it on (`VerifiedAndReputablePolicyState` = 1), an Application Control refusal is
  "blocked by Smart App Control", and Hermes (unsigned) is not even started (Update AI tools skips it with that note).
- **Terminal:** `config/terminal.json` `startingDirectory.prefer` = `dev-folder` (the dev folder logic itself); the
  folder is also set on the kit's own profiles, so a Claude Code profile with its own folder (Stacy's) moves too. A
  new **my-win-kit** profile starts `install.cmd` from the OneDrive kit folder through `%OneDrive%` (no personal
  path in the repo).
- **The kit inside Windows Terminal:** Daniel's run log showed Terminal installed and set as the default terminal
  app, but the elevate-once relaunch (`Start-Process powershell.exe -Verb RunAs`) still opened the blue console.
  With wt.exe present the elevated copy now starts as `wt.exe -w new new-tab ... powershell.exe -EncodedCommand ...`
  (one UAC prompt); the first window waits on a hand-off file (pid, then exit code; 75 = over-the-shoulder) because
  wt.exe returns at once. Without admin rights, or when Terminal was installed by the essentials in this same run,
  the loader moves into Terminal before the menu opens. Console window as before when wt.exe is missing or fails;
  `/auto` stays in its window; `-InTerminal` stops a second relaunch; tests simulate it
  (`MYWINKIT_SIMULATE_WT_LAUNCH`) and never start wt.
- **Dev folder = `dev\github`:** Daniel: "some machines have already /dev/github instead of git" and chose
  `dev\github`. A read-only check of his 4 PCs found `C:\dev\github`, `D:\dev\github` and (twice)
  `C:\dev\git`. `Get-KitDevFolderPath` (Dev folder app 60, the Terminal start folder) now uses the
  first existing one of `D:\dev\github`, `C:\dev\github`, `D:\dev\git`, `C:\dev\git` (D: only as a ready local fixed
  disk) and creates nothing then; without one it creates `D:\dev\github`, else `C:\dev\github`. Nothing is moved,
  renamed or deleted. Id 60's Desc says so; `config/terminal.json` keeps `prefer: dev-folder` (no hard-coded folder).
- **Small:** `install-*.log` names carry the PID; CLAUDE.md's "Config lives on GitHub" lists `terminal.json`.
- **Left for Daniel:** Bitwarden nullsoft + user scope, the Affinity rename, PostgreSQL password note, Zoom per-user,
  MAS DoH fallback (STATUS → Open items).

## 2026-11-26: Terminal tabs start in the dev folder

- Daniel: "change this starting to D:\dev\git or if no D: C:\dev\git". `config/terminal.json` `startingDirectory.prefer` is now
  `D:\dev\git` (was `%OneDrive%\.playground`); when it doesn't exist the dev-folder fallback picks
  `D:\dev\git` or `C:\dev\git` and creates it. Config-only, live at each PC's next start. A profile that already
  carries its own `startingDirectory` (Stacy's Claude Code profile) keeps it until v2.8 sets the kit profile's
  folder too.

## 2026-11-26: v2.7.0 merged to `main` and published

- Daniel: "merge 4". PR #4 (`essentials`) merged as f28612d after review; CI green on both jobs. The post-merge
  publish copied 8 files to OneDrive (`src/*`, `config/catalog.json`, `config/settings.json`, the new
  `config/terminal.json`, `win11-tweaks.ps1`, `install.ps1`).

## 2026-11-26: essentials at start: PowerShell 7, Terminal, Claude Code, Nerd Font, Terminal settings, default terminal (kit v2.7.0, branch `essentials`)

- Daniel: "go to stacy and copy settings for terminal app then analyze and tidy up and add to auto install upon the
  start script together with ps7 and terminal so terminal opens the same way. Add there also claude cli. These are
  absolute essentials for me on a new system and should be installed without asking."
- **Before this branch:** PR #3 (kit v2.6.0) was merged into `main` (6b9fcc5) and published on 2026-11-26 with
  Daniel's go ("merge 3"); the post-merge publish copied 7 files to OneDrive.
- **Essentials step (`install.ps1`):** v2.5's automatic PowerShell 7 + Terminal install became one step that runs at
  every start, after the elevate-once, without asking, in this order: PowerShell 7, Windows Terminal, **Claude Code
  CLI**, **CaskaydiaCove Nerd Font**, **Windows Terminal settings**, **Windows Terminal as the default terminal app**.
  Each step checks first and does nothing when done (a set-up PC adds about 0.3 s to the start-up); a failure prints
  one line and the start-up carries on; Terminal, Claude Code and the font aren't retried the same day after a
  failure (`loader.json`). `/auto` runs it too. The loader now imports `src/core.psm1` for these steps, and winget
  runs through `Invoke-KitProcess` instead of `& winget`.
- **One setting:** `autoInstallPwsh` → `autoInstallEssentials` (`config/settings.json`, default true; Settings row
  "Install essentials on start (PS7, Terminal, Claude Code, font, Terminal settings)", classic `K`). The older name is
  still read, shared and per PC, so a PC that turned it off stays off.
- **Terminal settings from Stacy, tidied (`config/terminal.json`, new):** copied from Stacy's Windows Terminal 1.25
  `settings.json`. Kept: a *Claude Code* profile as the default (same guid, `pwsh.exe -NoExit -Command claude`, robot
  icon as a `\u` escape), profile defaults *Dark+*, `CaskaydiaCove Nerd Font Mono`, opacity 90, no acrylic; acrylic
  tab row, no copy-on-select, plain-text copy; Ctrl+C copy, Ctrl+V paste, Alt+Shift+D duplicate pane; the
  remaining-profiles new-tab menu. Tidied: the starting folder is `%OneDrive%\.playground` resolved on each PC (Stacy's
  `D:\OneDrive\.playground` only exists there; the kit's dev folder when it doesn't exist); dropped the hard-coded
  Command Prompt / PowerShell / Ubuntu-26.04 entries (Terminal generates them itself), `startOnUserLogin` (only in
  Stacy's older backup), the profile's own copy of the starting folder and the empty `actions` / `schemes` / `themes`.
  The merge keeps everything else in a PC's file, backs it up first (`settings.json.bak-my-win-kit-<date>`), writes
  only when something changes, never overwrites a file it can't read, leaves the font out until the Nerd Font is
  installed and keeps the PC's default profile while PowerShell 7 is missing. Read like the other config files
  (GitHub → cache → bundled; the loader uses the cache or bundled copy).
- **Claude Code CLI:** the catalogue's official `irm https://claude.ai/install.ps1 | iex` in a child PowerShell. The
  installer only writes into the user's profile and Anthropic's setup page says "You do not need to run as
  Administrator"; Claude Code then updates itself as the user. So an elevated kit runs it at the user's normal rights
  (`Invoke-KitDeElevated`, falling back to the kit's own context, the same account). Catalogue Id 46 gets `NoAdmin`
  and a Desc saying the loader installs it; it stays in Update AI tools.
- **CaskaydiaCove Nerd Font:** `CascadiaCode.zip` from the latest `ryanoasis/nerd-fonts` release (GitHub API, no fixed
  version; v3.5.1 today), checked against the SHA-256 GitHub publishes for the asset (`digest`), falling back to the
  release's `SHA-256.txt`; not installed without a checksum. Regular + Mono TTFs; all users (`%WINDIR%\Fonts` + HKLM)
  when elevated, else this user; skipped when the Mono face is already there.
- **Default terminal:** `HKCU\Console\%%Startup` `DelegationConsole` / `DelegationTerminal` = Windows Terminal's GUIDs
  (checked against Microsoft's Terminal group-policy page; the same values Stacy has), only after Terminal is installed.
- **Fix:** the JSON writer read a key named `keys` (Terminal key bindings) as the dictionary's own key list; it now
  uses `PSBase.Keys` / `.Values` / `.Count`. Plain ASCII strings skip the character-by-character escape loop.
- **Tests:** test-core (merge on scratch files: fresh, comments + trailing comma + other profiles kept, backup,
  idempotent, dry run, unparsable file left alone, `-NoFont` / `-NoDefaultProfile`, old-style profile list;
  starting-folder fallback; default terminal through a registry stub; Nerd Font detection, install from a local zip
  into a scratch folder, latest-release parsing from a sample GitHub API answer; simulated steps; settings back-compat),
  smoke-loader (order, all / partly present, a failure carries on and isn't retried the same day, dry run, `/auto`,
  setting off = none run; new `MYWINKIT_SIMULATE_ESSENTIALS` / `MYWINKIT_SIMULATE_FAIL`; without them the new steps are
  skipped in test mode), test-config (terminal.json canonical, ASCII, no personal data, cached), smoke-tui (new
  Settings row). Nothing touched this PC's Terminal settings, fonts or registry.

## 2026-11-26: admin once at start, unattended `/auto`, Update menu (everything + AI tools), NoAdmin installs (kit v2.6.0, branch `elevate-auto`)

- Daniel: "any way the script could work unattended and not show security prompts, start in admin mode?" He chose
  option 1: ask for admin once at start, then nothing else prompts, plus an unattended `/auto` mode. No UAC bypass,
  no permanent scheduled-task elevation, no turning UAC off. Then: "we need update option then update everything
  and update ai tools" ("Update everything" = kit apps + the rest of the PC).
- **Before this branch:** PR #2 (kit v2.5.0) was merged into `main` (f30b5c7) and published on 2026-11-26 with
  Daniel's go ("merg 2"). The post-merge publish copied 6 files (`src/core.psm1`, `src/tui-classic.ps1`,
  `src/tui-spectre.ps1`, `config/catalog.json`, `config/settings.json`, `install.ps1`).
- **Admin once at start (`install.ps1`):** new setting `elevateAtStart` (`config/settings.json`, default true; per
  PC in Settings / classic `V`, same precedence as `autoInstallPwsh`). Not elevated → the loader relaunches its
  own copy with `Start-Process -Verb RunAs` (all arguments kept, `MYWINKIT_*` passed as `-KitEnv` because an
  elevated process doesn't inherit the environment), waits for it and exits with its code. UAC declined → carries
  on as before, one line says so. Elevation comes after the self-update and before the PowerShell 7 / Terminal
  install, so those run elevated and the modern menu inherits it. **Over-the-shoulder guard:** a standard account
  (its token has no deny-only `BUILTIN\Administrators` claim, so Windows would ask for another account) is never
  elevated as a whole; the elevated copy also checks that its account is the signed-in user (owner of
  `explorer.exe` in this session) and otherwise hands back (exit 75) so the normal window carries on. The run log
  records `elevated = yes/no` and why. No real UAC prompt in tests: the step is skipped in test mode unless
  `MYWINKIT_SIMULATE_UAC` is set (new hooks `MYWINKIT_SIMULATE_ADMIN|ELEVATION|UAC|SESSION_USER`).
- **ADMIN badge:** orange `ADMIN` on the modern banner and every sub-screen header ("not admin" in grey otherwise),
  and on the classic subtitle.
- **Unattended `/auto`:** `install.cmd` now passes its arguments (`/auto /pause /dryrun /classic /noelevate`;
  `install.ps1 -Auto` too). Elevates once, accepts a newer kit without asking, installs PowerShell 7 + Terminal
  when `autoInstallPwsh` is on (never asks when it's off), then runs `src/tui-classic.ps1 -Auto` in 5.1: installs the
  recommended apps that are missing and runs "update everything" (below), skips Interactive / POST items and lists
  them as "Skipped (needs you)", prints the summary, the log and the run log, and exits 0 (all ok) or 1 (a failure).
  `/pause` waits for Enter. `& ([scriptblock]::Create((irm <url>))) -Auto` forwards arguments through the bootstrap.
- **Update menu (both menus):** the main menu's "Update AI tools" moved under a new **Update** entry with two
  choices: **Update everything** and **Update AI tools**. "Install or update apps" is now "Install apps". Update
  everything = every installed catalogue app with a newer version (AI tools too, through their own methods and
  updaters) plus every other app `winget upgrade` lists on the PC (outside the catalogue, not pinned, known version),
  each run with `winget upgrade --id <Id> --exact --silent ...` through Invoke-KitProcess and classified like any winget
  run. It shows a Review table of both groups with counts first (Esc = back). Classic: `L` opens the same submenu.
  Engine: `Get-KitUpdateAllPlan`, `ConvertFrom-KitWingetUpgradeText`, `Get-KitWingetPins`, `Get-KitCatalogUpdateSet`,
  method `winget-upgrade` in `Invoke-KitPackage`. `/auto` uses the same plan for its update half.
- **NoAdmin (`config/catalog.json`):** new field, on OneDrive (10), VS Code (36), GitHub Desktop (38) and Cursor (53).
  From an elevated kit these installers run at the signed-in user's normal rights through `Invoke-KitDeElevated`:
  a one-shot scheduled task (Task Scheduler COM, interactive token, RunLevel LUA) that waits and returns the exit
  code and output, then is deleted. A winget "installer prohibits elevation" (0x8A150056) or "admin context
  prohibited" (0x8A15007D) exit is retried the same way for any app (Spotify's manifest declares `elevationProhibited`;
  no catalogue manifest does). Evidence: Squirrel (GitHub Desktop) reruns itself unelevated and exits 0 at once;
  Microsoft says OneDrive running elevated is not supported; VS Code and Cursor user installs turn updates off when run as
  admin. UniGetUI is left out because its installer elevates itself, so running it de-elevated would bring a UAC
  prompt back.
- **Fixes:** the results screens showed "« Back to main menu" twice: `Wait-Back` passed its own item and Select-One
  added the pinned Back row as well. Now the pinned row is the only one (an empty list draws no blank rows), so
  results screens are 3 rows shorter. A failed script tool or updater now shows the output line that names the
  problem (e.g. Hermes' "An Application Control policy has blocked this file") instead of "exit code 1 (see log)".
- **Tests:** smoke-loader covers elevation (relaunch, already admin, declined, standard account, other account
  handed back, setting off, `/noelevate`, arguments kept, classic `V`, ADMIN), `/auto` with stdin closed and a time
  limit (exit 0, no prompt, run log; with a simulated elevation), `install.cmd /auto` pass-through and classic `L`.
  test-core covers `elevateAtStart`, NoAdmin routing, the de-elevation helper (simulated) and the task script itself,
  the `/auto` plan, the update-everything plan from sample `winget upgrade` output and failure reasons. smoke-tui
  covers the Update submenu, Update everything (review, and a dry run when this PC has updates), one Back row on
  results, the ADMIN badge and the new Settings row. The scheduled-task runner was checked by hand on ATHENA
  (medium integrity, exit 7 returned, task deleted, ~1 s).

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
