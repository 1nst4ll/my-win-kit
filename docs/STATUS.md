# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-26._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Kit v2.6.0 is on branch `elevate-auto` (PR #3 into `main`, waiting for Daniel's go; not merged, not
  published).** Admin once at start (`elevateAtStart`, default on, per PC in Settings / classic `V`; standard
  accounts are never elevated as a whole), unattended `install.cmd /auto` (exit 0/1, no questions), a new **Update**
  menu (Update everything = kit apps + the rest of the PC via `winget upgrade`; Update AI tools moved under it),
  `NoAdmin` installs run at normal user rights from the elevated kit, the double Back row on results screens fixed.
  All local tests pass; the real UAC prompt and real installs are untested (see Open items 1).
- **Kit v2.5.0 is live:** PR #2 merged into `main` (f30b5c7) on 2026-11-26 with Daniel's go ("merg 2"); the
  post-merge publish copied 6 files to OneDrive.
- After the PR #3 merge: run `install.cmd` on this PC once (one UAC prompt, then no others), try
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
| Config home | `config/catalog.json`, `config/settings.json`, `config/winget-id-overrides.json` on GitHub `main`, edited by hand |
| Publish target | `$env:OneDrive\[98] Shortcuts` (the OneDrive folder every PC syncs) |
| Last publish | 2026-11-26: merge of PR #2 (kit v2.5.0), 6 files copied (`src/core.psm1`, `src/tui-classic.ps1`, `src/tui-spectre.ps1`, `config/catalog.json`, `config/settings.json`, `install.ps1`) |
| Apps in `config/catalog.json` | 59 total: 33 in the recommended set, 22 DEV (off), 3 POST (off); 2 removed (Perplexity 8, Samsung Quick Share 33). NoAdmin: 4 (OneDrive, VS Code, GitHub Desktop, Cursor) _(NoAdmin only on branch `elevate-auto`)_ |
| By method | 45 winget, 2 Store, 6 script, 2 direct, 1 npm, 3 builtin. AI-flagged (Update AI tools): 9 (Claude Desktop, Claude Code CLI, KiloCode CLI, Cursor, Codex CLI, Antigravity IDE, Antigravity, Antigravity CLI, Hermes Agent) |
| Next free app Id | 62 (above every Id in Packages, Removed, RetiredIds; use it when adding an app to `config/catalog.json` by hand) |
| Kit version | 2.6.0 on branch `elevate-auto` (`$script:KitVersion` in src/core.psm1); `main` is 2.5.0 |
| Shared settings | `removeShortcuts` true, `dryRunByDefault` false, `autoInstallPwsh` true, `elevateAtStart` true (branch) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0); no GitHub CLI or sign-in |
| Startup (this PC) | ~750 ms launch → banner → quit, plus the config fetch (3 small files) |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 25, Update 11, Update everything review ≤ 28, AI 26 (9 tools; pick 18), tweaks ≤ 24, settings 25 (27 with local fixes), classic 29 incl. the prompt line (1 row spare: one more row of apps in a group needs a layout change) |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept); config cache and this PC's learned heals (`local-overrides.json`) in `...\cache`, downloaded kit copies in `...\app`, per-PC preferences in `...\local-settings.json`, the loader's "Terminal install failed today" note in `...\loader.json` |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader, test-config) + pwsh job (lint, test-core -Online, test-config, smoke-tui) |

## Open items (priority order)

1. **Untested for real (needs a person or a spare PC):** the **real UAC relaunch** (`install.cmd` from Explorer:
   one prompt, the admin window, the first window waiting and closing; declined → carries on) and a **real
   `install.cmd /auto`** run; the over-the-shoulder hand-back with a real standard account; a real NoAdmin
   de-elevated install (the scheduled-task runner itself was checked by hand on ATHENA with `cmd /c`); a real
   Update everything run (rest-of-PC `winget upgrade` items, e.g. Visual C++ / .NET runtimes, which may want a
   restart); whether Dropbox's post-install launch runs elevated (no evidence either way, not NoAdmin);
   an actual install through each method;
   the **automatic PowerShell 7 + Windows Terminal install** from the loader on a fresh PC (tested with dry run and
   `MYWINKIT_SIMULATE_INSTALL` only); a **real WSL + Ubuntu install** (UAC prompt, possible restart, Ubuntu's
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

4. Hermes Agent on this PC: Windows Application Control blocks
   `%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\hermes.exe` ("An Application Control policy has blocked this
   file"), so its version shows as "installed" and `hermes update` from Update AI tools will fail here until that
   policy allows it. Detection uses the install folder (a custom `HERMES_HOME` is not detected).

## What's next

- Daniel's go on PR #3 (`elevate-auto`, kit v2.6.0), then the merge (publishes to OneDrive), then the real checks in
  Open items 1 (UAC once, `/auto`, Update everything).

- Run `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`
  on a spare PC, and bump `KitVersion` once to see the update prompt on a second PC.
