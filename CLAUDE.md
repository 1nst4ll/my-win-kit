# CLAUDE.md: my-win-kit

Personal Windows workstation kit: `install.ps1` (winget installer menu), `install.cmd` (its launcher) and
`win11-tweaks.ps1` (registry tweaks menu). Front door: [README.md](README.md). Docs index and ownership map:
[docs/architecture.md](docs/architecture.md#ownership-map).

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
   package list out of `$pk` in install.ps1. Link to it.
2. **Volatile numbers live only in STATUS:** package counts, dates, the last publish, open bugs.
3. **Reference docs use the present tense.** History goes in CHANGELOG (append-only, newest on top).
4. **Change the system → update the owning doc + a CHANGELOG entry, in the same commit.**

## Delivery: repo → OneDrive (one way)

- **Edit only in the repo, never the OneDrive copies** (`$env:OneDrive\[98] Shortcuts`). Every PC syncs that
  folder, so an edit there skips git and the lint gate.
- `tools/publish.ps1` runs automatically from `.githooks/post-commit` and `post-merge` on `main`. It copies only
  the 3 kit scripts, skips unchanged and uncommitted files, and never deletes anything. It never touches the other
  files in that folder, including `winget-id-overrides.json`.
- **A fresh clone needs `git config core.hooksPath .githooks`.** Without it nothing publishes.
- Drift guard: if a target file differs from the repo copy and is newer, publish refuses (exit 2) and names the
  file. Bring that edit into the repo, or re-run with `-Force` to overwrite it. Never pass `-Force` without
  looking at the target file first.

## Constraints

- **Windows PowerShell 5.1 compatible, stock fresh Windows.** No PS7-only syntax (`??`, `?.`, ternary, `&&`), and
  no modules beyond what ships with Windows. The scripts must run before anything else is installed.
- **Keep the bytes exact.** Files are LF (pinned in `.gitattributes`). `install.ps1` has a UTF-8 BOM, and 5.1
  needs it for the box-drawing characters. Any `.ps1` with non-ASCII characters must have a BOM. New tooling
  scripts stay ASCII-only. When editing, preserve the BOM. Check with `head -c3 file | xxd`.
- **install.ps1 layout budget: 120 columns × 30 rows** (Windows Terminal default). Menu height = 10 chrome rows +
  the tallest masonry column. The DEV column (sidebar) is the tallest. Adding a package to a full column
  pushes the menu past 30 rows. Check the budget in STATUS before adding.
- **POST-INSTALL is never armed by a bulk gesture.** `*` skips group `POST`. It always runs last and must
  stay opt-in only.
- **Package `Id`s are permanent:** never renumber or reuse one. The next free Id is in STATUS.
- `install.ps1` sets `$ErrorActionPreference = 'SilentlyContinue'` on purpose (best-effort installer).
  `win11-tweaks.ps1` uses StrictMode + `Stop`.

## Lint

```powershell
pwsh -File tools/lint.ps1                         # parse + PSScriptAnalyzer
powershell -File tools/lint.ps1 -ParseOnly        # parse under Windows PowerShell 5.1
```

CI (`.github/workflows/lint.yml`) runs both on `windows-latest`. Settings: `PSScriptAnalyzerSettings.psd1`
(Error + Warning). The rules it excludes are style choices this kit makes on purpose:

| Excluded rule | Why |
|---|---|
| PSAvoidUsingWriteHost | Interactive TUIs: coloured console output is the product. |
| PSAvoidUsingEmptyCatchBlock | Best-effort console/host calls (cursor, resize, encoding) that some hosts lack. |
| PSUseSingularNouns | Internal helpers (`Get-WingetRows`, `Get-PkgVersions`), never exported. |
| PSUseApprovedVerbs | `Run-Install`: internal helper, never exported. |
| PSAvoidUsingInvokeExpression | Custom installers run the vendors' official `irm … \| iex` one-liners. |

`$KnownIssues` in `tools/lint.ps1` turns specific known bugs into warnings. Remove an entry in the same commit
that fixes its bug. The list must only shrink.
