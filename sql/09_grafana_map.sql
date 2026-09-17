\x off
-- The Geomap panel query, measured in psql with the default dashboard range
-- (2016-01-01 00:00 to 2016-01-02 00:00) written out the way Grafana expands
-- $__timeFilter(pickup_datetime). Run as the dashboard's own role:
--   source .env && PGUSER=grafana_ro PGPASSWORD="$GRAFANA_DB_PASSWORD" \
--     psql -f sql/09_grafana_map.sql > results/09_grafana_map.txt 2>&1
SELECT current_user;

-- A. As described in the task: PostGIS does all the filtering.
EXPLAIN (ANALYZE, BUFFERS)
SELECT pickup_datetime AS time, trip_distance::float8 AS value,
       pickup_latitude::float8 AS latitude, pickup_longitude::float8 AS longitude
FROM rides
WHERE pickup_datetime BETWEEN '2016-01-01T00:00:00Z' AND '2016-01-02T00:00:00Z'
  AND trip_distance > 5
  AND ST_DWithin(ST_SetSRID(ST_MakePoint(pickup_longitude, pickup_latitude), 4326)::geography,
                 ST_SetSRID(ST_MakePoint(-73.9851, 40.7589), 4326)::geography, 2000)
ORDER BY random() LIMIT 1000;

-- B. What the dashboard runs: a cheap lat/long box (a superset of the 2 km
--    circle) ahead of the geography test, so ST_DWithin only sees Midtown rows.
EXPLAIN (ANALYZE, BUFFERS)
SELECT pickup_datetime AS time, trip_distance::float8 AS value,
       pickup_latitude::float8 AS latitude, pickup_longitude::float8 AS longitude
FROM rides
WHERE pickup_datetime BETWEEN '2016-01-01T00:00:00Z' AND '2016-01-02T00:00:00Z'
  AND trip_distance > 5
  AND pickup_latitude  BETWEEN  40.740 AND  40.778
  AND pickup_longitude BETWEEN -74.010 AND -73.960
  AND ST_DWithin(ST_SetSRID(ST_MakePoint(pickup_longitude, pickup_latitude), 4326)::geography,
                 ST_SetSRID(ST_MakePoint(-73.9851, 40.7589), 4326)::geography, 2000)
ORDER BY random() LIMIT 1000;
