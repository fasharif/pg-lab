"""Loading and validating the workload (workload/queries.toml) and the casebook (casebook/*.toml).

Definitions are data, not code: SQL with psycopg named placeholders such as %(org_id)s, and
parameters given as SQL expressions that are evaluated against the lab database, so a query
always targets rows that exist in the generated data set.
"""

from __future__ import annotations

import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pglab.errors import LabError
from pglab.explain import Expectation

ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
PLACEHOLDER = re.compile(r"%\((\w+)\)s")
API_SOURCE = re.compile(r"^(apps|packages)/[\w./-]+\.ts(:\d+)? .+$")


@dataclass(frozen=True)
class WorkloadQuery:
    id: str
    title: str
    api: str
    sql: str
    params: Mapping[str, str]
    note: str = ""


@dataclass(frozen=True)
class Total:
    """The pagination count a list endpoint runs with its page. TopFlow's list() methods run
    findMany and count with the same filter in one transaction, so a case that fixes the page
    also has to fix the count, with the same indexes and, where needed, its own rewrite."""

    query: WorkloadQuery
    rewrite: str
    before: Expectation
    after: Expectation

    @property
    def after_sql(self) -> str:
        return self.rewrite or self.query.sql


@dataclass(frozen=True)
class Case:
    number: int
    slug: str
    query: WorkloadQuery
    fix_kind: str
    problem: str
    fix: tuple[str, ...]
    revert: tuple[str, ...]
    rewrite: str
    fixed_by: int | None
    tradeoff: str
    before: Expectation
    after: Expectation
    path: Path
    total: Total | None = None

    @property
    def title(self) -> str:
        return self.query.title

    @property
    def after_sql(self) -> str:
        """The statement measured after the fix: the rewrite if there is one."""
        return self.rewrite or self.query.sql


def placeholders(sql: str) -> set[str]:
    """Named placeholders used by a statement; rejects stray '%' characters."""
    stripped = PLACEHOLDER.sub("", sql).replace("%%", "")
    if "%" in stripped:
        raise LabError("SQL contains a '%' that is not a %(name)s placeholder; write it as %%")
    return set(PLACEHOLDER.findall(sql))


def _text(data: Mapping[str, Any], key: str, where: str, *, required: bool = True) -> str:
    value = data.get(key, "")
    if not isinstance(value, str):
        raise LabError(f"{where}: '{key}' must be a string")
    value = value.strip()
    if required and not value:
        raise LabError(f"{where}: '{key}' is required")
    return value


def load_workload(path: Path) -> dict[str, WorkloadQuery]:
    """Read and validate the workload file; returns the queries keyed by id, in file order."""
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise LabError(f"cannot read {path}: {exc}") from exc
    entries = document.get("query")
    if not isinstance(entries, list) or not entries:
        raise LabError(f"{path}: expected at least one [[query]] table")
    queries: dict[str, WorkloadQuery] = {}
    for position, entry in enumerate(entries, start=1):
        where = f"{path.name} query #{position}"
        if not isinstance(entry, dict):
            raise LabError(f"{where}: not a table")
        query_id = _text(entry, "id", where)
        where = f"{path.name} query {query_id!r}"
        if not ID_PATTERN.match(query_id):
            raise LabError(f"{where}: id must be lower-case words separated by hyphens")
        if query_id in queries:
            raise LabError(f"{where}: duplicate id")
        api = _text(entry, "api", where)
        if not API_SOURCE.match(api):
            raise LabError(
                f"{where}: 'api' must look like 'apps/api/src/<file>.ts:<line> <function>'"
            )
        sql = _text(entry, "sql", where)
        params_raw = entry.get("params", {})
        if not isinstance(params_raw, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in params_raw.items()
        ):
            raise LabError(f"{where}: 'params' must map names to SQL expressions")
        used = placeholders(sql)
        if used != set(params_raw):
            raise LabError(
                f"{where}: placeholders {sorted(used)} do not match params {sorted(params_raw)}"
            )
        queries[query_id] = WorkloadQuery(
            id=query_id,
            title=_text(entry, "title", where),
            api=api,
            sql=sql,
            params=dict(params_raw),
            note=_text(entry, "note", where, required=False),
        )
    return queries


CASE_FILE = re.compile(r"^(\d{2})-([a-z0-9-]+)\.toml$")


