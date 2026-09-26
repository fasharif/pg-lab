-- Least privilege: role attributes, table and column privileges, ownership, DDL rights.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(43);

-- Role attributes
SELECT isnt_superuser(r, format('%s is not a superuser', r))
FROM unnest(ARRAY['topflow_migrator', 'topflow_app', 'topflow_backoffice', 'topflow_analyst',
                  'replicator', 'monitor', 'rewind']) AS r;
SELECT is(
    (SELECT count(*) FROM pg_roles WHERE rolbypassrls AND NOT rolsuper),
    0::bigint,
    'no role other than the superuser bypasses row-level security'
);
SELECT is(
    (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'topflow_owner'),
    false,
    'nobody logs in as the owner role'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_db_role_setting AS s JOIN pg_roles AS r ON r.oid = s.setrole
            WHERE r.rolname = 'topflow_migrator' AND 'role=topflow_owner' = ANY (s.setconfig)),
    'migrator sessions run as topflow_owner, so migrations create owner-owned objects'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_db_role_setting AS s JOIN pg_roles AS r ON r.oid = s.setrole
            WHERE r.rolname = 'topflow_analyst'
              AND 'default_transaction_read_only=on' = ANY (s.setconfig)),
    'analyst sessions are read-only by default'
);

-- Ownership and RLS coverage
SELECT is(
    (SELECT count(*) FROM pg_class AS c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
       AND c.relowner <> 'topflow_owner'::regrole),
    0::bigint,
    'topflow_owner owns every TopFlow table'
);
SELECT is(
    (SELECT count(*) FROM pg_class AS c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND NOT c.relrowsecurity),
    0::bigint,
    'row-level security is enabled on every TopFlow table'
);
SELECT is(
    (SELECT count(*) FROM pg_class AS c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
       AND c.relname NOT IN ('carts', 'cart_items')
       AND NOT EXISTS (SELECT 1 FROM pg_policies AS p
                       WHERE p.schemaname = 'public' AND p.tablename = c.relname
                         AND 'topflow_app' = ANY (p.roles))
       AND has_table_privilege('topflow_app', c.oid, 'SELECT')),
    0::bigint,
    'every table the API can read has a policy for it'
);

-- Table privileges
SELECT table_privs_are('public', 'orders', 'topflow_app', ARRAY['SELECT', 'INSERT'],
    'the API reads and creates orders, never deletes them, and updates named columns only');
SELECT table_privs_are('public', 'quotations', 'topflow_app', ARRAY['SELECT'],
    'the API updates named columns of quotations only');
SELECT table_privs_are('public', 'organization_members', 'topflow_app', ARRAY['SELECT', 'DELETE'],
    'the API cannot add members: joining an organisation is a staff flow');
SELECT table_privs_are('public', 'organizations', 'topflow_app', ARRAY['SELECT'],
    'the API cannot register organisations: a staff flow');
SELECT table_privs_are('public', 'document_sequences', 'topflow_app', ARRAY[]::text[],
    'the API has no privilege on the shared document counters');
SELECT table_privs_are('public', 'audit_logs', 'topflow_app', ARRAY['SELECT', 'INSERT'],
    'audit entries are append-only for the API');
SELECT table_privs_are('public', 'audit_logs', 'topflow_backoffice', ARRAY['SELECT', 'INSERT'],
    'audit entries are append-only for staff too');
SELECT table_privs_are('public', 'order_status_events', 'topflow_backoffice', ARRAY['SELECT', 'INSERT'],
    'order history is append-only for staff');
SELECT table_privs_are('public', 'quotation_items', 'topflow_app', ARRAY['SELECT'],
    'customers never write quotation lines');
SELECT table_privs_are('public', 'products', 'topflow_app', ARRAY['SELECT'],
    'customers cannot change the catalogue');
SELECT table_privs_are('public', 'carts', 'topflow_app', ARRAY[]::text[],
    'tables the API does not use are not granted');
SELECT table_privs_are('public', 'users', 'topflow_analyst', ARRAY[]::text[],
    'the analyst has no table-wide privilege on users, only column privileges');

-- Column privileges
SELECT column_privs_are('public', 'users', 'email', 'topflow_analyst', ARRAY[]::text[],
    'the analyst cannot read e-mail addresses');
SELECT column_privs_are('public', 'users', 'role', 'topflow_analyst', ARRAY['SELECT'],
    'the analyst can read user roles');
SELECT column_privs_are('public', 'orders', 'shippingAddress', 'topflow_analyst', ARRAY[]::text[],
    'the analyst cannot read delivery addresses');
SELECT column_privs_are('public', 'users', 'role', 'topflow_app', ARRAY['SELECT', 'INSERT'],
    'customers cannot change their own role');
SELECT column_privs_are('public', 'organizations', 'creditLimit', 'topflow_app', ARRAY['SELECT'],
    'customers cannot change their credit limit');
SELECT column_privs_are('public', 'organizations', 'name', 'topflow_app',
    ARRAY['SELECT', 'UPDATE'], 'customers can rename their organisation');
SELECT column_privs_are('public', 'orders', 'status', 'topflow_app',
    ARRAY['SELECT', 'INSERT', 'UPDATE'], 'customers can change an order''s status (to cancel it)');
SELECT column_privs_are('public', 'orders', 'paymentStatus', 'topflow_app',
    ARRAY['SELECT', 'INSERT'], 'customers cannot change an order''s payment status');
SELECT column_privs_are('public', 'orders', 'totalAmount', 'topflow_app',
    ARRAY['SELECT', 'INSERT'], 'customers cannot change an order''s amount');
SELECT column_privs_are('public', 'quotations', 'total', 'topflow_app', ARRAY['SELECT'],
    'customers cannot change a quotation''s prices');
SELECT column_privs_are('public', 'quotations', 'validUntil', 'topflow_app', ARRAY['SELECT'],
    'customers cannot change a quotation''s validity');
SELECT column_privs_are('public', 'organization_members', 'role', 'topflow_app',
    ARRAY['SELECT', 'UPDATE'], 'member roles change through UPDATE only (owners, by policy)');
SELECT function_privs_are('app', 'next_document_number', ARRAY['text'], 'topflow_app',
    ARRAY['EXECUTE'], 'the API takes document numbers through app.next_document_number()');
SELECT is_definer('app', 'next_document_number', ARRAY['text'],
    'app.next_document_number() runs as the owner');

-- DDL
SELECT is(has_schema_privilege('topflow_app', 'public', 'CREATE'), false,
    'the API cannot create objects');
SELECT is(has_schema_privilege('topflow_analyst', 'public', 'CREATE'), false,
    'the analyst cannot create objects');
SELECT is(has_schema_privilege('topflow_migrator', 'public', 'CREATE'), true,
    'the migrator can create objects (through topflow_owner)');

SELECT * FROM finish();
ROLLBACK;
