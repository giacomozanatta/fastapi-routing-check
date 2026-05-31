# test/fixture

A small but multi-file FastAPI service that exercises the analyzer's
interprocedural reach and intentionally seeds three silent routing
defects, one per family. The self-test runs the action against this
tree and asserts the routing checker emits exactly the expected
findings.

```
app/
├── __init__.py
├── main.py                 ← entrypoint: FastAPI() + top-level mounts
├── config.py               ← runtime flag read from os.environ (opaque to AI)
└── routers/
    ├── __init__.py
    ├── users.py            ← users router + admin sub-router include
    ├── admin.py            ← admin sub-router (destructive endpoints)
    ├── items.py            ← items router (parametric shadow defect)
    └── messages.py         ← v2 + v1-compat routers for the conditional
```

## Seeded defects

| Family | Site | Why it's a bug |
|---|---|---|
| **wrong-handler** (HIGH) | `app/routers/items.py:14` | `/items/{item_id}` is registered before `/items/featured`; under first-match dispatch the literal route is unreachable. |
| **duplicate-include** (HIGH) | `app/routers/users.py:30` | The admin sub-router is included twice on the users router; every admin route is silently dead in the second mount. |
| **conditional-registration** (MEDIUM) | `app/main.py:39–42` | `POST /api/v2/messages` is registered on both branches of `if ENABLE_V2_API`, bound to different handlers in different files. |

## Analyzer features the fixture exercises

* **Multi-file router discovery** — `main.py` imports two routers from
  `app/routers/`, and `users.py` further imports the admin sub-router
  from a sibling module.
* **Router inclusion chains** — `app → users.router → admin_router`
  is a two-level mount that the analyzer must traverse to attribute
  the duplicate-include correctly.
* **Conditional registration on incomparable branches** — the
  `if/else` in `main.py` mounts different routers under the same
  prefix; the analyzer must join both branches and report the
  same-path-different-handler outcome.
* **Constant-folding resistance** — `ENABLE_V2_API` is read from
  `os.environ` at module load, so the analyzer cannot fold the
  condition to a constant; both branches stay reachable in the
  joined abstract state.
