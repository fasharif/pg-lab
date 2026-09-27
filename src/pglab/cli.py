"""Command line of the lab's Python tooling: python -m pglab <command> (called by ./lab)."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence
from datetime import UTC, date, datetime
from pathlib import Path

import psycopg

from pglab import (
    casebook,
    dataset,
    drills,
    heartbeat,
    indexing,
    monitoring,
    mssql,
    partitioning,
    rls,
    workload,
)
from pglab.db import Connection, connect, scalar
from pglab.definitions import Case, WorkloadQuery, load_cases, load_workload
from pglab.errors import CheckError, LabError
from pglab.report import RunInfo, run_info

ROOT = Path(__file__).resolve().parents[2]
WORKLOAD_FILE = ROOT / "workload" / "queries.toml"
CASEBOOK_DIR = ROOT / "casebook"
# ./lab ci points this at out/reports so that CI runs never rewrite the committed reports.
REPORTS_DIR = Path(os.environ.get("LAB_REPORTS_DIR") or ROOT / "reports")


def _definitions() -> tuple[dict[str, WorkloadQuery], list[Case]]:
    queries = load_workload(WORKLOAD_FILE)
    return queries, load_cases(CASEBOOK_DIR, queries)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


def iso_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD): {value!r}") from exc


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
        casebook_queries=workload.casebook_labels(cases),
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
        if result.equivalence is not None and not result.equivalence.same:
            print(f"      rewrite: {result.equivalence.describe()}")
        if result.total is not None:
            total = result.total
            print(f"        total {total.total.query.id:<28} {'pass' if total.passed else 'FAIL'}")
            for failure in total.before.failures:
                print(f"      total before: {failure}")
            for failure in total.after.failures:
                print(f"      total after:  {failure}")
            if total.equivalence is not None and not total.equivalence.same:
                print(f"      total rewrite: {total.equivalence.describe()}")
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


def cmd_dataset_report(args: argparse.Namespace) -> int:
    with connect(application_name="pglab-dataset") as conn:
        info = run_info(conn, measured=False, runs=0)
        data = dataset.build(conn)
    _write(Path(args.output), dataset.render(data, info, command=args.label))
    for line in dataset.summary(data):
        print(line)
    return 0


def cmd_partition(args: argparse.Namespace) -> int:
    _, cases = _definitions()
    with connect(application_name="pglab-partition") as conn:
        info = run_info(conn, measured=args.measure, runs=args.runs)
        counts = partitioning.build(conn)
        results = partitioning.run_report(conn, cases, _runs(args))
        retention = partitioning.measure_retention(conn)
    text = partitioning.render_report(results, retention, counts, info, command=args.label)
    _write(Path(args.output), text)
    failed = [failure for r in results for failure in r.failures]
    for r in results:
        scanned = len(partitioning.partitions_scanned(r.partitioned.plan))
        status = "pass" if not r.failures else "FAIL"
        print(f"{r.query.id:<22} {scanned:>3} of {r.total_partitions} partitions  {status}")
    print(
        f"retention: DELETE wrote {retention.delete_wal_bytes:,} bytes of WAL, "
        f"DETACH wrote {retention.detach_wal_bytes:,}"
    )
    if failed:
        raise CheckError("; ".join(failed))
    return 0


def cmd_partition_maintain(args: argparse.Namespace) -> int:
    with connect(application_name="pglab-partition") as conn:
        result = partitioning.maintain(conn, ahead=args.ahead, retain=args.retain, as_of=args.as_of)
    for name in result.recovered:
        print(f"recovered {name} (left by an interrupted run; now in schema part_archive)")
    for name in result.created:
        print(f"created  {name}")
    for name in result.detached:
        print(f"detached {name} (now in schema part_archive)")
    for parent, months in result.months_ready.items():
        print(f"{parent}: partitions ready for the next {months} months")
    return 0


def cmd_rls_report(args: argparse.Namespace) -> int:
    _, cases = _definitions()
    # SET ROLE to the application role needs the superuser; no lab role may impersonate another.
    with connect("postgres", application_name="pglab-rls") as conn:
        info = run_info(conn, measured=args.measure, runs=args.runs)
        casebook.apply_all(conn, cases)
        page, count, variants = rls.compare(conn, _runs(args))
    _write(Path(args.output), rls.render_report(page, count, variants, info, command=args.label))
    for v in variants:
        print(
            f"page {v.page.shared_buffers():>7,} buffers, total {v.count.shared_buffers():>7,}"
            f" buffers, estimate {rls.orders_estimate(v.page) or 0:>8,.0f},"
            f" cost factor without index {rls.cost_ratio(v) or 0:>6,.1f},"
            f" unfiltered count reads {rls.orders_read(v.unfiltered) or 0:>9,} orders  {v.label}"
        )
    return 0


def cmd_heartbeat(args: argparse.Namespace) -> int:
    count = heartbeat.run_heartbeat(
        args.run_id, args.hosts, Path(args.out), interval=args.interval, duration=args.duration
    )
    print(f"{count} heartbeat attempts written to {args.out}")
    return 0


def cmd_fingerprint(_: argparse.Namespace) -> int:
    with connect(application_name="pglab-drill") as conn:
        count, checksum = drills.order_items_fingerprint(conn)
    print(count, checksum)
    return 0


def _failover_state(conn: Connection, facts: dict[str, str]) -> drills.FailoverState:
    run_id = drills.fact(facts, "RUN_ID")
    role = facts.get("REWIND_ROLE", "rewind")
    superuser = scalar(conn, "SELECT rolsuper FROM pg_roles WHERE rolname = %s", (role,))
    # The rejoined old primary is a standby now: read it directly (target_session_attrs=any).
    with connect(host=drills.fact(facts, "OLD_PRIMARY"), application_name="pglab-drill") as old:
        on_old = drills.heartbeat_rows(old, run_id)
    return drills.FailoverState(
        primary=str(scalar(conn, "SELECT current_setting('cluster_name')")),
        rows_on_primary=frozenset(drills.heartbeat_rows(conn, run_id)),
        rows_on_rejoined=frozenset(on_old),
        # A missing role counts as a superuser, so the check fails rather than passes.
        rewind_role_is_superuser=superuser is not False,
    )


def cmd_drill_report(args: argparse.Namespace) -> int:
    folder = Path(args.dir)
    facts = drills.load_facts(folder / "facts.env")
    with connect(application_name="pglab-drill") as conn:
        info = run_info(conn, measured=args.measure, runs=1)
        if args.drill == "pitr":
            count, checksum = drills.order_items_fingerprint(conn)
            recovered = drills.Recovered(
                count, checksum, drills.heartbeat_rows(conn, drills.fact(facts, "RUN_ID"))
            )
            attempts = drills.load_attempts(folder / "heartbeat.jsonl")
            result = drills.analyse_pitr(facts, attempts, recovered, measured=args.measure)
        elif args.drill == "switchover":
            attempts = drills.load_attempts(folder / "heartbeat.jsonl")
            result = drills.analyse_switchover(conn, facts, attempts, measured=args.measure)
        else:
            result = drills.analyse_failover(facts, _failover_state(conn, facts))
    text = drills.render(result, info, command=args.label)
    default = REPORTS_DIR / drills.report_name(args.drill, facts)
    _write(Path(args.output) if args.output else default, text)
    (folder / "report.md").write_text(text, encoding="utf-8", newline="\n")
    for check in result.checks:
        print(f"{'pass' if check.passed else 'FAIL'}  {check.description}  {check.detail}")
    if not result.passed:
        raise CheckError(f"the {args.drill} drill failed its checks; see {folder}")
    return 0


def cmd_mssql_report(args: argparse.Namespace) -> int:
    expectations = mssql.load_expectations(ROOT / "sqlserver" / "expectations.toml")
    before = mssql.split_cases(Path(args.before).read_text(encoding="utf-8", errors="replace"))
    after = mssql.split_cases(Path(args.after).read_text(encoding="utf-8", errors="replace"))
    info = mssql_run_info(args)
    _write(Path(args.output), mssql.render(before, after, expectations, info, command=args.label))
    failed = 0
    for number, expectation in sorted(expectations.items()):
        failures = mssql.check(after[number], expectation) if number in after else ["missing"]
        print(f"case {number} {'pass' if not failures else 'FAIL'} {'; '.join(failures)}")
        failed += 1 if failures else 0
    if failed:
        raise CheckError(f"{failed} SQL Server case(s) failed their plan checks")
    return 0


def mssql_run_info(args: argparse.Namespace) -> RunInfo:
    return RunInfo(
        postgres_version="SQL Server 2022 Developer edition (version in the sqlcmd output)",
        scale=args.scale,
        anchor="see dbo.lab_settings",
        environment=os.environ.get("LAB_ENVIRONMENT", "not recorded"),
        generated_at=datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC"),
        measured=False,
        runs=0,
    )


type Subparsers = argparse._SubParsersAction[argparse.ArgumentParser]


def _timing_options(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--measure", action="store_true", help="record median execution times (quiet machine only)"
    )
    p.add_argument("--runs", type=int, default=15, help="timed runs per statement (default 15)")


def _performance_commands(sub: Subparsers) -> None:
    sub.add_parser("validate", help="check the workload and casebook definitions").set_defaults(
        func=cmd_validate
    )
    p = sub.add_parser("workload", help="rank the workload statements by buffers touched")
    p.add_argument("--state", choices=("baseline", "tuned", "current"), default="baseline")
    p.add_argument("--output", default=str(REPORTS_DIR / "workload.md"))
    _timing_options(p)
    p.set_defaults(func=cmd_workload)

    p = sub.add_parser("casebook", help="before/after plans of the casebook cases")
    p.add_argument("--output", default=str(REPORTS_DIR / "casebook.md"))
    _timing_options(p)
    p.set_defaults(func=cmd_casebook)

    p = sub.add_parser("casebook-state", help="revert (baseline) or apply (tuned) every fix")
    p.add_argument("state", choices=("baseline", "tuned"))
    p.set_defaults(func=cmd_casebook_state)

    p = sub.add_parser("index-report", help="index sizes and WAL per inserted row")
    p.add_argument("--output", default=str(REPORTS_DIR / "indexing.md"))
    p.set_defaults(func=cmd_index_report)

    p = sub.add_parser("dataset-report", help="row counts, time order and skew of the data set")
    p.add_argument("--output", default=str(REPORTS_DIR / "dataset.md"))
    p.set_defaults(func=cmd_dataset_report)

    p = sub.add_parser("partition", help="build monthly partitions, check pruning, report")
    p.add_argument("--output", default=str(REPORTS_DIR / "partitioning.md"))
    _timing_options(p)
    p.set_defaults(func=cmd_partition)

    p = sub.add_parser("partition-maintain", help="create future partitions, detach old ones")
    p.add_argument("--ahead", type=int, default=3, help="months to keep ready (default 3)")
    p.add_argument("--retain", type=int, default=24, help="full months to keep (default 24)")
    p.add_argument(
        "--as-of", type=iso_date, default=None, help="reference date YYYY-MM-DD (default: anchor)"
    )
    p.set_defaults(func=cmd_partition_maintain)

    p = sub.add_parser("rls-report", help="tenant query plans under three RLS policy designs")
    p.add_argument("--output", default=str(REPORTS_DIR / "rls-plans.md"))
    _timing_options(p)
    p.set_defaults(func=cmd_rls_report)

    p = sub.add_parser("mssql-report", help="SQL Server chapter: check plans from sqlcmd output")
    p.add_argument("--before", required=True)
    p.add_argument("--after", required=True)
    p.add_argument("--scale", default=os.environ.get("LAB_SCALE", "unknown"))
    p.add_argument("--output", default=str(REPORTS_DIR / "sqlserver-casebook.md"))
    p.set_defaults(func=cmd_mssql_report)


def cmd_monitor_check(args: argparse.Namespace) -> int:
    rules = monitoring.expected_rule_count(
        ROOT / "monitoring" / "prometheus" / "rules" / "postgres.yml"
    )
    nodes = [node for node in args.nodes.split(",") if node]
    monitoring.wait_until_healthy(args.prometheus, args.grafana, nodes, rules, timeout=args.timeout)
    print(
        f"monitoring ok: {', '.join(nodes)} scraped, {rules} alert rules loaded, dashboard present"
    )
    return 0


def _reliability_commands(sub: Subparsers) -> None:
    p = sub.add_parser("heartbeat", help="client loop writing one row per interval")
    p.add_argument("--run-id", required=True)
    p.add_argument("--hosts", required=True, help="comma-separated node names, e.g. pg1,pg2")
    p.add_argument("--out", required=True)
    p.add_argument("--interval", type=float, default=0.1)
    p.add_argument("--duration", type=float, default=600.0)
    p.set_defaults(func=cmd_heartbeat)

    sub.add_parser("fingerprint", help="order_items row count and content checksum").set_defaults(
        func=cmd_fingerprint
    )

    p = sub.add_parser("monitor-check", help="exporters scraped, rules loaded, dashboard present")
    p.add_argument("--nodes", default="pg1,pg2")
    p.add_argument("--prometheus", default="http://prometheus:9090")
    p.add_argument("--grafana", default="http://grafana:3000")
    p.add_argument("--timeout", type=float, default=240.0)
    p.set_defaults(func=cmd_monitor_check)

    p = sub.add_parser("drill-report", help="check a drill's outcome and write its report")
    p.add_argument("drill", choices=("pitr", "switchover", "failover"))
    p.add_argument("--dir", required=True, help="the drill folder with facts.env and heartbeat")
    p.add_argument("--output", default=None)
    p.add_argument("--measure", action="store_true", help="publish the measured durations")
    p.set_defaults(func=cmd_drill_report)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pglab", description=__doc__)
    parser.add_argument("--label", default=None, help="command shown in report headers")
    sub = parser.add_subparsers(dest="command", required=True)
    _performance_commands(sub)
    _reliability_commands(sub)
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
    except psycopg.Error as exc:
        print(f"database error: {exc}", file=sys.stderr)
        return 2
