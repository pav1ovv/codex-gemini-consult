# Gemini Consult Modes

## Model Routing

- `ui-implement`
  - Preferred: `gemini-3.1-pro-preview`
  - Fallbacks: `gemini-3-pro-preview`, `gemini-2.5-pro`, `pro`
  - Why: strongest option in Gemini CLI docs/config for complex reasoning and agentic coding.
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

## Collaboration Contract

Every call should preserve this relationship:

- Codex owns local edits, tool use, integration, and verification.
- Gemini is the specialist consultant.
- For `ui-implement`, Gemini is the primary author of new UI/design code.
- The project root must always be passed explicitly.
- For long or extended tasks, prefer `stream-json` in headless mode so long-running executions can be handled safely.
- For `ui-implement`, `docs`, and `architecture`, generate a normalized brief first when the task is broad or carries meaningful context.
