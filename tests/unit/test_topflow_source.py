"""The TopFlow migrations are copied unchanged: their hashes match sql/topflow/SOURCE.md."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path


def test_migration_hashes_match_the_recorded_source(root: Path) -> None:
    folder = root / "sql" / "topflow"
    recorded = dict(
        re.findall(r"\| `([\w]+\.sql)` \| `([0-9a-f]{64})` \|", (folder / "SOURCE.md").read_text())
    )
    files = sorted(p.name for p in folder.glob("*.sql"))
    assert files == sorted(recorded), "every migration must be listed in SOURCE.md"
    for name, digest in recorded.items():
        actual = hashlib.sha256((folder / name).read_bytes()).hexdigest()
        assert actual == digest, f"{name} differs from the TopFlow original"


def test_generator_only_uses_fictional_contact_domains(root: Path) -> None:
    text = "".join(p.read_text(encoding="utf-8") for p in (root / "sql").rglob("*.sql"))
    domains = set(re.findall(r"@([a-z0-9.-]+\.[a-z]+)", text))
    reserved = {"example.com", "example.net", "topflow-lab.example"}
    assert domains <= reserved, f"unexpected e-mail domains: {domains - reserved}"
