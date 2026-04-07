<!-- gemini-consult:start -->
## Gemini Consult Rules

- Global launcher: `C:\Users\%USERNAME%\.codex\bin\gemini-consult.ps1`
- Global skill: `gemini-consult`
- Gemini CLI on PATH: `gemini`
- Gemini global context file: `%USERPROFILE%\.gemini\GEMINI.md`
- Gemini global commands directory: `%USERPROFILE%\.gemini\commands`

Use `gemini-consult` when:
- implementing or revising UI, design, layout, styling, component appearance, or interaction polish
- doing a full visual redesign while preserving the existing product structure
- comparing visual options or critiquing UI quality
- drafting substantial documentation, specs, usage guides, or other prose-heavy deliverables
- seeking a second opinion on architecture, decomposition, naming, or non-trivial trade-offs
- compressing long context into a tighter brief for later execution

Rules:
- For UI/design implementation tasks, Gemini is the primary author of new UI code.
- Codex gathers repo context, calls Gemini, integrates the output locally, and verifies the result.
- Always pass an explicit absolute working directory to Gemini.
- Always tell Gemini it is paired with Codex.
- Prefer `ui-implement`, `ui-critique`, `docs`, `architecture`, `compress`, and `prepare-brief` as the standard routing modes.
- Use `ui-redesign` when the design must change fully but information architecture and functional scope must remain one-to-one.
- For `ui-implement`, `docs`, and `architecture`, auto-briefing is the default for broad or long-running tasks.
- For long or extended headless tasks, prefer `stream-json`.
- If Gemini is unavailable during a UI/design implementation task, stop and report that the UI-primary-author path is blocked unless the user explicitly authorizes local fallback.
<!-- gemini-consult:end -->
