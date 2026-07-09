#!/usr/bin/env python3
"""Local driver for the statuswatch pipeline.

  python run_local.py probe    # test every vendor endpoint, no DB needed
  python run_local.py cycle    # one full poll -> archive -> upsert -> materialize
  python run_local.py serve    # (after cycle) print the materialized status.json

probe is the first thing to run after ANY vendors.yaml edit — it reports
exactly which adapters/endpoints work against the live internet.
"""
import asyncio
import os
import sys

import psycopg2

from core import (archive_raw, load_vendors, materialize_snapshot, poll_all,
                  upsert_observation)

DSN = os.environ.get(
    "DATABASE_URL",
    "host=localhost user=statuswatch password=localdev dbname=statuswatch",
)

GREEN, RED, YELLOW, RESET = "\033[92m", "\033[91m", "\033[93m", "\033[0m"


def probe():
    vendors = load_vendors()
    results = asyncio.run(poll_all(vendors))
    ok = bad = 0
    for obs in sorted(results, key=lambda o: (o.error is not None, o.vendor_slug)):
        if obs.error:
            bad += 1
            print(f"{RED}FAIL{RESET}  {obs.vendor_slug:<14} {obs.error}")
        else:
            ok += 1
            color = GREEN if obs.status == "operational" else YELLOW
            print(f"{GREEN}ok{RESET}    {obs.vendor_slug:<14} "
                  f"{color}{obs.status}{RESET}  "
                  f"{obs.latency_ms}ms  {len(obs.incidents)} recent incidents")
    print(f"\n{ok} working, {bad} failing out of {len(results)} vendors")
    if bad:
        print("Fix or disable failing vendors in vendors.yaml (enabled: false), then re-probe.")
    return 0 if bad == 0 else 1


def cycle():
    vendors = load_vendors()
    conn = psycopg2.connect(DSN)
    _seed_vendors(conn, vendors)
    results = asyncio.run(poll_all(vendors))
    for obs in results:
        key = archive_raw(obs)
        upsert_observation(conn, obs, raw_key=key)
    snapshot = materialize_snapshot(conn, vendors)
    with open("status.json", "w") as f:
        f.write(snapshot)
    unknowns = sum(1 for o in results if o.status == "unknown")
    print(f"cycle complete: {len(results)} vendors polled, {unknowns} unknown, status.json written")
    conn.close()


def _seed_vendors(conn, vendors):
    with conn.cursor() as cur:
        for v in vendors:
            cur.execute(
                """INSERT INTO vendors (slug, name, adapter, base_url, homepage, category)
                   VALUES (%(slug)s, %(name)s, %(adapter)s, %(base_url)s, %(homepage)s, %(category)s)
                   ON CONFLICT (slug) DO UPDATE SET
                     name = EXCLUDED.name, adapter = EXCLUDED.adapter,
                     base_url = EXCLUDED.base_url, category = EXCLUDED.category""",
                {"homepage": None, "category": None, **v},
            )
    conn.commit()


def serve():
    print(open("status.json").read())


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "probe"
    sys.exit({"probe": probe, "cycle": cycle, "serve": serve}.get(cmd, probe)() or 0)
