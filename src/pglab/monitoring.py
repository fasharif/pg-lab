"""Checks that the monitoring stack works: targets scraped, rules loaded, dashboard present."""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any

from pglab.errors import CheckError

type Fetch = Callable[[str], Any]


def fetch_json(url: str) -> Any:
    with urllib.request.urlopen(url, timeout=5) as response:
        return json.load(response)


def expected_rule_count(rules_file: Path) -> int:
    return len(re.findall(r"^\s*- alert:", rules_file.read_text(encoding="utf-8"), re.MULTILINE))


def check_once(
    prometheus: str, grafana: str, nodes: list[str], rules: int, *, fetch: Fetch = fetch_json
) -> list[str]:
    problems: list[str] = []
    targets = fetch(f"{prometheus}/api/v1/targets")["data"]["activeTargets"]
    health = {t["labels"].get("node"): t["health"] for t in targets if t["labels"].get("node")}
    for node in nodes:
        if health.get(node) != "up":
            problems.append(f"exporter for {node} is {health.get(node, 'not a target')}")
    groups = fetch(f"{prometheus}/api/v1/rules")["data"]["groups"]
    loaded = sum(len(group["rules"]) for group in groups)
    if loaded != rules:
        problems.append(f"Prometheus loaded {loaded} alert rules, the rules file has {rules}")
    up = fetch(f"{prometheus}/api/v1/query?query=pg_up")["data"]["result"]
    down = [r["metric"].get("node") for r in up if r["value"][1] != "1"]
    if down:
        problems.append(f"pg_up is 0 for {down}")
    dashboard = fetch(f"{grafana}/api/dashboards/uid/pglab-postgres")
    if not dashboard.get("dashboard", {}).get("panels"):
        problems.append("Grafana has no pglab-postgres dashboard")
    return problems


def wait_until_healthy(
    prometheus: str,
    grafana: str,
    nodes: list[str],
    rules: int,
    *,
    timeout: float = 180.0,
    fetch: Fetch = fetch_json,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    """Retry until every check passes (scrapes happen every 5 s) or the timeout expires."""
    deadline = time.monotonic() + timeout
    problems: list[str] = ["not checked yet"]
    while time.monotonic() < deadline:
        try:
            problems = check_once(prometheus, grafana, nodes, rules, fetch=fetch)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as exc:
            problems = [f"monitoring not reachable yet: {exc}"]
        if not problems:
            return
        sleep(5)
    raise CheckError("monitoring check failed: " + "; ".join(problems))
