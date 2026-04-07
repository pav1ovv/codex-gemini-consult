---
name: gemini-consult
description: Use when Codex should delegate UI/design implementation to Gemini first, or when a strong second-model pass is useful for architecture trade-offs, naming, documentation drafting, structured critique, or prompt/context compression. Trigger for frontend appearance, layout, styling, component structure, interaction polish, docs-heavy writing, and high-value second-opinion work.
---

# Gemini Consult

## Overview

Use Gemini as a paired specialist, not as a random external chatbot. Codex stays responsible for context gathering, local edits, integration, and verification; Gemini is used as the primary author for new UI/design code and as a second brain for selected high-value tasks.

## Core Rules

- For UI, design, styling, layout, and interaction-polish tasks, consult Gemini before writing new UI code locally.
- Treat Gemini as the primary author for new UI/design code. Codex integrates the result, adapts it to the repo, and verifies it.
- Pass an explicit absolute working directory on every call. Never let Gemini infer the project root from the ambient shell state.
- Tell Gemini it is paired with Codex. Gemini produces the specialist output; Codex owns edits, tool use, and validation.
- When Gemini is unavailable, do not freehand new UI/design implementation unless the user explicitly overrides that rule.
- For non-UI work, use Gemini selectively when a second-model pass is likely to add signal: architecture options, concise critique, naming, docs-heavy writing, or context compression.

## Mode Routing

- `ui-implement`
  - Use for new components, page sections, responsive layouts, visual refactors, Tailwind/CSS styling, and interaction polish.
  - Gemini is the primary author here.
- `ui-redesign`
  - Use for a full visual redesign when the product structure must stay the same.
  - Preserve information architecture, route structure, and behavior.
  - Do not add new semantic sections or product scope unless explicitly requested.
- `ui-critique`
  - Use for comparing visual options, spotting weak hierarchy, identifying awkward spacing, and reviewing component UX.
- `docs`
  - Use for README sections, specs, usage guides, integration notes, migration docs, and other prose-heavy deliverables.
- `architecture`
  - Use for trade-off analysis, alternate designs, decomposition, naming, and second-opinion reasoning on non-trivial changes.
- `compress`
  - Use to condense long context into a tighter brief before a second Gemini pass or before handing context back into Codex.
- `general`
  - Use when you want a second brain but the task does not fit a narrower mode.
- `prepare-brief`
  - Use to normalize a large task into a compact brief before a later `ui-implement`, `docs`, or `architecture` pass.

See [modes.md](C:/Users/yehor/.codex/skills/gemini-consult/references/modes.md) for the model mapping and expected output shapes.

## Workflow

1. Gather only the minimum repo context Gemini needs: relevant paths, code snippets, constraints, and target outcome.
2. Call `C:\Users\yehor\.codex\bin\gemini-consult.ps1` with:
   - `-Mode <mode>`
   - `-ExpectedDuration <quick|normal|long|extended>`
   - `-WorkingDirectory <absolute project root>`
   - optional `-ContextPath <paths>` for files Gemini should read
   - optional `-NoAutoBrief` only when you explicitly do not want the built-in briefing pass
   - a prompt that asks for implementation-ready output
3. Review Gemini's output critically. Do not trust it blindly.
4. Apply the result locally, adapting only as much as needed for the repo.
5. Verify with lint, typecheck, tests, or targeted checks before claiming success.

## Command Patterns

Use PowerShell directly:

```powershell
C:\Users\yehor\.codex\bin\gemini-consult.ps1 `
  -Mode ui-implement `
  -ExpectedDuration normal `
  -WorkingDirectory C:\path\to\project `
  -ContextPath src\components\Card.tsx,src\app\page.tsx `
  -PromptText "Implement a stronger premium pricing section that fits the existing design system."
```

Pipe short prompts when that is simpler:

```powershell
"We need a cleaner dashboard filter bar. Keep the current data flow. Return implementation-ready TSX and Tailwind." | `
  C:\Users\yehor\.codex\bin\gemini-consult.ps1 `
  -Mode ui-implement `
  -ExpectedDuration normal `
  -WorkingDirectory C:\path\to\project
```

For large multiline prompts, prefer a prompt file over shell quoting:

```powershell
$promptFile = Join-Path $env:TEMP "gemini-ui-task.txt"
Set-Content -LiteralPath $promptFile -Encoding utf8 -Value @"
You are redesigning the shared shell.
Keep the route-workspace pattern.
Return implementation-ready TSX and Tailwind.
"@

C:\Users\yehor\.codex\bin\gemini-consult.ps1 `
  -Mode ui-redesign `
  -ExpectedDuration long `
  -WorkingDirectory C:\path\to\project `
  -ContextPath src\components\dashboard\FilterBar.tsx `
  -PromptFile $promptFile
```

Generate only a normalized brief:

```powershell
C:\Users\yehor\.codex\bin\gemini-consult.ps1 `
  -Mode prepare-brief `
  -ExpectedDuration quick `
  -WorkingDirectory C:\path\to\project `
  -ContextPath src\app\page.tsx,src\components\Shell.tsx `
  -PromptText "Prepare the implementation brief for a shared-shell redesign."
```

## Duration Policy

- `quick`
  - Short critique, tiny rewrite, one-shot clarification.
- `normal`
  - Default for most consultations.
- `long`
  - Use for broad UI implementation, meaningful documentation drafts, and substantial architecture requests.
- `extended`
  - Use for full redesign passes, integrated shared-shell work, or any task where Gemini should behave like a long-running peer agent.

When the task is `long` or `extended`, do not treat slow completion as failure by itself. Give Gemini a long external wait window.

For `ui-implement`, `docs`, and `architecture`, the launcher now auto-generates a normalized brief when the task is broad, long-running, or has explicit context files. Disable that only with `-NoAutoBrief`.

## Prompting Rules

- Ask for implementation-ready output, not brainstorming fluff.
- State whether you want a patch, file rewrite, or code blocks by file.
- Tell Gemini what must be preserved: design system, API contracts, component names, accessibility constraints, responsive behavior.
- When using `ui-implement`, explicitly ask for concrete code and short integration notes.
- When using `ui-redesign`, explicitly lock product structure if the redesign must stay one-to-one with the current screens.
- When using `docs`, ask for concise finished prose, not an outline unless you specifically want one.
- When using `prepare-brief`, ask only for the normalized brief and avoid code-generation requests in the same call.
- Do not build giant inline quoted shell strings for long prompts. Use `-PromptFile` for large multiline prompts and use short pipeline input only for short one-shot prompts.

## Output Expectations

- For `ui-implement`: prefer file-by-file code blocks plus a short change plan.
- For `ui-redesign`: prefer a full visual replacement with explicit preservation of structure and behavior.
- For `ui-critique`: prefer ranked findings and direct recommendations.
- For `docs`: prefer publishable prose with only minimal commentary.
- For `architecture`: prefer 2-3 options, trade-offs, and a clear recommendation.
- For `compress`: prefer a compact brief that preserves constraints and open questions.
- For `prepare-brief`: prefer a compact markdown brief that can be fed directly into a later implementation pass.

## Resources (optional)

This skill uses:

### scripts/
- The global launcher lives at [gemini-consult.ps1](C:/Users/yehor/.codex/bin/gemini-consult.ps1).
- The wrapper always injects the Codex/Gemini collaboration contract and the explicit working directory.

### references/
- [modes.md](C:/Users/yehor/.codex/skills/gemini-consult/references/modes.md) documents the mode-to-model routing and intended usage.
