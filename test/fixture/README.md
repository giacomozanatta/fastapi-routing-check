# test/fixture

A small but multi-file FastAPI service that exercises the analyzer's
interprocedural reach. Every path resolves to exactly one handler, so
a correctly functioning routing checker reports no findings against it.
The self-test runs the action against this tree and asserts the
analysis pipeline runs cleanly (endpoints recovered, no findings, no
false positives).

```
app/
├── __init__.py
├── main.py                 ← entrypoint: FastAPI() + top-level mounts
└── routers/
    ├── __init__.py
    ├── users.py            ← users router + admin sub-router include
    ├── admin.py            ← admin sub-router (destructive endpoints)
    ├── items.py            ← items router (literal-before-parametric)
    └── messages.py         ← v2 + v1-compat routers on distinct prefixes
```

## Routing topology

| Concern | Site | Notes |
|---|---|---|
| **items** | `app/routers/items.py` | `/items/featured` is registered before `/items/{item_id}`, so the literal route is reachable under first-match dispatch. |
| **users + admin** | `app/routers/users.py` | The admin sub-router is included exactly once under `/admin`; every admin route is reachable. |
| **messages** | `app/main.py` | `v2_router` and `v1_compat_router` are mounted under distinct prefixes (`/api/v2` and `/api/v1`), so each path maps to a single handler. |

## Analyzer features the fixture exercises

* **Multi-file router discovery** — `main.py` imports two routers from
  `app/routers/`, and `users.py` further imports the admin sub-router
  from a sibling module.
* **Router inclusion chains** — `app → users.router → admin_router`
  is a two-level mount that the analyzer must traverse to recover the
  full admin surface.
* **Typed path converters** — `items.py` and `users.py` use `:int`
  converters; the checker refines these so look-alike literals
  (`/items/numeric/stats`, `/users/me`) are not reported as shadowed.
  The fixture verifies the checker raises no false positives on these
  patterns.
