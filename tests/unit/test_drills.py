"""Drill analysis and the heartbeat client, without a database."""

from __future__ import annotations

import io
import json
from pathlib import Path
from typing import Any, cast

import psycopg
import pytest

from pglab.drills import (
    Check,
    DrillResult,
    load_attempts,
    load_facts,
    longest_gap,
    node_sequence,
    render,
)
from pglab.errors import LabError
from pglab.heartbeat import Attempt, Heartbeat, default_dsn
from tests.unit.test_reports import info


def attempt(seq: int, at: float, ok: bool = True, node: str | None = "pg1") -> Attempt:
    return Attempt(seq, at, ok, node=node if ok else None, committed_at=at if ok else None)


def test_longest_gap_spans_the_failed_attempts() -> None:
    attempts = [
        attempt(1, 0.0),
        attempt(2, 0.1),
        attempt(3, 0.2, ok=False),
        attempt(4, 0.3, ok=False),
        attempt(5, 1.7, node="pg2"),
        attempt(6, 1.8, node="pg2"),
    ]
    gap = longest_gap(attempts)
    assert gap is not None
    assert gap.last_before == 2
    assert gap.first_after == 5
    assert gap.failed_between == 2
    assert gap.seconds == pytest.approx(1.6)


def test_longest_gap_needs_two_acknowledged_writes() -> None:
    assert longest_gap([attempt(1, 0.0), attempt(2, 0.1, ok=False)]) is None


def test_node_sequence_collapses_repeats() -> None:
    attempts = [
        attempt(1, 0.0),
        attempt(2, 0.1),
        attempt(3, 0.5, node="pg2"),
        attempt(4, 0.6, node="pg2"),
    ]
    assert node_sequence(attempts) == ["pg1", "pg2"]


def test_facts_file_is_key_value(tmp_path: Path) -> None:
    path = tmp_path / "facts.env"
    path.write_text(
        "# comment\nRUN_ID=pitr-1\nTARGET_TIME=2026-09-25 23:15:01+00\n\n", encoding="utf-8"
    )
    assert load_facts(path) == {"RUN_ID": "pitr-1", "TARGET_TIME": "2026-09-25 23:15:01+00"}
    path.write_text("not a pair\n", encoding="utf-8")
    with pytest.raises(LabError, match="not a KEY=value line"):
        load_facts(path)
    with pytest.raises(LabError, match="cannot read drill facts"):
        load_facts(tmp_path / "missing.env")


def test_attempts_are_read_in_sequence_order(tmp_path: Path) -> None:
    path = tmp_path / "heartbeat.jsonl"
    rows = [
        {"seq": 2, "sent_at": 1.0, "ok": True, "node": "pg1", "committed_at": 1.0, "error": None},
        {
            "seq": 1,
            "sent_at": 0.9,
            "ok": False,
            "node": None,
            "committed_at": None,
            "error": "down",
        },
    ]
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    assert [a.seq for a in load_attempts(path)] == [1, 2]


def test_report_hides_durations_of_functional_runs() -> None:
    result = DrillResult(
        "Drill",
        checks=[Check("it worked", True, "detail")],
        facts_table=[("Step", "value")],
        timings=[("Downtime", None)],
    )
    text = render(result, info(), command="./lab drill")
    assert "| it worked | pass | detail |" in text
    assert "| Downtime | pending a measured run |" in text
    measured = DrillResult("Drill", timings=[("Downtime", 1.234)])
    assert "| Downtime | 1.23 s |" in render(measured, info(measured=True), command="x")


class FakeConnection:
    """Stands in for a psycopg connection: fails while `down` is true."""

    def __init__(self, server: FakeServer) -> None:
        self.server = server
        self.closed = False

    def execute(self, _sql: str, params: tuple[Any, ...]) -> FakeConnection:
        if self.server.down:
            raise psycopg.OperationalError("server closed the connection unexpectedly")
        self.server.rows.append(params[1])
        return self

    def fetchone(self) -> tuple[str, float]:
        return (self.server.node, 1000.0 + len(self.server.rows))

    def close(self) -> None:
        self.closed = True


class FakeServer:
    def __init__(self) -> None:
        self.down = False
        self.node = "pg1"
        self.rows: list[int] = []
        self.connections = 0

    def connect(self, _dsn: str, _password: str) -> psycopg.Connection[tuple[Any, ...]]:
        self.connections += 1
        if self.down:
            raise psycopg.OperationalError("connection refused")
        return cast("psycopg.Connection[tuple[Any, ...]]", FakeConnection(self))


def test_heartbeat_logs_failures_and_reconnects() -> None:
    server = FakeServer()
    out = io.StringIO()
    beat = Heartbeat("run", "dsn", out, connector=server.connect, password="x", clock=lambda: 5.0)
    assert beat.beat().ok
    server.down = True
    failed = beat.beat()
    assert not failed.ok
    assert failed.error == "server closed the connection unexpectedly"
    assert not beat.beat().ok
    server.down = False
    server.node = "pg2"
    recovered = beat.beat()
    assert recovered.ok
    assert recovered.node == "pg2"
    assert server.rows == [1, 4]
    assert server.connections == 3
    lines = [json.loads(line) for line in out.getvalue().splitlines()]
    assert [line["ok"] for line in lines] == [True, False, False, True]


def test_heartbeat_stops_on_the_stop_file(tmp_path: Path) -> None:
    server = FakeServer()
    stop = tmp_path / "hb.stop"
    ticks = iter(float(t) for t in range(1000))

    def clock() -> float:
        now = next(ticks)
        if now >= 10:
            stop.touch()
        return now

    beat = Heartbeat(
        "run",
        "dsn",
        io.StringIO(),
        connector=server.connect,
        password="x",
        clock=clock,
        sleep=lambda _s: None,
    )
    count = beat.run(stop_file=stop, duration=10_000)
    assert 0 < count < 10


def test_default_dsn_targets_the_writable_node() -> None:
    dsn = default_dsn("pg1,pg2")
    assert "host=pg1,pg2" in dsn
    assert "port=5432,5432" in dsn
    assert "target_session_attrs=read-write" in dsn
