"""Markdown rendering, report headers, workload ranking and the timing policy."""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab import casebook
from pglab.casebook import (
    CREATE_INDEX,
    CaseResult,
    Equivalence,
    Snapshot,
    TotalResult,
    statement_tag,
)
from pglab.definitions import Case, WorkloadQuery, load_cases, load_workload
from pglab.execute import Timing, is_timing_line
from pglab.explain import check_plan
from pglab.indexing import human_bytes
from pglab.report import PENDING, RunInfo, code, ms, table, timing_cell
from pglab.workload import WorkloadResult, casebook_labels, rank, render_report
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


def test_the_header_says_what_kind_of_durations_a_report_holds() -> None:
    drill = RunInfo("PostgreSQL 18.6", "100", "a", "e", "g", True, 1, durations="drill")
    assert "one drill run" in drill.timing_note()
    assert "median" not in drill.timing_note()
    pending = RunInfo("PostgreSQL 18.6", "100", "a", "e", "g", False, 1, durations="drill")
    assert pending.timing_note().startswith(PENDING)
    sizes = RunInfo("PostgreSQL 18.6", "100", "a", "e", "g", False, 0, durations="none")
    assert sizes.timing_note().startswith("none in this report")
    assert PENDING not in "\n".join(sizes.header_lines("./lab indexing"))


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


def _result(query_id: str, plan_name: str, median_ms: float | None = None) -> WorkloadResult:
    query = WorkloadQuery(query_id, query_id, "apps/api/src/x.ts:1 f", "SELECT 1", {})
    timing = Timing((median_ms,)) if median_ms is not None else None
    return WorkloadResult(query, "SELECT 1", load_plan(plan_name), timing)


def test_ranking_puts_the_most_buffers_first() -> None:
    results = [
        _result("small", "orders-org-history.after"),
        _result("large", "orders-org-history.before"),
    ]
    assert [r.query.id for r in rank(results)] == ["large", "small"]


def test_a_measured_run_ranks_by_median_time() -> None:
    # Fewer buffers but slower (a CPU-heavy filter, say): time decides in a measured run.
    results = [
        _result("many-buffers", "orders-org-history.before", median_ms=1.5),
        _result("few-buffers", "orders-org-history.after", median_ms=30.0),
    ]
    assert [r.query.id for r in rank(results)] == ["few-buffers", "many-buffers"]
    text = render_report(
        results,
        info(measured=True),
        command="./lab workload --measure",
        casebook_queries={},
        state="baseline",
    )
    assert "ranked by median time" in text
    assert "| 1 | `few-buffers` |" in text


def test_workload_report_marks_casebook_entries() -> None:
    text = render_report(
        [
            _result("large", "orders-org-history.before"),
            _result("large-count", "orders-org-history.after"),
        ],
        info(),
        command="./lab workload",
        casebook_queries={"large": "case 8", "large-count": "case 8 (total)"},
        state="baseline",
    )
    assert "| 1 | `large` |" in text
    assert "| case 8 |" in text
    assert "| case 8 (total) |" in text
    assert "ranked by the shared buffers" in text
    assert PENDING in text


def _cases(root: Path) -> list[Case]:
    return load_cases(root / "casebook", load_workload(root / "workload" / "queries.toml"))


def test_casebook_labels_mark_the_pagination_total(root: Path) -> None:
    labels = casebook_labels(_cases(root))
    assert labels["orders-admin-search"] == "case 4"
    assert labels["orders-admin-search-count"] == "case 4 (total)"
    assert labels["catalogue-categories"] == "case 9"


def _snapshot(plan_name: str, failures: tuple[str, ...] = ()) -> Snapshot:
    return Snapshot("SELECT 1", load_plan(plan_name), "plan text", failures, None)


def test_casebook_report_shows_a_total_in_its_case(root: Path) -> None:
    case = _cases(root)[3]
    assert case.total is not None
    before, after = _snapshot("orders-admin-search.before"), _snapshot("orders-admin-search.after")
    total = TotalResult(case.total, {}, before, after, Equivalence(1, 1, same=True))
    result = CaseResult(case, {}, before, after, Equivalence(20, 20, same=True), total)
    assert result.passed
    text = casebook.render_report([result], info(), command="./lab casebook")
    assert '<a id="case-04-total"></a>' in text
    assert "### The pagination total" in text
    assert "(#case-04-total) | same fix as the page, rewritten to count the matches |" in text
    assert "the rewrite returns the same 1 row as" in text
    # A failing total fails its case, and only its own row in the summary.
    broken = TotalResult(case.total, {}, before, _snapshot("orders-admin-search.after", ("x",)))
    failed = CaseResult(case, {}, before, after, Equivalence(20, 20, same=True), broken)
    assert not failed.passed
    rows = [
        line
        for line in casebook.render_report([failed], info(), command="x").splitlines()
        if line.startswith("| 4 |")
    ]
    assert [row.endswith("| pass |") for row in rows] == [True, False]


def test_casebook_report_says_how_each_case_was_chosen(root: Path) -> None:
    cases = _cases(root)
    before, after = _snapshot("orders-admin-search.before"), _snapshot("orders-admin-search.after")
    results = [CaseResult(case, {}, before, after) for case in cases]
    text = casebook.render_report(results, info(), command="./lab casebook")
    assert "The casebook first held 10 cases, chosen by shared buffers touched" in text
    assert "It added case 11, which the buffer ranking missed." in text
    assert "Cases 8, 9 and 10 fell outside the ten slowest statements and stay;" in text
    chosen = [line for line in text.splitlines() if line.startswith("- Chosen by: ")]
    assert len(chosen) == len(cases)
    assert chosen[10].startswith("- Chosen by: median time in the measured run")
    assert chosen[7].startswith("- Chosen by: shared buffers at SCALE=1000000. The measured")


def test_the_total_expectations_of_case_4_hold_on_recorded_plans(root: Path) -> None:
    case = _cases(root)[3]
    assert case.total is not None
    before = load_plan("orders-admin-search-count.before")
    after = load_plan("orders-admin-search-count.after")
    indexes_only = load_plan("orders-admin-search-count.tuned-without-rewrite")
    assert check_plan(before, case.total.before) == []
    assert check_plan(after, case.total.after) == []
    # With the trigram indexes but without the rewrite, the count still reads every order.
    assert "orders" in indexes_only.seq_scanned()
    assert check_plan(indexes_only, case.total.after) != []


def test_the_expectations_of_case_11_hold_on_recorded_plans(root: Path) -> None:
    case = _cases(root)[10]
    assert case.total is not None
    assert check_plan(load_plan("rfq-admin-search.before"), case.before) == []
    assert check_plan(load_plan("rfq-admin-search.after"), case.after) == []
    assert check_plan(load_plan("rfq-admin-search-count.before"), case.total.before) == []
    after = load_plan("rfq-admin-search-count.after")
    assert check_plan(after, case.total.after) == []
    # One multicolumn GIN index answers the five patterns on quote_requests: five bitmap scans
    # of the same index under one BitmapOr.
    scans = [n for n in after.nodes() if n.index == "quote_requests_search_trgm_idx"]
    assert len(scans) == 5
    assert "BitmapOr" in after.node_types()
    # With the index but without the rewrite, the count still reads every quote request.
    indexes_only = load_plan("rfq-admin-search-count.tuned-without-rewrite")
    assert "quote_requests" in indexes_only.seq_scanned()
    assert check_plan(indexes_only, case.total.after) != []


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
