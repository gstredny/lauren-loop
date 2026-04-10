from __future__ import annotations

import csv
import json
import logging
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Any

from .config import NightshiftConfig


FOUR_DP = Decimal("0.0001")
ONE_MILLION = Decimal("1000000")
logger = logging.getLogger(__name__)


def check_cost_cap(total: Decimal | float | str, cap: Decimal | float | str) -> bool:
    return Decimal(str(total)) < Decimal(str(cap))


def weekly_summary(
    csv_path: Path,
    as_of_date: date | datetime | str | None = None,
) -> tuple[Decimal, int, list[tuple[str, Decimal]]]:
    if not csv_path.exists() or csv_path.stat().st_size == 0:
        return Decimal("0.0000"), 0, []

    cutoff = _normalize_as_of_date(as_of_date)
    daily_totals: dict[str, Decimal] = {}

    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        for row in reader:
            if not row or row[0] == "timestamp" or len(row) < 9:
                continue
            raw_date = row[0].split("T", 1)[0].strip()
            if not raw_date:
                continue
            if cutoff is not None and raw_date > cutoff:
                continue
            try:
                datetime.strptime(raw_date, "%Y-%m-%d")
                cost_value = Decimal(row[8]).quantize(FOUR_DP, rounding=ROUND_HALF_UP)
            except (ValueError, InvalidOperation):
                continue
            daily_totals[raw_date] = daily_totals.get(raw_date, Decimal("0.0000")) + cost_value

    breakdown = [
        (day, total.quantize(FOUR_DP, rounding=ROUND_HALF_UP))
        for day, total in sorted(daily_totals.items(), reverse=True)[:7]
    ]
    total = sum((amount for _, amount in breakdown), Decimal("0.0000")).quantize(
        FOUR_DP,
        rounding=ROUND_HALF_UP,
    )
    return total, len(breakdown), breakdown


@dataclass(frozen=True)
class CostRecord:
    agent: str
    model: str
    playbook: str
    input_tokens: int
    output_tokens: int
    cache_create_tokens: int
    cache_read_tokens: int
    cost_usd: str
    cost_source: str
    timestamp: str


@dataclass(frozen=True)
class CostRates:
    input_price: Decimal
    output_price: Decimal
    cache_write_price: Decimal
    cache_read_price: Decimal


