# Duel V3 Pipeline

`duel mode v3` is the staged workflow for risky tasks where one giant Gemini pass is too broad or too slow.

## Stages

1. `preflight`
   - validate project root
   - create or reuse duel ledger
   - prepare candidate workspaces
2. `scope-audit`
   - classify task shape
   - determine allowed and forbidden surfaces
   - choose a narrowed file set
3. `brief-compact`
   - write the compact brief Codex and Gemini should both anchor on
4. `candidate-plan`
   - write the narrow execution plan before asking Gemini for code
5. `candidate-package`
   - generate the Gemini candidate package
   - persist raw, normalized, package, and metadata artifacts
6. `machine-judge`
   - run validation, scope checks, blocked-environment checks, and diff scoring
7. `final-verdict`
   - produce `judge/verdict.md`
   - optionally create `merge-best-of-both`

## Core Artifacts

- `.codex/duels/<duel-id>/packet/objective.md`
- `.codex/duels/<duel-id>/packet/constraints.md`
- `.codex/duels/<duel-id>/packet/scope.json`
- `.codex/duels/<duel-id>/packet/context-summary.json`
- `.codex/duels/<duel-id>/scope-audit.md`
- `.codex/duels/<duel-id>/compact-brief.md`
- `.codex/duels/<duel-id>/reroute-log.json`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-raw.txt`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-normalized.txt`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-package.json`
- `.codex/duels/<duel-id>/gemini/attempt-<n>-metadata.json`

## Why This Exists

- oversized packets are blocked or rerouted before Gemini is asked to do heavy work
- Codex no longer has to manually shrink broad redesign prompts
- the terminal buffer is no longer the source of truth for Gemini output
- reroute reasons are recorded in the ledger instead of being implicit
