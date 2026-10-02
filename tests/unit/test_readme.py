"""The README's result tables, rebuilt from rendered reports."""

from __future__ import annotations

from pathlib import Path

import pytest

from pglab import casebook, readme
from pglab.casebook import CaseResult, Snapshot
from pglab.definitions import load_cases, load_workload
from pglab.drills import Check, DrillResult, render
from pglab.errors import LabError
from pglab.execute import Timing
from tests.conftest import load_plan
from tests.unit.test_reports import info


def _casebook_text(root: Path, *, measured: bool) -> str:
    cases = load_cases(root / "casebook", load_workload(root / "workload" / "queries.toml"))
    timing = Timing((100.0,), (0.5,)) if measured else None
    before = Snapshot("SELECT 1", load_plan("orders-admin-search.before"), "", (), timing)
    after = Snapshot("SELECT 1", load_plan("orders-admin-search.after"), "", (), timing)
    results = [CaseResult(case, {}, before, after) for case in cases[:2]]
    return casebook.render_report(results, info(measured), command="./lab casebook --measure")


def test_the_casebook_block_links_each_case_to_the_report(root: Path) -> None:
    report = readme.parse_report(_casebook_text(root, measured=True), "reports/casebook.md")
    block = readme.casebook_block(report)
    rows = [line for line in block.splitlines() if line.startswith("| 1 ")]
    assert len(rows) == 1
    cells = readme.split_row(rows[0])
    assert cells[1].endswith("](reports/casebook.md#case-01)")
    # Buffers without the size in parentheses; times as the report shows them.
    assert cells[3] == "11,640"
    assert cells[5:] == ["100 ms", "100 ms"]
    assert "written by `./lab casebook --measure` on 2026-09-26 00:00 UTC at SCALE=100000" in block
    assert "Times: median of 15 runs" in block


def test_a_functional_casebook_leaves_the_times_pending(root: Path) -> None:
    report = readme.parse_report(_casebook_text(root, measured=False), "reports/casebook.md")
    block = readme.casebook_block(report)
    assert "| pending a measured run | pending a measured run |" in block


def _drill(title: str, value: float | None) -> str:
    result = DrillResult(
        title,
        checks=[Check("first", True, "a | b"), Check("second", True)],
        facts_table=[("Step", "value")],
        timings=[("Write downtime", value)],
    )
    return render(result, info(value is not None), command="./lab switchover --measure")


def test_the_drill_block_lists_every_timing_with_its_checks() -> None:
    reports = [
        ("Switchover", readme.parse_report(_drill("A", 1.234), "reports/a.md")),
        ("Failover", readme.parse_report(_drill("B", None), "reports/b.md")),
    ]
    block = readme.drills_block(reports)
    assert "| [Switchover](reports/a.md) | Write downtime | 1.23 s | 2 of 2 |" in block
    assert (
        "| [Failover](reports/b.md) | Write downtime | pending a measured run | 2 of 2 |" in block
    )
    assert "(`./lab switchover --measure`)" in block


def test_escaped_pipes_survive_a_round_trip() -> None:
    report = readme.parse_report(_drill("A", 1.0), "reports/a.md")
    assert report.table_under("Checks")[1] == ["first", "pass", "a | b"]


def test_blocks_are_replaced_between_their_markers_only() -> None:
    text = "intro\n<!-- pglab:casebook -->\nold\n<!-- /pglab:casebook -->\noutro\n"
    assert readme.replace_blocks(text, {"casebook": "new\n"}) == (
        "intro\n<!-- pglab:casebook -->\nnew\n<!-- /pglab:casebook -->\noutro\n"
    )
    with pytest.raises(LabError, match="no markers for drills"):
        readme.replace_blocks(text, {"drills": "x"})


def test_the_readme_quotes_the_committed_reports(root: Path) -> None:
    """README.md must hold exactly what ./lab readme builds from reports/."""
    text = (root / "README.md").read_text(encoding="utf-8")
    blocks = readme.build_blocks(root / "reports")
    assert readme.replace_blocks(text, blocks) == text, "run ./lab readme"