class CostTracker:
    def __init__(self, *, state_file: Path, csv_file: Path, config: NightshiftConfig) -> None:
        self.state_file = state_file
        self.csv_file = csv_file
        self.config = config

    def init(self, run_id: str) -> None:
        self._write_state(self._new_state(run_id))

    def record_call(
        self,
        *,
        agent: str,
        model: str,
        playbook: str,
        input_tokens: int,
        output_tokens: int,
        cache_create_tokens: int = 0,
        cache_read_tokens: int = 0,
        input_price_per_million: Decimal | float | str | None = None,
        output_price_per_million: Decimal | float | str | None = None,
        cache_write_price_per_million: Decimal | float | str | None = None,
        cache_read_price_per_million: Decimal | float | str | None = None,
    ) -> Decimal:
        state = self._read_state()
        timestamp = self._timestamp()

        if input_tokens == output_tokens == cache_create_tokens == cache_read_tokens == 0:
            cost = Decimal(str(self.config.per_call_cap_usd))
            cost_source = "fallback"
            over_threshold = False
        else:
            rates = (
                CostRates(
                    input_price=self._coerce_rate(input_price_per_million),
                    output_price=self._coerce_rate(output_price_per_million),
                    cache_write_price=self._coerce_rate(cache_write_price_per_million),
                    cache_read_price=self._coerce_rate(cache_read_price_per_million),
                )
                if None
                not in (
                    input_price_per_million,
                    output_price_per_million,
                    cache_write_price_per_million,
                    cache_read_price_per_million,
                )
                else self._resolve_rates(model)
            )
            cost = (
                (Decimal(input_tokens) / ONE_MILLION * rates.input_price)
                + (Decimal(output_tokens) / ONE_MILLION * rates.output_price)
                + (Decimal(cache_create_tokens) / ONE_MILLION * rates.cache_write_price)
                + (Decimal(cache_read_tokens) / ONE_MILLION * rates.cache_read_price)
            ).quantize(FOUR_DP, rounding=ROUND_HALF_UP)
            cost_source = "parsed"
            over_threshold = cost >= Decimal(str(self.config.runaway_threshold_usd))

        cumulative = (
            Decimal(state["cumulative_usd"]) + cost
        ).quantize(FOUR_DP, rounding=ROUND_HALF_UP)
        consecutive = state["consecutive_high_cost_count"] + 1 if over_threshold else 0

        record = CostRecord(
            agent=agent,
            model=model,
            playbook=playbook,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_create_tokens=cache_create_tokens,
            cache_read_tokens=cache_read_tokens,
            cost_usd=f"{cost:.4f}",
            cost_source=cost_source,
            timestamp=timestamp,
        )

        state["call_count"] += 1
        state["last_call_cost"] = record.cost_usd
        state["cumulative_usd"] = f"{cumulative:.4f}"
        state["consecutive_high_cost_count"] = consecutive
        state["calls"].append(record.__dict__)
        self._write_state(state)
        self._append_csv(record, cumulative_usd=state["cumulative_usd"])
        return cost

    def total(self) -> Decimal:
        return Decimal(self._read_state()["cumulative_usd"])

    def total_value(self) -> str:
        return f"{self.total().quantize(FOUR_DP, rounding=ROUND_HALF_UP):.4f}"

    def check_cap(self) -> bool:
        return check_cost_cap(self.total(), self.config.cost_cap_usd)

    def check_per_call(self, cost: Decimal) -> bool:
        return cost < Decimal(str(self.config.per_call_cap_usd))

    def check_runaway(self) -> bool:
        return self._read_state()["consecutive_high_cost_count"] < self.config.runaway_consecutive

    def summary_text(self) -> str:
        state = self._read_state()
        lines = [f"=== Nightshift Cost Summary: {state['run_id']} ==="]
        for call in state["calls"]:
            lines.append(
                "  "
                f"{call['agent']} ({call['model']})  ${call['cost_usd']} [{call['cost_source']}]  "
                f"({call['input_tokens']} in / {call['cache_create_tokens']} cw / "
                f"{call['cache_read_tokens']} cr / {call['output_tokens']} out)"
            )
        lines.append("  ─────────────────────────────────────────")
        lines.append(f"  Total:  ${state['cumulative_usd']}")
        lines.append(f"  Calls:  {state['call_count']}")
        lines.append(f"  Cap:    ${self.config.cost_cap_usd}")
        return "\n".join(lines)

    def _resolve_rates(self, model: str) -> CostRates:
        normalized_model = model.lower()
        if "opus" in normalized_model:
            return CostRates(
                input_price=Decimal(str(self.config.claude_opus_input_price)),
                output_price=Decimal(str(self.config.claude_opus_output_price)),
                cache_write_price=Decimal(str(self.config.claude_opus_cache_write_price)),
                cache_read_price=Decimal(str(self.config.claude_opus_cache_read_price)),
            )
        if "sonnet" in normalized_model:
            return CostRates(
                input_price=Decimal(str(self.config.claude_sonnet_input_price)),
                output_price=Decimal(str(self.config.claude_sonnet_output_price)),
                cache_write_price=Decimal(str(self.config.claude_sonnet_cache_write_price)),
                cache_read_price=Decimal(str(self.config.claude_sonnet_cache_read_price)),
            )
        if any(family in normalized_model for family in ("codex", "gpt", "openai")):
            return CostRates(
                input_price=Decimal(str(self.config.codex_input_price)),
                output_price=Decimal(str(self.config.codex_output_price)),
                cache_write_price=Decimal("0"),
                cache_read_price=Decimal("0"),
            )
        return CostRates(
            input_price=Decimal(str(self.config.claude_sonnet_input_price)),
            output_price=Decimal(str(self.config.claude_sonnet_output_price)),
            cache_write_price=Decimal(str(self.config.claude_sonnet_cache_write_price)),
            cache_read_price=Decimal(str(self.config.claude_sonnet_cache_read_price)),
        )

    def _read_state(self) -> dict[str, Any]:
        try:
            return json.loads(self.state_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            logger.warning(
                "Cost state file %s is corrupt JSON; resetting state",
                self.state_file,
                exc_info=True,
            )
            state = self._new_state("recovered")
            self._write_state(state)
            return state

    def _write_state(self, state: dict[str, Any]) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.state_file.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(state, indent=2), encoding="utf-8")
        tmp_path.rename(self.state_file)

    def _append_csv(self, record: CostRecord, *, cumulative_usd: str) -> None:
        self.csv_file.parent.mkdir(parents=True, exist_ok=True)
        header = [
            "timestamp",
            "agent",
            "model",
            "playbook",
            "input_tokens",
            "output_tokens",
            "cache_create_tokens",
            "cache_read_tokens",
            "cost_usd",
            "cost_source",
            "cumulative_usd",
        ]
        write_header = not self.csv_file.exists() or self.csv_file.stat().st_size == 0
        with self.csv_file.open("a", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            if write_header:
                writer.writerow(header)
            writer.writerow(
                [
                    record.timestamp,
                    record.agent,
                    record.model,
                    record.playbook,
                    record.input_tokens,
                    record.output_tokens,
                    record.cache_create_tokens,
                    record.cache_read_tokens,
                    record.cost_usd,
                    record.cost_source,
                    cumulative_usd,
                ]
            )

    @staticmethod
    def _timestamp() -> str:
        return datetime.now().strftime("%Y-%m-%dT%H:%M:%S%z")

    @staticmethod
    def _coerce_rate(value: Decimal | float | str | None) -> Decimal:
        if value is None:
            raise ValueError("rate value is required")
        return Decimal(str(value))

    def _new_state(self, run_id: str) -> dict[str, Any]:
        return {
            "run_id": run_id,
            "started_at": self._timestamp(),
            "cumulative_usd": "0.0000",
            "call_count": 0,
            "last_call_cost": "0.0000",
            "consecutive_high_cost_count": 0,
            "calls": [],
        }


def _normalize_as_of_date(as_of_date: date | datetime | str | None) -> str | None:
    if as_of_date is None:
        return None
    if isinstance(as_of_date, datetime):
        return as_of_date.strftime("%Y-%m-%d")
    if isinstance(as_of_date, date):
        return as_of_date.isoformat()
    text = str(as_of_date).strip()
    if not text:
        return None
    datetime.strptime(text, "%Y-%m-%d")
    return text
