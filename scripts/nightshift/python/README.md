# Nightshift Python Orchestrator

Task 1 replaces the Night Shift bash control plane with a Python entrypoint while keeping the
current shell implementation as the reference source of truth.

## Usage

```bash
cd scripts/nightshift/python
python -m nightshift --dry-run
python -m nightshift --smoke
python -m pytest tests/ -v
```

The runtime resolves configuration from `../nightshift.conf`, optionally sources
`~/.nightshift-env`, and then applies current process environment overrides.
