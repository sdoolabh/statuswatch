from .base import Adapter, Incident, Observation
from .statuspage import StatuspageAdapter
from .custom import REGISTRY as CUSTOM_REGISTRY


def build(vendor: dict) -> Adapter:
    adapter = vendor["adapter"]
    if adapter == "statuspage":
        return StatuspageAdapter(vendor)
    if adapter in CUSTOM_REGISTRY:
        return CUSTOM_REGISTRY[adapter](vendor)
    raise ValueError(f"unknown adapter '{adapter}' for vendor '{vendor['slug']}'")
