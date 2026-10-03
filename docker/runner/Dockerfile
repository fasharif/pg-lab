# Tools container for the lab: Python 3.14 with the locked pglab dependencies, the
# PostgreSQL 18 client tools (psql, pgbench) and pg_prove for the pgTAP suites.
# The repository is bind-mounted at /work, so code changes need no rebuild.
FROM postgres:18.6-trixie AS pgdg
FROM ghcr.io/astral-sh/uv:0.12.22 AS uv

FROM python:3.14.7-slim-trixie

# Reuse the PGDG signing key shipped in the official postgres image instead of fetching it.
COPY --from=pgdg /usr/local/share/keyrings/postgres.gpg.asc /usr/local/share/keyrings/postgres.gpg.asc
RUN echo "deb [ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt trixie-pgdg main 18" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-18 libtap-parser-sourcehandler-pgtap-perl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /usr/local/bin/uv
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/work/src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY pyproject.toml uv.lock README.md /opt/pglab/
RUN cd /opt/pglab && uv sync --locked --no-install-project

WORKDIR /work
