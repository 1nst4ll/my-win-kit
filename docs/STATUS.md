# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-25._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Branch `rebuild-tui` is awaiting Daniel's review and merge** (PR #1 into `main`): loader + Spectre menu +
  classic fallback + shared engine, always-latest AI tools, **config read from GitHub** (`config/*.json`) and
  **self-update** from GitHub. Since v2.4.0 **the menu reads config from GitHub and never writes it**: Daniel edits
  `config/*.json` in the repo by hand, every PC picks the change up at its next start, and Settings is read-only.
  **Do not merge without Daniel's go:** merging publishes to every PC through OneDrive.
- **Repo is public since 2026-11-25** (Daniel's go). History was rewritten to the GitHub noreply address and
  scrubbed of the personal email and Windows user path; the repo was recreated so no old commits stay reachable.
  The pre-rewrite repo (`my-win-kit-old`) was deleted on 2026-11-25. GitHub account: "Keep my email private"
  and "Block command line pushes that expose my email" are both on.
  Raw-URL config reads, self-update and `irm | iex` read from `main`, so they go live at the merge.
- **Next session:** Daniel tests v2.4.1 by hand, then says "merge". v2.4.1 fixes the raw escape text in the
  progress view and scan spinner (conhost + pwsh). Daniel's own v2.4.0 session on 2026-11-25 ran a real install of
  21 apps (21 ok) and an Update AI tools run. Untested so far: real keyboard on the app search (`/`), PS7 install
  on a PC without it.
- Before merging, Daniel tries it by hand (steps in the PR). If anything looks wrong, read the newest
  `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` first.
- After the merge: the post-merge publish copies `src/`, `config/` and the kit files; check its output.
- Watch-outs: `main` auto-publishes. This clone has `core.hooksPath=.githooks`; other clones need it too.

## What's live

| Fact | Value |
|---|---|
| Repo | github.com/1nst4ll/my-win-kit (**public**). `main` = old single-file installer; `rebuild-tui` = the rebuild |
| Config home | `config/catalog.json`, `config/settings.json`, `config/winget-id-overrides.json` on GitHub `main`, edited by hand (not on `main` yet: arrives with the merge) |
| Publish target | `$env:OneDrive\[98] Shortcuts` (the OneDrive folder every PC syncs) |
| Last publish | 2026-11-24: nothing changed (old 3-file kit). The rebuild is not published yet |
| Apps in `config/catalog.json` (branch) | 58 total: 35 in the recommended set, 20 DEV (off), 3 POST (off); 0 removed |
| By method (branch) | 45 winget, 4 Store, 5 script, 2 direct, 1 npm, 1 builtin. AI-flagged (Update AI tools): 5 |
| Next free app Id | 59 (above every Id in Packages, Removed, RetiredIds; use it when adding an app to `config/catalog.json` by hand) |
| Kit version (branch) | 2.4.1 (`$script:KitVersion` in src/core.psm1) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0); no GitHub CLI or sign-in |
| Startup (this PC) | ~750 ms launch → banner → quit, plus the config fetch (3 small files) |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 28, AI 22, tweaks ≤ 27, settings 22 (24 with local fixes), classic 26 |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept); config cache and this PC's learned heals (`local-overrides.json`) in `...\cache`, downloaded kit copies in `...\app` |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader, test-config) + pwsh job (lint, test-core -Online, test-config, smoke-tui) |

## Open items (priority order)

1. **Merge `rebuild-tui`** after Daniel's manual check.
2. **Untested for real (needs a person, a spare PC, or the merge):** an actual install through each method;
   PowerShell 7 install from the loader on a PC without it; first-run PwshSpectreConsole install; the elevated
   tweaks window; self-update and `irm | iex` against the real GitHub URLs (tested with `file:///` stand-ins);
   raw-URL config reads (tested with a `file:///` stand-in; `config/` reaches GitHub `main` only with the merge).
3. **Self-update under an inherited PowerShell 7 `PSModulePath`:** when Windows PowerShell 5.1 is started from a
   shell that inherited pwsh's module path, `Expand-Archive` fails ("Cannot find an overload for
   ExtractToDirectory") and the update is skipped; the running copy is kept, so nothing strands. Seen in local test
   runs (`test-config.ps1` under 5.1 passes with a clean `PSModulePath`); `install.cmd` from Explorer is not
   affected. Not fixed yet.
4. Claude Desktop stays on winget: Anthropic's latest-download redirect returns HTTP 403 to scripted clients.

## What's next

- After the merge: run `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`
  on a spare PC, and bump `KitVersion` once to see the update prompt on a second PC.
