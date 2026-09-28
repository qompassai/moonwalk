"""MW-REQ-008 (adversarial): setBreakpoints with a non-table breakpoint entry.

The `breakpoints` array must contain objects; a string entry must not
make the adapter index a non-table. Exactly one unsuccessful response,
and the adapter still answers afterwards.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, malformed_roundtrip  # noqa: E402

CASE = {
    "id": "MW-REQ-008",
    "kind": "adversarial",
    "layer": "protocol",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["single-response", "no-crash-on-invalid-input"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])
    launch_loop(ctx, client)
    program = ctx.fixture("breakme.lua")
    malformed_roundtrip(ctx, client, "setBreakpoints", {
        "source": {"name": "breakme.lua", "path": program},
        "breakpoints": [{"line": 3}, "not-a-breakpoint"],
    })
    end_session(ctx, client)
