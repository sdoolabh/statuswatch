# statuswatch pipeline — Phase 1 (local)

The data layer of the vendor outage tracker, runnable entirely on a laptop
before any AWS resources exist.

## First run

```bash
pip install -r requirements.txt

# 1. Verify vendor endpoints against the live internet (no DB needed):
python run_local.py probe

# 2. Fix/disable any failures in vendors.yaml, re-probe until clean(ish).

# 3. Start Postgres and run a full cycle:
docker compose up -d
python run_local.py cycle      # poll -> raw archive -> Postgres -> status.json

# 4. Look at what the always-on product will serve:
python run_local.py serve | head -50
```

Run `cycle` a few times over a day and you'll have real snapshots and real
incident history — the same data model production will use.

## Layout
- `schema.sql` — normalized model: snapshots, incidents (upserted), updates,
  daily rollups, and `poll_health` (pipeline self-observability)
- `vendors.yaml` — the registry; adding a vendor is config, not code
- `adapters/` — one standard Statuspage adapter (~most vendors) + bespoke
  adapters for Slack/GCP/AWS/Azure; all fail soft to `unknown`
- `core.py` — poll/archive/upsert/materialize as plain functions (the same
  code becomes the Lambda in Phase 2 and can run on K8s in Phase 4)
- `raw/` — raw-before-parse archive (S3 in production)
- `status.json` — the materialized snapshot CloudFront will serve

## Known follow-ups
- Custom adapter endpoints (esp. AWS, Azure) are best-effort and probe will
  tell the truth; expect to tune them on first run.
- Statuspage `/incidents.json` returns recent history — a deeper backfill
  job comes with the K8s phase.
