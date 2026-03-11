# Task Manager Examples

## Task File Template

```markdown
## Task: [descriptive name]
## Status: not started | in progress | blocked | done
## Goal: [one sentence max]

## Relevant Files:
- [path/to/file.py] - [what changes needed]
- [path/to/other.js] - [what changes needed]

## Context:
[Only decisions and findings relevant to THIS task — not general project context]

## Done Criteria:
- [ ] [specific testable criterion]
- [ ] [specific testable criterion]

## Left Off At:
[Exactly where work stopped — be specific enough that a new session can resume without asking questions]

## Attempts:
- [date]: what was tried -> what happened -> result (worked/failed/partial)
```

## Good Example

```markdown
## Task: User Role Mapping
## Status: in progress
## Goal: Map user roles to correct service permissions

## Relevant Files:
- src/services/role_service.py - add role mapping
- tests/test_role_service.py - add test cases for role mapping

## Context:
- Admin roles currently unmapped, returns "Unknown" permission type
- Should map to "Full Access" category per product team
- 47 admin users in the database

## Done Criteria:
- [ ] Admin roles return "Full Access" permission type
- [ ] pytest tests/test_role_service.py passes
- [ ] No regression in existing role mappings

## Left Off At:
Added mapping in role_service.py:142. Need to write test cases.
File saved but tests not yet run.

## Attempts:
- 2025-01-15: Tried regex pattern `Admin.*Role` -> missed "Administrator Role Level2" -> switched to substring match
```

## Bad Example (What to Avoid)

```markdown
## Task: Fix stuff
## Status: working on it
## Goal: Make things work better

## Relevant Files:
- lots of files

## Context:
The whole system is complicated and there are many services...
[500 words of general architecture explanation]

## Done Criteria:
- [ ] Works correctly
- [ ] No bugs

## Left Off At:
Made some changes, will continue later.

## Attempts:
(none logged)
```

**Problems with bad example:**
- Vague task name and goal
- No specific files listed
- Context is general, not task-specific
- Done criteria are untestable
- "Left Off At" doesn't help resume
- No attempts logged

## When to Split Tasks

Create separate task files when:
- Work spans multiple unrelated systems
- Different skills/expertise needed for parts
- One part is blocked but another can proceed

**Example split:**
- `role-mapping-backend.md` - Python service changes
- `role-mapping-frontend.md` - React component updates
- `role-mapping-database.md` - Schema changes (blocked on DBA approval)
