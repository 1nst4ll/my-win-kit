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
| [config/catalog.json](../config/catalog.json) **on GitHub `main`** | The app catalogue: groups, packages (name, method, Id/URL, default on/off, detection), removed packages, `RetiredIds`, the direct-download rules. Edited by hand in the repo (the menu never writes it). Every PC reads the live copy at start. Fields: [Catalog fields](#catalog-fields). | Never copy it into docs. |
| [config/settings.json](../config/settings.json) **on GitHub `main`** | Kit settings shared by every PC (`removeShortcuts`, `dryRunByDefault`, `autoInstallEssentials`, `elevateAtStart`). Edited by hand in the repo; Settings shows them read-only. | Per-PC state (last selection, last failures: `%LOCALAPPDATA%\my-win-kit\state.json`) and per-PC preferences (`local-settings.json`, e.g. this PC's `autoInstallEssentials` / `elevateAtStart` override). |
| [config/terminal.json](../config/terminal.json) **on GitHub `main`** | The Windows Terminal settings every PC gets (essentials step): default profile, the Claude Code profile, profile defaults, globals, key bindings, starting folder. Fields: [Windows Terminal settings](#windows-terminal-settings). | The PC's own Terminal settings (merged into, never replaced). |
| [config/winget-id-overrides.json](../config/winget-id-overrides.json) **on GitHub `main`** | Shared winget-ID heals (old → new, `msstore:` prefix = Store). Edited by hand. Heals a PC learns itself stay in that PC's `cache\local-overrides.json` until copied in here. | |
| `$script:KitVersion` in [src/core.psm1](../src/core.psm1) | The kit version. The loader compares it with GitHub `main` for the self-update. | |
| `$script:Fixes` in [win11-tweaks.ps1](../win11-tweaks.ps1#L87) | The tweak catalogue (registry keys, apply/check/revert). | |

## Repo layout and delivery

```
install.cmd  install.ps1           # launcher + loader (Windows PowerShell 5.1, zero deps)
config/catalog.json settings.json winget-id-overrides.json terminal.json   # live config (GitHub main is the home)
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

`install.cmd` launches `%~dpn0.ps1` (its own name with `.ps1`) with its arguments (`%*`), so it sits beside `install.ps1`. The published
folder mirrors the repo: kit files at the top, `src/` beside them.

| Channel | What | How | Trigger |
|---|---|---|---|
| OneDrive publish | `src/*`, `win11-tweaks.ps1`, `install.cmd`, `install.ps1` | `tools/publish.ps1` → `$env:OneDrive\[98] Shortcuts`, then OneDrive syncs every PC | git hook on commit/merge on `main` |
| CI | lint + dry-run tests | GitHub Actions, `windows-latest` | push to `main`, PRs |
| GitHub | source of truth + backup | `git push` | by hand |

## Start-up: install.ps1 (the loader)

Runs on stock Windows PowerShell 5.1 with nothing installed.

0. **Arguments:** `install.cmd` passes its own; slash forms `/auto /pause /dryrun /classic /noelevate` map to the
   switches (`ValueFromRemainingArguments`, `PositionalBinding = $false`); anything else is named and ignored.
   Self-update ([below](#self-update-and-the-one-line-install)) runs first.
1. **Bootstrap:** TLS 1.2, `Unblock-File` on every kit file (mark-of-the-web), recreate `install.cmd` if missing.
1a. **Administrator rights, once** (`elevateAtStart`, read like `autoInstallEssentials`: this PC's `local-settings.json`,
   else the cached / bundled `settings.json`, else on; `Get-LoaderSwitch`):
   - already elevated → nothing to do (a warning when the elevated account is not the signed-in user);
   - off, or `-NoElevate` → installers ask for admin one by one, as before;
   - **standard account** (`Get-ElevationKind`: the current token has no `S-1-5-32-544` claim; an administrator's
     filtered token carries it as a deny-only group) → no whole-kit elevation, because Windows would ask for
     another account and per-user installs (Store, user-scope winget, `%USERPROFILE%` tools, npm globals) would
     land in that account's profile (over-the-shoulder);
   - otherwise, **Windows Terminal installed** (`Get-WtExe`: the `wt.exe` app alias) and not `/auto` →
     `Start-InTerminal -Elevated`: `Start-Process wt.exe -Verb RunAs` with `-w new new-tab -p <Windows PowerShell
     profile guid> --title my-win-kit --suppressApplicationTitle powershell.exe -NoProfile -ExecutionPolicy Bypass
     -EncodedCommand <script>`. The encoded script (`Get-HandoffScript`) runs this copy's `install.ps1` with the same
     arguments plus `-NoUpdate -InTerminal -ElevatedChild -KitEnv <base64 MYWINKIT_* variables>`, so no quoting and no
     `;` (wt's command separator) ever reaches wt's own parser. wt.exe returns at once, so the first window waits on
     a **hand-off file** (`<state>\handoff-<parent pid>.txt`): the tab writes `pid=<n>` when it starts and `ec=<exit
     code>` when the kit ends (`Wait-Handoff`; no `pid=` within 90 s = the tab never started, carry on here; the tab's
     process gone without `ec=` = exit 1). Its exit code ends the first window, 75 = the over-the-shoulder hand-back.
     UAC declined (Win32 error 1223) → one line, carry on non-elevated; any other wt failure → the console path:
   - **no Terminal** (first run on a fresh PC), wt failed, or `/auto` → `Start-Process powershell.exe -Verb RunAs` on
     this copy's `install.ps1` with the same arguments plus `-NoUpdate -ElevatedChild -KitEnv <base64>` (an elevated
     process doesn't inherit the environment; the run log path travels this way), wait for it, exit with its code.
     UAC declined (the start throws) → one line, carry on non-elevated.
   - **The elevated copy** compares its account SID with the owner of `explorer.exe` in its session
     (`Get-SessionUserSid`, CIM `GetOwnerSid`). Different → exit 75, and the waiting parent carries on
     non-elevated. The run log records `elevate: elevated = yes|no - <why>`.
   - Ordering: elevation comes before the essentials (PowerShell 7, Terminal, ...), so those run elevated (no
     prompt) and `pwsh` started for the modern menu inherits the token.
   - Never a real prompt in tests: in test mode (`-WhatIfLoader`, `-ClassicTestInput`, `-Answer`, `-UpdateAnswer`,
     or `MYWINKIT_STATE_DIR` set) the step is skipped unless `MYWINKIT_SIMULATE_UAC=accept|decline` simulates it
     (`accept` runs the child copy in the same console with `MYWINKIT_SIMULATE_ADMIN=1`). Other hooks:
     `MYWINKIT_SIMULATE_ADMIN=1|0`, `MYWINKIT_SIMULATE_ELEVATION=same|other`, `MYWINKIT_SIMULATE_SESSION_USER=same|other`,
     `MYWINKIT_SIMULATE_WT_LAUNCH=ok|fail` (the Terminal launch: `ok` runs the tab's encoded command in this console,
     `fail` = wt could not start; without it there is never a Terminal relaunch in test mode).
2. **Find PowerShell 7** (`Find-Pwsh`): checks `pwsh` on PATH plus the known install paths (PATH is stale right
   after an install) and asks each candidate for its version. The best one wins.
3. **Read the essentials setting** (`Get-EssentialsSetting`): `autoInstallEssentials` from this PC's
   `<state>\local-settings.json` (set from Settings / classic `K`), else `settings.json` (the cached copy in
   `<state>\cache`, then the bundled one; the loader does not fetch config itself), else **on**. In each file the
   older name `autoInstallPwsh` is read after the new one (back-compat with kits before 2.7.0 and their per-PC
   choice). The engine's `Get-KitAutoInstallEssentials` uses the same order.
4. **Decide:**
   - **essentials on** → the **essentials step**, without asking, in this order; each step checks first and does
     nothing when it is already done:
     1. **PowerShell 7** when 7.4+ is missing: `Install-Pwsh`: `winget install Microsoft.PowerShell` (exit 0 or
        `0x80073D06` = a higher version is already there); else the official **`.msixbundle`** of the latest GitHub
        release (`Get-KitPwshMsixAsset` reads the GitHub API answer; since 7.7 the releases ship no MSI, the bundle holds
        every architecture), Authenticode signer `O=Microsoft Corporation` required, `Add-AppxPackage` (per user);
        else the Microsoft Store package `9MZ1SNWT0N5D` through winget. `Find-Pwsh` also checks the MSIX alias
        `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`.
     2. **Windows Terminal** when missing: `Install-Terminal` (`winget install Microsoft.WindowsTerminal`; winget's
        "nothing to do" exits count as success; there is no other channel). Detection:
        `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe` or the `Microsoft.WindowsTerminal*` Appx package; `0x80073D06`
        (the Store copy is newer) counts as installed. winget runs
        through the engine's `Invoke-KitProcess` (the loader imports `src\core.psm1`, which is 5.1-compatible).
     3. to 6. **`Invoke-LoaderEssentials`** → `Invoke-KitEssential` (engine, [below](#essentials)) for `claude`
        (Claude Code CLI), `font` (CaskaydiaCove Nerd Font), `terminal-settings` (config/terminal.json merged into
        Terminal's settings.json) and `default-terminal` (Windows Terminal as the default terminal app; the last
        two only when Terminal is installed).

     A step that fails prints one yellow line and the start-up carries on; done steps print one green line,
     already-done steps only reach the run log (`essentials: <step> -> <status> - <detail>`). The download-type
     steps (Terminal, Claude Code, the font) are not retried until the next day after a failure (`<state>\loader.json`
     keys `wtFailed`, `claude-failed`, `font-failed`), so a PC without winget or network doesn't retry on every
     start. Then: pwsh available → modern menu; pwsh still missing → classic menu (never stranded).
   - **Into Windows Terminal first** (`Invoke-TerminalHandoff`, at the top of `Start-Modern` / `Start-Classic`, once
     per run): when wt.exe exists and this console is not already a terminal tab (`Test-InsideTerminal`: the
     `-InTerminal` marker, `WT_SESSION`, or a `PseudoConsoleWindow` console window, which is what Terminal as the
     default terminal app gives a console it took over), the loader relaunches itself into a new Terminal window with
     the same rights (`Start-InTerminal` without `-Verb RunAs`; same hand-off file) and exits with its code. This also
     covers a fresh PC: the essentials step installs Terminal, and the same run then moves into it (the relaunched copy
     re-runs the quick essentials checks). The tab runs Windows PowerShell 5.1 for the loader, which starts pwsh for
     the modern menu in the same tab. Never for `/auto` (an unattended run stays in its window, so pipes and scheduled
     runs keep its output and exit code), never twice (`-InTerminal`), never in tests without
     `MYWINKIT_SIMULATE_WT_LAUNCH`; a failed launch keeps the current window.
   - pwsh **7.4+** → `pwsh -NoProfile -ExecutionPolicy Bypass -File src\tui-spectre.ps1 -KitRoot <folder>`.
     If that exits **3** (Spectre module unavailable) → classic menu.
   - **essentials off** and pwsh missing or older → asks "Install PowerShell 7 now? [Y/n]" (Enter = yes), then the
     same `Install-Pwsh` and modern menu. Nothing else of the essentials runs.
   - declined or failed → `src\tui-classic.ps1` in the same 5.1 process.
   - `-Classic` skips all of this.
   - **`-Auto`** (`/auto`): the same steps without a question (essentials off and no PowerShell 7 → no question, no
     install), then always `src\tui-classic.ps1 -Auto` in this 5.1 process instead of a menu (`Start-Auto`), exit
     code passed through.
5. Test switches (no effect on normal use): `-NoPwsh` / env `MYWINKIT_SIMULATE_NO_PWSH=1` pretend pwsh is
   absent, `-NoTerminal` / `MYWINKIT_SIMULATE_WT=absent|present` fake Windows Terminal, `MYWINKIT_SIMULATE_INSTALL=ok|fail`
   makes both installs report that result without running anything, `MYWINKIT_SIMULATE_ESSENTIALS=absent|present|<steps
   that are present>` simulates steps 3-6 (detection and result; without it they are skipped in test mode, so tests
   never touch this PC's Terminal, fonts or registry), `MYWINKIT_SIMULATE_FAIL=<steps>` fails those, `-WhatIfLoader`
   prints the decision (modern / auto-install / offer-install / classic; also `elevate: ...`, `essentials: on|off`
   and, with `-Auto`, `front-end: unattended`), `-Answer` answers the question, `-ClassicTestInput` feeds
   the classic menu, `-Classic` forces it, `-DryRun` passes through to either menu (in auto mode it prints what
   would be installed, no question).

## The engine: src/core.psm1

No UI. Both menus call the same functions, so behaviour is identical in both.

- **`Initialize-Kit -KitRoot`** loads `config/catalog.json` (see [Configuration on GitHub](#configuration-on-github-read-only)), turns each entry
  into an object with a mutable `On`, and applies learned heals from `config/winget-id-overrides.json` plus this
  PC's `cache\local-overrides.json` (old→new chains up to 5 hops; `msstore:` prefix switches channel).
- **`Get-KitInstalled`** returns `Id → version` for everything installed: one `winget export --include-versions`
  for all winget/Store IDs, one `npm ls -g --depth=0 --json` when the catalogue has npm packages and npm exists,
  plus per-package checks: `Detect` (built-in checks: `dev-folder` = the folder exists, `ctt-profile` = PowerShell
  7's profile in Documents names Chris Titus Tech, `wsl-ubuntu` = an `Ubuntu*` distro registered under
  `HKCU\...\Lxss`, read from the registry so WSL is never started), `Appx` name (MSIX apps such as Claude Desktop),
  `Uninstall` DisplayName regex (direct installers), `Exe` path + `Version` command (script installs such as
  `claude`, `agy`; an `Exe` that is a folder only proves the install, the command then comes from PATH). Odd winget
  version strings (`> 280.4`, `ad 9.8.0`) are reduced to the dotted number.
- **`Invoke-KitPackage -Package -Installed -Mode install|update -DryRun -OnStatus`** is the single entry point.
  It returns a result object (`Status`, `From`, `To`, `Detail`, `Healed`, `Seconds`) and writes everything to a log
  in `%TEMP%\my-win-kit\install-<date>-<time>-<pid>.log` (the PID keeps two runs in one second apart). **Statuses:**
  installed | updated | current | done | dryrun | **restart** (done, Windows restart needed) | **skipped** (pinned,
  or updates itself) | **blocked** (needs a person: the app is in use, Smart App Control, installer type changed,
  policy, another version installed) | failed. `Test-KitResultOk` = everything except failed and blocked.
  `-Available <version>` (the menus pass the known update) tells it an upgrade will really run.
  - **Before anything:** `Unsigned` + Smart App Control on → blocked without running (below). **In use:** an
    installed winget / Store / rest-of-PC item with a known update, or a direct app that is not current, is checked
    first: `Get-KitInUse` finds the install folder in Add/Remove Programs (`Get-KitInstallFolder`: the entry that
    matches the `Uninstall` regex, else the DisplayName equal to or starting with the app's name; its
    `InstallLocation`, else the folder of its `DisplayIcon` .exe; never a drive root, Program Files, the profile,
    `%LOCALAPPDATA%\Programs` or a Windows folder) and lists running programs inside it (`Get-KitBlockingProcesses`,
    the kit's own process tree excluded). Any → **blocked** "in use by bash.exe, ssh.exe - close it, then Retry";
    nothing is ever killed.
  - **winget / msstore:** `winget install --id <id> --exact --silent --source winget|msstore` (the source is always
    named, so a winget item never matches msstore; `Get-KitWingetInstallArgs`). The catalogue's `InstallerType` /
    `Scope` become `--installer-type` / `--scope` on a **fresh install only**: an upgrade keeps the installed type and
    scope. Never `--force`, `--ignore-security-hash` (elevated winget refuses it anyway), `--include-unknown` or
    `--all`. **`Get-KitWingetOutcome` buckets** (codes from winget's returnCodes.md; `$script:WgBucketCodes`):
    | Bucket | Codes | Result |
    |---|---|---|
    | ok | 0 | installed / updated (then `winget list` reads the version) |
    | current | `0x8A15002B` `0x8A15004F` `0x8A150061` `0x8A15010E`, `0x80073D06` (MSIX: a higher version is installed) | current |
    | restart | `0x8A150109` reboot to finish, `0x8A15010B` reboot initiated (`0x8A15010A` "restart, then try again" is a failure) | restart |
    | busy | `0x8A150101` `0x8A150103` `0x8A150111` (app or file in use) | blocked: "close it, then Retry" |
    | transient | `0x8A150008` download failed, `0x8A15006D` service busy, `0x8A150102` install in progress, `0x8A150107` no network, `0x8A15007F` Store catalog | one automatic retry after 5 s, then failed |
    | reinstall | `0x8A15008E` (winget 1.29: the upgrade uses another install technology) | blocked: "installer type changed: uninstall + install needed" (never done silently) |
    | pinned | `0x8A150068` | skipped |
    | policy | `0x8A15001B` `0x8A15001C` (Store blocked by policy) | blocked |
    | otherver | `0x8A15010D` another version installed | blocked |
    | hash | `0x8A150011` installer hash mismatch | see below |
    | anything else | | failed, with the output line that names the problem plus the code ("Installer failed with exit code: 1 (winget 0x8A150006)") |

    **Hash mismatch:** the vendor replaced the file behind a fixed URL before winget's manifest caught up. The kit
    runs `winget source update` (once per run, `Invoke-KitProcess`) and retries once. Still a mismatch → failed
    "winget's catalogue is behind the vendor, try later" (the catalogue's `HashNote` replaces that text: Office says
    "Microsoft changed setup.exe; try tomorrow"); a `SelfUpdates` app is never failed for it: skipped when installed
    ("updates itself"), blocked when not.
    Self-healing: ID vanished (`0x8A150014`) → `Find-KitReplacementId` scores search hits (prefix/version
    split +6, same tail +4, exact name +3, pre-release −3; ≥ 3 wins) and retries; download dead (404, hash
    mismatch, nothing installed) → two previous versions, unless the newest two versions download from the same
    URL (`Test-KitSharedInstallerUrl`, `winget show --version`: Chrome, Office), then the Store channel. Heals are
    saved on this PC only (`cache\local-overrides.json`).
  - **script:** the vendor's official `irm <url> | iex`, always in a **child** `powershell.exe`, so a vendor
    `exit`/`throw` can't close the menu. A failure whose output names Windows Application Control while **Smart App
    Control** is on (`Test-KitSmartAppControl`: `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy`
    `VerifiedAndReputablePolicyState` = 1, Enforce; 0 off, 2 evaluation) is **blocked** "blocked by Smart App
    Control", not failed; an `Unsigned` tool (Hermes) is not even started there, so Update AI tools skips it with that
    note. When the tool is already installed and has an `Update` command
    (`claude update`, `agy update`, `hermes update`), that runs instead. `Interactive` scripts (MAS, WinUtil)
    share the console. `Shell: pwsh` runs the child in PowerShell 7 instead (the Chris Titus profile installs
    into the running shell's profile). `Elevated` without admin rights opens the child in **its own administrator
    window** (`Start-Process -Verb RunAs`, `-EncodedCommand`, so no quoting issues), which waits for Enter so its
    output can be read; a declined UAC prompt is reported as "administrator prompt declined" (exit 1223). Already
    elevated: it shares the console like any interactive script.
  - **direct:** `Resolve-KitDirect` fetches the vendor's download page and pulls the current installer link with
    the catalogue regex (per CPU arch), so every run gets the vendor's latest release. If the installed version
    is already ≥ that, it reports up to date and downloads nothing. Otherwise (after the in-use check) it downloads to `%TEMP%`, requires
    a **valid Authenticode signature from the catalogue's signer** (Google LLC), runs it silently and waits for
    that process only. If the page no longer matches, it falls back to the `Fallback` winget ID for that run.
  - **npm:** `npm install -g` (needs Node; also the update path, it fetches the latest).
  - **builtin:**
    - `enable-rdp`: registry + NLA + the firewall group by its resource string (`Enable-NetFirewallRule -Group
      '@FirewallAPI.dll,-28752'`, the same on every Windows language; the display name "Remote Desktop" is localized),
      elevated via UAC when needed (`Get-KitEnableRdpScript`); prints the Tailscale IP if present.
    - `dev-folder`: `Get-KitDevFolderPath` = the first folder that already exists of `D:\dev\github`,
      `%SystemDrive%\dev\github`, `D:\dev\git`, `%SystemDrive%\dev\git` (the D: ones only when D: is ready and a
      **Fixed** disk: `System.IO.DriveInfo`; a CD/DVD, USB stick or network drive doesn't count); none → `D:\dev\github`
      with a fixed D:, else `%SystemDrive%\dev\github`. Nothing is ever moved, renamed or deleted (an old `dev\git`
      keeps being used). Exists → current; dry run → "would create <path>"; otherwise `New-Item` → done.
      `-DDriveType` and `-Exists` (path → bool) inject the D: check and the folder checks for tests.
    - `wsl-ubuntu` (`Invoke-KitWslUbuntu`): WSL present (`%ProgramFiles%\WSL\wsl.exe` or the
      `MicrosoftCorporationII.WindowsSubsystemForLinux` package; the inbox stub doesn't count) → `wsl --update`,
      else `wsl --install --no-distribution`, both through `Invoke-KitElevatedCapture` (already admin:
      `Invoke-KitProcess`; otherwise one UAC prompt for a hidden `cmd.exe` that redirects the output to a temp
      file and sets `WSL_UTF8=1` itself, because the elevated process doesn't inherit the environment). A restart
      request (exit 3010/1641 or "reboot"/"restart the system" in the output, `Test-KitRebootNeeded`) ends it as
      failed with "restart Windows, then run this again", so *Retry last run's failures* picks it up. Then
      `wsl --list --online` (with `WSL_UTF8=1`; `ConvertFrom-KitWslText` strips the NULs of UTF-16 output either
      way) → `Select-KitUbuntuDistro`: the highest `Ubuntu-NN.04` with an even NN (LTS), else `Ubuntu`; no header
      needed, so localized output works. Already registered → current. Otherwise `wsl --install -d <name>` with
      the console attached (the catalogue entry is `Interactive`): Ubuntu's first run asks for a Linux user name
      and password, then the user types `exit`. Success = the distro is registered afterwards.
  - `Requires` (git, npm) is checked after reloading PATH from the registry, so a tool installed earlier in the
    same run is found.
- **Child processes: `Invoke-KitProcess`.** Every non-interactive native program (winget, `claude`/`agy`
  version and update, npm, the non-interactive `irm | iex` child, the RDP helper) runs through it, never through
  `& exe`. It starts the program with `ProcessStartInfo` (`CreateNoWindow`, stdin/stdout/stderr redirected, both
  streams read at once, UTF-8), so the child gets its own hidden console and returns `Ec`, `Out`, `Err` and
  `Started`. `.cmd`/`.bat` files run via `cmd.exe /d /s /c`. Reason: PowerShell 7 in a conhost window switches
  the console's VT processing off for as long as a `&`-started program runs, and Spectre's live progress and
  spinners then print raw escape codes. Only `Interactive` items (MAS, WinUtil, an already-elevated Chris Titus
  prompt, `wsl --install -d` for Ubuntu's first run) and the tweaks menu ("Open here") still share the console; nothing live is drawn while they run. `Enable-KitConsoleVt` switches VT back on (best effort, no-op when output is not a
  console); both menus call it after the scan and after each package.
- **`Get-KitRunOrder`** sorts by catalogue group order, then Id, with POST always last.
- **`Get-KitLatestVersion`** (direct = vendor page, winget = `winget show`, npm = `npm view`) feeds the "Update
  AI tools" table, for installed tools only.
- **`Get-KitAiUpdateSet -Installed`**: what "Update AI tools" (and classic `L` `2`) updates: `AI`-flagged apps that
  are installed. The `AI` flag never installs anything and never ticks an app (Cursor and Codex CLI are AI-flagged
  and off by default).
- **State** (`%LOCALAPPDATA%\my-win-kit\state.json`, per PC, never synced): last selection, last failures,
  the desktop-shortcut setting. `MYWINKIT_STATE_DIR` overrides the folder (tests).
- **Per-PC preferences** (`%LOCALAPPDATA%\my-win-kit\local-settings.json`, canonical JSON, never synced):
  `Get-KitLocalPrefs` / `Set-KitLocalPref`. Keys `autoInstallEssentials` (older name `autoInstallPwsh`, still read)
  and `elevateAtStart`; `Get-KitLocalSwitch -Legacy` (wrapped by `Get-KitAutoInstallEssentials` / `Get-KitElevateAtStart`)
  returns the effective value and its source (`this PC` / `shared` / `default`).
- **NoAdmin installs from an elevated kit:** `Test-KitDeElevate` = the package has `NoAdmin`, the kit is elevated
  (`Test-KitAdmin`, which honours `MYWINKIT_SIMULATE_ADMIN`) and it isn't Interactive. Then its install command
  (winget, script, native updater, npm, direct installer) goes through `Invoke-KitDeElevated` instead of
  `Invoke-KitProcess` (`Invoke-KitChild` picks one). **Method:** a one-shot scheduled task through the Task
  Scheduler COM API (`Schedule.Service`, no module): principal = the session user (`Get-KitSessionUser`, owner of
  `explorer.exe` in this session), `LogonType` 3 (interactive token), `RunLevel` 0 (LUA). Task Scheduler starts it
  with that user's filtered token, the same one Explorer has, so it runs at medium integrity in the user's own
  profile. The action is `conhost.exe --headless powershell.exe -EncodedCommand <script>` (no window, also with
  Windows Terminal as the default terminal); the script (`Get-KitDeElevatedCommand`) runs the program, writes its
  output and exit code to `%TEMP%\my-win-kit\deelevated-<id>.out|.ec`, and the kit polls for them (2 h limit),
  then deletes the task. `runas /trustlevel` is not used: it gives a restricted token, not a normal one. Separately, any
  winget run as admin that exits `0x8A150056` (installer prohibits elevation, manifest `elevationProhibited`) or
  `0x8A15007D` (admin context prohibited for a user-scope package) is retried once de-elevated, catalogue flag or
  not. `MYWINKIT_SIMULATE_DEELEVATE=ok|fail` fakes the result (tests).
- <a id="essentials"></a>**Essentials** (`Invoke-KitEssential -Name claude|font|terminal-settings|default-terminal`,
  called by the loader in that order; returns `Name, Label, Status = done|current|dryrun|failed|skipped, Detail`, never
  throws; `MYWINKIT_SIMULATE_ESSENTIALS` / `MYWINKIT_SIMULATE_FAIL` simulate it):
  - **`claude`** (`Install-KitClaudeCode`): present = `%USERPROFILE%\.local\bin\claude.exe` or `claude` on PATH
    (`Test-KitClaudeCode`). Otherwise Anthropic's official `irm https://claude.ai/install.ps1 | iex` in a child
    `powershell.exe` (`Get-KitRemoteScriptArgs`). The installer only writes to the user's profile
    (`%USERPROFILE%\.claude\downloads`, `%USERPROFILE%\.local\bin`) and Anthropic's docs say it needs no
    administrator rights; Claude Code updates itself in the background later, as the user. So from an elevated kit
    it runs at the signed-in user's normal rights (`Invoke-KitDeElevated`; if that cannot start, it runs in the kit's
    own context, which is the same account). The catalogue entry (Id 46) is `NoAdmin` for the same reason and stays
    in Update AI tools.
  - **`font`** (`Install-KitNerdFont`): present = `CaskaydiaCoveNerdFontMono-Regular.ttf` in `%WINDIR%\Fonts` or
    `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, or a `CaskaydiaCove Nerd Font Mono*` value under HKLM/HKCU
    `...\Windows NT\CurrentVersion\Fonts` (`Test-KitNerdFont`). Source: the GitHub API's
    `repos/ryanoasis/nerd-fonts/releases/latest` → asset `CascadiaCode.zip` (`Get-KitNerdFontRelease`; never a fixed
    version). Verification: the download's SHA-256 (.NET, `Get-KitFileSha256`) must equal the asset's `digest` that
    GitHub publishes, else the line for it in the release's `SHA-256.txt`; with neither it is not installed. The zip
    is opened with `System.IO.Compression.ZipFile` (not `Expand-Archive`), and only the leaf names
    `CaskaydiaCoveNerdFont-*.ttf` and `CaskaydiaCoveNerdFontMono-*.ttf` are extracted (no Propo variant, no paths
    from the archive). Elevated: copied to `%WINDIR%\Fonts`, registered under HKLM by file name; otherwise
    `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + HKCU by full path (value names from the file names,
    `ConvertTo-KitFontRegName`). Then `AddFontResource` + `WM_FONTCHANGE`, so it works without signing out.
  - **`terminal-settings`** (`Merge-KitTerminalSettings`): see [Windows Terminal settings](#windows-terminal-settings).
  - **`default-terminal`** (`Set-KitDefaultTerminal`): `HKCU\Console\%%Startup` `DelegationConsole` =
    `{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}` and `DelegationTerminal` = `{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}` (Windows
    Terminal, stable; values from Microsoft's Terminal group-policy page; Preview and "let Windows decide" use other
    GUIDs). Written only when they differ. Registry access goes through `@{ Read; Write }` scriptblocks
    (`Get-KitRegistryAccess`), which tests replace with an in-memory stub.
- **Update everything:** `Get-KitUpdateAllPlan -Installed -Updates` returns `Kit` (`Get-KitCatalogUpdateSet`:
  installed catalogue apps with a known newer version, plus script tools with a native updater and npm tools,
  whose updates winget doesn't list; never Interactive or POST; `SelfUpdates` apps go to `SelfUpdating` instead,
  listed as "updates itself" and left out of `Run`) and `Other`: the rows of `winget upgrade`
  (`ConvertFrom-KitWingetUpgradeText`: first table only, so the "require explicit targeting" table and the footer
  are left out; the raw lines are reused from the last `Get-KitUpdates`) minus catalogue winget / Store / fallback
  IDs, `winget pin` pins (`Get-KitWingetPins`), unknown or ranged versions and cut-off Ids (`Excluded` says why).
  Other rows become items with `Method = 'winget-upgrade'`, a negative Id and group `PC` (`New-KitPcUpgrade`);
  `Invoke-KitPackage` runs them as `winget upgrade --id <Id> --exact --silent --accept-package-agreements
  --accept-source-agreements --disable-interactivity [--source]` through `Invoke-KitWinget` and classifies the exit
  with `Get-KitWingetOutcome` (the same buckets; a transient error is retried once). Menus never remember negative
  Ids as a selection or failure.
- **Unattended plan:** `Get-KitAutoPlan` = recommended apps that are missing (`Install`) + the update-everything
  plan (`Update` = its kit half, `Other` = the rest of the PC); `Skipped` = Interactive / POST items it would otherwise touch
  (recommended or installed); `SelfUpdating` = left alone. `Get-KitAutoExitCode`: 1 = something failed, 2 = nothing
  failed but something is blocked, 0 = all ok (restart needed and skipped are not failures).
- **Failure reasons:** `Get-KitFailLine` picks the last output line that names a problem; winget, scripts and native
  updaters use it, so a result says e.g. "An Application Control policy has blocked this file (exit 1)" rather than
  "see log".
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
  in dry run, a purple **DRY RUN** badge plus a full-width purple rule on every screen. Elevated: an orange **ADMIN**
  badge on the banner and on every sub-screen's title rule (`not admin` in grey on the banner otherwise). Sub-screens use one
  gradient title rule. Tables and panels are rounded with coloured borders; each catalogue group has its own
  accent colour + icon (`$script:GroupStyle`). Quitting prints a gradient goodbye bar.
- **Glyphs:** only characters present in **both Consolas and Cascadia Mono** (verified with WPF `GlyphTypeface`),
  so classic conhost renders them without font fallback. Badges, used the same way in picker, review, progress
  and results: `√` installed (green), `↑` update available / updated (yellow / green), `·` not installed (grey),
  `×` failed (red), `↔` healed (aqua), `○` dry run (purple), `=` up to date (aqua); results only: `√` restart needed
  (yellow), `▲` blocked (orange; the same `▲` that marks warnings), `-` skipped (grey). ✓ ✗ ↻ are missing from Consolas
  (and ✗ ↻ from Cascadia Mono), so they are not used. The spinner is Spectre's `Point` (`∙●∙`); the default
  `Dots` spinner uses Braille, which Consolas lacks.

- **Update badges:** `Get-KitUpdates` (one `winget upgrade`, ~2-3 s, plus the vendor page for direct apps) runs
  with the installed scan when the install screen opens, so the picker can show `↑ old → new`.
- **Main menu:** Install apps · Update · Windows tweaks · Settings · Quit, each with an icon and a one-line
  description.
- **Update** (submenu, « Back = main menu): **Update everything** (spinner: scan + `Get-KitUpdates` +
  `Get-KitUpdateAllPlan`, then a Review table of kit apps, then "updates itself" rows (grey `-`, left out), then
  other apps, trimmed to window − 20 rows (− 21 with self-updating rows), with counts and the number skipped; Esc =
  back; "Update all now" / "Simulate all now" runs the plan's `Run` list; "Choose which to update" (only when there
  are self-updating apps) opens a grouped picker with kit and other apps ticked and the self-updating ones unticked)
  and **Update AI tools** (below). After a run, back goes to the main menu.
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
     summary panel (`√ ok · ↔ healed · ▲ blocked · × failed · total time`, "Restart Windows to finish: …", log path,
     removed shortcuts; purple in dry run, red with failures, orange with blocks, green otherwise). With failures or
     blocks the results screen offers **Retry the failed / blocked** (`Invoke-RunWithRetry`: runs just those again,
     as often as needed, after the user closed the apps that were in use; the results table keeps window − 24 rows
     then) above the « Back row.
- **Update AI tools** (under Update; « Back returns to the Update submenu): table of every `AI = $true` app (installed, latest, how it updates: winget upgrade, npm,
  official updater or download page; trimmed to window − 17 rows, installed first), then "Update all installed"
  or "Pick which installed tools to update". Both use `Get-KitAiUpdateSet`, so a tool that isn't installed is
  never installed from here (the title says so; with none installed only « Back is offered). Runs with
  `-Mode update`; latest versions are looked up for installed tools only.
- **Windows tweaks:** describes the 4 fixes and runs `win11-tweaks.ps1` here or elevated in a new window.
- **Settings:** read-only shared config (see [Configuration on GitHub](#configuration-on-github-read-only)); this
  PC's "Install essentials on start (PS7, Terminal, Claude Code, font, Terminal settings)" and "Ask for administrator
  rights once at start" toggles
  (`local-settings.json`; each row says whether the value is this PC's own or the shared default; the admin one
  takes effect at the next start), session dry-run toggle, open the log folder.
- **Interactive items** (POST, Chris Titus prompt, WSL + Ubuntu) run after the progress view; their `OnStatus`
  steps print as grey lines above the child's own output (e.g. "type exit to come back here").
- **Smoke-test hook:** `-TestKeys` swaps `AnsiConsole.Console` for Spectre's `TestConsole` (120 × 30) and feeds
  the keys to the picker; it forces dry run and locks it on, and prints `SCREEN-HEIGHTS: name=rows; ...` on exit
  so tests can prove every screen fits 30 rows.

## Configuration on GitHub (read-only)

**Decision (2026-11-25, Daniel):** in-menu saving to GitHub can't be relied on (gh install, sign-in and real
keyboard entry are untested on other PCs), so the menu never writes config. GitHub is the single home:
`config/catalog.json`, `config/settings.json`, `config/winget-id-overrides.json` and `config/terminal.json` on
`main`. Daniel edits them
by hand in the repo; every deployed copy reads the latest at start-up. There is no local overlay, no import step and
no GitHub CLI dependency.

- **Read (`Read-KitConfigFile`, per file):** `https://raw.githubusercontent.com/<repo>/<branch>/config/<file>`
  (4 s timeout, public repo, no sign-in) → `%LOCALAPPDATA%\my-win-kit\cache\<file>` (last good copy) → the copy
  bundled with the kit (`config/` next to install.ps1) → built-in defaults (settings/overrides only). A network
  failure skips the other files' timeouts. Every fetched copy is validated before it is used or cached; a damaged
  cache is reported and skipped. The banner and the Settings screen show the source (GitHub, cached <time>,
  bundled).
- **Settings screen (modern menu):** read-only panel with the config source, the current values of
  `removeShortcuts`, `dryRunByDefault`, `autoInstallEssentials` and `elevateAtStart`, the number of package-ID fixes in use and the ones
  learned on this PC (with their file), and the line "To change config, edit config/*.json in the my-win-kit repo
  on GitHub." Its actions are local only: this PC's auto-install override (`local-settings.json`), the session
  dry-run toggle and opening the log folder. Smoke tests write the override only into their scratch state folder.
- **Learned heals:** `Save-KitOverride` keeps each heal on the PC that found it
  (`cache\local-overrides.json`, `Get-KitLocalOverrides`) and applies it at every start on top of
  `config/winget-id-overrides.json`. Nothing is pushed; to share a heal, copy it into the repo file (or fix the
  `Ref` in `catalog.json`).
- **Hand edits:** keep the files in the canonical form `ConvertTo-KitJsonDocument` writes: ASCII-only JSON
  (`\uXXXX` escapes), one group / package / direct rule per line. `test-config.ps1` fails when a file is not in
  that form, when two packages (incl. `Removed`) share an Id, or when a package uses a `RetiredIds` entry. To drop
  an app, move its line to `Removed` (hidden, Id kept); a new app takes an Id above every Id in Packages, Removed
  and `RetiredIds` (the next free one is in STATUS).
- **Test hooks:** `MYWINKIT_REPO`, `MYWINKIT_BRANCH`, `MYWINKIT_CONFIG_URL` (another base, or a `file:///` folder).

### Windows Terminal settings

`config/terminal.json` (read like the other files; the loader reads the cached copy, then the bundled one, and the
menus refresh the cache from GitHub at each start; `Get-KitTerminalConfig`). Fields: `startingDirectory.prefer`
(`dev-folder` today = the kit's dev folder from `Get-KitDevFolderPath`: an existing `dev\github` or `dev\git` on D:
or C:, else a new `D:\dev\github` or `C:\dev\github`, created; or a folder, environment variables allowed, used when it exists, else the dev folder;
`Resolve-KitTerminalStartDir`), `defaultProfile` (guid), `globals`
(top-level Terminal settings), `profileDefaults` (= `profiles.defaults`), `profiles` (matched by `guid`) and
`keybindings` (`{ id, keys }`). Public repo: no user names, host names or personal paths (`test-config.ps1` checks).

`Merge-KitTerminalSettings` applies it to `Get-KitTerminalSettingsPath` (the package's
`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`, or the unpackaged
`%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json` when only that exists; `MYWINKIT_WT_SETTINGS` in tests):

- **No file** (Terminal never started): writes a new one with `$help`, `$schema` and the desired settings;
  Terminal adds its generated profiles (PowerShell, Command Prompt, WSL distros) at its first start, so the repo
  lists none of them.
- **Starting folder:** set in `profiles.defaults` and in every kit profile (the `profiles` here, by guid), so a PC's
  Claude Code profile that carries its own folder moves to the dev folder too; other profiles keep theirs. The
  `my-win-kit` profile starts `install.cmd` from the OneDrive kit folder through `%OneDrive%` (`cmd.exe /d /c if
  exist ...`, a message when the folder isn't there), so the repo holds no personal path.
- **Existing file:** read as JSON with comments (`ConvertFrom-KitJsoncText`: `//` and `/* */` comments and
  trailing commas are stripped outside strings; plain files take a fast path). It sets `globals`, merges
  `profileDefaults` into `profiles.defaults` key by key (objects such as `font` merge, so a font size stays), adds or
  updates each profile by guid (keys of its own stay), sets `defaultProfile`, and sets each key binding (an entry
  with the same id or the same keys is replaced). An old-style `profiles` list is wrapped into `{ defaults, list }`.
  Everything else stays (other profiles, schemes, actions, themes). Comments in the file are not kept.
- **Only when something changed:** the parsed file and the result are written with the same indented ASCII writer
  (`ConvertTo-KitJsonPretty`) and compared; equal → `current`, no write. Otherwise a backup
  `settings.json.bak-my-win-kit-<yyyy-MM-dd>` (a second one the same day gets the time), then the new file (UTF-8, no
  BOM). A file that does not parse is never overwritten.
- `-NoFont` leaves the font face out while CaskaydiaCove Nerd Font is missing (Terminal would warn on every start;
  it is added at the next start after the font is in); `-NoDefaultProfile` keeps the PC's default profile while
  PowerShell 7 is missing (the Claude Code profile runs `pwsh.exe`).

### Catalog fields

`Groups`: `Key`, `Label`, `Letter` (classic-menu hotkey). `Packages` (and `Removed`), required: `Id` (permanent,
never renumbered or reused), `Name` (unique), `Group`, `On` (in the recommended set), `Method` (`winget` | `msstore`
| `script` | `direct` | `npm` | `builtin`), `Ref` (winget ID | Store product ID | script URL | Direct key | npm
package | builtin name: `enable-rdp`, `dev-folder`, `wsl-ubuntu`), `Desc`. Optional: `AI` (listed under Update AI
tools, which updates it only when installed; never ticks or installs it), `Interactive` (needs the console, never
under a spinner), `Elevated` (script: runs as administrator, own window when the menu isn't elevated), `Shell`
(`pwsh` = run the script in PowerShell 7 instead of Windows PowerShell), `Detect` (built-in install check:
`dev-folder`, `ctt-profile`, `wsl-ubuntu`), `Exe` (file, or folder, that proves a script/npm install, env vars
expanded), `Version` (command whose
output has the installed version), `Update` (native updater, e.g. `claude update`), `Appx` (MSIX package name),
`Uninstall` (regex on the uninstall DisplayName), `Fallback` (winget ID when a direct download can't be resolved),
`Requires` (command that must exist first), `NoAdmin` (the installer must not run as administrator: from an
elevated kit it runs at the signed-in user's normal rights, see [the engine](#the-engine-srccorepsm1); never on an
Interactive or Elevated item), `SelfUpdates` (the app keeps itself current and runs ahead of winget: installed
normally, left out of Update everything and `/auto` updates unless ticked by hand, a hash mismatch or "not newer" is
never a failure), `Unsigned` (its program is unsigned: on a PC with Smart App Control on it is reported as blocked
and not run), `InstallerType` / `Scope` (winget `--installer-type` / `--scope`, fresh installs only, e.g. Notepad++
`nullsoft` instead of the enterprise MSI winget picks by default), `HashNote` (the text for a hash mismatch).
`RetiredIds`: Ids that must never be reused. `Direct.<key>`: `Page`,
`Pattern` (regex with `{arch}` / `{arch2}`), `Arch`, `Arch2`, `Signer` (Authenticode subject), `Args` (silent
switches). Claude Desktop stays on winget on purpose: Anthropic's latest-download link refuses scripted clients.

## Self-update and the one-line install

The loader (Windows PowerShell 5.1) keeps every PC on the newest kit without git or OneDrive changes:

- **Version check:** `KitVersion` from `src/core.psm1` on GitHub `main` (raw URL, 3 s timeout). Newer than the
  running copy → "Update kit 2.4.0 -> 2.5.0? [Y/n]" once per version (a "no" is remembered in
  `%LOCALAPPDATA%\my-win-kit\update.json`; no question when input is redirected, e.g. CI). `-Auto` takes the
  newer version without asking (an earlier "no" doesn't apply); a failure still keeps the running copy.
- **Install:** the repo zip (`codeload.github.com/<repo>/zip/refs/heads/main`) → extract → verify (required files,
  every script parses, catalog.json parses, version matches) → `%LOCALAPPDATA%\my-win-kit\app\<version>` (the three
  newest kept). The loader then re-runs that copy's `install.ps1 -NoUpdate` with the same arguments. Any failure
  (offline, private repo, bad zip) keeps the running copy. A newer copy already downloaded is used without asking.
- **`irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`** (fresh PC, public repo):
  `$PSScriptRoot` is empty, so the loader downloads the kit into `app\<version>` the same way, starts it as a child
  `powershell.exe` (which asks for administrator rights itself and waits for its elevated copy), and returns (never
  `exit`, which would close the user's window). `& ([scriptblock]::Create((irm <url>))) -Auto` passes arguments on.
- `OneDrive\[98] Shortcuts\install.cmd` keeps working as the launcher: it runs the published copy, which updates
  itself from GitHub.
- The repo is public, so none of this needs a sign-in. If it ever went private, the raw/zip URLs would return 404:
  no self-update, no `irm | iex`, and config would come from the cache or the bundled copy.
- Test hooks: `MYWINKIT_RAW_URL`, `MYWINKIT_ZIP_URL` (`file:///` allowed), `MYWINKIT_BOOTSTRAP_ARGS`,
  `-UpdateAnswer`.

## Run log (which front-end ran)

One file per run in `%LOCALAPPDATA%\my-win-kit\logs\run-<date>-<pid>.log` (newest 30 kept; `MYWINKIT_STATE_DIR`
moves it). The loader creates it and passes the path in `MYWINKIT_RUNLOG`; both menus append through
`Write-KitRunLog`. It records the loader's PowerShell, the pwsh it found (path, version), the decision
(modern / offer install / classic + reason), `elevate: elevated = yes|no - <why>` (and the elevated copy's own
lines, in the same file), the front-end that actually started (`elevated=yes|no`) (with PwshSpectreConsole
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
`I` install, `L` update (a one-line submenu: `1` everything = `Get-KitUpdateAllPlan` with both groups listed and one
[Y/n], `2` AI tools = `Get-KitAiUpdateSet`, installed ones only; Enter = back), `W` Windows tweaks, `K` this PC's
essentials on start on/off, `V` this PC's admin at start on/off (both shown on the command
line with their source), `Q` quit. `ADMIN` on the subtitle when elevated. **`-Auto`** (from the loader's `/auto`):
no menu and no questions: `Get-KitAutoPlan`, the same run loop without the "Press Enter" (`-Unattended`), a
"Skipped (needs you)" line, an "Updates itself (left alone)" line, a "Blocked (needs you)" list with each reason,
the run log path and `exit 0|1|2`; `-Pause` waits for Enter at the end. Runs print one line per app using the same
engine (badges as above); after a run with failures or blocks, `R` retries just those (Enter = continue), and they
stay selected for a later `I`. `L` `1` lists the self-updating apps apart and asks `[Y/n, s = also the N that update
themselves]`. `-TestInput "a;b;c"` feeds answers (tests).

## win11-tweaks.ps1

- StrictMode + `$ErrorActionPreference = 'Stop'`, 76-column layout, its own palette. UTF-8 with BOM (it
  contains box-drawing characters, and 5.1 needs the BOM to read them).
- `$script:Fixes` (L87) is a list of hashtables `Id, Name, Description, Scope (HKCU|HKLM), Reboot, Apply,
  Check, Revert`. The menu's `'1','2','3','4'` switch case is hard-coded.
- `Show-Menu` runs each fix's `Check` live to show ON/OFF. `Invoke-Toggle` runs `Apply` or `Revert`, and
  refuses HKLM fixes when not elevated. `A`/`R` = all on/off. `Q` offers a reboot if needed.

## publish.ps1

- Copies only the kit file set: `src/*.ps1|psm1|psd1` first, then `config/*.json` (the bundled offline fallback;
  live config is read from GitHub), `win11-tweaks.ps1`, `install.cmd`, and `install.ps1` **last**, so a PC that
  syncs mid-publish never gets a loader whose `src/` is missing. It creates `src\` / `config\` in the target when
  needed. It never deletes anything or touches other files there; `` names legacy root files from older
  versions (`my-packages.json*`, `winget-id-overrides.json`) that must never be written.
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
| `tools/test-core.ps1` | 5.1 + pwsh | essentials: Terminal settings merge on scratch files (new file, existing file with comments + trailing comma + other profiles kept, backup, second run = no write, dry run, unparsable file left alone, `-NoFont` / `-NoDefaultProfile`, old-style profile list), starting-folder fallback, default terminal through a registry stub, Nerd Font detection + install from a local zip into a scratch folder, latest-release parsing from a sample GitHub API answer (digest, `SHA-256.txt` fallback), simulated steps; per-PC `autoInstallEssentials` (+ the older `autoInstallPwsh`), `elevateAtStart`, NoAdmin set + routing (`Test-KitDeElevate`), the de-elevation helper (simulated) and its task script (run directly, no task), the `/auto` plan and exit code, the update-everything plan on sample `winget upgrade` output (kit IDs, pins, unknown versions left out; explicit-targeting table ignored), failure reasons; catalogue sanity (unique Ids/names, groups, methods, DEV/POST off, POST interactive), the 2026-11-26 catalogue changes (removed apps, Obsidian off, Cursor/Codex AI-flagged and off, the three new entries), `Get-KitAiUpdateSet` (installed only), dev-folder path choice (injected D: types x existing folders, 80 combinations), WSL distro picker on sample `wsl --list --online` text (plain and UTF-16-as-UTF-8), restart detection, dry run of every package, version compare; v2.8: every winget outcome bucket on sample exit codes, result status per bucket, SelfUpdates in the update-all plan and on hash mismatch, `/auto` exit codes 0/1/2, installer type / scope / source arguments (fresh install vs upgrade), in-use detection with a fake ARP list + process list, hash mismatch (source update once + retry) and transient retry with winget mocked in the module, Smart App Control (simulated), the RDP group string, the PowerShell 7 `.msixbundle` from a sample GitHub API answer, kit profile starting folder override, the PID in the log name, the 2.8 catalogue changes; `-Online` adds the installed scan and vendor-page resolution |
| `tools/smoke-tui.ps1` | pwsh | the Spectre menu driven by scripted keys (`MYWINKIT_SIMULATE_ADMIN=0` unless a scenario sets it): Update submenu, Update everything review (+ a dry run when this PC has updates, local only), exactly one Back row on a results screen, the ADMIN badge, the admin-at-start Settings row, install flow, search, AI table (every AI tool listed, never "installs missing ones"), settings (read-only panel, a seeded local fix, the per-PC auto-install toggle; fails if removed screens reappear) + tweaks (+ "update all" and "pick installed" when an AI tool is installed, local only), the result badges (blocked / restart needed / skipped / failed through `MYWINKIT_SIMULATE_OUTCOME`, dry run only) and Retry the failed / blocked |
| `tools/smoke-loader.ps1` | 5.1 | essentials (simulated): order PS7 → Terminal → Claude Code → font → Terminal settings → default terminal, all present = nothing runs, partly present, a failure carries on and is not retried the same day, dry run, `/auto`, setting off = none run, skipped in test mode without the simulation; elevation (simulated: relaunch / already admin / declined / standard account / other account handed back / setting off / `/noelevate`, arguments kept, classic `V`, ADMIN); `/auto` with stdin closed and a time limit (exit 0, no prompt, run log, with a simulated elevation; essentials off asks nothing); `install.cmd` argument pass-through; Windows Terminal relaunch (simulated with `MYWINKIT_SIMULATE_WT_LAUNCH`): elevated wt launch with arguments kept (incl. `;`) and the exit code through the hand-off file, the over-the-shoulder 75 through it, wt failure or no wt = the console window, no admin = relaunch without UAC, `-InTerminal` / `WT_SESSION` = no relaunch, one relaunch only, `/auto` stays; classic `L` submenu; classic result badges and `R` retry; loader decisions (pwsh/Terminal present / absent / forced classic); auto mode installs without the question (dry run, simulated ok and failed installs end in the classic menu; a failed Terminal install isn't retried the same day); essentials off via `local-settings.json` (older `autoInstallPwsh` name): declining and dry-run accepting the PowerShell 7 install; classic `K` toggles the override; a classic-menu run |
| `tools/test-config.ps1` | 5.1 + pwsh | config read chain (remote / cache / corrupt cache / bundled / defaults; terminal.json cached too), JSON writer (ASCII, round trip) and canonical form of all four `config/*.json`, terminal.json ASCII + no personal data (user and host names, `C:\Users\` paths, IPs), catalogue Ids (unique across Packages + Removed, no `RetiredIds` reuse, Python 3.14 on Id 62), terminal.json `dev-folder` start folder and the path-free my-win-kit profile, heals kept local, no config-write functions exported, publish, self-update (accept / reuse / decline / broken zip), `irm \| iex` bootstrap |
| `tools/render-screens.ps1 -OutDir <dir>` | pwsh (+5.1 for classic) | not a test: captures every screen as `.txt` (layout) and truecolor `.ans` (view with `Get-Content x.ans -Raw` in Windows Terminal) at 120 × 30, and prints the main-menu height |

test-core, smoke-tui, smoke-loader and render-screens point `MYWINKIT_CONFIG_URL` at the repo's own `config/`
(a `file:///` URL), so they test this copy's catalogue (a branch or PR), not whatever is on GitHub `main`.

`.github/workflows/lint.yml` runs two jobs on `windows-latest`: **ps51** (parse, test-core, smoke-loader, test-config) and
**pwsh** (lint, test-core -Online, test-config, install PwshSpectreConsole, smoke-tui). `$KnownIssues` in `lint.ps1`
downgrades listed findings to warnings; it is empty.
