"""SQL Server chapter: parsing sqlcmd output (synthetic fixture, SQL Server was not run)."""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab.errors import LabError
from pglab.mssql import (
    Expectation,
    check,
    load_expectations,
    parse_showplan,
    render,
    split_cases,
)
from tests.unit.test_reports import info


def output(root: Path) -> str:
    path = root / "tests" / "fixtures" / "mssql" / "sqlcmd-output-synthetic.txt"
    return path.read_text(encoding="utf-8")


def test_cases_are_split_on_markers(root: Path) -> None:
    cases = split_cases(output(root))
    assert set(cases) == {"01", "03"}
    assert cases["01"].logical_reads == 14
    assert cases["03"].logical_reads == 30115


def test_operators_and_indexes_come_from_the_showplan(root: Path) -> None:
    cases = split_cases(output(root))
    assert cases["01"].indexes == {"audit_logs_action_idx"}
    assert "Index Seek" in cases["01"].operators
    assert cases["03"].operators == {"Top N Sort", "Clustered Index Scan"}
    assert cases["03"].plans[0].tables == frozenset({"audit_logs"})


def test_checks_report_missing_indexes_and_leftover_operators(root: Path) -> None:
    cases = split_cases(output(root))
    good = Expectation("t", index_used=("audit_logs_action_idx",))
    assert check(cases["01"], good) == []
    bad = Expectation(
        "t",
        index_used=("audit_logs_userId_createdAt_idx",),
        index_not_used=("audit_logs_pkey",),
        operator_absent=("Top N Sort",),
    )
    assert len(check(cases["03"], bad)) == 3


def test_repository_expectations_cover_the_ten_cases(root: Path) -> None:
    expectations = load_expectations(root / "sqlserver" / "expectations.toml")
    assert sorted(expectations) == [f"{n:02d}" for n in range(1, 11)]
    assert all(e.index_used or e.operator_absent for e in expectations.values())


def test_invalid_input_is_explained() -> None:
    with pytest.raises(LabError, match="no '=== case NN' markers"):
        split_cases("nothing here")
    with pytest.raises(LabError, match="not a showplan document"):
        parse_showplan("<ShowPlanXML")


def test_report_lists_every_case(root: Path) -> None:
    cases = split_cases(output(root))
    expectations = {"01": Expectation("Action prefix", index_used=("audit_logs_action_idx",))}
    text = render(cases, cases, expectations, info(), command="./lab sqlserver casebook")
    assert "| 01 | Action prefix | 14 | 14 | audit_logs_action_idx | pass |" in text
