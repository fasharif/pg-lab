# The data set

Files: `sql/lab/20_generator_model.sql` (model functions), `sql/generate/generate.sql` (the load).

```bash
./lab seed                    # LAB_SCALE from .env, 100000 by default
./lab seed --scale 10000000   # the documented target
```

## Sizes

SCALE is the approximate number of order lines. Every other table is sized from it
(`lab.dataset_size`):

| Table | Rows |
| --- | --- |
| `order_items` | about SCALE (1 to 9 lines per order, 5 on average) |
| `orders` | SCALE / 5 |
| `order_status_events` | one per status an order went through (about 3.8 per order) |
| `audit_logs` | SCALE |
| `quote_requests` | SCALE / 8, with 1 to 5 lines each |
| `quotations` | one for most quote requests, 2 to 6 lines each; 20% have a superseded first revision |
| `organizations` | SCALE / 2000 (at least 50), five members each |
| `users` | 20 staff, the organisation members and SCALE / 100 retail customers |
| `products` | SCALE / 200, between 1,000 and 50,000, in 40 categories |

At SCALE=10000000 the load behind the committed reports wrote 40,592,314 rows across the 18
tables; `./lab seed` writes the count per table to `reports/dataset.md`.

## Shape

- **Time.** Orders, quote requests and audit entries are spread evenly over the two years before
  the anchor (the hour the data was generated) and inserted in time order, as an append-only
  table would be, so `createdAt` correlates almost perfectly with the physical order (1.0000 for
  both `orders` and `audit_logs` in `pg_stats`, to four places, at SCALE=10000000,
  `reports/dataset.md`).
  Statuses follow age: old orders are delivered or cancelled, orders from the last week are
  pending, confirmed, processing or dispatched.
- **Skew.** A trade order goes to organisation `1 + floor(n × u^2.5)` for a uniform `u`, so
  organisation 1 is by far the largest customer and most organisations have a handful of
  orders. At SCALE=10000000 the largest of the 5,000 organisations had 39,688 of the 1,199,343
  trade orders (3.3%) and the median one 146 (`reports/dataset.md`).
  Retail customers and products are skewed the same way, less strongly.
- **Consistency.** Order totals equal the sum of their lines, because the header and the lines
  are computed by the same function (`lab.order_lines`). VAT is 5%; retail orders under
  AED 500 pay a delivery fee.
- **Determinism.** Values come from `hashint8extended(row number, salt)` and ids from
  `md5(kind || ':' || row number)`, so the same SCALE and anchor give the same rows, in parallel
  or not. Queries that TopFlow runs relative to "now" use `lab.anchor()` in the lab, so plans do
  not drift with the calendar.
- **Fiction.** Names, companies, brands and products are made up from short word lists; e-mail
  addresses use the reserved `example.com`, `example.net` and `topflow-lab.example` domains
  (a unit test checks this). No Top Flow data is used.

## Simplifications

- `orders.quotationId` is left empty: the generator does not link sales orders to the quotation
  they came from. None of the workload statements reads it.
- Superseded quotation revisions have a header but no lines.
- `carts` and `cart_items` hold a few rows only; the current API does not use them.
- Addresses are short and synthetic; `deliveryAddress` holds a small JSON snapshot.

## Loading fast

`lab.begin_bulk_load()` records every primary key, unique constraint, index and foreign key of
the TopFlow tables and drops them; the rows are inserted with `synchronous_commit = off`; the
saved definitions are then recreated in order (keys, indexes, foreign keys) and the tables are
vacuumed and analysed. An interrupted load can be run again: the saved definitions are kept until
the rebuild finishes.
