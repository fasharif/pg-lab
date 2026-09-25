"""How the shape of a row-level security policy changes the tenant's query plans.

Compares the organisation's order page (casebook case 8, tuned schema) three ways:
  * as the owner (no RLS), the reference plan;
  * as topflow_app with the lab's policies (sql/security/30_row_level_security.sql);
  * as topflow_app with the membership lookup inside the permissive policy, the common first
    attempt. That variant is applied inside a transaction and rolled back.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from pglab.db import Connection, scalar
from pglab.execute import explain_json, explain_text, render
from pglab.explain import Plan, format_blocks, summarise
from pglab.report import RunInfo, code, table

ORG_HISTORY = """SELECT o.* FROM orders AS o
WHERE o."organizationId" = %(org_id)s
ORDER BY o."createdAt" DESC
LIMIT 20"""

INLINE_MEMBERSHIP_POLICY = """
CREATE FUNCTION pg_temp.member_org() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
    SELECT m."organizationId" FROM public.organization_members AS m
    WHERE m."organizationId" = nullif(current_setting('app.org_id', true), '')
      AND m."userId" = nullif(current_setting('app.user_id', true), '')
$$;
ALTER POLICY orders_app ON orders
    USING ("organizationId" = (SELECT pg_temp.member_org())
           OR ("organizationId" IS NULL AND "userId" = app.user_id()))
"""


@dataclass(frozen=True)
class Variant:
    label: str
    plan: Plan
    text: str


def _tenant_context(conn: Connection) -> None:
    conn.execute(
        "SELECT set_config('app.user_id', lab.uid('user', lab.member_user(1, 1)), true),"
        " set_config('app.org_id', lab.uid('org', 1), true)"
    )


def compare(conn: Connection) -> tuple[str, list[Variant]]:
    """conn must be the superuser (SET ROLE). Returns the statement and the three variants."""
    org_id = str(scalar(conn, "SELECT lab.uid('org', 1)"))
    statement = render(conn, ORG_HISTORY, {"org_id": org_id})
    variants = [
        Variant("owner, no RLS", explain_json(conn, statement), explain_text(conn, statement))
    ]
    with conn.transaction(force_rollback=True):
        conn.execute("SET LOCAL ROLE topflow_app")
        _tenant_context(conn)
        variants.append(
            Variant(
                "topflow_app, lab policies (settings inline, membership gate)",
                explain_json(conn, statement),
                explain_text(conn, statement),
            )
        )
    with conn.transaction(force_rollback=True):
        for part in INLINE_MEMBERSHIP_POLICY.split(";\n"):
            if part.strip():
                conn.execute(part)
        conn.execute("SET LOCAL ROLE topflow_app")
        _tenant_context(conn)
        variants.append(
            Variant(
                "topflow_app, membership lookup inside the policy",
                explain_json(conn, statement),
                explain_text(conn, statement),
            )
        )
    return statement, variants


def render_report(
    statement: str, variants: Sequence[Variant], info: RunInfo, *, command: str
) -> str:
    lines = [
        "# Row-level security and query plans",
        "",
        "The organisation's order page (casebook case 8) with the casebook's indexes in place,",
        "planned as the owner and as the customer-facing role under two policy designs. See",
        "`docs/security.md` for the discussion.",
        "",
        *info.header_lines(command),
        "",
        table(
            ["Planned as", "Shared buffers", "Rows", "Access path"],
            [
                (
                    v.label,
                    format_blocks(v.plan.shared_buffers()),
                    f"{v.plan.rows() or 0:,.0f}",
                    summarise(v.plan),
                )
                for v in variants
            ],
            "lrrl",
        ),
        "",
        code(statement, "sql"),
        "",
    ]
    for v in variants:
        lines += [f"## {v.label}", "", code(v.text, "text"), ""]
    lines += [
        "The membership variant's policy:",
        "",
        code(INLINE_MEMBERSHIP_POLICY.strip(), "sql"),
        "",
    ]
    return "\n".join(lines)
