# Source of the TopFlow schema

The four `.sql` files in this folder are copied unchanged from TopFlow Hub, Farah Sharif's
portfolio commerce platform (MIT licence, same author as this lab).

| Item | Value |
| --- | --- |
| Repository | https://github.com/fasharif/topflow |
| Commit | `61310d2457205b7a59ebd0be4c4e459122906584` (2026-09-25) |
| Path | `packages/database/prisma/migrations/<name>/migration.sql` |
| Generator | Prisma Migrate (hand-edited where the migration says so) |

| File | SHA-256 |
| --- | --- |
| `20260822220721_init.sql` | `e1bd1d623e27cbf8613da3ed38e0df84c41c54d589c49da9fc9a10b72b5e64a7` |
| `20260914090000_platform_v2.sql` | `156a4359747b0f8cf4507285e9e6a119043b83693c6eb49da3d480a2d3dc9408` |
| `20260915100000_catalogue_pricing_website_quotes.sql` | `83e0e0db36647d1c3c65a0dbf1581a4bce07908f4f951a02dd750cb33d06e481` |
| `20260916090000_supabase_auth.sql` | `dfee6763300594b0c5ffa841c21812ee1c0c0a45569736302c7f666b01b87246` |

`./lab migrate` applies them in name order as `topflow_migrator`, exactly as Prisma would on an
empty database, and records each one in `lab.schema_migrations`. The unit test
`tests/unit/test_topflow_source.py` checks the hashes above, so an accidental edit fails CI.

TopFlow Hub is a portfolio project built with Top Flow's permission. It is not Top Flow's
official system, and nothing in this lab is connected to Top Flow or holds its data: every row
is produced by the generator in `sql/generate/`.
