"""Analysis and reports of the point-in-time recovery and switchover drills.

The drill scripts (scripts/pitr-drill.sh, scripts/switchover.sh) drive Docker and record what
they did in a facts file (KEY=value lines) next to the heartbeat log. This module checks the
outcome against the database and renders the report. Correctness checks (row counts,
checksums, acknowledged writes) are always reported; durations (RTO, RPO window, write
downtime) are shown only for measured runs.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from pglab.db import Connection, scalar
from pglab.errors import LabError
from pglab.heartbeat import Attempt
from pglab.report import PENDING, RunInfo, table


def load_facts(path: Path) -> dict[str, str]:
    facts: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise LabError(f"cannot read drill facts {path}: {exc}") from exc
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise LabError(f"{path}: not a KEY=value line: {line!r}")
        facts[key.strip()] = value.strip()
    return facts


def fact(facts: dict[str, str], key: str) -> str:
    if key not in facts:
        raise LabError(f"drill facts are missing {key}")
    return facts[key]


def load_attempts(path: Path) -> list[Attempt]:
    attempts = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise LabError(f"cannot read heartbeat log {path}: {exc}") from exc
    for line in lines:
        if line.strip():
            attempts.append(Attempt(**json.loads(line)))
    return sorted(attempts, key=lambda a: a.seq)


@dataclass(frozen=True)
class Gap:
    """The longest time between two consecutive acknowledged writes."""

    seconds: float
    last_before: int
    first_after: int
    failed_between: int


def longest_gap(attempts: Sequence[Attempt]) -> Gap | None:
    best: Gap | None = None
    previous: Attempt | None = None
    failed = 0
    for attempt in attempts:
        if not attempt.ok:
            failed += 1
            continue
        if previous is not None:
            seconds = attempt.sent_at - previous.sent_at
            if best is None or seconds > best.seconds:
                best = Gap(seconds, previous.seq, attempt.seq, failed)
        previous = attempt
        failed = 0
    return best


def node_sequence(attempts: Sequence[Attempt]) -> list[str]:
    """Nodes that acknowledged writes, in order, with repeats collapsed (pg1, pg2, ...)."""
    nodes: list[str] = []
    for attempt in attempts:
        if attempt.ok and attempt.node and (not nodes or nodes[-1] != attempt.node):
            nodes.append(attempt.node)
    return nodes


@dataclass
class Check:
    description: str
    passed: bool
    detail: str = ""


@dataclass
class DrillResult:
    title: str
    checks: list[Check] = field(default_factory=list)
    facts_table: list[tuple[str, str]] = field(default_factory=list)
    timings: list[tuple[str, float | None]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return all(check.passed for check in self.checks)


def _acked(attempts: Sequence[Attempt]) -> list[Attempt]:
    return [a for a in attempts if a.ok and a.committed_at is not None]


def _present(conn: Connection, run_id: str) -> dict[int, float]:
    rows = conn.execute(
        "SELECT seq, extract(epoch FROM committed_at)::float8 FROM lab.heartbeat WHERE run_id = %s",
        (run_id,),
    ).fetchall()
    return {int(seq): float(at) for seq, at in rows}


def order_items_fingerprint(conn: Connection) -> tuple[int, str]:
    """Row count and an order-independent content checksum (sum of 64-bit row hashes)."""
    row = conn.execute(
        "SELECT count(*), coalesce(sum(hashtextextended(t::text, 0)), 0)::text"
        " FROM order_items AS t"
    ).fetchone()
    if row is None:
        raise LabError("could not fingerprint order_items")
    return int(row[0]), str(row[1])


def analyse_pitr(
    conn: Connection, facts: dict[str, str], attempts: Sequence[Attempt], *, measured: bool
) -> DrillResult:
    target = float(fact(facts, "TARGET_EPOCH"))
    run_id = fact(facts, "RUN_ID")
    count_before, checksum_before = int(fact(facts, "COUNT_BEFORE")), fact(facts, "CHECKSUM_BEFORE")
    count_after, checksum_after = order_items_fingerprint(conn)
    deleted = int(fact(facts, "ROWS_DELETED"))
    present = _present(conn, run_id)
    acked = _acked(attempts)
    before_target = [a for a in acked if a.committed_at is not None and a.committed_at <= target]
    after_target = [a for a in acked if a.committed_at is not None and a.committed_at > target]
    missing = [a.seq for a in before_target if a.seq not in present]
    survived_after = [seq for seq, at in present.items() if at > target]
    last_restored = max((at for at in present.values() if at <= target), default=None)

    result = DrillResult("Point-in-time recovery drill")
    result.checks = [
        Check(
            "the accident removed every order line",
            deleted == count_before,
            f"DELETE removed {deleted:,} of {count_before:,} rows",
        ),
        Check(
            "order lines are back: same row count as before the accident",
            count_after == count_before,
            f"{count_after:,} rows (expected {count_before:,})",
        ),
        Check(
            "order lines are back: same content checksum as before the accident",
            checksum_after == checksum_before,
            f"sum of row hashes {checksum_after} (expected {checksum_before})",
        ),
        Check(
            "every write acknowledged before the recovery target is present",
            not missing and bool(before_target),
            f"{len(before_target):,} acknowledged before the target, {len(missing)} missing",
        ),
        Check(
            "nothing committed after the recovery target was replayed",
            not survived_after,
            f"{len(survived_after)} rows newer than the target after recovery",
        ),
        Check(
            "the server finished recovery and accepts writes",
            facts.get("RECOVERY_DONE") == "1",
            f"timeline {facts.get('TIMELINE_AFTER', '?')}",
        ),
    ]
    result.facts_table = [
        ("Backup", f"full backup {facts.get('BACKUP_LABEL', '?')} (pgBackRest)"),
        ("Recovery target", f"{fact(facts, 'TARGET_TIME')} (recorded just before the DELETE)"),
        ("Accident", "`DELETE FROM order_items` without a WHERE clause"),
        ("Restore", "`pgbackrest restore --delta --type=time --target-action=promote`"),
        (
            "Timeline",
            f"{facts.get('TIMELINE_BEFORE', '?')} before, "
            f"{facts.get('TIMELINE_AFTER', '?')} after promotion",
        ),
        ("Writes acknowledged after the target (discarded by design)", f"{len(after_target):,}"),
    ]
    rto = float(fact(facts, "RTO_SECONDS"))
    rpo = target - last_restored if last_restored is not None else None
    result.timings = [
        (
            "Recovery time (RTO): damaged primary stopped until the restored one accepts writes",
            rto if measured else None,
        ),
        (
            "Data-loss window (RPO) before the target: target minus last recovered commit",
            rpo if measured else None,
        ),
    ]
    result.notes = [
        "The heartbeat client wrote one row every "
        f"{facts.get('HEARTBEAT_INTERVAL', '?')} s throughout; its log is the evidence for the "
        "acknowledged-writes checks.",
    ]
    return result


def analyse_switchover(
    conn: Connection, facts: dict[str, str], attempts: Sequence[Attempt], *, measured: bool
) -> DrillResult:
    run_id = fact(facts, "RUN_ID")
    old, new = fact(facts, "OLD_PRIMARY"), fact(facts, "NEW_PRIMARY")
    present = _present(conn, run_id)
    acked = _acked(attempts)
    missing = [a.seq for a in acked if a.seq not in present]
    nodes = node_sequence(attempts)
    gap = longest_gap(attempts)
    new_primary_node = scalar(conn, "SELECT current_setting('cluster_name')")
    split_brain = False
    seen_new = False
    for attempt in attempts:
        if attempt.ok and attempt.node == new:
            seen_new = True
        elif attempt.ok and attempt.node == old and seen_new:
            split_brain = True
    result = DrillResult("Planned switchover drill")
    result.checks = [
        Check(
            f"{new} was promoted and accepts writes",
            new_primary_node == new,
            f"writes now go to {new_primary_node}",
        ),
        Check(
            "the client moved from the old primary to the new one without reconfiguration",
            nodes[:1] == [old] and nodes[-1:] == [new],
            " -> ".join(nodes) or "no writes",
        ),
        Check(
            "every acknowledged write is on the new primary",
            not missing and bool(acked),
            f"{len(acked):,} acknowledged, {len(missing)} missing",
        ),
        Check(
            "no write reached the old primary after the promotion (no split brain)", not split_brain
        ),
        Check(
            f"pg_rewind ran on {old} before it rejoined",
            facts.get("REWIND_OK") == "1",
            facts.get("REWIND_SUMMARY", ""),
        ),
        Check(
            f"{old} streams from {new} again",
            facts.get("STANDBY_STATE") == "streaming",
            f"pg_stat_replication state: {facts.get('STANDBY_STATE', 'none')}",
        ),
    ]
    result.facts_table = [
        ("Old primary", old),
        ("New primary", new),
        ("Client connection", "libpq multi-host `host=pg1,pg2 target_session_attrs=read-write`"),
        (
            "Steps",
            "checkpoint; stop the old primary (fast shutdown); check the standby has "
            "received its last WAL; promote; pg_rewind the old primary; restart it as a "
            "standby of the new one",
        ),
    ]
    result.timings = [
        (
            "Write downtime seen by the client: longest gap between acknowledged writes",
            gap.seconds if (gap and measured) else None,
        ),
        (
            "Switchover script: old primary stopped until the new one was promoted",
            float(fact(facts, "PROMOTE_SECONDS")) if measured else None,
        ),
    ]
    if gap and measured:
        result.notes.append(f"{gap.failed_between} write attempts failed during the longest gap.")
    return result


def render(result: DrillResult, info: RunInfo, *, command: str) -> str:
    lines = [
        f"# {result.title}",
        "",
        *info.header_lines(command),
        "",
        "## What happened",
        "",
        table(["", ""], result.facts_table),
        "",
        "## Checks",
        "",
        table(
            ["Check", "Result", "Detail"],
            [(c.description, "pass" if c.passed else "FAIL", c.detail) for c in result.checks],
            "lcl",
        ),
        "",
        "## Timings",
        "",
        table(
            ["Measure", "Value"],
            [
                (label, PENDING if value is None else f"{value:.2f} s")
                for label, value in result.timings
            ],
            "lr",
        ),
        "",
        *result.notes,
        "",
    ]
    return "\n".join(lines)
