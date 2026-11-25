# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-25._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Branch `rebuild-tui` is awaiting Daniel's review and merge** (PR #1 into `main`): loader + Spectre menu +
  classic fallback + shared engine, always-latest AI tools, and since v2.3.0 **config on GitHub** (`config/*.json`,
  edited from the menu as commits) plus **self-update** from GitHub. **Do not merge without Daniel's go:** merging
  publishes to every PC through OneDrive.
- **Repo is public since 2026-11-25** (Daniel's go). History was rewritten to the GitHub noreply address and
  scrubbed of the personal email and Windows user path; the repo was recreated so no old commits stay reachable.
  The pre-rewrite repo is renamed **`1nst4ll/my-win-kit-old` (private)**: Daniel deletes it with
  `gh auth refresh -h github.com -s delete_repo` then `gh repo delete 1nst4ll/my-win-kit-old --yes`.
  Raw-URL config reads, self-update and `irm | iex` read from `main`, so they go live at the merge.
- Before merging, Daniel tries it by hand (steps in the PR). If anything looks wrong, read the newest
  `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` first.
- After the merge: the post-merge publish copies `src/`, `config/` and the kit files; check its output.
- Watch-outs: `main` auto-publishes. This clone has `core.hooksPath=.githooks`; other clones need it too.

## What's live

| Fact | Value |
|---|---|
| Repo | github.com/1nst4ll/my-win-kit (**public**). `main` = old single-file installer; `rebuild-tui` = the rebuild |
| Config home | `config/catalog.json`, `config/settings.json`, `config/winget-id-overrides.json` on GitHub `main` (not on `main` yet: arrives with the merge) |
| Publish target | `$env:OneDrive\[98] Shortcuts` (the OneDrive folder every PC syncs) |
| Last publish | 2026-11-24: nothing changed (old 3-file kit). The rebuild is not published yet |
| Apps in `config/catalog.json` (branch) | 58 total: 35 in the recommended set, 20 DEV (off), 3 POST (off); 0 removed |
| By method (branch) | 45 winget, 4 Store, 5 script, 2 direct, 1 npm, 1 builtin. AI-flagged (Update AI tools): 5 |
| Next free app Id | 59 (the menu computes it: above every Id in Packages, Removed, RetiredIds) |
| Kit version (branch) | 2.3.0 (`$script:KitVersion` in src/core.psm1) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0); saving config needs the GitHub CLI signed in |
| Startup (this PC) | ~750 ms launch → banner → quit, plus the config fetch (3 small files) |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 28, AI 22, tweaks ≤ 27, settings ≤ 16, manage ≤ 29, classic 26 |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept); config cache in `...\cache`, downloaded kit copies in `...\app` |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader, test-config) + pwsh job (lint, test-core -Online, test-config, smoke-tui) |

## Open items (priority order)

1. **Public or not** (see Resume here): Daniel's decision on the commit email in the history.
2. **Merge `rebuild-tui`** after Daniel's manual check.
3. **Untested for real (needs a person, a spare PC, or the public repo):** an actual install through each method;
   PowerShell 7 install from the loader on a PC without it; first-run PwshSpectreConsole install; the elevated
   tweaks window; self-update and `irm | iex` against the real GitHub URLs (tested with `file:///` stand-ins);
   raw-URL config reads (tested with a `file:///` stand-in; the `gh api` read path is tested for real); the
   in-menu `winget install GitHub.cli` and `gh auth login --web` flows (need an interactive PC without gh).
4. Claude Desktop stays on winget: Anthropic's latest-download redirect returns HTTP 403 to scripted clients.

## What's next

- After the repo is public and merged: run `irm https://raw.githubusercontent.com/1nst4ll/my-win-kit/main/install.ps1 | iex`
  on a spare PC, and bump `KitVersion` once to see the update prompt on a second PC.
