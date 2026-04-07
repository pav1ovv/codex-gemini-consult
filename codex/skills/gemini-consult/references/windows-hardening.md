# Windows Hardening

This reference tracks Windows-specific reliability rules for `gemini-consult` and `duel mode`.

## Core Rules

- use explicit absolute paths
- prefer UTF-8 file-backed prompt transport for large prompts
- avoid giant quoted shell strings
- avoid `cmd /c type ... | ...` for prompt transport
- prefer project-local artifact roots over random temp folders
- separate idle timeout detection from hard process timeout
- track long-running processes explicitly so they can be cleaned up

## Predicted Failure Classes

- PowerShell quoting failures
- Unicode corruption across shells
- path issues with spaces or non-ASCII characters
- stale worktrees and file locks
- blocked stdout/stderr on long-running processes
- CRLF noise in diff-based judging

## Current Status

The current package hardens these Windows edges:

- non-git fallback no longer crashes on `git rev-parse` stderr handling
- git probing uses `System.Diagnostics.Process` instead of PowerShell-native error semantics
- relative-path generation works on older Windows PowerShell runtimes without `System.IO.Path.GetRelativePath`
- `ProcessStartInfo` argument construction is compatible with older runtimes that do not expose `ArgumentList`
- artifact and packet files are now written as UTF-8 without BOM to reduce Windows PowerShell and marker-parsing noise
- non-git diffing now filters `.codex` and `.git` relative to the candidate workspace root instead of accidentally excluding the entire workspace
- duel candidate generation records structured Gemini attempt logs under the artifact root
- duel candidate generation persists raw and normalized Gemini responses to artifacts before package parsing
- staged duel preparation writes packet files instead of relying on giant inline here-strings for broad tasks
- machine scoring distinguishes forbidden-surface failure from blocked-environment failure
