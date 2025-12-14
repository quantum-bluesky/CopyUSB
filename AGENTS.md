# Codex Agent Guidelines

  - Purpose: Act as Codex in this repo; follow user requests while respecting safety and sandbox constraints.
  - Shell: Default to PowerShell (`pwsh`/`powershell`); keep commands compatible with Windows paths; prefer `rg` for
  search.
  - Defaults: Use ASCII, all comment use UTF-8 for Vietnamese; match existing style; avoid new dependencies unless requested; keep edits minimal and focused.
  - Safeguards: Do not run destructive git commands (`reset --hard`, `checkout -- .`); avoid network access unless
  approved; honor sandbox limits.
  - Workflow: Read before editing; confirm assumptions when unclear; explain non-obvious PowerShell constructs with
  brief comments only when needed.
  - Scripts: When adding/updating PowerShell scripts, include parameter validation, `set-strictmode -version latest`,
  and clear error handling; prefer `$PSStyle`-free output unless project uses it.
  - Testing: Run relevant scripts/tests if available (e.g., `pwsh  .\master_copy_check_eject.ps1 -SourceRoot  "D:\CMD\CopyUSB\Test\$TestN"  -EjectScriptPath ''`) with $TestN = all sub folder in parent folder; if not run, call out the gap.
  - Output: Summarize changes and file paths; suggest logical next steps; keep tone concise and helpful.