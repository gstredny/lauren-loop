from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Iterable

import yaml


SUPPRESSED_FINDINGS_HEADING = "## Suppressed Findings (Audit Only)"
EXPIRED_SUPPRESSIONS_HEADING = "## Expired Suppressions"
EXPIRING_SOON_HEADING = "## Expiring Soon"
FINDINGS_MISSING_RULE_KEY_HEADING = "## Findings Missing Rule Key"

_FINDING_HEADING_RE = re.compile(r"^### Finding(?::|\s+\d+:)\s*(.*\S)?\s*$")
_RULE_KEY_RE = re.compile(r"^\*\*Rule Key:\*\*\s*(.*\S)\s*$")
_PRIMARY_FILE_RE = re.compile(r"^\*\*Primary File:\*\*\s*(.*\S)\s*$")
_SEVERITY_RE = re.compile(r"^\*\*Severity:\*\*\s*(.*\S)\s*$")
_CATEGORY_RE = re.compile(r"^\*\*Category:\*\*\s*(.*\S)\s*$")
_EVIDENCE_RE = re.compile(r"^\*\*Evidence:\*\*\s*$")
_SOURCE_RE = re.compile(r"^## Source:\s*(.*\S)\s*$")
_RANKED_DETAIL_HEADING_RE = re.compile(r"^###\s+(\d+)\.\s+(.*\S)\s*$")
_DIGEST_FINGERPRINT_RE = re.compile(r"^<!-- nightshift:fingerprint (.+) -->$")
_DIGEST_UNAVAILABLE_RE = re.compile(r"^<!-- nightshift:fingerprint unavailable reason=(.+) -->$")
_REPO_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_./+-])((?:[A-Za-z0-9_+-]+/)*[A-Za-z0-9_+-]*\.[A-Za-z0-9_.+-]+):\d+(?:-\d+)?(?![A-Za-z0-9_./+-])"
)


@dataclass(frozen=True)
class SuppressionEntry:
    fingerprint: str
    rationale: str
    added_by: str
    added_date: str
    expires_date: str
    reviewed_date: str | None = None
    scope: str = "finding"


@dataclass(frozen=True)
class AppendSuppressionEntryResult:
    entry: SuppressionEntry
    action: str


@dataclass(frozen=True)
class FindingRecord:
    detective_name: str
    source_name: str
    title: str
    severity: str
    category: str
    rule_key: str | None
    primary_file: str | None
    raw_block: str
    finding_fingerprint: str | None
    rule_fingerprint: str | None
    suppressible: bool
    suppressible_reason: str


@dataclass(frozen=True)
class SuppressedFinding:
    fingerprint: str
    title: str
    detective_name: str
    category: str
    primary_file: str | None
    rule_key: str
    rationale: str
    expires_date: str
    scope: str
    runs_since_added: int


@dataclass(frozen=True)
class DigestAnnotation:
    rank: str
    title: str
    fingerprint: str | None
    reason: str | None


@dataclass(frozen=True)
class ApplySuppressionsResult:
    raw_total: int
    eligible_total: int
    suppressed_count: int
    warnings: tuple[str, ...]
    suppressed_findings: tuple[SuppressedFinding, ...]
    expired_suppressions: tuple[SuppressionEntry, ...]
    expiring_soon: tuple[SuppressionEntry, ...]
    missing_rule_key_findings: tuple[FindingRecord, ...]
    unsuppressible_findings: tuple[FindingRecord, ...]
    unsuppressed_findings: tuple[FindingRecord, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "raw_total": self.raw_total,
            "eligible_total": self.eligible_total,
            "suppressed_count": self.suppressed_count,
            "warnings": list(self.warnings),
            "suppressed_findings": [asdict(item) for item in self.suppressed_findings],
            "expired_suppressions": [asdict(item) for item in self.expired_suppressions],
            "expiring_soon": [asdict(item) for item in self.expiring_soon],
            "missing_rule_key_findings": [asdict(item) for item in self.missing_rule_key_findings],
            "unsuppressible_findings": [asdict(item) for item in self.unsuppressible_findings],
            "unsuppressed_findings": [asdict(item) for item in self.unsuppressed_findings],
        }


