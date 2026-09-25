"""Index sizes and the write cost of the casebook's indexes (reports/indexing.md).

Write cost is measured as WAL generated per inserted row, from EXPLAIN (ANALYZE, WAL) on a
batch INSERT, with the schema in its baseline state (TopFlow's indexes) and in its tuned state
(plus the casebook's indexes). WAL volume depends on the rows and indexes, not on machine load,
so it can be compared across runs. Each probe starts right after a CHECKPOINT, so it includes
the full-page images that the first change to a page after every checkpoint also writes in
production. The probe rows are deleted afterwards.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass

from pglab import casebook
from pglab.db import Connection, scalar
from pglab.definitions import Case
from pglab.execute import explain_raw
from pglab.explain import parse_plan
from pglab.report import RunInfo, table

PROBE_ROWS = 5000
PROBE_PREFIX = "walprobe-"
CREATE_INDEX = re.compile(
    r'CREATE\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?"?(\w+)"?', re.IGNORECASE
)

PROBES: dict[str, str] = {
    "audit_logs": f"""
        INSERT INTO audit_logs (id, "userId", action, "entityType", "entityId", details,
                                "createdAt", "ipAddress", "organizationId")
        SELECT '{PROBE_PREFIX}' || g, lab.uid('user', 1 + g % 50), 'orders.status_changed',
               'Order', lab.uid('order', g), '{{"requestId": "probe", "client": "web"}}',
               lab.anchor() + make_interval(secs => g), '10.0.0.1', lab.uid('org', 1 + g % 10)
        FROM generate_series(1, {PROBE_ROWS}) AS g""",
    "orders": f"""
        INSERT INTO orders (id, "orderNumber", "userId", "totalAmount", "shippingAddress",
                            "projectReference", "createdAt", "updatedAt", channel,
                            "organizationId", "purchaseOrderNumber", subtotal, "vatAmount")
        SELECT '{PROBE_PREFIX}' || g, 'TF-SO-PROBE-' || lpad(g::text, 6, '0'),
               lab.uid('user', lab.member_user(1 + g % 10, 1)), 105.00, 'Plot 1, Probe',
               'Probe Villa ' || g, lab.anchor() + make_interval(secs => g),
               lab.anchor() + make_interval(secs => g), 'B2B', lab.uid('org', 1 + g % 10),
               'PO-PROBE-' || g, 100.00, 5.00
        FROM generate_series(1, {PROBE_ROWS}) AS g""",
}


@dataclass(frozen=True)
class IndexRow:
    table: str
    name: str
    definition: str
    size_bytes: int
    origin: str


@dataclass(frozen=True)
class WalProbe:
    table: str
    index_count: int
    wal_bytes: int
    wal_fpi: int

    @property
    def bytes_per_row(self) -> float:
        return self.wal_bytes / PROBE_ROWS


@dataclass(frozen=True)
class IndexReport:
    indexes: list[IndexRow]
    table_sizes: dict[str, tuple[int, int]]  # table -> (heap bytes, index bytes)
    baseline: dict[str, WalProbe]
    tuned: dict[str, WalProbe]
    alternatives: list[tuple[str, str, int, int]]  # label, definition, size, compared size


def index_origins(cases: Sequence[Case]) -> dict[str, str]:
    origins: dict[str, str] = {}
    for case in cases:
        for statement in case.fix:
            match = CREATE_INDEX.search(statement)
            if match:
                origins[match.group(1)] = f"casebook case {case.number}"
    return origins


def list_indexes(conn: Connection, origins: dict[str, str]) -> list[IndexRow]:
    rows = conn.execute(
        """
        SELECT t.relname, i.relname, pg_get_indexdef(x.indexrelid),
               pg_relation_size(x.indexrelid),
               EXISTS (SELECT 1 FROM pg_constraint AS c
                       WHERE c.conindid = x.indexrelid AND c.contype = 'p')
        FROM pg_index AS x
        JOIN pg_class AS i ON i.oid = x.indexrelid
        JOIN pg_class AS t ON t.oid = x.indrelid
        WHERE t.relnamespace = 'public'::regnamespace AND t.relkind = 'r'
        ORDER BY t.relname, i.relname
        """
    ).fetchall()
    result = []
    for table_name, name, definition, size, is_pk in rows:
        origin = origins.get(name) or ("primary key" if is_pk else "TopFlow migration")
        short = re.sub(r"^CREATE (UNIQUE )?INDEX \S+ ON public\.", r"\1", str(definition))
        result.append(IndexRow(str(table_name), str(name), short, int(size), origin))
    return result


def table_sizes(conn: Connection) -> dict[str, tuple[int, int]]:
    rows = conn.execute(
        """
        SELECT relname, pg_table_size(oid), pg_indexes_size(oid)
        FROM pg_class
        WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
        ORDER BY relname
        """
    ).fetchall()
    return {str(name): (int(heap), int(idx)) for name, heap, idx in rows}


def probe_wal(conn: Connection, table_name: str) -> WalProbe:
    """Insert PROBE_ROWS rows right after a checkpoint, read the WAL figures, remove the rows."""
    statement = PROBES[table_name]
    conn.execute("CHECKPOINT")
    rows = explain_raw(conn, statement, "ANALYZE, WAL, TIMING OFF, SUMMARY OFF, FORMAT JSON")
    plan = parse_plan(rows[0][0])
    raw = plan.root.raw
    conn.execute(f"DELETE FROM {table_name} WHERE id LIKE '{PROBE_PREFIX}%'")
    conn.execute(f"VACUUM {table_name}")
    count = scalar(
        conn,
        "SELECT count(*) FROM pg_index WHERE indrelid = %s::regclass",
        (table_name,),
    )
    return WalProbe(
        table_name, int(count), int(raw.get("WAL Bytes", 0)), int(raw.get("WAL FPI", 0))
    )


def measure_alternative(conn: Connection, name: str, definition: str) -> int:
    """Build an index, read its size, drop it."""
    conn.execute(f'DROP INDEX IF EXISTS "{name}"')
    conn.execute(definition)
    size = int(scalar(conn, "SELECT pg_relation_size(%s::regclass)", (f'"{name}"',)))
    conn.execute(f'DROP INDEX "{name}"')
    return size


def build_report(conn: Connection, cases: Sequence[Case]) -> IndexReport:
    casebook.revert_all(conn, cases)
    baseline = {name: probe_wal(conn, name) for name in PROBES}
    casebook.apply_all(conn, cases)
    tuned = {name: probe_wal(conn, name) for name in PROBES}
    conn.execute("VACUUM (ANALYZE) orders, audit_logs")
    indexes = list_indexes(conn, index_origins(cases))
    sizes = {row.name: row.size_bytes for row in indexes}
    alternatives = [
        (
            "BRIN on orders.createdAt (instead of the covering B-tree of case 7)",
            'CREATE INDEX "lab_orders_createdAt_brin" ON orders USING brin ("createdAt")',
            measure_alternative(
                conn,
                "lab_orders_createdAt_brin",
                'CREATE INDEX "lab_orders_createdAt_brin" ON orders USING brin ("createdAt")',
            ),
            sizes.get("orders_createdAt_idx", 0),
        ),
        (
            "BRIN on audit_logs.createdAt (instead of TopFlow's B-tree)",
            'CREATE INDEX "lab_audit_createdAt_brin" ON audit_logs USING brin ("createdAt")',
            measure_alternative(
                conn,
                "lab_audit_createdAt_brin",
                'CREATE INDEX "lab_audit_createdAt_brin" ON audit_logs USING brin ("createdAt")',
            ),
            sizes.get("audit_logs_createdAt_idx", 0),
        ),
    ]
    return IndexReport(indexes, table_sizes(conn), baseline, tuned, alternatives)


def human_bytes(value: float) -> str:
    units = ("B", "kB", "MB", "GB", "TB")
    unit = 0
    while value >= 1024 and unit < len(units) - 1:
        value /= 1024
        unit += 1
    return (
        f"{value:.0f} {units[unit]}" if unit == 0 or value >= 100 else f"{value:.1f} {units[unit]}"
    )


def _change(before: WalProbe, after: WalProbe) -> str:
    return f"{(after.bytes_per_row / before.bytes_per_row - 1) * 100:+.0f}%"


def render_report(report: IndexReport, info: RunInfo, *, command: str) -> str:
    lines = [
        "# Index sizes and write cost",
        "",
        "Measured sizes of every index on the TopFlow tables after the casebook fixes, the WAL",
        "each inserted row costs before and after them, and two alternatives that were measured",
        "but not adopted. `docs/indexing.md` explains the choices.",
        "",
        *info.header_lines(command),
        "",
        "## Indexes (tuned state)",
        "",
        table(
            ["Table", "Index", "Definition", "Size", "Origin"],
            [
                (r.table, f"`{r.name}`", f"`{r.definition}`", human_bytes(r.size_bytes), r.origin)
                for r in report.indexes
                if r.table
                in {
                    "orders",
                    "audit_logs",
                    "quotations",
                    "products",
                    "users",
                    "organizations",
                    "order_items",
                    "quote_requests",
                }
            ],
            "lllrl",
        ),
        "",
        "## Table and index volume",
        "",
        table(
            ["Table", "Table size", "All indexes", "Indexes / table"],
            [
                (name, human_bytes(heap), human_bytes(idx), f"{idx / heap:.2f}" if heap else "")
                for name, (heap, idx) in sorted(
                    report.table_sizes.items(), key=lambda item: -(item[1][0] + item[1][1])
                )
            ],
            "lrrr",
        ),
        "",
        f"## Write cost: WAL per inserted row ({PROBE_ROWS:,} rows per probe)",
        "",
        table(
            [
                "Table",
                "Indexes before",
                "WAL per row before",
                "Indexes after",
                "WAL per row after",
                "Change",
            ],
            [
                (
                    name,
                    report.baseline[name].index_count,
                    f"{report.baseline[name].bytes_per_row:,.0f} B",
                    report.tuned[name].index_count,
                    f"{report.tuned[name].bytes_per_row:,.0f} B",
                    _change(report.baseline[name], report.tuned[name]),
                )
                for name in PROBES
            ],
            "lrrrrr",
        ),
        "",
        "## Alternatives measured, not adopted",
        "",
        table(
            ["Alternative", "Definition", "Size", "Size of the index it would replace"],
            [
                (label, f"`{d}`", human_bytes(size), human_bytes(other))
                for label, d, size, other in report.alternatives
            ],
            "llrr",
        ),
        "",
    ]
    return "\n".join(lines)
