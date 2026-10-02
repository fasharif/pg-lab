"""The monitoring check, against canned Prometheus and Grafana API answers."""

from __future__ import annotations

from typing import Any

import pytest

from pglab.errors import CheckError
from pglab.monitoring import check_once, wait_until_healthy

PROMETHEUS = "http://prometheus:9090"
GRAFANA = "http://grafana:3000"


def api(*, pg2_health: str = "up", rules: int = 11, panels: int = 16) -> dict[str, Any]:
    return {
        f"{PROMETHEUS}/api/v1/targets": {
            "data": {
                "activeTargets": [
                    {"labels": {"node": "pg1"}, "health": "up"},
                    {"labels": {"node": "pg2"}, "health": pg2_health},
                    {"labels": {"job": "prometheus"}, "health": "up"},
                ]
            }
        },
        f"{PROMETHEUS}/api/v1/rules": {"data": {"groups": [{"rules": [{}] * rules}]}},
        f"{PROMETHEUS}/api/v1/query?query=pg_up": {
            "data": {
                "result": [
                    {"metric": {"node": "pg1"}, "value": [0, "1"]},
                    {"metric": {"node": "pg2"}, "value": [0, "1" if pg2_health == "up" else "0"]},
                ]
            }
        },
        f"{GRAFANA}/api/dashboards/uid/pglab-postgres": {"dashboard": {"panels": [{}] * panels}},
    }


def test_healthy_stack_has_no_problems() -> None:
    answers = api()
    assert check_once(PROMETHEUS, GRAFANA, ["pg1", "pg2"], 11, fetch=answers.__getitem__) == []


def test_each_problem_is_reported() -> None:
    answers = api(pg2_health="down", rules=9, panels=0)
    problems = check_once(PROMETHEUS, GRAFANA, ["pg1", "pg2"], 11, fetch=answers.__getitem__)
    assert len(problems) == 4
    assert any("pg2 is down" in p for p in problems)
    assert any("loaded 9 alert rules" in p for p in problems)


def test_waiting_gives_up_with_the_last_problems() -> None:
    answers = api(pg2_health="down")
    with pytest.raises(CheckError, match="exporter for pg2 is down"):
        wait_until_healthy(
            PROMETHEUS,
            GRAFANA,
            ["pg2"],
            11,
            timeout=0.01,
            fetch=answers.__getitem__,
            sleep=lambda _seconds: None,
        )