def load_cases(directory: Path, workload: Mapping[str, WorkloadQuery]) -> list[Case]:
    """Read casebook/NN-slug.toml files, numbered 01, 02, ... without gaps."""
    files = sorted(p for p in directory.glob("*.toml"))
    cases: list[Case] = []
    for expected_number, path in enumerate(files, start=1):
        match = CASE_FILE.match(path.name)
        if not match:
            raise LabError(f"{path.name}: case files must be named NN-slug.toml")
        number = int(match.group(1))
        if number != expected_number:
            raise LabError(f"{path.name}: expected case number {expected_number:02d} (no gaps)")
        where = path.name
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise LabError(f"cannot read {path}: {exc}") from exc
        query_id = _text(data, "query", where)
        if query_id not in workload:
            raise LabError(f"{where}: query {query_id!r} is not in the workload")
        query = workload[query_id]
        fix = _statements(data, "fix", where)
        revert = _statements(data, "revert", where)
        rewrite = _text(data, "rewrite", where, required=False)
        fixed_by = data.get("fixed_by")
        if fixed_by is not None and (not isinstance(fixed_by, int) or isinstance(fixed_by, bool)):
            raise LabError(f"{where}: 'fixed_by' must be the number of another case")
        if bool(fix) != bool(revert):
            raise LabError(f"{where}: 'fix' and 'revert' go together (both or neither)")
        if fixed_by is not None and (fix or rewrite):
            raise LabError(f"{where}: a case with 'fixed_by' has no fix or rewrite of its own")
        if fixed_by is None and not fix and not rewrite:
            raise LabError(f"{where}: a case needs a 'fix', a 'rewrite', or 'fixed_by'")
        if rewrite and not placeholders(rewrite) <= set(query.params):
            raise LabError(f"{where}: the rewrite uses parameters the query does not define")
        before = Expectation.from_mapping(_table(data, "before", where), f"{where} [before]")
        after = Expectation.from_mapping(_table(data, "after", where), f"{where} [after]")
        if after.is_empty():
            raise LabError(f"{where}: [after] must state at least one plan check")
        total = _total(data, where, workload) if "total" in data else None
        cases.append(
            Case(
                number=number,
                slug=match.group(2),
                query=query,
                fix_kind=_text(data, "fix_kind", where),
                problem=_text(data, "problem", where),
                fix=fix,
                revert=revert,
                rewrite=rewrite,
                fixed_by=fixed_by,
                tradeoff=_text(data, "tradeoff", where),
                before=before,
                after=after,
                path=path,
                total=total,
            )
        )
    by_number = {case.number: case for case in cases}
    for case in cases:
        if case.fixed_by is None:
            continue
        target = by_number.get(case.fixed_by)
        if target is None or target.number == case.number or not target.fix:
            raise LabError(
                f"{case.path.name}: fixed_by = {case.fixed_by} must name another case with a fix"
            )
    queries_seen = [case.query.id for case in cases] + [
        case.total.query.id for case in cases if case.total is not None
    ]
    duplicates = {q for q in queries_seen if queries_seen.count(q) > 1}
    if duplicates:
        raise LabError(f"casebook: queries used by more than one case: {sorted(duplicates)}")
    return cases


def _total(data: Mapping[str, Any], where: str, workload: Mapping[str, WorkloadQuery]) -> Total:
    """The optional [total] table: the page's pagination count, checked in the same case."""
    table = _table(data, "total", where)
    where = f"{where} [total]"
    unknown = set(table) - {"query", "rewrite", "before", "after"}
    if unknown:
        raise LabError(f"{where}: unknown keys {sorted(unknown)}")
    query_id = _text(table, "query", where)
    if query_id not in workload:
        raise LabError(f"{where}: query {query_id!r} is not in the workload")
    query = workload[query_id]
    rewrite = _text(table, "rewrite", where, required=False)
    if rewrite and not placeholders(rewrite) <= set(query.params):
        raise LabError(f"{where}: the rewrite uses parameters the query does not define")
    before = Expectation.from_mapping(_table(table, "before", where), f"{where} [before]")
    after = Expectation.from_mapping(_table(table, "after", where), f"{where} [after]")
    if after.is_empty():
        raise LabError(f"{where}: [total.after] must state at least one plan check")
    return Total(query=query, rewrite=rewrite, before=before, after=after)


def _statements(data: Mapping[str, Any], key: str, where: str) -> tuple[str, ...]:
    """A list of SQL statements, each run on its own (so CREATE INDEX CONCURRENTLY works)."""
    value = data.get(key, [])
    if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
        raise LabError(f"{where}: '{key}' must be a list of SQL statements")
    return tuple(v.strip() for v in value)


def _table(data: Mapping[str, Any], key: str, where: str) -> Mapping[str, Any]:
    value = data.get(key, {})
    if not isinstance(value, dict):
        raise LabError(f"{where}: [{key}] must be a table")
    return value
