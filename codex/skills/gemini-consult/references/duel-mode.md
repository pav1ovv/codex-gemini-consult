# Duel Mode

`duel mode` is the high-rigor path for tasks where comparing two solution strategies is worth the cost.

## When To Use

- architecture changes
- refactors with behavior preservation
- flaky bug fixes
- broad UI redesign
- other high-risk tasks where Codex and Gemini may fail differently

## Current Implementation State

The v3 workflow is live end-to-end:

- shared duel artifact root
- packet directory and packet budget decision
- scope audit and task-shape classification
- compact brief and reroute log
- resumable `resume.json` with reroute and packet-budget state
- candidate workspace preparation
- git worktree setup for git roots
- mirror-copy fallback for non-git roots
- Codex candidate recording
- Gemini candidate-plan plus candidate generation via mock package or live `gemini-consult`
- persisted Gemini attempt artifacts: raw, normalized, package, metadata
- machine scoreboard with validation hooks, forbidden-surface checks, blocked-environment detection, and rerouted-run markers
- final verdict writing
- `merge-best-of-both` preparation workspace

## Preparation Contract

Start by creating the duel ledger and isolated candidate workspaces:

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

Expected artifacts:

- `.codex/duels/<duel-id>/brief.md`
- `.codex/duels/<duel-id>/context-manifest.json`
- `.codex/duels/<duel-id>/constraints.json`
- `.codex/duels/<duel-id>/resume.json`
- `.codex/duels/<duel-id>/packet/*`
- `.codex/duels/<duel-id>/scope-audit.md`
- `.codex/duels/<duel-id>/compact-brief.md`
- `.codex/duels/<duel-id>/reroute-log.json`
- `.codex/duels/<duel-id>/codex/plan.md`
- `.codex/duels/<duel-id>/gemini/plan.md`
- candidate workspace roots recorded in `resume.json`
- `.codex/duels/<duel-id>/workspaces/codex`
- `.codex/duels/<duel-id>/workspaces/gemini`

## Candidate Recording

Codex candidate:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -RecordCodexCandidate
```

Gemini candidate:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -GeminiMode ui-redesign `
  -GeminiExpectedDuration long `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -GenerateGeminiCandidate
```

When local testing should not depend on live Gemini, use `-GeminiMockPackageFile <path>` instead.

## Machine Judge

Run the deterministic judge first:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -Judge
```

Outputs:

- `.codex/duels/<duel-id>/judge/scoreboard.json`
- `.codex/duels/<duel-id>/judge/verification.log`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-raw.txt`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-normalized.txt`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-package.json`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-metadata.json`

The scoreboard currently evaluates:

- validation command success/failure
- forbidden surface touches
- changed file count
- diff line count
- blocked-environment detection when validation is broken for both candidates in the same way
- rerouted-run and packet-budget state from the duel ledger

## Verdict Flow

Write the final verdict after the scoreboard exists:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -WriteVerdict
```

Override the default recommendation and prepare a merge workspace:

```powershell
C:\Users\<you>\.codex\bin\gemini-duel.ps1 `
  -WorkingDirectory C:\path\to\project `
  -DuelId shell-redesign `
  -PromptText "Prepare a duel run for a locked-scope shell redesign." `
  -WriteVerdict `
  -VerdictChoice merge-best-of-both `
  -PrepareMergeWorkspace
```

Outputs:

- `.codex/duels/<duel-id>/judge/verdict.md`
- `.codex/duels/<duel-id>/judge/merge-best-of-both/workspace`
- `.codex/duels/<duel-id>/judge/merge-best-of-both/merge-plan.md`

## Design Rules

- both candidates must use the same brief
- the project root must always be explicit
- locked scope must be recorded, not implied
- deterministic judging must come before subjective judging
- long Gemini candidate runs should use prompt files and the `long` or `extended` duration budget rather than giant inline shell strings
