"""Products router — intentionally CLEAN.

Demonstrates patterns that look risky but are correctly handled, so the
checker must NOT report them (false-positive guard):

  * literal routes registered BEFORE the wildcard that could shadow them
  * a :int path-converter that safely separates a numeric id from a
    sibling literal
  * nested static segments under a wildcard
"""
from fastapi import APIRouter

router = APIRouter()


# Literals first, wildcard last — correct ordering, no shadow.
@router.get("/products/featured")
def featured_products():
    return {"products": ["p1", "p2"]}


@router.get("/products/on-sale")
def products_on_sale():
    return {"products": ["p3"]}


@router.get("/products/{product_id:int}")
def get_product(product_id: int):
    return {"product_id": product_id}


@router.get("/products/{product_id:int}/related")
def related_products(product_id: int):
    return {"product_id": product_id, "related": []}


@router.post("/products/")
def create_product(name: str, price: float):
    return {"name": name, "price": price}


@router.put("/products/{product_id:int}")
def replace_product(product_id: int, name: str):
    return {"product_id": product_id, "name": name}


@router.delete("/products/{product_id:int}")
def delete_product(product_id: int):
    return {"deleted": product_id}
