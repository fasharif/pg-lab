-- The TopFlow schema is in place, complete and recorded.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(23);

SELECT has_table('public', t, format('table %s exists', t))
FROM unnest(ARRAY[
    'users', 'categories', 'products', 'carts', 'cart_items', 'orders', 'order_items',
    'audit_logs', 'organizations', 'organization_members', 'quote_requests',
    'quote_request_items', 'organization_invitations', 'addresses', 'quotations',
    'quotation_items', 'order_status_events', 'document_sequences'
]) AS t;

SELECT is(
    (SELECT count(*) FROM lab.schema_migrations),
    4::bigint,
    'the four TopFlow migrations are recorded'
);
SELECT has_extension('public', 'pg_trgm', 'pg_trgm is installed');
SELECT has_extension('public', 'pg_stat_statements', 'pg_stat_statements is installed');
SELECT is(current_setting('data_checksums'), 'on', 'data checksums are enabled');
SELECT is(current_setting('wal_level'), 'replica', 'WAL carries enough for replication and PITR');

SELECT * FROM finish();
ROLLBACK;
