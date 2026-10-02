-- TopFlow Hub: identity moves to Supabase Auth.
--
-- Supabase Auth now owns credentials, sessions, email confirmation, password recovery and MFA.
-- users.id is the Supabase user id (auth.users.id), so every existing foreign key keeps working.
-- Existing accounts are imported into Supabase Auth with the same id and password hash before
-- this migration reaches a database that holds them.

-- 1. Credentials and self-issued tokens are no longer stored by the platform.
ALTER TABLE "users"
  DROP COLUMN "passwordHash",
  DROP COLUMN "passwordChangedAt",
  ADD COLUMN "lastSessionId" TEXT;

DROP TABLE "refresh_tokens";
DROP TABLE "one_time_tokens";
DROP TYPE "TokenPurpose";

-- 2. Richer website quote requests: how the visitor prefers to be contacted.
CREATE TYPE "ContactChannel" AS ENUM ('PHONE', 'WHATSAPP', 'EMAIL');
ALTER TABLE "quote_requests" ADD COLUMN "preferredContact" "ContactChannel";

-- 3. Defence in depth for Supabase. Only the API's database role (the table owner) reads and
--    writes platform data. Row Level Security without policies, plus revoked privileges for the
--    Data API roles, guarantees the public REST/GraphQL endpoints can never expose these tables.
--    The role checks keep this migration valid on plain PostgreSQL (CI, local development).
DO $$
DECLARE
  target record;
BEGIN
  FOR target IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', target.tablename);
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated';
    EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated';
    EXECUTE 'REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated';
  END IF;
END
$$;
