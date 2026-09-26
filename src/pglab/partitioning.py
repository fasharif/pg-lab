"""Monthly partitioning of orders and audit_logs: build, pruning checks, retention, maintenance.

The partitioned tables live in schema "part" (sql/partitioning). `build` fills them from the
TopFlow tables; `run_report` compares time-bounded statements on the plain and the
partitioned tables and checks that each plan scans exactly the partitions its time window
needs; `maintain` creates future partitions and detaches the ones past retention.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any

import psycopg

from pglab import casebook
from pglab.db import Connection, scalar
from pglab.definitions import Case
from pglab.errors import LabError
from pglab.execute import Timing, explain_json, explain_raw, explain_text, measure, render
from pglab.explain import Plan, format_blocks
from pglab.report import RunInfo, code, table, timing_cell

PARENTS = ("part.orders", "part.audit_logs")
PARTITION_NAME = re.compile(r"_p\d{4}_\d{2}$")
MONTHS_AHEAD = 3


@dataclass(frozen=True)
class PartitionInfo:
    name: str
    month: date
    lower: datetime
    upper: datetime


def partitions(conn: Connection, parent: str) -> list[PartitionInfo]:
    rows = conn.execute(
        "SELECT partition::text, month, lower_bound, upper_bound"
        " FROM part.partitions(%s::regclass)",
        (parent,),
    ).fetchall()
    return [PartitionInfo(str(r[0]), r[1], r[2], r[3]) for r in rows]


def overlapping(
    parts: Sequence[PartitionInfo], lower: datetime | None, upper: datetime | None
) -> set[str]:
    """Partitions a window [lower, upper) can touch: the set a pruned plan must scan."""
    return {
        p.name.split(".")[-1]
        for p in parts
        if (lower is None or p.upper > lower) and (upper is None or p.lower < upper)
    }


def add_months(day: date, months: int) -> date:
    index = day.year * 12 + day.month - 1 + months
    return date(index // 12, index % 12 + 1, 1)


def build(conn: Connection) -> dict[str, int]:
    """Create partitions covering the data plus MONTHS_AHEAD months and copy the rows."""
    anchor = scalar(conn, "SELECT lab.anchor()")
    if anchor is None:
        raise LabError("no data: run ./lab seed first")
    counts: dict[str, int] = {}
    for parent, source in (
        ("part.orders", "public.orders"),
        ("part.audit_logs", "public.audit_logs"),
    ):
        oldest = scalar(conn, f'SELECT min("createdAt") FROM {source}')
        if oldest is None:
            raise LabError(f"{source} is empty: run ./lab seed first")
        last = add_months(anchor.date(), MONTHS_AHEAD)
        conn.execute(
            "SELECT part.create_monthly_partitions(%s::regclass, %s, %s)",
            (parent, oldest.date(), last),
        )
        conn.execute(f"INSERT INTO {parent} SELECT * FROM {source}")
        conn.execute(f"VACUUM (ANALYZE) {parent}")
        counts[parent] = int(scalar(conn, f"SELECT count(*) FROM {parent}"))
    return counts


@dataclass(frozen=True)
class TimeQuery:
    id: str
    title: str
    sql: str  # {orders} / {audit} are replaced by the plain or the partitioned table
    params: dict[str, str]
    parent: str
    window: tuple[str | None, str | None]  # parameter names bounding the time window
    # Prepared with a generic plan (as drivers such as Prisma's prepare their statements):
    # the parameter is unknown at plan time, so pruning happens when execution starts.
    prepared_args: str | None = None

    @property
    def runtime_pruning(self) -> bool:
        return self.prepared_args is not None


QUERIES: tuple[TimeQuery, ...] = (
    TimeQuery(
        "revenue-30d",
        "Dashboard revenue of the last 30 days",
        """SELECT sum(o."totalAmount") FROM {orders} AS o
WHERE o."createdAt" >= %(since)s AND o.status <> 'CANCELLED'""",
        {"since": "SELECT lab.anchor() - interval '30 days'"},
        "part.orders",
        ("since", None),
    ),
    TimeQuery(
        "org-month-statement",
        "Monthly statement: one organisation's orders in the last full month",
        """SELECT o.* FROM {orders} AS o
