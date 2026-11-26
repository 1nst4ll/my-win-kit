# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-26._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Kit v2.8.0 is on branch `v28-latest`, PR #5 into `main` (not merged).** Daniel: "do v2.8" (the 2026-11-26
  package check) plus "can app open in terminal instead blue ps shell". Catalogue fixes (Python 3.14 on Id 62,
  PowerToys / Node.js detection, Hermes, Antigravity IDE, Acrobat Reader, Notepad++ installer type, SelfUpdates on
  8 apps), winget outcome buckets (restart / blocked / skipped), in-use check + Retry failed, hash-mismatch
  handling, PowerShell 7 `.msixbundle` fallback, RDP firewall group by resource string, Smart App Control, Terminal
  start folder on kit profiles, the kit running inside **Windows Terminal** (elevated or not), and the dev folder
  named **dev\github** (an existing `dev\github` or `dev\git` is reused: of Daniel's 4 PCs two keep their `dev\github`, two their
  `C:\dev\git`; a PC without one gets `D:\dev\github` or `C:\dev\github`). Waiting for
  Daniel's review and go to merge (merging publishes to every PC).
- **Kit v2.7.0 is live:** PR #4 merged into `main` (f28612d) on 2026-11-26 with Daniel's go ("merge 4"); the
  post-merge publish copied 8 files to OneDrive (incl. the new `config/terminal.json`). The essentials step: at
  every start, without asking, in order: PowerShell 7, Windows Terminal, Claude Code CLI, CaskaydiaCove Nerd Font,
  the Windows Terminal settings tidied from Stacy (`config/terminal.json`) and Windows Terminal as the default
  terminal app. Setting `autoInstallEssentials` (was `autoInstallPwsh`, still read). Not yet run for real (Open
  items 1).
- **Kit v2.6.0 is live:** PR #3 merged into `main` (6b9fcc5) on 2026-11-26 with Daniel's go ("merge 3"); the
  post-merge publish copied 7 files to OneDrive. Admin once at start, unattended `install.cmd /auto`, the Update
  menu (Update everything + Update AI tools), `NoAdmin` installs at normal user rights.
- **Next on this PC:** run `install.cmd` once (one UAC prompt, then no others). Expect the essentials
  to add the Nerd Font and change this PC's Terminal (Claude Code profile as default, start folder
  = the dev folder, `C:\dev\github` on this PC from v2.8, no acrylic; backup next to it as `settings.json.bak-my-win-kit-<date>`). Then try
  `install.cmd /auto /dryrun`, then Update → Update everything for real.
- **The rebuild is live (kit v2.4.2 on `main`).** PR #1 merged into `main` on 2026-11-25 with Daniel's go ("fix both and
  merge comit push to mainn"); the post-merge publish copied 8 files to OneDrive. Every PC now gets the modern
  menu + classic fallback, always-latest AI tools, **config read from GitHub `main`** at each start (raw URL →
  cache → bundled copy) and **self-update** from GitHub. The menu never writes config: Daniel edits
  `config/*.json` in the repo and commits to `main`; PCs pick it up at their next start (raw CDN can lag ~5 min).
- **Repo is public since 2026-11-25** (history rewritten to the noreply address; old repo deleted).
- **Next:** try it on a second PC: `install.cmd` from the OneDrive folder, or
  `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex` on a fresh one.
  Untested so far: real keyboard on the app search (`/`), PS7 install on a PC without it.
- Git on Daniel's PC is still 2.55.0.5: its upgrade needs the admin prompt answered (run the kit again, or
  `winget upgrade Git.Git` from an elevated shell).
- If anything looks wrong, read the newest `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` first.
- Watch-outs: `main` auto-publishes; do multi-step work on a branch. This clone has `core.hooksPath=.githooks`;
  other clones need it too.

## What's live

| Fact | Value |
|---|---|
| Repo | github.com/1nst4ll/my-win-kit (**public**). `main` = the rebuild (merged 2026-11-25); `rebuild-tui` merged, can be deleted |
| Config home | `config/catalog.json`, `config/settings.json`, `config/winget-id-overrides.json`, `config/terminal.json` on GitHub `main`, edited by hand. Branch `v28-latest` changes catalog.json and terminal.json (live only after the merge) |
| Publish target | `$env:OneDrive\[98] Shortcuts` (the OneDrive folder every PC syncs) |
| Last publish | 2026-11-26: merge of PR #4 (kit v2.7.0, f28612d), 8 files copied. Before that: PR #3 (kit v2.6.0), 7 files |
| Apps in `config/catalog.json` | 59 total: 33 in the recommended set, 22 DEV (off), 3 POST (off); 3 removed (Perplexity 8, Samsung Quick Share 33, Python 3.13 41). NoAdmin: 6 (OneDrive, VS Code, GitHub Desktop, Cursor, Claude Code CLI, Antigravity IDE). SelfUpdates: 8 (Office, Chrome, OneDrive, Dropbox, Acrobat Reader, Teams, WhatsApp, AnyDesk). Unsigned: 1 (Hermes) |
| By method | 45 winget, 2 Store, 6 script, 2 direct, 1 npm, 3 builtin. AI-flagged (Update AI tools): 9 (Claude Desktop, Claude Code CLI, KiloCode CLI, Cursor, Codex CLI, Antigravity IDE, Antigravity, Antigravity CLI, Hermes Agent) |
| Next free app Id | 63 (above every Id in Packages, Removed, RetiredIds; use it when adding an app to `config/catalog.json` by hand) |
| Kit version | 2.7.0 on `main`; 2.8.0 on branch `v28-latest` (`$script:KitVersion` in src/core.psm1) |
| Shared settings | `removeShortcuts` true, `dryRunByDefault` false, `elevateAtStart` true; `autoInstallEssentials` true (was `autoInstallPwsh`, still read) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0); no GitHub CLI or sign-in |
| Startup (this PC) | ~750 ms launch → banner → quit, plus the config fetch (3 small files; 4 with `terminal.json`). The essentials checks add ~0.3 s when everything is already set up (core import ~55 ms, Terminal settings compare ~260 ms in 5.1) |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 25 (26 with the Retry row), Update 11, Update everything review ≤ 28, AI 26 (9 tools; pick 18), tweaks ≤ 24, settings 25 (27 with local fixes), classic 29 incl. the prompt line (1 row spare: one more row of apps in a group needs a layout change) |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept); config cache and this PC's learned heals (`local-overrides.json`) in `...\cache`, downloaded kit copies in `...\app`, per-PC preferences in `...\local-settings.json`, the loader's "failed today, retry tomorrow" notes (Terminal, Claude Code, font) in `...\loader.json`. Terminal settings backups: `settings.json.bak-my-win-kit-<date>` next to Terminal's `settings.json` |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download); Nerd Fonts v3.5.1 (`CascadiaCode.zip`, 56.6 MB, 2026-11-26) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader, test-config) + pwsh job (lint, test-core -Online, test-config, smoke-tui) |

