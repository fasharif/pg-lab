"""Shared test helpers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from pglab.explain import Plan, parse_plan

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"


def load_plan(name: str) -> Plan:
    document: Any = json.loads((FIXTURES / "plans" / f"{name}.json").read_text(encoding="utf-8"))
    return parse_plan(document)


@pytest.fixture
def root() -> Path:
    return ROOT
