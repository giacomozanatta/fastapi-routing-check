"""Health/operational router — root-level routes.

Mounted at the application root (no prefix). Most routes are plain
literals with no overlaps; the /healthz/{check} + /healthz/ready pair
deliberately seeds an EXTRA wrong-handler defect (added in the
sticky-delta-render PR) so the self-test exercises the gate path on a
realistic "PR introduces a new finding" scenario alongside the +4/-1
endpoint-delta scenario.
"""
from fastapi import APIRouter

router = APIRouter()


@router.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/readyz")
def readyz():
    return {"ready": True}


# Added in the sticky-delta-render PR so the self-test exercises the
# rendering live. The PR's "Endpoint delta vs base" section should show
# this row under "+ added" with the file:line link pointing here.
# Clean literal, no overlaps, no findings.
@router.get("/buildinfo")
def buildinfo():
    return {"build": "fastapi-routing-check-selftest"}


# Also added in the sticky-delta-render PR — second clean literal, so
# the delta shows multiple "+ added" rows rather than just one.
@router.get("/uptime")
def uptime():
    return {"uptime_seconds": 123456}


# BUG (wrong-handler, HIGH) — added in the sticky-delta-render PR to
# exercise the gate path on a PR that introduces a new defect:
# /healthz/{check} is a str wildcard registered BEFORE /healthz/ready.
# Under first-match dispatch the wildcard binds "ready" as a literal
# string and answers the request itself — the get_healthz_ready handler
# below never executes. This is the same shape as the existing wrong-
# handler defect in items.py, deliberately in a different sub-tree so
# the analyzer reports it independently.
@router.get("/healthz/{check}")
def healthz_check(check: str):
    return {"check": check, "via": "parametric"}


@router.get("/healthz/ready")
def healthz_ready():
    return {"ready": True, "via": "literal"}
