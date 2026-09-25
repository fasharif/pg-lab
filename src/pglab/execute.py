"""Running workload statements: parameters, EXPLAIN and timed runs.

Functional runs (the default) use EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY OFF): the
plan with actual row counts and buffer counts but no durations, so nothing time-dependent
reaches a report. Measured runs time the statement with EXPLAIN (ANALYZE, TIMING OFF,
SUMMARY ON) and keep the server-side execution time of each run.
"""

from __future__ import annotations

import json
import statistics
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg import ClientCursor

from pglab.db import Connection
from pglab.errors import LabError
from pglab.explain import Plan, parse_plan


def resolve_params(conn: Connection, params: Mapping[str, str]) -> dict[str, Any]:
    """Evaluate each parameter's SQL expression; each must return exactly one non-null value."""
    values: dict[str, Any] = {}
    for name, expression in params.items():
        try:
            rows = conn.execute(expression).fetchall()
        except psycopg.Error as exc:
            raise LabError(f"parameter {name}: {expression!r} failed: {exc}") from exc
        if len(rows) != 1 or len(rows[0]) != 1 or rows[0][0] is None:
            raise LabError(f"parameter {name}: {expression!r} must return one non-null value")
        values[name] = rows[0][0]
    return values


def render(conn: Connection, sql: str, values: Mapping[str, Any]) -> str:
    """The statement with parameters inlined as SQL literals (what the report shows)."""
    with ClientCursor(conn) as cursor:
        return cursor.mogrify(sql, dict(values))


def explain_json(conn: Connection, statement: str, *, timing: bool = False) -> Plan:
    options = "ANALYZE, BUFFERS, FORMAT JSON, " + (
        "TIMING ON, SUMMARY ON" if timing else "TIMING OFF, SUMMARY OFF"
    )
    return parse_plan(explain_raw(conn, statement, options)[0][0])


def explain_text(conn: Connection, statement: str, *, timing: bool = False) -> str:
    """Text plan. Without `timing`, durations are removed: TIMING OFF and SUMMARY OFF drop
    node and statement times, and the "I/O Timings" lines that track_io_timing adds even
    then are filtered out here."""
    options = "ANALYZE, BUFFERS, " + (
        "TIMING ON, SUMMARY ON" if timing else "TIMING OFF, SUMMARY OFF"
    )
    lines = [str(row[0]) for row in explain_raw(conn, statement, options)]
    if not timing:
        lines = [line for line in lines if not is_timing_line(line)]
    return "\n".join(lines)


def is_timing_line(line: str) -> bool:
    """Plan lines that report durations (I/O timings, JIT timings, planning/execution time)."""
    stripped = line.strip()
    return stripped.startswith(("I/O Timings:", "Timing:", "Planning Time:", "Execution Time:"))


def explain_raw(conn: Connection, statement: str, options: str) -> list[tuple[Any, ...]]:
    try:
        rows = conn.execute(f"EXPLAIN ({options}) {statement}").fetchall()
    except psycopg.Error as exc:
        raise LabError(f"EXPLAIN failed: {exc}\n{statement}") from exc
    if rows and isinstance(rows[0][0], str) and "FORMAT JSON" in options:
        return [(json.loads(rows[0][0]),)]
    return rows


@dataclass(frozen=True)
class Timing:
    runs: tuple[float, ...]

    @property
    def median_ms(self) -> float:
        return statistics.median(self.runs)


def measure(conn: Connection, statement: str, runs: int, warmup: int = 1) -> Timing:
    """Median-ready server-side execution times (ms) of `runs` executions after `warmup`."""
    if runs < 1:
        raise LabError("measured runs need --runs of at least 1")
    samples: list[float] = []
    for index in range(warmup + runs):
        rows = explain_raw(conn, statement, "ANALYZE, TIMING OFF, SUMMARY ON, FORMAT JSON")
        plan = parse_plan(rows[0][0])
        if plan.execution_ms is None:
            raise LabError("EXPLAIN did not report an execution time")
        if index >= warmup:
            samples.append(plan.execution_ms)
    return Timing(tuple(samples))
