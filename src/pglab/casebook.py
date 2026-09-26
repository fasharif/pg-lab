"""The performance casebook: before and after plans for the heaviest workload statements.

Flow: revert every fix (baseline = TopFlow's own indexes), capture each case's "before" plan,
apply every fix, ANALYZE, capture each "after" plan, check both plans against the case's
expectations, check that every rewrite returns the same rows as the original statement, and
write the Markdown report. The database is left in the tuned state.

Applying a fix is idempotent without trusting names alone: an index that already exists under
a fix's name is kept only if it is valid and was built from the same statement (recorded in the
index's comment). An index left invalid by an interrupted concurrent build, or an older
definition under the same name, is dropped and built again.
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg import sql

from pglab.db import Connection
from pglab.definitions import Case
from pglab.errors import LabError
from pglab.execute import Timing, explain_json, explain_text, measure, render, resolve_params
from pglab.explain import Plan, check_plan, format_blocks
from pglab.report import RunInfo, code, ms, table

CREATE_INDEX = re.compile(
    r'CREATE\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?"?(\w+)"?', re.IGNORECASE
)
COMMENT_PREFIX = "pglab casebook fix "

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
class Equivalence:
    """A rewrite compared with the original statement, both run after the fixes."""

    original_rows: int
    rewrite_rows: int
    same: bool

    def describe(self) -> str:
        if self.same:
            return (
                f"the rewrite returns the same {self.rewrite_rows:,} rows as the original "
                "statement, in the same order"
            )
        return (
            "the rewrite does not return the same rows in the same order as the original "
            f"statement ({self.rewrite_rows:,} rows against {self.original_rows:,})"
        )


@dataclass(frozen=True)
class CaseResult:
    case: Case
    params: dict[str, Any]
    before: Snapshot
    after: Snapshot
    equivalence: Equivalence | None = None

    @property
    def passed(self) -> bool:
        return (
            not self.before.failures
            and not self.after.failures
            and (self.equivalence is None or self.equivalence.same)
        )


def _run_all(conn: Connection, statements: Sequence[str], what: str) -> None:
    for statement in statements:
        try:
            conn.execute(statement)
        except psycopg.Error as exc:
            raise LabError(f"{what} failed: {exc}\n{statement}") from exc


def analyze(conn: Connection) -> None:
    conn.execute("ANALYZE " + ", ".join(TOPFLOW_TABLES))


def statement_tag(statement: str) -> str:
    """The comment that records which statement built an index (whitespace-insensitive)."""
    digest = hashlib.sha256(" ".join(statement.split()).encode("utf-8")).hexdigest()
    return COMMENT_PREFIX + digest[:16]


def _index_state(conn: Connection, name: str) -> tuple[bool, str | None] | None:
    """(valid, comment) of an index in schema public, or None when there is none."""
    row = conn.execute(
        "SELECT x.indisvalid, obj_description(c.oid, 'pg_class')"
        " FROM pg_class AS c JOIN pg_index AS x ON x.indexrelid = c.oid"
        " WHERE c.relname = %s AND c.relnamespace = 'public'::regnamespace",
        (name,),
    ).fetchone()
    return None if row is None else (bool(row[0]), row[1])


def _create_index(conn: Connection, statement: str, name: str, *, tagged: bool, what: str) -> None:
    """Run CREATE INDEX ... IF NOT EXISTS so that the index it names is valid and current.

    tagged: the index is the lab's own (a casebook fix), so its comment must match the
    statement; TopFlow's own indexes (restored by a revert) are only checked for validity."""
    tag = statement_tag(statement)
    state = _index_state(conn, name)
    if state is not None:
        valid, comment = state
        if not valid or (tagged and comment != tag):
            reason = "invalid" if not valid else "built from another definition"
            print(f"rebuilding index {name}: {reason}")
            conn.execute(
                sql.SQL("DROP INDEX CONCURRENTLY IF EXISTS {}").format(
                    sql.Identifier("public", name)
                )
            )
    _run_all(conn, (statement,), what)
    state = _index_state(conn, name)
    if state is None or not state[0]:
        raise LabError(f"{what}: index {name} is missing or invalid after\n{statement}")
    if tagged and state[1] != tag:
        conn.execute(
            sql.SQL("COMMENT ON INDEX {} IS {}").format(
                sql.Identifier("public", name), sql.Literal(tag)
            )
        )


def _apply(conn: Connection, statements: Sequence[str], what: str, *, tagged: bool) -> None:
    for statement in statements:
        match = CREATE_INDEX.search(statement)
        if match and re.search(r"IF\s+NOT\s+EXISTS", statement, re.IGNORECASE):
            _create_index(conn, statement, match.group(1), tagged=tagged, what=what)
        else:
            _run_all(conn, (statement,), what)


def revert_all(conn: Connection, cases: Sequence[Case]) -> None:
    for case in reversed(cases):
        _apply(conn, case.revert, f"revert of case {case.number}", tagged=False)
    analyze(conn)


def apply_all(conn: Connection, cases: Sequence[Case]) -> None:
    for case in cases:
        _apply(conn, case.fix, f"fix of case {case.number}", tagged=True)
    analyze(conn)


def compare_rewrite(conn: Connection, case: Case, params: dict[str, Any]) -> Equivalence:
    """Run the original statement and its rewrite; both must return the same rows in order."""
    original = conn.execute(render(conn, case.query.sql, params)).fetchall()
    rewritten = conn.execute(render(conn, case.after_sql, params)).fetchall()
    return Equivalence(len(original), len(rewritten), original == rewritten)


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
        equivalence = compare_rewrite(conn, case, params[case.number]) if case.rewrite else None
        results.append(
            CaseResult(case, params[case.number], befores[case.number], after, equivalence)
        )
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
    if result.equivalence is not None:
        status = "passed" if result.equivalence.same else "FAILED"
        lines.append(f"- Rewrite ({status}): {result.equivalence.describe()}.")
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
        "The ten heaviest statements of the TopFlow API workload by shared buffers touched (see",
        "`reports/workload.md`), each with its plan before and after the fix. Plans come from",
        "`EXPLAIN (ANALYZE, BUFFERS)`; CI checks the plan shape of every case (indexes used, nodes",
        "present) and that a rewritten statement returns the same rows, never timings.",
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
