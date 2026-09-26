"""SQL Server chapter: read sqlcmd output (actual plans and logical reads) and check the plans.

./lab sqlserver casebook runs the ten statements with SET STATISTICS XML ON and SET STATISTICS
IO ON before and after the fixes. sqlcmd prints, for each statement, a "=== case NN" marker,
the showplan XML and one "Table 'x'. Scan count n, logical reads n, ..." line per table. This
module splits that output per case, extracts the operators and indexes of each plan, sums the
logical reads (SQL Server's counterpart of PostgreSQL's shared buffers) and checks
sqlserver/expectations.toml.
"""

from __future__ import annotations

import re
import tomllib
import xml.etree.ElementTree as ET
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pglab.errors import LabError
from pglab.report import RunInfo, table

SHOWPLAN_NS = "{http://schemas.microsoft.com/sqlserver/2004/07/showplan}"
CASE_MARKER = re.compile(r"^=== case (\d{2})\s*$", re.MULTILINE)
SHOWPLAN = re.compile(r"<ShowPlanXML\b.*?</ShowPlanXML>", re.DOTALL)
LOGICAL_READS = re.compile(r"logical reads (\d+)")


@dataclass(frozen=True)
class MssqlPlan:
    operators: tuple[str, ...]
    indexes: frozenset[str]
    tables: frozenset[str]


@dataclass(frozen=True)
class CaseOutput:
    number: str
    plans: tuple[MssqlPlan, ...]
    logical_reads: int

    @property
    def operators(self) -> set[str]:
        return {op for plan in self.plans for op in plan.operators}

    @property
    def indexes(self) -> set[str]:
        return {index for plan in self.plans for index in plan.indexes}


def _unbracket(name: str) -> str:
    return name[1:-1] if name.startswith("[") and name.endswith("]") else name


def parse_showplan(xml_text: str) -> MssqlPlan:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        raise LabError(f"not a showplan document: {exc}") from exc
    operators: list[str] = []
    indexes: set[str] = set()
    tables: set[str] = set()
    for relop in root.iter(f"{SHOWPLAN_NS}RelOp"):
        operators.append(relop.get("PhysicalOp", "?"))
    for obj in root.iter(f"{SHOWPLAN_NS}Object"):
        if obj.get("Index"):
            indexes.add(_unbracket(obj.get("Index", "")))
        if obj.get("Table"):
            tables.add(_unbracket(obj.get("Table", "")))
    return MssqlPlan(tuple(operators), frozenset(indexes), frozenset(tables))


def split_cases(output: str) -> dict[str, CaseOutput]:
    """One CaseOutput per "=== case NN" marker, with the plans and reads that follow it."""
    markers = list(CASE_MARKER.finditer(output))
    if not markers:
        raise LabError("no '=== case NN' markers in the sqlcmd output")
    cases: dict[str, CaseOutput] = {}
    for index, marker in enumerate(markers):
        end = markers[index + 1].start() if index + 1 < len(markers) else len(output)
        chunk = output[marker.end() : end]
        plans = tuple(parse_showplan(match.group(0)) for match in SHOWPLAN.finditer(chunk))
        reads = sum(int(value) for value in LOGICAL_READS.findall(chunk))
        cases[marker.group(1)] = CaseOutput(marker.group(1), plans, reads)
    return cases


@dataclass(frozen=True)
class Expectation:
    title: str
    index_used: tuple[str, ...] = ()
    index_not_used: tuple[str, ...] = ()
    operator_absent: tuple[str, ...] = ()


def load_expectations(path: Path) -> dict[str, Expectation]:
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise LabError(f"cannot read {path}: {exc}") from exc
    cases = document.get("case")
    if not isinstance(cases, dict) or not cases:
        raise LabError(f"{path}: expected [case.NN] tables")
    result: dict[str, Expectation] = {}
    for number, raw in cases.items():
        if not isinstance(raw, dict) or not isinstance(raw.get("title"), str):
            raise LabError(f"{path}: case {number} needs a title")
        values: dict[str, Any] = {"title": raw["title"]}
        for key in ("index_used", "index_not_used", "operator_absent"):
            items = raw.get(key, [])
            if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
                raise LabError(f"{path}: case {number} {key} must be a list of strings")
            values[key] = tuple(items)
        result[str(number)] = Expectation(**values)
    return result


def check(case: CaseOutput, expectation: Expectation) -> list[str]:
    failures = []
    if not case.plans:
        failures.append("no execution plan in the output")
    for name in expectation.index_used:
        if name not in case.indexes:
            failures.append(f"expected index {name}; plan uses {sorted(case.indexes) or 'none'}")
    for name in expectation.index_not_used:
        if name in case.indexes:
            failures.append(f"index {name} should not be used")
    for operator in expectation.operator_absent:
        if operator in case.operators:
            failures.append(f"plan still has a {operator} operator")
    return failures


def render(
    before: Mapping[str, CaseOutput],
    after: Mapping[str, CaseOutput],
    expectations: Mapping[str, Expectation],
    info: RunInfo,
    *,
    command: str,
) -> str:
    rows = []
    for number, expectation in sorted(expectations.items()):
        b, a = before.get(number), after.get(number)
        failures = check(a, expectation) if a else ["case missing from the output"]
        rows.append(
            (
                number,
                expectation.title,
                f"{b.logical_reads:,}" if b else "missing",
                f"{a.logical_reads:,}" if a else "missing",
                ", ".join(sorted(a.indexes)) if a else "",
                "pass" if not failures else "FAIL: " + "; ".join(failures),
            )
        )
    lines = [
        "# SQL Server casebook",
        "",
        "The ten PostgreSQL casebook statements on SQL Server 2022 Developer edition, before and",
        "after the fixes in `sqlserver/sql/20_fixes.sql`. Logical reads are SQL Server's",
        "counterpart of PostgreSQL's shared buffers (8 kB pages read from the buffer pool).",
        "",
        *info.header_lines(command),
        "",
        table(
            [
                "#",
                "Statement",
                "Logical reads before",
                "Logical reads after",
                "Indexes used after",
                "Plan check",
            ],
            rows,
            "rlrrll",
        ),
        "",
    ]
    return "\n".join(lines)
