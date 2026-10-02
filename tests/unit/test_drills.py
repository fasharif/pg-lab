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
    FailoverState,
    Recovered,
    analyse_failover,
    analyse_pitr,
    load_attempts,
    load_facts,
    longest_gap,
    node_sequence,
    parse_lsn,
    render,
    report_name,
    split_at_target,
)
from pglab.errors import LabError
from pglab.heartbeat import Attempt, Heartbeat, default_dsn
from tests.unit.test_reports import info


def attempt(
    seq: int, at: float, ok: bool = True, node: str | None = "pg1", lsn: str | None = None
) -> Attempt:
    return Attempt(
        seq, at, ok, node=node if ok else None, committed_at=at if ok else None, wal_lsn=lsn
    )


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


def test_longest_gap_runs_from_acknowledgement_to_acknowledgement() -> None:
    # Write 3 is sent at 0.3 s but waits for the promotion and is acknowledged at 4.0 s.
    attempts = [
        Attempt(1, 0.0, True, node="pg1", committed_at=0.01, acked_at=0.02),
        Attempt(2, 0.1, False, error="server closed the connection unexpectedly"),
        Attempt(3, 0.3, True, node="pg2", committed_at=3.99, acked_at=4.0),
        Attempt(4, 4.1, True, node="pg2", committed_at=4.11, acked_at=4.12),
    ]
    gap = longest_gap(attempts)
    assert gap is not None
    assert (gap.last_before, gap.first_after, gap.failed_between) == (1, 3, 1)
    assert gap.seconds == pytest.approx(3.98)
    # Logs written before the acknowledgement time was recorded fall back to commit times.
    old_log = [Attempt(a.seq, a.sent_at, a.ok, a.node, a.committed_at) for a in attempts]
    old_gap = longest_gap(old_log)
    assert old_gap is not None
    assert old_gap.seconds == pytest.approx(3.98)


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

    def fetchone(self) -> tuple[str, float, str]:
        return (self.server.node, 1000.0 + len(self.server.rows), f"0/{len(self.server.rows):X}")

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
    assert recovered.wal_lsn == "0/2"
    assert recovered.acked_at == 5.0
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


def test_parse_lsn_orders_wal_positions() -> None:
    assert parse_lsn("0/0") == 0
    assert parse_lsn("16/B374D4F8") == 0x16B374D4F8
    assert parse_lsn("1/0") > parse_lsn("0/FFFFFFFF")
    with pytest.raises(LabError, match="not a WAL position"):
        parse_lsn("B374D4F8")
    with pytest.raises(LabError, match="not a WAL position"):
        parse_lsn("0/XYZ")


# A PITR run: writes 1-4 were visible when the restore point (0/5000) was created; write 5 was
# running at that moment (its WAL position is below the point); 6 and 7 started afterwards.
PITR_ATTEMPTS = [
    attempt(1, 100.0, lsn="0/1000"),
    attempt(2, 100.1, lsn="0/2000"),
    attempt(3, 100.2, ok=False),
    attempt(4, 100.3, lsn="0/4000"),
    attempt(5, 100.4, lsn="0/4F00"),
    attempt(6, 100.5, lsn="0/6000"),
    attempt(7, 100.6, lsn="0/7000"),
]
PITR_FACTS = {
    "RUN_ID": "pitr-1",
    "TARGET_TYPE": "name",
    "TARGET_NAME": "pitr-1",
    "TARGET_LSN": "0/5000",
    "TARGET_TIME": "2026-09-26 10:00:00+00",
    "TARGET_EPOCH": "100.45",
    "LAST_SEQ_BEFORE_TARGET": "4",
    "COUNT_BEFORE": "10",
    "CHECKSUM_BEFORE": "42",
    "ROWS_DELETED": "10",
    "RTO_SECONDS": "12.5",
    "RECOVERY_DONE": "1",
    "HEARTBEAT_INTERVAL": "0.1",
}


def test_split_at_target_uses_visibility_and_wal_positions_not_clocks() -> None:
    split = split_at_target(PITR_ATTEMPTS, last_seq_before=4, target_lsn=parse_lsn("0/5000"))
    assert [a.seq for a in split.before] == [1, 2, 4]
    assert [a.seq for a in split.in_flight] == [5]
    assert [a.seq for a in split.after] == [6, 7]


def test_pitr_passes_when_recovery_keeps_exactly_the_writes_before_the_target() -> None:
    # Write 5 was in flight: kept or not, both are correct.
    for kept in ({1: 100.0, 2: 100.1, 4: 100.3}, {1: 100.0, 2: 100.1, 4: 100.3, 5: 100.4}):
        result = analyse_pitr(PITR_FACTS, PITR_ATTEMPTS, Recovered(10, "42", kept), measured=True)
        assert result.passed, [c for c in result.checks if not c.passed]
    result = analyse_pitr(
        PITR_FACTS,
        PITR_ATTEMPTS,
        Recovered(10, "42", {1: 100.0, 2: 100.1, 4: 100.3}),
        measured=True,
    )
    timings = dict(result.timings)
    loss = next(v for k, v in timings.items() if k.startswith("Data lost"))
    reached = next(v for k, v in timings.items() if k.startswith("Recovery reached"))
    # Lost: writes 5, 6 and 7; the last one committed 0.15 s after the target.
    assert loss == pytest.approx(0.15)
    assert reached == pytest.approx(0.15)
    assert (
        "Data lost by restoring in place",
        "3 acknowledged writes, every one committed after the target",
    ) in result.facts_table


