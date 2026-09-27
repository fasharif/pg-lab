-- The TopFlow schema is in place, complete and recorded, and the generator numbers
-- documents as TopFlow does.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(25);

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

-- TopFlow pads the yearly counter with padStart(6, '0'), which never cuts a longer number.
SELECT is(lab.document_number('TF-SO', 2026, 123), 'TF-SO-2026-000123',
          'a document number is padded to six digits');
SELECT is(lab.document_number('TF-SO', 2025, 1000000), 'TF-SO-2025-1000000',
          'the millionth document of a year keeps its seventh digit');

SELECT * FROM finish();
ROLLBACK;
