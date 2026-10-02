"""Analysis and reports of the reliability drills: point-in-time recovery, planned switchover
and unplanned failover (a crashed primary).

The drill functions in scripts/drills.sh drive Docker and record what they did in a facts file
(KEY=value lines) next to the heartbeat log. This module checks the outcome and renders the
report. The PITR and failover analyses are pure functions of the facts, the heartbeat log and a
few values read from the database by the caller, so they are unit-tested without a server.
Correctness checks (row counts, checksums, acknowledged writes) are always reported; durations
(RTO, data-loss window, write downtime) are shown only for measured runs.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime
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


def parse_lsn(text: str) -> int:
    """A WAL position such as '16/B374D4F8' as an integer, for comparisons."""
    high, sep, low = text.strip().partition("/")
    if not sep:
        raise LabError(f"not a WAL position: {text!r}")
    try:
        return (int(high, 16) << 32) + int(low, 16)
    except ValueError as exc:
        raise LabError(f"not a WAL position: {text!r}") from exc


@dataclass(frozen=True)
class Gap:
    """The longest time between two consecutive acknowledged writes."""

    seconds: float
    last_before: int
    first_after: int
    failed_between: int


def acknowledged_at(attempt: Attempt) -> float:
    """When the client learnt that a write succeeded. Older logs have no acknowledgement time:
    the commit time stands in for it (the server and the client share the Docker VM's clock),
    then the time the write was sent."""
    if attempt.acked_at is not None:
        return attempt.acked_at
    if attempt.committed_at is not None:
        return attempt.committed_at
    return attempt.sent_at


def longest_gap(attempts: Sequence[Attempt]) -> Gap | None:
    """The write downtime seen by the client: the longest time from one acknowledged write to
    the next. Measured between acknowledgements, not between sends: a write that waits seconds
    for a server that is being promoted is sent early but acknowledged late."""
    best: Gap | None = None
    previous: Attempt | None = None
    failed = 0
    for attempt in attempts:
        if not attempt.ok:
            failed += 1
            continue
        if previous is not None:
            seconds = acknowledged_at(attempt) - acknowledged_at(previous)
            if best is None or seconds > best.seconds:
                best = Gap(seconds, previous.seq, attempt.seq, failed)
        previous = attempt
        failed = 0
    return best


def epoch_of(timestamp: str) -> float:
    """Seconds since the epoch of an ISO 8601 time such as Docker's
    '2026-10-02T16:44:41.313133287Z' (digits beyond microseconds are dropped)."""
    try:
        return datetime.fromisoformat(timestamp).timestamp()
    except ValueError as exc:
        raise LabError(f"not an ISO 8601 time: {timestamp!r}") from exc


def reconnection(attempts: Sequence[Attempt], node: str) -> float | None:
    """How long the client's first acknowledged write on `node` took, from sending it to its
    acknowledgement: mostly the client's reconnection after the old primary went away."""
    for attempt in attempts:
        if attempt.ok and attempt.node == node:
            return acknowledged_at(attempt) - attempt.sent_at
    return None


RECONNECTION = (
    "Reconnection: the client's first write on the new primary, from sending it to its "
    "acknowledgement"
)


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


def heartbeat_rows(conn: Connection, run_id: str) -> dict[int, float]:
    """This run's heartbeat rows on the connected server: seq -> committed_at (epoch)."""
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


@dataclass(frozen=True)
class Recovered:
    """What the restored database holds, read by the caller after the PITR drill."""

    count: int
    checksum: str
    present: dict[int, float]  # heartbeat seq -> committed_at (server clock, epoch seconds)


@dataclass(frozen=True)
class TargetSplit:
    """The acknowledged heartbeat writes, classified against the recovery target.

    before: visible to the statement that recorded the target (the restore point, or the time
    just before the accident), so committed, with their commit records written and their
    commit times taken, before it; recovery must keep every one.
    after: the WAL insert position read inside their transaction is already past the position
    recorded at the target, so their commit record comes later in the WAL and their commit time
    is later than the recorded time; recovery must drop every one.
    in_flight: neither (at most the one or two writes running while the target was recorded);
    either outcome is correct, so they are counted but not checked.
    """

    before: list[Attempt]
    after: list[Attempt]
    in_flight: list[Attempt]


def split_at_target(
    attempts: Sequence[Attempt], last_seq_before: int, target_lsn: int
) -> TargetSplit:
    before: list[Attempt] = []
    after: list[Attempt] = []
    in_flight: list[Attempt] = []
    for attempt in _acked(attempts):
        if attempt.seq <= last_seq_before:
            before.append(attempt)
        elif attempt.wal_lsn is not None and parse_lsn(attempt.wal_lsn) > target_lsn:
            after.append(attempt)
        else:
            in_flight.append(attempt)
    return TargetSplit(before, after, in_flight)


@dataclass(frozen=True)
class TargetWords:
    """How a PITR report names its recovery target."""

    noun: str  # "the recorded time", "the restore point"
    description: str  # the "Recovery target" row of the report
    restore: str  # the pgBackRest command, with the target as a placeholder


def target_words(facts: dict[str, str]) -> TargetWords:
    """TARGET_TYPE time: the time recorded just before the accident, as an operator would have
    it; name: a restore point the drill created just before the accident."""
    kind = facts.get("TARGET_TYPE", "name")
    lsn = facts.get("TARGET_LSN", "?")
    when = facts.get("TARGET_TIME", "?")
    if kind == "time":
        return TargetWords(
            "the recorded time",
            f"time `{when}`, recorded just before the DELETE (WAL insert position {lsn} "
            "read right after it)",
            "`pgbackrest restore --delta --type=time --target=<recorded time> "
            "--target-action=promote`",
        )
    if kind == "name":
        return TargetWords(
            "the restore point",
            f"restore point `{facts.get('TARGET_NAME', '?')}` at WAL {lsn}, created at {when} "
            "just before the DELETE",
            "`pgbackrest restore --delta --type=name --target=<restore point> "
            "--target-action=promote`",
        )
    raise LabError(f"unknown recovery target type {kind!r} (expected time or name)")


def analyse_pitr(
    facts: dict[str, str], attempts: Sequence[Attempt], recovered: Recovered, *, measured: bool
) -> DrillResult:
    words = target_words(facts)
    target_epoch = float(fact(facts, "TARGET_EPOCH"))
    target_lsn_text = fact(facts, "TARGET_LSN")
    count_before, checksum_before = int(fact(facts, "COUNT_BEFORE")), fact(facts, "CHECKSUM_BEFORE")
    deleted = int(fact(facts, "ROWS_DELETED"))
    split = split_at_target(
        attempts, int(fact(facts, "LAST_SEQ_BEFORE_TARGET")), parse_lsn(target_lsn_text)
    )
    present = recovered.present
    missing = [a.seq for a in split.before if a.seq not in present]
    replayed_after = [a.seq for a in split.after if a.seq in present]
    discarded = [a for a in _acked(attempts) if a.seq not in present]
    last_recovered = max(present.values(), default=None)
    last_discarded = max((a.committed_at for a in discarded if a.committed_at), default=None)

    result = DrillResult("Point-in-time recovery drill")
    result.checks = [
        Check(
            "the accident removed every order line",
            deleted == count_before,
            f"DELETE removed {deleted:,} of {count_before:,} rows",
        ),
        Check(
            "order lines are back: same row count as before the accident",
            recovered.count == count_before,
            f"{recovered.count:,} rows (expected {count_before:,})",
        ),
        Check(
            "order lines are back: same content checksum as before the accident",
            recovered.checksum == checksum_before,
            f"sum of row hashes {recovered.checksum} (expected {checksum_before})",
        ),
        Check(
            f"every write committed before {words.noun} is present",
            not missing and bool(split.before),
            f"{len(split.before):,} committed before it, {len(missing)} missing",
        ),
        Check(
            f"no write that started after {words.noun} was replayed",
            not replayed_after and bool(split.after),
            f"{len(split.after):,} started after it, {len(replayed_after)} replayed",
        ),
        Check(
            "the server finished recovery and accepts writes",
            facts.get("RECOVERY_DONE") == "1",
            f"timeline {facts.get('TIMELINE_AFTER', '?')}",
        ),
    ]
    result.facts_table = [
        (
            "Backup",
            f"full backup {facts.get('BACKUP_LABEL', '?')} "
            f"({facts.get('PGBACKREST_VERSION', 'pgBackRest')})",
        ),
        ("Recovery target", words.description),
        ("Accident", "`DELETE FROM order_items` without a WHERE clause"),
        ("Restore", words.restore),
        (
            "Timeline",
            f"{facts.get('TIMELINE_BEFORE', '?')} before, "
            f"{facts.get('TIMELINE_AFTER', '?')} after promotion",
        ),
        (
            "Acknowledged client writes",
            f"{len(split.before):,} before {words.noun}, {len(split.in_flight)} in flight "
            f"while it was recorded, {len(split.after):,} after it",
        ),
        (
            "Data lost by restoring in place",
            f"{len(discarded):,} acknowledged writes, every one committed after the target",
        ),
    ]
    rto = float(fact(facts, "RTO_SECONDS"))
    loss_window = (
        last_discarded - target_epoch if (last_discarded is not None and discarded) else 0.0
    )
    reached = target_epoch - last_recovered if last_recovered is not None else None
    result.timings = [
        (
            "Recovery time (RTO): damaged primary stopped until the restored one accepts writes",
            rto if measured else None,
        ),
        (
            "Data lost (RPO of an in-place restore): from the target to the last acknowledged "
            "write that the restore discarded",
            loss_window if measured else None,
        ),
        (
            "Recovery reached the target: target minus the last write it kept",
            reached if measured else None,
        ),
    ]
    result.notes = [
        "The heartbeat client wrote one row every "
        f"{facts.get('HEARTBEAT_INTERVAL', '?')} s throughout; its log is the evidence for the "
        f"acknowledged-writes checks. A write counts as committed before {words.noun} when the "
        "statement that recorded the target could see it, and as started after it when the "
        "WAL position read inside its own transaction is past the position recorded at the "
        "target, so neither check compares the client's clock with the server's.",
        "",
    ]
    if facts.get("TARGET_TYPE") == "time":
        result.notes += [
            "Recovery to a time replays every transaction that committed at or before the "
            "target and stops at the first commit after it (`recovery_target_inclusive` is on "
            "by default). The DELETE commits after the recorded time, so a correct recovery "
            "stops before it: the row-count and checksum checks above test exactly that.",
            "",
        ]
    result.notes += [
        "Restoring in place goes back in time for the whole database: the writes the "
        "application made after the accident are lost with it. Restoring a copy to a side "
        "instance and moving the deleted rows back instead keeps them (docs/pitr.md).",
    ]
    return result


def analyse_switchover(
    conn: Connection, facts: dict[str, str], attempts: Sequence[Attempt], *, measured: bool
) -> DrillResult:
    run_id = fact(facts, "RUN_ID")
    old, new = fact(facts, "OLD_PRIMARY"), fact(facts, "NEW_PRIMARY")
    present = heartbeat_rows(conn, run_id)
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
        (RECONNECTION, reconnection(attempts, new) if measured else None),
    ]
    if gap and measured:
        result.notes.append(f"{gap.failed_between} write attempts failed during the longest gap.")
    return result


