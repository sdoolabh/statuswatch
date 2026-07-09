"""The poll cycle, written as plain functions so the same code runs three
ways: locally via run_local.py, as a Lambda (phase 2), or in a container on
K8s (phase 4 option). No environment leaks into the logic."""
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path

import aiohttp
import yaml

from adapters import build

HEADERS = {"User-Agent": "statuswatch/0.1 (+https://shanedoolabh.com)"}
CONCURRENCY = 12
TIMEOUT = aiohttp.ClientTimeout(total=10)


def load_vendors(path="vendors.yaml"):
    doc = yaml.safe_load(Path(path).read_text())
    return [v for v in doc["vendors"] if v.get("enabled", True)]


async def poll_all(vendors):
    """Fetch every vendor concurrently; one hung vendor can't stall a cycle."""
    sem = asyncio.Semaphore(CONCURRENCY)
    async with aiohttp.ClientSession(timeout=TIMEOUT, headers=HEADERS) as session:
        async def one(vendor):
            async with sem:
                adapter = build(vendor)
                try:
                    return await adapter.fetch(session)
                except Exception as exc:  # belt & suspenders: adapters shouldn't leak
                    return adapter.unknown(f"adapter crashed: {exc}")
        return await asyncio.gather(*(one(v) for v in vendors))


def archive_raw(obs, root="raw"):
    """Raw-before-parse. Locally: files. In AWS: same layout, S3 keys."""
    if not obs.raw:
        return None
    ts = datetime.now(timezone.utc).strftime("%Y%m%d/%H%M%S")
    key = f"{obs.vendor_slug}/{ts}.json"
    path = Path(root) / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(obs.raw)
    return key


def upsert_observation(conn, obs, raw_key=None):
    """Write one observation: snapshot append, incident upserts, poll health."""
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO status_snapshots (vendor_slug, status, raw_s3_key, latency_ms)
               VALUES (%s, %s, %s, %s)""",
            (obs.vendor_slug, obs.status, raw_key, obs.latency_ms),
        )
        for inc in obs.incidents:
            cur.execute(
                """INSERT INTO incidents (vendor_slug, provider_incident_id, title,
                       impact, status, started_at, resolved_at, url)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (vendor_slug, provider_incident_id) DO UPDATE SET
                       title = EXCLUDED.title,
                       impact = EXCLUDED.impact,
                       status = EXCLUDED.status,
                       resolved_at = EXCLUDED.resolved_at
                   RETURNING id""",
                (obs.vendor_slug, inc.provider_incident_id, inc.title, inc.impact,
                 inc.status, inc.started_at, inc.resolved_at, inc.url),
            )
            incident_id = cur.fetchone()[0]
            for (uid, body, ustatus, posted_at) in inc.updates:
                if posted_at is None:
                    continue
                cur.execute(
                    """INSERT INTO incident_updates (incident_id, provider_update_id,
                           body, status, posted_at)
                       VALUES (%s, %s, %s, %s, %s)
                       ON CONFLICT (incident_id, provider_update_id) DO NOTHING""",
                    (incident_id, uid, body[:4000], ustatus, posted_at),
                )
        if obs.error:
            cur.execute(
                """INSERT INTO poll_health (vendor_slug, last_attempt, consecutive_failures, last_error)
                   VALUES (%s, now(), 1, %s)
                   ON CONFLICT (vendor_slug) DO UPDATE SET
                       last_attempt = now(),
                       consecutive_failures = poll_health.consecutive_failures + 1,
                       last_error = EXCLUDED.last_error""",
                (obs.vendor_slug, obs.error[:1000]),
            )
        else:
            cur.execute(
                """INSERT INTO poll_health (vendor_slug, last_attempt, last_success, consecutive_failures, last_error)
                   VALUES (%s, now(), now(), 0, NULL)
                   ON CONFLICT (vendor_slug) DO UPDATE SET
                       last_attempt = now(), last_success = now(),
                       consecutive_failures = 0, last_error = NULL""",
                (obs.vendor_slug,),
            )
    conn.commit()


def materialize_snapshot(conn, vendors):
    """The static status.json that CloudFront serves — the always-on product."""
    by_slug = {v["slug"]: v for v in vendors}
    with conn.cursor() as cur:
        cur.execute(
            """SELECT DISTINCT ON (vendor_slug) vendor_slug, status, observed_at
               FROM status_snapshots ORDER BY vendor_slug, observed_at DESC"""
        )
        current = cur.fetchall()
        cur.execute(
            """SELECT vendor_slug, title, impact, started_at, url
               FROM incidents WHERE resolved_at IS NULL
               ORDER BY started_at DESC LIMIT 50"""
        )
        ongoing = cur.fetchall()

    return json.dumps({
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "vendors": [
            {
                "slug": slug,
                "name": by_slug.get(slug, {}).get("name", slug),
                "category": by_slug.get(slug, {}).get("category"),
                "status": status,
                "observed_at": observed_at.isoformat(),
            }
            for (slug, status, observed_at) in current
        ],
        "ongoing_incidents": [
            {"vendor": v, "title": t, "impact": i,
             "started_at": s.isoformat(), "url": u}
            for (v, t, i, s, u) in ongoing
        ],
    }, indent=2)
