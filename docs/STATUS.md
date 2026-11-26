# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-25._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **The rebuild is live (kit v2.4.2).** PR #1 merged into `main` on 2026-11-25 with Daniel's go ("fix both and
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
| Last publish | 2026-11-25: merge of PR #1, 8 files copied (`src/*`, `config/*`, `win11-tweaks.ps1`, `install.ps1`; `install.cmd` unchanged) |
| Apps in `config/catalog.json` | 58 total: 35 in the recommended set, 20 DEV (off), 3 POST (off); 0 removed |
| By method | 45 winget, 4 Store, 5 script, 2 direct, 1 npm, 1 builtin. AI-flagged (Update AI tools): 5 |
| Next free app Id | 59 (above every Id in Packages, Removed, RetiredIds; use it when adding an app to `config/catalog.json` by hand) |
| Kit version | 2.4.2 (`$script:KitVersion` in src/core.psm1) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0); no GitHub CLI or sign-in |
| Startup (this PC) | ~750 ms launch → banner → quit, plus the config fetch (3 small files) |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 28, AI 22, tweaks ≤ 27, settings 22 (24 with local fixes), classic 26 |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept); config cache and this PC's learned heals (`local-overrides.json`) in `...\cache`, downloaded kit copies in `...\app` |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader, test-config) + pwsh job (lint, test-core -Online, test-config, smoke-tui) |

## Open items (priority order)

1. **Untested for real (needs a person or a spare PC):** an actual install through each method;
   PowerShell 7 install from the loader on a PC without it; first-run PwshSpectreConsole install; the elevated
   tweaks window; self-update and `irm | iex` against the real GitHub URLs (tested with `file:///` stand-ins).
   Raw-URL config read from `main` answers HTTP 200 since the merge.
2. **Self-update under an inherited PowerShell 7 `PSModulePath`:** when Windows PowerShell 5.1 is started from a
   shell that inherited pwsh's module path, `Expand-Archive` fails ("Cannot find an overload for
   ExtractToDirectory") and the update is skipped; the running copy is kept, so nothing strands. Seen in local test
   runs (`test-config.ps1` under 5.1 passes with a clean `PSModulePath`); `install.cmd` from Explorer is not
   affected. Not fixed yet.
3. Claude Desktop stays on winget: Anthropic's latest-download redirect returns HTTP 403 to scripted clients.

## What's next

- Run `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`
  on a spare PC, and bump `KitVersion` once to see the update prompt on a second PC.