def compute_fingerprint(
    detective_name: str,
    category: str,
    primary_file: str | None,
    rule_key: str,
    *,
    scope: str = "finding",
) -> str:
    normalized_scope = scope.strip().lower()
    if normalized_scope not in {"finding", "rule"}:
        raise ValueError(f"Unsupported suppression scope: {scope}")
    if normalized_scope == "finding":
        if not primary_file:
            raise ValueError("Finding-scope fingerprints require a primary file")
        if primary_file == "*":
            raise ValueError("Finding-scope fingerprints must not use '*' in the file slot")
        file_slot = primary_file
    else:
        file_slot = "*"
    parts = [detective_name.strip(), category.strip(), file_slot.strip(), rule_key.strip()]
    if any(not part for part in parts):
        raise ValueError("Fingerprint parts must be non-empty")
    return ":".join(parts)


def validate_fingerprint_for_scope(fingerprint: str, scope: str) -> None:
    parts = fingerprint.split(":")
    if len(parts) != 4:
        raise ValueError("Fingerprints must contain exactly four ':'-separated parts")
    if any(not part for part in parts):
        raise ValueError("Fingerprint parts must be non-empty")
    file_slot = parts[2]
    normalized_scope = scope.strip().lower()
    if normalized_scope == "finding" and file_slot == "*":
        raise ValueError("scope=finding fingerprints must not use '*' in the file slot")
    if normalized_scope == "rule" and file_slot != "*":
        raise ValueError("scope=rule fingerprints must use '*' in the file slot")


