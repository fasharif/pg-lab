"""The data set report, without a database."""

from __future__ import annotations

from pglab.dataset import Dataset, Skew, render, summary
from tests.unit.test_reports import info

DATA = Dataset(
    rows={"orders": 20_000, "order_items": 100_314, "audit_logs": 100_000},
    correlation=[("audit_logs", 1.0), ("orders", 0.99991), ("users", None)],
    skew=Skew(
        organisations=50,
        organisations_with_orders=48,
        trade_orders=12_000,
        retail_orders=8_000,
        largest=1_200,
        median=40.0,
    ),
)


def test_report_lists_counts_correlation_and_skew() -> None:
    text = render(DATA, info(), command="./lab seed --scale 100000")
    assert "| order_items | 100,314 |" in text
    assert "| **all 18 TopFlow tables** | **220,314** |" in text
    assert "| orders | 0.9999 |" in text
    assert "| users | n/a |" in text
    assert "| Trade orders of the largest organisation | 1,200 (10.0%) |" in text
    assert "pending a measured run" in text


def test_summary_for_the_terminal() -> None:
    assert summary(DATA) == [
        "220,314 rows in 3 tables",
        "largest organisation: 1,200 of 12,000 trade orders",
    ]
