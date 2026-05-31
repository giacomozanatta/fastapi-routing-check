"""Runtime configuration read from the process environment.

The values here are deliberately opaque to static analysis: reading
from os.environ at module import time gives the analyzer no way to
fold ENABLE_V2_API to a constant, so both branches of any `if`
guarded on it stay reachable in the joined abstract state.
"""
import os

ENABLE_V2_API: bool = os.environ.get("ENABLE_V2_API", "0") == "1"
