"""Internal operator tooling: grant access and load the catalog through the real importer.

Never exposed over HTTP. The loader requires an operator session with MFA and catalog_admin;
there is no synthetic shortcut for a persistent store.
"""

import json
from datetime import datetime, timezone
from decimal import Decimal

from .catalog import CatalogImporter
from .service import Problem
from .store import Conflict

PERMISSIONS = ("catalog_admin", "moderation", "lake_read")
FIXTURE_ORIGIN = "https://runpass.invalid/fixture-sintetica"


def grant_access(store, subject, permissions, granted_by, now=None):
    """Create or update OPERATOR#sub/ACCESS. A distinct responsible must grant it."""
    if not subject or not granted_by:
        raise ValueError("Operator subject and responsible are required")
    if granted_by == subject:
        raise ValueError("A distinct responsible must grant operator access")
    unknown = set(permissions) - set(PERMISSIONS)
    if unknown or not permissions:
        raise ValueError("Unknown or empty permissions")
    key = ("identity", f"OPERATOR#{subject}", "ACCESS")
    current = store.get(key)
    now = now or datetime.now(timezone.utc)
    value = {
        "state": "active",
        "permissions": sorted(set(permissions)),
        "grantedBy": granted_by,
        "grantedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        store.commit({key: current}, {key: value})
    except Conflict as error:
        raise Problem(409, "ACCESS_CONFLICT") from error
    return store.get(key)


def load_catalog(catalog, actor, fixture_text, origin=FIXTURE_ORIGIN):
    """Load editions through CatalogImporter as an MFA operator; safe to repeat."""
    entries = json.loads(fixture_text, parse_float=Decimal)
    importer = CatalogImporter(catalog)
    for entry in entries:
        importer.put(entry, expected_version=0, origin=origin, actor=actor)
    return [entry["id"] for entry in entries]
