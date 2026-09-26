-- pgbench script for ./lab load: TopFlow back-office traffic as topflow_backoffice.
-- Each transaction reads an organisation's order page, one user's audit count and the
-- dashboard's 30-day revenue, then updates one order and appends an audit entry, so the
-- monitoring dashboard shows throughput, cache use, WAL, replication and dead rows.
-- Bounds stay inside the smallest data set (SCALE=1000: 50 organisations, 1000 orders).
\set org random(1, 50)
\set ord random(1, 1000)
\set usr random(1, 1000)
BEGIN;
SELECT o.id, o."totalAmount" FROM orders AS o
WHERE o."organizationId" = lab.uid('org', :org)
ORDER BY o."createdAt" DESC LIMIT 20;
SELECT count(*) FROM audit_logs AS a WHERE a."userId" = lab.uid('user', :usr);
SELECT sum(o."totalAmount") FROM orders AS o
WHERE o."createdAt" >= lab.anchor() - interval '30 days' AND o.status <> 'CANCELLED';
UPDATE orders SET notes = 'pgbench ' || :ord, "updatedAt" = now() WHERE id = lab.uid('order', :ord);
INSERT INTO audit_logs (id, "userId", action, "entityType", "entityId", "createdAt")
VALUES (gen_random_uuid()::text, lab.uid('user', 1), 'orders.status_changed', 'Order',
        lab.uid('order', :ord), now());
END;
