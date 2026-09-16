\x off
-- \gexec runs each generated CALL as its own statement
SELECT format('CALL convert_to_columnstore(%L)', c) FROM show_chunks('rides') c \gexec

SELECT pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_columnstore_stats('rides');

EXPLAIN (ANALYZE, BUFFERS)
SELECT rates.description, COUNT(vendor_id) AS num_trips
FROM rides JOIN rates ON rides.rate_code = rates.rate_code
WHERE pickup_datetime < '2016-01-08'
GROUP BY rates.description ORDER BY LOWER(rates.description);