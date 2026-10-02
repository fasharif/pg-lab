"""Partition maintenance must finish what an interrupted run left behind.

DETACH PARTITION ... CONCURRENTLY commits in two steps. Cancelled between them, it leaves the
partition "detach pending", and every later DETACH of it fails until FINALIZE completes it. A
run that fails after the DETACH but before SET SCHEMA part_archive leaves a detached table in
schema part. partitioning.maintain() handles both before its own work. These tests create both
situations on a small partitioned table in schema part (needs ./lab partition first).
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import date

import psycopg
import pytest

from pglab import partitioning
from pglab.db import Connection, connect, scalar

PARENT = "part.lab_maintenance_test"
MONTHS = ("2026_01", "2026_02", "2026_03", "2026_04", "2026_05", "2026_06", "2026_07")
STRANDED = "lab_maintenance_test_p2020_01"


def _drop_everything(conn: Connection) -> None:
    conn.execute(f"DROP TABLE IF EXISTS {PARENT}, part.{STRANDED}, part_archive.{STRANDED}")
    for month in MONTHS:
        conn.execute(f"DROP TABLE IF EXISTS part_archive.lab_maintenance_test_p{month}")


@pytest.fixture
def parent() -> Iterator[str]:
    with connect() as conn:
        if scalar(conn, "SELECT to_regnamespace('part')") is None:
            pytest.skip("schema part does not exist: run ./lab partition first")
        _drop_everything(conn)
        conn.execute(f"CREATE TABLE {PARENT} (id int, at timestamp) PARTITION BY RANGE (at)")
        conn.execute(
            "SELECT part.create_monthly_partitions(%s::regclass, '2026-01-01', '2026-06-01')",
            (PARENT,),
        )
    yield PARENT
    with connect() as conn:
        _drop_everything(conn)


def _schema_of(conn: Connection, table: str) -> str:
    schema = scalar(
        conn,
        "SELECT n.nspname FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace"
        " WHERE c.relname = %s",
        (table,),
    )
    return str(schema)


@pytest.mark.integration
def test_maintenance_finishes_an_interrupted_detach_and_archives_a_stranded_table(
    parent: str,
) -> None:
    oldest = "part.lab_maintenance_test_p2026_01"
    with connect() as blocker, connect() as detacher:
        # A transaction that reads the parent holds a lock the second step of the concurrent
        # detach waits for; a statement timeout cancels it there, leaving the detach pending.
        with blocker.transaction():
            blocker.execute(f"SELECT count(*) FROM {parent}").fetchall()
            detacher.execute("SET statement_timeout = '2s'")
            with pytest.raises(psycopg.errors.QueryCanceled):
                detacher.execute(f"ALTER TABLE {parent} DETACH PARTITION {oldest} CONCURRENTLY")
        pending = detacher.execute(partitioning.PENDING_DETACH, (parent,)).fetchall()
        assert pending == [(oldest,)]
        # Until then, detaching it again fails (what broke every later maintenance run).
        detacher.execute("RESET statement_timeout")
        with pytest.raises(psycopg.errors.ObjectNotInPrerequisiteState):
            detacher.execute(f"ALTER TABLE {parent} DETACH PARTITION {oldest} CONCURRENTLY")
        # A table detached by a run that stopped before moving it to the archive.
        detacher.execute(f"CREATE TABLE part.{STRANDED} (id int, at timestamp)")

    with connect() as conn:
        result = partitioning.maintain(
            conn, ahead=1, retain=4, as_of=date(2026, 6, 10), parents=(parent,)
        )
        assert result.recovered == [oldest, f"part.{STRANDED}"]
        assert result.created == ["part.lab_maintenance_test_p2026_07"]
        assert result.detached == []
        assert conn.execute(partitioning.PENDING_DETACH, (parent,)).fetchall() == []
        assert _schema_of(conn, "lab_maintenance_test_p2026_01") == "part_archive"
        assert _schema_of(conn, STRANDED) == "part_archive"
        again = partitioning.maintain(
            conn, ahead=1, retain=4, as_of=date(2026, 6, 10), parents=(parent,)
        )
        assert (again.recovered, again.created, again.detached) == ([], [], [])


@pytest.mark.integration
def test_maintenance_detaches_old_partitions_into_the_archive(parent: str) -> None:
    with connect() as conn:
        result = partitioning.maintain(
            conn, ahead=1, retain=3, as_of=date(2026, 6, 10), parents=(parent,)
        )
        assert result.detached == [
            "part.lab_maintenance_test_p2026_01",
            "part.lab_maintenance_test_p2026_02",
        ]
        assert result.recovered == []
        assert _schema_of(conn, "lab_maintenance_test_p2026_02") == "part_archive"
        assert result.months_ready[parent] == 1