WHERE o."organizationId" = %(org_id)s
  AND o."createdAt" >= %(month_start)s AND o."createdAt" < %(month_end)s
ORDER BY o."createdAt"
""",
        {
            "org_id": "SELECT lab.uid('org', 1)",
            "month_start": "SELECT date_trunc('month', lab.anchor()) - interval '1 month'",
            "month_end": "SELECT date_trunc('month', lab.anchor())",
        },
        "part.orders",
        ("month_start", "month_end"),
    ),
    TimeQuery(
        "audit-one-day",
        "Audit entries of one day (compliance lookup)",
        """SELECT a.* FROM {audit} AS a
WHERE a."createdAt" >= %(day_start)s AND a."createdAt" < %(day_end)s
ORDER BY a."createdAt" DESC
LIMIT 50""",
        {
            "day_start": "SELECT date_trunc('day', lab.anchor()) - interval '10 days'",
            "day_end": "SELECT date_trunc('day', lab.anchor()) - interval '9 days'",
        },
        "part.audit_logs",
        ("day_start", "day_end"),
    ),
    TimeQuery(
        "recent-7d-generic-plan",
        "Orders of the last 7 days as a prepared statement with a generic plan (run-time pruning)",
        """SELECT count(*) FROM {orders} AS o
WHERE o."createdAt" >= $1""",
        {"since": "SELECT lab.anchor() - interval '7 days'"},
        "part.orders",
        ("since", None),
        prepared_args="%(since)s",
    ),
    TimeQuery(
        "org-history-no-key",
        "Organisation order history with no date filter (no pruning possible)",
        """SELECT o.* FROM {orders} AS o
WHERE o."organizationId" = %(org_id)s
ORDER BY o."createdAt" DESC
LIMIT 20""",
        {"org_id": "SELECT lab.uid('org', 1)"},
        "part.orders",
        (None, None),
    ),
)


@dataclass(frozen=True)
class Side:
    statement: str
    plan: Plan
    text: str
    timing: Timing | None


@dataclass(frozen=True)
class TimeResult:
    query: TimeQuery
    baseline: Side
    plain: Side
    partitioned: Side
    expected: set[str]
    total_partitions: int
    failures: tuple[str, ...]


def _side(
    conn: Connection, query: TimeQuery, sql: str, values: dict[str, Any], runs: int | None
) -> Side:
    if query.prepared_args is None:
        statement = render(conn, sql, values)
        return Side(
            statement,
            explain_json(conn, statement),
            explain_text(conn, statement),
            measure(conn, statement, runs) if runs else None,
        )
    conn.execute("SET plan_cache_mode = force_generic_plan")
    conn.execute(f"PREPARE lab_generic (timestamp) AS {sql}")
    try:
        execute = render(conn, f"EXECUTE lab_generic({query.prepared_args})", values)
        return Side(
            f"SET plan_cache_mode = force_generic_plan;\n"
            f"PREPARE lab_generic (timestamp) AS\n{sql};\n{execute}",
            explain_json(conn, execute),
            explain_text(conn, execute),
            measure(conn, execute, runs) if runs else None,
        )
    finally:
        conn.execute("DEALLOCATE lab_generic")
        conn.execute("RESET plan_cache_mode")


def partitions_scanned(plan: Plan) -> set[str]:
    return {name for name in plan.relations_scanned() if PARTITION_NAME.search(name)}


def check_pruning(query: TimeQuery, plan: Plan, expected: set[str]) -> list[str]:
    scanned = partitions_scanned(plan)
    failures = []
    if scanned != expected:
        failures.append(
            f"{query.id}: expected partitions {sorted(expected)}, plan scans {sorted(scanned)}"
        )
    if query.runtime_pruning and plan.subplans_removed() == 0:
        failures.append(f"{query.id}: expected run-time pruning (Subplans Removed > 0)")
    return failures


def _values(conn: Connection, query: TimeQuery) -> dict[str, Any]:
    return {name: scalar(conn, expression) for name, expression in query.params.items()}


def _sql_values(query: TimeQuery, values: dict[str, Any]) -> dict[str, Any]:
    used = query.sql + (query.prepared_args or "")
    return {k: v for k, v in values.items() if f"%({k})s" in used}


def _plain_sql(query: TimeQuery) -> str:
    return query.sql.format(orders="public.orders", audit="public.audit_logs")


def run_report(conn: Connection, cases: Sequence[Case], runs: int | None) -> list[TimeResult]:
    """Each statement three ways: plain table with TopFlow's own indexes, plain table with the
    casebook's indexes, partitioned table with the same indexes. Leaves the schema tuned."""
    casebook.revert_all(conn, cases)
    baseline = {
        q.id: _side(conn, q, _plain_sql(q), _sql_values(q, _values(conn, q)), runs) for q in QUERIES
    }
    casebook.apply_all(conn, cases)
    results = []
    for query in QUERIES:
        values = _values(conn, query)
        sql_values = _sql_values(query, values)
        plain = _side(conn, query, _plain_sql(query), sql_values, runs)
        partitioned_sql = query.sql.format(orders="part.orders", audit="part.audit_logs")
        partitioned = _side(conn, query, partitioned_sql, sql_values, runs)
        parts = partitions(conn, query.parent)
        lower = values.get(query.window[0]) if query.window[0] else None
        upper = values.get(query.window[1]) if query.window[1] else None
        expected = overlapping(parts, lower, upper)
        failures = tuple(check_pruning(query, partitioned.plan, expected))
        results.append(
            TimeResult(
                query, baseline[query.id], plain, partitioned, expected, len(parts), failures
            )
        )
    return results


