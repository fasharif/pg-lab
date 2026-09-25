"""Parsing EXPLAIN (FORMAT JSON) output and checking plans against expectations.

The casebook's CI checks are about plan shape, never about timings: which indexes a plan
uses, which node types appear, which relations are read with a sequential scan and, for
partitioned tables, exactly which partitions are scanned.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, ClassVar

from pglab.errors import LabError

SCAN_NODES = frozenset(
    {
        "Seq Scan",
        "Index Scan",
        "Index Only Scan",
        "Bitmap Heap Scan",
        "Bitmap Index Scan",
        "Tid Scan",
        "Tid Range Scan",
        "Sample Scan",
    }
)


@dataclass(frozen=True)
class PlanNode:
    """One node of a plan tree with the attributes the lab looks at."""

    node_type: str
    relation: str | None
    index: str | None
    actual_rows: float | None
    actual_loops: float | None
    shared_hit: int
    shared_read: int
    temp_read: int
    temp_written: int
    subplans_removed: int
    children: tuple[PlanNode, ...]
    raw: Mapping[str, Any] = field(repr=False, compare=False)

    def walk(self) -> Iterator[PlanNode]:
        """This node and all its descendants, depth first."""
        yield self
        for child in self.children:
            yield from child.walk()


@dataclass(frozen=True)
class Plan:
    """A parsed EXPLAIN result."""

    root: PlanNode
    planning_ms: float | None
    execution_ms: float | None

    def nodes(self) -> Iterator[PlanNode]:
        return self.root.walk()

    def node_types(self) -> set[str]:
        return {node.node_type for node in self.nodes()}

    def indexes_used(self) -> set[str]:
        return {node.index for node in self.nodes() if node.index is not None}

    def seq_scanned(self) -> set[str]:
        return {
            node.relation
            for node in self.nodes()
            if node.node_type == "Seq Scan" and node.relation is not None
        }

    def relations_scanned(self) -> set[str]:
        """Tables (or partitions) read by any scan node."""
        return {
            node.relation
            for node in self.nodes()
            if node.node_type in SCAN_NODES and node.relation is not None
        }

    def subplans_removed(self) -> int:
        """Partitions removed by run-time pruning (Append/MergeAppend "Subplans Removed")."""
        return sum(node.subplans_removed for node in self.nodes())

    def shared_buffers(self) -> int:
        """Shared buffers hit or read by the whole statement (the root node's totals)."""
        return self.root.shared_hit + self.root.shared_read

    def temp_buffers(self) -> int:
        return self.root.temp_read + self.root.temp_written

    def rows(self) -> float | None:
        return self.root.actual_rows


def _int(raw: Mapping[str, Any], key: str) -> int:
    value = raw.get(key, 0)
    return int(value) if isinstance(value, (int, float)) else 0


def _float(raw: Mapping[str, Any], key: str) -> float | None:
    value = raw.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def _node(raw: Mapping[str, Any]) -> PlanNode:
    if "Node Type" not in raw:
        raise LabError("EXPLAIN output has a plan node without 'Node Type'")
    children_raw = raw.get("Plans", [])
    if not isinstance(children_raw, list):
        raise LabError("EXPLAIN output has a 'Plans' entry that is not a list")
    relation = raw.get("Relation Name")
    index = raw.get("Index Name")
    return PlanNode(
        node_type=str(raw["Node Type"]),
        relation=str(relation) if relation is not None else None,
        index=str(index) if index is not None else None,
        actual_rows=_float(raw, "Actual Rows"),
        actual_loops=_float(raw, "Actual Loops"),
        shared_hit=_int(raw, "Shared Hit Blocks"),
        shared_read=_int(raw, "Shared Read Blocks"),
        temp_read=_int(raw, "Temp Read Blocks"),
        temp_written=_int(raw, "Temp Written Blocks"),
        subplans_removed=_int(raw, "Subplans Removed"),
        children=tuple(_node(child) for child in children_raw),
        raw=raw,
    )


def parse_plan(document: Any) -> Plan:
    """Parse the value returned by EXPLAIN (FORMAT JSON): a one-element list."""
    if isinstance(document, list):
        if len(document) != 1:
            raise LabError(f"expected one EXPLAIN result, got {len(document)}")
        document = document[0]
    if not isinstance(document, Mapping) or "Plan" not in document:
        raise LabError("not an EXPLAIN (FORMAT JSON) document: no 'Plan' key")
    return Plan(
        root=_node(document["Plan"]),
        planning_ms=_float(document, "Planning Time"),
        execution_ms=_float(document, "Execution Time"),
    )


@dataclass(frozen=True)
class Expectation:
    """What a plan must (or must not) contain. Empty fields are not checked."""

    index_used: tuple[str, ...] = ()
    index_not_used: tuple[str, ...] = ()
    node_present: tuple[str, ...] = ()
    node_absent: tuple[str, ...] = ()
    seq_scan_on: tuple[str, ...] = ()
    no_seq_scan_on: tuple[str, ...] = ()
    relations_scanned: tuple[str, ...] | None = None

    KEYS: ClassVar[tuple[str, ...]] = (
        "index_used",
        "index_not_used",
        "node_present",
        "node_absent",
        "seq_scan_on",
        "no_seq_scan_on",
        "relations_scanned",
    )

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any], where: str) -> Expectation:
        unknown = set(data) - set(cls.KEYS)
        if unknown:
            raise LabError(f"{where}: unknown expectation keys {sorted(unknown)}")
        values: dict[str, Any] = {}
        for key in cls.KEYS:
            if key not in data:
                continue
            value = data[key]
            if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                raise LabError(f"{where}: '{key}' must be a list of strings")
            values[key] = tuple(value)
        return cls(**values)

    def is_empty(self) -> bool:
        return self == Expectation()

    def describe(self) -> list[str]:
        """Human-readable list of the checks, for reports."""
        parts: list[str] = []
        parts += [f"uses index `{name}`" for name in self.index_used]
        parts += [f"does not use index `{name}`" for name in self.index_not_used]
        parts += [f"has a {node} node" for node in self.node_present]
        parts += [f"has no {node} node" for node in self.node_absent]
        parts += [f"sequential scan on `{rel}`" for rel in self.seq_scan_on]
        parts += [f"no sequential scan on `{rel}`" for rel in self.no_seq_scan_on]
        if self.relations_scanned is not None:
            names = ", ".join(f"`{rel}`" for rel in self.relations_scanned)
            parts.append(f"scans exactly {names}")
        return parts


