---
name: tdd-planning
description: Plan implementation work before coding by defining public interfaces, real collaborator boundaries, and vertical RED or VERIFY slices.
---

# TDD Planning

Use this skill after the goal is clear but before writing the first test or implementation edit.

## When to Use

- New feature work with multiple behaviors
- Bug fixes where the existing interface is unclear
- Refactors that need an explicit observable-behavior contract

Skip it for trivial documentation edits or one-line fixes with one obvious test.

## Planning Questions

1. What public interface or observable behavior will prove the change works?
2. Which collaborators must stay real, and which boundaries are truly external and mockable?
3. What is the smallest first RED slice that proves real progress?
4. Which steps are not meaningfully testable and should be called out as `VERIFY` instead?

## Output Shape

Produce a short plan with:

- Interface under test
- Allowed mocks and required real collaborators
- Ordered vertical slices, one behavior per slice
- Explicit `VERIFY` steps for non-testable work

## Rules

- Keep tests on observable behavior through public entry points.
- Do not batch-write tests up front.
- If the plan changes task scope materially, update the task file before coding.
