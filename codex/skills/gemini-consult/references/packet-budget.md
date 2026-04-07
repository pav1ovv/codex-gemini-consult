# Packet Budget

V3 packet budgeting prevents broad Gemini requests from being sent blindly.

## Inputs

- prompt length
- context file count
- total context characters
- largest context file size
- validation command count

## Decisions

- `allow`
  - packet is small enough for direct candidate generation
- `compact-first`
  - write a compact brief and reroute into `candidate-plan`
- `split-stage`
  - task is large enough that a staged path is required
- `block-until-narrowed`
  - packet is oversized and must be narrowed before any implementation pass

## Operational Rule

If the packet budget is anything other than `allow`, treat the run as staged:

- write packet artifacts
- write `scope-audit.md`
- write `compact-brief.md`
- record a reroute entry
- prefer `candidate-plan` before `candidate-package`

## Why It Matters

This is the fix for the common failure mode where Gemini receives too much context, drifts into a heavy agent session, and forces Codex to manually shrink the task afterward.
