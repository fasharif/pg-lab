"""The Grafana dashboard and the alert rules only use metrics postgres_exporter really exposes."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest

METRIC = re.compile(r"\b(pg_[a-z0-9_]+)\b")
FUNCTIONS = {"pg_wal"}  # words that look like metric names inside PromQL comments, never used


def exporter_metrics(root: Path) -> set[str]:
    text = (root / "tests" / "fixtures" / "exporter-metric-names.txt").read_text(encoding="utf-8")
    return {line.strip() for line in text.splitlines() if line and not line.startswith("#")}


def rule_expressions(text: str) -> list[str]:
    """The PromQL of every `expr:` in a rules file, including folded multi-line ones."""
    expressions: list[str] = []
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        match = re.match(r"^(\s*)expr:\s*(.*)$", lines[index])
        if not match:
            index += 1
            continue
        indent = len(match.group(1))
        parts = [match.group(2).lstrip(">-| ")]
        index += 1
        while index < len(lines) and (
            not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > indent
        ):
            parts.append(lines[index].strip())
            index += 1
        expressions.append(" ".join(parts))
    return expressions


def dashboard(root: Path) -> dict[str, Any]:
    path = root / "monitoring" / "grafana" / "dashboards" / "postgres-overview.json"
    document: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return document


def test_rule_expressions_are_found(root: Path) -> None:
    text = (root / "monitoring" / "prometheus" / "rules" / "postgres.yml").read_text()
    expressions = rule_expressions(text)
    assert len(expressions) == text.count("- alert:")
    assert all("pg_" in expression for expression in expressions)


def test_alert_rules_use_exported_metrics(root: Path) -> None:
    known = exporter_metrics(root)
    text = (root / "monitoring" / "prometheus" / "rules" / "postgres.yml").read_text()
    used = {m for e in rule_expressions(text) for m in METRIC.findall(e)} - FUNCTIONS
    assert used, "no metrics found in the rules"
    assert used <= known, f"unknown metrics in alert rules: {sorted(used - known)}"


def test_rule_tests_feed_exported_metrics(root: Path) -> None:
    known = exporter_metrics(root)
    text = (root / "monitoring" / "prometheus" / "tests" / "postgres_test.yml").read_text()
    used = set(re.findall(r"series: '(pg_[a-z0-9_]+)", text))
    assert used <= known, f"rule tests use metrics the exporter does not expose: {used - known}"


def test_dashboard_uses_exported_metrics(root: Path) -> None:
    known = exporter_metrics(root)
    used = {
        metric
        for panel in dashboard(root)["panels"]
        for target in panel["targets"]
        for metric in METRIC.findall(target["expr"])
    }
    assert used <= known, f"unknown metrics in the dashboard: {sorted(used - known)}"


def test_dashboard_covers_the_required_topics(root: Path) -> None:
    titles = " ".join(panel["title"].lower() for panel in dashboard(root)["panels"])
    for topic in (
        "connections",
        "transactions per second",
        "cache hit ratio",
        "replication lag",
        "transaction",
        "bloat",
        "locks",
    ):
        assert topic in titles, f"no panel about {topic}"


@pytest.mark.parametrize("key", ["uid", "title", "panels"])
def test_dashboard_has_identity(root: Path, key: str) -> None:
    assert dashboard(root)[key]


def test_dashboard_layout_is_valid(root: Path) -> None:
    panels = dashboard(root)["panels"]
    ids = [panel["id"] for panel in panels]
    assert len(ids) == len(set(ids)), "panel ids must be unique"
    for panel in panels:
        grid = panel["gridPos"]
        assert grid["x"] + grid["w"] <= 24, f"{panel['title']} is wider than the grid"
        assert panel["datasource"]["uid"] == "prometheus"
        assert all(target["datasource"]["uid"] == "prometheus" for target in panel["targets"])