def check_plan(plan: Plan, expectation: Expectation) -> list[str]:
    """Return one message per failed check (an empty list means the plan matches)."""
    failures: list[str] = []
    used = plan.indexes_used()
    types = plan.node_types()
    seq = plan.seq_scanned()
    for name in expectation.index_used:
        if name not in used:
            failures.append(f"expected index {name} to be used; plan uses {sorted(used) or 'none'}")
    for name in expectation.index_not_used:
        if name in used:
            failures.append(f"index {name} should not be used")
    for node in expectation.node_present:
        if node not in types:
            failures.append(f"expected a {node} node; plan has {sorted(types)}")
    for node in expectation.node_absent:
        if node in types:
            failures.append(f"plan should not contain a {node} node")
    for rel in expectation.seq_scan_on:
        if rel not in seq:
            failures.append(
                f"expected a sequential scan on {rel}; seq scans: {sorted(seq) or 'none'}"
            )
    for rel in expectation.no_seq_scan_on:
        if rel in seq:
            failures.append(f"plan should not scan {rel} sequentially")
    if expectation.relations_scanned is not None:
        wanted = set(expectation.relations_scanned)
        actual = plan.relations_scanned()
        if actual != wanted:
            failures.append(
                f"expected scans of exactly {sorted(wanted)}; plan scans {sorted(actual)}"
            )
    return failures


def summarise(plan: Plan, limit: int = 3) -> str:
    """Short description of the most important access paths, for tables in reports."""
    seen: list[str] = []
    for node in plan.nodes():
        if node.node_type not in SCAN_NODES or node.node_type == "Bitmap Index Scan":
            continue
        target = node.relation or "?"
        label = f"{node.node_type} on {target}"
        if node.index is not None:
            label += f" using {node.index}"
        if label not in seen:
            seen.append(label)
    if not seen:
        seen = [plan.root.node_type]
    text = "; ".join(seen[:limit])
    if len(seen) > limit:
        text += f"; +{len(seen) - limit} more"
    return text


def buffers_to_bytes(blocks: int, block_size: int = 8192) -> int:
    return blocks * block_size


def format_blocks(blocks: int) -> str:
    """'12,345 (96 MB)' style: buffer count with the volume it represents."""
    size = float(buffers_to_bytes(blocks))
    units: Sequence[str] = ("B", "kB", "MB", "GB", "TB")
    unit = 0
    while size >= 1024 and unit < len(units) - 1:
        size /= 1024
        unit += 1
    volume = f"{size:.0f} {units[unit]}" if unit else f"{int(size)} B"
    return f"{blocks:,} ({volume})"
