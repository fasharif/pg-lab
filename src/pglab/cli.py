"""Command line of the lab's Python tooling: python -m pglab <command> (called by ./lab)."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from pglab import casebook, indexing, workload
from pglab.db import connect
from pglab.definitions import Case, WorkloadQuery, load_cases, load_workload
from pglab.errors import CheckError, LabError
from pglab.report import run_info

ROOT = Path(__file__).resolve().parents[2]
WORKLOAD_FILE = ROOT / "workload" / "queries.toml"
CASEBOOK_DIR = ROOT / "casebook"
REPORTS_DIR = ROOT / "reports"


def _definitions() -> tuple[dict[str, WorkloadQuery], list[Case]]:
    queries = load_workload(WORKLOAD_FILE)
    return queries, load_cases(CASEBOOK_DIR, queries)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


def _runs(args: argparse.Namespace) -> int | None:
    return int(args.runs) if args.measure else None


def cmd_validate(_: argparse.Namespace) -> int:
    queries, cases = _definitions()
    print(f"{len(queries)} workload statements and {len(cases)} casebook cases are valid")
    return 0


def cmd_workload(args: argparse.Namespace) -> int:
    queries, cases = _definitions()
    with connect(application_name="pglab-workload") as conn:
        if args.state == "baseline":
            casebook.revert_all(conn, cases)
        elif args.state == "tuned":
            casebook.revert_all(conn, cases)
            casebook.apply_all(conn, cases)
        info = run_info(conn, measured=args.measure, runs=args.runs)
        results = workload.run_workload(conn, queries.values(), runs=_runs(args))
    text = workload.render_report(
        results,
        info,
        command=args.label,
        casebook_queries={case.query.id: case.number for case in cases},
        state=args.state,
    )
    _write(Path(args.output), text)
    for position, result in enumerate(workload.rank(results)[:10], start=1):
        print(f"{position:>2}. {result.query.id:<28} {result.plan.shared_buffers():>12,} buffers")
    return 0


def cmd_casebook(args: argparse.Namespace) -> int:
    _, cases = _definitions()
    if not cases:
        raise LabError(f"no casebook cases in {CASEBOOK_DIR}")
    with connect(application_name="pglab-casebook") as conn:
        info = run_info(conn, measured=args.measure, runs=args.runs)
        results = casebook.run_casebook(conn, cases, runs=_runs(args))
    _write(Path(args.output), casebook.render_report(results, info, command=args.label))
    failed = 0
    for result in results:
        status = "pass" if result.passed else "FAIL"
        print(f"case {result.case.number:>2} {result.case.query.id:<28} {status}")
        for failure in result.before.failures:
            print(f"      before: {failure}")
        for failure in result.after.failures:
            print(f"      after:  {failure}")
        failed += 0 if result.passed else 1
    if failed:
        raise CheckError(f"{failed} casebook case(s) failed their plan checks")
    return 0


def cmd_casebook_state(args: argparse.Namespace) -> int:
    _, cases = _definitions()
    with connect(application_name="pglab-casebook") as conn:
        casebook.revert_all(conn, cases)
        if args.state == "tuned":
            casebook.apply_all(conn, cases)
    print(f"schema is now in the {args.state} state")
    return 0


def cmd_index_report(args: argparse.Namespace) -> int:
    _, cases = _definitions()
    # CHECKPOINT (for comparable WAL probes) needs a superuser or pg_checkpoint.
    with connect("postgres", application_name="pglab-indexing") as conn:
        info = run_info(conn, measured=False, runs=0)
        report = indexing.build_report(conn, cases)
    _write(Path(args.output), indexing.render_report(report, info, command=args.label))
    for name in indexing.PROBES:
        before, after = report.baseline[name], report.tuned[name]
        print(
            f"{name:<12} WAL per row {before.bytes_per_row:,.0f} B -> {after.bytes_per_row:,.0f} B"
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pglab", description=__doc__)
    parser.add_argument("--label", default=None, help="command shown in report headers")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("validate", help="check the workload and casebook definitions").set_defaults(
        func=cmd_validate
    )

    def timing_options(p: argparse.ArgumentParser) -> None:
        p.add_argument(
            "--measure",
            action="store_true",
            help="record median execution times (quiet machine only)",
        )
        p.add_argument("--runs", type=int, default=15, help="timed runs per statement (default 15)")

    p = sub.add_parser("workload", help="rank the workload statements by buffers touched")
    p.add_argument("--state", choices=("baseline", "tuned", "current"), default="baseline")
    p.add_argument("--output", default=str(REPORTS_DIR / "workload.md"))
    timing_options(p)
    p.set_defaults(func=cmd_workload)

    p = sub.add_parser("casebook", help="before/after plans of the casebook cases")
    p.add_argument("--output", default=str(REPORTS_DIR / "casebook.md"))
    timing_options(p)
    p.set_defaults(func=cmd_casebook)

    p = sub.add_parser("index-report", help="index sizes and WAL per inserted row")
    p.add_argument("--output", default=str(REPORTS_DIR / "indexing.md"))
    p.set_defaults(func=cmd_index_report)

    p = sub.add_parser("casebook-state", help="revert (baseline) or apply (tuned) every fix")
    p.add_argument("state", choices=("baseline", "tuned"))
    p.set_defaults(func=cmd_casebook_state)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.label is None:
        args.label = "python -m pglab " + " ".join(sys.argv[1:] if argv is None else argv)
    if getattr(args, "runs", 1) < 1:
        parser.error("--runs must be at least 1")
    try:
        return int(args.func(args))
    except CheckError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except LabError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
