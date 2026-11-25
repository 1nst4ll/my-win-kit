# CLAUDE.md: my-win-kit

Personal Windows workstation kit. `install.cmd` → `install.ps1` (loader) → the modern menu
(`src/tui-spectre.ps1`, PowerShell 7.4+) or the classic menu (`src/tui-classic.ps1`, 5.1). Both call the engine
`src/core.psm1`, and the app list lives in `src/catalog.psd1`. `win11-tweaks.ps1` is the registry tweaks menu.
Front door: [README.md](README.md). Docs index and ownership map: [docs/architecture.md](docs/architecture.md#ownership-map).

## Session continuity: resume without a handover

- **Start every session by reading [docs/STATUS.md](docs/STATUS.md).** It is the living handover: what's live,
  what's next, current focus. Then check `git log`.
- **Update the record in the same commit as the work:**
  1. `docs/STATUS.md`: move finished items, set the next focus, and update any number that changed.
  2. `docs/CHANGELOG.md`: add a dated entry on top. Append-only.
  3. `docs/architecture.md` if behaviour or design changed.
- A commit that changes state but leaves STATUS stale is incomplete.
- **Suggest a fresh session at clean checkpoints.** That means work committed, STATUS current, nothing half-edited.
  Never mid-task. Suggest once and don't nag.

## Drift rules

1. **One owner per fact.** See the ownership map. Link to the owner, never copy. In particular, never copy the
   app list out of `src/catalog.psd1`. Link to it.
2. **Volatile numbers live only in STATUS:** app counts, dates, the last publish, open bugs, the next free Id.
3. **Reference docs use the present tense.** History goes in CHANGELOG (append-only, newest on top).
4. **Change the system → update the owning doc + a CHANGELOG entry, in the same commit.**

## Delivery: repo → OneDrive (one way)

- **Edit only in the repo, never the OneDrive copies** (`$env:OneDrive\[98] Shortcuts`). Every PC syncs that
  folder, so an edit there skips git and the tests.
- **Commits on `main` publish immediately** (`.githooks/post-commit` / `post-merge` → `tools/publish.ps1`).
  Do multi-step work on a branch and merge only when it's done and tested; a half-built kit on `main` reaches
  every PC.
- `publish.ps1` copies only the kit file set (`src/*`, `win11-tweaks.ps1`, `install.cmd`, then `install.ps1`
  last), skips unchanged and uncommitted files, and never deletes anything. It never touches the other files in
  that folder, including `winget-id-overrides.json`.
- **A fresh clone needs `git config core.hooksPath .githooks`.** Without it nothing publishes.
- Drift guard: if a target file differs from the repo copy and is newer, publish refuses (exit 2) and names the
  file. Bring that edit into the repo, or re-run with `-Force` to overwrite it. Never pass `-Force` without
  looking at the target file first.

## Constraints

- **The loader, engine and classic menu are Windows PowerShell 5.1 compatible** (`install.ps1`,
  `src/core.psm1`, `src/tui-classic.ps1`, `src/catalog.psd1`): no `??`, `?.`, ternary, `&&`; no modules beyond
  what ships with Windows. They must run on a fresh PC before anything is installed.
- `src/tui-spectre.ps1` needs PowerShell 7.4+ (PwshSpectreConsole 2.x requires it) but must still **parse**
  under 5.1, because CI parses every file under both editions. Avoid 7-only syntax there too.
- **Kit sources are ASCII-only.** Glyphs (√ ↑ × ● …) come from `[char]0x221A` etc., so no BOM is needed and 5.1
  never mis-decodes them.
- **Only glyphs present in both Consolas and Cascadia Mono.** Check a new one with WPF `GlyphTypeface`
  (`Add-Type -AssemblyName PresentationCore`, `.CharacterToGlyphMap.ContainsKey(0x....)` on
  `C:\Windows\Fonts\consola.ttf` and Windows Terminal's bundled `CascadiaMono.ttf`). No Nerd Font glyphs, no emoji.
  ✓ ✗ ↻ ★ ⚙ and Braille (Spectre's default `Dots` spinner) fail this check; use √ × ↔ and the `Point` spinner.
- **Colours are truecolor gruvbox hex** from `$script:Hex` (Spectre) / `$Pal` (classic). Badges mean the same
  thing everywhere (see architecture.md → Modern menu → Glyphs).
- **PowerShell variable names ignore case:** `$G` and `$g`, `$P` and `$p` are one variable. Never name a
  script-level table with a letter that a loop variable uses (this bit twice in the classic menu). `win11-tweaks.ps1` is the exception: it contains box-drawing characters and must keep
  its UTF-8 BOM. `install.ps1` carries a BOM from history; harmless, keep it. Check with `head -c3 file | xxd`.
- **Line endings are LF** (pinned in `.gitattributes`): publish hash-compares with the OneDrive copies.
- **No UI in `core.psm1`.** It returns result objects and reports progress through `-OnStatus`. Anything both
  menus need goes into core, so behaviour stays identical.
- **Remote scripts always run in a child process** (`Invoke-KitRemoteScript`). Never `iex` a vendor script
  inside the menu process: a vendor `exit` would close the menu.
- **Direct downloads must be signature-checked** (`Signer` in the catalogue's `Direct` entry) and resolved from
  the vendor's official page. Never hard-code a versioned URL.
- **Don't work around bot protection.** Claude Desktop's "latest" link returns 403 to scripts; it stays on winget.
- **POST is never armed by a bulk gesture.** `*` skips group `POST`; the Spectre picker only ticks POST through
  its own group header. POST runs last and is `Interactive`.
- **App `Id`s are permanent:** never renumber or reuse one. The next free Id is in STATUS.
- **Smoke tests must never install:** `-TestKeys` / `-TestInput` force dry run, and the dry-run toggle is locked
  on in test mode. Keep it that way when adding screens.
- **Never use Spectre prompts** (`SelectionPrompt`, `MultiSelectionPrompt`, `ConfirmationPrompt`, `Read-Spectre*`):
  they have no Esc/back. All input goes through `Show-Picker` / `Select-One` / `Select-Apps` in tui-spectre.ps1.
  Every screen except the main menu gets a pinned « Back row and Esc/Backspace/← = back; the main menu has q.
- **Every screen must fit 120 × 30 with its picker visible.** The picker sizes itself to what's left; tall tables
  must be trimmed (`Get-TrimmedRows`). `smoke-tui.ps1` fails any screen taller than 30 rows (`SCREEN-HEIGHTS`).
- **Console set-up order in tui-spectre.ps1:** UTF-8 output encoding *before* `Import-Module PwshSpectreConsole`,
  then the explicit TrueColor console. Don't let Spectre auto-detect: it disables colour on `NO_COLOR`, which
  dev/agent shells export to child windows. The kit's off switch is `MYWINKIT_NO_COLOR=1`.
- **The TestConsole does not prove real-console rendering** (no cursor moves, no encoding, no colour detection).
  After changing the picker or console set-up, check a real 120 × 30 conhost window too (launch
  `conhost.exe powershell.exe -File install.ps1 -DryRun`, drive it, screenshot). Any key-sending helper must find
  the kit window by title and abort if it can't; never send keys blind.
- **Prove which front-end ran from the run log** (`%LOCALAPPDATA%\my-win-kit\logs`), not from how the screen looks.
- `win11-tweaks.ps1` uses StrictMode + `Stop`. `core.psm1` uses `Set-StrictMode -Version 2.0`: read optional
  catalogue keys with the indexer (`$h['Key']`), not `$h.Key`, or StrictMode throws.

## Tests and lint (all dry run)

```powershell
pwsh -File tools/lint.ps1                                        # parse + PSScriptAnalyzer
powershell -File tools/lint.ps1 -ParseOnly                       # parse under Windows PowerShell 5.1
powershell -File tools/test-core.ps1                             # catalogue + engine (add -Online for scan + vendor pages)
pwsh -File tools/smoke-tui.ps1                                   # Spectre menu, scripted keys
powershell -ExecutionPolicy Bypass -File tools/smoke-loader.ps1  # loader decisions + classic menu
pwsh -File tools/render-screens.ps1 -OutDir <dir>                # capture every screen (.txt + truecolor .ans)
```

After any visual change, run `render-screens.ps1`: it prints the rows each screen used (budget 30).

CI (`.github/workflows/lint.yml`) runs all of them on `windows-latest`. Settings: `PSScriptAnalyzerSettings.psd1`
(Error + Warning). The rules it excludes are style choices this kit makes on purpose:

| Excluded rule | Why |
|---|---|
| PSAvoidUsingWriteHost | Interactive TUIs: coloured console output is the product. |
| PSAvoidUsingEmptyCatchBlock | Best-effort console/host calls (cursor, resize, encoding) that some hosts lack. |
| PSUseSingularNouns | Internal helpers, never exported to users. |
| PSUseApprovedVerbs | Internal helpers, never exported to users. |
| PSAvoidUsingInvokeExpression | Custom installers are the vendors' official `irm … \| iex` one-liners (run in a child process). |
| PSUseShouldProcessForStateChangingFunctions | Internal helpers; the kit's what-if is `-DryRun`. |

`$KnownIssues` in `tools/lint.ps1` turns specific known bugs into warnings. Remove an entry in the same commit
that fixes its bug. The list must only shrink (it is empty now).

Gotchas found while building: Spectre grids wrap even with `NoWrap`, so picker rows go through `Limit-Markup`;`
`continue` inside a PowerShell `switch` only leaves the switch; `-like` treats `[1/5]` as a wildcard class, so tests
use `.Contains()`.
