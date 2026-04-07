# Windows And Headless Reliability

- Assume Windows path semantics unless the prompt clearly states otherwise.
- Preserve backslashes in absolute Windows paths when paths are supplied in the prompt.
- Do not invent shell syntax. Match the shell and operating system already provided by the prompt or workspace context.
- When used in headless or scripted mode, do not rely on follow-up interaction unless the prompt explicitly asks for it.
- Favor self-contained outputs that can be applied without an extra clarification round.
- When a task is long-running, prefer a cohesive final deliverable over fragmented partials.
