CREATE TABLE rides (
  vendor_id TEXT,
  pickup_datetime  TIMESTAMP NOT NULL,
  dropoff_datetime TIMESTAMP NOT NULL,
  passenger_count NUMERIC, trip_distance NUMERIC,
  pickup_longitude NUMERIC, pickup_latitude NUMERIC,
  rate_code INTEGER,
  dropoff_longitude NUMERIC, dropoff_latitude NUMERIC,
  payment_type INTEGER,
  fare_amount NUMERIC, extra NUMERIC, mta_tax NUMERIC, tip_amount NUMERIC,
  tolls_amount NUMERIC, improvement_surcharge NUMERIC, total_amount NUMERIC
) WITH (
  tsdb.hypertable,
  tsdb.create_default_indexes = false,
  tsdb.segmentby = 'vendor_id',
  tsdb.orderby = 'pickup_datetime DESC'
);


-- Hash partitioning from the tutorial (must run while the table is empty)
SELECT add_dimension('rides', by_hash('payment_type', 2));

-- Pause auto-compression so the "before" measurements are honest
SELECT alter_job(job_id, scheduled => false)
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_compression' AND hypertable_name = 'rides';

CREATE TABLE payment_types (payment_type INTEGER PRIMARY KEY, description TEXT);
INSERT INTO payment_types VALUES (1,'credit card'),(2,'cash'),(3,'no charge'),
  (4,'dispute'),(5,'unknown'),(6,'voided trip');

CREATE TABLE rates (rate_code INTEGER PRIMARY KEY, description TEXT);
INSERT INTO rates VALUES (1,'standard rate'),(2,'JFK'),(3,'Newark'),
  (4,'Nassau or Westchester'),(5,'negotiated fare'),(6,'group ride');