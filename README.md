# Lauren Loop

A multi-agent workflow system for autonomous software development. Runs planner, critic, executor, and reviewer agents in coordinated pipelines using Claude Code CLI sessions with task files as the communication bus.

## Pipelines

### V1 -- Planner-Critic Pipeline (`lauren-loop.sh`)
Linear pipeline: plan > critique > execute > review > fix. Single-engine (Claude). Best for straightforward tasks.

### V2 -- Competitive Pipeline (`lauren-loop-v2.sh`)
Dual-engine competitive pipeline: two planners (Claude + Codex) generate independent plans, a Lead agent selects/synthesizes the best, then dual reviewers validate. Best for complex tasks requiring diverse perspectives.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Git
- Bash 4+
- Optional: [Codex CLI](https://github.com/openai/codex) for V2 dual-engine mode

## Quick Start

> Already installed? Jump to [Usage](#usage). Need to install first? See [Installation](#installation).

### Try it (sample task)

A sample task ships with the install. Run the full plan-critique-execute-review cycle:

```bash
./lauren-loop.sh pick
# Select "sample-hello-world" → auto-classify → walk away
```

Or launch it directly:

```bash
./lauren-loop.sh auto sample-hello-world "Add a CONTRIBUTING.md with setup instructions and PR guidelines"
```

Expect 15-30 minutes of autonomous work. When it finishes, review the diff and inspect `docs/tasks/open/sample-hello-world.md` to see how plans and reviews were recorded.

### Use your own tasks

Point Lauren Loop at your own work:

```bash
# Create and run a new task
./lauren-loop.sh auto my-feature "Add rate limiting to the /api/health endpoint"

# Or pick from existing tasks in docs/tasks/open/
./lauren-loop.sh pick
```

Tasks are markdown files in `docs/tasks/open/` with a `## Goal:` and `## Status:` header. See [docs/tasks/TEMPLATE.md](docs/tasks/TEMPLATE.md) for the full format.

## Structured Workflows

Lauren Loop executes individual tasks with adversarial quality checks. It doesn't plan your project or structure your work. For a full context engineering methodology — project init, phase planning, research, and multi-task orchestration — see [GSD (Get Shit Done)](https://github.com/gsd-build/get-shit-done). For a lighter starting point, Lauren Loop includes a task template at `docs/tasks/TEMPLATE.md`.

## Installation

### Install as a git submodule (recommended)

```bash
# From your project root:
bash <(curl -s https://raw.githubusercontent.com/gstredny/lauren-loop/main/install.sh) .

# Or clone first:
git clone git@github.com:gstredny/lauren-loop.git /tmp/lauren-loop
bash /tmp/lauren-loop/install.sh /path/to/your/project
```

This will:
1. Add `vendor/lauren-loop` as a git submodule
2. Create shim scripts (`lauren-loop.sh`, `lauren-loop-v2.sh`) in your project root
3. Copy scaffold files (won't overwrite existing files)

### Direct clone

```bash
git clone git@github.com:gstredny/lauren-loop.git
cd lauren-loop
```

### Post-install setup

```bash
# Required: Configure project rules
mv prompts/project-rules.md.example prompts/project-rules.md
# Edit with your project's constraints and rules

# Required: Configure Lauren Loop settings
mv .lauren-loop.conf.example .lauren-loop.conf
# Edit with your preferred settings

# Optional: Set up AGENTS.md
mv AGENTS.md.example AGENTS.md
# Edit with your project-specific agent instructions
```

## Usage

### V1 Pipeline

```bash
# Interactively rank and launch an existing open task
./lauren-loop.sh pick

# Read-only recommendation for the next open task
./lauren-loop.sh next

# Start from a brand-new idea and let Lauren Loop classify it
./lauren-loop.sh auto <slug> "<goal>"

# Start V1 directly
./lauren-loop.sh <slug> "<goal>"

# Resume an existing task
./lauren-loop.sh <slug> "<goal>" --resume

# Dry run (no actual agent calls)
./lauren-loop.sh <slug> "<goal>" --dry-run

```

### V2 Competitive Pipeline

```bash
# Start competitive pipeline
./lauren-loop-v2.sh <slug> "<goal>"

# With specific engine configuration
ENGINE_PLANNER_B=claude ./lauren-loop-v2.sh <slug> "<goal>"
```

### Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Print what would happen without executing |
| `--resume` | Resume an existing task |
| `--model <model>` | Override agent model (default: opus) |
| `--no-review` | Skip review phase |
| `--no-close` | Don't auto-close task on success |

## Configuration

### `.lauren-loop.conf`

Project-scoped configuration sourced at startup:

```bash
LAUREN_LOOP_MAX_COST=100      # Cost ceiling in USD
LAUREN_LOOP_MODEL=opus        # Agent model
LAUREN_LOOP_STRICT=false      # Strict mode (fail on warnings)
LEAD_TIMEOUT=120m             # Per-role timeout limits
EXECUTOR_TIMEOUT=120m
CRITIC_TIMEOUT=15m
REVIEWER_TIMEOUT=30m
FIX_TIMEOUT=45m
```

### `prompts/project-rules.md`

Project-specific rules prepended to all agent system prompts. This is your primary mechanism for project-specific constraints. Missing file warns but doesn't crash.

### Environment Variables

| Variable | Description |
|----------|-------------|
| `LAUREN_LOOP_PROJECT_DIR` | Override project root (set by shim scripts) |
| `LAUREN_LOOP_PROJECT_NAME` | Override project name (default: dirname) |
| `LAUREN_LOOP_MODEL` | Agent model override |
| `LAUREN_LOOP_MAX_COST` | Cost ceiling in USD |
| `LAUREN_LOOP_STRICT` | Strict mode (true/false) |
| `LAUREN_LOOP_CODEX_MODEL` | Codex engine model (V2) |
| `ENGINE_PLANNER_A` | V2 planner A engine (claude/codex) |
| `ENGINE_PLANNER_B` | V2 planner B engine (claude/codex) |
| `ENGINE_REVIEWER_A` | V2 reviewer A engine |
| `ENGINE_REVIEWER_B` | V2 reviewer B engine |

## API Compatibility

| Provider | Status | Notes |
|----------|--------|-------|
| Claude (Anthropic API) | Works | Primary engine for all pipelines |
| Azure Foundry | Supported | Via `context-guard.sh` routing |
| Codex (OpenAI) | V2 dual-engine | Used for competitive planning and review |

## Updating

```bash
bash vendor/lauren-loop/upgrade.sh
```

This pulls the latest code and reports any new scaffold files.

## Architecture

- **V1 Architecture:** See [docs/architecture-v1.md](docs/architecture-v1.md)
- **V2 Architecture:** See [docs/architecture-v2.md](docs/architecture-v2.md)
- **V2 Reference:** See [docs/v2-reference.md](docs/v2-reference.md)
- **User Guide:** See [docs/user-guide.md](docs/user-guide.md)
- **Workflow:** See [docs/WORKFLOW.md](docs/WORKFLOW.md)

## Project Structure

```
lauren-loop/
├── lauren-loop.sh              # V1 planner-critic pipeline
├── lauren-loop-v2.sh           # V2 competitive pipeline
├── lib/lauren-loop-utils.sh    # Shared utilities
├── prompts/                    # Agent role prompts (21 files)
├── templates/                  # Task templates
├── tests/                      # Test suites (8 files)
├── docs/                       # Architecture and usage docs
├── scaffold/                   # Files copied to project on install
├── install.sh                  # Submodule installer
├── upgrade.sh                  # Update helper
├── AGENTS.md.example           # Template for project AGENTS.md
└── LICENSE                     # MIT License
```

## Key Design Decisions

- **`PROJECT_DIR` / `SCRIPT_DIR` separation:** `SCRIPT_DIR` points to the Lauren Loop code (prompts, lib, templates). `PROJECT_DIR` points to the consuming project (tasks, logs, config, project-rules). This enables submodule installation.
- **`project-rules.md` injection:** Project constraints are loaded once at startup and prepended to all agent prompts. Missing file warns but doesn't crash.
- **`context-guard.sh` optional:** V2's Codex engines gracefully fall back to Claude when context-guard.sh is absent.
- **Template constraint injection:** The `<!-- LAUREN_LOOP:INJECT_RULES -->` marker in task templates is replaced with project rules at task creation time.

## Testing

```bash
# Run all tests
for t in tests/test_*.sh; do bash "$t"; done

# Run a specific test
bash tests/test_lauren_loop_logic.sh
```

## License

[MIT](LICENSE)
