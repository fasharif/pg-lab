"""The data set report (reports/dataset.md), written by ./lab seed.

It records what the generator produced, so that the figures quoted in docs/data.md and
docs/benchmarking.md (row counts, the physical order of the time columns, the customer skew)
come from a committed report rather than from a terminal: exact row counts per table, the
pg_stats correlation of every createdAt column, and how the trade orders are spread over the
organisations.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from pglab.casebook import TOPFLOW_TABLES
from pglab.db import Connection, scalar
from pglab.errors import LabError
from pglab.report import RunInfo, table


@dataclass(frozen=True)
class Skew:
    organisations: int
    organisations_with_orders: int
    trade_orders: int
    retail_orders: int
    largest: int  # trade orders of the largest organisation
    median: float  # trade orders of the median organisation with orders


@dataclass(frozen=True)
class Dataset:
    rows: dict[str, int]
    correlation: list[tuple[str, float | None]]  # table -> pg_stats correlation of createdAt
    skew: Skew

    @property
    def total_rows(self) -> int:
        return sum(self.rows.values())


def build(conn: Connection) -> Dataset:
    rows = {
        name: int(scalar(conn, f'SELECT count(*) FROM public."{name}"')) for name in TOPFLOW_TABLES
    }
    correlation = [
        (str(name), None if value is None else float(value))
        for name, value in conn.execute(
            "SELECT tablename, correlation FROM pg_stats"
            " WHERE schemaname = 'public' AND attname = 'createdAt' ORDER BY tablename"
        ).fetchall()
    ]
    row = conn.execute(
        """
        WITH per_org AS (
            SELECT "organizationId", count(*) AS n FROM orders
            WHERE "organizationId" IS NOT NULL GROUP BY 1
        )
        SELECT (SELECT count(*) FROM organizations),
               (SELECT count(*) FROM per_org),
               (SELECT coalesce(sum(n), 0) FROM per_org),
               (SELECT count(*) FROM orders WHERE "organizationId" IS NULL),
               (SELECT coalesce(max(n), 0) FROM per_org),
               (SELECT coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY n), 0) FROM per_org)
        """
    ).fetchone()
    if row is None:
        raise LabError("could not measure the customer skew")
    skew = Skew(int(row[0]), int(row[1]), int(row[2]), int(row[3]), int(row[4]), float(row[5]))
    return Dataset(rows, correlation, skew)


def render(dataset: Dataset, info: RunInfo, *, command: str) -> str:
    s = dataset.skew
    share = s.largest / s.trade_orders if s.trade_orders else 0.0
    lines = [
        "# Data set",
        "",
        "What `./lab seed` generated: exact row counts, the physical order of the time columns",
        "and how the trade orders are spread over the organisations. See docs/data.md for the",
        "model behind these numbers.",
        "",
        *info.header_lines(command),
        "",
        "## Rows",
        "",
        table(
            ["Table", "Rows"],
            [
                *((name, f"{count:,}") for name, count in sorted(dataset.rows.items())),
                ("**all 18 TopFlow tables**", f"**{dataset.total_rows:,}**"),
            ],
            "lr",
        ),
        "",
        "## Physical order of `createdAt`",
        "",
        "`pg_stats.correlation` after the generator's `ANALYZE`: 1 means the rows lie on disk in",
        "`createdAt` order, which is what makes BRIN indexes and time-bounded range scans cheap.",
        "",
        table(
            ["Table", "Correlation"],
            [(name, _correlation(value)) for name, value in dataset.correlation],
            "lr",
        ),
        "",
        "## Customer skew",
        "",
        table(
            ["", ""],
            [
                ("Organisations", f"{s.organisations:,}"),
                ("Organisations with trade orders", f"{s.organisations_with_orders:,}"),
                ("Trade orders", f"{s.trade_orders:,}"),
                ("Retail orders", f"{s.retail_orders:,}"),
                ("Trade orders of the largest organisation", f"{s.largest:,} ({share:.1%})"),
                ("Trade orders of the median organisation", f"{s.median:,.0f}"),
            ],
            "lr",
        ),
        "",
    ]
    return "\n".join(lines)


def _correlation(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.4f}"


def summary(dataset: Dataset) -> Sequence[str]:
    """Lines for the terminal."""
    return [
        f"{dataset.total_rows:,} rows in {len(dataset.rows)} tables",
        f"largest organisation: {dataset.skew.largest:,} of {dataset.skew.trade_orders:,} "
        "trade orders",
    ]
