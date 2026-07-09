"""Adapter contract. Every adapter turns one vendor's status API into the
normalized shape. Failure is a first-class result, never an exception that
escapes: an unreachable status page IS information ('unknown')."""
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class Incident:
    provider_incident_id: str
    title: str
    impact: str                 # normalized vendor_status value
    status: str                 # provider vocab (investigating/resolved/...)
    started_at: datetime
    resolved_at: datetime | None
    url: str | None = None
    updates: list = field(default_factory=list)  # [(update_id, body, status, posted_at)]


@dataclass
class Observation:
    vendor_slug: str
    status: str                 # normalized vendor_status value
    incidents: list[Incident] = field(default_factory=list)
    raw: bytes = b""            # exact payload, archived before parsing
    latency_ms: int | None = None
    error: str | None = None    # set => status is 'unknown'


class Adapter:
    """Subclasses implement fetch(). One vendor, one Observation, no leaks."""

    def __init__(self, vendor: dict):
        self.slug = vendor["slug"]
        self.base_url = vendor["base_url"].rstrip("/")

    async def fetch(self, session) -> Observation:  # pragma: no cover
        raise NotImplementedError

    def unknown(self, error: str) -> Observation:
        return Observation(vendor_slug=self.slug, status="unknown", error=error)
