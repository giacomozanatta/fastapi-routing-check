"""Two parallel routers for the v2 messages API.

Seeds: conditional-registration — v2_router and v1_compat_router
both expose POST /messages, bound to different handlers. The
conditional in app/main.py mounts ONE of them under /api/v2 based
on a runtime feature flag, so POST /api/v2/messages dispatches to
a different function in different deployments.
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

    Deployed when ENABLE_V2_API is unset/false. The route path is
    identical to v2's, but the payload contract differs: v1 returns
    a flat envelope, v2 returns a structured one. Whichever branch
    of the main.py conditional ran at startup determines what every
    caller sees.
    """
    return {"sent": text, "version": "v1-compat"}
