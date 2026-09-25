-- Least privilege: role attributes, table and column privileges, ownership, DDL rights.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(31);

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
SELECT table_privs_are('public', 'orders', 'topflow_app', ARRAY['SELECT', 'INSERT', 'UPDATE'],
    'the API reads, creates and updates orders but never deletes them');
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
SELECT column_privs_are('public', 'organizations', 'creditLimit', 'topflow_app', ARRAY['SELECT', 'INSERT'],
    'customers cannot change their credit limit');
SELECT column_privs_are('public', 'organizations', 'name', 'topflow_app',
    ARRAY['SELECT', 'INSERT', 'UPDATE'], 'customers can rename their organisation');

-- DDL
SELECT is(has_schema_privilege('topflow_app', 'public', 'CREATE'), false,
    'the API cannot create objects');
SELECT is(has_schema_privilege('topflow_analyst', 'public', 'CREATE'), false,
    'the analyst cannot create objects');
SELECT is(has_schema_privilege('topflow_migrator', 'public', 'CREATE'), true,
    'the migrator can create objects (through topflow_owner)');

SELECT * FROM finish();
ROLLBACK;
