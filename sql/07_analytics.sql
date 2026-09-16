\x off
WITH hourly AS (
  SELECT bucket, sum(trips) AS trips
  FROM rides_hourly
  GROUP BY bucket
), scored AS (
  SELECT bucket, trips,
         round(avg(trips) OVER (ORDER BY bucket ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS avg_3h,
         trips - lag(trips) OVER (ORDER BY bucket) AS vs_prev_hour,
         rank() OVER (PARTITION BY bucket::date ORDER BY trips DESC) AS rank_in_day
  FROM hourly
)
SELECT bucket::date AS day, bucket::time AS busiest_hour, trips, avg_3h, vs_prev_hour
FROM scored
WHERE rank_in_day = 1
ORDER BY day;

CREATE OR REPLACE FUNCTION hypertable_health(p_table regclass)
RETURNS TABLE (check_name text, result text)
LANGUAGE plpgsql AS $$
DECLARE
  v_name text := (SELECT relname FROM pg_class WHERE oid = p_table);
  v_chunks int;
  v_columnstore int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables
                 WHERE hypertable_name = v_name) THEN
    RAISE EXCEPTION '% is not a hypertable', p_table;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE is_compressed)
  INTO v_chunks, v_columnstore
  FROM timescaledb_information.chunks WHERE hypertable_name = v_name;

  RETURN QUERY VALUES
    ('chunks', v_chunks::text),
    ('chunks in columnstore', v_columnstore::text),
    ('total size', pg_size_pretty(hypertable_size(p_table)));

  RETURN QUERY
    SELECT format('job %s (%s)', j.job_id, j.proc_name),
           CASE WHEN j.scheduled THEN 'active' ELSE 'PAUSED' END
    FROM timescaledb_information.jobs j WHERE j.hypertable_name = v_name;
END $$;

SELECT * FROM hypertable_health('rides');
SELECT * FROM hypertable_health('rates');   -- expected: a clear error