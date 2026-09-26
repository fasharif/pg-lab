"""Applying the casebook's fixes must leave exactly the intended indexes.

CREATE INDEX ... IF NOT EXISTS keeps whatever carries the name: an index left invalid by an
interrupted concurrent build, or an older definition. casebook.apply_all() checks validity and
the statement recorded in the index's comment, and rebuilds the index when either is wrong.
These tests break case 7's index both ways and apply the fixes again.
"""

from __future__ import annotations

from pathlib import Path

import psycopg
import pytest

from pglab import casebook
from pglab.db import Connection, connect, scalar
from pglab.definitions import Case, load_cases, load_workload

ROOT = Path(__file__).resolve().parents[2]
INDEX = "orders_createdAt_idx"


def _case(number: int) -> Case:
    cases = load_cases(ROOT / "casebook", load_workload(ROOT / "workload" / "queries.toml"))
    return next(case for case in cases if case.number == number)


def _state(conn: Connection) -> tuple[bool, str]:
    row = conn.execute(
        "SELECT x.indisvalid, pg_get_indexdef(x.indexrelid) FROM pg_index AS x"
        " WHERE x.indexrelid = %s::regclass",
        (f'public."{INDEX}"',),
    ).fetchone()
    assert row is not None
    return bool(row[0]), str(row[1])


@pytest.mark.integration
def test_an_older_definition_under_the_same_name_is_rebuilt() -> None:
    case = _case(7)
    with connect(application_name="pglab-test") as conn:
        conn.execute(f'DROP INDEX CONCURRENTLY IF EXISTS "{INDEX}"')
        conn.execute(f'CREATE INDEX CONCURRENTLY "{INDEX}" ON orders ("createdAt")')
        casebook.apply_all(conn, [case])
        valid, definition = _state(conn)
        comment = scalar(
            conn, "SELECT obj_description(%s::regclass, 'pg_class')", (f'public."{INDEX}"',)
        )
    assert valid
    assert 'INCLUDE (status, "totalAmount")' in definition
    assert comment == casebook.statement_tag(case.fix[0])


@pytest.mark.integration
def test_an_index_left_invalid_by_a_failed_concurrent_build_is_rebuilt() -> None:
    case = _case(7)
    with connect(application_name="pglab-test") as conn:
        conn.execute(f'DROP INDEX CONCURRENTLY IF EXISTS "{INDEX}"')
        # A unique index on a column full of duplicates fails half-way and stays behind, invalid.
        with pytest.raises(psycopg.errors.UniqueViolation):
            conn.execute(f'CREATE UNIQUE INDEX CONCURRENTLY "{INDEX}" ON orders (status)')
        assert _state(conn)[0] is False
        casebook.apply_all(conn, [case])
        valid, definition = _state(conn)
    assert valid
    assert 'INCLUDE (status, "totalAmount")' in definition
