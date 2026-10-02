# Indexing strategy

What to index in TopFlow's database, what not to, and what each index costs on writes. Figures
come from `reports/indexing.md` (`./lab indexing`, SCALE=10000000, PostgreSQL 18.6, 2026-10-02)
unless a section gives its own command. Sizes are of freshly built indexes.

## Start from the statements, not the columns

Every index in the lab answers a statement the API sends (`workload/queries.toml`); nothing is
indexed because a column "looks important". The workload ranking (`reports/workload.md`) shows
which statements do the most work, and the casebook fixes the heaviest of them (eleven cases;
cases 4 and 11 also fix their search's pagination count). The rules that came out of it:

1. **Equality columns first, then the column you sort or range on.** `(organizationId, createdAt)`
   returns an organisation's newest 20 orders from the index alone, whatever the size of its
   history (case 8); `(organizationId, status)` cannot, because it is not in date order. Case 8
   also includes `userId`, which the row-level security policy reads (see below).
2. **One index for all the statements of an endpoint.** The audit screen's page and its count
   share `(userId, createdAt)` (cases 2 and 3). An index on `userId` alone would serve the count
   but not the page.
3. **Cover the hot aggregates.** `createdAt INCLUDE (status, totalAmount)` lets the dashboard sum
   a month of orders from the index (an index-only scan) and also returns the newest orders in
   order (cases 5, 6 and 7).
4. **Partial indexes when every query carries the same predicate.** The storefront only counts
   active, non-trade products; the partial index holds exactly those, and each category count
   becomes an index-only scan (case 9).
5. **Match the operator.** `ILIKE '%term%'` needs trigrams (pg_trgm GIN, cases 4 and 11), and
   `LIKE 'prefix%'` under the `en_US.utf8` collation needs `text_pattern_ops` (case 1). A plain
   B-tree helps neither. A GIN index can hold several columns and serves a condition on any of
   them, so one index covers the RFQ search's five columns (case 11).
6. **Replace, do not accumulate.** `(status, updatedAt)` makes TopFlow's `(status)` redundant, so
   case 10 drops it and the table keeps the same number of indexes.

## What not to index

- **Booleans and low-selectivity flags on their own.** 97.1% of products are active, so an
  index on `isActive` can only help the rare query for inactive products: the storefront listing
  scans the table, and no plan in `reports/workload.md` uses `products_isActive_idx`. The
  partial index of case 9 is the useful form of that predicate.
- **Columns filtered in a way the index cannot serve.** The API filters brands with Prisma's
  `mode: 'insensitive'`, which PostgreSQL receives as `ILIKE`; `products_brand_idx` is a plain
  B-tree and the plan is a sequential scan. If brand filtering matters, an index on
  `lower(brand)` with a matching query, or a case-insensitive collation, would serve it.
- **Every column that appears in a search.** The order search could have indexed the customer's
  name on `orders` (denormalised); the rewrite looks names up in `users` and joins instead, so
  `orders` carries three trigram indexes, not five.
- **Indexes that only duplicate a prefix.** Before adding `(a, b)`, check whether `(a)` exists;
  after adding it, `(a)` can usually go (case 10).

These two checks reproduce the first two points on a seeded lab:

```sql
EXPLAIN (COSTS OFF) SELECT * FROM products
WHERE brand ILIKE 'Aqualine' AND "isActive" AND NOT "isTradeOnly";          -- Seq Scan on products

SELECT round(100.0 * count(*) FILTER (WHERE "isActive") / count(*), 1) FROM products;  -- 97.1
```

## What the indexes cost

### Size

| Index (after the casebook) | Size | Table size |
| --- | ---: | ---: |
| `audit_logs_userId_createdAt_idx` (case 3) | 647 MB | `audit_logs`: 2.6 GB |
| `audit_logs_action_pattern_idx` (case 1) | 67.9 MB | |
| `orders_organizationId_createdAt_idx` with `INCLUDE (userId)` (case 8) | 188 MB | `orders`: 842 MB |
| `orders_createdAt_idx` with `INCLUDE` (case 7) | 77.3 MB | |
| three trigram GIN indexes on `orders` (case 4): order, PO and project numbers | 57.7 + 44.9 + 38.9 MB | |
| `quote_requests_search_trgm_idx`, one GIN index on five columns (case 11) | 102 MB | `quote_requests`: 359 MB |
| `products_categoryId_visible_idx` (case 9) | 304 kB | `products`: 19.5 MB |

After the casebook, all indexes on `audit_logs` together take 1.8 GB, 0.69 times the table; on
`orders`, 689 MB, 0.82 times the table; on `quote_requests`, 257 MB, 0.72 times the table.

The largest single cost is the id type. TopFlow's ids are UUIDs stored as `TEXT` (36 characters),
so every primary key, foreign key and composite index that contains an id carries 37 bytes per
entry instead of 16. The same ten million audit ids take 563 MB in the primary key's text index
and 301 MB in an index on the ids cast to `uuid` (`reports/indexing.md`, "Alternatives
measured"):

```sql
CREATE INDEX "lab_audit_id_uuid" ON audit_logs ((id::uuid));
```

That is why `(userId, createdAt)` is the biggest index in the table. Moving TopFlow's ids to the
native `uuid` type (Prisma: `@db.Uuid`) would roughly halve every id index; it is a migration of
every table and foreign key, so it is a roadmap item rather than a casebook fix.

### Writes

Each index is maintained on every insert and on every update that changes its columns (or cannot
be a HOT update). Measured as WAL per inserted row, the median of three probes of 5,000 rows,
each right after a `CHECKPOINT`:

| Table | Indexes before | WAL per row before | Indexes after | WAL per row after | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| `audit_logs` | 3 | 4,074 B | 5 | 4,333 B | +6% |
| `orders` | 6 | 8,212 B | 11 | 9,693 B | +18% |
| `quote_requests` | 6 | 4,657 B | 7 | 7,423 B | +59% |

Full-page images are most of this volume. Indexes with scattered keys (ids, `entityId`) change a
different page for nearly every row, and the first change to a page after a checkpoint writes
the whole page (compressed here, `wal_compression = zstd`): a probe of 5,000 orders writes about
11,000 of them, two per row, before and after the casebook (10,930 and 11,081 in the report).
For `audit_logs` and `orders` that number barely changes with the casebook's indexes, so their
extra WAL is mostly the new indexes' own records. The five indexes added to `orders` are the
three trigram GIN indexes of case 4 and the B-trees of cases 7 and 8. `quote_requests` is the
exception: with case 11's five-column GIN index its full-page images rise from 5,289 to 9,015
per probe, which is most of its +59%. GIN's `fastupdate` (on by default) appends new entries to a
pending list and merges them later, which keeps most inserts cheap but moves the cost to vacuum
or to the insert that overflows the list (`gin_pending_list_limit`).

For TopFlow the trade-off is acceptable: orders are written a few times in their life and read
on every page view, audit entries are written once, and quote requests far less often than the
sales team searches them. The two searches are the fixes to revisit first if write volume grows,
for example by searching order, PO and RFQ numbers by prefix with B-trees and keeping trigrams
for names only.

### Alternatives measured

| Alternative | Size | Index it would replace |
| --- | ---: | ---: |
| BRIN on `orders.createdAt` | 40 kB | `orders_createdAt_idx`, 77.3 MB |
| BRIN on `audit_logs.createdAt` | 104 kB | `audit_logs_createdAt_idx`, 214 MB |
| case 8 without `INCLUDE (userId)` | 102 MB | `orders_organizationId_createdAt_idx`, 188 MB |

BRIN stores one summary per block range, which works here because rows are inserted in
`createdAt` order. It serves range filters (a bitmap scan of the matching ranges) but cannot return
rows in order, and the dashboard's newest orders and the audit screen's newest entries both sort
by `createdAt`. BRIN becomes the right choice for a time column that is only filtered, never
sorted; ADR 7 in docs/decisions.md records why the covering B-tree won for `orders`.

`userId` nearly doubles case 8's index, because the ids are 36-character text. It is there for
row-level security: the API role's policy reads `organizationId` and `userId`, and without
`userId` in the index the organisation's order count visits every one of its orders in the heap
(34,029 buffers against 558, and 65 ms against 19 ms, in `reports/rls-plans.md`). A database
without RLS on `orders` would not need it.

## Building and removing indexes in production

- `CREATE INDEX CONCURRENTLY` and `DROP INDEX CONCURRENTLY`, as every casebook fix does, so that
  writes continue; a failed concurrent build leaves an invalid index that must be dropped.
- Watch `pg_stat_user_indexes.idx_scan` over a full business cycle before dropping an index that
  looks unused, and remember that unique indexes enforce constraints even when never scanned.
- `REINDEX CONCURRENTLY` rebuilds a bloated index without blocking writes.
