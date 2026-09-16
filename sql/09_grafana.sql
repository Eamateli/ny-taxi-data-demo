\x off
-- Database side of the Grafana dashboard. Safe to rerun.
--
-- Run from the repo root as tsdbadmin, passing the reader password twice:
--   source .env && psql \
--     -v pw="$GRAFANA_DB_PASSWORD" \
--     -v pw_verifier="$(python3 scripts/scram_verifier.py)" \
--     -f sql/09_grafana.sql > results/09_grafana.txt 2>&1
--
-- pw_verifier is a precomputed SCRAM-SHA-256 verifier (what psql's \password
-- sends), so the plaintext never reaches the server or its logs. pw itself is
-- only used locally, to reconnect as grafana_ro for the checks at the end.

\if :{?pw}
\else
  \echo 'ERROR: run with -v pw="$GRAFANA_DB_PASSWORD" (see header)'
  \quit 1
\endif
\if :{?pw_verifier}
\else
  \echo 'ERROR: run with -v pw_verifier="$(python3 scripts/scram_verifier.py)" (see header)'
  \quit 1
\endif

-- 1. PostGIS for the map query (locations computed at query time, no geometry columns)
CREATE EXTENSION IF NOT EXISTS postgis;
SELECT extname, extversion FROM pg_extension WHERE extname = 'postgis';

-- 2. Read-only login role. Grafana runs whatever a panel says, so the database
--    has to be the one that enforces read-only access.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
      CONNECTION LIMIT 10;
  END IF;
END $$;

ALTER ROLE grafana_ro PASSWORD :'pw_verifier';
ALTER ROLE grafana_ro SET default_transaction_read_only = on;
ALTER ROLE grafana_ro SET statement_timeout = '30s';

GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON rides, rates, payment_types, rides_hourly, trips_by_rate TO grafana_ro;

-- pg_roles, not pg_authid: tsdbadmin is not a superuser on Tiger Cloud. The
-- verifier itself is not visible here; the successful \c below proves it works.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolconnlimit
FROM pg_roles WHERE rolname = 'grafana_ro';
SELECT unnest(rolconfig) AS role_setting FROM pg_roles WHERE rolname = 'grafana_ro';
SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE grantee = 'grafana_ro' GROUP BY table_name ORDER BY table_name;

-- 3. Verify as grafana_ro. The role changes, so psql drops the cached password
--    and libpq falls back to PGPASSWORD, which we point at the reader password.
\setenv PGPASSWORD :pw
\c - grafana_ro
SELECT current_user, current_setting('default_transaction_read_only') AS read_only,
       current_setting('statement_timeout') AS statement_timeout;

-- 3a. Every dashboard query returns rows (time filter written out for 2016-01-01)
\echo '-- map: long trips near Times Square (sampled, LIMIT 1000)'
SELECT count(*) AS map_rows, min(value) AS min_distance, max(value) AS max_distance
FROM (
  SELECT pickup_datetime AS time, trip_distance::float8 AS value,
         pickup_latitude::float8 AS latitude, pickup_longitude::float8 AS longitude
  FROM rides
  WHERE pickup_datetime BETWEEN '2016-01-01T00:00:00Z' AND '2016-01-02T00:00:00Z'
    AND trip_distance > 5
    AND ST_DWithin(ST_SetSRID(ST_MakePoint(pickup_longitude, pickup_latitude), 4326)::geography,
                   ST_SetSRID(ST_MakePoint(-73.9851, 40.7589), 4326)::geography, 2000)
  ORDER BY random() LIMIT 1000
) map;

\echo '-- trips per hour from the continuous aggregate'
SELECT count(*) AS hourly_rows, sum(trips) AS trips
FROM (
  SELECT bucket AS time, sum(trips) AS trips
  FROM rides_hourly
  WHERE bucket BETWEEN '2016-01-01T00:00:00Z' AND '2016-01-02T00:00:00Z'
  GROUP BY 1 ORDER BY 1
) hourly;

\echo '-- trips by rate code, week 1'
SELECT * FROM trips_by_rate ORDER BY lower(description);

\echo '-- hypertable health (optional panel; only if this works as grafana_ro)'
SELECT * FROM hypertable_health('rides');

-- 3b. Writes are rejected. Each one should fail; the script keeps going.
\echo '-- expected: three errors'
CREATE TABLE grafana_ro_probe (i int);
INSERT INTO rates VALUES (7, 'probe');
DELETE FROM rates WHERE rate_code = 7;

-- 3c. default_transaction_read_only is a session default a client could flip
--     back; the privileges are the real boundary. Expected: another error.
\echo '-- expected: one more error even after SET transaction_read_only = off'
BEGIN;
SET transaction_read_only = off;
INSERT INTO rates VALUES (7, 'probe');
ROLLBACK;

SELECT has_schema_privilege('grafana_ro', 'public', 'CREATE') AS can_create_in_public,
       has_table_privilege('grafana_ro', 'rides', 'INSERT') AS can_insert_rides,
       has_table_privilege('grafana_ro', 'rides', 'SELECT') AS can_select_rides;
