"""Nightly rollup: yesterday's snapshots -> uptime_daily percentages.
Runs as a K8s CronJob — the batch half of the pipeline lives on the cluster
(the streaming half is Lambda; that split is the architecture story)."""
import os
from datetime import date, timedelta

import psycopg2

SQL = """
INSERT INTO uptime_daily (vendor_slug, day, operational_pct, degraded_pct, outage_pct, unknown_pct)
SELECT vendor_slug, %(day)s::date,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'operational') / COUNT(*), 2),
    ROUND(100.0 * COUNT(*) FILTER (WHERE status IN ('degraded','maintenance')) / COUNT(*), 2),
    ROUND(100.0 * COUNT(*) FILTER (WHERE status IN ('partial_outage','major_outage')) / COUNT(*), 2),
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'unknown') / COUNT(*), 2)
FROM status_snapshots
WHERE observed_at >= %(day)s::date AND observed_at < %(day)s::date + interval '1 day'
GROUP BY vendor_slug
ON CONFLICT (vendor_slug, day) DO UPDATE SET
    operational_pct = EXCLUDED.operational_pct,
    degraded_pct    = EXCLUDED.degraded_pct,
    outage_pct      = EXCLUDED.outage_pct,
    unknown_pct     = EXCLUDED.unknown_pct
"""

def main():
    day = date.today() - timedelta(days=1)
    conn = psycopg2.connect(
        host=os.environ["DB_HOST"], user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"], dbname=os.environ["DB_NAME"],
        connect_timeout=10,
    )
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(SQL, {"day": day.isoformat()})
        print(f"rolled up {cur.rowcount} vendors for {day}")
    conn.close()

if __name__ == "__main__":
    main()