@dataclass(frozen=True)
class Retention:
    rows: int
    delete_wal_bytes: int
    detach_wal_bytes: int
    partition: str


def measure_retention(conn: Connection) -> Retention:
    """WAL written to remove the oldest full month of audit entries: DELETE on the plain table
    (rolled back afterwards) versus DETACH PARTITION on the partitioned one (re-attached).
    The first partition usually holds a partial month, so the second one is used."""
    parts = partitions(conn, "part.audit_logs")
    if len(parts) < 2:
        raise LabError("need at least two audit partitions to measure retention")
    oldest = parts[1]
    rows = int(scalar(conn, f"SELECT count(*) FROM {oldest.name}"))
    delete = (
        'DELETE FROM public.audit_logs WHERE "createdAt" >= %(lower)s AND "createdAt" < %(upper)s'
    )
    statement = render(conn, delete, {"lower": oldest.lower, "upper": oldest.upper})
    with conn.transaction(force_rollback=True):
        plan_doc = explain_raw(
            conn, statement, "ANALYZE, WAL, TIMING OFF, SUMMARY OFF, FORMAT JSON"
        )
    delete_wal = int(plan_doc[0][0][0]["Plan"].get("WAL Bytes", 0))
    before = scalar(conn, "SELECT pg_current_wal_insert_lsn()")
    conn.execute(f"ALTER TABLE part.audit_logs DETACH PARTITION {oldest.name}")
    after = scalar(conn, "SELECT pg_current_wal_insert_lsn()")
    detach_wal = int(scalar(conn, "SELECT pg_wal_lsn_diff(%s, %s)", (after, before)))
    conn.execute(
        f"ALTER TABLE part.audit_logs ATTACH PARTITION {oldest.name} "
        f"FOR VALUES FROM ('{oldest.lower}') TO ('{oldest.upper}')"
    )
    conn.execute("VACUUM public.audit_logs")
    return Retention(rows, delete_wal, detach_wal, oldest.name)


@dataclass(frozen=True)
class MaintenanceResult:
    created: list[str]
    detached: list[str]
    months_ready: dict[str, int]


