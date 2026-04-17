from __future__ import annotations

import argparse
import os
import sys
from datetime import date
from pathlib import Path

from ..config import REPO_ROOT
from ..suppression import (
    annotate_digest_with_fingerprints,
    append_suppression_entry,
    apply_suppressions,
    compute_fingerprint,
    default_expires_date,
    parse_digest_rank_fingerprint,
    validate_fingerprint_for_scope,
    write_apply_artifacts,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Night Shift suppression helpers")
    subparsers = parser.add_subparsers(dest="command", required=True)

    apply_parser = subparsers.add_parser("apply", help="Apply suppressions to canonical findings")
    apply_parser.add_argument("--findings-dir", type=Path, required=True)
    apply_parser.add_argument("--suppressions-file", type=Path, required=True)
    apply_parser.add_argument("--digests-dir", type=Path, required=True)
    apply_parser.add_argument("--run-date", required=True)
    apply_parser.add_argument("--output-dir", type=Path, required=True)

    annotate_parser = subparsers.add_parser("annotate-digest", help="Annotate digest ranks with fingerprints")
    annotate_parser.add_argument("--digest-path", type=Path, required=True)
    annotate_parser.add_argument("--findings-dir", type=Path, required=True)

    add_parser = subparsers.add_parser("add-entry", help="Append a suppression entry")
    add_parser.add_argument("--suppressions-file", type=Path, default=REPO_ROOT / "docs/nightshift/suppressions.yaml")
    add_target = add_parser.add_mutually_exclusive_group(required=True)
    add_target.add_argument("--fingerprint")
    add_target.add_argument("--digest-path", type=Path)
    add_parser.add_argument("--index", help="Rank index inside the digest's Ranked Findings table")
    add_parser.add_argument("--scope", choices=("finding", "rule"), default="finding")
    add_parser.add_argument("--rationale")
    add_parser.add_argument("--added-by")
    add_parser.add_argument("--added-date", default=date.today().isoformat())
    add_parser.add_argument("--expires-date")
    add_parser.add_argument("--reviewed-date")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "apply":
        result = apply_suppressions(
            args.findings_dir,
            suppressions_path=args.suppressions_file,
            digests_dir=args.digests_dir,
            run_date=args.run_date,
        )
        write_apply_artifacts(args.output_dir, result)
        return 0

    if args.command == "annotate-digest":
        annotate_digest_with_fingerprints(args.digest_path, args.findings_dir)
        return 0

    if args.command == "add-entry":
        fingerprint = args.fingerprint
        if args.digest_path is not None:
            if not args.index:
                parser.error("--index is required when --digest-path is used")
            fingerprint, unavailable_reason = parse_digest_rank_fingerprint(args.digest_path, args.index)
            if fingerprint is None:
                raise SystemExit(
                    f"Digest rank {args.index} is not suppressible from index mode: "
                    f"{unavailable_reason or 'missing fingerprint annotation'}"
                )

        if fingerprint is None:
            parser.error("Could not resolve a fingerprint")

        if args.scope == "rule":
            parts = fingerprint.split(":")
            if len(parts) != 4:
                raise SystemExit("Resolved fingerprint is malformed")
            fingerprint = compute_fingerprint(parts[0], parts[1], parts[2], parts[3], scope="rule")
        else:
            validate_fingerprint_for_scope(fingerprint, "finding")

        rationale = args.rationale or _prompt("Rationale (min 20 chars): ")
        added_by = args.added_by or _prompt("Added by: ")
        expires_date = args.expires_date or default_expires_date(args.added_date)

        result = append_suppression_entry(
            args.suppressions_file,
            fingerprint=fingerprint,
            rationale=rationale,
            added_by=added_by,
            added_date=args.added_date,
            expires_date=expires_date,
            scope=args.scope,
            reviewed_date=args.reviewed_date,
        )
        print(result.entry.fingerprint)
        if result.action == "unchanged":
            print(
                f"Suppression already exists with the same rationale and expiry; no changes made: {result.entry.fingerprint}",
                file=sys.stderr,
            )
        elif result.action == "updated":
            print(f"Updated existing suppression entry: {result.entry.fingerprint}", file=sys.stderr)
        return 0

    parser.error(f"Unknown command: {args.command}")
    return 2


def _prompt(prompt_text: str) -> str:
    if not sys.stdin.isatty() and os.environ.get("PYTEST_CURRENT_TEST"):
        raise SystemExit(f"Missing required interactive value: {prompt_text.strip()}")
    return input(prompt_text).strip()


if __name__ == "__main__":
    raise SystemExit(main())
