# Codex Gemini Consult

`gemini-consult` is a Windows-first Codex skill pack that turns Gemini CLI into a paired specialist for Codex.

It gives Codex:

- a global `gemini-consult` skill
- a global `gemini-duel` launcher for high-risk compare-two-solutions workflows
- staged duel v3 packetization, scope-audit, reroute, and response artifact capture
- a Windows-safe launcher for Gemini headless usage
- long-running `stream-json` handling
- auto-brief generation before broad UI, docs, or architecture tasks
- global Gemini context files
- global Gemini custom commands

The main goal is simple:

- Gemini becomes the primary author for new UI and design code
- Codex stays responsible for repo context, local edits, integration, and verification

## What gets installed

Into `%USERPROFILE%\\.codex`:

- `bin\\gemini-consult.ps1`
- `bin\\gemini-consult.cmd`
- `bin\\gemini-duel.ps1`
- `bin\\gemini-duel.cmd`
- `skills\\gemini-consult\\`

Into `%USERPROFILE%\\.gemini`:

- `GEMINI.md`
- `context\\*.md`
- `commands\\codex\\*.toml`

Optionally into `%USERPROFILE%\\.codex\\AGENTS.md`:

- a `Gemini Consult Rules` snippet so Codex knows when to route work to Gemini

## Requirements

- Windows
- [Node.js LTS](https://nodejs.org/)
- npm on `PATH`
- Codex installed and using `%USERPROFILE%\\.codex`

## Install Gemini CLI

Install Gemini CLI globally:

```powershell
npm install -g @google/gemini-cli@latest
```

Check it:

```powershell
gemini --help
```

Authenticate:

```powershell
gemini
```

Then choose the sign-in flow you want.

## Install This Skill Pack

### Quick install

From the cloned repo root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -InstallGeminiCli -AppendAgents
```

If Gemini CLI is already installed:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -AppendAgents
```

### What the installer does

- copies the launcher into `%USERPROFILE%\\.codex\\bin`
- copies the skill into `%USERPROFILE%\\.codex\\skills\\gemini-consult`
- copies global Gemini context and custom commands into `%USERPROFILE%\\.gemini`
- merges `%USERPROFILE%\\.gemini\\settings.json` so `AGENTS.md` and `GEMINI.md` are both valid context filenames
- optionally appends the Codex AGENTS snippet if it is not already present

## Manual install

If you do not want the installer:

1. Copy `codex\\bin\\gemini-consult.ps1` to `%USERPROFILE%\\.codex\\bin\\gemini-consult.ps1`
2. Copy `codex\\bin\\gemini-consult.cmd` to `%USERPROFILE%\\.codex\\bin\\gemini-consult.cmd`
3. Copy `codex\\skills\\gemini-consult` to `%USERPROFILE%\\.codex\\skills\\gemini-consult`
4. Copy `gemini\\GEMINI.md` to `%USERPROFILE%\\.gemini\\GEMINI.md`
5. Copy `gemini\\context\\*` to `%USERPROFILE%\\.gemini\\context\\`
6. Copy `gemini\\commands\\codex\\*` to `%USERPROFILE%\\.gemini\\commands\\codex\\`
7. Merge `AGENTS.md` and `GEMINI.md` into `%USERPROFILE%\\.gemini\\settings.json` under `context.fileName`
8. Append `codex\\AGENTS.gemini-consult-snippet.md` to `%USERPROFILE%\\.codex\\AGENTS.md`

## Usage

### Through Codex

Just ask normally:

- `используй gemini для UI`
- `пусть gemini напишет интерфейс`
- `сначала прогони через gemini как second brain`
- `используй gemini для документации`

### Direct launcher

```powershell
C:\Users\<you>\.codex\bin\gemini-consult.ps1 `
  -Mode ui-implement `
  -ExpectedDuration long `
  -WorkingDirectory C:\path\to\project `
  -ContextPath src\app\page.tsx,src\components\Shell.tsx `
  -PromptText "Implement the new dashboard shell."
```

### Gemini custom commands

These become global commands in Gemini CLI:

- `/codex:ui-implement`
- `/codex:ui-redesign`
- `/codex:ui-critique`
- `/codex:docs-draft`
- `/codex:arch-review`
- `/codex:brief`

Example:

```powershell
gemini -p "/codex:brief Goal: redesign the shared shell. Deliverable: normalized brief only."
```

For a locked-scope redesign:

```powershell
gemini -p "/codex:ui-redesign Replace the visual design completely, but preserve the existing screen structure and behavior one-to-one."
```

### Duel mode

Use the duel launcher when you want a full Codex-vs-Gemini comparison with isolated workspaces, machine scoring, and a verdict artifact:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -LockedScope `
  -ContextPath src\app\page.tsx,src\components\Shell.tsx `
  -ValidationCommand "npm run lint","npm run test" `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -PrepareCandidates
```

Then:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -RecordCodexCandidate

C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -GeminiMode ui-redesign `
  -GeminiExpectedDuration long `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -GenerateGeminiCandidate

C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -Judge

C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -WriteVerdict
```

This v3 implementation creates:

- `.codex/duels/<duel-id>/brief.md`
- `.codex/duels/<duel-id>/context-manifest.json`
- `.codex/duels/<duel-id>/constraints.json`
- `.codex/duels/<duel-id>/resume.json`
- `.codex/duels/<duel-id>/packet/*`
- `.codex/duels/<duel-id>/scope-audit.md`
- `.codex/duels/<duel-id>/compact-brief.md`
- `.codex/duels/<duel-id>/reroute-log.json`
- candidate artifacts under `codex/` and `gemini/`
- Gemini attempt artifacts under `gemini/attempt-<n>-{raw,normalized,package,metadata}.*`
- candidate workspaces using git worktrees for git roots
- mirror-copy fallback workspaces for non-git roots
- `.codex/duels/<duel-id>/judge/scoreboard.json`
- `.codex/duels/<duel-id>/judge/verification.log`
- `.codex/duels/<duel-id>/judge/verdict.md`
- `.codex/duels/<duel-id>/judge/merge-best-of-both/*` when requested

## Windows notes

- The launcher is designed for Windows PowerShell / `pwsh`
- long-running mode uses `stream-json`
- broad staged duel runs switch to packet files instead of giant inline prompt strings
- response capture no longer depends on the terminal buffer alone
- stderr is handled without PowerShell background runspace callbacks, which avoids the common Windows crash path for event-based handlers
- non-git roots are supported with mirror-copy candidate workspaces
- old Windows PowerShell compatibility is handled for `ProcessStartInfo` arguments and relative-path generation

## Restart

After installation, restart Codex so it reloads global skills and AGENTS context.

## Repository layout

```text
codex/
  AGENTS.gemini-consult-snippet.md
  bin/
  skills/gemini-consult/
gemini/
  GEMINI.md
  context/
  commands/codex/
scripts/
  install.ps1
```
