"""Items router.

The literal /items/featured route is registered BEFORE the parametric
/items/{item_id} route, so under FastAPI's first-match dispatch a
request to /items/featured reaches its dedicated handler instead of
being captured by the parametric one.
"""
from fastapi import APIRouter

router = APIRouter()


@router.get("/items/featured")
def get_featured():
    """Return the curated list of featured items."""
    return {"items": ["alpha", "beta", "gamma"], "via": "literal"}


@router.get("/items/{item_id}")
def get_item(item_id: str):
    """Fetch an item by id."""
    return {"item_id": item_id, "via": "parametric"}


@router.get("/items/{item_id}/reviews")
def list_reviews(item_id: str):
    return {"item_id": item_id, "reviews": []}


# A typed-parametric route followed by a literal: not a shadow, because
# the :int path-converter rejects non-integer segments at validation
# time, so /items/numeric/stats reaches its own handler. The routing
# checker correctly refines this away rather than reporting it.
@router.get("/items/numeric/{num:int}")
def get_numeric_item(num: int):
    return {"num": num, "via": "parametric-int"}


@router.get("/items/numeric/stats")
def numeric_stats():
    return {"count": 100, "via": "literal"}
