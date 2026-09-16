\x off
-- Q1 rewritten: count on the columnstore first, join the lookup table afterwards.
-- The original (sql/03, sql/05) joins 2.3M rows to `rates` before aggregating.
EXPLAIN (ANALYZE, BUFFERS)
SELECT COALESCE(r.description, 'unknown') AS description, t.num_trips
FROM (
  SELECT rate_code, count(*) AS num_trips
  FROM rides
  WHERE pickup_datetime < '2016-01-08'
  GROUP BY rate_code
) t
LEFT JOIN rates r USING (rate_code)
ORDER BY lower(COALESCE(r.description, 'unknown'));
