"""Live logins over the network: SCRAM passwords, database access and session defaults."""

from __future__ import annotations

import psycopg
import pytest

from pglab.db import connect, role_password

ROLES = ("topflow_migrator", "topflow_app", "topflow_backoffice", "topflow_analyst")


@pytest.mark.integration
@pytest.mark.parametrize("role", ROLES)
def test_right_password_logs_in_with_scram(role: str) -> None:
    with connect(role) as conn:
        assert conn.execute("SELECT session_user").fetchone() == (role,)
        # The server asked for SCRAM: libpq reports the method it completed.
        assert conn.pgconn.used_password


@pytest.mark.integration
@pytest.mark.parametrize("role", ROLES)
def test_wrong_password_is_refused(role: str) -> None:
    with pytest.raises(psycopg.OperationalError, match="password authentication failed"):
        psycopg.connect(user=role, password=role_password(role) + "-wrong", connect_timeout=5)


@pytest.mark.integration
def test_client_can_insist_on_scram() -> None:
    # require_auth makes libpq refuse any method other than SCRAM-SHA-256.
    with psycopg.connect(
        user="topflow_app", password=role_password("topflow_app"), require_auth="scram-sha-256"
    ) as conn:
        assert conn.execute("SELECT 1").fetchone() == (1,)


@pytest.mark.integration
def test_application_roles_cannot_open_other_databases() -> None:
    with pytest.raises(psycopg.OperationalError, match="permission denied for database"):
        psycopg.connect(
            user="topflow_app", password=role_password("topflow_app"), dbname="postgres"
        )


@pytest.mark.integration
def test_migrator_sessions_act_as_the_owner() -> None:
    with connect("topflow_migrator") as conn:
        assert conn.execute("SELECT current_user").fetchone() == ("topflow_owner",)


@pytest.mark.integration
def test_analyst_sessions_are_read_only() -> None:
    with connect("topflow_analyst") as conn:
        assert conn.execute("SHOW default_transaction_read_only").fetchone() == ("on",)
        with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
            conn.execute("CREATE TEMP TABLE scratch (id int)")


@pytest.mark.integration
def test_api_sessions_have_timeouts() -> None:
    with connect("topflow_app") as conn:
        assert conn.execute("SHOW statement_timeout").fetchone() == ("30s",)
        assert conn.execute("SHOW idle_in_transaction_session_timeout").fetchone() == ("1min",)
