## Task: {{TASK_NAME}}
## Status: pilot-planning
## Goal: {{GOAL}}
## Tags:
## Created: {{TIMESTAMP}}

## Constraints
- No mock data — Azure/model fails → return error message
- .env is read-only
- No new endpoints — modify existing, maintain backward compatibility
- Product data integrity — never modify product_data.json structure
- Managed identity — never toggle
- SAS URLs never sent to LLM
- Packaging — protected code, read docs before modifying
- ARR affinity required
- Never recreate singletons (PyTorch model, ProductLookupService)
- Preserve LRU cache decorators
- UI changes require explicit user approval

## Current Plan
(Planner writes here)

## Critique
(Critic writes here)

## Plan History
(Archived plan+critique rounds)

## Related Context
(Auto-injected by script)

## Left Off At:
Not started.

## Attempts:
(none yet)

## Execution Log
(Timestamped round results)
