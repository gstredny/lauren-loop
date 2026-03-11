# Complete Claude Code Workflow (v2 — Agent Teams)

## Philosophy

**Declarative, not imperative.** Don't tell Claude HOW to do something step-by-step. Tell Claude WHAT the end result should be — success criteria, tests that prove it works, constraints. Let Claude figure out the implementation. This gives Claude room to loop, try approaches, and self-correct.

**Task files are persistent memory.** Claude Code doesn't remember between sessions. Task files in `docs/tasks/open/` ARE the memory. Every session reads the task file, sees what was tried, and picks up where the last session left off. No repeating yourself.

**You are the only one who can close a task.** Claude Code proposes, you approve. Claude sets status to "needs verification" — never "done." You test, you confirm each Done Criterion, you say "close it out."

**Agent teams are an accelerator, not a replacement.** Use agent teams when work can genuinely be split into independent, parallel pieces across different files. Default to single-agent for sequential or single-file work. The workflow phases don't change — agent teams slot into Phases 2 and 4 as an optional execution mode.

---

## Phase 1: Task Initiation (Claude.ai — Planning Partner)

You come to Claude.ai with a feature or bug. Describe what you want to accomplish.

Claude.ai acts as senior dev critic:
- No code — planning only
- Push for robust, long-term architectural solutions — no band-aids
- Challenge assumptions, find gaps

