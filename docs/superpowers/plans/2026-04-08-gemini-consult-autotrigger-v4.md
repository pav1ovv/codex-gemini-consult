# Gemini Consult Automation V4 Plan

## Goal

Strengthen `gemini-consult` so Codex triggers Gemini more proactively, auto-discovers relevant context, supports one-shot duel execution, captures structured Gemini output, and installs a safe post-commit critique workflow.

## Non-Goals

- Do not remove or rename existing public flags.
- Do not make Gemini mandatory for non-UI work.
- Do not add non-Windows-only behavior.

## Architecture Approach

1. Keep `gemini-consult.ps1` backward compatible, but add:
   - mode and execution auto-detection
   - automatic context discovery when `-ContextPath` is omitted
   - large timeout defaults with explicit override
   - structured response instructions and artifact parsing
2. Keep `gemini-duel.ps1` backward compatible, but add:
   - automatic context discovery when `-ContextPath` is omitted
   - `-AutoRun` to execute the full staged duel pipeline in one call
   - large timeout forwarding to Gemini candidate generation
3. Add repo scripts:
   - `scripts/get-context.ps1`
   - `scripts/install-hooks.ps1`
   - `scripts/post-commit-critique.ps1`
4. Update Gemini prompt surfaces:
   - launcher prompt contract
   - Gemini command TOMLs
   - output contract docs
5. Update Codex trigger guidance:
   - `codex/AGENTS.gemini-consult-snippet.md`
   - `README.md`

## Target Files

- `codex/bin/gemini-consult.ps1`
- `codex/bin/gemini-duel.ps1`
- `codex/AGENTS.gemini-consult-snippet.md`
- `codex/skills/gemini-consult/SKILL.md`
- `codex/skills/gemini-consult/references/modes.md`
- `gemini/GEMINI.md`
- `gemini/context/output-contracts.md`
- `gemini/commands/codex/*.toml`
- `scripts/install.ps1`
- `scripts/get-context.ps1`
- `scripts/install-hooks.ps1`
- `scripts/post-commit-critique.ps1`
- `README.md`
- tests under `scripts/`

## Milestones

### Milestone 1

- Add durable context discovery script and launcher integration.
- Add `-TimeoutSeconds` to `gemini-consult.ps1`.
- Add `Get-GeminiMode` inference logic.

Validation:

- parser for `gemini-consult.ps1`
- parser for `scripts/get-context.ps1`
- local smoke for auto-context with a temp git repo

### Milestone 2

- Add structured output instructions to launcher prompt contract and Gemini command TOMLs.
- Parse `DECISION`, `IMPLEMENTATION_PLAN`, `RISKS`, `FILES_TO_TOUCH` into separate artifacts.
- Add `docs-draft` and `critique` aliases without breaking existing routes.

Validation:

- prompt artifact contains the structured-output contract
- structured sections artifact is created for a mock response

### Milestone 3

- Add `-AutoRun` and `-TimeoutSeconds` to `gemini-duel.ps1`.
- Execute `PrepareCandidates -> RecordCodexCandidate -> GenerateGeminiCandidate -> Judge -> WriteVerdict` with stage progress and fail-fast stage errors.
- Integrate auto-context when explicit `-ContextPath` is absent.

Validation:

- parser for `gemini-duel.ps1`
- mock-package autorun smoke
- verdict path output present

### Milestone 4

- Add repo-local post-commit auto-critique installer and helper.
- Hook writes `.codex/reviews/<short-hash>.md` and never blocks commit on failure.
- Update installer and docs.

Validation:

- parser for hook scripts
- install hook into temp git repo
- verify hook file content and non-blocking helper behavior

## Risks

- prompt-contract changes must not break duel package JSON extraction
- auto-context import resolution must stay conservative and quiet on failure
- `-AutoRun` must preserve existing one-stage duel usage
- hook logic must tolerate missing Gemini auth/quota without noisy failures

## Explicit Next Actions

1. Implement `scripts/get-context.ps1` and wire it into both launchers.
2. Extend `gemini-consult.ps1` for inference, timeouts, aliases, and structured artifacts.
3. Extend `gemini-duel.ps1` for `-AutoRun`.
4. Add hook installer and helper scripts.
5. Update snippet, skill docs, Gemini command TOMLs, and README.
6. Run local parser and smoke verification before any install or push.
