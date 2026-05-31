"""Items router.

Seeds: wrong-handler (HIGH) — the str-typed wildcard /items/{item_id}
is registered BEFORE the literal /items/featured. Under first-match
dispatch the wildcard captures "featured" (a valid str), so a request
to /items/featured runs get_item with item_id="featured" and returns a
successful-but-wrong response; get_featured never executes.
"""
from fastapi import APIRouter

router = APIRouter()


# BUG (wrong-handler): str wildcard registered before the literal it
# shadows. "featured" is a valid str, so get_item answers the request.
@router.get("/items/{item_id}")
def get_item(item_id: str):
    """Fetch an item by id."""
    return {"item_id": item_id, "via": "parametric"}


@router.get("/items/featured")
def get_featured():
    """Return the curated list of featured items (unreachable at runtime)."""
    return {"items": ["alpha", "beta", "gamma"], "via": "literal"}


@router.get("/items/{item_id}/reviews")
def list_reviews(item_id: str):
    return {"item_id": item_id, "reviews": []}


# Correctly handled (no finding): the :int path-converter rejects
# non-integer segments at the routing layer, so /items/numeric/stats
# reaches its own handler. The checker refines this away.
@router.get("/items/numeric/{num:int}")
def get_numeric_item(num: int):
    return {"num": num, "via": "parametric-int"}


@router.get("/items/numeric/stats")
def numeric_stats():
    return {"count": 100, "via": "literal"}