def test_pitr_fails_when_a_write_before_the_target_is_missing_or_one_after_is_replayed() -> None:
    missing = analyse_pitr(
        PITR_FACTS, PITR_ATTEMPTS, Recovered(10, "42", {1: 100.0, 4: 100.3}), measured=False
    )
    assert not missing.passed
    replayed = analyse_pitr(
        PITR_FACTS,
        PITR_ATTEMPTS,
        Recovered(10, "42", {1: 100.0, 2: 100.1, 4: 100.3, 6: 100.5}),
        measured=False,
    )
    assert [c.description for c in replayed.checks if not c.passed] == [
        "no write that started after the restore point was replayed"
    ]
    wrong_content = analyse_pitr(
        PITR_FACTS, PITR_ATTEMPTS, Recovered(10, "41", {1: 1.0, 2: 1.0, 4: 1.0}), measured=False
    )
    assert not wrong_content.passed
    assert all(value is None for _, value in wrong_content.timings)


# The same run with the default target: the time recorded just before the accident, with the
# WAL insert position read right after it (0/5000).
PITR_TIME_FACTS = {
    **{k: v for k, v in PITR_FACTS.items() if k != "TARGET_NAME"},
    "TARGET_TYPE": "time",
    "TARGET_TIME": "2026-09-26 10:00:00.123456+00",
    "PGBACKREST_VERSION": "pgBackRest 2.59.1",
}


def test_pitr_to_a_recorded_time_uses_the_same_checks_and_names_the_time() -> None:
    kept = {1: 100.0, 2: 100.1, 4: 100.3}
    result = analyse_pitr(PITR_TIME_FACTS, PITR_ATTEMPTS, Recovered(10, "42", kept), measured=False)
    assert result.passed, [c for c in result.checks if not c.passed]
    table = dict(result.facts_table)
    assert table["Recovery target"].startswith("time `2026-09-26 10:00:00.123456+00`")
    assert "--type=time --target=<recorded time>" in table["Restore"]
    assert table["Backup"].endswith("(pgBackRest 2.59.1)")
    assert "every write committed before the recorded time is present" in [
        c.description for c in result.checks
    ]
    assert any("recovery_target_inclusive" in note for note in result.notes)
    replayed = analyse_pitr(
        PITR_TIME_FACTS, PITR_ATTEMPTS, Recovered(10, "42", {**kept, 7: 100.6}), measured=False
    )
    assert [c.description for c in replayed.checks if not c.passed] == [
        "no write that started after the recorded time was replayed"
    ]


def test_each_drill_variant_has_its_own_report() -> None:
    assert report_name("pitr", PITR_TIME_FACTS) == "pitr-drill.md"
    assert report_name("pitr", PITR_FACTS) == "pitr-drill-name.md"
    there = {"OLD_PRIMARY": "pg1", "NEW_PRIMARY": "pg2"}
    back = {"OLD_PRIMARY": "pg2", "NEW_PRIMARY": "pg1"}
    assert report_name("switchover", there) == "switchover-drill-pg1-to-pg2.md"
    assert report_name("switchover", back) == "switchover-drill-pg2-to-pg1.md"
    assert report_name("failover", there) == "failover-drill.md"


def test_pitr_rejects_an_unknown_target_type() -> None:
    with pytest.raises(LabError, match="unknown recovery target type 'xid'"):
        analyse_pitr(
            {**PITR_FACTS, "TARGET_TYPE": "xid"},
            PITR_ATTEMPTS,
            Recovered(10, "42", {}),
            measured=False,
        )


FAILOVER_FACTS = {
    "OLD_PRIMARY": "pg1",
    "NEW_PRIMARY": "pg2",
    "LOST_ROWS": "3",
    "NEW_SEQ": "1000000",
    "REWIND_ROLE": "rewind",
    "REWIND_DIVERGED": "servers diverged at WAL location 0/5000060 on timeline 4",
    "REWIND_SUMMARY": "pg_rewind: Done!",
    "STANDBY_STATE": "streaming",
}


def test_failover_passes_when_the_lost_rows_are_gone_everywhere() -> None:
    state = FailoverState("pg2", frozenset({1_000_000}), frozenset({1_000_000}), False)
    result = analyse_failover(FAILOVER_FACTS, state)
    assert result.passed, [c for c in result.checks if not c.passed]
    assert result.timings == []
    assert "## Timings" not in render(result, info(), command="./lab failover-drill")


def test_failover_fails_without_a_real_rewind_or_with_lost_rows_left() -> None:
    state = FailoverState("pg2", frozenset({1_000_000}), frozenset({1_000_000}), False)
    no_work = analyse_failover(
        {
            **FAILOVER_FACTS,
            "REWIND_DIVERGED": "",
            "REWIND_SUMMARY": "pg_rewind: no rewind required",
        },
        state,
    )
    assert [c.description for c in no_work.checks if not c.passed] == [
        "pg_rewind found the divergence and rewound pg1"
    ]
    leftover = analyse_failover(
        FAILOVER_FACTS,
        FailoverState("pg2", frozenset({1_000_000}), frozenset({2, 1_000_000}), False),
    )
    assert not leftover.passed
    superuser = analyse_failover(
        FAILOVER_FACTS, FailoverState("pg2", frozenset(), frozenset(), True)
    )
    assert "pg_rewind connected as a role that is not a superuser" in [
        c.description for c in superuser.checks if not c.passed
    ]
