"""Admin sub-router mounted under the users router.

This file deliberately exposes destructive endpoints (DELETE /,
GET /stats) so the duplicate-include bug in users.py — which
registers every one of these twice — has visibly meaningful
runtime consequences in a real deployment.
"""
from fastapi import APIRouter

admin_router = APIRouter()


@admin_router.get("/stats")
def admin_stats():
    return {"users": 42, "items": 117}


@admin_router.delete("/")
def admin_delete_all():
    return {"deleted": True}


@admin_router.post("/announce")
def admin_announce(message: str):
    return {"announced": message}