@dataclass(frozen=True)
class FailoverState:
    """What the nodes hold after the failover drill, read by the caller."""

    primary: str  # cluster_name of the node that accepts writes
    rows_on_primary: frozenset[int]  # this run's heartbeat seqs on the new primary
    rows_on_rejoined: frozenset[int]  # the same, read on the rejoined old primary
    rewind_role_is_superuser: bool


@dataclass(frozen=True)
class ClientWrites:
    """The heartbeat client's acknowledged writes in the failover drill, by node."""

    by_old: list[Attempt]  # acknowledged by the old primary before it crashed
    lost: list[int]  # of those, the ones the new primary does not have
    by_new: list[Attempt]  # acknowledged by the new primary after the promotion
    missing_on_new: list[int]  # of those, the ones the new primary does not have (none)


def client_writes(
    attempts: Sequence[Attempt], old: str, new: str, on_new: frozenset[int]
) -> ClientWrites:
    acked = _acked(attempts)
    by_old = [a for a in acked if a.node == old]
    by_new = [a for a in acked if a.node == new]
    return ClientWrites(
        by_old,
        [a.seq for a in by_old if a.seq not in on_new],
        by_new,
        [a.seq for a in by_new if a.seq not in on_new],
    )


def analyse_failover(
    facts: dict[str, str],
    state: FailoverState,
    attempts: Sequence[Attempt],
    *,
    measured: bool,
) -> DrillResult:
    old, new = fact(facts, "OLD_PRIMARY"), fact(facts, "NEW_PRIMARY")
    lost = int(fact(facts, "LOST_ROWS"))
    first = int(facts.get("LOST_FIRST_SEQ", "1"))
    new_seq = int(fact(facts, "NEW_SEQ"))
    lost_seqs = frozenset(range(first, first + lost))
    diverged = facts.get("REWIND_DIVERGED", "")
    summary = facts.get("REWIND_SUMMARY", "")
    role = facts.get("REWIND_ROLE", "?")
    on_new = len(lost_seqs & state.rows_on_primary)
    on_old = len(lost_seqs & state.rows_on_rejoined)
    writes = client_writes(attempts, old, new, state.rows_on_primary)
    nodes = node_sequence(attempts)
    gap = longest_gap(attempts)
    result = DrillResult("Unplanned failover drill: a crashed primary, divergence and pg_rewind")
    result.checks = [
        Check(
            f"{new} was promoted and accepts writes",
            state.primary == new,
            f"writes now go to {state.primary}",
        ),
        Check(
            "the client moved from the crashed primary to the new one without reconfiguration",
            nodes == [old, new],
            " -> ".join(nodes) or "no writes",
        ),
        Check(
            f"every write {new} acknowledged after the promotion is on {new}",
            bool(writes.by_new) and not writes.missing_on_new,
            f"{len(writes.by_new):,} acknowledged, {len(writes.missing_on_new)} missing",
        ),
        Check(
            f"the {lost} rows {old} accepted when it came back are not on {new}",
            lost > 0 and on_new == 0,
            f"{on_new} of {lost} found on {new}",
        ),
        Check(
            f"pg_rewind found the divergence and rewound {old}",
            bool(diverged) and "no rewind required" not in summary,
            f"{diverged}; {summary}" if diverged else summary or "no pg_rewind output",
        ),
        Check(
            "pg_rewind connected as a role that is not a superuser",
            role == "rewind" and not state.rewind_role_is_superuser,
            f"role {role}",
        ),
        Check(
            f"{old} streams from {new} again",
            facts.get("STANDBY_STATE") == "streaming",
            f"pg_stat_replication state: {facts.get('STANDBY_STATE', 'none')}",
        ),
        Check(
            f"{old} now has {new}'s write and none of its own lost rows",
            new_seq in state.rows_on_rejoined and on_old == 0,
            f"{new}'s write {'present' if new_seq in state.rows_on_rejoined else 'missing'}, "
            f"{on_old} of {lost} lost rows left",
        ),
    ]
    result.facts_table = [
        ("Old primary", old),
        ("New primary", new),
        ("Client connection", "libpq multi-host `host=pg1,pg2 target_session_attrs=read-write`"),
        (
            "Crash",
            f"`docker compose kill -s SIGKILL {old}`: every PostgreSQL process of {old} killed, "
            "no shutdown checkpoint",
        ),
        (
            "Promotion",
            f"`pg_promote()` on {new} as soon as the crash was done; no failure detector, "
            "so no detection delay",
        ),
        (
            "Acknowledged client writes",
            f"{len(writes.by_old):,} by {old} before the crash ({len(writes.lost)} of them "
            f"missing on {new}: asynchronous replication); {len(writes.by_new):,} by {new} "
            "after the promotion",
        ),
        (
            "Old primary back without fencing",
            f"{old} restarted: crash recovery, then a primary on its old timeline next to {new}",
        ),
        ("Lost transaction", f"{lost} rows written on {old} after it came back"),
        ("Write on the new primary", f"one row (seq {new_seq}) written on {new}"),
        ("pg_rewind", f"`pg_rewind --source-server='host={new} user={role}'` on {old}"),
        ("Rejoin", f"standby.signal, primary_conninfo and a slot on {new}; streaming again"),
    ]
    killed = epoch_of(fact(facts, "KILLED_AT"))
    promote_started = float(fact(facts, "PROMOTE_STARTED_EPOCH"))
    promoted = float(fact(facts, "PROMOTED_EPOCH"))
    result.timings = [
        (
            "Write downtime seen by the client: longest gap between acknowledged writes",
            gap.seconds if (gap and measured) else None,
        ),
        (
            "Old primary killed (Docker's record) until the promotion finished (server clock)",
            promoted - killed if measured else None,
        ),
        (
            "Of which the promotion itself: `pg_promote()` on the new primary (server clock)",
            promoted - promote_started if measured else None,
        ),
        (RECONNECTION, reconnection(attempts, new) if measured else None),
    ]
    if gap and measured:
        result.notes += [
            f"{gap.failed_between} write attempts failed during the longest gap. Docker, both "
            "servers and the client share the clock of Docker Desktop's virtual machine. The "
            "time from the kill to the start of the promotion is the script's own reaction "
            "time, two Docker commands; a real failover first has to notice the failure (a "
            "health check's timeout, or an operator), and that delay comes on top of the "
            "downtime measured here.",
            "",
        ]
    result.notes += [
        "Replication is asynchronous: the primary acknowledges a commit once its own WAL is "
        "flushed, so the writes it acknowledged but had not yet sent when it crashed are lost "
        "in the failover. The row above counts them for this run.",
        "",
        "The rows the old primary accepted after it came back are gone for good: pg_rewind "
        "replaces its diverged pages with the new primary's. In a real failover the same "
        "happens to every write that reaches the old primary once the standby is promoted, "
        "which is why the old primary must be fenced (kept down, or cut off from clients) "
        "before the promotion. The planned switchover drill stops it first and loses nothing.",
    ]
    return result


def report_name(drill: str, facts: dict[str, str]) -> str:
    """File name of a drill's report: one per PITR target type and one per switchover
    direction, so that ./lab ci keeps the evidence of every variant it runs."""
    if drill == "pitr":
        kind = facts.get("TARGET_TYPE", "name")
        return "pitr-drill.md" if kind == "time" else f"pitr-drill-{kind}.md"
    if drill == "switchover":
        return f"switchover-drill-{fact(facts, 'OLD_PRIMARY')}-to-{fact(facts, 'NEW_PRIMARY')}.md"
    return f"{drill}-drill.md"


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
    ]
    if result.timings:
        lines += [
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
        ]
    lines += [*result.notes, ""]
    return "\n".join(lines)
