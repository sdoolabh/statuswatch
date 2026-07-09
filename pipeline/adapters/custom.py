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
    """AWS's public health data. The legacy data.json lists current events;
    verify with probe — AWS has migrated dashboards before and may again."""

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

        latency = int((time.monotonic() - t0) * 1000)
        current = doc.get("current") or []
        if not current:
            status = "operational"
        else:
            # AWS severity levels: 0/1 informational..., treat any active event as degraded+
            status = "partial_outage" if len(current) > 2 else "degraded"

        incidents = []
        for ev in current[:50]:
            incidents.append(Incident(
                provider_incident_id=str(ev.get("event_id") or ev.get("archive_id") or hash(json.dumps(ev, sort_keys=True))),
                title=f"{ev.get('service_name', 'AWS')}: {ev.get('summary', '')[:200]}",
                impact="degraded",
                status="investigating",
                started_at=_now(),
                resolved_at=None,
                url="https://health.aws.amazon.com/health/status",
            ))
        return Observation(vendor_slug=self.slug, status=status,
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
