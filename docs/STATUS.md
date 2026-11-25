# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-25._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Branch `rebuild-tui` is awaiting Daniel's review and merge** (PR into `main`). It replaces the single-file
  installer with a loader + Spectre menu + classic fallback + shared engine, and adds always-latest AI tools.
  **Do not merge without Daniel's go:** merging publishes the new kit to every PC through OneDrive.
- Before merging, Daniel tries it by hand (steps in the PR description): the modern menu, the classic menu
  (`install.ps1 -Classic`), and one real install or update. His first dry-run feedback (more colour, ASCII art,
  modern UI) is addressed in the v2.1.0 visual pass; next is his look at it in a real terminal.
- After the merge: check the post-merge publish output (expect `src/` + 4 files copied), then open
  `OneDrive\[98] Shortcuts\install.cmd` on a second PC.
- Watch-outs: `main` auto-publishes. This clone has `core.hooksPath=.githooks`; other clones need it too.

## What's live

| Fact | Value |
|---|---|
| Repo | github.com/1nst4ll/my-win-kit (private). `main` = old single-file installer; `rebuild-tui` = the rebuild |
| Publish target | `$env:OneDrive\[98] Shortcuts` |
| Last publish | 2026-11-24: nothing changed (old 3-file kit). The rebuild is not published yet |
| Apps in `src/catalog.psd1` (branch) | 58 total: 35 in the recommended set, 20 DEV (off), 3 POST (off) |
| By method (branch) | 45 winget, 4 Store, 5 script, 2 direct, 1 npm, 1 builtin. AI-flagged (Update AI tools): 5 |
| Next free app Id | 59 |
| Kit version (branch) | 2.1.0 (`$script:KitVersion` in src/core.psm1) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0) |
| Startup (this PC) | ~750 ms launch → banner → quit; main menu 16 rows, classic menu 26 rows (budget 30) |
| Latest direct versions seen | Antigravity IDE 2.8.0, Antigravity 2.35.1 (2026-11-25, from antigravity.google/download) |
| CI | lint.yml: ps51 job (parse, test-core, smoke-loader) + pwsh job (lint, test-core -Online, smoke-tui) |

## Open items (priority order)

1. **Merge `rebuild-tui`** after Daniel's manual check.
2. **Untested for real (needs a person or a spare PC):** an actual install through each method (winget,
   Store, script, direct, npm, RDP builtin); PowerShell 7 install from the loader on a PC without it (winget and
   MSI paths); first-run PwshSpectreConsole install on a PC without it; the elevated tweaks window; whether
   Antigravity's Inno installer launches the app after `/VERYSILENT` (the engine waits only for the installer
   process, so it shouldn't hang).
3. Claude Desktop stays on winget: Anthropic's latest-download redirect returns HTTP 403 to scripted clients.
   Revisit if Anthropic publishes a scriptable endpoint.

## What's next

- Optional: pin package IDs that self-healing changed on other PCs. Check `winget-id-overrides.json` in the
  OneDrive folder and fold the entries into `src/catalog.psd1`.
