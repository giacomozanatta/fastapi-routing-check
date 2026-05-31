"""
fixture: a multi-file FastAPI service used to exercise the routing
checker across multiple router files and inclusion chains.

The tree recovers a routing topology spanning four router files plus
the top-level mounts in this module. Every path resolves to exactly
one handler, so a correctly functioning routing checker reports no
findings against it.

Patterns exercised
------------------

  * Multi-file router discovery — main.py imports the users and items
    routers from app/routers/, and users.py further includes the admin
    sub-router from a sibling module.

  * Router inclusion chains — app -> users.router -> admin_router is a
    two-level mount the analyzer must traverse.

  * Typed path converters — items.py and users.py use :int converters,
    which the checker refines so look-alike literals are not reported
    as shadowed.
"""
from fastapi import FastAPI

from app.routers import items, messages, users

app = FastAPI(title="fixture", version="0.1")

# --- Top-level mounts -------------------------------------------------
# Stable v1 surface: a router-per-concern, mounted under /api/v1.
app.include_router(users.router, prefix="/api/v1/users")
app.include_router(items.router, prefix="/api/v1")


# --- Message API mounts ----------------------------------------------
# The v2 message API and the v1-compatible shim are mounted under
# distinct prefixes, so POST /api/v2/messages and POST /api/v1/messages
# each resolve unambiguously to their own handler regardless of any
# runtime configuration.
app.include_router(messages.v2_router, prefix="/api/v2")
app.include_router(messages.v1_compat_router, prefix="/api/v1")