def load_suppressions(
    suppressions_path: Path,
    *,
    today: date,
) -> tuple[list[SuppressionEntry], list[SuppressionEntry], list[SuppressionEntry], list[str]]:
    if not suppressions_path.exists():
        return [], [], [], []

    try:
        parsed = yaml.safe_load(suppressions_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return [], [], [], [f"Suppression file parse error in {suppressions_path}: {exc}"]
    except OSError as exc:
        return [], [], [], [f"Suppression file read error in {suppressions_path}: {exc}"]

    if parsed in (None, ""):
        return [], [], [], []
    if not isinstance(parsed, list):
        return [], [], [], [f"Suppression file must contain a top-level YAML list: {suppressions_path}"]

    active: list[SuppressionEntry] = []
    expired: list[SuppressionEntry] = []
    expiring_soon: list[SuppressionEntry] = []
    warnings: list[str] = []
    active_by_fingerprint: dict[str, SuppressionEntry] = {}

    for index, raw_entry in enumerate(parsed, start=1):
        if not isinstance(raw_entry, dict):
            warnings.append(f"Suppression entry #{index} is not a mapping and was ignored")
            continue
        try:
            entry = _parse_suppression_entry(raw_entry)
        except ValueError as exc:
            warnings.append(f"Suppression entry #{index} is invalid: {exc}")
            continue

        expiry = date.fromisoformat(entry.expires_date)
        if expiry < today:
            expired.append(entry)
            warnings.append(f"Suppression expired and was not applied: {entry.fingerprint} (expired {entry.expires_date})")
            continue

        if (expiry - today).days <= 14:
            expiring_soon.append(entry)

        previous = active_by_fingerprint.get(entry.fingerprint)
        if previous is not None:
            warnings.append(f"Duplicate active suppression fingerprint detected; later entry wins: {entry.fingerprint}")
        active_by_fingerprint[entry.fingerprint] = entry

    active = list(active_by_fingerprint.values())
    return active, expired, expiring_soon, warnings


def parse_findings_dir(findings_dir: Path) -> list[FindingRecord]:
    findings: list[FindingRecord] = []
    for path in sorted(findings_dir.glob("*-findings.md")):
        detective_name = path.name.removesuffix("-findings.md")
        findings.extend(parse_findings_file(path, detective_name=detective_name))
    return findings


def parse_findings_file(path: Path, *, detective_name: str) -> list[FindingRecord]:
    text = path.read_text(encoding="utf-8")
    current_source = detective_name
    records: list[FindingRecord] = []
    current_block: list[str] = []

    for line in text.splitlines():
        source_match = _SOURCE_RE.match(line)
        if source_match:
            if current_block:
                records.append(_parse_finding_block("\n".join(current_block), detective_name=detective_name, source_name=current_source))
                current_block = []
            current_source = source_match.group(1)
            continue

        if _FINDING_HEADING_RE.match(line):
            if current_block:
                records.append(_parse_finding_block("\n".join(current_block), detective_name=detective_name, source_name=current_source))
            current_block = [line]
            continue

        if current_block:
            current_block.append(line)

    if current_block:
        records.append(_parse_finding_block("\n".join(current_block), detective_name=detective_name, source_name=current_source))
    return records


def apply_suppressions(
    findings_dir: Path,
    *,
    suppressions_path: Path,
    digests_dir: Path,
    run_date: str,
    today: date | None = None,
) -> ApplySuppressionsResult:
    current_day = today or date.fromisoformat(run_date)
    findings = parse_findings_dir(findings_dir)
    raw_total = len(findings)

    active_suppressions, expired_suppressions, expiring_soon, warnings = load_suppressions(
        suppressions_path,
        today=current_day,
    )

    active_by_fingerprint = {entry.fingerprint: entry for entry in active_suppressions}
    prior_counts, prior_warning = load_prior_runs_since_added(
        digests_dir=digests_dir,
        run_date=run_date,
        fingerprints=[entry.fingerprint for entry in active_suppressions],
    )
    if prior_warning:
        warnings.append(prior_warning)

    suppressed_findings: list[SuppressedFinding] = []
    unsuppressed_findings: list[FindingRecord] = []
    missing_rule_key_findings: list[FindingRecord] = []
    unsuppressible_findings: list[FindingRecord] = []

    for finding in findings:
        if not finding.rule_key:
            missing_rule_key_findings.append(finding)
            unsuppressible_findings.append(finding)
            warnings.append(
                f"Finding missing Rule Key is not suppressible and flowed through ranking: "
                f"{finding.detective_name} / {finding.title}"
            )
            unsuppressed_findings.append(finding)
            continue

        matched_entry = None
        if finding.finding_fingerprint:
            matched_entry = active_by_fingerprint.get(finding.finding_fingerprint)
        if matched_entry is None and finding.rule_fingerprint:
            matched_entry = active_by_fingerprint.get(finding.rule_fingerprint)

        if matched_entry is None:
            if not finding.suppressible:
                unsuppressible_findings.append(finding)
                warnings.append(
                    f"Finding could not compute a finding-scope fingerprint and flowed through ranking: "
                    f"{finding.detective_name} / {finding.title} ({finding.suppressible_reason})"
                )
            unsuppressed_findings.append(finding)
            continue

        runs_since_added = prior_counts.get(matched_entry.fingerprint, 0) + 1
        suppressed_findings.append(
            SuppressedFinding(
                fingerprint=matched_entry.fingerprint,
                title=finding.title,
                detective_name=finding.detective_name,
                category=finding.category,
                primary_file=finding.primary_file,
                rule_key=finding.rule_key,
                rationale=matched_entry.rationale,
                expires_date=matched_entry.expires_date,
                scope=matched_entry.scope,
                runs_since_added=runs_since_added,
            )
        )

    rewrite_findings_dir_with_unsuppressed(findings_dir, unsuppressed_findings)

    return ApplySuppressionsResult(
        raw_total=raw_total,
        eligible_total=len(unsuppressed_findings),
        suppressed_count=len(suppressed_findings),
        warnings=tuple(dict.fromkeys(warnings)),
        suppressed_findings=tuple(suppressed_findings),
        expired_suppressions=tuple(expired_suppressions),
        expiring_soon=tuple(expiring_soon),
        missing_rule_key_findings=tuple(missing_rule_key_findings),
        unsuppressible_findings=tuple(unsuppressible_findings),
        unsuppressed_findings=tuple(unsuppressed_findings),
    )


def load_prior_runs_since_added(
    *,
    digests_dir: Path,
    run_date: str,
    fingerprints: Iterable[str],
) -> tuple[dict[str, int], str | None]:
    wanted = set(fingerprints)
    if not wanted:
        return {}, None

    prior_digest = find_prior_digest(digests_dir=digests_dir, run_date=run_date)
    if prior_digest is None:
        return {}, None

    try:
        parsed = parse_suppressed_runs_from_digest(prior_digest)
    except ValueError as exc:
        return {}, f"Prior digest suppressed-runs parsing failed for {prior_digest.name}; defaulted runs-since-added to 1: {exc}"
    except OSError as exc:
        return {}, f"Prior digest suppressed-runs parsing failed for {prior_digest.name}; defaulted runs-since-added to 1: {exc}"

    return {fingerprint: parsed[fingerprint] for fingerprint in wanted if fingerprint in parsed}, None


def find_prior_digest(*, digests_dir: Path, run_date: str) -> Path | None:
    same_day = digests_dir / f"{run_date}.md"
    if same_day.exists():
        return same_day
    candidates = sorted(path for path in digests_dir.glob("*.md") if path.name < f"{run_date}.md")
    return candidates[-1] if candidates else None


def parse_suppressed_runs_from_digest(digest_path: Path) -> dict[str, int]:
    text = digest_path.read_text(encoding="utf-8")
    section_lines = _extract_section_lines(text, SUPPRESSED_FINDINGS_HEADING)
    if section_lines is None:
        return {}

    header_seen = False
    runs_by_fingerprint: dict[str, int] = {}
    for line in section_lines:
        if not line.startswith("|"):
            if line.strip():
                raise ValueError("suppressed findings section is not a Markdown table")
            continue
        if line.startswith("|---") or line.startswith("| ---"):
            continue
        columns = [column.strip() for column in line.split("|")[1:-1]]
        if not header_seen:
            if len(columns) < 5 or columns[0] != "Fingerprint" or columns[4] != "Runs Since Added":
                raise ValueError("suppressed findings table header is malformed")
            header_seen = True
            continue
        if len(columns) < 5:
            raise ValueError("suppressed findings table row is malformed")
        fingerprint = columns[0]
        try:
            runs_by_fingerprint[fingerprint] = int(columns[4])
        except ValueError as exc:
            raise ValueError(f"invalid runs-since-added value for {fingerprint}") from exc
    if not header_seen:
        raise ValueError("suppressed findings table header missing")
    return runs_by_fingerprint


def rewrite_findings_dir_with_unsuppressed(findings_dir: Path, unsuppressed_findings: Iterable[FindingRecord]) -> None:
    findings_by_detective: dict[str, list[FindingRecord]] = {}
    for finding in unsuppressed_findings:
        findings_by_detective.setdefault(finding.detective_name, []).append(finding)

    for path in sorted(findings_dir.glob("*-findings.md")):
        detective_name = path.name.removesuffix("-findings.md")
        original_text = path.read_text(encoding="utf-8")
        rewritten = rewrite_findings_file_text(
            original_text,
            kept_findings=findings_by_detective.get(detective_name, []),
        )
        path.write_text(rewritten, encoding="utf-8")


def rewrite_findings_file_text(original_text: str, *, kept_findings: Iterable[FindingRecord]) -> str:
    if "## Source:" not in original_text and "### Finding" not in original_text:
        return original_text if original_text.endswith("\n") else f"{original_text}\n"

    prefix_lines: list[str] = []
    source_order: list[str] = []
    source_headings: dict[str, str] = {}
    before_sources = True

    for line in original_text.splitlines():
        source_match = _SOURCE_RE.match(line)
        if source_match:
            before_sources = False
            source_name = source_match.group(1)
            source_order.append(source_name)
            source_headings[source_name] = line
            continue
        if before_sources:
            prefix_lines.append(line)

    kept_by_source: dict[str, list[FindingRecord]] = {}
    for finding in kept_findings:
        kept_by_source.setdefault(finding.source_name, []).append(finding)

    output_lines = [line for line in prefix_lines]
    if not any(kept_by_source.values()):
        note = "_No findings reported after suppression._"
        while output_lines and output_lines[-1] == "":
            output_lines.pop()
        output_lines.extend(["", note])
        return "\n".join(output_lines).rstrip() + "\n"

    while output_lines and output_lines[-1] == "":
        output_lines.pop()
    output_lines.append("")

    for source_name in source_order:
        source_findings = kept_by_source.get(source_name)
        if not source_findings:
            continue
        output_lines.append(source_headings[source_name])
        output_lines.append("")
        for index, finding in enumerate(source_findings):
            output_lines.extend(finding.raw_block.strip().splitlines())
            if index != len(source_findings) - 1:
                output_lines.append("")
                output_lines.append("")
        output_lines.append("")
        output_lines.append("")

    return "\n".join(output_lines).rstrip() + "\n"


def render_suppressed_findings_section(result: ApplySuppressionsResult) -> str:
    lines = [
        SUPPRESSED_FINDINGS_HEADING,
        "",
        "| Fingerprint | Title | Expires | Rationale | Runs Since Added |",
        "|-------------|-------|---------|-----------|-----------------:|",
    ]
    if result.suppressed_findings:
        for finding in result.suppressed_findings:
            lines.append(
                f"| {finding.fingerprint} | {finding.title} | {finding.expires_date} | "
                f"{_escape_table_cell(finding.rationale)} | {finding.runs_since_added} |"
            )
    else:
        lines.append("| (none) | (none) | (none) | (none) | 0 |")
    return "\n".join(lines)


def render_expired_suppressions_section(result: ApplySuppressionsResult) -> str:
    lines = [
        EXPIRED_SUPPRESSIONS_HEADING,
        "",
        "| Fingerprint | Scope | Expires | Rationale |",
        "|-------------|-------|---------|-----------|",
    ]
    if result.expired_suppressions:
        for entry in result.expired_suppressions:
            lines.append(
                f"| {entry.fingerprint} | {entry.scope} | {entry.expires_date} | "
                f"{_escape_table_cell(entry.rationale)} |"
            )
    else:
        lines.append("| (none) | (none) | (none) | (none) |")
    return "\n".join(lines)


def render_expiring_soon_section(result: ApplySuppressionsResult) -> str:
    lines = [
        EXPIRING_SOON_HEADING,
        "",
        "| Fingerprint | Scope | Expires | Added By |",
        "|-------------|-------|---------|----------|",
    ]
    if result.expiring_soon:
        for entry in result.expiring_soon:
            lines.append(f"| {entry.fingerprint} | {entry.scope} | {entry.expires_date} | {entry.added_by} |")
    else:
        lines.append("| (none) | (none) | (none) | (none) |")
    return "\n".join(lines)


def render_findings_missing_rule_key_section(result: ApplySuppressionsResult) -> str:
    lines = [
        FINDINGS_MISSING_RULE_KEY_HEADING,
        "",
        "| Detective | Category | Title | Primary File |",
        "|-----------|----------|-------|--------------|",
    ]
    if result.missing_rule_key_findings:
        for finding in result.missing_rule_key_findings:
            lines.append(
                f"| {finding.detective_name} | {finding.category} | {finding.title} | {finding.primary_file or '(none)'} |"
            )
    else:
        lines.append("| (none) | (none) | (none) | (none) |")
    return "\n".join(lines)


def annotate_digest_with_fingerprints(digest_path: Path, findings_dir: Path) -> list[DigestAnnotation]:
    text = digest_path.read_text(encoding="utf-8")
    findings = parse_findings_dir(findings_dir)
    annotations = build_digest_annotations(text, findings=findings)
    digest_path.write_text(apply_digest_annotations(text, annotations), encoding="utf-8")
    return annotations


def build_digest_annotations(digest_text: str, *, findings: Iterable[FindingRecord]) -> list[DigestAnnotation]:
    finding_list = list(findings)
    rank_sections = _extract_rank_sections(digest_text)
    annotations: list[DigestAnnotation] = []
    for rank, _severity, _category, title in manager_top_findings_from_digest_from_text(digest_text):
        section_text = rank_sections.get(rank, "")
        if not _rank_section_is_single_source(section_text):
            annotations.append(
                DigestAnnotation(rank=rank, title=title, fingerprint=None, reason="digest-rank-not-single-source")
            )
            continue
        matches = _match_findings_by_title(title, finding_list)
        if len(matches) == 1:
            match = matches[0]
            if match.finding_fingerprint:
                annotations.append(DigestAnnotation(rank=rank, title=title, fingerprint=match.finding_fingerprint, reason=None))
            else:
                annotations.append(
                    DigestAnnotation(rank=rank, title=title, fingerprint=None, reason=match.suppressible_reason)
                )
            continue
        reason = "non-unique-title-match" if len(matches) > 1 else "no-raw-finding-match"
        annotations.append(DigestAnnotation(rank=rank, title=title, fingerprint=None, reason=reason))
    return annotations


def apply_digest_annotations(digest_text: str, annotations: Iterable[DigestAnnotation]) -> str:
    by_rank = {annotation.rank: annotation for annotation in annotations}
    output_lines: list[str] = []
    lines = digest_text.splitlines()
    skip_next_comment = False

    for index, line in enumerate(lines):
        if skip_next_comment and (_DIGEST_FINGERPRINT_RE.match(line) or _DIGEST_UNAVAILABLE_RE.match(line)):
            skip_next_comment = False
            continue

        output_lines.append(line)
        match = _RANKED_DETAIL_HEADING_RE.match(line)
        if not match:
            continue
        rank = match.group(1)
        annotation = by_rank.get(rank)
        if annotation is None:
            continue
        next_line = lines[index + 1] if index + 1 < len(lines) else ""
        if _DIGEST_FINGERPRINT_RE.match(next_line) or _DIGEST_UNAVAILABLE_RE.match(next_line):
            skip_next_comment = True
        if annotation.fingerprint:
            output_lines.append(f"<!-- nightshift:fingerprint {annotation.fingerprint} -->")
        else:
            output_lines.append(
                f"<!-- nightshift:fingerprint unavailable reason={annotation.reason or 'unknown'} -->"
            )
    return "\n".join(output_lines).rstrip() + "\n"


def parse_digest_rank_fingerprint(digest_path: Path, rank: str) -> tuple[str | None, str | None]:
    current_rank: str | None = None
    lines = digest_path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        detail_match = _RANKED_DETAIL_HEADING_RE.match(line)
        if detail_match:
            current_rank = detail_match.group(1)
            continue
        if current_rank != rank:
            continue
        if unavailable_match := _DIGEST_UNAVAILABLE_RE.match(line):
            return None, unavailable_match.group(1)
        if fingerprint_match := _DIGEST_FINGERPRINT_RE.match(line):
            return fingerprint_match.group(1), None
        if line.startswith("### ") or line.startswith("## "):
            break
    return None, "digest-rank-missing-fingerprint-annotation"


def append_suppression_entry(
    suppressions_path: Path,
    *,
    fingerprint: str,
    rationale: str,
    added_by: str,
    added_date: str,
    expires_date: str,
    scope: str,
    reviewed_date: str | None = None,
) -> AppendSuppressionEntryResult:
    entry = SuppressionEntry(
        fingerprint=fingerprint,
        rationale=rationale,
        added_by=added_by,
        added_date=added_date,
        expires_date=expires_date,
        reviewed_date=reviewed_date,
        scope=scope,
    )
    validate_fingerprint_for_scope(entry.fingerprint, entry.scope)
    _validate_rationale(entry.rationale)
    date.fromisoformat(entry.added_date)
    date.fromisoformat(entry.expires_date)
    if entry.reviewed_date:
        date.fromisoformat(entry.reviewed_date)

    existing: list[Any]
    if suppressions_path.exists():
        parsed = yaml.safe_load(suppressions_path.read_text(encoding="utf-8"))
        if parsed in (None, ""):
            existing = []
        elif isinstance(parsed, list):
            existing = list(parsed)
        else:
            raise ValueError(f"Suppression file must contain a top-level list: {suppressions_path}")
    else:
        existing = []

    replacement = asdict(entry)
    for index, raw_entry in enumerate(existing):
        if not isinstance(raw_entry, dict):
            continue
        try:
            parsed_entry = _parse_suppression_entry(raw_entry)
        except ValueError:
            continue
        if parsed_entry.fingerprint != entry.fingerprint:
            continue
        if (
            parsed_entry.rationale == entry.rationale
            and parsed_entry.expires_date == entry.expires_date
        ):
            return AppendSuppressionEntryResult(entry=entry, action="unchanged")
        existing[index] = replacement
        suppressions_path.parent.mkdir(parents=True, exist_ok=True)
        suppressions_path.write_text(
            yaml.safe_dump(existing, sort_keys=False, default_flow_style=False),
            encoding="utf-8",
        )
        return AppendSuppressionEntryResult(entry=entry, action="updated")

    existing.append(replacement)
    suppressions_path.parent.mkdir(parents=True, exist_ok=True)
    suppressions_path.write_text(
        yaml.safe_dump(existing, sort_keys=False, default_flow_style=False),
        encoding="utf-8",
    )
    return AppendSuppressionEntryResult(entry=entry, action="added")


def default_expires_date(added_date: str) -> str:
    return (date.fromisoformat(added_date) + timedelta(days=90)).isoformat()


def write_apply_artifacts(output_dir: Path, result: ApplySuppressionsResult) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "report.json").write_text(json.dumps(result.to_dict(), indent=2) + "\n", encoding="utf-8")
    (output_dir / "suppressed-findings.md").write_text(render_suppressed_findings_section(result) + "\n", encoding="utf-8")
    (output_dir / "expired-suppressions.md").write_text(render_expired_suppressions_section(result) + "\n", encoding="utf-8")
    (output_dir / "expiring-soon.md").write_text(render_expiring_soon_section(result) + "\n", encoding="utf-8")
    (output_dir / "missing-rule-key.md").write_text(
        render_findings_missing_rule_key_section(result) + "\n",
        encoding="utf-8",
    )


