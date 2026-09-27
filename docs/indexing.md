# Indexing strategy

What to index in TopFlow's database, what not to, and what each index costs on writes. Figures
come from `reports/indexing.md` (`./lab indexing`, SCALE=1000000, PostgreSQL 18.6, 2026-09-26)
unless a section gives its own command. Sizes are of freshly built indexes.

## Start from the statements, not the columns

Every index in the lab answers a statement the API sends (`workload/queries.toml`); nothing is
indexed because a column "looks important". The workload ranking (`reports/workload.md`) shows
which statements do the most work, and the casebook fixes the heaviest of them (ten cases; case
4 also fixes the search's pagination count). The rules that came out of it:

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
5. **Match the operator.** `ILIKE '%term%'` needs trigrams (pg_trgm GIN, case 4), and
   `LIKE 'prefix%'` under the `en_US.utf8` collation needs `text_pattern_ops` (case 1). A plain
   B-tree helps neither.
6. **Replace, do not accumulate.** `(status, updatedAt)` makes TopFlow's `(status)` redundant, so
   case 10 drops it and the table keeps the same number of indexes.

## What not to index

- **Booleans and low-selectivity flags on their own.** 97.4% of products are active, so an
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

SELECT round(100.0 * count(*) FILTER (WHERE "isActive") / count(*), 1) FROM products;  -- 97.4
```

## What the indexes cost

### Size

| Index (after the casebook) | Size | Table size |
| --- | ---: | ---: |
| `audit_logs_userId_createdAt_idx` (case 3) | 64.7 MB | `audit_logs`: 263 MB |
| `audit_logs_action_pattern_idx` (case 1) | 6.8 MB | |
| `orders_organizationId_createdAt_idx` with `INCLUDE (userId)` (case 8) | 18.9 MB | `orders`: 84.2 MB |
| `orders_createdAt_idx` with `INCLUDE` (case 7) | 7.8 MB | |
| three trigram GIN indexes on `orders` (case 4) | 6.1 + 7.1 + 4.1 MB | |
| `products_categoryId_visible_idx` (case 9) | 48 kB | `products`: 2.0 MB |

After the casebook, all indexes on `audit_logs` together take 181 MB, 0.69 times the table; on
`orders`, 72.1 MB, 0.86 times the table.

The largest single cost is the id type. TopFlow's ids are UUIDs stored as `TEXT` (36 characters),
so every primary key, foreign key and composite index that contains an id carries 37 bytes per
entry instead of 16. The same one million audit ids take 56.3 MB in the primary key's text index
and 30.1 MB in an index on the ids cast to `uuid` (`reports/indexing.md`, "Alternatives
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
| `audit_logs` | 3 | 1,860 B | 5 | 2,115 B | +14% |
| `orders` | 6 | 3,257 B | 11 | 4,750 B | +46% |

Both states write thousands of full-page images per probe (about 3,900 for `orders`, from
the report): indexes with scattered keys (ids, `entityId`) change a different page for nearly
every row, and the first change to a page after a checkpoint writes the whole page (compressed
here, `wal_compression = zstd`). The number of full-page images barely changes with the
casebook's indexes, so the extra WAL is mostly their own index records. The five indexes added
to `orders` are the three trigram GIN indexes of case 4 and the B-trees of cases 7 and 8. GIN's
`fastupdate` (on by default) appends new entries to a pending list and merges them later, which
keeps each insert cheap but moves the cost to vacuum or to the insert that overflows the list
(`gin_pending_list_limit`).

For TopFlow the trade-off is acceptable: orders are written a few times in their life and read
on every page view, and audit entries are written once. The order search is the fix to revisit
first if write volume grows, for example by searching order and PO numbers by prefix with
B-trees and keeping trigrams for names only.

### Alternatives measured

| Alternative | Size | Index it would replace |
| --- | ---: | ---: |
| BRIN on `orders.createdAt` | 24 kB | `orders_createdAt_idx`, 7.8 MB |
| BRIN on `audit_logs.createdAt` | 24 kB | `audit_logs_createdAt_idx`, 21.4 MB |
| case 8 without `INCLUDE (userId)` | 10.2 MB | `orders_organizationId_createdAt_idx`, 18.9 MB |

BRIN stores one summary per block range, which works here because rows are inserted in
`createdAt` order. It serves range filters (a bitmap scan of the matching ranges) but cannot return
rows in order, and the dashboard's newest orders and the audit screen's newest entries both sort
by `createdAt`. BRIN becomes the right choice for a time column that is only filtered, never
sorted; ADR 7 in docs/decisions.md records why the covering B-tree won for `orders`.

`userId` nearly doubles case 8's index, because the ids are 36-character text. It is there for
row-level security: the API role's policy reads `organizationId` and `userId`, and without
`userId` in the index the organisation's order count visits every one of its orders in the heap
(6,764 buffers against 143 in `reports/rls-plans.md`). A database without RLS on `orders`
would not need it.

## Building and removing indexes in production

- `CREATE INDEX CONCURRENTLY` and `DROP INDEX CONCURRENTLY`, as every casebook fix does, so that
  writes continue; a failed concurrent build leaves an invalid index that must be dropped.
- Watch `pg_stat_user_indexes.idx_scan` over a full business cycle before dropping an index that
  looks unused, and remember that unique indexes enforce constraints even when never scanned.
- `REINDEX CONCURRENTLY` rebuilds a bloated index without blocking writes.
