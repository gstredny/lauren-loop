---
name: plan-review
description: Review an implementation plan before execution to catch missed success criteria, scope creep, constraint violations, unverified assumptions, and missed reuse opportunities.
---

# Plan Review

Use this skill after a plan exists and before code is written.

## Checklist

1. Does the plan cover every success criterion from the task file?
2. Does the plan respect repo-level constraints from project rules and task-specific rules?
3. Is there a simpler approach that reaches the same outcome with fewer new abstractions or files?
4. Are all important assumptions verified by reading code, configs, or docs already in the repo?
5. Does the plan stay within the intended scope and file set?
6. Does it reuse existing helpers, services, tests, and patterns instead of duplicating them?
7. Does the plan name the public interface under test for each behavior?
8. Does it allow mocks only at true external boundaries and keep internal collaborators real?
9. Does it sequence the work as one-test, one-implementation vertical slices instead of bulk upfront test writing?
10. Are non-testable steps explicitly marked as verification-only work instead of forced into fake TDD?

## Decision Rules

- If items 1, 2, 4, 7, or 8 fail, stop and resolve the gap before execution.
- If items 3, 5, 6, 9, or 10 fail, simplify the plan and re-check it.
- Prefer the smallest plan that still satisfies the task and verification requirements.
