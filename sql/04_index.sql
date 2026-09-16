\x off
CREATE INDEX rides_rate_code_time_idx ON rides (rate_code, pickup_datetime DESC);

EXPLAIN (ANALYZE, BUFFERS)
SELECT time_bucket('1 hour', pickup_datetime) AS hour, count(*), avg(total_amount)
FROM rides
WHERE rate_code = 3 AND pickup_datetime >= '2016-01-02' AND pickup_datetime < '2016-01-05'
GROUP BY hour ORDER BY hour;

SELECT pg_size_pretty(hypertable_size('rides')) AS rowstore_size_with_index;