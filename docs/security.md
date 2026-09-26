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
   customer's own rows with no organisation (retail orders, personal quotations). They compare
   columns with `app.org_id()` and `app.user_id()`, plain SQL functions over `current_setting()`
   that PostgreSQL inlines. Child tables follow their parent (`order_items` through `orders`).
   Customers never see draft quotations, as in TopFlow's `orgList`.
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
orders): twelve of its checks failed, and they passed again once the policy was restored.

### RLS and query plans

Policies are predicates that PostgreSQL adds to every query, so their shape matters for
performance. The first version of the policies put the membership lookup inside the permissive
policy, `"organizationId" = (SELECT app.current_org_id())`. The planner cannot estimate a
comparison with an InitPlan value, assumed that almost no order would pass it and gave up the
casebook's `(organizationId, createdAt)` index for the organisation's order page.

`./lab rls-plans` rebuilds both designs and writes `reports/rls-plans.md`: the order page planned
as the owner, as `topflow_app` with the lab's policies (inline settings plus the gate) and as
`topflow_app` with the lookup inside the policy (applied in a transaction and rolled back). The
integration test `test_rls_plans.py` fails if the tenant query loses its index.

## Limitations

- TLS is not configured. SCRAM protects the passwords, but queries and results cross the Docker
  network in clear text. Production needs `ssl = on` and `hostssl` lines.
- Flows that cross tenants (sign-up, accepting an invitation, KYC review) are assigned to
  `topflow_backoffice` in this model; TopFlow runs them in its API with one connection role.
- Passwords live in `.env` on the host. A real deployment would use a secret manager.
