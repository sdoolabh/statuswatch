"""Poller Lambda (runs OUTSIDE the VPC — needs internet, not the database).

EventBridge (rate 2 min) -> poll all vendors concurrently -> archive raw to
S3 -> enqueue one SQS message per observation. Raw bytes go to S3, never SQS
(256KB message limit); the message carries the S3 key as provenance.
Packaging note: pipeline/ (core.py, adapters/, vendors.yaml) is copied in at
build time by `make package` — the laptop code IS the cloud code.
"""
import asyncio
import json
import os
from datetime import datetime, timezone

import boto3

from core import load_vendors, poll_all

S3 = boto3.client("s3")
SQS = boto3.client("sqs")
RAW_BUCKET = os.environ["RAW_BUCKET"]
QUEUE_URL = os.environ["QUEUE_URL"]


def _archive_raw_s3(obs):
    if not obs.raw:
        return None
    ts = datetime.now(timezone.utc).strftime("%Y%m%d/%H%M%S")
    key = f"raw/{obs.vendor_slug}/{ts}.json"
    S3.put_object(Bucket=RAW_BUCKET, Key=key, Body=obs.raw,
                  ContentType="application/json")
    return key


def _to_message(obs, raw_key):
    return {
        "vendor_slug": obs.vendor_slug,
        "status": obs.status,
        "error": obs.error,
        "latency_ms": obs.latency_ms,
        "raw_s3_key": raw_key,
        "incidents": [
            {
                "provider_incident_id": i.provider_incident_id,
                "title": i.title,
                "impact": i.impact,
                "status": i.status,
                "started_at": i.started_at.isoformat() if i.started_at else None,
                "resolved_at": i.resolved_at.isoformat() if i.resolved_at else None,
                "url": i.url,
                "updates": [
                    [uid, body, ustatus, posted.isoformat() if posted else None]
                    for (uid, body, ustatus, posted) in i.updates
                ],
            }
            for i in obs.incidents
        ],
    }


def lambda_handler(_event, _context):
    vendors = load_vendors(os.path.join(os.path.dirname(__file__), "vendors.yaml"))
    results = asyncio.run(poll_all(vendors))

    sent = 0
    # SQS batch limit is 10 messages per call
    entries = []
    for obs in results:
        raw_key = _archive_raw_s3(obs)
        body = json.dumps(_to_message(obs, raw_key))
        entries.append({"Id": str(len(entries)), "MessageBody": body})
        if len(entries) == 10:
            SQS.send_message_batch(QueueUrl=QUEUE_URL, Entries=entries)
            sent += len(entries)
            entries = []
    if entries:
        SQS.send_message_batch(QueueUrl=QUEUE_URL, Entries=entries)
        sent += len(entries)

    unknowns = sum(1 for o in results if o.status == "unknown")
    print(json.dumps({"polled": len(results), "unknown": unknowns, "enqueued": sent}))
    return {"polled": len(results), "unknown": unknowns}
