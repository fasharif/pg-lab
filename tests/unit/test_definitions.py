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


def test_every_paginated_page_has_its_total_in_the_workload(root: Path) -> None:
    """TopFlow's paginated lists run the page and a count(*) with the same filter."""
    queries = load_workload(root / "workload" / "queries.toml")
    pages = {q.id for q in queries.values() if "LIMIT 20 OFFSET 0" in q.sql}
    totals = {
        q.id
        for q in queries.values()
        if q.sql.startswith("SELECT count(*)") and "DashboardService" not in q.api
    }
    assert len(pages) == len(totals) == 14
    assert {"orders-admin-search-count", "rfq-admin-search-count"} <= totals


def test_the_order_search_total_is_fixed_in_case_4(root: Path) -> None:
    queries = load_workload(root / "workload" / "queries.toml")
    case = load_cases(root / "casebook", queries)[3]
    assert case.total is not None
    assert case.total.query.id == "orders-admin-search-count"
    assert "UNION" in case.total.after_sql
    assert case.total.after.no_seq_scan_on == ("orders",)


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


TOTAL_QUERY = """
[[query]]
id = "orders-page-count"
title = "Orders, number"
api = "apps/api/src/orders/orders.service.ts:2 OrdersService.list() -> order.count"
params = { org_id = "SELECT 1" }
sql = "SELECT count(*) FROM orders WHERE \\"organizationId\\" = %(org_id)s"
"""

CASE_WITH_TOTAL = """
query = "orders-page"
fix_kind = "index"
problem = "slow"
tradeoff = "costs"
fix = ["CREATE INDEX CONCURRENTLY x ON orders (id)"]
revert = ["DROP INDEX CONCURRENTLY IF EXISTS x"]
[after]
index_used = ["x"]
[total]
query = "orders-page-count"
[total.before]
seq_scan_on = ["orders"]
[total.after]
index_used = ["x"]
"""


def test_a_case_can_check_its_pages_total(tmp_path: Path) -> None:
    queries = load_workload(write(tmp_path / "q.toml", VALID_QUERY + TOTAL_QUERY))
    cases_dir = tmp_path / "cases"
    cases_dir.mkdir()
    write(cases_dir / "01-orders.toml", CASE_WITH_TOTAL)
    (case,) = load_cases(cases_dir, queries)
    assert case.total is not None
    assert case.total.query.id == "orders-page-count"
    assert case.total.after_sql == case.total.query.sql  # no rewrite: the same statement
    assert case.total.before.seq_scan_on == ("orders",)


@pytest.mark.parametrize(
    ("change", "replacement", "message"),
    [
        ('query = "orders-page-count"', 'query = "missing"', "is not in the workload"),
        ('[total.after]\nindex_used = ["x"]', "", "must state at least one plan check"),
        ("[total]\n", '[total]\ncolour = "red"\n', "unknown keys"),
        ("[total]\n", '[total]\nrewrite = "SELECT %(other)s"\n', "parameters the query does"),
        ('query = "orders-page-count"', 'query = "orders-page"', "more than one case"),
    ],
)
def test_invalid_totals_are_explained(
    tmp_path: Path, change: str, replacement: str, message: str
) -> None:
    queries = load_workload(write(tmp_path / "q.toml", VALID_QUERY + TOTAL_QUERY))
    cases_dir = tmp_path / "cases"
    cases_dir.mkdir()
    assert change in CASE_WITH_TOTAL
    write(cases_dir / "01-orders.toml", CASE_WITH_TOTAL.replace(change, replacement, 1))
    with pytest.raises(LabError, match=message):
        load_cases(cases_dir, queries)
