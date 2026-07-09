"""Bespoke adapters for the giants that don't use Statuspage.

HONESTY NOTE: these endpoints are best-effort from documentation and may have
drifted — that is exactly what `run_local.py probe` exists to detect. Every
adapter fails soft to 'unknown', so a wrong endpoint degrades gracefully and
shows up in poll_health rather than crashing a cycle.
"""
import json
import time
from datetime import datetime, timezone

from .base import Adapter, Incident, Observation


def _now():
    return datetime.now(timezone.utc)


class SlackAdapter(Adapter):
    """Slack publishes a JSON API at /api/v2.0.0/current."""

    async def fetch(self, session) -> Observation:
        t0 = time.monotonic()
        try:
            async with session.get(f"{self.base_url}/api/v2.0.0/current") as r:
                if r.status != 200:
                    return self.unknown(f"HTTP {r.status}")
                raw = await r.read()
            doc = json.loads(raw)
        except Exception as exc:
            return self.unknown(f"{type(exc).__name__}: {exc}")

        latency = int((time.monotonic() - t0) * 1000)
        active = doc.get("active_incidents") or []
        # Slack status values: "ok" or "active" with incident types
        if not active:
            status = "operational"
        else:
            types = {i.get("type") for i in active}
            status = "major_outage" if "outage" in types else "degraded"

        incidents = []
        for inc in active:
            incidents.append(Incident(
                provider_incident_id=str(inc.get("id")),
                title=inc.get("title") or "(untitled)",
                impact="major_outage" if inc.get("type") == "outage" else "degraded",
                status=inc.get("status") or "active",
                started_at=_parse_slack_ts(inc.get("date_created")) or _now(),
                resolved_at=None,
                url=inc.get("url"),
            ))
        return Observation(vendor_slug=self.slug, status=status,
                           incidents=incidents, raw=raw, latency_ms=latency)


def _parse_slack_ts(v):
    if not v:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%a, %d %b %Y %H:%M:%S %z"):
        try:
            return datetime.strptime(v, fmt)
        except ValueError:
            continue
    return None


class GcpAdapter(Adapter):
    """Google Cloud publishes /incidents.json — a flat list of incidents,
    most-recent first. Current status is derived: any unresolved incident
    means degraded/outage."""

    async def fetch(self, session) -> Observation:
        t0 = time.monotonic()
        try:
            async with session.get(f"{self.base_url}/incidents.json") as r:
                if r.status != 200:
                    return self.unknown(f"HTTP {r.status}")
                raw = await r.read()
            doc = json.loads(raw)
        except Exception as exc:
            return self.unknown(f"{type(exc).__name__}: {exc}")

        latency = int((time.monotonic() - t0) * 1000)
        incidents, ongoing_severity = [], []
        for inc in doc[:50] if isinstance(doc, list) else []:
            resolved = inc.get("end") is not None
            sev = (inc.get("severity") or "").lower()
            impact = {"high": "major_outage", "medium": "partial_outage",
                      "low": "degraded"}.get(sev, "degraded")
            if not resolved:
                ongoing_severity.append(impact)
            incidents.append(Incident(
                provider_incident_id=str(inc.get("id")),
                title=(inc.get("external_desc") or "(untitled)").strip()[:300],
                impact=impact,
                status="resolved" if resolved else "investigating",
                started_at=datetime.fromisoformat(inc["begin"].replace("Z", "+00:00")) if inc.get("begin") else _now(),
                resolved_at=datetime.fromisoformat(inc["end"].replace("Z", "+00:00")) if inc.get("end") else None,
                url=f"https://status.cloud.google.com/incidents/{inc.get('id')}",
            ))

        if not ongoing_severity:
            status = "operational"
        elif "major_outage" in ongoing_severity:
            status = "major_outage"
        elif "partial_outage" in ongoing_severity:
            status = "partial_outage"
        else:
            status = "degraded"

        return Observation(vendor_slug=self.slug, status=status,
                           incidents=incidents, raw=raw, latency_ms=latency)


