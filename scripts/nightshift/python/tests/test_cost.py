from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

from nightshift.cost import CostTracker, check_cost_cap, weekly_summary


def test_cost_accumulates_and_writes_summary(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=1000,
        output_tokens=100,
    )
    tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=0,
        output_tokens=0,
    )

    summary = tracker.summary_text()
    csv_text = (tmp_path / "cost-history.csv").read_text(encoding="utf-8")

    assert "Total:" in summary
    assert "Calls:" in summary
    assert tracker.total() > 0
    assert csv_text.splitlines()[0].startswith("timestamp,agent,model,playbook")


def test_unknown_model_falls_back_to_sonnet_pricing(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    cost = tracker.record_call(
        agent="mystery-agent",
        model="mystery-model",
        playbook="mystery.md",
        input_tokens=1_000_000,
        output_tokens=1_000_000,
    )

    expected = Decimal(str(config.claude_sonnet_input_price)) + Decimal(str(config.claude_sonnet_output_price))
    assert cost == expected


def test_sonnet_pricing_includes_cache_token_parity(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    cases = [
        {
            "input_tokens": 1000,
            "output_tokens": 500,
            "cache_create_tokens": 200,
            "cache_read_tokens": 300,
            "expected_cost": Decimal("0.0113"),
        }
    ]

    for case in cases:
        cost = tracker.record_call(
            agent="mystery-agent",
            model="mystery-model",
            playbook="mystery.md",
            input_tokens=case["input_tokens"],
            output_tokens=case["output_tokens"],
            cache_create_tokens=case["cache_create_tokens"],
            cache_read_tokens=case["cache_read_tokens"],
        )

        assert cost == case["expected_cost"]


def test_gpt_family_uses_codex_pricing(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    cost = tracker.record_call(
        agent="codex-commit-detective",
        model="azure54/gpt-5.4",
        playbook="commit-detective.md",
        input_tokens=1_000_000,
        output_tokens=1_000_000,
    )

    expected = Decimal(str(config.codex_input_price)) + Decimal(str(config.codex_output_price))
    assert cost == expected


def test_explicit_rates_override_model_resolution(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    cost = tracker.record_call(
        agent="custom-agent",
        model="mystery-model",
        playbook="custom.md",
        input_tokens=1_000_000,
        output_tokens=500_000,
        input_price_per_million="1.25",
        output_price_per_million="2.50",
        cache_write_price_per_million="0",
        cache_read_price_per_million="0",
    )

    assert cost == Decimal("2.5000")


def test_zero_token_fallback_cost_does_not_increment_runaway(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )
    tracker.init("run-123")

    first = tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=0,
        output_tokens=0,
    )

    second = tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=0,
        output_tokens=0,
    )

    assert first == Decimal(str(config.per_call_cap_usd))
    assert second == Decimal(str(config.per_call_cap_usd))
    assert tracker.check_runaway() is True


def test_init_writes_cost_state_via_temp_rename(tmp_path: Path, config_factory, monkeypatch) -> None:
    config = config_factory(repo_dir=tmp_path)
    tracker = CostTracker(
        state_file=tmp_path / "state.json",
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )

    rename_calls: list[tuple[Path, Path]] = []
    original_rename = Path.rename

    def spy_rename(self: Path, target: Path) -> Path:
        rename_calls.append((self, target))
        return original_rename(self, target)

    monkeypatch.setattr(Path, "rename", spy_rename)

    tracker.init("run-123")

    assert rename_calls == [(tmp_path / "state.tmp", tmp_path / "state.json")]
    assert not (tmp_path / "state.tmp").exists()
    assert json.loads((tmp_path / "state.json").read_text(encoding="utf-8"))["run_id"] == "run-123"


def test_corrupt_cost_state_recovers_to_zero_total(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    state_file = tmp_path / "state.json"
    state_file.write_text('{"broken":', encoding="utf-8")

    tracker = CostTracker(
        state_file=state_file,
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )

    assert tracker.total() == Decimal("0.0000")
    recovered_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert recovered_state["run_id"] == "recovered"
    assert recovered_state["call_count"] == 0
    assert recovered_state["cumulative_usd"] == "0.0000"


def test_record_call_succeeds_after_corrupt_state_recovery(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    state_file = tmp_path / "state.json"
    state_file.write_text("not-json", encoding="utf-8")

    tracker = CostTracker(
        state_file=state_file,
        csv_file=tmp_path / "cost-history.csv",
        config=config,
    )

    cost = tracker.record_call(
        agent="claude-commit-detective",
        model=config.claude_model,
        playbook="commit-detective.md",
        input_tokens=0,
        output_tokens=0,
    )

    assert cost == Decimal(str(config.per_call_cap_usd))
    assert tracker.total() == cost
    recovered_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert recovered_state["call_count"] == 1
    assert recovered_state["cumulative_usd"] == f"{cost:.4f}"


def test_weekly_summary_returns_most_recent_seven_days(tmp_path: Path) -> None:
    csv_path = tmp_path / "cost-history.csv"
    csv_path.write_text(
        "\n".join(
            [
                "timestamp,agent,model,playbook,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,cost_usd,cost_source,cumulative_usd",
                "2026-04-01T01:00:00-0500,det,model,a,1,1,0,0,1.0000,parsed,1.0000",
                "2026-04-02T01:00:00-0500,det,model,a,1,1,0,0,2.0000,parsed,3.0000",
                "2026-04-03T01:00:00-0500,det,model,a,1,1,0,0,3.0000,parsed,6.0000",
                "2026-04-04T01:00:00-0500,det,model,a,1,1,0,0,4.0000,parsed,10.0000",
                "2026-04-05T01:00:00-0500,det,model,a,1,1,0,0,5.0000,parsed,15.0000",
                "2026-04-06T01:00:00-0500,det,model,a,1,1,0,0,6.0000,parsed,21.0000",
                "2026-04-07T01:00:00-0500,det,model,a,1,1,0,0,7.0000,parsed,28.0000",
                "2026-04-08T01:00:00-0500,det,model,a,1,1,0,0,8.0000,parsed,36.0000",
                "2026-04-09T01:00:00-0500,det,model,a,1,1,0,0,9.0000,parsed,45.0000",
                "2026-04-10T01:00:00-0500,det,model,a,1,1,0,0,10.0000,parsed,55.0000",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    total, day_count, breakdown = weekly_summary(csv_path)

    assert total == Decimal("49.0000")
    assert day_count == 7
    assert [day for day, _amount in breakdown] == [
        "2026-04-10",
        "2026-04-09",
        "2026-04-08",
        "2026-04-07",
        "2026-04-06",
        "2026-04-05",
        "2026-04-04",
    ]


def test_weekly_summary_empty_csv_returns_zeroes(tmp_path: Path) -> None:
    total, day_count, breakdown = weekly_summary(tmp_path / "missing.csv")

    assert total == Decimal("0.0000")
    assert day_count == 0
    assert breakdown == []


def test_check_cost_cap_under_limit_matches_shell_semantics() -> None:
    assert check_cost_cap(Decimal("9.9999"), Decimal("10.0000")) is True


def test_check_cost_cap_equal_or_over_limit_halts_run() -> None:
    assert check_cost_cap(Decimal("10.0000"), Decimal("10.0000")) is False
    assert check_cost_cap(Decimal("10.0001"), Decimal("10.0000")) is False
