---
name: task-manager
description: Manage task files in docs/tasks/open and docs/tasks/closed, including task discovery, resume/create rules, append-only Attempts logging, Left Off At updates, Code Review field handling, and needs verification closeout.
---

# Task Manager

Use this skill when work in this repo needs task-file discovery, creation, resume behavior, or task-file hygiene.

## Start Every Task

- Check `docs/tasks/open/` first for a matching task.
- If a task matches, resume from `Left Off At` and avoid retrying failed `Attempts`.
- If no task exists for substantive work, create one from `docs/tasks/TEMPLATE.md` before editing code.

## Maintain the Task File

- Keep one task per file and use a descriptive kebab-case name.
- Keep `Attempts` append-only. Add an entry after each meaningful code-change attempt or verification pass.
- Keep `Left Off At` specific enough that a fresh session can resume without questions.
- Use the live statuses from the template: `not started`, `in progress`, `blocked`, `needs verification`.
- Add `## Code Review: completed` or `## Code Review: not required` once review status is known. Many live tasks use this field even though the template does not include it yet.

## Close-Out Rules

- Only the user closes tasks.
- End implementation at `needs verification`, never `done`.
- Before moving a task to `docs/tasks/closed/`, make sure the user has confirmed the Done Criteria and a retro entry exists in `docs/tasks/RETRO.md`.
