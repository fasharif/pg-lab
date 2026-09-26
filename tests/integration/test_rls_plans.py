"""Row-level security must not cost the tenant queries their indexes.

The customer-facing API runs every statement under the orders policies, which add
app.is_tenant_row("organizationId", "userId") and a membership gate to the query. These tests
check, as topflow_app, that the organisation's order page still uses the casebook's index with
a wide cost margin, that its total stays an index-only scan, and that the page returns the same
rows as the owner sees.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab import casebook
from pglab.db import Connection, connect
from pglab.definitions import load_cases, load_workload
from pglab.execute import explain_json, plan_only, render

ROOT = Path(__file__).resolve().parents[2]
ORG_HISTORY = """
SELECT o.* FROM orders AS o
WHERE o."organizationId" = %(org_id)s
ORDER BY o."createdAt" DESC
LIMIT 20
"""
ORG_TOTAL = """
SELECT count(*) FROM orders AS o
WHERE o."organizationId" = %(org_id)s
"""
# The best plan without index scans must cost at least this many times the chosen one. With the
# lab's policies `./lab rls-plans` gave a factor of 18.7 at SCALE=100000 (the CI data set) and 77
# at SCALE=1000000 (reports/rls-plans.md); the transparent policy the docs argue against gave 2.2
# and 1.2. A threshold of 10 tells the two designs apart at CI scale as well.
MIN_COST_FACTOR = 10.0


@pytest.fixture(scope="module")
def tuned() -> None:
    """The casebook's indexes (idempotent: existing ones are kept)."""
    queries = load_workload(ROOT / "workload" / "queries.toml")
    cases = load_cases(ROOT / "casebook", queries)
    with connect() as conn:
        casebook.apply_all(conn, cases)


def _as_tenant(conn: Connection) -> str:
    org_id, user_id = conn.execute(
        "SELECT lab.uid('org', 1), lab.uid('user', lab.member_user(1, 1))"
    ).fetchone() or (None, None)
    conn.execute(
        "SELECT set_config('app.user_id', %s, false), set_config('app.org_id', %s, false)",
        (user_id, org_id),
    )
    return str(org_id)


@pytest.mark.integration
@pytest.mark.usefixtures("tuned")
def test_org_history_keeps_its_index_under_rls() -> None:
    with connect("topflow_app") as conn:
        org_id = _as_tenant(conn)
        plan = explain_json(conn, render(conn, ORG_HISTORY, {"org_id": org_id}))
    assert "orders_organizationId_createdAt_idx" in plan.indexes_used()
    assert "Sort" not in plan.node_types()
    assert plan.rows() == 20


@pytest.mark.integration
@pytest.mark.usefixtures("tuned")
def test_org_history_index_has_a_wide_cost_margin() -> None:
    with connect("topflow_app") as conn:
        org_id = _as_tenant(conn)
        page = render(conn, ORG_HISTORY, {"org_id": org_id})
        with conn.transaction(force_rollback=True):
            chosen = plan_only(conn, page).cost()
            conn.execute("SET LOCAL enable_indexscan = off")
            conn.execute("SET LOCAL enable_indexonlyscan = off")
            without_index = plan_only(conn, page).cost()
    assert chosen is not None
    assert without_index is not None
    assert without_index >= MIN_COST_FACTOR * chosen, (chosen, without_index)


@pytest.mark.integration
def test_orders_policy_uses_the_opaque_tenant_row_function() -> None:
    """The design decision itself (ADR 10): the planner must not see into the tenant test."""
    with connect() as conn:
        row = conn.execute(
            "SELECT qual, with_check FROM pg_policies"
            " WHERE schemaname = 'public' AND tablename = 'orders' AND policyname = 'orders_app'"
        ).fetchone()
        language = conn.execute(
            "SELECT l.lanname FROM pg_proc AS p JOIN pg_language AS l ON l.oid = p.prolang"
            " WHERE p.oid = 'app.is_tenant_row(text, text)'::regprocedure"
        ).fetchone()
    assert row is not None
    qual, with_check = row
    assert "app.is_tenant_row" in qual
    assert "app.is_tenant_row" in with_check
    assert "app.org_id()" not in qual
    assert language == ("plpgsql",)


@pytest.mark.integration
@pytest.mark.usefixtures("tuned")
def test_org_total_stays_index_only_under_rls() -> None:
    with connect("topflow_app") as conn:
        org_id = _as_tenant(conn)
        plan = explain_json(conn, render(conn, ORG_TOTAL, {"org_id": org_id}))
    assert "Index Only Scan" in plan.node_types()
    assert "orders" not in plan.seq_scanned()
    assert "Bitmap Heap Scan" not in plan.node_types()


@pytest.mark.integration
@pytest.mark.usefixtures("tuned")
def test_tenant_sees_the_same_page_as_the_owner() -> None:
    with connect() as owner:
        org_id = owner.execute("SELECT lab.uid('org', 1)").fetchone()
        assert org_id is not None
        expected = owner.execute(render(owner, ORG_HISTORY, {"org_id": org_id[0]})).fetchall()
    with connect("topflow_app") as conn:
        tenant_org = _as_tenant(conn)
        actual = conn.execute(render(conn, ORG_HISTORY, {"org_id": tenant_org})).fetchall()
    assert actual == expected
