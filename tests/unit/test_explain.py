"""Plan parsing and plan checks, on plans recorded from the lab (tests/fixtures/plans)."""

from __future__ import annotations

import pytest

from pglab.errors import LabError
from pglab.explain import Expectation, check_plan, format_blocks, parse_plan, summarise
from tests.conftest import load_plan


def test_parses_org_history_before_fix() -> None:
    plan = load_plan("orders-org-history.before")
    assert plan.root.node_type == "Limit"
    assert "Sort" in plan.node_types()
    assert plan.indexes_used() == {"orders_organizationId_status_idx"}
    assert plan.relations_scanned() == {"orders"}
    assert plan.rows() == 20
    assert plan.shared_buffers() > 1000


def test_parses_org_history_after_fix() -> None:
    plan = load_plan("orders-org-history.after")
    assert plan.indexes_used() == {"orders_organizationId_createdAt_idx"}
    assert "Sort" not in plan.node_types()
    assert plan.shared_buffers() < 100
    assert plan.seq_scanned() == set()


def test_estimates_and_costs_are_parsed() -> None:
    plan = load_plan("orders-org-history.after")
    scan = next(node for node in plan.nodes() if node.relation == "orders")
    assert scan.plan_rows is not None
    assert plan.root.plan_rows == 20  # LIMIT keeps 20 of the rows the scan is estimated to find
    assert scan.plan_rows > 20
    cost = plan.cost()
    assert cost is not None
    assert scan.total_cost is not None
    assert 0 < cost < scan.total_cost


def test_plan_without_analyze_has_no_actual_rows() -> None:
    plan = parse_plan(
        [
            {
                "Plan": {
                    "Node Type": "Seq Scan",
                    "Relation Name": "orders",
                    "Plan Rows": 5,
                    "Total Cost": 12.5,
                }
            }
        ]
    )
    assert plan.rows() is None
    assert plan.cost() == 12.5
    assert plan.root.plan_rows == 5


def test_seq_scans_and_parallel_plans_are_found() -> None:
    plan = load_plan("dashboard-revenue-30d.before")
    assert plan.seq_scanned() == {"orders"}
    assert "Gather" in plan.node_types()


def test_nested_bitmap_or_plan_lists_every_index() -> None:
    plan = load_plan("orders-admin-search.after")
    used = plan.indexes_used()
    assert {
        "orders_orderNumber_trgm_idx",
        "orders_purchaseOrderNumber_trgm_idx",
        "orders_projectReference_trgm_idx",
        "users_fullName_trgm_idx",
        "organizations_name_trgm_idx",
    } <= used
    assert "BitmapOr" in plan.node_types()
    assert "orders" not in plan.seq_scanned()


def test_expectations_pass_on_matching_plans() -> None:
    after = load_plan("audit-by-user.after")
    expectation = Expectation(
        index_used=("audit_logs_userId_createdAt_idx",),
        node_absent=("Sort",),
        no_seq_scan_on=("audit_logs",),
    )
    assert check_plan(after, expectation) == []


def test_expectations_report_each_failure() -> None:
    before = load_plan("audit-by-user.before")
    expectation = Expectation(
        index_used=("audit_logs_userId_createdAt_idx",),
        index_not_used=("audit_logs_createdAt_idx",),
        node_present=("Index Only Scan",),
        seq_scan_on=("audit_logs",),
        relations_scanned=("audit_logs", "users"),
    )
    failures = check_plan(before, expectation)
    assert len(failures) == 5
    assert any("audit_logs_userId_createdAt_idx" in f for f in failures)
    assert any("should not be used" in f for f in failures)


def test_relations_scanned_is_an_exact_match() -> None:
    plan = load_plan("orders-admin-search.before")
    assert (
        check_plan(plan, Expectation(relations_scanned=("orders", "users", "organizations"))) == []
    )
    assert check_plan(plan, Expectation(relations_scanned=("orders",))) != []


def test_expectation_from_mapping_validates_keys_and_types() -> None:
    parsed = Expectation.from_mapping({"index_used": ["a"], "node_absent": ["Sort"]}, "t")
    assert parsed.index_used == ("a",)
    assert parsed.describe() == ["uses index `a`", "has no Sort node"]
    with pytest.raises(LabError, match="unknown expectation keys"):
        Expectation.from_mapping({"index_use": ["a"]}, "t")
    with pytest.raises(LabError, match="must be a list of strings"):
        Expectation.from_mapping({"index_used": "a"}, "t")


def test_parse_plan_rejects_other_documents() -> None:
    with pytest.raises(LabError, match="no 'Plan' key"):
        parse_plan({"Query": 1})
    with pytest.raises(LabError, match="expected one EXPLAIN result"):
        parse_plan([])
    with pytest.raises(LabError, match="without 'Node Type'"):
        parse_plan({"Plan": {"Plans": []}})


def test_summary_names_access_paths() -> None:
    text = summarise(load_plan("orders-org-history.after"))
    assert text == "Index Scan on orders using orders_organizationId_createdAt_idx"


def test_format_blocks_shows_volume() -> None:
    assert format_blocks(1) == "1 (8 kB)"
    assert format_blocks(33618) == "33,618 (263 MB)"
