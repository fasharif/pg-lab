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
| `topflow_app` | yes | The customer-facing API, always inside row-level security. `UPDATE` only on the columns a customer flow changes (column privileges): an order's status and cancellation fields, a quotation's status and response fields, a request's status, a member's role and approval limit. Order lines only while placing an order, and order history only as its own flows write it (policies). No `DELETE` on orders, no `UPDATE` or `DELETE` on audit entries or order history, no `INSERT` of members or organisations, no privilege on the shared document counters. |
| `topflow_backoffice` | yes | Top Flow staff. Every tenant, same append-only rules, `DELETE` only where the back office deletes (draft quotations, empty categories, members, addresses). Runs the flows that cross tenants: registering a trade account, accepting an invitation, KYC review. |
| `topflow_analyst` | yes | Read-only reporting (`default_transaction_read_only`). Every tenant, but no personal data: e-mail, names, phone numbers, street addresses, delivery addresses and the IP addresses in the audit trail are excluded by column privileges. It still sees user ids, so its results are pseudonymous, not anonymous. |
| `replicator` | yes | Streaming replication and `pg_basebackup` only, from the lab network. The replication stream carries every row, so this role can read all data. |
| `monitor` | yes | Member of `pg_monitor`, for postgres_exporter. |
| `rewind` | only during a drill | pg_rewind: `EXECUTE` on the four file functions it calls (`pg_ls_dir`, `pg_stat_file` and two `pg_read_binary_file`). Those functions read any file in the data directory: every table's data files, including the users' e-mail addresses, and `pg_authid` with every role's SCRAM verifier. So the role bypasses row-level security and column privileges in practice. It is `NOLOGIN` except while a drill runs pg_rewind (`scripts/drills.sh` switches it on and off), may connect only to the maintenance database from the lab network, one session at a time. |

Five of these are application roles (owner, migrator, app, back office, analyst) and three are
infrastructure roles (replicator, monitor, rewind).

There are no default privileges. A table added by a future migration is invisible to every role
until `20_privileges.sql` grants it, so it cannot leak before it has policies. A pgTAP test fails
if any table the API can read has no policy for it.

## Authentication

- `password_encryption = scram-sha-256`; every login role has a SCRAM verifier (pgTAP checks
  `pg_authid`).
- `pg_hba.conf` has no `trust`, `password` or `md5` lines. Replication is limited to `replicator`
  from the lab network, `rewind` to the maintenance database from the lab network, and the
  superuser is rejected from outside it. `samenet` is the Docker network's subnet. The ports are
  published on 127.0.0.1 only, but depending on the Docker engine a connection through a
  published port can arrive from the network's gateway address, which is inside that subnet:
  these lines narrow where a login can come from, and the passwords remain the barrier.
- The integration tests log in over the network as each application role with a client that
  insists on SCRAM (`require_auth=scram-sha-256`), so each login proves the method; a wrong
  password is refused, and so is a client that accepts only MD5.
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

A user who claims an organisation they do not belong to sees none of its rows, and a missing
context sees nothing. Trade-only products are visible only to members of verified (`ACTIVE`)
organisations.

### What a customer may change

Tenant policies decide *which* rows a customer reaches; they say nothing about *what* the
customer may do to their own rows. Three more layers do:

- **Column privileges** limit `UPDATE` to the columns a customer flow changes (the list is at the
  top of `sql/security/20_privileges.sql`, with the TopFlow service behind each). A customer
  cannot touch an order's payment status or amounts, or a quotation's prices or validity.