def manager_top_findings_from_digest_from_text(digest_text: str) -> list[tuple[str, str, str, str]]:
    in_table = False
    header_seen = False
    rank_col = sev_col = cat_col = title_col = -1
    results: list[tuple[str, str, str, str]] = []
    for line in digest_text.splitlines():
        if line.strip() == "## Ranked Findings":
            in_table = True
            continue
        if in_table and line.startswith("## "):
            break
        if not in_table or not line.startswith("|") or line.startswith("|---") or line.startswith("| ---"):
            continue
        columns = [column.strip() for column in line.split("|")]
        if not header_seen:
            for index, column in enumerate(columns):
                lowered = column.lower()
                if lowered == "#":
                    rank_col = index
                elif lowered == "severity":
                    sev_col = index
                elif lowered == "category":
                    cat_col = index
                elif lowered == "title":
                    title_col = index
            if min(rank_col, sev_col, cat_col, title_col) >= 0:
                header_seen = True
            continue
        if max(rank_col, sev_col, cat_col, title_col) >= len(columns):
            continue
        rank, severity, category, title = (
            columns[rank_col],
            columns[sev_col],
            columns[cat_col],
            columns[title_col],
        )
        if rank and severity and category and title:
            results.append((rank, severity, category, title))
    return results


def _parse_suppression_entry(raw_entry: dict[str, Any]) -> SuppressionEntry:
    fingerprint = _require_string(raw_entry, "fingerprint")
    rationale = _require_string(raw_entry, "rationale")
    added_by = _require_string(raw_entry, "added_by")
    added_date = _require_iso_date_value(raw_entry, "added_date")
    expires_date = _require_iso_date_value(raw_entry, "expires_date")
    reviewed_date = _optional_iso_date_value(raw_entry, "reviewed_date")
    scope = _optional_string(raw_entry, "scope") or "finding"
    if scope not in {"finding", "rule"}:
        raise ValueError("scope must be one of: finding, rule")
    validate_fingerprint_for_scope(fingerprint, scope)
    _validate_rationale(rationale)
    return SuppressionEntry(
        fingerprint=fingerprint,
        rationale=rationale,
        added_by=added_by,
        added_date=added_date,
        expires_date=expires_date,
        reviewed_date=reviewed_date,
        scope=scope,
    )


