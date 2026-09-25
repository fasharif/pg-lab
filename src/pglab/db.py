"""Database connections for the lab roles.

Connection targets come from the standard libpq environment variables (PGHOST, PGPORT,
PGDATABASE, PGTARGETSESSIONATTRS...), which compose.yaml sets in the runner container so that
every connection reaches the current primary. Passwords come from the LAB_* variables.
"""

from __future__ import annotations

import os
from typing import Any

import psycopg

from pglab.errors import LabError

type Connection = psycopg.Connection[tuple[Any, ...]]

ROLE_PASSWORD_VARIABLES: dict[str, str] = {
    "postgres": "PGPASSWORD",
    "topflow_migrator": "LAB_MIGRATOR_PASSWORD",
    "topflow_app": "LAB_APP_PASSWORD",
    "topflow_analyst": "LAB_ANALYST_PASSWORD",
    "monitor": "LAB_MONITOR_PASSWORD",
}


def role_password(role: str) -> str:
    """Password of a lab role, read from the environment."""
    variable = ROLE_PASSWORD_VARIABLES.get(role)
    if variable is None:
        known = ", ".join(sorted(ROLE_PASSWORD_VARIABLES))
        raise LabError(f"unknown role {role!r}; expected one of: {known}")
    password = os.environ.get(variable)
    if not password:
        raise LabError(f"{variable} is not set; run the command through ./lab")
    return password


def connect(
    role: str = "topflow_migrator",
    *,
    host: str | None = None,
    autocommit: bool = True,
    application_name: str = "pglab",
    connect_timeout: int = 5,
) -> Connection:
    """Open a connection as one of the lab roles (default: the migrator, which owns the schema)."""
    options: dict[str, Any] = {
        "user": role,
        "password": role_password(role),
        "application_name": application_name,
        "connect_timeout": connect_timeout,
    }
    if host is not None:
        options["host"] = host
        options["port"] = 5432
        options["target_session_attrs"] = "any"
    try:
        return psycopg.connect(autocommit=autocommit, **options)
    except psycopg.OperationalError as exc:
        raise LabError(f"cannot connect as {role}: {exc}".strip()) from exc


def scalar(conn: Connection, sql: str, params: tuple[Any, ...] | None = None) -> Any:
    """First column of the first row (None when there is no row)."""
    row = conn.execute(sql, params).fetchone()
    return None if row is None else row[0]
