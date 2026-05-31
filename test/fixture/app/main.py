"""
Minimal FastAPI app that should trigger two routing-checker findings:
  1. wrong-handler — /items/{item_id} is registered BEFORE /items/featured,
     so the parametric route shadows the literal one under first-match
     dispatch. Any request to GET /items/featured is served by the
     parametric handler, and `get_featured` never runs.
  2. duplicate-include — `users_router` is mounted twice under the same
     "/api/v1" prefix. The second include is silently dead.
"""
from fastapi import APIRouter, FastAPI

app = FastAPI(title="fixture")

users_router = APIRouter()


@users_router.get("/users/{user_id}")
def get_user(user_id: int):
    return {"user_id": user_id}


items_router = APIRouter()


@items_router.get("/items/{item_id}")
def get_item(item_id: str):
    return {"item_id": item_id, "via": "parametric"}


@items_router.get("/items/featured")
def get_featured():
    return {"items": ["a", "b"], "via": "literal"}

# Duplicate include — second mount of the same router at the same prefix.
app.include_router(users_router, prefix="/api/v1")
app.include_router(users_router, prefix="/api/v1")
app.include_router(items_router, prefix="/api/v1")