def _parse_finding_block(block_text: str, *, detective_name: str, source_name: str) -> FindingRecord:
    lines = block_text.strip().splitlines()
    title_match = _FINDING_HEADING_RE.match(lines[0]) if lines else None
    title = (title_match.group(1) if title_match and title_match.group(1) else "").strip()
    severity = ""
    category = ""
    rule_key: str | None = None
    primary_file_override: str | None = None
    evidence_bullets: list[str] = []
    in_evidence = False

    for line in lines[1:]:
        if severity_match := _SEVERITY_RE.match(line):
            severity = severity_match.group(1).strip()
            in_evidence = False
            continue
        if category_match := _CATEGORY_RE.match(line):
            category = category_match.group(1).strip()
            in_evidence = False
            continue
        if rule_match := _RULE_KEY_RE.match(line):
            rule_key = rule_match.group(1).strip()
            in_evidence = False
            continue
        if primary_match := _PRIMARY_FILE_RE.match(line):
            primary_file_override = primary_match.group(1).strip().strip("`")
            in_evidence = False
            continue
        if _EVIDENCE_RE.match(line):
            in_evidence = True
            continue
        if line.startswith("**") and ":**" in line:
            in_evidence = False
            continue
        if in_evidence and line.startswith("- "):
            evidence_bullets.append(line[2:].strip())
            continue
        if in_evidence and evidence_bullets and (line.startswith("  ") or line.startswith("\t")):
            evidence_bullets[-1] = f"{evidence_bullets[-1]} {line.strip()}"

    primary_file = primary_file_override or _extract_primary_file_from_bullets(evidence_bullets)
    finding_fingerprint: str | None = None
    rule_fingerprint: str | None = None
    suppressible = True
    suppressible_reason = "suppressible"

    if rule_key:
        rule_fingerprint = compute_fingerprint(
            detective_name,
            category,
            primary_file,
            rule_key,
            scope="rule",
        )
        if primary_file:
            finding_fingerprint = compute_fingerprint(
                detective_name,
                category,
                primary_file,
                rule_key,
                scope="finding",
            )
        else:
            suppressible = False
            suppressible_reason = "missing-primary-file"
    else:
        suppressible = False
        suppressible_reason = "missing-rule-key"

    return FindingRecord(
        detective_name=detective_name,
        source_name=source_name,
        title=title,
        severity=severity,
        category=category,
        rule_key=rule_key,
        primary_file=primary_file,
        raw_block=block_text.strip(),
        finding_fingerprint=finding_fingerprint,
        rule_fingerprint=rule_fingerprint,
        suppressible=suppressible,
        suppressible_reason=suppressible_reason,
    )


