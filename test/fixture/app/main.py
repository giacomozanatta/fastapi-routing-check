"""
fixture: a larger multi-file FastAPI service that deliberately seeds one
defect from every family the routing checker can detect, alongside a set
of intentionally CLEAN routers that exercise the false-positive guards.

Seeded defects (one per detectable class)
-----------------------------------------

  1. duplicate-include (HIGH)
       app/routers/users.py — the admin sub-router is included twice on
       the users router; the second mount is dead.

  2. wrong-handler (HIGH)
       app/routers/items.py — the str wildcard /items/{item_id} is
       registered before the literal /items/featured, which it captures.

  3. dead-handler (MEDIUM)
       app/routers/orders.py — the int-typed wildcard /orders/{order_id}
       precedes /orders/summary; "summary" fails int validation (422) so
       the literal is unreachable.

  4. duplicate-registration (HIGH)
       app/routers/search.py + search_legacy.py — both expose GET /search
       and are mounted at the same prefix, so the path is registered
       twice across files and only the first runs.

  5. conditional-registration (MEDIUM)
       app/routers/messages.py — POST /api/v2/messages is registered on
       both branches of `if ENABLE_V2_API`, bound to different handlers.

  6. route-overlap (surfaces under the wrong-handler headline)
       app/routers/files.py — /files/{owner}/config and /files/me/{name}
       carry parameters in different segments and collide at
       /files/me/config. This is the analyzer's sixth internal detection
       category; it does not have its own warning headline.

Clean routers (must NOT produce findings)
-----------------------------------------

  * app/routers/products.py — literals before wildcards, :int converters.
  * app/routers/health.py    — root-level literal routes.
  * the :int converters in users.py and items.py.
"""
from fastapi import FastAPI

from app.config import ENABLE_V2_API
from app.routers import (
    files,
    health,
    items,
    messages,
    orders,
    products,
    search,
    search_legacy,
    users,
)

app = FastAPI(title="fixture", version="0.2")

# --- Operational surface (root) --------------------------------------
app.include_router(health.router)

# --- Stable v1 surface (a router-per-concern under /api/v1) ----------
app.include_router(users.router, prefix="/api/v1/users")
app.include_router(items.router, prefix="/api/v1")
app.include_router(orders.router, prefix="/api/v1")
app.include_router(products.router, prefix="/api/v1")
app.include_router(files.router, prefix="/api/v1")

# Duplicate-registration: search.router and search_legacy.legacy_router
# both expose GET /search and are mounted at the same prefix.
app.include_router(search.router, prefix="/api/v1")
app.include_router(search_legacy.legacy_router, prefix="/api/v1")


# --- Conditional v2 mount --------------------------------------------
# The v2 message API ships when the feature flag is on; otherwise a
# back-compat shim is mounted under the SAME path. ENABLE_V2_API is read
# from the process environment (app/config.py), so the analyzer cannot
# fold the condition and both branches stay reachable in the joined
# abstract state — POST /api/v2/messages is reported as conditional.
if ENABLE_V2_API:
    app.include_router(messages.v2_router, prefix="/api/v2")
else:
    app.include_router(messages.v1_compat_router, prefix="/api/v2")
