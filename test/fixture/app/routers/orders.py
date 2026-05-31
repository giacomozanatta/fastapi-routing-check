"""Orders router.

Seeds: dead-handler (MEDIUM) — the plain wildcard /orders/{order_id} is
registered before the literal /orders/summary, and order_id is typed
`int`. A request to /orders/summary matches the wildcard first; "summary"
then fails int validation (HTTP 422), so order_summary is never reached.

Note on the int type hint: this defect specifically requires a
validation-rejecting type. A bare wildcard with no annotation defaults
to `str`, which happily binds "summary" — that is the *wrong-handler*
case (a successful-but-wrong 200), not dead-handler. A `:int` path
converter (e.g. /orders/{order_id:int}) is the opposite again: the
routing layer rejects non-integers before matching, so the literal stays
reachable and the checker reports nothing. The numeric signature hint on
a plain wildcard is what makes the literal genuinely dead.
"""
from fastapi import APIRouter

router = APIRouter()


# BUG (dead-handler): int-typed plain wildcard registered before the
# literal it shadows. "summary" fails int validation -> 422 -> dead.
@router.get("/orders/{order_id}")
def get_order(order_id: int):
    """Fetch an order by numeric id."""
    return {"order_id": order_id}


@router.get("/orders/summary")
def order_summary():
    """Aggregate order stats (unreachable at runtime)."""
    return {"open": 12, "shipped": 130}


@router.post("/orders/")
def create_order(total: float):
    return {"created": True, "total": total}


@router.get("/orders/{order_id}/items")
def order_items(order_id: int):
    return {"order_id": order_id, "items": []}
