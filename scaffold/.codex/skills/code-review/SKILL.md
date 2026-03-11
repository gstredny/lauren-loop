---
name: code-review
description: Run code review with findings-first, severity-ordered output focused on bugs, regressions, edge cases, error handling, performance, architecture, caller impact, and missing tests.
---

# Code Review

Use this skill when the user asks for a review or when a task reaches its review phase.

## Review Standard

- Read the task file first so the review is anchored to the goal, constraints, and Done Criteria.
- Read the diff and the full current contents of every changed file.
- Prioritize findings over summary. Lead with the most severe issues.
- Focus on correctness, behavioral regressions, missing tests, edge cases, error handling, security, performance, architecture, and caller impact.
- For tests, prefer observable behavior through public interfaces. Flag internal-collaborator mocks, helper-call assertions, DB-row checks, or storage internals when they are standing in for real behavior proof.
- If the change adds tests, check that at least one meaningful path keeps internal collaborators real and exercises the main entry point.

## Output Format

Use concrete findings in this form:

```text
[severity/category] path:line - issue
-> resolution
```

- Order findings by severity: `critical`, `major`, `minor`, `nit`.
- If there are no findings, say so explicitly and note any residual risk or verification gap.
- Do not dilute the review with style-only commentary when behavioral risk exists.

## Task-File Behavior

- For code-changing tasks, record the review result in the task file and set `## Code Review: completed` once findings are addressed.
- For documentation-only or equivalent low-risk tasks, use `## Code Review: not required` if review is explicitly waived.
- Do not close the task during review. Review feeds the verification and close-out phases.
