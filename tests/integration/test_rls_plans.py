"""Row-level security must not cost the tenant queries their indexes.

The customer-facing API runs every statement under the orders policies, which add
"organizationId = app.org_id() OR ..." and a membership gate to the query. These tests check
that the organisation's order page still uses the casebook's index as topflow_app, and that it
returns the same rows as the owner sees.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab import casebook
from pglab.db import Connection, connect
from pglab.definitions import load_cases, load_workload
from pglab.execute import explain_json, render

ROOT = Path(__file__).resolve().parents[2]
ORG_HISTORY = """
SELECT o.* FROM orders AS o
WHERE o."organizationId" = %(org_id)s
ORDER BY o."createdAt" DESC
LIMIT 20
"""


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
def test_tenant_sees_the_same_page_as_the_owner() -> None:
    with connect() as owner:
        org_id = owner.execute("SELECT lab.uid('org', 1)").fetchone()
        assert org_id is not None
        expected = owner.execute(render(owner, ORG_HISTORY, {"org_id": org_id[0]})).fetchall()
    with connect("topflow_app") as conn:
        tenant_org = _as_tenant(conn)
        actual = conn.execute(render(conn, ORG_HISTORY, {"org_id": tenant_org})).fetchall()
    assert actual == expected
