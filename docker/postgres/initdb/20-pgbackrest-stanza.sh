#!/usr/bin/env bash
# First start of a new cluster only: create the pgBackRest stanza so that archive_command
# succeeds from the first WAL switch onwards. The temporary server started by the official
# entrypoint is reachable on the Unix socket, which is all stanza-create needs.
set -Eeuo pipefail

pgbackrest --stanza=topflow --log-level-console=warn stanza-create
pgbackrest --stanza=topflow --log-level-console=warn check
