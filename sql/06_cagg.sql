\x off
DROP VIEW IF EXISTS trips_by_rate;
DROP MATERIALIZED VIEW IF EXISTS rides_hourly;

CREATE MATERIALIZED VIEW rides_hourly WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', pickup_datetime) AS bucket, rate_code,
       count(*) AS trips, sum(total_amount) AS revenue
FROM rides GROUP BY bucket, rate_code
WITH NO DATA;

CALL refresh_continuous_aggregate('rides_hourly', NULL, NULL);

CREATE VIEW trips_by_rate AS
SELECT COALESCE(r.description, 'unknown') AS description, sum(h.trips) AS num_trips
FROM rides_hourly h LEFT JOIN rates r USING (rate_code)
WHERE h.bucket < '2016-01-08'
GROUP BY 1;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM trips_by_rate ORDER BY lower(description);
SELECT * FROM trips_by_rate ORDER BY lower(description);