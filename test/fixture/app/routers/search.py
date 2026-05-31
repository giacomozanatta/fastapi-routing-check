"""Primary search router.

Pairs with search_legacy.py to seed a duplicate-registration: both
routers expose GET /search and are mounted at the same /api/v1 prefix
in main.py, so GET /api/v1/search is registered twice across files and
only the first registration runs.
"""
from fastapi import APIRouter

router = APIRouter()


@router.get("/search")
def search(q: str, limit: int = 20):
    """Full-text search (the registration that actually runs)."""
    return {"q": q, "limit": limit, "engine": "primary"}


@router.get("/search/suggest")
def suggest(prefix: str):
    return {"prefix": prefix, "suggestions": []}