- **Restrictive policies** limit the states a row may leave and enter. A new order starts unpaid
  and undispatched. A customer can only cancel an order, while it is waiting for payment or
  confirmed and unpaid (TopFlow's `isCustomerCancellable`), and an organisation's order only as
  its owner or approver. A quotation is answered only while it is open, an approval is recorded in
  the caller's own name, and an expired quotation cannot be accepted. A request for a quotation
  starts as submitted and can only be cancelled, closed or sent back for review. The policies
  check the states, not every pair of states; the API's state machines stay the reference.
- **Order lines and history.** TopFlow writes an order, then its lines, then its first status
  event, in one transaction. A line can be added only to an open, unpaid order whose history has
  not started, so nobody appends lines to a paid or delivered order. A customer appends to an
  order's history only what their own flows write: the first event of an order they place and
  the cancellation of an open order, in their own name. Each event must continue the order's
  timeline (its `fromStatus` is the status the last event reached) and end in the status the
  order has now, which `app.continues_order_timeline()` checks as the owner, because a policy on
  `order_status_events` cannot query that table itself. A customer cannot record a status the
  order never took, repeat an event, or write one in someone else's name.
- **Owner-only membership.** Only the organisation's owner (`app.org_role()`, TopFlow's
  `MEMBERS_MANAGE`) changes a member's role or approval limit, removes a member, or sees and
  manages invitations, which hold e-mail addresses. There is no `INSERT` on
  `organization_members`: without it, an owner could add any user to their organisation and then
  read that user's profile.

Document numbers (TF-SO-2026-000123) come from `document_sequences`, one table that every tenant
shares. The API roles have no privilege on it; `app.next_document_number(key)`, a
`SECURITY DEFINER` function, runs TopFlow's own upsert for known keys only. TopFlow's
`NumberingService` would call the function instead of running the upsert itself.

What the database does not check: the values the API computes. The prices of a new order and its
lines, or which lines a new quotation request holds, come from the API, and checking them would
mean repeating its pricing in SQL. Nor does it check the time stamps the API writes, such as an
event's `createdAt`. The database stops changes to amounts and lines once an order is placed,
not a wrong amount at creation.

### Trust boundary

The request context is two settings, `app.user_id` and `app.org_id`, and any `topflow_app`
session can set them. The restrictive gate checks that the claimed user belongs to the claimed
organisation, not that the claim is true: a session that says it is B's owner is B's owner as far
as the policies can tell (the suite has a test that shows it).

So row-level security here guards against **application query bugs**: a list endpoint that
forgets its `WHERE "organizationId" = $1`, a lookup by id that does not check the tenant, an
update that matches more rows than intended. It does **not** guard against code that can run
arbitrary SQL as `topflow_app`, such as SQL injection or a compromised API process, because that
code can set any context. Stronger designs move the identity out of the session's control:

