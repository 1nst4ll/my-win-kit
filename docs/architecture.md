# Architecture: how the kit works

> **Owns:** how the scripts, publish and CI work now (present tense). **Does not cover:** counts, dates or open
> bugs (→ [STATUS](STATUS.md)), history (→ [CHANGELOG](CHANGELOG.md)), usage (→ [README](../README.md)).

## Ownership map

| Doc / file | Single source of truth for… | Does **not** cover |
|---|---|---|
| [README.md](../README.md) | What the kit is, how to run it, how to add a package. | Internals, counts. |
| [CLAUDE.md](../CLAUDE.md) | Constraints, drift rules, continuity protocol, lint exclusions. | Current state. |
| [STATUS.md](STATUS.md) | Every volatile fact: counts, last publish, row budget, open bugs, next step. | How it works. |
| [CHANGELOG.md](CHANGELOG.md) | Dated history, append-only. | Current state. |
| architecture.md (this) | How the scripts, publish and CI work. | Counts, history. |
| `$pk` in [install.ps1](../install.ps1#L92) | The package catalogue (names, IDs, groups, defaults). | Never copy it into docs. |
| `$script:Fixes` in [win11-tweaks.ps1](../win11-tweaks.ps1#L87) | The tweak catalogue (registry keys, apply/check/revert). | |

## Repo layout and delivery

```
install.cmd  install.ps1  win11-tweaks.ps1   # the kit: published to OneDrive, run on PCs
tools/publish.ps1                            # repo → OneDrive copy (one way)
tools/lint.ps1  PSScriptAnalyzerSettings.psd1
.githooks/post-commit  post-merge  publish-on-main
.github/workflows/lint.yml                   # quality gate only
docs/
```

The kit files stay at the repo root. `install.cmd` launches `%~dpn0.ps1` (its own name with `.ps1`), so it must
sit beside `install.ps1`, and the published folder is flat.

| Channel | What | How | Trigger |
|---|---|---|---|
| OneDrive publish | the 3 kit files | `tools/publish.ps1` → `$env:OneDrive\[98] Shortcuts`, then OneDrive syncs every PC | git hook on commit/merge on `main` |
| CI | lint | GitHub Actions, `windows-latest` | push to `main`, PRs |
| GitHub | source of truth + backup | `git push` | by hand |

### publish.ps1

- Copies only `install.cmd`, `install.ps1` and `win11-tweaks.ps1`. It never deletes anything in the target or
  touches other files there. In particular it leaves `winget-id-overrides.json` alone: installs run from
  OneDrive write it there, and it syncs to every PC on purpose.
- It skips files with identical SHA-256 (computed through .NET, because `Get-FileHash` fails to load in 5.1
  when a git hook inherits a PowerShell 7 `PSModulePath`).
- It skips kit files with uncommitted changes, so only committed content ships.
- **Drift guard:** if a target file differs from the repo copy and its `LastWriteTime` is newer, it was edited on
  another PC. Publish doesn't overwrite it: it warns, names the file and exits 2. `-Force` overrides. The guard
  is time-based: if the repo file is edited again *after* the stray OneDrive edit, the repo copy is newer and
  wins without a warning.
- `Copy-Item` keeps the source timestamp, so after a publish both copies have the same `LastWriteTime`.
- Every path call uses `-LiteralPath`, because `[98]` contains wildcard characters.
- Exit codes: 0 = done, 1 = error, 2 = drift blocked.

The hooks are POSIX `sh` (Git for Windows). They run `publish-on-main`, which exits early off `main`, calls
`powershell.exe` (5.1, the same engine a fresh PC has), prints the result and always exits 0, so a publish
problem never blocks a commit. They are turned on per clone with `git config core.hooksPath .githooks`.

### lint.ps1 / CI

`tools/lint.ps1` is the single lint entry point. It runs a parser check on every `.ps1`, then
PSScriptAnalyzer (unless `-ParseOnly`). CI runs it twice. The 5.1 parse job matters because Windows PowerShell
5.1 decodes BOM-less files as ANSI. `$KnownIssues` downgrades listed findings to warnings
(`::warning` annotations in CI).

## install.ps1

Top to bottom:

1. **Bootstrap** (L12): forces TLS 1.2, unblocks itself (removes mark-of-the-web), and recreates `install.cmd`
   next to itself if it's missing.
2. **Layout + palette** (L33–90): fixed 120-column layout, 4 content columns at x = 6/34/62/90, Gruvbox-mapped
   console colours, and one colour per group header.
3. **Catalogue** (`$pk`, L92): `[pscustomobject]` rows `Id, On, N, W, S, G`. `$grpOrder` sets the group order
   and install order. `$gk` maps hotkey letters to groups, and `$gl` holds the group labels. A snapshot of the
   defaults backs the `Z` key.
4. **ID overrides** (L187–222): loads `winget-id-overrides.json` from beside the script (or `%LOCALAPPDATA%` when
   there's no script path). It follows old→new chains up to 5 hops. A value with the `msstore:` prefix switches
   the source.
5. **Buffered rendering** (L224–292): when the host supports VT, `X`/`XNL`/`Pad`/`Bar` append ANSI-coloured text
   to a StringBuilder, and each frame goes out in one `[Console]::Write`. Without VT (e.g. ISE) they fall back
   to per-call `Write-Host`. `$script:col` tracks the cursor column for padding.
6. **Masonry menu** (`Build-Masonry`, L322): DEV is pinned as the column-4 sidebar. The other app groups pack
   into columns 1–3 by height (first-fit-decreasing), and POST drops into the shortest of those columns. The
   result is computed once. `Show-Menu` repaints in place (cursor home) and does a full clear only on first
   paint, after sub-screens, or after a window resize.
7. **Input grammar** (main loop, L1035): the standalone commands are `I`, `Q`, `N` and `Z`. Everything else is
   tokens split on spaces or commas: a number toggles, `a-b` toggles a range, a group letter toggles the group
   (all on if any is off), `*` turns everything on except POST, and `0` turns everything off. Unknown tokens
   are flashed as "Ignored".
8. **Install pipeline** (`Run-Install`, L896): sorts the selection by group order then Id, starts a transcript
   in `%TEMP%`, and runs `winget source update`. It snapshots desktop `.lnk` files, runs `Inst` for each package
   (POST always last, under a banner), deletes new shortcuts if `N` = DELETE, and prints a summary. Packages
   that succeed are deselected, and failures stay selected so `I` retries them.
9. **Per package** (`Inst`, L692): winget installs run in a background job behind a spinner
   (`Invoke-JobSpinner`). `Get-PkgInfo` reads the installed version before and after, so the result shows
   INSTALLED, UPDATED vX → vY, or up to date.
10. **Self-healing:**
    - **ID vanished** (exit `0x8A150014`): `Find-ReplacementId` searches winget and scores the candidates
      (prefix or version split +6, same tail segment +4, exact name +3, pre-release −3). A score of 3 or more
      wins, then it retries.
    - **Download dead** (404 or hash mismatch, nothing installed yet): it tries the two previous versions, then
      the Microsoft Store channel.
    - Heals are saved with `Save-IdOverride`.
11. **Custom installers** (`switch ($P.Id)`, L707): official `irm … | iex` installers via `RunCustom`, an npm
    global install (needs Node), a check that Git is present first, and the RDP host enable. The RDP step writes
    a temp script and runs it elevated (UAC prompt if needed): registry, NLA and firewall group. If Tailscale is
    installed it prints the Tailscale IP.
12. **Guards** (L997–1033): no winget → it opens the App Installer Store page and exits. It tries to grow the
    console to the layout size and warns if the host refuses.

## win11-tweaks.ps1

- StrictMode + `$ErrorActionPreference = 'Stop'`, 76-column layout, its own palette.
- `$script:Fixes` (L87) is a list of hashtables `Id, Name, Description, Scope (HKCU|HKLM), Reboot, Apply,
  Check, Revert`. Adding a tweak means adding an entry. Note that the menu's `'1','2','3','4'` switch case is
  hard-coded.
- `Show-Menu` runs each fix's `Check` live to show ON/OFF. `Invoke-Toggle` runs `Apply` or `Revert`, and
  refuses HKLM fixes when not elevated.
- `A`/`R` turn everything on or off. `Q` offers a reboot if any toggled fix has `Reboot = $true`.
