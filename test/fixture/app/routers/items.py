"""Items router.

Seeds: wrong-handler (parametric shadow) — /items/{item_id} is
registered BEFORE /items/featured on the same router, so under
FastAPI's first-match dispatch any request to /items/featured is
served by the parametric handler with item_id="featured" and
the literal handler never runs.
"""
from fastapi import APIRouter

router = APIRouter()


@router.get("/items/{item_id}")
def get_item(item_id: str):
    """Fetch an item by id."""
    return {"item_id": item_id, "via": "parametric"}


@router.get("/items/featured")
def get_featured():
    """Return the curated list of featured items.

    BUG: this handler is unreachable. The parametric route above
    captures every URL that would match this path, so a request
    to /api/v1/items/featured returns
    {"item_id": "featured", "via": "parametric"} from get_item,
    not the curated list this function builds.
    """
    return {"items": ["alpha", "beta", "gamma"], "via": "literal"}


@router.get("/items/{item_id}/reviews")
def list_reviews(item_id: str):
    return {"item_id": item_id, "reviews": []}
