# Changelog

> Append-only. New entries on top. Don't edit old ones except to fix an error.

## 2026-11-24

- **Repo created:** github.com/1nst4ll/my-win-kit (private). The three scripts were imported byte-identical
  to the copies already in `OneDrive\[98] Shortcuts`. `.gitattributes` pins LF so checkouts never rewrite the
  bytes, and `.gitignore` excludes per-machine `winget-id-overrides.json`.
- **Docs system:** README, CLAUDE.md (continuity + drift rules + constraints), docs/STATUS.md,
  docs/CHANGELOG.md, docs/architecture.md (with the ownership map).
- **Lint CI:** `tools/lint.ps1` + `PSScriptAnalyzerSettings.psd1` + `.github/workflows/lint.yml`. Parse runs
  under 5.1 and pwsh, and PSScriptAnalyzer runs under pwsh. The first run found that win11-tweaks.ps1 fails to
  parse under 5.1 (missing BOM). It's tracked as a known issue in STATUS.
- **One-way publish to OneDrive:** `tools/publish.ps1` + `.githooks/post-commit` / `post-merge`. The
  drift-guard behaviour was tested against a scratch folder: copy, no-op, drift block (exit 2), `-Force`,
  repo-newer overwrite, skipping uncommitted files, and leaving other files alone.

## Before git (from file timestamps)

- **2026-07-07:** `install.ps1` / `install.cmd` last modified before the repo existed.
- **2026-04-14:** `win11-tweaks.ps1` v1.0 written.
