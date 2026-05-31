# test/fixture

A multi-file FastAPI service that deliberately seeds **one defect from
every family the routing checker can detect**, alongside intentionally
**clean** routers that exercise the false-positive guards. The self-test
runs the action against this tree and asserts the analyzer detects every
family (and nothing else).

```
app/
├── __init__.py
├── main.py                 ← entrypoint: FastAPI() + all mounts + conditional
├── config.py               ← runtime flag read from os.environ (opaque to AI)
└── routers/
    ├── __init__.py
    ├── users.py            ← duplicate-include (admin sub-router mounted twice)
    ├── admin.py            ← admin sub-router (destructive endpoints)
    ├── items.py            ← wrong-handler (str wildcard before literal)
    ├── orders.py           ← dead-handler (int wildcard before literal)
    ├── search.py           ← GET /search (the registration that runs)
    ├── search_legacy.py    ← duplicate-registration (GET /search again)
    ├── files.py            ← route-overlap (multi-segment parametric)
    ├── messages.py         ← conditional-registration (v2 / v1 on if/else)
    ├── products.py         ← CLEAN (literals-before-wildcards, :int)
    └── health.py           ← CLEAN (root-level literals)
```

## Seeded defects (one per detectable family)

| Family | Severity | Site | Why it's a bug |
|---|---|---|---|
| **duplicate-include** | HIGH | `routers/users.py` | The admin sub-router is `include_router`'d twice at `/admin`; the second mount is dead. |
| **wrong-handler** | HIGH | `routers/items.py` | `str` wildcard `/items/{item_id}` precedes literal `/items/featured`; the wildcard binds "featured" and answers with the wrong handler (200, wrong data). |
| **dead-handler** | MEDIUM | `routers/orders.py` | `int`-typed wildcard `/orders/{order_id}` precedes `/orders/summary`; "summary" fails int validation (422) so the literal is unreachable. |
| **duplicate-registration** | HIGH | `routers/search.py` + `search_legacy.py` | Both expose `GET /search`, mounted at the same prefix; the path is registered twice **across files** and only the first runs. |
| **conditional-registration** | MEDIUM | `routers/messages.py` + `main.py` | `POST /api/v2/messages` is registered on both branches of `if ENABLE_V2_API`, bound to different handlers. |
| **route-overlap** | (HIGH, via wrong-handler) | `routers/files.py` | `/files/{owner}/config` and `/files/me/{name}` carry parameters in different segments and collide at `/files/me/config`. |

### A note on the six categories

The analyzer tracks **six** internal detection categories — `shadows`,
`parametric-shadows`, `route-overlaps`, `duplicate-includes`,
`duplicate-registrations`, and `conditional-registrations` (see the
`# Routing detections — …` header in `routing-detections.txt`). It emits
findings through **five** warning headlines: *route-overlap shares the
`Wrong handler` / `Handler is dead code` headlines* rather than having
its own, so the action's family table lists five.

### A note on dead-handler and type hints

`dead-handler` specifically requires a **validation-rejecting type**. The
fixture uses an `int` type hint on a plain wildcard (`/orders/{order_id}`
+ `order_id: int`). Two look-alike patterns do **not** produce it:

* a **bare** wildcard with no annotation defaults to `str`, which binds
  any literal → that's the *wrong-handler* case (a successful-but-wrong
  200), not dead-handler;
* a **`:int` path converter** (`/orders/{order_id:int}`) is rejected at
  the routing layer before matching, so the sibling literal stays
  reachable and the checker reports nothing.

The numeric signature hint on a plain wildcard is what makes the literal
genuinely dead.

## Clean routers (must NOT produce findings)

* `routers/products.py` — literal routes registered before the wildcards
  that could shadow them, plus `:int` converters that safely separate a
  numeric id from sibling literals.
* `routers/health.py` — root-level literal routes (no prefix).
* the `:int` converters in `users.py` and `items.py`.
