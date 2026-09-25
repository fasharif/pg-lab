"""The workload and casebook definitions: the real files are valid, and mistakes are reported."""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab.definitions import load_cases, load_workload, placeholders
from pglab.errors import LabError

VALID_QUERY = """
[[query]]
id = "orders-page"
title = "Orders"
api = "apps/api/src/orders/orders.service.ts:1 OrdersService.list"
params = { org_id = "SELECT 1" }
sql = "SELECT * FROM orders WHERE \\"organizationId\\" = %(org_id)s"
"""


def write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="utf-8")
    return path


def test_repository_workload_and_casebook_are_valid(root: Path) -> None:
    queries = load_workload(root / "workload" / "queries.toml")
    cases = load_cases(root / "casebook", queries)
    assert len(queries) >= 25
    assert [case.number for case in cases] == list(range(1, 11))
    for case in cases:
        assert case.after.describe(), f"case {case.number} checks nothing after the fix"
        assert case.problem
        assert case.tradeoff


def test_every_casebook_index_is_created_concurrently(root: Path) -> None:
    queries = load_workload(root / "workload" / "queries.toml")
    for case in load_cases(root / "casebook", queries):
        for statement in case.fix + case.revert:
            if "INDEX" in statement:
                assert "CONCURRENTLY" in statement, f"case {case.number}: {statement}"


def test_shared_fixes_point_at_cases_that_have_a_fix(root: Path) -> None:
    queries = load_workload(root / "workload" / "queries.toml")
    cases = {case.number: case for case in load_cases(root / "casebook", queries)}
    for case in cases.values():
        if case.fixed_by is not None:
            assert cases[case.fixed_by].fix


def test_placeholders_are_named_and_percent_signs_are_rejected() -> None:
    assert placeholders("SELECT %(a)s, %(b)s, %(a)s") == {"a", "b"}
    assert placeholders("SELECT 5 %% 2") == set()
    with pytest.raises(LabError, match="not a %\\(name\\)s placeholder"):
        placeholders("SELECT * FROM t WHERE name LIKE 'a%'")


def test_workload_rejects_unused_or_missing_parameters(tmp_path: Path) -> None:
    text = VALID_QUERY.replace('params = { org_id = "SELECT 1" }', "params = {}")
    with pytest.raises(LabError, match="do not match params"):
        load_workload(write(tmp_path / "q.toml", text))


def test_workload_rejects_duplicate_ids_and_bad_sources(tmp_path: Path) -> None:
    with pytest.raises(LabError, match="duplicate id"):
        load_workload(write(tmp_path / "q.toml", VALID_QUERY + VALID_QUERY))
    bad_source = VALID_QUERY.replace("apps/api/src/orders/orders.service.ts:1", "orders.ts")
    with pytest.raises(LabError, match="'api' must look like"):
        load_workload(write(tmp_path / "q.toml", bad_source))


def test_cases_must_be_numbered_without_gaps(tmp_path: Path) -> None:
    queries = load_workload(write(tmp_path / "q.toml", VALID_QUERY))
    cases_dir = tmp_path / "cases"
    cases_dir.mkdir()
    case = """
query = "orders-page"
fix_kind = "index"
problem = "slow"
tradeoff = "costs"
fix = ["CREATE INDEX CONCURRENTLY x ON orders (id)"]
revert = ["DROP INDEX CONCURRENTLY IF EXISTS x"]
[after]
index_used = ["x"]
"""
    write(cases_dir / "02-orders.toml", case)
    with pytest.raises(LabError, match="expected case number 01"):
        load_cases(cases_dir, queries)
    (cases_dir / "02-orders.toml").rename(cases_dir / "01-orders.toml")
    assert load_cases(cases_dir, queries)[0].slug == "orders"


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ('query = "orders-page"', 'query = "missing"'),
        ('[after]\nindex_used = ["x"]', "[after]"),
        ('revert = ["DROP INDEX CONCURRENTLY IF EXISTS x"]', ""),
    ],
)
def test_invalid_cases_are_explained(tmp_path: Path, change: str, message: str) -> None:
    queries = load_workload(write(tmp_path / "q.toml", VALID_QUERY))
    cases_dir = tmp_path / "cases"
    cases_dir.mkdir()
    case = """
query = "orders-page"
fix_kind = "index"
problem = "slow"
tradeoff = "costs"
fix = ["CREATE INDEX CONCURRENTLY x ON orders (id)"]
revert = ["DROP INDEX CONCURRENTLY IF EXISTS x"]
[after]
index_used = ["x"]
"""
    write(cases_dir / "01-orders.toml", case.replace(change, message))
    with pytest.raises(LabError):
        load_cases(cases_dir, queries)


def test_fixed_by_must_reference_a_case_with_a_fix(tmp_path: Path) -> None:
    queries = load_workload(write(tmp_path / "q.toml", VALID_QUERY))
    cases_dir = tmp_path / "cases"
    cases_dir.mkdir()
    write(
        cases_dir / "01-orders.toml",
        'query = "orders-page"\nfix_kind = "k"\nproblem = "p"\ntradeoff = "t"\n'
        'fixed_by = 1\n[after]\nindex_used = ["x"]\n',
    )
    with pytest.raises(LabError, match="must name another case with a fix"):
        load_cases(cases_dir, queries)
