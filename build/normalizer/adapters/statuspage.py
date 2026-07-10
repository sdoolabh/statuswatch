"""Atlassian Statuspage standard adapter — covers the large majority of
vendors via /api/v2/summary.json (current status + active incidents) and
/api/v2/incidents.json (recent history, including resolved)."""
import json
import time
from datetime import datetime

from .base import Adapter, Incident, Observation

# Statuspage indicator -> our normalized vocabulary
INDICATOR_MAP = {
    "none": "operational",
    "minor": "degraded",
    "major": "partial_outage",
    "critical": "major_outage",
    "maintenance": "maintenance",
}
IMPACT_MAP = {
    "none": "operational",
    "minor": "degraded",
    "major": "partial_outage",
    "critical": "major_outage",
    "maintenance": "maintenance",
}


def _ts(value):
    if not value:
        return None
    # Statuspage timestamps: ISO8601 with offset
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class StatuspageAdapter(Adapter):
    async def fetch(self, session) -> Observation:
        t0 = time.monotonic()
        try:
            async with session.get(f"{self.base_url}/api/v2/summary.json") as r:
                if r.status != 200:
                    return self.unknown(f"summary HTTP {r.status}")
                raw = await r.read()
            summary = json.loads(raw)

            async with session.get(f"{self.base_url}/api/v2/incidents.json") as r:
                incidents_raw = await r.read() if r.status == 200 else b"{}"
            incidents_doc = json.loads(incidents_raw or b"{}")
        except Exception as exc:
            return self.unknown(f"{type(exc).__name__}: {exc}")

        latency = int((time.monotonic() - t0) * 1000)
        indicator = (summary.get("status") or {}).get("indicator", "")
        status = INDICATOR_MAP.get(indicator, "unknown")

        incidents = []
        for inc in (incidents_doc.get("incidents") or [])[:25]:
            incidents.append(Incident(
                provider_incident_id=str(inc.get("id")),
                title=inc.get("name") or "(untitled)",
                impact=IMPACT_MAP.get(inc.get("impact"), "unknown"),
                status=inc.get("status") or "unknown",
                started_at=_ts(inc.get("started_at") or inc.get("created_at")),
                resolved_at=_ts(inc.get("resolved_at")),
                url=inc.get("shortlink"),
                updates=[
                    (str(u.get("id")), u.get("body") or "", u.get("status") or "",
                     _ts(u.get("created_at")))
                    for u in (inc.get("incident_updates") or [])
                ],
            ))

        return Observation(
            vendor_slug=self.slug, status=status, incidents=incidents,
            raw=raw, latency_ms=latency,
        )
