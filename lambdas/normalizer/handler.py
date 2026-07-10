"""Normalizer Lambda (runs INSIDE the VPC — needs the database, not internet).

SQS -> upsert Postgres -> re-materialize status.json -> S3 data bucket (via
the free S3 gateway endpoint). Vendor registry is seeded on cold start.

Connection hygiene (learned the hard way): _conn is reused across warm
invocations, so ANY failure must rollback — otherwise the connection is
permanently stuck in InFailedSqlTransaction and every later invocation
fails instantly. Connection-level errors discard the connection entirely.
"""
import json
import os
from datetime import datetime

import boto3
import psycopg2

from core import load_vendors, materialize_snapshot

S3 = boto3.client("s3")
DATA_BUCKET = os.environ["DATA_BUCKET"]
VENDORS = load_vendors(os.path.join(os.path.dirname(__file__), "vendors.yaml"))

_conn = None  # reused across warm invocations


def conn():
    global _conn
    if _conn is None or _conn.closed:
        _conn = psycopg2.connect(
            host=os.environ["DB_HOST"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            dbname=os.environ["DB_NAME"],
            connect_timeout=10,
        )
        _seed_vendors(_conn)
    return _conn


def _discard_conn():
    """Connection-level problem: close and forget; next invoke reconnects."""
    global _conn
    try:
        if _conn is not None:
            _conn.close()
    except Exception:
        pass
    _conn = None


def _seed_vendors(c):
    with c.cursor() as cur:
        for v in VENDORS:
            cur.execute(
                """INSERT INTO vendors (slug, name, adapter, base_url, category)
                   VALUES (%(slug)s, %(name)s, %(adapter)s, %(base_url)s, %(category)s)
                   ON CONFLICT (slug) DO UPDATE SET
                     name = EXCLUDED.name, adapter = EXCLUDED.adapter,
                     base_url = EXCLUDED.base_url, category = EXCLUDED.category""",
                {"category": None, **v},
            )
    c.commit()


def _ts(v):
    return datetime.fromisoformat(v) if v else None


def _upsert_message(c, msg):
    with c.cursor() as cur:
        cur.execute(
            """INSERT INTO status_snapshots (vendor_slug, status, raw_s3_key, latency_ms)
               VALUES (%s, %s, %s, %s)""",
            (msg["vendor_slug"], msg["status"], msg.get("raw_s3_key"), msg.get("latency_ms")),
        )
        for inc in msg.get("incidents", []):
            if not inc.get("started_at"):
                continue
            cur.execute(
                """INSERT INTO incidents (vendor_slug, provider_incident_id, title,
                       impact, status, started_at, resolved_at, url)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (vendor_slug, provider_incident_id) DO UPDATE SET
                       title = EXCLUDED.title, impact = EXCLUDED.impact,
                       status = EXCLUDED.status, resolved_at = EXCLUDED.resolved_at
                   RETURNING id""",
                (msg["vendor_slug"], inc["provider_incident_id"], inc["title"],
                 inc["impact"], inc["status"], _ts(inc["started_at"]),
                 _ts(inc.get("resolved_at")), inc.get("url")),
            )
            incident_id = cur.fetchone()[0]
            for (uid, body, ustatus, posted_at) in inc.get("updates", []):
                if not posted_at:
                    continue
                cur.execute(
                    """INSERT INTO incident_updates (incident_id, provider_update_id,
                           body, status, posted_at)
                       VALUES (%s, %s, %s, %s, %s)
                       ON CONFLICT (incident_id, provider_update_id) DO NOTHING""",
                    (incident_id, uid, body[:4000], ustatus, _ts(posted_at)),
                )
        if msg.get("error"):
            cur.execute(
                """INSERT INTO poll_health (vendor_slug, last_attempt, consecutive_failures, last_error)
                   VALUES (%s, now(), 1, %s)
                   ON CONFLICT (vendor_slug) DO UPDATE SET
                       last_attempt = now(),
                       consecutive_failures = poll_health.consecutive_failures + 1,
                       last_error = EXCLUDED.last_error""",
                (msg["vendor_slug"], msg["error"][:1000]),
            )
        else:
            cur.execute(
                """INSERT INTO poll_health (vendor_slug, last_attempt, last_success, consecutive_failures, last_error)
                   VALUES (%s, now(), now(), 0, NULL)
                   ON CONFLICT (vendor_slug) DO UPDATE SET
                       last_attempt = now(), last_success = now(),
                       consecutive_failures = 0, last_error = NULL""",
                (msg["vendor_slug"],),
            )
    c.commit()


def lambda_handler(event, _context):
    try:
        c = conn()
        for record in event.get("Records", []):
            _upsert_message(c, json.loads(record["body"]))
        snapshot = materialize_snapshot(c, VENDORS)
    except (psycopg2.OperationalError, psycopg2.InterfaceError):
        _discard_conn()   # dead/broken connection: rebuild next invoke
        raise             # let SQS retry the batch
    except Exception:
        try:
            conn().rollback()   # CRITICAL: clear the aborted transaction
        except Exception:
            _discard_conn()
        raise               # SQS retries; upserts are idempotent, so safe

    S3.put_object(
        Bucket=DATA_BUCKET, Key="status.json", Body=snapshot.encode(),
        ContentType="application/json", CacheControl="max-age=60",
    )
    return {"processed": len(event.get("Records", []))}