class AwsAdapter(Adapter):
    """AWS public health data (data.json): a LIST of event objects.
    Quirks handled deliberately:
      * UTF-16 w/ BOM payload (json.loads on bytes auto-detects)
      * top-level 'date' is epoch SECONDS; transition 'timestamp' is MILLISECONDS
      * top-level 'status' is PEAK severity, never updated on resolution —
        resolution must be derived from impacted_service_status_changes:
        an event is ongoing only if some service's latest transition != '0'
    Codes: 0 ok, 1 informational, 2 degradation, 3 disruption."""

    SEVERITY = {"1": "degraded", "2": "partial_outage", "3": "major_outage"}
    RANK = {"operational": 0, "degraded": 1, "partial_outage": 2, "major_outage": 3}

    async def fetch(self, session) -> Observation:
        t0 = time.monotonic()
        try:
            async with session.get(f"{self.base_url}/data.json") as r:
                if r.status != 200:
                    return self.unknown(f"HTTP {r.status}")
                raw = await r.read()
            doc = json.loads(raw)
        except Exception as exc:
            return self.unknown(f"{type(exc).__name__}: {exc}")

        if not isinstance(doc, list):
            return self.unknown(f"unexpected payload shape: {type(doc).__name__}")

        latency = int((time.monotonic() - t0) * 1000)
        incidents = []
        worst_ongoing = "operational"

        for ev in doc:
            if not isinstance(ev, dict):
                continue
            try:
                started = datetime.fromtimestamp(int(ev.get("date", 0)), tz=timezone.utc)
            except (ValueError, TypeError):
                continue

            impact = self.SEVERITY.get(str(ev.get("status", "")), "degraded")

            # resolution from the transition log
            latest = {}
            for t in ev.get("impacted_service_status_changes") or []:
                ts, svc = t.get("timestamp"), t.get("service")
                if ts is None or svc is None:
                    continue
                if svc not in latest or ts >= latest[svc][0]:
                    latest[svc] = (ts, str(t.get("current_status")))

            STALE_DAYS = 7  # no transition activity for a week => event is over
            if latest:
                newest_ts = max(ts for ts, _ in latest.values())
                newest_at = datetime.fromtimestamp(newest_ts / 1000, tz=timezone.utc)
                all_clear = all(st == "0" for _, st in latest.values())
                gone_quiet = (_now() - newest_at).days >= STALE_DAYS
                # Feed quirk: AWS closes events without back-filling every
                # service's ->0 transition, so silence is also resolution.
                resolved = all_clear or gone_quiet
                resolved_at = newest_at if resolved else None
            else:
                resolved = str(ev.get("status", "")) == "0" or \
                           (_now() - started).days >= STALE_DAYS
                resolved_at = started if resolved else None

            if not resolved and self.RANK[impact] > self.RANK[worst_ongoing]:
                worst_ongoing = impact

            n_services = len(ev.get("impacted_services") or {})
            suffix = f" ({n_services} services)" if n_services > 1 else ""
            incidents.append(Incident(
                provider_incident_id=ev.get("arn") or f"aws-{ev.get('date')}-{ev.get('service')}",
                title=f"{ev.get('service_name', 'AWS')} — {ev.get('region_name', 'global')}{suffix}: {(ev.get('summary') or '').strip()[:200]}",
                impact=impact,
                status="resolved" if resolved else "investigating",
                started_at=started,
                resolved_at=resolved_at,
                url="https://health.aws.amazon.com/health/status",
            ))

        return Observation(vendor_slug=self.slug, status=worst_ongoing,
                           incidents=incidents, raw=raw, latency_ms=latency)


class AzureAdapter(Adapter):
    """Azure has no clean public JSON API; their status page ships an RSS
    feed. We parse it minimally (stdlib only). Expect probe to guide fixes."""

    async def fetch(self, session) -> Observation:
        import xml.etree.ElementTree as ET
        t0 = time.monotonic()
        try:
            async with session.get(f"{self.base_url}/en-us/status/feed/") as r:
                if r.status != 200:
                    return self.unknown(f"HTTP {r.status}")
                raw = await r.read()
            root = ET.fromstring(raw)
        except Exception as exc:
            return self.unknown(f"{type(exc).__name__}: {exc}")

        latency = int((time.monotonic() - t0) * 1000)
        items = root.findall(".//item")
        incidents = []
        for item in items[:25]:
            title = (item.findtext("title") or "(untitled)").strip()
            guid = item.findtext("guid") or title
            pub = item.findtext("pubDate")
            posted = None
            if pub:
                try:
                    posted = datetime.strptime(pub.strip(), "%a, %d %b %Y %H:%M:%S %Z")
                except ValueError:
                    posted = None
            incidents.append(Incident(
                provider_incident_id=guid,
                title=title[:300],
                impact="degraded",
                status="posted",
                started_at=posted or _now(),
                resolved_at=None,
                url=item.findtext("link"),
            ))
        # RSS presence of recent items != current outage; without a cleaner
        # signal we only report operational vs unknown here.
        return Observation(vendor_slug=self.slug, status="operational",
                           incidents=incidents, raw=raw, latency_ms=latency)


REGISTRY = {
    "slack": SlackAdapter,
    "gcp": GcpAdapter,
    "aws": AwsAdapter,
    "azure": AzureAdapter,
}
