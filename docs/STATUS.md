# Status: where the kit is

> **Owns:** every volatile fact (counts, dates, last publish, open bugs, what's next). Other docs link here.
> _Last updated: 2026-11-24._

## ▶ Resume here (current focus)

_A new session can start from this line, no handover needed._

- Done: the repo is set up with docs, lint CI and the OneDrive auto-publish hook (see CHANGELOG 2026-11-24).
  Nothing is uncommitted.
- Next concrete step: fix the win11-tweaks.ps1 encoding (open item 1). Then remove its two entries from
  `$KnownIssues` in `tools/lint.ps1`.
- Watch-outs: the install.ps1 menu is at its 30-row limit (see below). This clone has
  `core.hooksPath=.githooks` set. Other clones need it too.

## What's live

| Fact | Value |
|---|---|
| Repo | github.com/1nst4ll/my-win-kit (private), branch `main` |
| Publish target | `$env:OneDrive\[98] Shortcuts` |
| Last publish | 2026-11-24: nothing changed, all 3 files already identical to the repo |
| Packages in `$pk` | 57 total: 35 on by default, 19 DEV (off), 3 POST (off) |
| By source | 46 winget, 4 msstore, 7 custom |
| Next free package Id | 58 |
| Menu height | 30 / 30 rows (DEV column: 19 items + header = 20, plus 10 chrome). **Full.** |
| install.ps1 last changed (pre-git) | 2026-07-07 (file timestamp) |
| win11-tweaks.ps1 last changed (pre-git) | 2026-04-14, v1.0 |
| CI | lint.yml: parse (5.1) + parse/PSScriptAnalyzer (pwsh) |

## Open items (priority order)

1. **win11-tweaks.ps1 fails to parse under Windows PowerShell 5.1.** It has no UTF-8 BOM but contains
   non-ASCII characters (─ ● ○ ✗ ◌ ⚠), so 5.1 reads it as ANSI. First error is at line 365. It works under
   `pwsh` only, despite `#Requires -Version 5.1`. Fix: re-save with a UTF-8 BOM. CI reports it as a known-issue
   warning.
2. **Menu is at the row limit.** Before adding a DEV package, rebalance groups or move one out of DEV.
3. Stale comments in install.ps1. Line 36 says 19 masonry rows (actually 20). Lines 316–318 describe a
   3-column layout (it's 4). Line 1012 says 8 chrome rows (the code adds 10).

## What's next

- Optional: pin a few package IDs that self-healing changed on other PCs. Check each PC's
  `winget-id-overrides.json` in the OneDrive folder and fold the entries into `$pk`.
