-- Replication role for Site B standby
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'ReplicatorPoC2026!';
  END IF;
END
$$;

SELECT pg_create_physical_replication_slot('site_b_standby', true)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name = 'site_b_standby'
);
