# PostgreSQL 18 node for the lab: the official image plus pgBackRest (backups and WAL
# archiving) and pgTAP (database unit tests). Both packages come from the PGDG apt
# repository that the official image already trusts.
FROM postgres:18.6-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends pgbackrest postgresql-18-pgtap \
    && rm -rf /var/lib/apt/lists/* /etc/pgbackrest.conf \
    && install -d -o postgres -g postgres -m 0750 \
        /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest /etc/pgbackrest

COPY postgresql.conf pg_hba.conf /etc/postgresql/
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY initdb/ /docker-entrypoint-initdb.d/
COPY lab-entrypoint.sh /usr/local/bin/lab-entrypoint.sh
RUN chmod 0755 /usr/local/bin/lab-entrypoint.sh \
    && chmod 0644 /etc/postgresql/postgresql.conf /etc/postgresql/pg_hba.conf /etc/pgbackrest/pgbackrest.conf

ENTRYPOINT ["lab-entrypoint.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
