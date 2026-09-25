-- SCRAM-SHA-256 everywhere: stored verifiers, server default and pg_hba.conf rules.
-- The live login checks (wrong password refused, right one accepted) are in
-- tests/integration/test_authentication.py.
BEGIN;
SET LOCAL search_path = public, tap;
SELECT plan(7);

SELECT is(current_setting('password_encryption'), 'scram-sha-256',
          'new passwords are stored as SCRAM-SHA-256 verifiers');
SELECT is(
    (SELECT count(*) FROM pg_authid
     WHERE rolcanlogin AND (rolpassword IS NULL OR rolpassword NOT LIKE 'SCRAM-SHA-256$%')),
    0::bigint,
    'every login role has a SCRAM-SHA-256 verifier (no MD5 hashes, no passwordless logins)'
);
SELECT is((SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL), 0::bigint,
          'pg_hba.conf has no invalid lines');
SELECT is(
    (SELECT count(*) FROM pg_hba_file_rules WHERE auth_method IN ('trust', 'password', 'md5')),
    0::bigint,
    'no trust, clear-text password or md5 rules'
);
SELECT is(
    (SELECT count(*) FROM pg_hba_file_rules
     WHERE type LIKE 'host%' AND auth_method NOT IN ('scram-sha-256', 'reject')),
    0::bigint,
    'every network rule either requires SCRAM or rejects'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_hba_file_rules
            WHERE type = 'host' AND 'replication' = ANY (database)
              AND 'replicator' = ANY (user_name) AND auth_method = 'scram-sha-256'),
    'replication connections authenticate with SCRAM'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_hba_file_rules
            WHERE type = 'host' AND 'postgres' = ANY (user_name) AND address = 'all'
              AND auth_method = 'reject'),
    'the superuser is rejected from outside the lab network'
);

SELECT * FROM finish();
ROLLBACK;
