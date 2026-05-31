"""Two parallel routers for the messages API.

v2_router and v1_compat_router both expose POST /messages, bound to
different handlers. app/main.py mounts them under distinct prefixes
(/api/v2 and /api/v1 respectively), so each fully-qualified path maps
to exactly one handler.
"""
from fastapi import APIRouter

v2_router = APIRouter()
v1_compat_router = APIRouter()


@v2_router.post("/messages")
def post_message_v2(text: str):
    """Post a v2-shaped message."""
    return {"sent": text, "version": "v2", "format": "json"}


@v1_compat_router.post("/messages")
def post_message_v1_compat(text: str):
    """Post a v1-compatible message.

    Mounted under /api/v1 (distinct from v2's /api/v2 prefix). The
    payload contract differs from v2's: v1 returns a flat envelope,
    v2 returns a structured one.
    """
    return {"sent": text, "version": "v1-compat"}
