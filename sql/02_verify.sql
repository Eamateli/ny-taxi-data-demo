SELECT count(*) AS total_rows FROM rides;

SELECT rate_code, COUNT(vendor_id) AS num_trips
FROM rides
WHERE pickup_datetime < '2016-01-08'
GROUP BY rate_code ORDER BY rate_code;

SELECT count(*) AS chunks FROM show_chunks('rides');
SELECT pg_size_pretty(hypertable_size('rides')) AS total_size;
SELECT job_id, proc_name, scheduled
FROM timescaledb_information.jobs WHERE hypertable_name = 'rides';
