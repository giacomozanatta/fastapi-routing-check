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
