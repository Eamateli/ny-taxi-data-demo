\x off
SELECT count(*) FILTER (WHERE is_compressed) AS compressed_chunks, count(*) AS chunks
FROM timescaledb_information.chunks WHERE hypertable_name = 'rides';
SELECT scheduled FROM timescaledb_information.jobs WHERE hypertable_name = 'rides';

ANALYZE rides;  -- fresh bulk load: give the planner statistics

-- Q1: the tutorial's "59 second" query
EXPLAIN (ANALYZE, BUFFERS)
SELECT rates.description, COUNT(vendor_id) AS num_trips
FROM rides JOIN rates ON rides.rate_code = rates.rate_code
WHERE pickup_datetime < '2016-01-08'
GROUP BY rates.description ORDER BY LOWER(rates.description);

-- Q2: Newark trips per hour over 3 days, no index yet
EXPLAIN (ANALYZE, BUFFERS)
SELECT time_bucket('1 hour', pickup_datetime) AS hour, count(*), avg(total_amount)
FROM rides
WHERE rate_code = 3 AND pickup_datetime >= '2016-01-02' AND pickup_datetime < '2016-01-05'
GROUP BY hour ORDER BY hour;