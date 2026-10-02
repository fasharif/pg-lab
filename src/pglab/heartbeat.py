"""A client that writes one small row at a fixed interval, as an application would.

Used by the drills to see a failover or recovery from the client's side: every attempt is
logged as one JSON line with its outcome and the client's time when it was sent and, for a
write that succeeded, when it was acknowledged, so the analysis can compute the longest gap
between two acknowledgements (write downtime) and check that every acknowledged write
survived. Each acknowledged write also records the server's WAL insert position read inside
its transaction: its commit record comes later in the WAL, which lets the PITR analysis tell
for certain that a write started after the recovery target. It connects with libpq's
multi-host syntax and target_session_attrs=read-write, so after a switchover it reconnects to
whichever node accepts writes.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO

import psycopg

from pglab.db import role_password

type Clock = Callable[[], float]
type Connector = Callable[[str, str], psycopg.Connection[tuple[Any, ...]]]


def _connect(dsn: str, password: str) -> psycopg.Connection[tuple[Any, ...]]:
    return psycopg.connect(dsn, password=password, autocommit=True)


@dataclass(frozen=True)
class Attempt:
    seq: int
    sent_at: float  # client clock, seconds since the epoch
    ok: bool
    node: str | None = None
    committed_at: float | None = None  # server clock, seconds since the epoch
    error: str | None = None
    # pg_current_wal_insert_lsn() inside the write's transaction: a lower bound of its commit LSN.
    wal_lsn: str | None = None
    # client clock when the server's acknowledgement arrived (logs before 2026-10-02 lack it)
    acked_at: float | None = None


def default_dsn(hosts: str) -> str:
    ports = ",".join("5432" for _ in hosts.split(","))
    return (
        f"host={hosts} port={ports} dbname=topflow user=topflow_app "
        "target_session_attrs=read-write connect_timeout=2 application_name=pglab-heartbeat"
    )


class Heartbeat:
    """Writes lab.heartbeat rows until the stop file appears or the duration elapses."""

    def __init__(
        self,
        run_id: str,
        dsn: str,
        out: TextIO,
        *,
        interval: float = 0.1,
        clock: Clock = time.time,
        sleep: Callable[[float], None] = time.sleep,
        connector: Connector = _connect,
        password: str | None = None,
    ) -> None:
        self.run_id = run_id
        self.dsn = dsn
        self.out = out
        self.interval = interval
        self.clock = clock
        self.sleep = sleep
        self.connector = connector
        self.password = password
        self.conn: psycopg.Connection[tuple[Any, ...]] | None = None
        self.seq = 0

    def _connect(self) -> psycopg.Connection[tuple[Any, ...]]:
        if self.conn is None or self.conn.closed:
            self.conn = self.connector(self.dsn, self.password or role_password("topflow_app"))
        return self.conn

    def beat(self) -> Attempt:
        self.seq += 1
        sent_at = self.clock()
        try:
            conn = self._connect()
            row = conn.execute(
                "INSERT INTO lab.heartbeat (run_id, seq, sent_at) "
                "VALUES (%s, %s, to_timestamp(%s)) "
                "RETURNING node, extract(epoch FROM committed_at)::float8,"
                " pg_current_wal_insert_lsn()::text",
                (self.run_id, self.seq, sent_at),
            ).fetchone()
            acked_at = self.clock()
            node, committed, wal_lsn = row if row else (None, None, None)
            attempt = Attempt(
                self.seq,
                sent_at,
                True,
                node=node,
                committed_at=committed,
                wal_lsn=wal_lsn,
                acked_at=acked_at,
            )
        except psycopg.Error as exc:
            if self.conn is not None:
                self.conn.close()
            self.conn = None
            attempt = Attempt(self.seq, sent_at, False, error=str(exc).strip().splitlines()[0])
        self.out.write(json.dumps(asdict(attempt)) + "\n")
        self.out.flush()
        return attempt

    def run(self, *, stop_file: Path, duration: float) -> int:
        deadline = self.clock() + duration
        while self.clock() < deadline and not stop_file.exists():
            started = self.clock()
            self.beat()
            self.sleep(max(0.0, self.interval - (self.clock() - started)))
        if self.conn is not None:
            self.conn.close()
        return self.seq


def run_heartbeat(
    run_id: str, hosts: str, out_path: Path, *, interval: float, duration: float
) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    stop_file = out_path.with_suffix(".stop")
    stop_file.unlink(missing_ok=True)
    done_file = out_path.with_suffix(".done")
    done_file.unlink(missing_ok=True)
    try:
        with out_path.open("a", encoding="utf-8") as out:
            heartbeat = Heartbeat(run_id, default_dsn(hosts), out, interval=interval)
            return heartbeat.run(stop_file=stop_file, duration=duration)
    finally:
        # The drill scripts wait for this file before they analyse the log.
        done_file.touch()
