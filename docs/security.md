# Security: roles, authentication and tenant isolation

Files: `docker/postgres/initdb/10-lab-roles.sh` (roles, database), `docker/postgres/pg_hba.conf`,
`sql/security/20_privileges.sql` (grants), `sql/security/30_row_level_security.sql` (policies).
Tests: `tests/pgtap/02_roles_and_privileges.sql`, `03_tenant_isolation.sql`,
`04_authentication.sql` and `tests/integration/test_authentication.py`, `test_rls_plans.py`.

## Roles

| Role | Logs in | What it may do |
| --- | --- | --- |
| `topflow_owner` | no | Owns the database, schema `public` and every TopFlow object. |
| `topflow_migrator` | yes | Runs migrations. Its sessions start as `topflow_owner` (`ALTER ROLE ... SET role`), so new objects belong to the owner role, not to a person. |
| `topflow_app` | yes | The customer-facing API. Reads and writes what customer flows need, always inside row-level security. No `DELETE` on orders, no `UPDATE` or `DELETE` on audit entries or order history, no change to its own role, credit limit or discount (column privileges). |
| `topflow_backoffice` | yes | Top Flow staff. Every tenant, same append-only rules, `DELETE` only where the back office deletes (draft quotations, empty categories, members, addresses). |
| `topflow_analyst` | yes | Read-only reporting (`default_transaction_read_only`). Every tenant, but no personal contact data: e-mail, names, phone numbers, street addresses and delivery addresses are excluded by column privileges. |
| `replicator` | yes | Streaming replication and `pg_basebackup` only. |
| `monitor` | yes | Member of `pg_monitor`, for postgres_exporter. |
| `rewind` | yes | pg_rewind: `EXECUTE` on the four file functions it calls, nothing else. |

There are no default privileges. A table added by a future migration is invisible to every role
until `20_privileges.sql` grants it, so it cannot leak before it has policies. A pgTAP test fails
if any table the API can read has no policy for it.

## Authentication

- `password_encryption = scram-sha-256`; every login role has a SCRAM verifier (pgTAP checks
  `pg_authid`).
- `pg_hba.conf` has no `trust`, `password` or `md5` lines. Replication is limited to `replicator`
  from the lab network, and the superuser is rejected from outside it.
- The integration tests log in over the network: the right password works, a wrong one is
  refused, and a client that insists on SCRAM (`require_auth=scram-sha-256`) connects.
- Passwords are random, created by `./lab init` in `.env` (not committed); `.env.example` holds
  placeholders only.

## Tenant isolation with row-level security

TopFlow already enables RLS on every table (its migration `20260916090000_supabase_auth`) and
relies on the table owner bypassing it. The lab adds the policies a non-owner API role needs.

For each transaction the API sets the request context, as TopFlow's
`x-organization-id` header does in the application:

```sql
SELECT set_config('app.user_id', '<user id>', true),
       set_config('app.org_id',  '<organisation id, or empty>', true);
```

Two kinds of policy work together on every tenant table:

1. **Permissive policies** say which rows belong to the context: the organisation's rows, or the
   customer's own rows with no organisation (retail orders, personal quotations). On the four
   tables where a row can be either (orders, quote requests, quotations, addresses) the test is
   `app.is_tenant_row(organisation, owner)`, a PL/pgSQL function over `current_setting()`; the
   section on query plans below explains why it is PL/pgSQL. Child tables follow their parent
   (`order_items` through `orders`). Customers never see draft quotations, as in TopFlow's
   `orgList`.
2. **A restrictive policy** (`<table>_app_context`) checks that the user is a member of the
   organisation they claim. It calls a `SECURITY DEFINER` function with a pinned `search_path`,
   and because it references no column it runs once per statement as an InitPlan.

A forged organisation id therefore sees nothing, and a missing context sees nothing either.
Trade-only products are visible only to members of verified (`ACTIVE`) organisations.

### What the tests prove

`tests/pgtap/03_tenant_isolation.sql` runs 27 checks on the generated data with two real
tenants, A and B. As a member of A acting for A:

- A sees every one of its orders and none of anyone else's, and cannot read B's order, its lines
  or its history by id;
- A cannot insert an order in B's name, move its own order to B, or change B's order (the update
  affects no row);
- the API role cannot delete orders or change or delete audit entries, and a customer cannot make
  themselves an administrator or raise their credit limit.

