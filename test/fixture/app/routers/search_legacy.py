"""Legacy search router (kept for backwards compatibility).

Seeds: duplicate-registration (HIGH) — legacy_router also defines
GET /search. main.py mounts both this router and search.router at the
same /api/v1 prefix, so GET /api/v1/search collides across two files;
under first-match dispatch only search.router's handler runs and this
one is dead.
"""
from fastapi import APIRouter

legacy_router = APIRouter()


# BUG (duplicate-registration): same (GET, /search) as search.router,
# mounted at the same prefix from a different file. This one is dead.
@legacy_router.get("/search")
def legacy_search(q: str):
    """Old search implementation (dead: shadowed by search.router)."""
    return {"q": q, "engine": "legacy"}