def maintain(conn: Connection, *, ahead: int, retain: int, as_of: date | None) -> MaintenanceResult:
    """Create partitions up to `ahead` months after as_of and detach those older than
    `retain` full months. DETACH ... CONCURRENTLY needs autocommit (no transaction block)."""
    if ahead < 1 or retain < 1:
        raise LabError("--ahead and --retain must be at least 1")
    if as_of is None:
        anchor = scalar(conn, "SELECT lab.anchor()")
        if anchor is None:
            raise LabError("no anchor date: run ./lab seed, or pass --as-of")
        as_of = anchor.date()
    created: list[str] = []
    detached: list[str] = []
    ready: dict[str, int] = {}
    for parent in PARENTS:
        rows = conn.execute(
            "SELECT part.create_monthly_partitions(%s::regclass, %s, %s)",
            (parent, as_of, add_months(as_of, ahead)),
        ).fetchall()
        created += [str(r[0]) for r in rows]
        old = conn.execute(
            "SELECT p::text FROM part.partitions_to_detach(%s::regclass, %s, %s) AS p",
            (parent, retain, as_of),
        ).fetchall()
        for (name,) in old:
            try:
                conn.execute(f"ALTER TABLE {parent} DETACH PARTITION {name} CONCURRENTLY")
                conn.execute(f"ALTER TABLE {name} SET SCHEMA part_archive")
            except psycopg.Error as exc:
                raise LabError(f"detaching {name} failed: {exc}") from exc
            detached.append(str(name))
        ready[parent] = int(
            scalar(conn, "SELECT part.months_ready(%s::regclass, %s)", (parent, as_of))
        )
        if ready[parent] < ahead:
            raise LabError(f"{parent}: only {ready[parent]} future months have partitions")
    return MaintenanceResult(created, detached, ready)


def render_report(
    results: Sequence[TimeResult],
    retention: Retention,
    counts: dict[str, int],
    info: RunInfo,
    *,
    command: str,
) -> str:
    summary = []
    timings = []
    for r in results:
        scanned = len(partitions_scanned(r.partitioned.plan))
        summary.append(
            (
                r.query.title,
                f"{scanned} of {r.total_partitions}",
                format_blocks(r.baseline.plan.shared_buffers()),
                format_blocks(r.plain.plan.shared_buffers()),
                format_blocks(r.partitioned.plan.shared_buffers()),
                "pass" if not r.failures else "FAIL",
            )
        )
        timings.append(
            (
                r.query.title,
                *(
                    timing_cell(
                        side.timing.median_ms if side.timing else None,
                        side.timing.median_planning_ms if side.timing else None,
                    )
                    for side in (r.baseline, r.plain, r.partitioned)
                ),
            )
        )
    lines = [
        "# Partitioning: pruning and retention",
        "",
        "`orders` and `audit_logs` copied into monthly range partitions (schema `part`, see",
        "`sql/partitioning/`) and compared with the plain tables, first with TopFlow's own",
        "indexes and then with the casebook's indexes. The partitioned tables carry the same",
        "indexes as the tuned plain tables.",
        "",
        *info.header_lines(command),
        f"- Rows copied: {', '.join(f'{k} {v:,}' for k, v in counts.items())}.",
        "",
        "## Time-bounded statements: shared buffers touched",
        "",
        table(
            [
                "Statement",
                "Partitions scanned",
                "Plain, TopFlow indexes",
                "Plain, tuned",
                "Partitioned",
                "Pruning check",
            ],
            summary,
            "lrrrrc",
        ),
        "",
        "## Time-bounded statements: median time per call",
        "",
        "Planning plus execution, with the planning share in brackets: pruning and the number",
        "of partitions add planning work, and a generic plan prunes when it starts executing.",
        "",
        table(
            ["Statement", "Plain, TopFlow indexes", "Plain, tuned", "Partitioned"], timings, "lrrr"
        ),
        "",
        "## Retention: removing the oldest full month of audit entries",
        "",
        table(
            ["Method", "Rows removed", "WAL written"],
            [
                (
                    "`DELETE` on the plain table",
                    f"{retention.rows:,}",
                    f"{retention.delete_wal_bytes:,} bytes",
                ),
                (
                    f"`DETACH PARTITION` ({retention.partition.split('.')[-1]})",
                    f"{retention.rows:,}",
                    f"{retention.detach_wal_bytes:,} bytes",
                ),
            ],
            "lrr",
        ),
        "",
        "The DELETE also leaves every removed row as a dead tuple for VACUUM, and its index",
        "entries until VACUUM cleans them; a detached partition is a table of its own that can",
        "be dumped, moved to cheaper storage or dropped in one step.",
        "",
    ]
    for r in results:
        lines += [
            f"## {r.query.title}",
            "",
            "Partitioned table:",
            "",
            code(r.partitioned.statement, "sql"),
            "",
            code(r.partitioned.text, "text"),
            "",
            f"Expected partitions: {', '.join(f'`{p}`' for p in sorted(r.expected)) or 'none'}.",
            *(f"- FAILED: {failure}" for failure in r.failures),
            "",
        ]
    return "\n".join(lines)
