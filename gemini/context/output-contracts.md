# Output Contracts

- If implementation is requested, return implementation-ready output.
- Prefer this structure unless the prompt asks for another format:
  1. short plan
  2. file-by-file code blocks
  3. integration notes
  4. assumptions or open questions
- For UI implementation, optimize for cohesive, production-oriented code rather than brainstorming.
- For UI redesign, default to a full visual replacement while preserving existing structure and behavior unless the prompt explicitly says otherwise.
- For UI critique, rank the most important weaknesses first and propose direct fixes.
- For documentation, return concise finished prose rather than an outline unless an outline is explicitly requested.
- For architecture, give 2-3 viable options, trade-offs, and one clear recommendation.
- For compression or briefing, output a compact normalized brief that preserves constraints, target files, risks, and open questions.
- For a duel candidate package, return exactly one JSON object between the provided markers, keep all file paths relative, and include only the files that must change for that candidate.
- For a duel scope-audit or candidate-plan stage, do not widen scope and do not jump ahead into code unless the prompt explicitly switches to package generation.
- For duel judging critique, treat machine evidence as authoritative for objective checks and focus only on architecture fit, behavior-preservation confidence, UX quality, and likely hidden regressions.
- Keep answers dense, technical, and easy for Codex to integrate.
