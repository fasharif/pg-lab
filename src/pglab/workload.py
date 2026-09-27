"""Runs every workload statement and ranks them by the work they do.

Functional runs rank by shared buffers touched (hit + read, from EXPLAIN ANALYZE BUFFERS).
Buffer counts depend on the data and the plan rather than on how busy the machine is, so that
ranking can be made on a shared laptop (a parallel plan's count varies a little with its
workers). Buffers are a stand-in for time: measured runs (--measure, quiet machine only) rank
by median time instead.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

from pglab.db import Connection
from pglab.definitions import Case, WorkloadQuery
from pglab.execute import Timing, explain_json, measure, render, resolve_params
from pglab.explain import Plan, format_blocks, summarise
from pglab.report import RunInfo, ms, table


@dataclass(frozen=True)
class WorkloadResult:
    query: WorkloadQuery
    statement: str
    plan: Plan
    timing: Timing | None


def run_workload(
    conn: Connection, queries: Iterable[WorkloadQuery], *, runs: int | None
) -> list[WorkloadResult]:
    results: list[WorkloadResult] = []
    for query in queries:
        values = resolve_params(conn, query.params)
        statement = render(conn, query.sql, values)
        plan = explain_json(conn, statement)
        timing = measure(conn, statement, runs) if runs else None
        results.append(WorkloadResult(query, statement, plan, timing))
    return results


def casebook_labels(cases: Sequence[Case]) -> dict[str, str]:
    """Casebook column of the ranking: 'case 4' for a case's statement, 'case 4 (total)' for
    the pagination total fixed in the same case."""
    labels = {case.query.id: f"case {case.number}" for case in cases}
    for case in cases:
        if case.total is not None:
            labels[case.total.query.id] = f"case {case.number} (total)"
    return labels


def _median_ms(result: WorkloadResult) -> float:
    return result.timing.median_ms if result.timing is not None else 0.0


def is_timed(results: Sequence[WorkloadResult]) -> bool:
    """True for a measured run: every statement has its median time."""
    return bool(results) and all(r.timing is not None for r in results)


def rank(results: Sequence[WorkloadResult]) -> list[WorkloadResult]:
    """Most work first. A measured run ranks by median time (planning plus execution); a
    functional run by shared buffers, then temporary buffers. The id keeps the order stable."""
    if is_timed(results):
        return sorted(results, key=lambda r: (-_median_ms(r), r.query.id))
    return sorted(
        results,
        key=lambda r: (-r.plan.shared_buffers(), -r.plan.temp_buffers(), r.query.id),
    )


def render_report(
    results: Sequence[WorkloadResult],
    info: RunInfo,
    *,
    command: str,
    casebook_queries: Mapping[str, str],
    state: str,
) -> str:
    ranked = rank(results)
    rows = []
    for position, result in enumerate(ranked, start=1):
        case = casebook_queries.get(result.query.id)
        rows.append(
            (
                position,
                f"`{result.query.id}`",
                result.query.title,
                f"{result.plan.rows():,.0f}" if result.plan.rows() is not None else "",
                format_blocks(result.plan.shared_buffers()),
                summarise(result.plan),
                ms(result.timing.median_ms if result.timing else None),
                case or "",
            )
        )
    lines = [
        "# Workload ranking",
        "",
        *_basis_lines(is_timed(results)),
        f"Schema state: **{state}**.",
        "",
        *info.header_lines(command),
        "",
        table(
            [
                "#",
                "Query",
                "What the API does",
                "Rows",
                "Shared buffers",
                "Main access path",
                "Median time",
                "Casebook",
            ],
            rows,
            "rllrrllr",
        ),
        "",
        "The casebook (`reports/casebook.md`) was chosen from the top of the buffer ranking at",
        "SCALE=1000000, the reference scale: one case per statement, except that a pagination",
        "total is fixed in its page's case (marked total). Buffers stand in for time until a",
        "measured run (`./lab workload --measure`) ranks the workload by median time;",
        "docs/benchmarking.md says what happens when that ranking differs. Regenerate with",
        "`./lab workload`.",
        "",
    ]
    return "\n".join(lines)


def _basis_lines(timed: bool) -> list[str]:
    if timed:
        return [
            "Every read statement of the TopFlow API in `workload/queries.toml`, timed with",
            "`EXPLAIN (ANALYZE)` and ranked by median time (planning plus execution); the shared",
            "buffers of one `EXPLAIN (ANALYZE, BUFFERS)` run are shown for comparison.",
        ]
    return [
        "Every read statement of the TopFlow API in `workload/queries.toml`, run once with",
        "`EXPLAIN (ANALYZE, BUFFERS)` and ranked by the shared buffers it touched (8 kB pages",
        "found in or read into shared buffers).",
    ]
