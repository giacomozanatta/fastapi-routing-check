"""Health/operational router — intentionally CLEAN.

Mounted at the application root (no prefix). Plain literal routes with
no overlaps, exercising root-level registration in the topology.
"""
from fastapi import APIRouter

router = APIRouter()


@router.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/readyz")
def readyz():
    return {"ready": True}


@router.get("/version")
def version():
    return {"version": "0.2"}


# Added in the sticky-delta-render PR so the self-test exercises the
# rendering live: this PR's own CI run should produce a sticky comment
# whose "Endpoint delta vs base" section shows "+1 added" with this
# line as the source. Clean literal, no overlaps, no findings.
@router.get("/buildinfo")
def buildinfo():
    return {"build": "fastapi-routing-check-selftest"}
