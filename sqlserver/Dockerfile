# SQL Server 2022 (Developer edition at run time) with Full-Text Search, which casebook
# case 4 needs and the base image does not include. Written, not built in this repository:
# building and running it means accepting Microsoft's licence (see docs/sqlserver.md).
FROM mcr.microsoft.com/mssql/server:2022-CU27-ubuntu-22.04

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022 jammy main" \
        > /etc/apt/sources.list.d/mssql-server-2022.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends mssql-server-fts \
    && rm -rf /var/lib/apt/lists/*
USER mssql
