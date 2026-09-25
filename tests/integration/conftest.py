"""Integration tests need the running lab (./lab test runs them inside the runner container)."""

from __future__ import annotations

import os

import pytest


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    skip = pytest.mark.skip(reason="needs the lab database: run ./lab test")
    for item in items:
        if "integration" in item.keywords and not os.environ.get("LAB_APP_PASSWORD"):
            item.add_marker(skip)
