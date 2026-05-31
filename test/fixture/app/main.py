"""
fixture: a multi-file FastAPI service designed to exercise three
silent-routing-defect families against the routing checker.

Defects seeded in this tree
---------------------------

  1. wrong-handler (parametric shadow)
       app/routers/items.py — /items/{item_id} is registered before
       /items/featured, so the literal route is shadowed under
       first-match dispatch.

  2. duplicate-include
       app/routers/users.py — the admin sub-router is included twice
       on the users router; every admin route is silently dead in
       the second mount.

  3. conditional-registration
       app/main.py — POST /api/v2/messages is registered on BOTH
       branches of `if ENABLE_V2_API`, bound to different handlers in
       different files. At deploy time only one runs; which one
       depends on a runtime environment variable.

The analyzer is expected to recover the routing topology across all
four router files and the conditional in main.py, then surface the
three defects with HIGH/HIGH/MEDIUM severity respectively.
"""
from fastapi import FastAPI

from app.config import ENABLE_V2_API
from app.routers import items, messages, users

app = FastAPI(title="fixture", version="0.1")

# --- Top-level mounts -------------------------------------------------
# Stable v1 surface: a router-per-concern, mounted under /api/v1.
app.include_router(users.router, prefix="/api/v1/users")
app.include_router(items.router, prefix="/api/v1")


# --- Conditional v2 mount --------------------------------------------
# The v2 message API ships when the feature flag is on; otherwise we
# mount a back-compat shim under the SAME path. The static analyzer
# cannot resolve ENABLE_V2_API (it is read from the process
# environment in app/config.py), so both branches are reachable in
# the joined abstract state and the routing checker reports the
# resulting POST /api/v2/messages registration as conditional.
if ENABLE_V2_API:
    app.include_router(messages.v2_router, prefix="/api/v2")
else:
    app.include_router(messages.v1_compat_router, prefix="/api/v2")