A forged organisation id, a missing context and a retail customer are checked too, and so are
the staff and analyst roles. The suite was checked against a broken policy (`USING (true)` on
orders): eleven of its checks failed, and they passed again once the policy was restored.

### RLS and query plans

Policies are predicates that PostgreSQL adds to every query, so their shape decides the plans.
The API's own queries already filter by organisation (`WHERE "organizationId" = $1`); the policy
repeats that test, and how the planner estimates the repetition decides whether the
organisation's order page keeps casebook case 8's index.

`./lab rls-plans` plans the page and its total as the owner and as `topflow_app` under three
policy designs, and once more with case 8's index built without `INCLUDE ("userId")`. The
alternatives are applied in a transaction that is rolled back. From `reports/rls-plans.md`
(SCALE=1000000, the largest organisation, 9,943 orders):

| Planned as | Estimated rows | Page | Cost without index scans | Total |
| --- | ---: | --- | ---: | --- |
| owner, no RLS | 10,107 | index scan, 18 buffers | 469x | index-only scan, 13 buffers |
| lab policies | 1,684 | index scan, 21 buffers | 77x | index-only scan, 143 buffers |
| lab policies, index without `userId` | 1,684 | index scan, 21 buffers | 78x | bitmap heap scan, 6,764 buffers |
| transparent policy | 275 | index scan, 21 buffers | 1.2x | index-only scan, 143 buffers |
| lookup inside the policy | 27 | bitmap heap scan and sort, 6,899 buffers | 1.0x | bitmap heap scan, 6,899 buffers |

*Cost without index scans* is the planner's cost for the best page plan it finds with index
scans disabled, as a multiple of the chosen plan's cost: how far the page is from losing its
index. What each design does to the estimate:

- **Membership lookup inside the policy**, `"organizationId" = (SELECT member_org())`, the
  usual first design and the lab's first version. The planner cannot know the subquery's value
  when it plans, so it assumes the average organisation's share of the orders and expects 27
  rows. Fetching 25 rows with a bitmap scan and sorting them looks cheapest; the page reads all
  9,943 orders (6,899 buffers) to return 20.
- **Transparent policy**, `"organizationId" = app.org_id() OR ...`, where `app.org_id()` is an
  SQL function that PostgreSQL inlines. The planner evaluates `current_setting()` while
  planning, so it knows the organisation, but it applies the organisation's share twice, once
  for the query's predicate and once for the policy's, as if they were independent. The largest
  organisation has 5% of the orders, so the estimate falls to 5% of the real count, and to half
  of that for the membership gate: 275 rows. The smaller the organisation, the smaller the
  fraction. The page keeps its index here, but the bitmap plan costs only 1.2 times as much
  (675 against 585): a different statistics sample or a little more data can tip it.
- **Tenant-row function**, the lab's design. PL/pgSQL functions are never inlined, so the
  planner uses its default selectivity for a boolean function, one third, and one half for the
  membership gate: it expects one sixth of the real rows whichever the organisation, and the
  bitmap plan costs 77 times the index scan. The function is declared `COST 10`: with the
  default cost of 100 for non-C functions, the planner ran the organisation's count as a
  parallel index-only scan to share out the function calls.

The total needs one more change. Under RLS the count evaluates the policy for every row, and the
policy reads `userId` as well as `organizationId`. With `(organizationId, createdAt)` alone the
count visits all the organisation's orders in the heap (6,764 buffers); with `userId` in the
index it stays an index-only scan (143). The owner needs 13 buffers because it counts on the
smaller `(organizationId, status)` index, whose repeated keys B-tree deduplication compresses.
The price is index size: `docs/indexing.md` gives the index's size with and without `userId`.

Estimates are the fragile part of this design, not correctness: every design returns the same
rows. The integration tests (`tests/integration/test_rls_plans.py`) run as `topflow_app` and
fail if the page loses its index or has a sort, if the index scan's cost margin falls below a
factor of 2, if the total stops being an index-only scan, or if the page differs from the
owner's.

## Limitations

- TLS is not configured. SCRAM protects the passwords, but queries and results cross the Docker
  network in clear text. Production needs `ssl = on` and `hostssl` lines.
- Flows that cross tenants (sign-up, accepting an invitation, KYC review) are assigned to
  `topflow_backoffice` in this model; TopFlow runs them in its API with one connection role.
- Passwords live in `.env` on the host. A real deployment would use a secret manager.
