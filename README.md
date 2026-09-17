# NYC Taxi on Tiger Cloud

A small, reproducible support-engineering lab built on Tiger Data's
[Analyze transport data](https://www.tigerdata.com/docs/build/examples/analyze-transport-data)
tutorial. It loads one week of NYC yellow-taxi trips into a Tiger Cloud
service, measures every step with `EXPLAIN (ANALYZE, BUFFERS)`, fixes what the
tutorial gets wrong, and ends with a Grafana dashboard provisioned entirely
from this repository.

Every number below comes from a saved plan in [`results/`](results/). Nothing is
quoted from memory.

## Results at a glance

| Question | Where it started | Where it ended | Script |
|---|---|---|---|
| Q1: trips per rate code, week 1 (join + count) | 2,637.5 ms on the rowstore | **92.6 ms** after rewriting the query to aggregate on the columnstore first (`VectorAgg`) | `sql/03`, `sql/05`, `sql/08` |
| Same answer from a continuous aggregate | 2,637.5 ms | **0.6 ms** from `trips_by_rate` | `sql/06` |
| Q2: Newark trips per hour over 3 days | 441.9 ms, sequential scan | **5.0 ms** with an index on `(rate_code, pickup_datetime DESC)` | `sql/04` |
| Storage for 2,333,578 rows | 417 MB rowstore + index | **147 MB** in the columnstore (65 % smaller) | `sql/05` |
| Map query: long trips near Times Square, one day | 266.6 ms | **135.2 ms** with a lat/long box ahead of `ST_DWithin` | `sql/09_grafana_map` |

The one that matters for a support engineer is the first row: converting to the
columnstore alone only took Q1 from 2,637.5 ms to 2,282.7 ms. The 25× win came
from understanding *why* the plan didn't vectorise and changing the query, not
the storage.

## Setup

| | |
|---|---|
| Service | Tiger Cloud `taxi-support-demo`, Development environment, 0.5 CPU, eu-central-1 |
| Versions | PostgreSQL 18.6, TimescaleDB 2.30.0, PostGIS 3.6.4 |
| Data | `nyc_data_rides.csv` from the tutorial, filtered to 2016-01-01 … 2016-01-07 (`data/rides_week1.csv`, 2,333,578 rows) |
| Schema | The tutorial's `rides` hypertable (`tsdb.hypertable`, `segmentby = 'vendor_id'`, `orderby = 'pickup_datetime DESC'`, `add_dimension(by_hash('payment_type', 2))`), plus the `rates` and `payment_types` lookup tables |
| Timestamps | `TIMESTAMP WITHOUT TIME ZONE`, NYC local time as shipped in the CSV |

Connection settings live in a git-ignored `.env` as `export KEY=value` lines
(`PGHOST`, `PGPORT`, `PGUSER=tsdbadmin`, `PGPASSWORD`, `PGDATABASE=tsdb`,
`PGSSLMODE=require`, and later `GRAFANA_DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`).
After `source .env`, `psql` connects with no arguments. `~/.psqlrc` turns
`\timing` on, which is where the `Time:` lines in `results/` come from; the
numbers quoted here are always the server-side `Execution Time` from the plan.

`sql/01_schema.sql` does two things the tutorial doesn't mention: it pauses the
columnstore policy that `tsdb.hypertable` creates automatically (job 1001,
`compress_after = 7 days`), so the "before" measurements really are on the
rowstore, and it runs `add_dimension` before `\COPY`, because it only works on
an empty table.

## Performance lab

Each script is one step; each was run once and its output saved next to it.

| Step | Script | What changed | Execution Time | Size |
|---|---|---|---|---|
| Baseline, rowstore | `sql/03_rowstore.sql` | `ANALYZE`, then Q1 and Q2 as written in the tutorial | Q1 **2,637.5 ms**, Q2 **441.9 ms** | 372 MB |
| Index | `sql/04_index.sql` | `CREATE INDEX ON rides (rate_code, pickup_datetime DESC)` | Q2 **5.0 ms** | 417 MB |
| Columnstore | `sql/05_columnstore.sql` | `convert_to_columnstore` on all 4 chunks, policy re-enabled | Q1 **2,282.7 ms** | **147 MB** |
| Continuous aggregate | `sql/06_cagg.sql` | `rides_hourly` (1-hour buckets by `rate_code`), view `trips_by_rate` | Q1 via view **0.6 ms** | |
| Query rewrite | `sql/08_rewrite.sql` | Q1 rewritten: `GROUP BY rate_code` on `rides` first, join `rates` after | Q1 **92.6 ms** | |
| Map query | `sql/09_grafana_map.sql` | Geomap query as `grafana_ro`, with and without a bounding-box pre-filter | **266.6 ms → 135.2 ms** | |

### Finding 1: the index does exactly what you'd expect

Q2 filters on `rate_code = 3` and a 3-day window. Without an index it's a
parallel sequential scan of the two chunks covering those days
(`Rows Removed by Filter: 593,214` and `780,226`); with
`(rate_code, pickup_datetime DESC)` it becomes two `Index Scan Backward`s
reading 2,029 rows, 441.9 → 5.0 ms (88×). Cost: 45 MB of index on 372 MB of
data. [`results/04_index.txt`](results/04_index.txt)

### Finding 2: the columnstore alone doesn't fix Q1 — the query shape does

Converting the four chunks cut the table from 417 MB to 147 MB, but Q1 went
from 2,637.5 ms to only 2,282.7 ms. The plan in
[`results/05_columnstore.txt`](results/05_columnstore.txt) shows why: the
`Hash Join` to `rates` sits *below* the aggregate, so all 2.3 M rows are
decompressed into ordinary tuples, pushed through the join, and hashed on a
`text` key (`rates.description`). The `ColumnarScan` nodes are vectorised, the
aggregate isn't.

`sql/08_rewrite.sql` keeps the result identical and moves the join above the
aggregate:

```sql
SELECT COALESCE(r.description, 'unknown') AS description, t.num_trips
FROM (
  SELECT rate_code, count(*) AS num_trips
  FROM rides
  WHERE pickup_datetime < '2016-01-08'
  GROUP BY rate_code
) t
LEFT JOIN rates r USING (rate_code)
ORDER BY lower(COALESCE(r.description, 'unknown'));
```

Now `GROUP BY rate_code` sits directly on each `ColumnarScan`, TimescaleDB
replaces it with `Custom Scan (VectorAgg)` — one per chunk — and counts on the
compressed batches without materialising rows. Seven rows per chunk leave the
aggregate, and the join handles 7 rows instead of 2.3 M. Execution Time
**92.6 ms** (a second run measured 32.8 ms; the spread is 0.5-CPU noise). Buffers
are the same ~15,250 shared hits in both plans, so the whole gain is CPU.
[`results/08_rewrite.txt`](results/08_rewrite.txt)

Two side effects worth telling a customer about: the `LEFT JOIN` + `COALESCE`
surfaces the 42 trips with `rate_code = 99`, which the tutorial's inner join
silently drops (its answer has 6 rows, the right answer has 7); and
`count(*)` replaces `COUNT(vendor_id)`, which is the same here (`vendor_id` is
never null) but lets the vectorised path count batches instead of values.

### Finding 3: the continuous aggregate answers the same question in under a millisecond

`rides_hourly` materialises trips and revenue per hour and rate code (884 rows
for the week; the refresh took 1.5 s). `trips_by_rate` sums it and joins
`rates`: **0.611 ms**, from 14 buffers instead of 15,000.
[`results/06_cagg.txt`](results/06_cagg.txt) The trade-off is freshness and
one more object to explain; for a dashboard that's exactly the right trade.

### Finding 4: PostGIS at query time is fast enough — no geometry columns needed

The dashboard's map query computes `ST_DWithin` on the fly from the existing
`pickup_longitude`/`pickup_latitude` columns. For one day around Times Square
it scans only the 2 of 4 chunks that cover the day (chunk exclusion on the
time filter, which is vectorised), then evaluates the geography test on
the ~348 K rows that pass it (16,625 match): **266.6 ms**. Adding a plain lat/long box that is a superset of
the 2 km circle ahead of `ST_DWithin` halves that to **135.2 ms**, because the
numeric comparisons are much cheaper than the geodesic distance.
[`results/09_grafana_map.txt`](results/09_grafana_map.txt)

## Analytics

`sql/07_analytics.sql` uses window functions over the continuous aggregate to
find each day's busiest hour with a 3-hour moving average and the change from
the previous hour ([`results/07_analytics.txt`](results/07_analytics.txt)):
New Year's Day peaks at 01:00 (28,511 trips), the Saturday at 19:00, the
Sunday at midnight, and every weekday after that at 18:00 or 19:00.

It also defines `hypertable_health(regclass)`, a PL/pgSQL function that
returns chunk count, chunks in the columnstore, total size and the state of
every policy job — and raises a clear error for a table that isn't a
hypertable. It's what a support engineer asks a customer to run first, and
it's the fourth panel of the dashboard.

## Grafana dashboard

![NYC Taxi on Tiger Cloud dashboard](docs/grafana-dashboard.png)

Grafana 13.2.2 runs locally in Docker and is provisioned entirely from this
repository: the data source, the dashboard and its four panels. Nothing is
clicked together in the UI.

```sh
source .env && docker compose up -d      # http://localhost:3000, user admin
docker compose down                       # stop; the Grafana database survives in a named volume
```

The main panel reproduces the tutorial's Geomap: a dark CARTO basemap centred
on Times Square (40.7589, −73.9851, zoom 12) with a **markers** layer and a
**heatmap** layer (fixed weight 1, radius 5, blur 15). The other panels are
trips per hour from `rides_hourly`, week-1 trips by rate code from
`trips_by_rate` (log scale — standard-rate trips outnumber every other code
40:1; this panel ignores the time picker), and `hypertable_health('rides')`.

The dashboard runs in **UTC** with a default range of 2016-01-01 00:00 to
2016-01-02 00:00. The stored timestamps have no time zone, so a UTC dashboard
is the only setting that keeps the time picker aligned with the data.

### The read-only role

Grafana runs whatever SQL a panel contains; it has no idea whether a query is
safe. So the database enforces it. `sql/09_grafana.sql` creates `grafana_ro`
with `USAGE` on `public` and `SELECT` on `rides`, `rates`, `payment_types`,
`rides_hourly` and `trips_by_rate` (TimescaleDB propagates the grants to every
chunk and to the aggregate's materialised hypertable), plus
`default_transaction_read_only = on`, `statement_timeout = '30s'` and a
connection limit of 10. Grafana never sees `tsdbadmin`'s password.

The script verifies all of this *while connected as `grafana_ro`*
([`results/09_grafana.txt`](results/09_grafana.txt)): the four panel queries
return rows; `CREATE TABLE`, `INSERT` and `DELETE` fail; and an `INSERT` still
fails after `SET transaction_read_only = off`, which a client is free to do —
the privileges are the real boundary, the setting is a seatbelt.

The password is generated with `openssl rand`, kept in `.env`, and passed to
`psql` as a variable. What reaches the server is a SCRAM-SHA-256 verifier
computed locally by `scripts/scram_verifier.py` (the same thing psql's
`\password` sends), so the plaintext cannot end up in `log_statement` output.

### What the dashboard fixes from the docs review

- **Item 6** — `$__timeFilter(pickup_datetime)` instead of a hard-coded
  six-hour window, so the map follows the time picker.
- **Item 7** — `trip_distance > 5` is actually applied; the tutorial describes
  "rides longer than 5 miles" but never filters on it.
- **Item 5** — `ORDER BY random() LIMIT 1000` samples across the whole range
  instead of showing the first 500 pickups after midnight, and `ST_DWithin`
  replaces `ST_Distance(...) < 2000`.
- **Locations are computed at query time.** The tutorial adds two geometry
  columns and runs a full-table `UPDATE` (10.9 M rows in its dataset). On a
  hypertable whose chunks are already in the columnstore — which they will be,
  see item 2 — that means decompressing and rewriting everything. Finding 4
  shows the on-the-fly version is fast enough for a dashboard.

### Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | `grafana/grafana:13.2.2`, port 3000; passes in only `PGHOST`, `PGPORT`, `GRAFANA_DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` |
| `grafana/provisioning/datasources/tiger.yaml` | data source `Tiger Cloud` (uid `tiger-cloud`), user `grafana_ro`, `sslmode: require`, `timescaledb: true`, 4-connection pool |
| `grafana/provisioning/dashboards/dashboards.yaml` | file provider with `allowUiUpdates: true` |
| `grafana/dashboards/nyc-taxi.json` | the dashboard |
| `scripts/grafana_api.sh` | admin API calls without the password on the command line |

Compose reads the `export KEY=value` lines in `.env` directly
(`docker compose config --quiet` is clean), so no second env file is needed.

Verification after `docker compose up -d`, all through the HTTP API:
`/api/health` reports 13.2.2; `/api/datasources/uid/tiger-cloud/health` says
"Database Connection OK"; `/api/search` lists the dashboard; and each panel's
query, posted to `/api/ds/query` for the default range, returns rows (map
1,000, bar chart 7, health 4, hourly 25).

If you change a panel in the UI and save, export it back into the repo:

```sh
source .env && scripts/grafana_api.sh GET /api/dashboards/uid/nyc-taxi \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["dashboard"]; d.pop("id",None); print(json.dumps(d, indent=2))' \
  > grafana/dashboards/nyc-taxi.json
```

## Docs review

Things a reader of the tutorial trips over, in page order. Items 5–7 are
fixed in the dashboard above.

1. **"About 59 seconds"** for the rowstore query is given without the service
   size, the data volume or a plan. On 0.5 CPU with week 1 (2.3 M rows) it takes
   2.6 s; readers can't tell whether their 3 s or 30 s is normal. An
   `EXPLAIN (ANALYZE, BUFFERS)` next to the claim would fix that.
2. **`tsdb.hypertable` silently creates a columnstore policy** (`compress_after
   = 7 days`). With 2016 data every chunk qualifies on the policy's first run,
   so anyone who follows the page at their own pace measures "rowstore"
   performance on chunks that are already compressed. The page should say so,
   or pause the job as `sql/01_schema.sql` does.
3. **`add_dimension('rides', by_hash('payment_type', 2))`** is never used by a
   query on the page, doubles the chunk count (4 instead of 2 for one week),
   and must run before `\COPY` because it only works on an empty table. None
   of that is explained.
4. **The columnstore section shows no SQL and no measurement.** "Compressed by
   up to 98 %" is 65 % on this dataset (417 → 147 MB), and the page's own
   flagship query barely moves (2,637.5 → 2,282.7 ms) because its join
   prevents vectorised aggregation — see Finding 2. The rewrite in
   `sql/08_rewrite.sql` is the thing the page should teach.
5. **The map query's mechanics.** `ORDER BY time LIMIT 500` returns the first
   500 pickups of the range, not a sample, so the map only ever shows the
   minutes after the range starts; the `GROUP BY` over every selected column is
   a no-op; and `ST_Distance(...) < 2000` computes the distance for every row
   where `ST_DWithin` would let PostGIS short-circuit.
6. **Hard-coded timestamps** (`BETWEEN '2016-01-01T01:41:55.986Z' AND
   '2016-01-01T07:41:55.986Z'`) instead of `$__timeFilter(pickup_datetime)`, so
   the Geomap ignores the time picker that the page just told the reader to set.
7. **`trip_distance > 5` is described but never applied.** The text asks for
   rides longer than 5 miles; the `WHERE` clause only filters on location and
   time.

And the full-table geometry `UPDATE` — `ALTER TABLE rides ADD COLUMN
pickup_geom ...` followed by `UPDATE rides SET pickup_geom = ..., dropoff_geom
= ...` over all 10.9 M rows — is the step most likely to generate a support
ticket: it is slow, it doubles the row width, and on already-compressed chunks
(item 2) it has to decompress them first. Finding 4 shows it isn't needed.

## Reproduce

```sh
source .env                                   # never commit this file
psql -f sql/01_schema.sql                     # hypertable, lookup tables, policy paused
psql -c "\copy rides FROM 'data/rides_week1.csv' CSV"
psql -f sql/02_verify.sql        > results/02_verify.txt      2>&1
psql -f sql/03_rowstore.sql      > results/03_rowstore.txt    2>&1
psql -f sql/04_index.sql         > results/04_index.txt       2>&1
psql -f sql/05_columnstore.sql   > results/05_columnstore.txt 2>&1
psql -f sql/06_cagg.sql          > results/06_cagg.txt        2>&1
psql -f sql/07_analytics.sql     > results/07_analytics.txt   2>&1
psql -f sql/08_rewrite.sql       > results/08_rewrite.txt     2>&1

# Grafana: reader role (safe to rerun), then the map query as that role
grep -q GRAFANA_DB_PASSWORD .env || printf "export GRAFANA_DB_PASSWORD='%s'\n" "$(openssl rand -hex 24)" >> .env
source .env
psql -v pw="$GRAFANA_DB_PASSWORD" -v pw_verifier="$(python3 scripts/scram_verifier.py)" \
     -f sql/09_grafana.sql > results/09_grafana.txt 2>&1
PGUSER=grafana_ro PGPASSWORD="$GRAFANA_DB_PASSWORD" \
     psql -f sql/09_grafana_map.sql > results/09_grafana_map.txt 2>&1

grep -q GRAFANA_ADMIN_PASSWORD .env || printf "export GRAFANA_ADMIN_PASSWORD='%s'\n" "$(openssl rand -hex 24)" >> .env
source .env && docker compose up -d           # http://localhost:3000
```

`sql/06`–`sql/09` are safe to rerun (`DROP ... IF EXISTS`, `CREATE OR REPLACE`,
`CREATE EXTENSION IF NOT EXISTS`, create-role-if-missing + `ALTER ROLE`).
`sql/01`–`sql/05` are one-shot by nature (they create and convert the data).

## Troubleshooting log

Problems hit along the way and what fixed them. Entries 1–3 are
reconstructed from the earlier scripts and commit history; 4–9 were hit while
building the Grafana part.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `convert_to_columnstore` can't be called from a `SELECT ... FROM show_chunks()` | It's a procedure (`CALL`), not a function | Generate one `CALL` per chunk and run them with `\gexec` (`sql/05`) |
| 2 | Rerunning `sql/06` failed on `CREATE MATERIALIZED VIEW` | The aggregate and the view already existed | `DROP VIEW IF EXISTS` / `DROP MATERIALIZED VIEW IF EXISTS` first; the drop cascades to the materialised chunk, which is expected |
| 3 | `hypertable_health('rates')` raises `rates is not a hypertable` | Intentional: the function checks its input | Nothing — it's the test that the error message is useful (`results/07_analytics.txt`) |
| 4 | `psql: error: invalid sslmode value: "requireexport"` right after adding a variable to `.env` | The file had no trailing newline, so `printf ... >> .env` glued the new line onto `PGSSLMODE='require'` | Split the line with `sed`; append with `[ -n "$(tail -c1 .env)" ] && echo >> .env` first |
| 5 | `ERROR: permission denied for table pg_authid` while checking the password type | `tsdbadmin` is not a superuser on Tiger Cloud | Query `pg_roles` instead; the successful reconnect as `grafana_ro` is the proof that the verifier works |
| 6 | `\c - grafana_ro` inside a script would prompt for a password | psql drops the cached password when the user changes; libpq then reads `PGPASSWORD`, which held `tsdbadmin`'s | `\setenv PGPASSWORD :pw` immediately before `\c`, with `pw` passed as `-v pw="$GRAFANA_DB_PASSWORD"` |
| 7 | `docker: failed to connect to the docker API at unix:///var/run/docker.sock` | The Ubuntu Docker daemon wasn't running in WSL and Docker Desktop's WSL integration was off for this distro | `sudo service docker start` |
| 8 | `docker: unknown command: docker compose` | The apt package `docker.io` doesn't ship the Compose plugin | Installed the official `docker-compose` v5.5.1 binary into `~/.docker/cli-plugins/` (checksum verified); `sudo apt install docker-compose-v2` is the packaged alternative |
| 9 | Which tag to pin? | `grafana/grafana:latest` says nothing in a repo | Pulled `latest`, read `"version": "13.2.2"` from `/api/health`, pinned that tag (same image digest) |

## Repository layout

```
.
├── README.md
├── .env                     # connection settings + Grafana passwords (git-ignored)
├── .gitignore               # .env, data/, .venv/, grafana/data/, .env.compose
├── docker-compose.yml       # Grafana 13.2.2, provisioned from ./grafana
├── data/                    # tutorial CSVs and the week-1 extract (git-ignored)
├── docs/
│   └── grafana-dashboard.png
├── grafana/
│   ├── dashboards/nyc-taxi.json
│   └── provisioning/
│       ├── dashboards/dashboards.yaml
│       └── datasources/tiger.yaml
├── results/                 # saved psql output, one file per script
│   ├── 02_verify.txt … 08_rewrite.txt
│   ├── 09_grafana.txt
│   └── 09_grafana_map.txt
├── scripts/
│   ├── grafana_api.sh       # admin API calls without the password in argv
│   └── scram_verifier.py    # SCRAM-SHA-256 verifier for ALTER ROLE ... PASSWORD
└── sql/
    ├── 01_schema.sql        # hypertable, lookup tables, policy paused
    ├── 02_verify.sql        # row count, chunks, size, jobs
    ├── 03_rowstore.sql      # ANALYZE, Q1 and Q2 baselines
    ├── 04_index.sql         # (rate_code, pickup_datetime DESC)
    ├── 05_columnstore.sql   # convert all chunks, Q1 again
    ├── 06_cagg.sql          # rides_hourly, trips_by_rate
    ├── 07_analytics.sql     # window functions, hypertable_health()
    ├── 08_rewrite.sql       # Q1: aggregate first, join after
    ├── 09_grafana.sql       # PostGIS, grafana_ro, verification as grafana_ro
    └── 09_grafana_map.sql   # the map query, EXPLAINed as grafana_ro
```

## Next steps

- **Ship the rewrite, not just the columnstore.** Finding 2 is the one-line
  answer to "I compressed my hypertable and my query is still slow": check
  whether the aggregate sits directly on the `ColumnarScan`. A follow-up would
  test whether `count(*)` vs `COUNT(vendor_id)` and `LEFT JOIN` vs `JOIN` each
  matter on their own.
- **Load the whole month** (10.9 M rows) to see whether the 59-second claim,
  the 98 % compression claim and the 92.6 ms rewrite scale the way the plans
  suggest.
- **Real-time aggregation** on `rides_hourly` and a refresh policy, so the
  dashboard stays correct when new trips arrive.
- **A spatial index** isn't possible without a geometry column, but a
  columnstore `orderby` that includes `pickup_latitude` could tighten the
  min/max metadata for the map's bounding box. Worth an experiment.
- **Hybrid search over this log** (`pg_textsearch` BM25 + `pgvectorscale`
  DiskANN with reciprocal rank fusion): all three extensions are available on
  the service; it needs an embedding API key, which this environment doesn't
  have.
