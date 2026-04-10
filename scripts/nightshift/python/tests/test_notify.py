from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import nightshift.notify as notify_module
from nightshift.cost import CostTracker
from nightshift.notify import build_summary, send_webhook
from nightshift.runtime import RunContext


def _create_context_and_tracker(tmp_path: Path, config_factory) -> tuple[RunContext, CostTracker]:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(
        config,
        dry_run=False,
        smoke=False,
        now=datetime(2026, 4, 9, 1, 0, 0),
    )
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=1_000_000,
        output_tokens=0,
        input_price_per_million="1.25",
        output_price_per_million="0",
        cache_write_price_per_million="0",
        cache_read_price_per_million="0",
    )
    return context, tracker


def test_build_summary_includes_all_fields(tmp_path: Path, config_factory) -> None:
    context, tracker = _create_context_and_tracker(tmp_path, config_factory)
    digest_path = context.temp_digest_path
    digest_path.write_text(
        "\n".join(
            [
                "# Nightshift Detective Digest — 2026-04-09",
                "",
                "## Ranked Findings",
                "| # | Severity | Category | Title |",
                "|---|----------|----------|-------|",
                "| 1 | critical | regression | Auth regression |",
                "| 2 | major | missing-test | Coverage gap |",
                "| 3 | minor | quality | UI typo |",
                "",
                "## Minor & Observation Findings",
                "| # | Title | Severity | Category | Source | Evidence |",
                "|---|-------|----------|----------|--------|----------|",
                "| 4 | Follow-up note | observation | process | manager | summary |",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    context.digest_path = digest_path
    context.total_findings_available = 4
    context.task_file_count = 2
    context.pr_url = "https://github.com/example/repo/pull/123"
    context.warnings.append("warning one")
    context.failures.append("failure one")

    summary = build_summary(
        context,
        tracker,
        now=datetime(2026, 4, 9, 2, 1, 1),
    )

    assert "Nightshift Detective Summary" in summary
    assert "Run date: 2026-04-09" in summary
    assert "Findings: 4 findings" in summary
    assert "Severity: critical=1 high=1 medium=1 low=1" in summary
    assert "Task files: 2" in summary
    assert "Cost: $1.2500" in summary
    assert "Duration: 1h 1m 1s" in summary
    assert "PR: https://github.com/example/repo/pull/123" in summary
    assert "- Auth regression" in summary
    assert "- Coverage gap" in summary
    assert "- UI typo" in summary
    assert "Warnings:" in summary
    assert "Failures:" in summary


def test_build_summary_no_findings_is_clean(tmp_path: Path, config_factory) -> None:
    context, tracker = _create_context_and_tracker(tmp_path, config_factory)
    context.total_findings_available = 0
    context.task_file_count = 0
    context.pr_url = None

    summary = build_summary(
        context,
        tracker,
        now=datetime(2026, 4, 9, 1, 0, 30),
    )

    assert "Findings: 0 findings" in summary
    assert "PR: none" in summary
    assert "Top findings:" not in summary
    assert "Warnings:" not in summary
    assert "Failures:" not in summary


def test_send_webhook_success_posts_expected_payload(monkeypatch) -> None:
    captured: dict[str, object] = {}

    class FakeResponse:
        status = 200

        def __enter__(self) -> "FakeResponse":
            return self

        def __exit__(self, exc_type, exc, tb) -> bool:
            return False

    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["timeout"] = timeout
        captured["payload"] = json.loads(req.data.decode("utf-8"))
        return FakeResponse()

    monkeypatch.setattr(notify_module.request, "urlopen", fake_urlopen)

    assert send_webhook("https://example.com/webhook", "summary text", "2026-04-09") is True
    assert captured["url"] == "https://example.com/webhook"
    assert captured["timeout"] == 10
    assert captured["payload"] == {"text": "summary text", "run_date": "2026-04-09"}


def test_send_webhook_failure_returns_false(monkeypatch) -> None:
    def fake_urlopen(_req, timeout):
        raise OSError(f"timeout={timeout}")

    monkeypatch.setattr(notify_module.request, "urlopen", fake_urlopen)

    assert send_webhook("https://example.com/webhook", "summary text", "2026-04-09") is False


def test_send_webhook_empty_url_returns_false() -> None:
    assert send_webhook("", "summary text", "2026-04-09") is False
