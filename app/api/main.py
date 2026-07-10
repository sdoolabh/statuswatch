"""statuswatch history API — the rich layer the static site can't provide.
Read-only over the pipeline's Postgres. RED metrics exposed at /metrics for
Prometheus (rate/errors/duration — the dashboards speak that framework)."""
import os
import time

import psycopg2
import psycopg2.extras
import psycopg2.pool
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="statuswatch-api", docs_url="/docs")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET"], allow_headers=["*"])

REQS = Counter("api_requests_total", "requests", ["path", "status"])
LAT = Histogram("api_request_duration_seconds", "latency", ["path"])

POOL = psycopg2.pool.SimpleConnectionPool(
    1, 5,
    host=os.environ["DB_HOST"], user=os.environ["DB_USER"],
    password=os.environ["DB_PASSWORD"], dbname=os.environ["DB_NAME"],
    connect_timeout=5,
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    t0 = time.monotonic()
    response = await call_next(request)
    path = request.url.path
    if not path.startswith("/metrics"):
        REQS.labels(path=path, status=response.status_code).inc()
        LAT.labels(path=path).observe(time.monotonic() - t0)
    return response


def q(sql, params=()):
    conn = POOL.getconn()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    except psycopg2.Error as exc:
        conn.rollback()
        raise HTTPException(status_code=503, detail=f"database error: {exc.pgcode}") from exc
    finally:
        POOL.putconn(conn)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/vendors")
def vendors():
    return {"vendors": q("""
        SELECT v.slug, v.name, v.category,
               s.status, s.observed_at
        FROM vendors v
        LEFT JOIN LATERAL (
            SELECT status, observed_at FROM status_snapshots
            WHERE vendor_slug = v.slug ORDER BY observed_at DESC LIMIT 1
        ) s ON true
        WHERE v.enabled ORDER BY v.slug""")}


@app.get("/api/vendors/{slug}/incidents")
def vendor_incidents(slug: str, limit: int = 50):
    rows = q("""
        SELECT provider_incident_id, title, impact, status, started_at, resolved_at, url
        FROM incidents WHERE vendor_slug = %s
        ORDER BY started_at DESC LIMIT %s""", (slug, min(limit, 200)))
    if not rows and not q("SELECT 1 FROM vendors WHERE slug = %s", (slug,)):
        raise HTTPException(status_code=404, detail="unknown vendor")
    return {"vendor": slug, "incidents": rows}


@app.get("/api/vendors/{slug}/uptime")
def vendor_uptime(slug: str, days: int = 30):
    return {"vendor": slug, "days": q("""
        SELECT day, operational_pct, degraded_pct, outage_pct, unknown_pct
        FROM uptime_daily WHERE vendor_slug = %s
        ORDER BY day DESC LIMIT %s""", (slug, min(days, 365)))}


@app.get("/api/incidents/recent")
def recent_incidents(limit: int = 50):
    return {"incidents": q("""
        SELECT vendor_slug, title, impact, status, started_at, resolved_at, url
        FROM incidents ORDER BY started_at DESC LIMIT %s""", (min(limit, 200),))}


@app.get("/api/pipeline/health")
def pipeline_health():
    """The pipeline watching itself — the public honesty endpoint."""
    return {"vendors": q("""
        SELECT vendor_slug, last_attempt, last_success,
               consecutive_failures, last_error
        FROM poll_health ORDER BY consecutive_failures DESC, vendor_slug""")}