- a context set only through a `SECURITY DEFINER` function that verifies a token signed by the
  identity provider (the approach of Supabase's `auth.jwt()` claims), with direct `set_config`
  of the settings refused;
- a database role per tenant or per user, entered with `SET ROLE` by a connection pooler that
  holds the only login;
- a pooler or proxy that injects the verified context itself, so the application never sets it.

Each adds moving parts; the lab documents the boundary rather than claiming more than the
design gives.

### What the tests check

`tests/pgtap/03_tenant_isolation.sql` runs 96 checks on the generated data with two generated
tenants, A and B, and a few rows adjusted inside the test transaction (open orders with a
one-event history, an open quotation, one invitation each), all rolled back at the end.

- **Reads, for every tenant table** (users, organisations, members, invitations, addresses,
  orders and their lines and history, requests for quotations and their lines, quotations and
  their lines, audit entries): the rows A's owner should see when acting for A are computed first
  as the superuser, in plain SQL without the policy functions. As `topflow_app`, A sees none of
  the other rows and all of its own. The rows of others include B's rows and other customers'
  personal rows, such as retail orders and home addresses.
- **Writes aimed at B**: creating an order, an order line, an address, a request or an
  invitation in B's name fails; updating B's order, address, request or invitation changes no
  row; adding B's owner to A as a member is refused, so their profile stays invisible.
- **Changes to A's own rows**: every case in "What a customer may change" above, both the
  refusals (mark an order paid, change its amount, move it to delivered, add a line to a
  delivered and paid order or to one whose history has started, record a status change the order
  did not make, repeat an event or write one in another member's name, change or delete order
  history, change a quotation's prices or validity, accept an expired quotation, approve in
  someone else's name, a buyer promoting themselves) and the allowed paths (place an order with
  its lines and first event, cancel an open order and record the cancellation, accept a valid
  quotation, the owner changing a member's role).
- A forged organisation id, a missing context, a retail customer, the trust boundary, and the
  staff and analyst roles.

Write checks run through a helper that reports an error as a result (`error 42501`) instead of
aborting the file, so a broken policy shows up as failed tests. Two self-checks at the end
disable `orders_app` and `users_app_read` inside the transaction and show that the same read
probes then see other tenants' rows: the checks above can fail.

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
| owner, no RLS | 9,627 | index scan, 18 buffers | 447x | index-only scan, 13 buffers |
| lab policies | 1,604 | index scan, 21 buffers | 74x | index-only scan, 143 buffers |
| lab policies, index without `userId` | 1,604 | index scan, 21 buffers | 74x | bitmap heap scan, 6,764 buffers |
| transparent policy | 251 | index scan, 21 buffers | 1.0x | index-only scan, 143 buffers |
| lookup inside the policy | 26 | bitmap heap scan and sort, 6,899 buffers | 1.0x | bitmap heap scan, 6,899 buffers |

*Cost without index scans* is the planner's cost for the best page plan it finds with index
scans disabled, as a multiple of the chosen plan's cost: how far the page is from losing its
index. What each design does to the estimate:

- **Membership lookup inside the policy**, `"organizationId" = (SELECT member_org())`, the
  usual first design and the lab's first version. The planner cannot know the subquery's value
  when it plans, so it assumes the average organisation's share of the orders and expects 26
  rows. Fetching that few rows with a bitmap scan and sorting them looks cheapest; the page reads
  all 9,943 orders (6,899 buffers) to return 20.
- **Transparent policy**, `"organizationId" = app.org_id() OR ...`, where `app.org_id()` is an
  SQL function that PostgreSQL inlines. The planner evaluates `current_setting()` while
  planning, so it knows the organisation, but it applies the organisation's share twice, once
  for the query's predicate and once for the policy's, as if they were independent. The largest
  organisation has 5% of the orders, so the estimate falls to 5% of the real count, and to half
  of that for the membership gate: 251 rows. The smaller the organisation, the smaller the
  fraction. The page keeps its index in this run, but only just: the bitmap plan costs 622
  against 619 for the index scan, so a different statistics sample or a little more data can
  tip it.
- **Tenant-row function**, the lab's design. PL/pgSQL functions are never inlined, so the
  planner uses its default selectivity for a boolean function, one third, and one half for the
  membership gate: it expects one sixth of the real rows whichever the organisation, and the
  bitmap plan costs 74 times the index scan. The function is declared `COST 10`: with the
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
factor of 10, if the total stops being an index-only scan, or if the page differs from the
owner's. A separate test checks the design itself: the orders policy calls the PL/pgSQL
`app.is_tenant_row`. The threshold of 10 separates the designs at CI scale too: at
SCALE=100000, `./lab rls-plans` gave 18.7 for the lab's policies and 2.2 for the transparent
policy.

## Limitations

- TLS is not configured. SCRAM protects the passwords, but queries and results cross the Docker
  network in clear text. Production needs `ssl = on` and `hostssl` lines.
- Flows that cross tenants (registering a trade account with its owner membership, accepting an
  invitation, KYC review) are assigned to `topflow_backoffice` in this model; TopFlow runs them in
  its API with one connection role. A `SECURITY DEFINER` function per flow (for example one that
  accepts an invitation after checking its token and e-mail address) would let the customer
  API run them without the staff role.
- Where the column privileges are narrower than TopFlow's code: an organisation profile update
  that changes the trade licence or TRN also resets the verification status in TopFlow, which
  `topflow_app` may not write; that path would move to staff or to a trigger.
- The request context is self-asserted (see "Trust boundary").
- Passwords live in `.env` on the host. A real deployment would use a secret manager.