def _match_findings_by_title(title: str, findings: Iterable[FindingRecord]) -> list[FindingRecord]:
    finding_list = list(findings)
    exact = [finding for finding in finding_list if finding.title == title]
    if exact:
        return exact
    lowered_title = title.lower()
    nocase = [finding for finding in finding_list if finding.title.lower() == lowered_title]
    if nocase:
        return nocase
    normalized_title = _normalize_match_text(title)
    return [finding for finding in finding_list if _normalize_match_text(finding.title) == normalized_title]


def _normalize_match_text(text: str) -> str:
    return " ".join(" ".join(line.lower().split()) for line in text.splitlines() if line.strip())


def _extract_rank_sections(digest_text: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_rank: str | None = None
    for line in digest_text.splitlines():
        heading_match = _RANKED_DETAIL_HEADING_RE.match(line)
        if heading_match:
            current_rank = heading_match.group(1)
            sections[current_rank] = [line]
            continue
        if current_rank is not None and line.startswith("### "):
            current_rank = None
        if current_rank is not None and line.startswith("## "):
            current_rank = None
        if current_rank is not None:
            sections[current_rank].append(line)
    return {rank: "\n".join(lines) for rank, lines in sections.items()}


def _rank_section_is_single_source(section_text: str) -> bool:
    if not section_text:
        return False
    if "**Source Detectives:**" in section_text:
        return False
    return "**Source Detective:**" in section_text or "**Source:**" in section_text


def _extract_primary_file_from_bullets(evidence_bullets: list[str]) -> str | None:
    if not evidence_bullets:
        return None
    first_bullet = evidence_bullets[0].replace("`", "")
    match = _REPO_PATH_RE.search(first_bullet)
    if not match:
        return None
    return match.group(1)


def _extract_section_lines(text: str, heading: str) -> list[str] | None:
    capture = False
    lines: list[str] = []
    for line in text.splitlines():
        if line.strip() == heading:
            capture = True
            continue
        if capture and line.startswith("## "):
            break
        if capture:
            lines.append(line)
    return lines if capture else None


def _escape_table_cell(text: str) -> str:
    return text.replace("|", "\\|")


def _require_string(raw_entry: dict[str, Any], key: str) -> str:
    value = raw_entry.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} is required")
    return value.strip()


def _optional_string(raw_entry: dict[str, Any], key: str) -> str | None:
    value = raw_entry.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string when provided")
    stripped = value.strip()
    return stripped or None


def _validate_rationale(rationale: str) -> None:
    if len(rationale.strip()) < 20:
        raise ValueError("rationale must be at least 20 characters")


def _require_iso_date_value(raw_entry: dict[str, Any], key: str) -> str:
    value = raw_entry.get(key)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, str) and value.strip():
        return date.fromisoformat(value.strip()).isoformat()
    raise ValueError(f"{key} is required")


def _optional_iso_date_value(raw_entry: dict[str, Any], key: str) -> str | None:
    value = raw_entry.get(key)
    if value is None:
        return None
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return None
        return date.fromisoformat(stripped).isoformat()
    raise ValueError(f"{key} must be an ISO date string when provided")
