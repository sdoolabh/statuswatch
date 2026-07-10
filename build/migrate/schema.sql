-- statuswatch schema: the system of record.
-- Design notes:
--  * status vocabulary is normalized to ONE enum across all vendors
--  * incidents are UPSERTed on (vendor, provider_incident_id) — providers
--    update incidents in place, we must never duplicate
--  * snapshots are append-only observations; 'unknown' is a first-class
--    status meaning "we could not observe" (never silently stale)

CREATE TYPE vendor_status AS ENUM (
  'operational', 'degraded', 'partial_outage', 'major_outage',
  'maintenance', 'unknown'
);

CREATE TABLE vendors (
  slug         TEXT PRIMARY KEY,          -- 'github', 'cloudflare'
  name         TEXT NOT NULL,
  adapter      TEXT NOT NULL,             -- 'statuspage', 'slack', 'gcp', ...
  base_url     TEXT NOT NULL,             -- adapter-specific endpoint root
  homepage     TEXT,
  category     TEXT,                      -- 'ci', 'cloud', 'registry', ...
  enabled      BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE status_snapshots (
  id           BIGSERIAL PRIMARY KEY,
  vendor_slug  TEXT NOT NULL REFERENCES vendors(slug),
  observed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  status       vendor_status NOT NULL,
  raw_s3_key   TEXT,                      -- provenance: the raw payload behind this row
  latency_ms   INTEGER                    -- how long the vendor's status API took
);
CREATE INDEX idx_snapshots_vendor_time ON status_snapshots (vendor_slug, observed_at DESC);

CREATE TABLE incidents (
  id                    BIGSERIAL PRIMARY KEY,
  vendor_slug           TEXT NOT NULL REFERENCES vendors(slug),
  provider_incident_id  TEXT NOT NULL,    -- the vendor's own ID
  title                 TEXT NOT NULL,
  impact                vendor_status NOT NULL DEFAULT 'unknown',
  status                TEXT NOT NULL,    -- provider vocab: investigating/identified/monitoring/resolved
  started_at            TIMESTAMPTZ NOT NULL,
  resolved_at           TIMESTAMPTZ,      -- NULL = ongoing
  url                   TEXT,
  UNIQUE (vendor_slug, provider_incident_id)
);
CREATE INDEX idx_incidents_vendor_started ON incidents (vendor_slug, started_at DESC);
CREATE INDEX idx_incidents_ongoing ON incidents (started_at DESC) WHERE resolved_at IS NULL;

CREATE TABLE incident_updates (
  id                    BIGSERIAL PRIMARY KEY,
  incident_id           BIGINT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  provider_update_id    TEXT NOT NULL,
  body                  TEXT NOT NULL,
  status                TEXT NOT NULL,
  posted_at             TIMESTAMPTZ NOT NULL,
  UNIQUE (incident_id, provider_update_id)
);

-- Nightly rollup (K8s CronJob in phase 4). Percentage of the day each vendor
-- spent in each status, from snapshots.
CREATE TABLE uptime_daily (
  vendor_slug   TEXT NOT NULL REFERENCES vendors(slug),
  day           DATE NOT NULL,
  operational_pct  NUMERIC(5,2) NOT NULL,
  degraded_pct     NUMERIC(5,2) NOT NULL,
  outage_pct       NUMERIC(5,2) NOT NULL,
  unknown_pct      NUMERIC(5,2) NOT NULL,
  PRIMARY KEY (vendor_slug, day)
);

-- Pipeline self-observability: per-vendor poll health, the raw material for
-- the public /health page and Grafana freshness SLOs.
CREATE TABLE poll_health (
  vendor_slug     TEXT PRIMARY KEY REFERENCES vendors(slug),
  last_attempt    TIMESTAMPTZ,
  last_success    TIMESTAMPTZ,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT
);