## Open items (priority order)

1. **Untested for real (needs a person or a spare PC):** the **real UAC relaunch** (`install.cmd` from Explorer:
   one prompt, the admin window, the first window waiting and closing; declined → carries on) and a **real
   `install.cmd /auto`** run; the over-the-shoulder hand-back with a real standard account; a real NoAdmin
   de-elevated install (the scheduled-task runner itself was checked by hand on ATHENA with `cmd /c`); a real
   Update everything run (rest-of-PC `winget upgrade` items, e.g. Visual C++ / .NET runtimes, which may want a
   restart); whether Dropbox's post-install launch runs elevated (no evidence either way, not NoAdmin);
   an actual install through each method;
   the **essentials step** on a fresh PC (PowerShell 7 + Windows Terminal install; Claude Code installed
   de-elevated from the elevated kit; the Nerd Font download + machine-wide install; Terminal's settings created
   before its first start and then filled in by Terminal; the default-terminal switch). Tested with dry run,
   `MYWINKIT_SIMULATE_*`, scratch files and a registry stub only; a read-only dry run on this PC found Claude Code
   and the default terminal already set, the font missing and four Terminal settings to change; a **real WSL + Ubuntu install** (UAC prompt, possible restart, Ubuntu's
   user set-up in the kit's console, distro detection afterwards); the **real Chris Titus profile install** (its
   own administrator window under pwsh; this PC's profile is already the CTT one and is detected as installed);
   the Dev folder on a PC with a D: disk; first-run PwshSpectreConsole install; the elevated tweaks window;
   self-update and `irm | iex` against the real GitHub URLs (tested with `file:///` stand-ins). Raw-URL config
   read from `main` answers HTTP 200 since the merge.
2. **Self-update under an inherited PowerShell 7 `PSModulePath`:** when Windows PowerShell 5.1 is started from a
   shell that inherited pwsh's module path, `Expand-Archive` fails ("Cannot find an overload for
   ExtractToDirectory") and the update is skipped; the running copy is kept, so nothing strands. Seen in local test
   runs (`test-config.ps1` under 5.1 passes with a clean `PSModulePath`); `install.cmd` from Explorer is not
   affected. Not fixed yet.
3. Claude Desktop stays on winget: Anthropic's latest-download redirect returns HTTP 403 to scripted clients.

4. Hermes Agent on this PC: Smart App Control (Enforce) blocks its unsigned `hermes.exe`. From v2.8 the kit reports
   "blocked by Smart App Control" and skips it (no more failed `hermes update`); to use Hermes here, run it in WSL or
   turn Smart App Control off. Detection uses the install folder (a custom `HERMES_HOME` is not detected).
5. **v2.8 untested for real:** the elevated Windows Terminal relaunch (one UAC prompt for wt.exe, the hand-off file,
   the first window closing), the non-elevated relaunch, Terminal as the default terminal app taking over a started
   console (detected by its pseudo-console window), the PowerShell 7 `.msixbundle` signature check + `Add-AppxPackage`
   (Get-AuthenticodeSignature on a bundle not tried here) and the Store fallback, a real in-use block (e.g. Git with
   Git Bash open) and Retry, a real hash mismatch (Office) going through `winget source update`, the my-win-kit
   Terminal profile.
6. **Report items not done in v2.8 (Daniel's call):** Bitwarden `InstallerType` nullsoft + `Scope` user (winget
   picks the APPX), Affinity rename ("Affinity", Canva account), PostgreSQL password note in Desc, Zoom per-user
   package for new PCs, RealVNC `SelfUpdates` (left off: its Store copy is an MSI, and the Store does not update
   those), MAS DoH fallback, the Chris Titus profile exit-0 check, `Microsoft.WinGet.Client` instead of CLI parsing.

## What's next

- Review PR #5 (kit v2.8.0); after Daniel's go, merge (publishes), then run `install.cmd` once to see the Terminal
  window and the new result badges.
- The real checks in Open items 1 (UAC once, the essentials on this PC and on a fresh one, `/auto`, Update everything).

- Run `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`
  on a spare PC, and bump `KitVersion` once to see the update prompt on a second PC.
