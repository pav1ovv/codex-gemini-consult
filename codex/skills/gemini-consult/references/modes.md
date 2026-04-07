# Gemini Consult Modes

## Execution Modes

- `build`
  - Default for `ui-implement`, `ui-redesign`, and `docs`
  - Optimize for task completion, concrete artifacts, and easy Codex integration
  - Prefer one strong path over broad exploration
- `think`
  - Default for `architecture`, `compress`, `prepare-brief`, and `general`
  - Optimize for alternatives, trade-offs, risk framing, and a clear recommendation
  - Use when the real need is reasoning before implementation
- `critique`
  - Default for `ui-critique`
  - Optimize for review, weaknesses, regressions, and targeted improvements
  - Avoid greenfield rewrites unless the prompt explicitly asks for one

## Model Routing

- `ui-implement`
  - Preferred: `gemini-3.1-pro-preview`
  - Fallbacks: `gemini-3-pro-preview`, `gemini-2.5-pro`, `pro`
  - Why: strongest option in Gemini CLI docs/config for complex reasoning and agentic coding.
- `ui-redesign`
  - Preferred: `gemini-3.1-pro-preview`
  - Fallbacks: `gemini-3-pro-preview`, `gemini-2.5-pro`, `pro`
  - Why: full visual replacement with locked structure still needs the strongest coding and planning model.
- `ui-critique`
  - Preferred: `gemini-3-flash-preview`
  - Fallbacks: `gemini-2.5-flash`, `flash`, `gemini-2.5-pro`
  - Why: quick second-pass critique usually benefits more from speed than from maximum depth.
- `docs`
  - Preferred: `gemini-3.1-pro-preview`
  - Fallbacks: `gemini-3-pro-preview`, `gemini-2.5-pro`, `pro`
  - Why: documentation and spec drafting benefit from stronger reasoning and structured long-form output.
- `architecture`
  - Preferred: `gemini-3.1-pro-preview`
  - Fallbacks: `gemini-3-pro-preview`, `gemini-2.5-pro`, `pro`
  - Why: trade-off analysis and decomposition are high-value reasoning tasks.
- `compress`
  - Preferred: `gemini-3.1-flash-lite-preview`
  - Fallbacks: `gemini-2.5-flash-lite`, `flash-lite`, `gemini-2.5-flash`
  - Why: compression and briefing do not need the most expensive model.
- `prepare-brief`
  - Preferred: `gemini-3.1-flash-lite-preview`
  - Fallbacks: `gemini-3-flash-preview`, `gemini-2.5-flash-lite`, `flash-lite`, `gemini-2.5-flash`
  - Why: a fast normalized brief improves downstream passes without paying pro-model cost first.
- `general`
  - Preferred: `gemini-3-flash-preview`
  - Fallbacks: `gemini-2.5-flash`, `flash`, `gemini-2.5-pro`

## Output Shape

- `ui-implement`
  - Ask for: short plan, file-by-file code blocks, integration notes.
- `ui-redesign`
  - Ask for: file-by-file redesign code, explicit preservation of structure and behavior, and short integration notes.
- `ui-critique`
  - Ask for: ranked findings, direct fixes, optional rewritten snippets.
- `docs`
  - Ask for: finished prose unless an outline is explicitly requested.
- `architecture`
  - Ask for: 2-3 options, trade-offs, recommendation.
- `compress`
  - Ask for: a compact brief preserving constraints, assumptions, and open questions.
- `prepare-brief`
  - Ask for: compact markdown with goal, deliverable, constraints, relevant files, risks, and open questions.

## Duel Mode Relationship

`duel mode` is not another Gemini generation mode. It is a higher-level orchestration path that uses a shared brief and artifact ledger before candidate comparison.

Current status:

- use `gemini-duel.ps1 -PrepareCandidates` to create the shared brief, packet directory, scope audit, compact brief, and isolated candidate workspaces
- use `-RecordCodexCandidate` to snapshot the Codex candidate from its workspace
- use `-GenerateGeminiCandidate` to generate the Gemini candidate-plan and candidate package with persisted attempt artifacts
- use `-Judge` to produce `judge/scoreboard.json` and `judge/verification.log`
- use `-WriteVerdict` to produce `judge/verdict.md`
- use `-PrepareMergeWorkspace` when the final choice is `merge-best-of-both`

## Collaboration Contract

Every call should preserve this relationship:

- Codex owns local edits, tool use, integration, and verification.
- Gemini is the specialist consultant.
- For `ui-implement`, Gemini is the primary author of new UI/design code.
- For `ui-redesign`, Gemini must change the design comprehensively without widening product scope unless explicitly authorized.
- The project root must always be passed explicitly.
- For long or extended tasks, prefer `stream-json` in headless mode so long-running executions can be handled safely.
- For `ui-implement`, `docs`, and `architecture`, generate a normalized brief first when the task is broad or carries meaningful context.
