"""Files router.

Seeds: route-overlap (the analyzer's sixth internal detection category,
"multi-segment parametric overlap"). Two routes carry path parameters
in *different* segments and collide on a subset of URLs:

    GET /files/{owner}/config   matches /files/me/config (owner="me")
    GET /files/me/{name}        matches /files/me/config (name="config")

Neither route strictly shadows the other, but they overlap at
/files/me/config. The first-registered route wins there, so the second
is unreachable for that URL. The checker reports this as a route-overlap;
because the winning route binds the colliding segment to a literal
value, it surfaces under the "Wrong handler" warning headline (there is
no separate route-overlap headline — it shares wrong-handler/dead-handler).
"""
from fastapi import APIRouter

router = APIRouter()


# BUG (route-overlap): collides with /files/me/{name} at /files/me/config.
@router.get("/files/{owner}/config")
def file_config(owner: str):
    """Per-owner config blob."""
    return {"owner": owner, "kind": "config"}


@router.get("/files/me/{name}")
def my_file(name: str):
    """Named file in the caller's own space."""
    return {"name": name, "owner": "me"}
