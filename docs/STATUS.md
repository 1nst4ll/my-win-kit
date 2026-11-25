# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-25._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- **Branch `rebuild-tui` is awaiting Daniel's review and merge** (PR into `main`). It replaces the single-file
  installer with a loader + Spectre menu + classic fallback + shared engine, and adds always-latest AI tools.
  **Do not merge without Daniel's go:** merging publishes the new kit to every PC through OneDrive.
- Before merging, Daniel tries it by hand (steps in the PR description): the modern menu, the classic menu
  (`install.ps1 -Classic`), and one real install or update. Feedback so far: colour/ASCII art (v2.1.0 visual pass) and no way back + "looks like plain
  PowerShell" (universal back picker, UTF-8/truecolor console fix, run log). Then Manage packages was added (his request). Next: his look in a real terminal.
  If it still looks plain, read the newest `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` first.
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
| Next free app Id | 59 in the base catalogue; the menu takes max(all Ids ever used) + 1 automatically (overlay `lastId`, `RetiredIds`) |
| Package-list overlay | `my-packages.json` next to install.ps1 (OneDrive). None exists yet on this PC; fold changes into the repo with `tools/import-overlay.ps1` |
| Kit version (branch) | 2.2.0 (`$script:KitVersion` in src/core.psm1) |
| Modern menu needs | PowerShell 7.4+, PwshSpectreConsole ≥ 2.3 (tested with 2.6.3 on pwsh 7.7.0) |
| Startup (this PC) | ~750 ms launch → banner → quit |
| Screen heights (120 × 30) | main 17, start 14, app picker 29, review ≤ 29, results ≤ 28, AI 22, tweaks ≤ 27, settings 12, classic 26 |
| Run logs | `%LOCALAPPDATA%\my-win-kit\logs\run-*.log` (newest 30 kept) |
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
