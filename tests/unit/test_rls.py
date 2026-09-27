"""The row-level security report: rows a policy filter reads, and the timing policy."""

from __future__ import annotations

from typing import Any

from pglab.execute import Timing
from pglab.explain import Plan, parse_plan
from pglab.report import PENDING, RunInfo
from pglab.rls import Variant, counted, orders_read, render_report
from tests.conftest import load_plan


def _count_plan(scan: dict[str, Any]) -> Plan:
    """A count(*) over one scan of orders, shaped like EXPLAIN (ANALYZE, FORMAT JSON)."""
    return parse_plan(
        [
            {
                "Plan": {
                    "Node Type": "Aggregate",
                    "Actual Rows": 1,
                    "Actual Loops": 1,
                    "Plans": [{"Relation Name": "orders", **scan}],
                }
            }
        ]
    )


def test_orders_read_counts_the_rows_a_policy_filter_removed() -> None:
    plan = _count_plan(
        {
            "Node Type": "Index Only Scan",
            "Index Name": "orders_organizationId_createdAt_idx",
            "Actual Rows": 2495.0,
            "Actual Loops": 1,
            "Rows Removed by Filter": 17505,
        }
    )
    assert orders_read(plan) == 20_000
    assert counted(plan) == "2,495"


def test_orders_read_adds_up_parallel_workers() -> None:
    # Per-loop averages: three processes each returned 100 rows and removed 900.
    plan = _count_plan(
        {
            "Node Type": "Seq Scan",
            "Actual Rows": 100.0,
            "Actual Loops": 3,
            "Rows Removed by Filter": 900,
        }
    )
    assert orders_read(plan) == 3000
    assert counted(plan) == "300"


def test_orders_read_ignores_bitmap_index_scans_and_other_tables() -> None:
    plan = load_plan("orders-org-history.before")
    heap_rows = sum(
        (node.actual_rows or 0) * (node.actual_loops or 1)
        for node in plan.nodes()
        if node.relation == "orders" and node.node_type != "Bitmap Index Scan"
    )
    assert orders_read(plan) == round(heap_rows)
    assert orders_read(_count_plan({"Node Type": "Seq Scan"})) is None  # not ANALYZEd


def _variant(timed: bool) -> Variant:
    page = load_plan("orders-org-history.after")
    count = _count_plan({"Node Type": "Index Only Scan", "Actual Rows": 10.0, "Actual Loops": 1})
    timing = Timing((1.0, 3.0, 2.0), (0.1, 0.1, 0.1))
    return Variant(
        label="owner, no RLS",
        page=page,
        count=count,
        page_text="page plan",
        count_text="count plan",
        without_index=page,
        unfiltered=count,
        unfiltered_text="unfiltered plan",
        timings=(timing, timing, timing) if timed else None,
    )


def _info(measured: bool) -> RunInfo:
    return RunInfo("PostgreSQL 18.6", "100000", "2026-09-27 19:00:00", "test", "now", measured, 3)


def test_report_marks_timings_pending_unless_measured() -> None:
    text = render_report("SELECT 1", "SELECT 2", [_variant(False)], _info(False), command="x")
    assert "## A query that forgets its tenant filter" in text
    assert f"| owner, no RLS | {PENDING} | {PENDING} | {PENDING} |" in text
    measured = render_report("SELECT 1", "SELECT 2", [_variant(True)], _info(True), command="x")
    assert "| owner, no RLS | 2.1 ms | 2.1 ms | 2.1 ms |" in measured
