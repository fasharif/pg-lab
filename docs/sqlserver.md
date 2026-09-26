# SQL Server chapter (written, not run)

**Status: the scripts are written and syntax-checked, but SQL Server has not been run in this
repository.** Running it requires accepting Microsoft's licence terms for SQL Server
(`ACCEPT_EULA=Y`). That is a decision for the person running the lab, so `./lab sqlserver` stops
unless you set `MSSQL_ACCEPT_EULA=Y` yourself. No SQL Server plan, read count or timing is
claimed anywhere in this repository.

## What it does

The same exercise as the PostgreSQL casebook, on SQL Server 2022 Developer edition in Docker:

```bash
MSSQL_ACCEPT_EULA=Y ./lab sqlserver up          # builds sqlserver/Dockerfile, starts pg-lab-mssql
MSSQL_ACCEPT_EULA=Y ./lab sqlserver seed --scale 1000000
MSSQL_ACCEPT_EULA=Y ./lab sqlserver casebook    # plans before, fixes, plans after, report
./lab sqlserver down
```

| File | Content |
| --- | --- |
| `sqlserver/Dockerfile` | `mcr.microsoft.com/mssql/server:2022-CU27-ubuntu-22.04` plus the Full-Text Search package from Microsoft's repository |
| `sqlserver/compose.yaml` | one service on 127.0.0.1:55414, 3 GB memory limit, `MSSQL_PID=Developer` |
| `sqlserver/sql/01_schema.sql` | the seven TopFlow tables the ten statements read, with TopFlow's indexes |
| `sqlserver/sql/02_generate.sql` | generator with `GENERATE_SERIES` (new in SQL Server 2022) and `HASHBYTES`, same distributions as the PostgreSQL generator |
| `sqlserver/sql/10_queries_before.sql`, `11_queries_after.sql` | the ten statements with `SET STATISTICS XML ON` and `SET STATISTICS IO ON` |
| `sqlserver/sql/20_fixes.sql` | the fixes in SQL Server terms |
| `sqlserver/expectations.toml` | the plan each fixed statement should have (to confirm on the first run) |
| `src/pglab/mssql.py` | reads the sqlcmd output: showplan operators and indexes, logical reads per statement |

The `casebook` step writes `reports/sqlserver-casebook.md` with logical reads (SQL Server's
counterpart of shared buffers) before and after each fix, the indexes the new plans use and
whether each plan matches its expectation.

## How the fixes translate

| Case | PostgreSQL fix | SQL Server fix | Difference |
| --- | --- | --- | --- |
| 1 | B-tree with `text_pattern_ops` | ordinary nonclustered index on `action` | SQL Server can seek `LIKE 'prefix%'` under any collation; PostgreSQL needs byte-wise order |
| 2, 3 | `(userId, createdAt)` | same | none |
| 4 | pg_trgm GIN indexes and a UNION rewrite | full-text indexes and `CONTAINS` in the UNION rewrite | SQL Server has no trigram index: full-text search matches words and word prefixes, not any substring. The rewrite searches for the order number's "year-sequence" prefix as a phrase; how the word breaker splits `TF-SO-2024-0000123` must be checked on the first run |
| 5, 6, 7 | covering B-tree `createdAt INCLUDE (status, totalAmount)` | same (`INCLUDE` exists in both) | a columnstore index is SQL Server's alternative for large aggregates |
| 8 | `(organizationId, createdAt)` | same | none |
| 9 | partial index `WHERE "isActive" AND NOT "isTradeOnly"` | filtered index `WHERE isActive = 1 AND isTradeOnly = 0` | SQL Server matches a filtered index only when the predicate is visible at compile time, so the statement keeps literals (or needs `OPTION (RECOMPILE)` with parameters) |
| 10 | `(status, updatedAt)`, drop `(status)` | same | none |

Two more differences matter for TopFlow's schema on SQL Server:

- A `PRIMARY KEY` is clustered by default. Prisma keeps that default, so the tables are clustered
  on random UUID text: every insert lands on a random page (page splits, fragmentation). A
  clustered index on `createdAt` with a nonclustered primary key would suit append-mostly tables
  such as `audit_logs`. The schema keeps Prisma's default so that the baseline is faithful.
- Statements use `OPTION (RECOMPILE)` so that each is planned for its actual values, like the
  custom plans in the PostgreSQL casebook. Prisma sends parameterised statements through
  `sp_executesql`, where parameter sniffing decides the cached plan; Query Store (enabled by the
  schema script) is the tool for that analysis.

## What was checked without running SQL Server

- `sqlfluff lint --dialect tsql` parses every T-SQL file (in `./lab check` and CI). Its grammar
  does not know `CONTAINS`, so the three full-text lines carry `-- noqa: PRS`.
- `tests/unit/test_mssql.py` tests the showplan and logical-reads parser on a hand-written
  (synthetic) sqlcmd output, and that `expectations.toml` covers the ten cases.
- The licence guard: `./lab sqlserver up` without `MSSQL_ACCEPT_EULA=Y` stops with an
  explanation, and `docker compose` itself refuses the file without the variable.
