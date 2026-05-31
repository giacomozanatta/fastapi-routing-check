"""Users router with a nested admin sub-router.

Seeds: duplicate-include — admin_router is included twice under
the same /admin prefix; every admin route exposed by the second
inclusion is silently unreachable at runtime.
"""
from fastapi import APIRouter

from app.routers.admin import admin_router

router = APIRouter()


@router.get("/me")
def get_me():
    """Return the authenticated user's profile."""
    return {"user": "me"}


@router.get("/{user_id:int}")
def get_user(user_id: int):
    """Fetch a user by numeric id.

    The :int path-converter on the parameter narrows the route to
    URLs whose final segment parses as an integer. /me above is
    therefore unambiguously reachable on the routing-layer side,
    and the routing checker's Pydantic-style refinement would
    further reject any incompatible literal anyway.
    """
    return {"user_id": user_id}


@router.post("/")
def create_user(name: str):
    return {"created": name}


# Sub-router inclusion — admin endpoints under /admin
router.include_router(admin_router, prefix="/admin")

# BUG: the same admin sub-router is included a second time. FastAPI
# happily registers every admin route twice; the duplicate is dead
# under first-match dispatch.
router.include_router(admin_router, prefix="/admin")
