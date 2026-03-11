---
name: workflow
description: Follow the end-to-end delivery workflow for planning, task-file management, execution, code review, verification, and closeout without relying on Claude-specific hooks or command conventions.
---

# Workflow

Use this skill when a request needs the repo's end-to-end delivery workflow rather than ad hoc edits.

## Core Flow

1. Define goal, success criteria, tests, testability design, constraints, and whether the work is single-agent or team-safe.
2. Check `docs/tasks/open/` first. Resume an existing task or create a new one from `docs/tasks/TEMPLATE.md`.
3. Read code before editing. Reuse existing patterns and avoid speculative design.
4. Before coding, make the plan name the public interface under test, allowed external mocks, and the first RED test or `VERIFY` step for each behavior.
5. Execute in one-test, one-implementation vertical slices and append to `Attempts` after each meaningful change.
6. Keep tests focused on observable behavior through public interfaces. Mock only true out-of-process boundaries.
7. Run code review for code-changing work unless it was explicitly waived. Keep review findings severity-ordered and concrete.
8. Set status to `needs verification` when implementation is ready, then walk the Done Criteria with the user.
9. Only after user approval, append a retro entry to `docs/tasks/RETRO.md` and move the task to `docs/tasks/closed/`.

## Working Rules

- Default to single-agent. Use parallel teammates only when file ownership is clear and there is zero overlap.
- Split large work before execution if the plan naturally breaks into multiple independently verifiable phases.
- Do not write a batch of tests up front. Every testable behavior should map to one RED/GREEN slice.
- Prefer tests that prove user-visible outcomes, not helper internals, call counts, or storage state unless those are the contract.
- Treat `.claude/skills/` as source material only. Codex work should follow live repo behavior, not Claude-specific hand-off language.
- Keep retro guidance inline for this repo: use the existing `docs/tasks/RETRO.md` format instead of assuming a separate retro skill exists.
- If the request is specifically about pre-code test-slice design, use `tdd-planning` before starting implementation.
