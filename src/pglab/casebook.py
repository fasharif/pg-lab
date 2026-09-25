"""The performance casebook: before and after plans for the slowest workload statements.

Flow: revert every fix (baseline = TopFlow's own indexes), capture each case's "before" plan,
apply every fix, ANALYZE, capture each "after" plan, check both plans against the case's
expectations and write the Markdown report. The database is left in the tuned state.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import psycopg

from pglab.db import Connection
from pglab.definitions import Case
from pglab.errors import LabError
from pglab.execute import Timing, explain_json, explain_text, measure, render, resolve_params
from pglab.explain import Plan, check_plan, format_blocks
from pglab.report import RunInfo, code, ms, table

TOPFLOW_TABLES = (
    "users",
    "categories",
    "products",
    "carts",
    "cart_items",
    "orders",
    "order_items",
    "audit_logs",
    "organizations",
    "organization_members",
    "quote_requests",
    "quote_request_items",
    "organization_invitations",
    "addresses",
    "quotations",
    "quotation_items",
    "order_status_events",
    "document_sequences",
)


@dataclass(frozen=True)
class Snapshot:
    statement: str
    plan: Plan
    text: str
    failures: tuple[str, ...]
    timing: Timing | None


@dataclass(frozen=True)
class CaseResult:
    case: Case
    params: dict[str, Any]
    before: Snapshot
    after: Snapshot

    @property
    def passed(self) -> bool:
        return not self.before.failures and not self.after.failures


def _run_all(conn: Connection, statements: Sequence[str], what: str) -> None:
    for statement in statements:
        try:
            conn.execute(statement)
        except psycopg.Error as exc:
            raise LabError(f"{what} failed: {exc}\n{statement}") from exc


def analyze(conn: Connection) -> None:
    conn.execute("ANALYZE " + ", ".join(TOPFLOW_TABLES))


def revert_all(conn: Connection, cases: Sequence[Case]) -> None:
    for case in reversed(cases):
        _run_all(conn, case.revert, f"revert of case {case.number}")
    analyze(conn)


def apply_all(conn: Connection, cases: Sequence[Case]) -> None:
    for case in cases:
        _run_all(conn, case.fix, f"fix of case {case.number}")
    analyze(conn)


def _snapshot(
    conn: Connection, sql: str, values: dict[str, Any], case: Case, *, after: bool, runs: int | None
) -> Snapshot:
    statement = render(conn, sql, values)
    plan = explain_json(conn, statement)
    text = explain_text(conn, statement)
    expectation = case.after if after else case.before
    failures = tuple(check_plan(plan, expectation))
    timing = measure(conn, statement, runs) if runs else None
    return Snapshot(statement, plan, text, failures, timing)


def run_casebook(conn: Connection, cases: Sequence[Case], *, runs: int | None) -> list[CaseResult]:
    revert_all(conn, cases)
    params: dict[int, dict[str, Any]] = {}
    befores: dict[int, Snapshot] = {}
    for case in cases:
        params[case.number] = resolve_params(conn, case.query.params)
        befores[case.number] = _snapshot(
            conn, case.query.sql, params[case.number], case, after=False, runs=runs
        )
    apply_all(conn, cases)
    results = []
    for case in cases:
        after = _snapshot(conn, case.after_sql, params[case.number], case, after=True, runs=runs)
        results.append(CaseResult(case, params[case.number], befores[case.number], after))
    return results


def _check_cell(snapshot: Snapshot) -> str:
    return "fail" if snapshot.failures else "pass"


def _expectation_lines(result: CaseResult) -> list[str]:
    lines = []
    for label, snapshot, expectation in (
        ("Before", result.before, result.case.before),
        ("After", result.after, result.case.after),
    ):
        described = expectation.describe()
        if not described:
            continue
        status = "passed" if not snapshot.failures else "FAILED"
        lines.append(f"- {label} ({status}): " + "; ".join(described) + ".")
        lines.extend(f"  - {failure}" for failure in snapshot.failures)
    return lines


def render_report(results: Sequence[CaseResult], info: RunInfo, *, command: str) -> str:
    summary_rows = []
    for r in results:
        summary_rows.append(
            (
                r.case.number,
                f"[{r.case.title}](#{_anchor(r.case)})",
                r.case.fix_kind,
                format_blocks(r.before.plan.shared_buffers()),
                format_blocks(r.after.plan.shared_buffers()),
                ms(r.before.timing.median_ms if r.before.timing else None),
                ms(r.after.timing.median_ms if r.after.timing else None),
                "pass" if r.passed else "FAIL",
            )
        )
    out = [
        "# Performance casebook",
        "",
        "The ten slowest statements of the TopFlow API workload (see `reports/workload.md`), each",
        "with its plan before and after the fix. Plans come from `EXPLAIN (ANALYZE, BUFFERS)`;",
        "CI checks the plan shape of every case (indexes used, nodes present), never timings.",
        "",
        *info.header_lines(command),
        "",
        table(
            [
                "#",
                "Case",
                "Fix",
                "Buffers before",
                "Buffers after",
                "Median before",
                "Median after",
                "Plan checks",
            ],
            summary_rows,
            "rllrrrrc",
        ),
        "",
    ]
    for r in results:
        out += _case_section(r)
    return "\n".join(out)


def _anchor(case: Case) -> str:
    return f"case-{case.number:02d}"


def _case_section(r: CaseResult) -> list[str]:
    case = r.case
    params = ", ".join(f"`{k}` = `{v}`" for k, v in r.params.items()) or "none"
    lines = [
        f'<a id="{_anchor(case)}"></a>',
        "",
        f"## {case.number}. {case.title}",
        "",
        f"- API: `{case.query.api}` (workload id `{case.query.id}`)",
        f"- Fix: {case.fix_kind}",
        f"- Parameters: {params}",
        "",
        "### Why it is slow",
        "",
        case.problem,
        "",
        "### Before",
        "",
        code(r.before.statement, "sql"),
        "",
        code(r.before.text, "text"),
        "",
        "### Fix",
        "",
    ]
    if case.fixed_by is not None:
        lines += [
            f"No change of its own: the index added in [case {case.fixed_by}]"
            f"(#case-{case.fixed_by:02d}) also serves this statement.",
            "",
        ]
    if case.fix:
        lines += [code(";\n\n".join(case.fix) + ";", "sql"), ""]
    if case.rewrite:
        lines += ["The statement is rewritten:", "", code(r.after.statement, "sql"), ""]
    lines += [
        "### After",
        "",
        code(r.after.text, "text"),
        "",
        table(
            ["", "Before", "After"],
            [
                (
                    "Shared buffers",
                    format_blocks(r.before.plan.shared_buffers()),
                    format_blocks(r.after.plan.shared_buffers()),
                ),
                (
                    "Rows returned",
                    f"{r.before.plan.rows() or 0:,.0f}",
                    f"{r.after.plan.rows() or 0:,.0f}",
                ),
                (
                    "Median time",
                    ms(r.before.timing.median_ms if r.before.timing else None),
                    ms(r.after.timing.median_ms if r.after.timing else None),
                ),
                ("Plan checks", _check_cell(r.before), _check_cell(r.after)),
            ],
            "lrr",
        ),
        "",
        *_expectation_lines(r),
        "",
        "### Trade-off",
        "",
        case.tradeoff,
        "",
    ]
    return lines
