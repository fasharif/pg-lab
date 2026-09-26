"""How the shape of a row-level security policy changes the tenant's query plans.

The organisation's order page and its total (casebook case 8, tuned schema), planned five ways:
  * as the owner, without RLS: the reference;
  * as topflow_app with the lab's policies (sql/security/30_row_level_security.sql);
  * the same, with case 8's index built without INCLUDE ("userId");
  * as topflow_app with a transparent policy, "organizationId" = app.org_id() OR ..., which the
    planner can see into;
  * as topflow_app with the membership lookup inside the policy, the common first attempt.
The alternatives are applied inside a transaction that is rolled back. Each statement runs
once before it is explained, so one-off reads (compiling the policy function in a new session)
are not counted. For the page, the report also plans the statement with index scans disabled:
the gap between that plan's cost and the chosen one's is how far the planner is from giving
up the index.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from pglab.db import Connection, scalar
from pglab.execute import explain_json, explain_text, plan_only, render
from pglab.explain import Plan, format_blocks, summarise
from pglab.report import RunInfo, code, table

PAGE = """SELECT o.* FROM orders AS o
WHERE o."organizationId" = %(org_id)s
ORDER BY o."createdAt" DESC
LIMIT 20"""

COUNT = """SELECT count(*) FROM orders AS o
WHERE o."organizationId" = %(org_id)s"""

TRANSPARENT_POLICY = """
ALTER POLICY orders_app ON orders
    USING ("organizationId" = app.org_id()
           OR ("organizationId" IS NULL AND "userId" = app.user_id()))
"""

WITHOUT_INCLUDE = """
DROP INDEX "orders_organizationId_createdAt_idx";
CREATE INDEX "orders_organizationId_createdAt_idx" ON orders ("organizationId", "createdAt")
"""

LOOKUP_POLICY = """
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
    page: Plan
    count: Plan
    page_text: str
    count_text: str
    without_index: Plan


def _tenant_context(conn: Connection) -> None:
    conn.execute(
        "SELECT set_config('app.user_id', lab.uid('user', lab.member_user(1, 1)), true),"
        " set_config('app.org_id', lab.uid('org', 1), true)"
    )


def _variant(conn: Connection, label: str, page: str, count: str) -> Variant:
    """Must run inside a transaction that is rolled back (it changes planner settings)."""
    for statement in (page, count):
        conn.execute(statement).fetchall()
    measured = (
        explain_json(conn, page),
        explain_json(conn, count),
        explain_text(conn, page),
        explain_text(conn, count),
    )
    conn.execute("SET LOCAL enable_indexscan = off")
    conn.execute("SET LOCAL enable_indexonlyscan = off")
    return Variant(label, *measured, without_index=plan_only(conn, page))


def orders_estimate(plan: Plan) -> float | None:
    """The planner's row estimate for its first scan of orders: all the rows it expects to pass,
    not only the page that LIMIT keeps."""
    for node in plan.nodes():
        if node.relation == "orders" and node.node_type != "Bitmap Index Scan":
            return node.plan_rows
    return None


def counted_rows(plan: Plan) -> str:
    """Rows seen by a count(*) plan: the actual rows of its scan of orders."""
    for node in plan.nodes():
        if node.relation == "orders" and node.actual_rows is not None:
            return f"{node.actual_rows:,.0f}"
    return "an unknown number of"


def compare(conn: Connection) -> tuple[str, str, list[Variant]]:
    """conn must be the superuser (SET ROLE). Returns the two statements and the variants."""
    org_id = str(scalar(conn, "SELECT lab.uid('org', 1)"))
    page = render(conn, PAGE, {"org_id": org_id})
    count = render(conn, COUNT, {"org_id": org_id})
    variants: list[Variant] = []
    designs = (
        ("owner, no RLS", None),
        ("topflow_app, lab policies (tenant-row function, membership gate)", ""),
        ("topflow_app, lab policies, case 8 index without INCLUDE (userId)", WITHOUT_INCLUDE),
        ("topflow_app, transparent policy (settings inline)", TRANSPARENT_POLICY),
        ("topflow_app, membership lookup inside the policy", LOOKUP_POLICY),
    )
    for label, ddl in designs:
        with conn.transaction(force_rollback=True):
            if ddl is not None:
                for statement in ddl.split(";\n"):
                    if statement.strip():
                        conn.execute(statement)
                conn.execute("SET LOCAL ROLE topflow_app")
                _tenant_context(conn)
            variants.append(_variant(conn, label, page, count))
    return page, count, variants


def _estimate(plan: Plan) -> str:
    value = orders_estimate(plan)
    return f"{value:,.0f}" if value is not None else ""


def cost_ratio(v: Variant) -> float | None:
    """Cost of the best plan without index scans over the cost of the chosen page plan."""
    chosen, alternative = v.page.cost(), v.without_index.cost()
    if chosen is None or alternative is None or chosen <= 0:
        return None
    return alternative / chosen


def _costs(v: Variant) -> str:
    chosen, alternative, ratio = v.page.cost(), v.without_index.cost(), cost_ratio(v)
    if chosen is None or alternative is None or ratio is None:
        return ""
    return f"{chosen:,.0f} / {alternative:,.0f} ({ratio:,.1f}x)"


def render_report(
    page: str, count: str, variants: Sequence[Variant], info: RunInfo, *, command: str
) -> str:
    lines = [
        "# Row-level security and query plans",
        "",
        "The organisation's order page and its total (casebook case 8, the largest organisation),",
        "planned as the owner and as the customer-facing role under three policy designs.",
        "*Estimated rows* is the planner's expected row count for its scan of `orders`; the",
        f"organisation has {counted_rows(variants[0].count)} orders. *Page cost* is the planner's",
        "cost of the chosen page plan, then of the best plan it finds with index scans disabled",
        "(a bitmap scan and a sort, or a sequential scan) and how many times dearer that is:",
        "the smaller the factor, the closer the page is to losing its index (1.0 means the",
        "chosen plan already does without it). Each statement ran once before it was explained.",
        "See `docs/security.md`.",
        "",
        *info.header_lines(command),
        "",
        table(
            [
                "Planned as",
                "Page: buffers",
                "Page: access path",
                "Estimated rows",
                "Page cost: chosen / without index scans",
                "Total: buffers",
                "Total: access path",
            ],
            [
                (
                    v.label,
                    format_blocks(v.page.shared_buffers()),
                    summarise(v.page),
                    _estimate(v.page),
                    _costs(v),
                    format_blocks(v.count.shared_buffers()),
                    summarise(v.count),
                )
                for v in variants
            ],
            "lrlrrrl",
        ),
        "",
        code(page, "sql"),
        "",
        code(count, "sql"),
        "",
    ]
    for v in variants:
        lines += [
            f"## {v.label}",
            "",
            "Page:",
            "",
            code(v.page_text, "text"),
            "",
            "Total:",
            "",
            code(v.count_text, "text"),
            "",
        ]
    lines += [
        "The alternatives, each applied in a transaction that was rolled back:",
        "",
        code(WITHOUT_INCLUDE.strip(), "sql"),
        "",
        code(TRANSPARENT_POLICY.strip(), "sql"),
        "",
        code(LOOKUP_POLICY.strip(), "sql"),
        "",
    ]
    return "\n".join(lines)
