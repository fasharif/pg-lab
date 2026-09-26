"""Markdown rendering, report headers, workload ranking and the timing policy."""

from __future__ import annotations

import pytest

from pglab.casebook import CREATE_INDEX, statement_tag
from pglab.definitions import WorkloadQuery
from pglab.execute import Timing, is_timing_line
from pglab.indexing import human_bytes
from pglab.report import PENDING, RunInfo, code, ms, table, timing_cell
from pglab.workload import WorkloadResult, rank, render_report
from tests.conftest import load_plan


def info(measured: bool = False) -> RunInfo:
    return RunInfo(
        postgres_version="PostgreSQL 18.6",
        scale="100000",
        anchor="2026-09-25 21:00:00",
        environment="test",
        generated_at="2026-09-26 00:00 UTC",
        measured=measured,
        runs=15,
    )


def test_table_escapes_pipes_and_aligns_columns() -> None:
    text = table(["a", "b"], [("x|y", 1)], "lr")
    assert text.splitlines() == ["| a | b |", "| --- | ---: |", "| x\\|y | 1 |"]
    with pytest.raises(ValueError, match="row has 1 cells"):
        table(["a", "b"], [("x",)])


def test_code_blocks_survive_backticks_in_content() -> None:
    assert code("select 1", "sql") == "```sql\nselect 1\n```"
    assert code("a ``` b").startswith("````")


def test_timings_are_pending_unless_measured() -> None:
    assert ms(None) == PENDING
    assert ms(1234.5) == "1,234 ms"
    assert ms(12.34) == "12.3 ms"
    assert ms(0.1234) == "0.123 ms"
    assert "pending a measured run" in "\n".join(info().header_lines("./lab x"))
    assert "median of 15 runs" in "\n".join(info(measured=True).header_lines("./lab x"))


def test_timing_lines_are_recognised() -> None:
    assert is_timing_line("        I/O Timings: shared read=414.085")
    assert is_timing_line("Execution Time: 3.2 ms")
    assert not is_timing_line("  Buffers: shared hit=10")
    assert not is_timing_line("Sort Method: top-N heapsort  Memory: 45kB")


def test_timing_median() -> None:
    assert Timing((5.0, 1.0, 3.0)).median_ms == 3.0
    # With planning times, the median is taken over planning plus execution per run.
    timing = Timing((5.0, 1.0, 3.0), (0.5, 4.0, 0.1))
    assert timing.median_ms == 5.0
    assert timing.median_execution_ms == 3.0
    assert timing.median_planning_ms == 0.5
    assert Timing((1.0,)).median_planning_ms is None


def test_timing_cells_show_the_planning_share() -> None:
    assert timing_cell(None, None) == PENDING
    assert timing_cell(12.34, 0.41) == "12.3 ms (planning 0.410 ms)"
    assert timing_cell(250.0, None) == "250 ms"


def _result(query_id: str, plan_name: str) -> WorkloadResult:
    query = WorkloadQuery(query_id, query_id, "apps/api/src/x.ts:1 f", "SELECT 1", {})
    return WorkloadResult(query, "SELECT 1", load_plan(plan_name), None)


def test_ranking_puts_the_most_buffers_first() -> None:
    results = [
        _result("small", "orders-org-history.after"),
        _result("large", "orders-org-history.before"),
    ]
    assert [r.query.id for r in rank(results)] == ["large", "small"]


def test_workload_report_marks_casebook_entries() -> None:
    text = render_report(
        [_result("large", "orders-org-history.before")],
        info(),
        command="./lab workload",
        casebook_queries={"large": 8},
        state="baseline",
    )
    assert "| 1 | `large` |" in text
    assert "case 8" in text
    assert PENDING in text


def test_index_names_are_extracted_from_fix_statements() -> None:
    match = CREATE_INDEX.search('CREATE INDEX CONCURRENTLY "orders_createdAt_idx" ON orders (x)')
    assert match is not None
    assert match.group(1) == "orders_createdAt_idx"
    match = CREATE_INDEX.search("CREATE INDEX CONCURRENTLY IF NOT EXISTS plain_idx ON t (x)")
    assert match is not None
    assert match.group(1) == "plain_idx"


def test_human_bytes() -> None:
    assert human_bytes(512) == "512 B"
    assert human_bytes(24576) == "24.0 kB"
    assert human_bytes(8_300_000) == "7.9 MB"


def test_statement_tag_ignores_whitespace_and_tracks_the_definition() -> None:
    one = 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "i" ON orders ("createdAt")'
    same = 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "i"\n    ON orders  ("createdAt")'
    other = 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "i" ON orders ("createdAt") INCLUDE (x)'
    assert statement_tag(one) == statement_tag(same)
    assert statement_tag(one) != statement_tag(other)
    assert statement_tag(one).startswith("pglab casebook fix ")