Together we define:
- **Success criteria:** What does "done" look like? Specific, testable.
- **Tests:** What query, command, or test proves it works?
- **Testability design:** What public interface should the test hit, what external boundary may be mocked, and what seam is needed if the current shape is hard to test?
- **Constraints:** What should Claude NOT do? (No new endpoints, don't touch X file, etc.)
- **Execution mode decision:** Single-agent or agent team? (See "When to Use Agent Teams" below)

Claude.ai gives you a prompt to send to Claude Code. The prompt is framed as outcomes, not instructions:

> "Make this test pass: [specific test]. Success criteria: [list]. Public interface: [entry point]. Allowed mocks: [external boundaries only]. Constraints: [list]. Create a task in docs/tasks/open/ first."

If agent team mode was selected, the prompt includes team structure (see Phase 4b).

---

## Phase 2: Exploration & Planning (Claude Code Terminal)

You paste the prompt into Claude Code.

**Always start with:** `"Check docs/tasks/open first"`

Claude Code either:
- Finds existing task -> reads it, announces where we left off, resumes (never retries failed approaches from Attempts log)
- No matching task -> creates `docs/tasks/open/[descriptive-name].md` using the template

Claude Code explores the codebase and generates a plan.

Minimum planning content before execution:
- The public interface or observable behavior each slice will test
- Which boundaries may be mocked and which collaborators must stay real
- The first RED test for each behavior, or a `VERIFY` step for non-testable work
- A slice order that can be executed one behavior at a time instead of as a bulk test-writing pass

### Task Sizing Rule (Hard Gate)

Before proceeding to Phase 3, check the exploration plan's scope:

- **Threshold:** If the plan has **3+ phases** or is estimated to need **3+ sessions** -> it **must** be split into separate task files before execution begins.
- **Split boundaries:**
  - Natural dependency boundary (phase B doesn't start until phase A is verified)
  - Highest-value deliverable first
  - Each sub-task must be independently verifiable
- **Naming:** Append a letter suffix to the task ID: `TaskID-a`, `TaskID-b`, `TaskID-c`
- **Rationale:** Large tasks executed in a single session risk context window compaction, which degrades code quality.
- **Enforcement point:** Phase 2 — if your exploration plan has 3+ phases, split into separate task files before proceeding to Phase 3. No exceptions.

### Phase 2b: Parallel Exploration (Agent Team — Optional)

When the problem space is large or multi-layered, Claude Code can spin up an **exploration team** instead of investigating solo.

Trigger this by including in your prompt:

> "Explore this problem with a team. Assign teammates to investigate different layers. Lead synthesizes findings into a single plan. No code changes — exploration only."

Example team structure for exploration:
- **Teammate 1 — Database layer:** Investigate schema, queries, data flow
- **Teammate 2 — API layer:** Investigate endpoints, request/response patterns, error handling
- **Teammate 3 — Frontend layer:** Investigate components, state management, UI behavior

Rules for exploration teams:
- **No code changes.** Exploration only. Findings go into the task file's Context section.
- **Lead agent in delegate mode** (Shift+Tab) — coordinates only, doesn't explore itself.
- **Lead owns the task file.** Teammates report findings via messaging. Lead writes to Context section.
- **Each teammate writes a summary** of what they found before shutting down.
- **Lead synthesizes** all teammate findings into a single proposed plan.

You bring the synthesized plan back to Claude.ai for Phase 3 review.

---

## Phase 3: Plan Review & Agent Assignment (Claude.ai — Planning Partner)

You copy Claude Code's plan and bring it here.

Claude.ai reviews and improves:
- Is this over-engineered? Could it be simpler?
- Are there wrong assumptions Claude is making?
- Is this a band-aid or a real fix?
- What's missing?

### Single-Agent Assignment

For sequential or single-file tasks, Claude.ai gives you the improved plan ready to paste back into Claude Code.

The reviewed plan should keep the same TDD constraints:
- one failing test per behavior
- tests prove observable behavior through public interfaces
- mocks only at true external boundaries
- non-testable work called out as `VERIFY`

### Agent Team Assignment

For multi-file parallel tasks, Claude.ai assigns 2-4 scoped teammates:
- Each teammate gets a **specific file or set of files** (no overlap)
- Each teammate gets a **specific question or objective**
- Each teammate gets an **output format** (table, list, code change, etc.)
- **Constraints per teammate** (what they should NOT touch)
- **No file overlap between teammates** — this is non-negotiable

Claude.ai provides the full agent team prompt including:
1. Team structure with named roles
2. File ownership map (which teammate owns which files)
3. Success criteria per teammate
4. Lead agent instructions (delegate mode, task file ownership, coordination rules)

---

## Phase 4: Execution (Claude Code Terminal)

You send the improved plan back to Claude Code.

### Phase 4a: Single-Agent Execution (Default)

Claude Code executes. The key rules:
- One failing test, one minimum implementation, then repeat. Do not write a batch of tests up front.
- If a planned step contains multiple behaviors, split it into multiple RED/GREEN cycles before editing code.
- Tests should prove observable behavior through public interfaces. Mock only true out-of-process boundaries.
- After EVERY code change attempt -> Claude appends to the task file's Attempts log immediately (not batched at session end):
  - Date
  - What was tried (specific files, lines, changes)
  - What happened (error, test result, behavior)
  - Result: worked / failed / partial
- Attempts log is append-only. Never overwrite. Never delete. If 3 things were tried in one session, there are 3 separate dated entries.
- Only Status and "Left Off At" can be overwritten. Everything else accumulates.

### Phase 4b: Agent Team Execution (When Assigned)

When Claude.ai's Phase 3 output includes agent team assignments, execute as a team.

**Setup:**
1. Enable agent teams: Add `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"` to settings.json under `env`
2. Paste the full agent team prompt from Claude.ai
3. Claude Code (lead) creates the team and spawns teammates

**Lead Agent Rules:**
- **Delegate mode ON** (Shift+Tab) — lead coordinates only, does not write code
- **Lead owns the task file exclusively.** No teammate writes to the task file directly.
- Lead maintains the shared task list for teammate coordination
- Lead monitors teammate progress and redirects if needed

**Teammate Rules:**
- Each teammate works ONLY on their assigned files (per the file ownership map from Phase 3)
- Teammates report progress to lead via messaging, not by writing to the task file
- Teammates can message each other directly for cross-layer coordination
- When a teammate completes their work, they send a completion summary to lead including:
  - What was changed (specific files, lines)
  - Test results
  - Any issues or concerns discovered

**Task File Logging (Lead Responsibility):**

The lead agent is the ONLY writer to the task file. As teammates report in, the lead:
- Appends each teammate's work to the Attempts log as a separate dated entry
- Tags each entry with the teammate role: `[Teammate: Frontend]`, `[Teammate: API]`, etc.
- Updates "Left Off At" with overall team status
- Logs any cross-teammate coordination decisions in Context

Example Attempts log entry for team execution:
```
- 2025-02-06 [Teammate: API]: Modified service.py lines 280-315.
  Changed mapping to match expected values. pytest test_service passed (5/5).
  -> Result: worked

- 2025-02-06 [Teammate: Frontend]: Updated Results.jsx to display new column headers.
  Manual test: query returns correct 5 columns. Console: no errors.
  -> Result: worked

- 2025-02-06 [Lead]: Both teammates completed. Integration test pending — need to verify
  end-to-end query with both changes active. Set status to needs verification.
  -> Result: partial (integration not yet tested)
```

**Shutdown Sequence:**
1. All teammates send final completion summaries to lead
2. Lead logs all summaries to task file
3. Lead shuts down each teammate (sends shutdown request, teammate confirms)
4. Lead runs cleanup to remove shared team resources
5. Lead updates task file status and "Left Off At"

---

## Phase 5: Verification (You + Claude Code)

When Claude Code believes the fix works (code compiles, tests pass, committed), it:
1. Sets status to "needs verification" (never "done")
2. Asks: "This fix appears to be working. Want me to walk through the Done Criteria to close out this task?"

Claude Code goes through each Done Criterion checkbox one by one:
- "First criterion: [X]. Did you verify this works?"
- You confirm -> Claude marks `[x]`
- You reject -> Claude logs it as a new Attempt entry and keeps working

Only you can mark checkboxes. Claude proposes, you approve.

**Hook enforcement:** A PreToolUse hook automatically blocks moving any task to `docs/tasks/closed/` if unchecked `- [ ]` criteria remain in the file. All boxes must be `[x]` before the move proceeds.

**No change for agent teams.** Verification is always sequential, always you driving. If a rejected criterion requires rework on a specific layer, you decide whether to re-spin a teammate or handle it single-agent.

---

## Phase 6: Close-out (You Control This)

Only you can close a task. Once:
- All Done Criteria are `[x]`
- You've tested it yourself
- You're satisfied

You say: `"Close it out"`

**Two automated checks must pass before the move executes:**
1. **Done Criteria check** — all checkboxes in the task file must be `[x]`. If any `- [ ]` remain, the hook blocks the move and lists the unchecked criteria.
2. **Retro entry check** — a matching entry must exist in `docs/tasks/RETRO.md`. If missing, the hook blocks the move and asks for a retro entry first.

Claude Code:
1. Appends a retro entry to `docs/tasks/RETRO.md` capturing what was learned
2. Moves the task file from `docs/tasks/open/` to `docs/tasks/closed/`

**Retro entry format:**
```
### [YYYY-MM-DD] Task: [task name]
- **What worked:** [approaches worth repeating]
- **What broke:** [failures to avoid next time]
- **Workflow friction:** [process issues, not code issues — or "None"]
- **Pattern:** [generalizable lesson for future tasks]
```

Entries are **append-only** — never edit or delete previous entries in `docs/tasks/RETRO.md`.

---

## When to Use Agent Teams

Use agent teams when ALL of these are true:
- [ ] Work spans **multiple files** with clear ownership boundaries
- [ ] Tasks can run **independently in parallel** (step B doesn't depend on step A)
- [ ] Each piece produces a **clear deliverable** (a function, a test file, a component)
- [ ] The time savings from parallelization **outweigh coordination overhead**

Do NOT use agent teams when:
- Work is sequential (step 2 depends on step 1)
- Multiple agents would need to edit the same file
- The task is simple enough for one agent to handle quickly
- You're debugging a single tricky issue (use competing-hypothesis exploration instead, Phase 2b)

### Decision Quick-Check

Ask yourself: "Can I draw clear file-ownership lines with zero overlap?"

- **Yes -> Agent team candidate.** Proceed with team structure in Phase 3.
- **No -> Single agent.** Don't force it.

---

## Session Hygiene

**Start every session:**
> "Check docs/tasks/open first"

**End every session:**
> "Summarize what changed, test results, and what's left"

This prevents the "unclear outcome" problem where sessions end and you don't know what happened.

**Review retro entries:**
The session hook automatically injects the last 10 entries from `docs/tasks/RETRO.md` at session start. Use these to avoid repeating past mistakes.

**Always activate venv:**
Claude Code runs `source .venv/bin/activate` before any Python command.

**Agent team sessions — additional hygiene:**
- Before ending: Ensure all teammates are shut down and lead has logged their summaries
- Lead runs cleanup before session end
- Verify task file has complete Attempts log entries for ALL teammates

**Task file status declaration:**
At session end, your summary must declare task file status:
- "Task file updated: docs/tasks/open/[filename].md" OR
- "Task file unchanged — no scope/criteria changes"

**When updates are required:**
- **Scope changes** (approach pivot, architecture decision) -> update Context section
- **Criteria changes** (new requirements, updated done criteria) -> update Done Criteria
- **Failed approaches** -> append to Attempts (date, what tried, result)

**Examples:**
- "Changed from REST to GraphQL" -> update Context + declare: "Task file updated: docs/tasks/open/api-refactor.md"
- "Tried Redis, auth failed" -> append to Attempts + declare: "Task file updated: docs/tasks/open/caching.md"
- "Only minor code edits, no scope change" -> declare: "Task file unchanged — no scope/criteria changes"

**Hook vs Rule:**
- The stop hook enforces the **declaration** (reminds you to state what happened)
- Project rules define **when updates are required** (what constitutes a significant change)

---

## Task File Template

```markdown
## Task: [name]
## Status: not started | in progress | blocked | needs verification
## Execution Mode: single-agent | agent-team
## Goal: [one sentence — the outcome, not the approach]

## Success Criteria:
- [ ] [specific testable criterion]
- [ ] [specific testable criterion]

## Constraints:
- [what NOT to do]

## Team Structure (agent-team mode only):
- Lead: delegate mode, owns task file
- Teammate 1 [Role]: [assigned files] — [objective]
- Teammate 2 [Role]: [assigned files] — [objective]
- Teammate 3 [Role]: [assigned files] — [objective]

## File Ownership Map (agent-team mode only):
| Teammate | Files | Constraint |
|----------|-------|------------|
| [Role]   | [specific files] | [what NOT to touch] |

## Relevant Files:
- [only files this task touches]

## Context:
[decisions and findings relevant to THIS task only]

## Left Off At:
[exactly where work stopped — specific enough to resume cold]

## Attempts:
- [date] [Teammate: role if team mode]: what was tried -> what happened -> result (worked/failed/partial)
```

---

## The Key Mindset Shift

**Old way (imperative):**
> "Fix service.py line 312. Change the mapping to match the expected values. Then update the test. Then run the test suite."

**New way (declarative):**
> "Success criteria: Query returns the correct results with correct columns. All mappings match expected values. Constraint: Don't add new queries. Figure out how to make it work."

Claude loops until criteria are met. You review the result, not the approach.

**Agent team mindset (parallel declarative):**
> "Success criteria: [same as above]. This is a team task. Teammate 1 (API): Make mappings match expected values in service.py. Teammate 2 (Frontend): Update Results.jsx column headers to match new response schema. Teammate 3 (Tests): Write integration test covering end-to-end query. Lead: delegate mode, own the task file, coordinate."

Same declarative philosophy. Parallel execution. One task file. One source of truth.

---

## Summary

| Phase | Where | Who Drives | Output | Agent Team Change |
|-------|-------|-----------|--------|-------------------|
| 1. Initiation | Claude.ai | You + Claude.ai | Success criteria, constraints, execution mode decision | Decide single vs team |
| 2. Exploration | Claude Code | Claude | Plan + task file created | Optional: parallel exploration team |
| 3. Review | Claude.ai | Claude.ai | Improved plan, agent/team assignments | File ownership map + team structure |
| 4. Execution | Claude Code | Claude | Code changes, attempts logged | Parallel teammates, lead logs to task file |
| 5. Verification | Claude Code | You | Done criteria checked off | No change — always sequential |
| 6. Close-out | Claude Code | You | Task moved to closed/ | No change |
